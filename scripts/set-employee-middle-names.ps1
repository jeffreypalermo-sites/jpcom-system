#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Sets the employee middle names system.json declares for an environment in that environment's database.

.DESCRIPTION
    Step "Set employee middle names" of the Octopus project <slug>-system, after "Grant database access" and before
    "Verify environment"; octopus/projects.tf inlines this file and adds the step, scoped to those environments, only
    when an environment of system.json has employeeMiddleNames ({ "<user name>": "<middle name>" }). The variable
    Employee.MiddleNames carries that object for the environment as JSON. The step sets dbo.Employee.MiddleName for
    each user name; running it again changes nothing. No declared names, a database without the column (the app
    release that adds it is not deployed there yet) and a user name the database does not have are logged and skipped.

    The worker's address gets a firewall rule for the duration of the step. A paused serverless database resumes only
    on a login attempt, so the step logs in again until it answers, for up to five minutes.
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
$ruleName = "octopus-names-$(([string] $OctopusParameters['Octopus.Task.Id']) -replace '[^A-Za-z0-9-]', '-')"

$declared = [string] $OctopusParameters['Employee.MiddleNames']
$middleNames = if ($declared) { $declared | ConvertFrom-Json -AsHashtable } else { @{} }
if ($middleNames.Count -eq 0) {
    Write-Host "No employee middle names declared for ${environmentName}: nothing to set."
    return
}

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$serverFqdn = [string] $outputs.sqlServerFqdn.value
$database = [string] $outputs.databaseName.value
$adminLogin = [string] $outputs.sqlAdminLogin.value
$vault = [string] $outputs.keyVaultName.value

function Open-Database {
    # Logs in as the administrator ($adminPassword, read from the vault below); repeats while a paused database
    # resumes, for up to five minutes.
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$serverFqdn,1433"
    $builder['Initial Catalog'] = $database
    $builder['User ID'] = $adminLogin
    $builder['Password'] = $adminPassword
    $builder['Encrypt'] = $true
    $builder['Connect Timeout'] = 30
    $deadline = (Get-Date).AddMinutes(5)
    for ($attempt = 1; ; $attempt++) {
        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        try {
            $connection.Open()
            return $connection
        }
        catch {
            $connection.Dispose()
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            if ((Get-Date) -gt $deadline) {
                Fail-Step "Database $database did not accept a login within 5 minutes: $reason"
            }
            Write-Host "Waiting for database $database to resume (attempt $attempt)."
            Start-Sleep -Seconds 15
        }
    }
}

# One statement per employee, the values as parameters. It returns -1 for a user name the database does not have,
# otherwise the rows changed: 0 when the middle name is already the declared one (compared case-sensitively, so a
# change of case is applied too).
$update = @'
IF NOT EXISTS (SELECT 1 FROM dbo.Employee WHERE UserName = @userName)
    SELECT -1;
ELSE
BEGIN
    UPDATE dbo.Employee SET MiddleName = @middleName
    WHERE UserName = @userName AND (MiddleName IS NULL OR MiddleName <> @middleName COLLATE Latin1_General_BIN2);
    SELECT @@ROWCOUNT;
END
'@

$workerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
Write-Host "Opening $server to the worker ($workerIp) as rule $ruleName"
az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
    --start-ip-address $workerIp --end-ip-address $workerIp --output none
try {
    $adminPassword = ([string] (az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv)).Trim()
    $connection = Open-Database
    try {
        $check = $connection.CreateCommand()
        $check.CommandText = "SELECT COL_LENGTH(N'dbo.Employee', N'MiddleName')"
        if ($check.ExecuteScalar() -is [DBNull]) {
            Write-Host "Database $database of $environmentName has no column dbo.Employee.MiddleName yet: nothing to set."
            return
        }
        $set = 0
        foreach ($userName in ($middleNames.Keys | Sort-Object)) {
            $middleName = [string] $middleNames[$userName]
            $command = $connection.CreateCommand()
            $command.CommandText = $update
            $null = $command.Parameters.AddWithValue('@userName', [string] $userName)
            $null = $command.Parameters.AddWithValue('@middleName', $middleName)
            $changed = [int] $command.ExecuteScalar()
            if ($changed -lt 0) {
                Write-Host "Employee $userName is not in database $database of ${environmentName}: skipped."
            }
            elseif ($changed -eq 0) {
                Write-Host "Employee $userName in $environmentName already has middle name $middleName."
            }
            else {
                $set++
                Write-Highlight "Employee $userName in ${environmentName}: middle name set to $middleName."
            }
        }
        if ($set -eq 0) {
            Write-Highlight "Employee middle names in ${environmentName}: nothing to change (already set, or not in the database)."
        }
    }
    finally {
        $connection.Dispose()
    }
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
    $PSNativeCommandUseErrorActionPreference = $true
}
