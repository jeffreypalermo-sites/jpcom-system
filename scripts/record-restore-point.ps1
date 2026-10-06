#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Records the database restore point of a production release before the release changes anything.

.DESCRIPTION
    Step "Record restore point" of the Octopus project <slug>-<deployable>, in the prod-tier environments, before "Pin
    version"; octopus/projects.tf inlines this file. Azure SQL keeps automatic backups for point-in-time restore. The
    step fails when the database has no backup to restore from yet, and otherwise records this moment as the restore
    point: in the task log, with the command that restores to it, and as output variable RestorePoint. It creates no
    copy, so it adds no cost; restoring creates a new database next to the current one.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$release = "$($OctopusParameters['Octopus.Project.Name']) $($OctopusParameters['Octopus.Release.Number'])"

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$database = [string] $outputs.databaseName.value
$db = az sql db show --resource-group $resourceGroup --server $server --name $database --output json | ConvertFrom-Json -AsHashtable
if (-not $db.earliestRestoreDate) {
    Fail-Step "$database has no automatic backup to restore from yet; deploy again once Azure SQL has taken its first backup."
}
$point = [datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-OctopusVariable -name 'RestorePoint' -value $point
Write-Highlight "Restore point before ${release}: $point (backups available since $($db.earliestRestoreDate))."
Write-Host "To return the data to it: az sql db restore --resource-group $resourceGroup --server $server --name $database --dest-name $database-before-$($OctopusParameters['Octopus.Release.Number']) --time $point"
