#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Restarts the container apps that read secrets of their own from the vault, so they read the current values.

.DESCRIPTION
    Runbook "Restart apps" of the Octopus project <slug>-system (it exists once a deployable declares secrets in
    system.json; octopus/runbooks.tf inlines this file). A container app reads a vault secret when a revision starts:
    after the operator wrote a new value (the kit's set-demo-secret.ps1), the running revision still holds the old
    one. Only the deploy identity may restart a revision (the stack's deny settings), so this runbook does it: the
    latest revision of every container app of the environment that references a secret besides the SQL connection
    string, then a check that each one answers its health path again.
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
$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs

$failed = 0
$restarted = 0
foreach ($deployable in @($outputs.deployables.value | Where-Object { $_['containerApp'] })) {
    $app = [string] $deployable.containerApp
    $current = az containerapp show --name $app --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable
    $own = @($current.properties.configuration['secrets'] | Where-Object { $_ -and $_.name -ne 'sql-connection-string' })
    if ($own.Count -eq 0) {
        Write-Host "$app references no secret of its own: left running"
        continue
    }
    $revision = [string] $current.properties.latestRevisionName
    az rest --method post --url "https://management.azure.com$($current.id)/revisions/$revision/restart?api-version=2024-03-01" --output none
    $restarted++
    $uri = "$(([string] $deployable.url).TrimEnd('/'))$($deployable.healthPath)"
    $deadline = (Get-Date).AddMinutes(10)
    $status = 0
    while ((Get-Date) -lt $deadline) {
        try { $status = [int] (Invoke-WebRequest -Uri $uri -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
        if ($status -eq 200) { break }
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        Write-Highlight "$app restarted ($revision, $($own.Count) secret(s) read again) and healthy"
    }
    else {
        Write-Warning "$app did not answer 200 on $uri within 10 minutes after the restart (last $status)."
        $failed++
    }
}
if ($failed -gt 0) {
    Fail-Step "$failed app(s) of $environmentName are unhealthy after the restart."
}
Write-Highlight "$restarted app(s) of $environmentName restarted; each one answers its health path."
