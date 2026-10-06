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
       environment of system.json on main and, in each, every deployable with hosting "appservice", with its nodes by
       naming convention: app-<slug>-<env>-<deployable> in system.location (primary) and, when the environment has a
       standbyLocation, app-<slug>-<env>-<deployable>-<region> (standby). An environment with capability "frontdoor"
       also gets the address of its Front Door endpoint, read from the system's profile (azure.frontDoor).
       Container-app deployables are left out: their address is not a convention (the platform generates it, and a
       placement changes it), so the dashboard does not show them.
    2. The deployment, with the Static Web Apps CLI and the site's deployment token. The token is read from Azure
       when the step runs (the deploy identity may; the stack's deny settings keep everyone else from listing it),
       reaches the CLI through an environment variable, and is never stored, printed or passed as an argument.
    3. The proof: the site serves the topology this step wrote.

    The topology is a picture of system.json at the time of the deployment. After a change to the environments, a
    standby region or a Front Door endpoint, deploy the dashboard's release again in every environment that has it:
    until then its page shows the old picture. An environment that is in system.json but not applied yet shows its
    nodes as unreachable.
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
    # The dashboard's topology from system.json (parsed, as a hashtable) and the host name of each Front Door endpoint
    # by endpoint name (<slug>-<env>-<deployable>). It asks nothing: the same input gives the same topology.
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [hashtable] $EndpointHost = @{},
        [datetime] $Generated = [datetime]::UtcNow
    )
    $slug = [string] $System.system.slug
    $location = [string] $System.system.location
    $apps = @($System.deployables | Where-Object { $_['hosting'] -eq 'appservice' })
    $environments = @(foreach ($environment in @($System.environments)) {
            $environmentName = [string] $environment.name
            $standbyLocation = [string] $environment['standbyLocation']
            $hasFrontDoor = @($environment['capabilities']) -contains 'frontdoor'
            $deployables = @(foreach ($app in $apps) {
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
                })
            [ordered] @{ name = $environmentName; tier = [string] $environment['tier']; deployables = $deployables }
        })
    return [ordered] @{
        system       = [ordered] @{ slug = $slug; name = [string] $System.system['name'] }
        generated    = $Generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        environments = $environments
    }
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
$file = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/contents/system.json?ref=main" -Headers $headers
$system = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', ''))) | ConvertFrom-Json -AsHashtable

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

$topology = ConvertTo-Topology -System $system -EndpointHost $endpointHosts
$nodeCount = 0
$addressCount = 0
foreach ($environment in $topology.environments) {
    foreach ($deployable in $environment.deployables) {
        $nodeCount += @($deployable.nodes).Count
        if ($deployable.frontDoor) {
            $addressCount++
        }
        elseif ($withFrontDoor -contains $environment.name) {
            Write-Host "No Front Door endpoint $slug-$($environment.name)-$($deployable.name) in $($frontDoor['profile']) yet: the dashboard shows $($deployable.name) in $($environment.name) without a public address until it is deployed again."
        }
    }
}
($topology | ConvertTo-Json -Depth 10) + "`n" | Set-Content -LiteralPath (Join-Path $folder 'topology.json') -Encoding utf8NoBOM -NoNewline
$summary = "$(@($topology.environments).Count) environment(s), $nodeCount node(s), $addressCount public address(es)"
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
