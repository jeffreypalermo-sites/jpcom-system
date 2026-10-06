#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Gives every App Service deployable a database login of its own in the environment's database.

.DESCRIPTION
    Step "Grant database access" of the Octopus project <slug>-system, after "Apply environment"; octopus/projects.tf
    inlines this file and adds the step only when system.json has an App Service deployable. Such a deployable gets a
    contained user named after it, with the password the stack keeps in the vault (<name>-sql-password), and read and
    write on the data. One that shares the database gets no schema rights: migrations stay with the deployable that
    owns the database. The owner itself (stack output ownsDatabase, from databasePackage) may also change the schema,
    because the app creates its message queues at startup; Octopus still runs its migrations as the administrator. The
    step creates the user, or sets its password to the vault's, and adds the roles; running it again changes nothing
    else.

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
$ruleName = "octopus-grant-$(([string] $OctopusParameters['Octopus.Task.Id']) -replace '[^A-Za-z0-9-]', '-')"

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$sites = @($outputs.deployables.value | Where-Object { $_['hosting'] -eq 'appservice' })
$logins = @($sites | ForEach-Object { [string] $_.name })
# The deployable that owns the database (system.json databasePackage) creates its message queues at startup
# (NServiceBus installers), so its login may also change the schema; the others read and write only.
$owners = @($sites | Where-Object { $_['ownsDatabase'] } | ForEach-Object { [string] $_.name })
if ($logins.Count -eq 0) {
    Write-Host "No App Service deployable in ${environmentName}: no login to grant."
    return
}
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

# CREATE USER, ALTER USER and ALTER ROLE take no parameters, so each statement is built in a variable with QUOTENAME
# around the name and the password (EXEC (...) accepts no function call) and run with sp_executesql; the values
# themselves arrive as parameters.
$grant = @'
DECLARE @sql nvarchar(max);
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
    SET @sql = N'ALTER USER ' + QUOTENAME(@name) + N' WITH PASSWORD = ' + QUOTENAME(@password, N'''');
ELSE
    SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' WITH PASSWORD = ' + QUOTENAME(@password, N'''');
EXEC sys.sp_executesql @sql;
IF IS_ROLEMEMBER(N'db_datareader', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
END
IF IS_ROLEMEMBER(N'db_datawriter', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
END
IF @owner = 1 AND IS_ROLEMEMBER(N'db_ddladmin', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_ddladmin ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
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
        foreach ($login in $logins) {
            $password = ([string] (az keyvault secret show --vault-name $vault --name "$login-sql-password" --query value --output tsv)).Trim()
            $command = $connection.CreateCommand()
            $command.CommandText = $grant
            $null = $command.Parameters.AddWithValue('@name', $login)
            $null = $command.Parameters.AddWithValue('@password', $password)
            $null = $command.Parameters.AddWithValue('@owner', [int] ($owners -contains $login))
            $null = $command.ExecuteNonQuery()
            $rights = if ($owners -contains $login) { 'read, write and schema changes (it owns the database)' } else { 'read and write, no schema rights' }
            Write-Highlight "Login $login in database $database of ${environmentName}: $rights."
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
