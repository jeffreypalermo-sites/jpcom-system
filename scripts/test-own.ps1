#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the system's own checks: every infra/own/test-*.ps1 of this repository, once per environment.

.DESCRIPTION
    Capability CAP-090 (the kit's docs/decisions/0034). Job "own" of workflow "capabilities" runs it after the
    capability checks, signed in to Azure as id-<slug>-plan, a reader of the system's groups, and as nothing else.
    infra/own/ is the system's (CAP-089): no template sync changes a script there.

    The scripts run in ordinal order of their names, each once for every environment of system.json in that order,
    from the repository's root, as pwsh -File <script> -Environment <name>. Exit code 0 passes. A run that has not
    ended after -LimitMinutes is stopped with every process it started, and fails. What a script writes goes to the
    log as it comes; after it, one line:
      PASS own: <script> in <environment>
      FAIL own: <script> in <environment> (exit code <n>)
      FAIL own: <script> in <environment> (stopped after <limit> minutes)
    No run starts once -BudgetMinutes have passed since this script started: the job's Azure sign-in lasts about an
    hour, and with the defaults the last run (10 minutes at most) ends before it does. Each script and environment
    not started then fails, with one line and nothing run:
      FAIL own: <script> in <environment> (not run: the job's <budget> minutes are spent)
    The last line counts the runs; the exit code is 1 when one failed. A repository without such a script gets one
    line, SKIP own: no infra/own/test-*.ps1, and exit code 0: what a system adds asks for no check of its own.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-own.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    # The kit's tests pass a shorter one.
    [double] $LimitMinutes = 10,
    # Kept under the job's hour less -LimitMinutes; the kit's tests pass 0 and a large one.
    [double] $BudgetMinutes = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$clock = [Diagnostics.Stopwatch]::StartNew()
# The scripts inherit it: the Azure CLI's progress bar writes to standard error.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

# Absolute: it is the scripts' working directory as well as the start of their paths.
$repository = (Resolve-Path -LiteralPath $Root).ProviderPath
$folder = Join-Path $repository 'infra' 'own'
[string[]] $scripts = @(if (Test-Path -LiteralPath $folder -PathType Container) {
        Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -cmatch '^test-.*\.ps1$' } | ForEach-Object Name
    })
if ($scripts.Count -eq 0) {
    Write-Host 'SKIP own: no infra/own/test-*.ps1'
    exit 0
}
[Array]::Sort($scripts, [StringComparer]::Ordinal)
$system = Get-Content -LiteralPath (Join-Path $repository 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$environments = @($system.environments | ForEach-Object { [string] $_.name })

function Invoke-OwnCheck {
    # One run, whose output goes straight to this log. Returns why it failed, or nothing when it passed.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [double] $Minutes
    )
    $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($item in '-NoProfile', '-NonInteractive', '-File', $Path, '-Environment', $Environment) { $start.ArgumentList.Add($item) }
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $Directory
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit([int] [Math]::Ceiling($Minutes * 60000))) { return "stopped after $Minutes minutes" }
        if ($process.ExitCode -ne 0) { return "exit code $($process.ExitCode)" }
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { Write-Host "The script could not be stopped: $($_.Exception.Message)" }
            $null = $process.WaitForExit(10000)
        }
    }
}

$failed = 0
foreach ($name in $scripts) {
    foreach ($environment in $environments) {
        if ($clock.Elapsed.TotalMinutes -ge $BudgetMinutes) {
            $failed++
            Write-Host "FAIL own: $name in $environment (not run: the job's $BudgetMinutes minutes are spent)"
            continue
        }
        Write-Host "==> own: $name in $environment"
        $reason = Invoke-OwnCheck -Path (Join-Path $folder $name) -Environment $environment -Directory $repository -Minutes $LimitMinutes
        if ($reason) {
            $failed++
            Write-Host "FAIL own: $name in $environment ($reason)"
        }
        else {
            Write-Host "PASS own: $name in $environment"
        }
    }
}
$runs = $scripts.Count * $environments.Count
if ($failed -gt 0) {
    Write-Host "$failed of $runs own check runs failed."
    exit 1
}
Write-Host "All $runs own check runs passed."
# Said as an exit code: a workflow step in GitHub's pwsh shell ends with the exit code of the last program it ran.
exit 0
