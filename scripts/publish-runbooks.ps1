#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Publishes a snapshot of every runbook of <slug>-system, so their schedules run the process just applied.

.DESCRIPTION
    Step "Publish runbooks" of the system workflow, after "Apply octopus/". Octopus runs a scheduled runbook from its
    published snapshot, which Terraform does not create. Signs in with the access token of OctopusDeploy/login
    (OCTOPUS_ACCESS_TOKEN). The snapshot name is the workflow run, so a re-run publishes again.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$system = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'system.json') -Raw | ConvertFrom-Json
$url = [string] $system.octopus.url
$space = [string] $system.octopus.spaceId
$headers = @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" }
$project = Invoke-RestMethod -Uri "$url/api/$space/projects/$($system.system.slug)-system" -Headers $headers
$runbooks = (Invoke-RestMethod -Uri "$url/api/$space/projects/$($project.Id)/runbooks?take=100" -Headers $headers).Items
foreach ($runbook in $runbooks) {
    # Snapshot names are unique per project, so the runbook's name is part of it.
    $body = @{ ProjectId = $project.Id; RunbookId = $runbook.Id; Name = "$($runbook.Name) $Name"; Notes = "Published by the system workflow ($Name)" } | ConvertTo-Json
    $snapshot = Invoke-RestMethod -Uri "$url/api/$space/runbookSnapshots?publish=true" -Method Post -Headers $headers -Body $body -ContentType 'application/json'
    Write-Host "Published $($runbook.Name): snapshot $($snapshot.Name)"
}
