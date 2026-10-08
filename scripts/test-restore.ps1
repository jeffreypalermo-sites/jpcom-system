#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves that the environment's database can be restored: a point-in-time restore into a temporary database, checked,
    then deleted.

.DESCRIPTION
    Runbook "Restore test" of the Octopus project <slug>-system (scheduled weekly in the first environment;
    octopus/runbooks.tf inlines this file). Capability CAP-060. It restores the database to 15 minutes ago as
    <database>-restoretest-<time> (serverless, 1 vCore, local backup redundancy: a few cents for the minutes it
    exists), opens the server to the worker, checks that the copy has the same user tables as the source and data in
    them, and always deletes the copy and the firewall rule. The copy is created with the tags of the source database
    (system, environment, tier, purpose: infra/main.bicep), so that its cost counts for this environment and not for
    what the environments share (scripts/write-cost.ps1 goes by the tag "environment").
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
$server = [string] $outputs.sqlServerName.value
$serverFqdn = [string] $outputs.sqlServerFqdn.value
$database = [string] $outputs.databaseName.value
$login = [string] $outputs.sqlAdminLogin.value
$vault = [string] $outputs.keyVaultName.value

$clock = [Diagnostics.Stopwatch]::StartNew()
$source = az sql db show --resource-group $resourceGroup --server $server --name $database --output json | ConvertFrom-Json -AsHashtable
$point = [datetimeoffset]::UtcNow.AddMinutes(-15)
if (-not $source.earliestRestoreDate -or [datetimeoffset] $source.earliestRestoreDate -gt $point) {
    Fail-Step "$database has no backup older than 15 minutes yet (earliest restore point: $($source.earliestRestoreDate))."
}
$copy = "$database-restoretest-$($point.ToString('yyyyMMddHHmm'))"
# The source's tags for the copy, as the restore command takes them (key=value each); none when the source has none.
$tagArguments = @()
if ($source['tags'] -and $source.tags.Count -gt 0) {
    $tagArguments = @('--tags') + @($source.tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
}
$ruleName = "octopus-restoretest-$(([string] $OctopusParameters['Octopus.Task.Id']) -replace '[^A-Za-z0-9-]', '-')"

Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
Import-Module SqlServer
function Get-Shape {
    param([string] $Name, [pscredential] $Credential)
    $query = "SELECT (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS UserTables, " +
        "(SELECT COALESCE(SUM(p.rows), 0) FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id " +
        "WHERE t.is_ms_shipped = 0 AND p.index_id IN (0, 1)) AS TotalRows"
    # A paused serverless database resumes only on a login attempt and refuses logins while it resumes ("is not
    # currently available"): log in again until it answers, for up to five minutes, logging the waits as information.
    $deadline = (Get-Date).AddMinutes(5)
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-Sqlcmd -ServerInstance $serverFqdn -Database $Name -Credential $Credential -Query $query `
                -Encrypt Mandatory -ConnectionTimeout 120 -QueryTimeout 120
        }
        catch {
            if ((Get-Date) -gt $deadline) { throw }
            Write-Host "Waiting for database $Name to resume (attempt $attempt)."
            Start-Sleep -Seconds 15
        }
    }
}

try {
    Write-Host "Restoring $database to $($point.ToString('u')) as $copy"
    az sql db restore --resource-group $resourceGroup --server $server --name $database --dest-name $copy `
        --time $point.ToString('yyyy-MM-ddTHH:mm:ssZ') --edition GeneralPurpose --family Gen5 --capacity 1 --compute-model Serverless `
        --auto-pause-delay 60 --min-capacity 0.5 --backup-storage-redundancy Local @tagArguments --output none
    Write-Host "Restored in $([int] $clock.Elapsed.TotalMinutes) minutes"

    $workerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
    az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
        --start-ip-address $workerIp --end-ip-address $workerIp --output none
    $secret = ([string] (az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv)).Trim()
    $credential = [pscredential]::new($login, [Net.NetworkCredential]::new('', $secret).SecurePassword)
    $secret = $null
    $original = Get-Shape -Name $database -Credential $credential
    $restored = Get-Shape -Name $copy -Credential $credential
    Write-Host "Source: $($original.UserTables) user tables, $($original.TotalRows) rows; copy: $($restored.UserTables) user tables, $($restored.TotalRows) rows"
    if ($restored.UserTables -ne $original.UserTables -or $restored.TotalRows -le 0) {
        Fail-Step "The restored copy $copy does not match: $($restored.UserTables) tables and $($restored.TotalRows) rows against $($original.UserTables) tables in $database."
    }
    Write-Highlight "Restore test passed in $environmentName`: $database restored to $($point.ToString('u')) in $([int] $clock.Elapsed.TotalMinutes) minutes ($($restored.UserTables) tables, $($restored.TotalRows) rows)."
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    az sql db show --resource-group $resourceGroup --server $server --name $copy --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        az sql db delete --resource-group $resourceGroup --server $server --name $copy --yes --output none
        Write-Host "Deleted $copy"
    }
    az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
}
