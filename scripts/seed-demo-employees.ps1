#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Adds the app's demo employees to the environment's database with the seeder of the release's test package.

.DESCRIPTION
    Step "Seed demo employees" of the Octopus project <slug>-<deployable>, right after "Migrate database", for a
    deployable that owns the database and ships an acceptance-test package with a data loader assembly
    (deployables[].acceptanceTestsPackage and dataLoaderAssembly), in every environment without acceptance tests;
    octopus/projects.tf inlines this file. An environment with acceptance tests gets the same employees from
    ZDataLoader, which empties its database first.

    The employees are the app's own list: the step runs one explicit test of the data loader assembly, selected by its
    full name ($seederTest below), with the environment's connection string from the vault. The seeder only inserts
    what is missing (a role by name, an employee by user name, an employee-role link) and never changes or deletes a
    row, so a second run adds nothing. A release whose package has no seeder yet is logged and skipped.

    The worker's address gets a firewall rule for the duration of the step. A paused serverless database resumes only
    on a login attempt, so the step logs in until it answers, for up to five minutes, before the seeder runs. dotnet
    test needs a .NET 10 SDK: the container's when it has one, otherwise one installed into a temporary folder.
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
$package = [string] $OctopusParameters['Octopus.Action.Package[tests].ExtractedPath']
$loaderAssembly = Join-Path $package ([string] $OctopusParameters['DataLoader.Assembly'])
$ruleName = "octopus-seed-$(([string] $OctopusParameters['Octopus.Deployment.Id']) -replace '[^A-Za-z0-9-]', '-')"
# The seeder of the bootcamp app (src/IntegrationTests/DemoData/DemoEmployeeSeeder.cs): an [Explicit] test, so it runs
# only when selected by this name, and outside the namespace whose SetUpFixture starts the test host.
$seederTest = 'ClearMeasure.Bootcamp.DemoData.DemoEmployeeSeeder.SeedDemoEmployees'

if (-not (Test-Path -LiteralPath $loaderAssembly)) {
    Fail-Step "The acceptance-test package has no $([IO.Path]::GetFileName($loaderAssembly)) ($package)."
}

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$database = [string] $outputs.databaseName.value
$vault = [string] $outputs.keyVaultName.value

function Wait-Database {
    # Logs in with the environment's connection string ($connectionString, read from the vault below); repeats while a
    # paused database resumes, for up to five minutes.
    $deadline = (Get-Date).AddMinutes(5)
    for ($attempt = 1; ; $attempt++) {
        $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
        try {
            $connection.Open()
            return
        }
        catch {
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            if ((Get-Date) -gt $deadline) {
                Fail-Step "Database $database did not accept a login within 5 minutes: $reason"
            }
            Write-Host "Waiting for database $database to resume (attempt $attempt)."
            Start-Sleep -Seconds 15
        }
        finally {
            $connection.Dispose()
        }
    }
}

function Get-DotnetSdk {
    # The container's dotnet when it has a .NET 10 SDK, otherwise one installed into a temporary folder.
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command -and (@(& $command.Source --list-sdks) -match '^10\.')) {
        return $command.Source
    }
    $installDir = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10-sdk'
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Channel 10.0 -InstallDir $installDir -NoPath
    $env:DOTNET_ROOT = $installDir
    $env:PATH = "${installDir}:$env:PATH"
    Write-Host "Installed the .NET 10 SDK into $installDir"
    return (Join-Path $installDir 'dotnet')
}

$workerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
Write-Host "Opening $server to the worker ($workerIp) as rule $ruleName"
az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
    --start-ip-address $workerIp --end-ip-address $workerIp --output none
try {
    $connectionString = ([string] (az keyvault secret show --vault-name $vault --name sql-connection-string --query value --output tsv)).Trim()
    Wait-Database

    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $dotnet = Get-DotnetSdk
    $results = Join-Path ([IO.Path]::GetTempPath()) "seed-$([Guid]::NewGuid().ToString('N'))"
    $env:ConnectionStrings__SqlConnectionString = $connectionString
    $PSNativeCommandUseErrorActionPreference = $false
    & $dotnet test $loaderAssembly --filter "FullyQualifiedName=$seederTest" `
        --logger 'trx;LogFileName=seed.trx' --logger 'console;verbosity=minimal' --results-directory $results
    $exitCode = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -Path Env:ConnectionStrings__SqlConnectionString

    $trxFile = Join-Path $results 'seed.trx'
    if (-not (Test-Path -LiteralPath $trxFile)) {
        Fail-Step "dotnet test wrote no results for $seederTest (exit code $exitCode, output above)."
    }
    [xml] $trx = Get-Content -LiteralPath $trxFile -Raw
    $counters = $trx.TestRun.ResultSummary.Counters
    if ([int] $counters.total -eq 0) {
        Write-Host "The release's test package has no $seederTest (built before the seeder): no demo employees to add to $environmentName."
        return
    }
    if ($exitCode -ne 0 -or [int] $counters.total -ne 1 -or [int] $counters.passed -ne 1) {
        Fail-Step "The demo-employee seeder failed in $environmentName (exit code $exitCode, $($counters.passed) of $($counters.total) passed; output above). It saves in one transaction, so it added nothing."
    }
    $output = $trx.SelectSingleNode("//*[local-name()='UnitTestResult']/*[local-name()='Output']/*[local-name()='StdOut']")
    $summary = if ($output) { $output.InnerText.Trim() } else { 'Demo employees: the seeder passed and printed no counts.' }
    Write-Highlight ($summary -replace '^Demo employees:', "Demo employees in ${environmentName}:")
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
    $PSNativeCommandUseErrorActionPreference = $true
}
