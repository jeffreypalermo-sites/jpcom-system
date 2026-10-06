#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Puts the previous version back into environments/<env>/versions.json when a deployment fails after its pin.

.DESCRIPTION
    Step "Revert pin" of the Octopus project <slug>-<deployable>, which runs only when an earlier step failed;
    octopus/projects.tf inlines this file. "Pin version" commits the new version first (desired state first) and
    records what it replaced (output variables Pinned and PreviousVersion). When Migrate, Update or Verify then fails,
    this step restores the previous version, so main keeps describing what runs and the next apply of the stack does
    not roll out a version that never deployed. It changes nothing when the pin did not commit, or when versions.json
    no longer pins this release (a later deployment already moved it).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$repository = [string] $OctopusParameters['System.Repository']
$deployable = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
$pinned = [string] $OctopusParameters['Octopus.Action[Pin version].Output.Pinned']
$previous = [string] $OctopusParameters['Octopus.Action[Pin version].Output.PreviousVersion']
if ($pinned -ne 'True') {
    Write-Highlight "This deployment did not commit a pin; versions.json stays as it is."
    return
}

$path = "environments/$environmentName/versions.json"
$uri = "https://api.github.com/repos/$repository/contents/$path"
$headers = @{
    Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

for ($attempt = 1; $attempt -le 4; $attempt++) {
    $file = Invoke-RestMethod -Uri "${uri}?ref=main" -Headers $headers
    $versions = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', ''))) | ConvertFrom-Json -AsHashtable
    if (-not $versions.ContainsKey($deployable) -or [string] $versions[$deployable] -ne $version) {
        Write-Highlight "$path no longer pins $deployable ${version}; nothing to revert."
        return
    }
    if ($previous) {
        $versions[$deployable] = $previous
    }
    else {
        $versions.Remove($deployable)
    }
    $ordered = [ordered] @{}
    foreach ($key in ($versions.Keys | Sort-Object)) {
        $ordered[$key] = $versions[$key]
    }
    $content = ($ordered | ConvertTo-Json -Depth 5) + "`n"
    $body = @{
        message = "Revert pin of $deployable $version in $environmentName ($deployment failed)"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        branch  = 'main'
        sha     = $file.sha
    }
    try {
        $commit = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body ($body | ConvertTo-Json) -ContentType 'application/json'
        Write-Highlight "Reverted $deployable in $environmentName to $(if ($previous) { $previous } else { 'no version' }): $($commit.commit.html_url)"
        return
    }
    catch {
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 409 -and $attempt -lt 4) {
            Write-Warning "versions.json changed while reverting (attempt $attempt of 4); reading it again."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        throw
    }
}
