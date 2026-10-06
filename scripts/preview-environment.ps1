#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Previews what applying infra/ would change in each environment (what-if), for pull requests and drift checks.

.DESCRIPTION
    Runs in job preview of .github/workflows/env-checks.yml (the pull request's own files) and in
    .github/workflows/drift.yml (main), signed in as id-<slug>-plan (Reader). Writes a Markdown table per environment
    to the job summary. With -FailOnChange it exits 1 when any environment differs from main: that is drift.

    Versions come from the working tree's environments/<env>/versions.json. The SQL password parameter gets a
    stand-in: what-if never shows secure values, and vault secrets are left out of the drift decision for the same
    reason. An environment whose resource group does not exist yet is reported, not failed.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Environment = @(),
    [switch] $FailOnChange,
    # Where the Markdown report goes; the job summary by default.
    [string] $SummaryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$template = Join-Path $Root 'infra' 'main.bicep'
$summary = if ($SummaryPath) { $SummaryPath } elseif ($env:GITHUB_STEP_SUMMARY) { $env:GITHUB_STEP_SUMMARY } else { Join-Path ([IO.Path]::GetTempPath()) 'preview-summary.md' }
# What-if reports properties Azure fills in itself as Delete, expressions it cannot evaluate before deployment
# (reference(), the outputs of other modules) as Modify, and write-only properties as Create. None of them is drift.
$writeOnlyPaths = @('properties.Flow_Type', 'properties.Request_Source')
function Get-PropertyChange {
    param($Delta, [string] $Prefix = '')
    foreach ($item in @($Delta)) {
        if (-not $item) { continue }
        $path = if ($Prefix) { "$Prefix.$($item.path)" } else { [string] $item.path }
        if ($item.children) {
            Get-PropertyChange -Delta $item.children -Prefix $path
            continue
        }
        if ($item.propertyChangeType -in @('Delete', 'NoEffect')) { continue }
        if ($writeOnlyPaths -contains $path) { continue }
        $after = ($item.after | ConvertTo-Json -Depth 20 -Compress)
        if ($after -match '\[[a-zA-Z]+\(') { continue }
        $path
    }
}
$drifted = [Collections.Generic.List[string]]::new()
$unchecked = [Collections.Generic.List[string]]::new()

foreach ($entry in $system.environments) {
    $name = [string] $entry.name
    if ($Environment.Count -gt 0 -and $Environment -notcontains $name) {
        continue
    }
    $resourceGroup = [string] $system.azure.resourceGroups[[string] $entry.tier]
    $versionsFile = Join-Path $Root 'environments' $name 'versions.json'
    $versions = if (Test-Path -LiteralPath $versionsFile) { Get-Content -LiteralPath $versionsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }

    # Secrets of the container deployables of this environment (deployables[].secrets), by vault name
    # <deployable>-<secret>: the preview shows the desired state, so every operator-supplied secret counts as present
    # (an app that does not reference one yet differs from Git), and a generated one gets a throwaway value.
    $presentSecrets = [Collections.Generic.List[string]]::new()
    $generatedSecrets = @{}
    foreach ($deployable in @($system.deployables | Where-Object { -not $_.ContainsKey('environments') -or @($_.environments) -contains $name })) {
        if ($deployable.ContainsKey('hosting') -and $deployable.hosting -ne 'containerapp') { continue }
        foreach ($secret in @($deployable['secrets'] | Where-Object { $_ })) {
            if ($secret['generate'] -eq $true) { $generatedSecrets["$($deployable.name)-$($secret.name)"] = "Preview-$([Guid]::NewGuid().ToString('N'))" }
            else { $presentSecrets.Add("$($deployable.name)-$($secret.name)") }
        }
    }

    $parameters = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            environmentName   = @{ value = $name }
            versions          = @{ value = $versions }
            sqlAdminPassword  = @{ value = "Preview-$([Guid]::NewGuid().ToString('N'))" }
            deployPrincipalId = @{ value = [string] $system.azure.identities.deploy[[string] $entry.tier].principalId }
            presentSecrets    = @{ value = @($presentSecrets) }
            generatedSecrets  = @{ value = $generatedSecrets }
        }
    }
    $parametersFile = Join-Path ([IO.Path]::GetTempPath()) "preview-$name-$([Guid]::NewGuid().ToString('N')).json"
    $parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parametersFile -Encoding utf8NoBOM

    try {
        $PSNativeCommandUseErrorActionPreference = $false
        # ProviderNoRbac: full validation, but only read permissions are checked, so id-<slug>-plan (Reader and the
        # what-if role) can preview without any write right; the default level checks write on every resource.
        $raw = az deployment group what-if --resource-group $resourceGroup --template-file $template `
            --parameters "@$parametersFile" --validation-level ProviderNoRbac `
            --result-format FullResourcePayloads --no-pretty-print --output json 2>&1
        $ok = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
    }
    finally {
        Remove-Item -LiteralPath $parametersFile -Force -ErrorAction SilentlyContinue
    }

    Add-Content -LiteralPath $summary -Value "### $name ($resourceGroup)`n"
    if (-not $ok) {
        $message = (@($raw) | ForEach-Object { "$_" }) -join "`n"
        Add-Content -LiteralPath $summary -Value "What-if could not run:`n`n``````text`n$message`n```````n"
        Write-Host "SKIP preview ${name}: what-if could not run"
        Write-Host (($message -split "`n" | Where-Object { $_ -match 'ERROR|Code|Message' } | Select-Object -First 5) -join "`n")
        $unchecked.Add($name)
        continue
    }

    $result = (@($raw) -join "`n") | ConvertFrom-Json -AsHashtable
    $changes = @($result.changes | Where-Object { $_.changeType -notin @('NoChange', 'Ignore') } | ForEach-Object {
            $properties = @(if ($_.changeType -eq 'Modify') { Get-PropertyChange -Delta $_.delta })
            if ($_.changeType -ne 'Modify' -or $properties.Count -gt 0) {
                @{ changeType = $_.changeType; resourceId = $_.resourceId; properties = $properties }
            }
        })
    $relevant = $changes
    if ($changes.Count -eq 0) {
        Add-Content -LiteralPath $summary -Value "No change.`n"
    }
    else {
        $rows = foreach ($change in $changes) {
            $resource = ($change.resourceId -split '/providers/')[-1]
            $properties = @($change.properties | ForEach-Object { '`' + $_ + '`' }) -join ', '
            "| $($change.changeType) | ``$resource`` | $properties |"
        }
        Add-Content -LiteralPath $summary -Value ((@('| Change | Resource | Properties |', '|---|---|---|') + $rows + '') -join "`n")
    }
    if ($relevant.Count -gt 0) {
        $drifted.Add($name)
    }
    Write-Host "PASS preview $name ($($changes.Count) change(s))"
}

if ($FailOnChange -and $drifted.Count -gt 0) {
    Write-Host "FAIL drift: $($drifted -join ', ') differ from main"
    exit 1
}
# A drift check that could not look is not green; a pull request preview never blocks.
if ($FailOnChange -and $unchecked.Count -gt 0) {
    Write-Host "FAIL drift: what-if could not run for $($unchecked -join ', ')"
    exit 1
}
exit 0
