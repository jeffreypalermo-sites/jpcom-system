#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Restarts the container apps that read secrets of their own from the vault, and waits until each one answers its
    health path, for as long as Container Apps may take to read a changed secret.

.DESCRIPTION
    Runbook "Restart apps" of the Octopus project <slug>-system (it exists once a deployable declares secrets in
    system.json; octopus/runbooks.tf inlines this file), for after the operator wrote a new value to the vault (the
    kit's set-demo-secret.ps1).

    What brings a changed value to an app is Container Apps, not this runbook. A secret of a container app is a Key
    Vault reference: Container Apps reads a new version of the vault's secret within 30 minutes, and then restarts the
    revisions that use it in an environment variable, by itself (Microsoft, "Manage secrets in Azure Container Apps",
    "Key Vault secret URI and secret rotation": https://learn.microsoft.com/azure/container-apps/manage-secrets).
    Microsoft documents no way to ask for that sooner, and restarting the revision is not one: a restarted revision
    starts with the value Container Apps read last (cmdemo1, 2026-10-07: the vault written at 05:19:36 UTC, the
    revision restarted at 05:34 and still failing on the old value, healthy at 05:50).

    So the runbook does what it can and says what it saw. For every container app of the environment that references
    a secret besides the SQL connection string:
      1. it restarts the latest revision (only the deploy identity may: the stack's deny settings), so the app starts
         again with the values Container Apps holds at that moment;
      2. it reads from the vault when the app's secrets last changed (names and times, never a value);
      3. it asks the app's health path until it answers 200: for 10 minutes, or until 10 minutes after the 30 minutes
         Container Apps may take, counted from the last change.
    An app that answers 200 before those 30 minutes are over may still run with the earlier value: the runbook says
    so, and until when. An app that does not answer in time fails the run.

    The health path is the one system.json declares (variable System.HealthPaths) once the app runs a release. The
    stack's output is not asked for it: that names "/" for a deployable that had no version at the environment's last
    apply, and "/" answers 200 while the app's own health check fails (the same day on cmdemo1: this runbook said
    "restarted and healthy" about an app whose /health answered 503).
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

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$registry = [string] $OctopusParameters['Azure.RegistryServer']
# { "<deployable>": "<health path>" } from system.json; a runbook snapshot older than the variable has none.
$declaredPaths = @{}
if ([string] $OctopusParameters['System.HealthPaths']) { $declaredPaths = [string] $OctopusParameters['System.HealthPaths'] | ConvertFrom-Json -AsHashtable }
# Container Apps reads a new version of a Key Vault secret "within 30 minutes" (the page named above); an app gets
# another 10 to start and answer.
$refreshMinutes = 30
$startMinutes = 10
$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs

# When each secret of the vault last changed. A list returns names and times, never a value; the times are read as
# text (ConvertFrom-Json would turn them into dates of the worker's time zone).
$vault = [string] $outputs.keyVaultName.value
$changedAt = @{}
foreach ($line in @(az keyvault secret list --vault-name $vault --query '[].[id, attributes.updated]' --output tsv)) {
    $id, $updated = "$line" -split "`t"
    if ($id -and $updated) {
        $changedAt[$id.TrimEnd('/')] = [DateTimeOffset]::Parse($updated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    }
}

$waiting = [Collections.Generic.List[hashtable]]::new()
foreach ($deployable in @($outputs.deployables.value | Where-Object { $_['containerApp'] })) {
    $app = [string] $deployable.containerApp
    $current = az containerapp show --name $app --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable
    $own = @($current.properties.configuration['secrets'] | Where-Object { $_ -and $_.name -ne 'sql-connection-string' })
    if ($own.Count -eq 0) {
        Write-Host "$app references no secret of its own: left running"
        continue
    }
    # The declared health path once a release runs (an image of the system's registry); the placeholder answers "/".
    $image = [string] @($current.properties.template.containers)[0].image
    $released = $registry -and $image.StartsWith("$registry/", [StringComparison]::OrdinalIgnoreCase)
    $path = if ($released -and $declaredPaths.ContainsKey([string] $deployable.name)) { [string] $declaredPaths[[string] $deployable.name] } else { [string] $deployable.healthPath }
    $changes = @($own | ForEach-Object { $changedAt[([string] $_['keyVaultUrl']).TrimEnd('/')] } | Where-Object { $_ } | Sort-Object)
    $revision = [string] $current.properties.latestRevisionName
    az rest --method post --url "https://management.azure.com$($current.id)/revisions/$revision/restart?api-version=2024-03-01" --output none
    Write-Host "$app restarted ($revision): it starts again with the values Container Apps holds now"
    $waiting.Add(@{
            App      = $app
            Revision = $revision
            Secrets  = $own.Count
            Uri      = "$(([string] $deployable.url).TrimEnd('/'))$path"
            # None when the vault lists none of the secrets the app references.
            Changed  = if ($changes.Count -gt 0) { $changes[-1] } else { $null }
        })
}

$failed = 0
$unproven = [Collections.Generic.List[string]]::new()
foreach ($entry in $waiting) {
    $app = [string] $entry.App
    $uri = [string] $entry.Uri
    # By when Container Apps has read the last change, by its documentation.
    $readBy = if ($entry.Changed) { ([DateTimeOffset] $entry.Changed).AddMinutes($refreshMinutes) } else { [DateTimeOffset]::MinValue }
    $now = [DateTimeOffset]::UtcNow
    $deadline = $(if ($readBy -gt $now) { $readBy } else { $now }).AddMinutes($startMinutes)
    $changedText = if ($entry.Changed) { "$(([DateTimeOffset] $entry.Changed).ToString('yyyy-MM-dd HH:mm:ss')) UTC" } else { '' }
    if ($readBy -gt $now) {
        Write-Host "A secret of $app changed in the vault at $changedText. Container Apps reads a changed Key Vault secret within $refreshMinutes minutes (by $($readBy.ToString('HH:mm')) UTC) and then restarts the revision itself; nothing makes it sooner. Asking $uri until $($deadline.ToString('HH:mm')) UTC."
    }
    $status = 0
    $said = -1
    $saidAt = [DateTimeOffset]::MinValue
    while ($true) {
        try { $status = [int] (Invoke-WebRequest -Uri $uri -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
        if ($status -eq 200 -or [DateTimeOffset]::UtcNow -ge $deadline) { break }
        # One line when the answer changes and one every five minutes: the wait can take most of an hour.
        if ($status -ne $said -or [DateTimeOffset]::UtcNow -ge $saidAt.AddMinutes(5)) {
            Write-Host "$([DateTimeOffset]::UtcNow.ToString('HH:mm:ss')) UTC $uri answers $status; asking until $($deadline.ToString('HH:mm')) UTC"
            $said = $status
            $saidAt = [DateTimeOffset]::UtcNow
        }
        Start-Sleep -Seconds 15
    }
    if ($status -ne 200) {
        $reason = if ($entry.Changed) { "Its secrets last changed in the vault at $changedText, so Container Apps has had its $refreshMinutes minutes to read them: a value in the vault is not one the app accepts, or the app fails for another reason." } else { 'The vault lists none of the secrets it references.' }
        Write-Warning "$app does not answer 200 on $uri (last $status, asked until $($deadline.ToString('HH:mm')) UTC). $reason"
        $failed++
    }
    elseif ($readBy -gt [DateTimeOffset]::UtcNow) {
        Write-Highlight "$app restarted ($($entry.Revision)) and answers 200 on $uri. That does not show the value written at $changedText yet: Container Apps reads it by $($readBy.ToString('HH:mm')) UTC at the latest and restarts the revision itself then."
        $unproven.Add("$app until $($readBy.ToString('HH:mm')) UTC")
    }
    else {
        Write-Highlight "$app restarted ($($entry.Revision)) and answers 200 on $uri$(if ($entry.Changed) { "; its $($entry.Secrets) secret(s) last changed in the vault at $changedText, more than $refreshMinutes minutes ago" })"
    }
}
if ($failed -gt 0) {
    Fail-Step "$failed app(s) of $environmentName do not answer their health path after the restart."
}
if ($unproven.Count -gt 0) {
    Write-Highlight "$($waiting.Count) app(s) of $environmentName restarted; each one answers its health path. Possibly still with the earlier value of a secret: $($unproven -join ', '). Ask its health path again after that time."
}
else {
    Write-Highlight "$($waiting.Count) app(s) of $environmentName restarted; each one answers its health path, and none of their secrets changed in the vault in the last $refreshMinutes minutes."
}
