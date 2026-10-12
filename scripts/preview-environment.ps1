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

    The system's own module (infra/own/main.bicep) is previewed a second time, on its own: what-if does not look into
    a module whose parameters are known only at deployment (the identities main.bicep hands it), so the environment's
    what-if says nothing about its resources. It gets the identities as Azure has them now, and a stand-in for one
    that does not exist yet. cmdemo1, 2026-10-10: a pull request that added a storage account there was previewed as
    "0 change(s)" until this.
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

# The Azure CLI checks once a day whether a newer Bicep exists and says so as a warning on the next command that
# reads a template: a warning in the log that is about nothing in it. The version in use is the installed one.
$env:AZURE_BICEP_CHECK_VERSION = 'false'

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
function Get-ResourceChange {
    # The resources a what-if result says would change: not the ones it left alone or could not look at, and not a
    # Modify whose only differences are no change (Get-PropertyChange).
    param($Result)
    @($Result.changes | Where-Object { $_.changeType -notin @('NoChange', 'Ignore') } | ForEach-Object {
            $properties = @(if ($_.changeType -eq 'Modify') { Get-PropertyChange -Delta $_.delta })
            if ($_.changeType -ne 'Modify' -or $properties.Count -gt 0) {
                @{ changeType = $_.changeType; resourceId = $_.resourceId; properties = $properties }
            }
        })
}
function Format-ResourceChange {
    # The Markdown table of changes, or "No change.".
    param([object[]] $Change = @())
    if ($Change.Count -eq 0) { return "No change.`n" }
    $rows = foreach ($one in $Change) {
        $resource = ($one.resourceId -split '/providers/')[-1]
        $properties = @($one.properties | ForEach-Object { '`' + $_ + '`' }) -join ', '
        "| $($one.changeType) | ``$resource`` | $properties |"
    }
    return (@('| Change | Resource | Properties |', '|---|---|---|') + $rows + '') -join "`n"
}
# The system's own module, when it declares anything (the kit's empty one declares nothing and is not asked about).
$ownTemplate = Join-Path $Root 'infra' 'own' 'main.bicep'
$ownDeclares = (Test-Path -LiteralPath $ownTemplate) -and (Get-Content -LiteralPath $ownTemplate -Raw) -match '(?m)^(resource|module) '
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
    $withIdentity = [Collections.Generic.List[string]]::new()
    foreach ($deployable in @($system.deployables | Where-Object { -not $_.ContainsKey('environments') -or @($_.environments) -contains $name })) {
        if ($deployable.ContainsKey('hosting') -and $deployable.hosting -ne 'containerapp') { continue }
        # A container deployable with secrets has an identity of its own, which main.bicep hands to infra/own.
        if (@($deployable['secrets'] | Where-Object { $_ }).Count -gt 0) { $withIdentity.Add([string] $deployable.name) }
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
    $changes = @(Get-ResourceChange -Result $result)
    Add-Content -LiteralPath $summary -Value (Format-ResourceChange -Change $changes)

    # The system's own module, on its own (see the description): with the environment as main.bicep hands it over.
    $ownChanges = @()
    $ownSaid = ''
    if ($ownDeclares) {
        $standIns = [Collections.Generic.List[string]]::new()
        $identities = @(foreach ($deployable in $withIdentity) {
                $identityName = "id-$($system.system.slug)-$name-$deployable"
                $PSNativeCommandUseErrorActionPreference = $false
                $found = az identity show --name $identityName --resource-group $resourceGroup --query '{principalId: principalId, clientId: clientId, resourceId: id}' --output json 2>$null
                $exists = $LASTEXITCODE -eq 0
                $PSNativeCommandUseErrorActionPreference = $true
                if ($exists) { $identity = (@($found) -join "`n") | ConvertFrom-Json -AsHashtable }
                else {
                    # Not created yet (a new deployable, or a new environment): a stand-in, so the rest is previewed.
                    $standIns.Add($identityName)
                    $identity = @{ principalId = '00000000-0000-0000-0000-000000000000'; clientId = '00000000-0000-0000-0000-000000000000'; resourceId = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$resourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$identityName" }
                }
                @{ deployable = $deployable; principalId = [string] $identity.principalId; clientId = [string] $identity.clientId; resourceId = [string] $identity.resourceId }
            })
        $ownParameters = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{
                stack = @{
                    value = @{
                        slug = [string] $system.system.slug; environmentName = $name; location = [string] $system.system.location
                        tags = @{ system = [string] $system.system.slug; environment = $name; tier = [string] $entry.tier; purpose = 'demo' }
                        identities = $identities
                    }
                }
            }
        }
        $ownParametersFile = Join-Path ([IO.Path]::GetTempPath()) "preview-own-$name-$([Guid]::NewGuid().ToString('N')).json"
        $ownParameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownParametersFile -Encoding utf8NoBOM
        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $ownRaw = az deployment group what-if --resource-group $resourceGroup --template-file $ownTemplate `
                --parameters "@$ownParametersFile" --validation-level ProviderNoRbac `
                --result-format FullResourcePayloads --no-pretty-print --output json 2>&1
            $ownOk = $LASTEXITCODE -eq 0
            $PSNativeCommandUseErrorActionPreference = $true
        }
        finally {
            Remove-Item -LiteralPath $ownParametersFile -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $summary -Value "#### $name, what the system adds itself (``infra/own``)`n"
        if (-not $ownOk) {
            $message = (@($ownRaw) | ForEach-Object { "$_" }) -join "`n"
            Add-Content -LiteralPath $summary -Value "What-if of ``infra/own/main.bicep`` could not run, so nothing is known about its resources:`n`n``````text`n$message`n```````n"
            Write-Host "SKIP preview $name, infra/own: what-if could not run"
            Write-Host (($message -split "`n" | Where-Object { $_ -match 'ERROR|Code|Message' } | Select-Object -First 5) -join "`n")
            $unchecked.Add("$name (infra/own)")
            $ownSaid = '; infra/own not previewed'
        }
        else {
            $ownChanges = @(Get-ResourceChange -Result ((@($ownRaw) -join "`n") | ConvertFrom-Json -AsHashtable))
            $note = 'Previewed on its own: the what-if above does not look into this module. Not listed here: a resource the module no longer declares, which is deleted at the next apply with its data; and the settings the module returns to an app, which change that app.'
            if ($standIns.Count -gt 0) { $note += " Not in Azure yet, so a stand-in was used for: $($standIns -join ', ')." }
            Add-Content -LiteralPath $summary -Value ((Format-ResourceChange -Change $ownChanges) + "`n$note`n")
            $ownSaid = "; infra/own $($ownChanges.Count) change(s)"
        }
    }
    if (($changes.Count + $ownChanges.Count) -gt 0) {
        $drifted.Add($name)
    }
    Write-Host "PASS preview $name ($($changes.Count) change(s)$ownSaid)"
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
