#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Deploys the release's static site to the deployable's Static Web App, with the topology of the whole system.

.DESCRIPTION
    Step "Update deployable" of an Octopus project <slug>-<deployable> whose deployable is a static site (system.json
    hosting "staticwebapp": the health dashboard); octopus/projects.tf inlines this file. The package reference "site"
    is the zip the dashboard's release workflow pushed to the Octopus built-in feed (<slug>-<deployable>.<version>.zip,
    index.html at its root), extracted. The site is the one the stack created (stack output deployables[].staticSite).

    1. topology.json, written next to index.html (the contract is in the dashboard repository's README): every
       environment of system.json on main and, in each, the deployables whose nodes are known:
       - hosting "appservice": its nodes by naming convention, app-<slug>-<env>-<deployable> in system.location
         (primary) and, when the environment has a standbyLocation, app-<slug>-<env>-<deployable>-<region>
         (standby). An environment with capability "frontdoor" also gets the address of its Front Door endpoint,
         read from the system's profile (azure.frontDoor).
       - hosting "own": what the application reported when it was last verified there, the deployable's entry in
         environments/<env>/nodes.json on main (scripts/invoke-application.ps1 records it): its nodes, its paths and
         its own public address. Without a record in an environment the deployable is left out of that environment,
         and the log says so. A record that breaks the rules stops the step: it would break the dashboard's page.
       Container-app deployables are left out: their address is not a convention (the platform generates it, and a
       placement changes it), so the dashboard does not show them.
    2. The deployment, with the Static Web Apps CLI and the site's deployment token. The token is read from Azure
       when the step runs (the deploy identity may; the stack's deny settings keep everyone else from listing it),
       reaches the CLI through an environment variable, and is never stored, printed or passed as an argument.
    3. The proof: the site serves the topology this step wrote.

    The topology is a picture of system.json and the recorded nodes at the time of the deployment. After a change to
    the environments, a standby region or a Front Door endpoint, or a deployment of an application with hosting "own"
    that changed its nodes, deploy the dashboard's release again in every environment that has it: until then its
    page shows the old picture. An environment that is in system.json but not applied yet shows its nodes as
    unreachable.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

# The Static Web Apps CLI, at a fixed version: a promotion deploys with the tool the earlier environments used.
$swaCliVersion = '2.0.10'
$swaCliNodeVersion = 18

function ConvertTo-Topology {
    # The dashboard's topology from system.json (parsed, as a hashtable), the host name of each Front Door endpoint
    # by endpoint name (<slug>-<env>-<deployable>), and the recorded nodes of the deployables with hosting "own" by
    # environment and deployable (each as ConvertTo-NodeRecord returns it). It asks nothing: the same input gives the
    # same topology. The deployables keep the order of system.json.
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [hashtable] $EndpointHost = @{},
        [hashtable] $NodeRecord = @{},
        [datetime] $Generated = [datetime]::UtcNow
    )
    $slug = [string] $System.system.slug
    $location = [string] $System.system.location
    $environments = @(foreach ($environment in @($System.environments)) {
            $environmentName = [string] $environment.name
            $standbyLocation = [string] $environment['standbyLocation']
            $hasFrontDoor = @($environment['capabilities']) -contains 'frontdoor'
            $recorded = if ($NodeRecord[$environmentName] -is [Collections.IDictionary]) { $NodeRecord[$environmentName] } else { @{} }
            $deployables = @(foreach ($app in @($System.deployables)) {
                    if ($app['hosting'] -eq 'appservice') {
                        $primary = "app-$slug-$environmentName-$($app.name)"
                        $nodes = @([ordered] @{ name = $primary; region = $location; role = 'primary'; url = "https://$primary.azurewebsites.net" })
                        if ($standbyLocation) {
                            $standby = "$primary-$standbyLocation"
                            $nodes += [ordered] @{ name = $standby; region = $standbyLocation; role = 'standby'; url = "https://$standby.azurewebsites.net" }
                        }
                        $hostName = [string] $EndpointHost["$slug-$environmentName-$($app.name)"]
                        [ordered] @{
                            name        = [string] $app.name
                            frontDoor   = if ($hasFrontDoor -and $hostName) { "https://$hostName" } else { $null }
                            healthPath  = if ($app['healthPath']) { [string] $app.healthPath } else { '/_healthcheck' }
                            alivePath   = '/alive'
                            versionPath = '/_version'
                            nodes       = $nodes
                        }
                    }
                    elseif ($app['hosting'] -eq 'own' -and $recorded[[string] $app.name] -is [Collections.IDictionary]) {
                        # The application's own report: its name first, then the fields it recorded, in their order.
                        $record = $recorded[[string] $app.name]
                        $entry = [ordered] @{ name = [string] $app.name }
                        foreach ($key in 'frontDoor', 'healthPath', 'alivePath', 'versionPath') {
                            if ($record.Contains($key)) { $entry[$key] = $record[$key] }
                        }
                        $entry.nodes = @($record['nodes'])
                        $entry
                    }
                })
            [ordered] @{ name = $environmentName; tier = [string] $environment['tier']; deployables = $deployables }
        })
    return [ordered] @{
        system       = [ordered] @{ slug = $slug; name = [string] $System.system['name'] }
        generated    = $Generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        environments = $environments
    }
}

function ConvertTo-NodeRecord {
    # One deployable's nodes, as its verify.ps1 reported them or as environments/<env>/nodes.json records them,
    # reduced to the fields the dashboard's topology knows, in one order. Returns Record ($null when a rule is
    # broken) and Problems (every broken rule, by field). It asks nothing: the same input gives the same result.
    # scripts/invoke-application.ps1 and scripts/deploy-staticwebapp.ps1 hold this function, line for line:
    # octopus/projects.tf inlines one file per step, so the two cannot share it.
    param([AllowNull()] [object] $Value)
    $problems = [Collections.Generic.List[string]]::new()
    if ($Value -isnot [Collections.IDictionary]) {
        return @{ Record = $null; Problems = [string[]] @('one JSON object is expected') }
    }
    $isAddress = {
        param([AllowNull()] [object] $Text)
        $address = $null
        $Text -is [string] -and [uri]::TryCreate($Text.Trim(), [UriKind]::Absolute, [ref] $address) -and $address.Scheme -cin 'http', 'https'
    }
    $record = [ordered] @{}
    if ($Value.Contains('frontDoor') -and $null -ne $Value['frontDoor']) {
        if (& $isAddress $Value['frontDoor']) { $record.frontDoor = ([string] $Value['frontDoor']).Trim() }
        else { $problems.Add('frontDoor: not an absolute http or https address') }
    }
    foreach ($key in 'healthPath', 'alivePath', 'versionPath') {
        if (-not $Value.Contains($key) -or $null -eq $Value[$key]) { continue }
        if ($Value[$key] -is [string] -and $Value[$key] -cmatch '^/\S*\z') { $record[$key] = [string] $Value[$key] }
        else { $problems.Add("${key}: not a path that starts with /") }
    }
    # Not as the value of an if: that would unroll a list of one node into the node.
    $listed = $null
    if ($Value.Contains('nodes')) { $listed = $Value['nodes'] }
    if ($listed -isnot [array] -or $listed.Count -eq 0) {
        $problems.Add('nodes: a list of at least one node is required')
    }
    else {
        $nodes = [Collections.Generic.List[object]]::new()
        $seen = @{}
        for ($index = 0; $index -lt $listed.Count; $index++) {
            $entry = $listed[$index]
            if ($entry -isnot [Collections.IDictionary]) { $problems.Add("nodes[$index]: not an object"); continue }
            $node = [ordered] @{}
            foreach ($key in 'name', 'region', 'role') {
                if (-not $entry.Contains($key) -or $null -eq $entry[$key]) { continue }
                if ($entry[$key] -isnot [string] -or -not $entry[$key].Trim()) { $problems.Add("nodes[$index].${key}: not a text"); continue }
                $node[$key] = $entry[$key].Trim()
            }
            if ($node.Contains('role') -and $node.role -cnotin 'primary', 'standby') { $problems.Add("nodes[$index].role: not primary or standby") }
            if (-not $entry.Contains('url') -or -not (& $isAddress $entry['url'])) { $problems.Add("nodes[$index].url: missing or not an absolute http or https address"); continue }
            $node.url = ([string] $entry['url']).Trim()
            $address = $node.url.TrimEnd('/').ToLowerInvariant()
            if ($seen.ContainsKey($address)) { $problems.Add("nodes[$index].url: the same address as nodes[$($seen[$address])]"); continue }
            $seen[$address] = $index
            $nodes.Add($node)
        }
        $record.nodes = $nodes.ToArray()
    }
    if ($problems.Count -gt 0) { return @{ Record = $null; Problems = [string[]] $problems.ToArray() } }
    return @{ Record = $record; Problems = [string[]] @() }
}

function Measure-Topology {
    # What a topology holds, for the step's summary line: its environments, its nodes (those by naming convention and
    # those an application reported) and its public addresses.
    param([Parameter(Mandatory)] [Collections.IDictionary] $Topology)
    $nodes = 0
    $addresses = 0
    foreach ($environment in @($Topology['environments'])) {
        foreach ($deployable in @($environment['deployables'])) {
            $nodes += @($deployable['nodes']).Count
            if ($deployable['frontDoor']) { $addresses++ }
        }
    }
    return @{ Environments = @($Topology['environments']).Count; Nodes = $nodes; Addresses = $addresses }
}

function Read-MainFile {
    # The text of a file of the system repository on main, or $null when main has no such file (404).
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $file = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/contents/${Path}?ref=main" -Headers $headers
    }
    catch {
        # Not every failure has a response (a name that does not resolve).
        $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
        if ($response -and [int] $response.StatusCode -eq 404) { return $null }
        throw
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
}

function Read-NodeRecord {
    # The nodes of the deployables with hosting "own", by environment and deployable: only the application knows what
    # it runs on, and its step "Verify deployable" records what it reported in environments/<env>/nodes.json on main
    # (scripts/invoke-application.ps1). Read for every environment, as the topology shows them all. A deployable
    # without a record in an environment is left out there, with one line that says so; a record that breaks the
    # rules stops the step, because the dashboard shows nothing at all when one entry of its topology is wrong.
    param([Parameter(Mandatory)] [hashtable] $System)
    $records = @{}
    $owners = @($System.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
    if ($owners.Count -eq 0) { return $records }
    foreach ($environment in @($System.environments | ForEach-Object { [string] $_.name })) {
        $path = "environments/$environment/nodes.json"
        $text = Read-MainFile -Path $path
        $recorded = $null
        if ($null -ne $text) {
            $recorded = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
            if ($recorded -isnot [Collections.IDictionary]) {
                Fail-Step "$path on main of $repository is not a JSON object: correct it by pull request, then deploy $name $version to $environmentName again."
            }
        }
        $records[$environment] = @{}
        foreach ($owner in $owners) {
            if ($null -eq $recorded -or -not $recorded.Contains($owner)) {
                Write-Host "No nodes of $owner are recorded for $environment ($path on main): the dashboard leaves $owner out of $environment until its application reports them there and this release is deployed again."
                continue
            }
            $checked = ConvertTo-NodeRecord $recorded[$owner]
            if ($checked.Problems.Count -gt 0) {
                Fail-Step "$path on main of $repository records nodes of $owner that break the rules: $($checked.Problems -join '; '). The next deployment of $owner to $environment writes the record anew; then deploy $name $version to $environmentName again."
            }
            $records[$environment][$owner] = $checked.Record
        }
    }
    return $records
}

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$repository = [string] $OctopusParameters['System.Repository']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$name = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$folder = [string] $OctopusParameters['Octopus.Action.Package[site].ExtractedPath']

if (-not $folder -or -not (Test-Path -LiteralPath (Join-Path $folder 'index.html'))) {
    Fail-Step "The release has no site package for $name with index.html at its root ($folder)."
}
$folder = (Resolve-Path -LiteralPath $folder).Path

# The Static Web Apps CLI is a Node.js tool, run with npx: the worker container must bring both.
foreach ($tool in 'node', 'npx') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail-Step "The worker container has no $tool, which the Static Web Apps CLI needs: use a worker-tools image with Node.js $swaCliNodeVersion or later (octopus/main.tf, worker_tools_image)."
    }
}
$nodeVersion = ([string] (node --version)).Trim()
if ([int] ($nodeVersion -replace '^v(\d+).*$', '$1') -lt $swaCliNodeVersion) {
    Fail-Step "The worker container has Node.js $nodeVersion; the Static Web Apps CLI $swaCliVersion needs $swaCliNodeVersion or later (octopus/main.tf, worker_tools_image)."
}

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$entry = @($outputs.deployables.value | Where-Object { $_.name -eq $name -and $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
if (-not $entry) {
    Fail-Step "Stack stack-$slug-$environmentName has no static site named ${name}: deploy the latest $slug-system release to $environmentName first."
}
$staticSite = [string] $entry.staticSite
$url = ([string] $entry.url).TrimEnd('/')

# system.json on main, through the API (raw.githubusercontent.com caches for minutes): the current desired state of
# the whole system, not the commit of an older release.
$headers = @{
    Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$systemText = Read-MainFile -Path 'system.json'
if ($null -eq $systemText) {
    Fail-Step "$repository has no system.json on main."
}
$system = $systemText | ConvertFrom-Json -AsHashtable
$ownDeployables = @($system.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
$nodeRecords = Read-NodeRecord -System $system

# The public address of an environment with capability "frontdoor" is the host name of its endpoint
# <slug>-<env>-<deployable> in the system's Front Door profile, which the deploy identities of both tiers may read.
$endpointHosts = @{}
$frontDoor = if ($system.azure.ContainsKey('frontDoor')) { $system.azure.frontDoor } else { @{} }
$withFrontDoor = @($system.environments | Where-Object { @($_['capabilities']) -contains 'frontdoor' } | ForEach-Object { [string] $_.name })
# A dormant Front Door (azure.frontDoor.dormant) has no profile to ask: the dashboard then shows the nodes only.
if ($withFrontDoor.Count -gt 0 -and $frontDoor['profile'] -and -not $frontDoor['dormant']) {
    $listed = az afd endpoint list --resource-group ([string] $frontDoor.resourceGroup) --profile-name ([string] $frontDoor.profile) `
        --query '[].{name: name, hostName: hostName}' --only-show-errors --output json | ConvertFrom-Json -AsHashtable
    foreach ($endpoint in @($listed | Where-Object { $_ })) {
        $endpointHosts[[string] $endpoint.name] = [string] $endpoint.hostName
    }
}

$topology = ConvertTo-Topology -System $system -EndpointHost $endpointHosts -NodeRecord $nodeRecords
foreach ($environment in $topology.environments) {
    foreach ($deployable in $environment.deployables) {
        # The system's Front Door serves the App Service deployables; an application's own public address is in its record.
        if (-not $deployable['frontDoor'] -and $withFrontDoor -contains $environment.name -and $ownDeployables -notcontains $deployable.name) {
            Write-Host "No Front Door endpoint $slug-$($environment.name)-$($deployable.name) in $($frontDoor['profile']) yet: the dashboard shows $($deployable.name) in $($environment.name) without a public address until it is deployed again."
        }
    }
}
($topology | ConvertTo-Json -Depth 10) + "`n" | Set-Content -LiteralPath (Join-Path $folder 'topology.json') -Encoding utf8NoBOM -NoNewline
$counted = Measure-Topology -Topology $topology
$summary = "$($counted.Environments) environment(s), $($counted.Nodes) node(s), $($counted.Addresses) public address(es)"
Write-Host "topology.json of $($topology.generated): $summary"

# The deployment token of the site: read now, kept in this variable only, handed to the CLI through its environment
# variable (never an argument, which a process list shows), and removed from the environment when the CLI has ended.
$token = ([string] (az staticwebapp secrets list --name $staticSite --resource-group $resourceGroup --query properties.apiKey --only-show-errors --output tsv)).Trim()
if (-not $token) {
    Fail-Step "Azure returned no deployment token for $staticSite."
}

# The CLI (and npx before it) reports its progress on stderr, which Octopus would log as errors: everything it writes
# is captured and shown as information, and its exit code decides. The CLI takes its working directory as the "app
# location", which it searches for an api folder, workflow files and a configuration file: it runs in a folder of its
# own that holds nothing but the site.
Write-Host "Deploying $name $version to $staticSite with the Static Web Apps CLI $swaCliVersion (Node.js $nodeVersion)"
$env:NO_COLOR = '1'
$env:npm_config_update_notifier = 'false'
$stage = Join-Path ([IO.Path]::GetTempPath()) "site-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -LiteralPath $folder -Destination (Join-Path $stage 'site') -Recurse
Push-Location -LiteralPath $stage
try {
    $env:SWA_CLI_DEPLOYMENT_TOKEN = $token
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(npx --yes "@azure/static-web-apps-cli@$swaCliVersion" deploy ./site --env production 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -LiteralPath Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue
    Pop-Location
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
# Colour codes out, and the token too, should a tool ever echo it.
$lines = @($output | ForEach-Object { ($_ -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '').Replace($token, '***').TrimEnd() } | Where-Object { $_ })
$token = $null
$lines | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) {
    Fail-Step "The Static Web Apps CLI ended with exit code $code while deploying $name $version to ${staticSite}; its output is above."
}

# The proof that this release is what the site serves: the topology written above, by its time stamp. A deployment
# takes the platform a moment to publish everywhere.
$deadline = (Get-Date).AddMinutes(5)
$served = ''
while ($true) {
    try {
        $answer = Invoke-WebRequest -Uri "$url/topology.json" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 60 -SkipHttpErrorCheck
        $text = if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }
        # By pattern, not as JSON: ConvertFrom-Json turns the time stamp into a date, in the worker's own format.
        $served = if ([int] $answer.StatusCode -eq 200) { [regex]::Match($text, '"generated"\s*:\s*"([^"]*)"').Groups[1].Value } else { "HTTP $([int] $answer.StatusCode)" }
    }
    catch {
        $served = $_.Exception.Message
    }
    if ($served -eq $topology.generated) { break }
    if ((Get-Date) -gt $deadline) {
        Fail-Step "$url/topology.json does not serve the topology of this deployment ($($topology.generated)) after 5 minutes: it answered '$served'. The CLI's output is above."
    }
    Write-Host "$url/topology.json answered '$served', not $($topology.generated) yet; retrying"
    Start-Sleep -Seconds 10
}
Write-Highlight "$name $version deployed to $staticSite in ${environmentName}: $url ($summary)"
