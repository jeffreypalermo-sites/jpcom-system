#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the app's acceptance tests against the deployed environment, then reloads its test data.

.DESCRIPTION
    Step "Acceptance tests" of the Octopus project <slug>-<deployable>, in the environments whose system.json entry has
    "acceptanceTests": true (the first environment: the first time a version runs on its real Azure resources);
    octopus/projects.tf inlines this file. It runs in the Playwright image (Chromium and pwsh included) on the
    release's acceptance-test package:
      1. .NET 10 SDK into a temporary folder (the image carries .NET 8).
      2. The suite in remote mode (no local server, no Worker: those tests skip themselves) against the app's URL,
         with the database connection from "Open test database": every test, or only the tests of the deployable's
         acceptanceTestsFilter in system.json (AcceptanceTests.Filter, a dotnet test filter such as
         TestCategory=Smoke; the app's pull requests run the full suite). The suite starts by loading its own data
         (ZDataLoader). Parallel test workers: AcceptanceTests.Workers, or 0 for 1.5 per core, capped by memory
         (0.5 GB per browser) and at 16; a worker starts a browser only for a test, so a small set needs no other
         sizing. The run reports how many tests actually ran at once.
      3. Always, even after failures: ZDataLoader once more, so the environment is left with good test data.
    The test results (TRX) are attached to the deployment as artifacts. A failed test fails the deployment, which
    keeps the release from being promoted; the version stays pinned, because it is what runs. A run in which no test
    ran fails too: a filter that matches nothing, or tests that all skip themselves, prove nothing.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$package = [string] $OctopusParameters['Octopus.Action.Package[tests].ExtractedPath']
$testAssembly = Join-Path $package ([string] $OctopusParameters['AcceptanceTests.Assembly'])
$loaderAssembly = Join-Path $package ([string] $OctopusParameters['DataLoader.Assembly'])
$baseUrl = [string] $OctopusParameters['Octopus.Action[Open test database].Output.ApplicationBaseUrl']
$connectionString = [string] $OctopusParameters['Octopus.Action[Open test database].Output.SqlConnectionString']
$requestedWorkers = [int] $OctopusParameters['AcceptanceTests.Workers']
$filter = ([string] $OctopusParameters['AcceptanceTests.Filter']).Trim()
$selection = if ($filter) { @('--filter', $filter) } else { @() }
$scope = if ($filter) { "filter $filter" } else { 'full suite' }
$results = Join-Path (Get-Location) 'results'
New-Item -ItemType Directory -Path $results -Force | Out-Null

$clock = [Diagnostics.Stopwatch]::StartNew()
$dotnetRoot = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10'
$installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.sh'
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.sh' -OutFile $installer
bash $installer --channel 10.0 --install-dir $dotnetRoot --no-path | Out-Null
$env:DOTNET_ROOT = $dotnetRoot
$env:PATH = "${dotnetRoot}:$env:PATH"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
Write-Host ".NET $(dotnet --version) SDK in $([int] $clock.Elapsed.TotalSeconds) s"

$testsExit = 1
$loadExit = 1
$executed = 0
try {
    # Zip extraction drops the execute bit of Playwright's Node driver.
    Get-ChildItem -LiteralPath (Join-Path $package '.playwright') -Recurse -File -Force -Filter 'node' | ForEach-Object { chmod +x $_.FullName }
    $revision = ((Get-Content -LiteralPath (Join-Path $package '.playwright' 'package' 'browsers.json') -Raw | ConvertFrom-Json).browsers |
            Where-Object { $_.name -eq 'chromium' }).revision
    if (-not (Test-Path -LiteralPath (Join-Path ([string] $env:PLAYWRIGHT_BROWSERS_PATH) "chromium-$revision"))) {
        Write-Warning "The image has no Chromium $revision (the suite's Playwright version changed): installing it."
        pwsh -NoProfile -File (Join-Path $package 'playwright.ps1') install chromium
    }

    $cores = [Environment]::ProcessorCount
    $memoryGb = ([long] ((Get-Content -LiteralPath '/proc/meminfo' | Select-String -Pattern '^MemTotal:\s+(\d+)').Matches[0].Groups[1].Value)) / 1MB
    $automatic = [Math]::Max(2, [Math]::Min(16, [Math]::Min([Math]::Floor($cores * 1.5), [Math]::Floor(($memoryGb - 1) / 0.5))))
    $workers = if ($requestedWorkers -gt 0) { $requestedWorkers } else { [int] $automatic }
    Write-Highlight "Acceptance tests ($scope): $workers parallel workers ($cores cores, $([Math]::Round($memoryGb, 1)) GB) against $baseUrl"

    $env:ApplicationBaseUrl = $baseUrl
    $env:ConnectionStrings__SqlConnectionString = $connectionString
    $env:StartLocalServer = 'false'
    $env:StartWorker = 'false'
    $env:HeadlessTestBrowser = 'true'
    $env:SkipScreenshotsForSpeed = 'true'
    $env:TEST_INPUT_DELAY_MS = [string] $OctopusParameters['AcceptanceTests.InputDelayMs']

    function Get-TrxSummary {
        # Counts and the parallelism the run reached: the sum of test durations over the wall time of the tests.
        # A run without tests has no Results element, which strict mode would not let the dotted path read.
        param([Parameter(Mandatory)] [string] $Path)
        [xml] $trx = Get-Content -LiteralPath $Path -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $tests = @($trx.TestRun.SelectNodes("*[local-name()='Results']/*[local-name()='UnitTestResult']"))
        $parallelism = 0
        if ($tests.Count -gt 0) {
            $busy = ($tests | ForEach-Object { [TimeSpan]::Parse($_.duration).TotalSeconds } | Measure-Object -Sum).Sum
            $wall = (([datetimeoffset[]] @($tests.endTime) | Measure-Object -Maximum).Maximum - ([datetimeoffset[]] @($tests.startTime) | Measure-Object -Minimum).Minimum).TotalSeconds
            if ($wall -gt 0) { $parallelism = [Math]::Round($busy / $wall, 2) }
        }
        return [pscustomobject] @{
            Executed = [int] $counters.executed
            Text     = "$($counters.passed) passed, $($counters.failed) failed, $([int] $counters.total - [int] $counters.executed) not run; effective parallelism $parallelism"
        }
    }

    $clock.Restart()
    $PSNativeCommandUseErrorActionPreference = $false
    dotnet test $testAssembly @selection --settings (Join-Path $package 'AcceptanceTests.runsettings') `
        --logger 'trx;LogFileName=acceptance.trx' --logger 'console;verbosity=minimal' --results-directory $results `
        -- "NUnit.NumberOfTestWorkers=$workers"
    $testsExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $acceptanceTrx = Join-Path $results 'acceptance.trx'
    if (Test-Path -LiteralPath $acceptanceTrx) {
        $summary = Get-TrxSummary -Path $acceptanceTrx
        $executed = $summary.Executed
        Write-Highlight "Acceptance tests in $([int] $clock.Elapsed.TotalSeconds) s: $($summary.Text)"
        New-OctopusArtifact -Path $acceptanceTrx -Name "acceptance-tests-$($OctopusParameters['Octopus.Environment.Name'])-$($OctopusParameters['Octopus.Release.Number']).trx"
    }
}
finally {
    $clock.Restart()
    $PSNativeCommandUseErrorActionPreference = $false
    dotnet test $loaderAssembly --filter 'FullyQualifiedName~ZDataLoader' `
        --logger 'trx;LogFileName=load-data.trx' --logger 'console;verbosity=minimal' --results-directory $results
    $loadExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "Test data reloaded (ZDataLoader) in $([int] $clock.Elapsed.TotalSeconds) s, exit code $loadExit"
}

if ($loadExit -ne 0) {
    Fail-Step 'ZDataLoader could not reload the test data (above).'
}
if ($testsExit -ne 0) {
    Fail-Step "Acceptance tests failed against $baseUrl (results attached as an artifact); the test data was reloaded."
}
if ($executed -eq 0) {
    Fail-Step "No acceptance test ran against $baseUrl ($scope): none matched, or every one skipped itself, and a run that tests nothing must not pass; the test data was reloaded."
}
Write-Highlight "Acceptance tests passed; the test data was reloaded."
