#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Turns off Octopus's cancelling of "superseded" tasks for every project and runbook of the system.

.DESCRIPTION
    Step "Keep queued tasks" of the system workflow, after "Apply octopus/". Octopus cancels a queued (and optionally a
    running) task when a newer task of the same queue arrives ("Superseded by ServerTasks-..."). The system runs one task
    per environment at a time across both projects and the runbooks (Octopus.Task.ConcurrencyTag = the environment), so
    for Octopus a deployment of the app supersedes a queued system release, or a restore test: an environment would
    silently miss its apply (it happened to cmdemo1-system 1.0.55 in tdd). The setting is per project
    (deployment settings) and per runbook (CancelQueuedTasks, CancelRunningTasks); the Terraform provider does not
    manage it, so this step sets it after every apply. Signs in with the access token of OctopusDeploy/login.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$system = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'system.json') -Raw | ConvertFrom-Json
$url = [string] $system.octopus.url
$space = [string] $system.octopus.spaceId
$headers = @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" }
$slugs = @("$($system.system.slug)-system") + @($system.deployables | ForEach-Object { "$($system.system.slug)-$($_.name)" })

function Set-Kept {
    # PUTs the resource back with both cancel switches off, when either is on (or present and unset).
    param([Parameter(Mandatory)] [string] $Uri, [Parameter(Mandatory)] [string] $Label)
    $resource = Invoke-RestMethod -Uri $Uri -Headers $headers
    $names = @($resource.PSObject.Properties.Name)
    if ($names -notcontains 'CancelQueuedTasks') {
        Write-Host "${Label}: this Octopus version has no task cancellation setting"
        return
    }
    if (-not $resource.CancelQueuedTasks -and -not $resource.CancelRunningTasks) {
        Write-Host "${Label}: queued and running tasks are kept"
        return
    }
    $resource.CancelQueuedTasks = $false
    if ($names -contains 'CancelRunningTasks') { $resource.CancelRunningTasks = $false }
    $null = Invoke-RestMethod -Uri $Uri -Method Put -Headers $headers -Body ($resource | ConvertTo-Json -Depth 20) -ContentType 'application/json'
    Write-Host "${Label}: superseded tasks are no longer cancelled"
}

foreach ($slug in $slugs) {
    $project = Invoke-RestMethod -Uri "$url/api/$space/projects/$slug" -Headers $headers
    Set-Kept -Uri "$url/api/$space/projects/$($project.Id)/deploymentsettings" -Label "$slug deployments"
    foreach ($runbook in @((Invoke-RestMethod -Uri "$url/api/$space/projects/$($project.Id)/runbooks?take=100" -Headers $headers).Items)) {
        Set-Kept -Uri "$url/api/$space/runbooks/$($runbook.Id)" -Label "$slug runbook $($runbook.Name)"
    }
}
