#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the app's DbUp migrations against the environment's database.

.DESCRIPTION
    Step "Migrate database" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. The
    package reference "database" is the app's database package (ChurchBulletin.Database for the bootcamp app), at the
    release's version. Names come from the stack outputs of stack-<slug>-<env>, the password from the environment's
    vault. The worker's address gets a firewall rule for the duration of the step, as the bootcamp's own Octopus
    process does. The .NET 10 runtime is installed into a temporary folder when the container lacks it.

    The databases are serverless with auto-pause. A paused database resumes only on a login attempt (reading its
    status with az sql db show does not wake it), and the migration tool fails while it resumes. So the step first
    logs in itself, and repeats that until a query succeeds, for up to five minutes. The waiting lines are plain
    information: a resume is normal, not a warning.

    Known limit: the bootcamp's database tool takes the password as a positional argument (DatabaseOptions), so it is
    visible to processes of the single-use worker container while the tool runs. The capability "secretless" removes
    it by switching the database to Microsoft Entra authentication.
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
$assemblyName = [string] $OctopusParameters['Database.Assembly']
$package = [string] $OctopusParameters['Octopus.Action.Package[database].ExtractedPath']
$ruleName = "octopus-$(([string] $OctopusParameters['Octopus.Deployment.Id']) -replace '[^A-Za-z0-9-]', '-')"

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$serverFqdn = [string] $outputs.sqlServerFqdn.value
$database = [string] $outputs.databaseName.value
$login = [string] $outputs.sqlAdminLogin.value
$vault = [string] $outputs.keyVaultName.value

# The package also carries build intermediates (obj/, ref/) that cannot run: take a copy with its runtimeconfig.json,
# Release before Debug.
$assembly = Get-ChildItem -Path $package -Filter $assemblyName -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/]obj[\\/]' -and (Test-Path -LiteralPath (Join-Path $_.DirectoryName "$($_.BaseName).runtimeconfig.json")) } |
    Sort-Object { if ($_.FullName -match '[\\/]Release[\\/]') { 0 } else { 1 } }, { $_.FullName.Length } |
    Select-Object -First 1
if (-not $assembly) {
    Fail-Step "$assemblyName is not in the database package ($package)."
}
$scripts = Join-Path $package 'scripts'
if (-not (Test-Path -LiteralPath $scripts)) {
    Fail-Step "The database package has no scripts folder ($scripts)."
}

# .NET 10 runtime: the execution container may carry an older one.
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { $null }
$hasRuntime = $dotnet -and (@(& $dotnet --list-runtimes) -match '^Microsoft\.NETCore\.App 10\.')
if (-not $hasRuntime) {
    $installDir = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10'
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Channel 10.0 -Runtime dotnet -InstallDir $installDir -NoPath
    $dotnet = Join-Path $installDir 'dotnet'
    Write-Host "Installed the .NET 10 runtime into $installDir"
}

$workerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
Write-Host "Opening $server to the worker ($workerIp) as rule $ruleName"
az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
    --start-ip-address $workerIp --end-ip-address $workerIp --output none

try {
    $password = ([string] (az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv)).Trim()
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$serverFqdn,1433"
    $builder['Initial Catalog'] = $database
    $builder['User ID'] = $login
    $builder['Password'] = $password
    $builder['Encrypt'] = $true
    $builder['Connect Timeout'] = 30
    $deadline = (Get-Date).AddMinutes(5)
    $attempt = 0
    while ($true) {
        $attempt++
        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        $reason = $null
        try {
            $connection.Open()
            $command = $connection.CreateCommand()
            $command.CommandText = 'SELECT 1'
            $null = $command.ExecuteScalar()
        }
        catch {
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        }
        finally {
            $connection.Dispose()
        }
        if (-not $reason) { break }
        if ((Get-Date) -gt $deadline) {
            Fail-Step "Database $database did not accept a login within 5 minutes: $reason"
        }
        $status = [string] (az sql db show --resource-group $resourceGroup --server $server --name $database --query status --output tsv)
        Write-Host "Waiting for database $database to resume (status $status, attempt $attempt)."
        Start-Sleep -Seconds 15
    }
    Write-Host "Database $database is online$(if ($attempt -gt 1) { " after $attempt login attempts" })."

    Write-Host "Migrating $database on $serverFqdn with $($assembly.Name)"
    & $dotnet $assembly.FullName update $serverFqdn $database $scripts $login $password
    if ($LASTEXITCODE -ne 0) {
        Fail-Step "The database migration failed (exit code $LASTEXITCODE)."
    }
    Write-Highlight "Database $database of $environmentName is migrated."
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
    $PSNativeCommandUseErrorActionPreference = $true
}
