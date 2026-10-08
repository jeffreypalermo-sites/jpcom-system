#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Measures a failover: stops the environment's primary app and times how long its public address takes to answer
    from the standby region, then starts the primary again and times the way back.

.DESCRIPTION
    Runbook "Failover test" of the Octopus project <slug>-system (octopus/runbooks.tf inlines this file; it exists
    when an environment has a standbyLocation, and is scheduled monthly in the nonprod ones). Capability CAP-047.
    The environment's Front Door endpoint has the primary app at priority 1 and the standby at priority 2 and probes
    both. The runbook asks the endpoint for /_healthcheck/detailed every 3 seconds; that answer carries the start time
    of the process that served it, which tells the two apps apart. It stops the primary web app, waits until three
    answers in a row come from the standby, and reports the seconds that took and the requests that failed meanwhile.
    Then it starts the primary (always, also after a failure) and waits until the endpoint is served by it again.
    Without an endpoint (capability frontdoor off, or the Front Door dormant) or without a standby there is nothing to
    measure, and the runbook says so and ends. The database is one for both regions: this is the web tier's failover.
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
$edgeGroup = [string] $OctopusParameters['Azure.EdgeResourceGroup']
$limitMinutes = 10

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$standbySites = @(if ($outputs.ContainsKey('standby')) { $outputs.standby.value })
$standby = $standbySites | Select-Object -First 1
if (-not $standby) {
    Write-Highlight "No standby region in ${environmentName}: nothing to fail over."
    return
}
$primary = $outputs.deployables.value | Where-Object { $_.name -eq $standby.name } | Select-Object -First 1
$endpoint = $null
if ($edgeGroup) {
    $PSNativeCommandUseErrorActionPreference = $false
    $edgeJson = az stack group show --name "stack-$slug-$environmentName-edge" --resource-group $edgeGroup --output json 2>$null
    $hasEdge = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    # Select-Object, not [0]: under strict mode an index into an empty list throws instead of leaving $null.
    if ($hasEdge) { $endpoint = ($edgeJson | ConvertFrom-Json -AsHashtable).outputs.endpoints.value | Where-Object { $_.name -eq $standby.name } | Select-Object -First 1 }
}
if (-not $endpoint) {
    Write-Highlight "No Front Door endpoint for $($standby.name) in $environmentName (capability frontdoor off, or the Front Door dormant): nothing to fail over."
    return
}

function Get-Answer {
    # One request for the detailed health report: the HTTP status and, when the app answered, its process start time.
    param([Parameter(Mandatory)] [string] $Url)
    try {
        $response = Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))/_healthcheck/detailed" -Method Get -TimeoutSec 10 -SkipHttpErrorCheck `
            -Headers @{ 'Cache-Control' = 'no-cache' } -DisableKeepAlive
        $started = ''
        if ([int] $response.StatusCode -eq 200) {
            try { $started = [string] ($response.Content | ConvertFrom-Json -AsHashtable)['processStartUtc'] } catch { $started = '' }
        }
        return @{ Status = [int] $response.StatusCode; Started = $started }
    }
    catch {
        return @{ Status = 0; Started = '' }
    }
}

function Wait-Answer {
    # Polls $Url every 3 seconds until $Accept says yes three times in a row; returns the seconds until the first of
    # those answers and the requests that were not 200 before it, or $null after $limitMinutes.
    param([Parameter(Mandatory)] [string] $Url, [Parameter(Mandatory)] [scriptblock] $Accept)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $failed = 0
    $total = 0
    $streak = 0
    $firstAt = 0.0
    $failedAtFirst = 0
    $totalAtFirst = 0
    while ($clock.Elapsed.TotalMinutes -lt $limitMinutes) {
        $answer = Get-Answer -Url $Url
        $total++
        if (& $Accept $answer) {
            if ($streak -eq 0) { $firstAt = $clock.Elapsed.TotalSeconds; $failedAtFirst = $failed; $totalAtFirst = $total - 1 }
            $streak++
            if ($streak -ge 3) { return @{ Seconds = [Math]::Round($firstAt); Failed = $failedAtFirst; Requests = $totalAtFirst } }
        }
        else {
            $streak = 0
            if ($answer.Status -ne 200) { $failed++ }
        }
        Start-Sleep -Seconds 3
    }
    return $null
}

$name = [string] $primary.name
$primaryApp = [string] $primary.webApp
$publicUrl = [string] $endpoint.url
# Both apps are asked directly first. The stack's outputs do not tell whether the app is deployed (they describe the
# last apply, and an app release comes after it), so the app's own answer decides.
$primaryStarted = (Get-Answer -Url ([string] $primary.url)).Started
$standbyStarted = (Get-Answer -Url ([string] $standby.url)).Started
if (-not $primaryStarted -or -not $standbyStarted) {
    Fail-Step "$name does not answer /_healthcheck/detailed in both regions of $environmentName (primary: $(if ($primaryStarted) { 'yes' } else { 'no' }), standby: $(if ($standbyStarted) { 'yes' } else { 'no' })): the test tells the regions apart by that answer, and a failover without a healthy standby would be an outage. Deploy the app first. Nothing was stopped."
}
Write-Host "Baseline: waiting for $publicUrl to be served by the primary ($primaryApp)."
$baseline = Wait-Answer -Url $publicUrl -Accept { param($a) $a.Status -eq 200 -and $a.Started -and $a.Started -ne $standbyStarted }
if (-not $baseline) {
    Fail-Step "$publicUrl is not served by the primary of $name in $environmentName within $limitMinutes minutes. Nothing was stopped."
}

$over = $null
$back = $null
try {
    Write-Host "Stopping $primaryApp ($($primary.region))."
    az webapp stop --resource-group $resourceGroup --name $primaryApp --output none
    $over = Wait-Answer -Url $publicUrl -Accept { param($a) $a.Status -eq 200 -and $a.Started -eq $standbyStarted }
}
finally {
    Write-Host "Starting $primaryApp again."
    az webapp start --resource-group $resourceGroup --name $primaryApp --output none
}
if ($over) {
    Write-Highlight "Failover of $name in ${environmentName}: $publicUrl answered from the standby ($($standby.region)) $($over.Seconds) s after $primaryApp stopped; $($over.Failed) of $($over.Requests) requests failed meanwhile."
}
# The way back: the restarted primary has a new process, so "not the standby" is the primary.
$back = Wait-Answer -Url $publicUrl -Accept { param($a) $a.Status -eq 200 -and $a.Started -and $a.Started -ne $standbyStarted }
if ($back) {
    Write-Highlight "Failback of $name in ${environmentName}: served by the primary ($($primary.region)) again $($back.Seconds) s after it was started; $($back.Failed) of $($back.Requests) requests failed meanwhile."
}
if (-not $over) {
    Fail-Step "$publicUrl was not served by the standby within $limitMinutes minutes after $primaryApp stopped: no failover. The primary is started again."
}
if (-not $back) {
    Fail-Step "$publicUrl was not served by the primary again within $limitMinutes minutes after $primaryApp was started. Check $($primary.url)."
}
