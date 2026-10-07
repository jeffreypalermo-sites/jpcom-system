#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the application's own deploy.ps1 or verify.ps1 for one environment.

.DESCRIPTION
    Steps "Update deployable", "Verify deployable" and "Revert deployable" of an Octopus project <slug>-<deployable>
    whose deployable brings its own runtime (system.json hosting "own", principle 007); octopus/projects.tf inlines
    this file for all three. The system's infra/ creates nothing for such a deployable: what it runs on, and how a
    version gets there, is the application's.

    "Revert deployable" runs only after a failed step: deploy.ps1 again, with the version the environment ran before
    ("Pin version" recorded it), so that what runs is what versions.json names once "Revert pin" has put it back
    (principle 002). The first deployment to an environment has no version before it: there is nothing to go back to,
    and the step says so.

    The contract. The package reference "app" is <slug>-<deployable>.<version>.zip from the Octopus built-in feed,
    which the application's release workflow made from the content of its deploy/ folder. At its root:
      deploy.ps1   makes the environment run the version (its own infrastructure code, its own way of updating)
      verify.ps1   exits 0 when the environment runs that version and answers
    Each is started with pwsh, signed in to Azure as the tier's deploy identity (the Azure CLI of this step), with
      -Environment <name>   the environment (tdd, uat, prod, ...)
      -Version <number>     the release
      -Context <file>       a JSON file with what the system knows: system, deployable, environment, version,
                            resourceGroup (the tier's, which the identity owns), registryServer, deployPrincipalId
                            (for deny settings of the application's own stack) and systemRepository; for verify.ps1
                            also nodesFile (below)
    Exit code 0 is success; anything else fails the step, and "Revert pin" puts the previous version back.
    What the scripts write to standard output is the step's log. Standard error is logged by Octopus as an error,
    and a deployment with error lines is a broken window: a quiet script writes none.

    The nodes of the application (step "Verify deployable" only). Only the application knows what it runs on, so it
    may report it: the context of verify.ps1 names nodesFile, the absolute path of a file that does not exist yet.
    When verify.ps1 exits 0 and has written that file, it holds one JSON object with the field names of a deployable
    in the dashboard's topology (the dashboard repository's README):
      nodes         required: a list of at least one node, each { "url": an absolute http or https address, each
                    once; optional "name", "region" and "role" (primary or standby) }, in the order the dashboard
                    shows them
      frontDoor     optional (or null): the public address in front of the nodes, an absolute http or https address
      healthPath, alivePath, versionPath   optional: paths that start with /
    This step checks the file and commits it to environments/<env>/nodes.json on main of the system repository, as
    { "<deployable>": { ... } } next to the other deployables' entries, keys in order, through the contents API with
    GitHub.Token, the way "Pin version" commits versions.json (scripts/pin-version.ps1: read, compare, write, again
    after a 409). Only the fields above are recorded. A record that is already the same is not committed again (a
    redeployment). A file that breaks a rule fails the step with every problem named, and the deployment goes back
    like any failed verification. No file: the step succeeds, says that the application reported no nodes, and
    leaves the record as it is. The dashboard's deployment (scripts/deploy-staticwebapp.ps1) reads the record; the
    system workflow ignores a push that changes only nodes.json. deploy.ps1 and "Revert deployable" get no nodesFile.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off, also for the
# application's script, which inherits them.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$deployable = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$package = [string] $OctopusParameters['Octopus.Action.Package[app].ExtractedPath']
$step = [string] $OctopusParameters['Octopus.Step.Name']
$verifying = $step -eq 'Verify deployable'
$entry = if ($verifying) { 'verify.ps1' } else { 'deploy.ps1' }
if ($step -eq 'Revert deployable') {
    $previous = [string] $OctopusParameters['Octopus.Action[Pin version].Output.PreviousVersion']
    if ([string] $OctopusParameters['Octopus.Action[Pin version].Output.Pinned'] -ne 'True') {
        Write-Host "$deployable $version was not pinned in ${environmentName}: nothing was deployed, nothing to revert."
        return
    }
    if (-not $previous) {
        Write-Host "$environmentName ran no version of $deployable before ${version}: there is none to go back to."
        return
    }
    Write-Host "Going back to $deployable $previous in $environmentName, with the deploy.ps1 of $version."
    $version = $previous
}

$script = Join-Path $package $entry
if (-not (Test-Path -LiteralPath $script)) {
    Fail-Step "The package $slug-$deployable.$version has no $entry at its root: the application's deploy/ folder holds deploy.ps1 and verify.ps1 (the kit's reference.md, 'An application that brings its own runtime')."
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

function Save-NodeRecord {
    # Commits the record to environments/<env>/nodes.json on main: the loop of scripts/pin-version.ps1 (read,
    # compare, write, again after a 409). A conflict the next attempt gets past is information, not a warning.
    param([Parameter(Mandatory)] [Collections.IDictionary] $Record)
    $repository = [string] $OctopusParameters['System.Repository']
    $deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
    $path = "environments/$environmentName/nodes.json"
    $uri = "https://api.github.com/repos/$repository/contents/$path"
    $headers = @{
        Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $count = @($Record.nodes).Count

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $sha = $null
        $text = '{}'
        try {
            $file = Invoke-RestMethod -Uri "${uri}?ref=main" -Headers $headers
            $sha = $file.sha
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
        }
        catch {
            # 404: the environment has no record yet. (Not every failure has a response: a name that does not resolve.)
            $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
            if (-not ($response -and [int] $response.StatusCode -eq 404)) {
                throw
            }
        }
        $recorded = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
        if ($recorded -isnot [Collections.IDictionary]) {
            Fail-Step "$path on main of $repository is not a JSON object: correct it by pull request, then deploy $deployable $version to $environmentName again."
        }

        $before = if ($recorded.Contains($deployable)) { (ConvertTo-NodeRecord $recorded[$deployable]).Record } else { $null }
        if ($before -and ($before | ConvertTo-Json -Depth 5 -Compress) -ceq ($Record | ConvertTo-Json -Depth 5 -Compress)) {
            Write-Highlight "$path already records these $count node(s) of ${deployable}: nothing to commit."
            return
        }

        $recorded[$deployable] = $Record
        $ordered = [ordered] @{}
        foreach ($key in ($recorded.Keys | Sort-Object)) {
            $ordered[$key] = $recorded[$key]
        }
        $content = ($ordered | ConvertTo-Json -Depth 10) + "`n"
        $body = @{
            message = "Record the nodes of $deployable $version in $environmentName ($deployment)"
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
            branch  = 'main'
        }
        if ($sha) {
            $body.sha = $sha
        }

        try {
            $commit = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body ($body | ConvertTo-Json) -ContentType 'application/json'
            Write-Highlight "Recorded $count node(s) of $deployable in ${environmentName}: $($commit.commit.html_url)"
            return
        }
        catch {
            # 409: another commit changed the file since it was read; read it again.
            $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
            if ($response -and [int] $response.StatusCode -eq 409 -and $attempt -lt 4) {
                Write-Host "nodes.json changed while recording (attempt $attempt of 4); reading it again."
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            throw
        }
    }
}

$unique = "$slug-$deployable-$([Guid]::NewGuid().ToString('N'))"
$contextFile = Join-Path ([IO.Path]::GetTempPath()) "context-$unique.json"
# Only verify.ps1 is asked for the nodes: after it, the environment runs the version it reports them for.
$nodesFile = if ($verifying) { Join-Path ([IO.Path]::GetTempPath()) "nodes-$unique.json" } else { '' }
$context = [ordered] @{
    system            = $slug
    deployable        = $deployable
    environment       = $environmentName
    version           = $version
    resourceGroup     = [string] $OctopusParameters['Azure.ResourceGroup']
    registryServer    = [string] $OctopusParameters['Azure.RegistryServer']
    deployPrincipalId = [string] $OctopusParameters['Azure.DeployPrincipalId']
    systemRepository  = [string] $OctopusParameters['System.Repository']
}
if ($verifying) { $context.nodesFile = $nodesFile }
$context | ConvertTo-Json | Set-Content -LiteralPath $contextFile -Encoding utf8NoBOM

Write-Host "$entry of $deployable $version for $environmentName"
$reported = $null
$PSNativeCommandUseErrorActionPreference = $false
try {
    & pwsh -NoProfile -NonInteractive -File $script -Environment $environmentName -Version $version -Context $contextFile
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0 -and $nodesFile -and (Test-Path -LiteralPath $nodesFile -PathType Leaf)) {
        $reported = [IO.File]::ReadAllText($nodesFile)
    }
}
finally {
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue
    if ($nodesFile) { Remove-Item -LiteralPath $nodesFile -Force -ErrorAction SilentlyContinue }
}
if ($exitCode -ne 0) {
    Fail-Step "$entry of $deployable $version failed in $environmentName (exit code $exitCode); its output is above."
}
if (-not $verifying) {
    return
}

if ($null -eq $reported) {
    Write-Host "$deployable reported no nodes for $environmentName (its verify.ps1 wrote no nodesFile): environments/$environmentName/nodes.json stays as it is, and without an entry there the dashboard leaves $deployable out of $environmentName."
}
else {
    # -NoEnumerate: a file that holds a list of one object must not pass for that object.
    $read = $null
    $isJson = $true
    try { $read = $reported | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $isJson = $false }
    $checked = if ($isJson) { ConvertTo-NodeRecord $read } else { @{ Record = $null; Problems = [string[]] @('the file is not JSON') } }
    if ($checked.Problems.Count -gt 0) {
        Fail-Step "verify.ps1 of $deployable $version passed in $environmentName, but the nodes it reported (nodesFile) cannot be recorded: $($checked.Problems -join '; '). The rules are in the kit's reference.md, 'An application that brings its own runtime'."
    }
    Save-NodeRecord -Record $checked.Record
}
Write-Highlight "$deployable $version runs in $environmentName (its own verify.ps1 says so)."
