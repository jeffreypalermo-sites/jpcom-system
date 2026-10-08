#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Commits the release's version of one deployable to environments/<env>/versions.json on main.

.DESCRIPTION
    Step "Pin version" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. This is the
    GitOps write: desired state changes first, then the steps after it make the environment match. The commit goes
    straight to main through the contents API with GitHub.Token, whose account the main ruleset lets bypass pull
    requests; the system workflow ignores pushes that change only versions.json, so a pin never starts an
    environment release. A pin that is already in place is not committed again (a redeployment).
    Output variables Pinned and PreviousVersion let step "Revert pin" put the previous version back when a later step
    fails, so main never keeps a version that did not deploy.
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
$path = "environments/$environmentName/versions.json"
$uri = "https://api.github.com/repos/$repository/contents/$path"
# GitHub.Token is scoped to the steps that read it (octopus/variables.tf, token_steps): a step that is not among them
# reads it empty, and says so here instead of being refused by GitHub.
if (-not [string] $OctopusParameters['GitHub.Token']) {
    Fail-Step "GitHub.Token did not reach step '$([string] $OctopusParameters['Octopus.Step.Name'])': octopus/variables.tf hands it only to the steps of local.token_steps. A release made before a step was replaced has that step under its old id and gets no token there: make a new release."
}
$headers = @{
    Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

for ($attempt = 1; $attempt -le 4; $attempt++) {
    $sha = $null
    $versions = @{}
    try {
        $file = Invoke-RestMethod -Uri "${uri}?ref=main" -Headers $headers
        $sha = $file.sha
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
        $versions = $text | ConvertFrom-Json -AsHashtable
    }
    catch {
        if (-not ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 404)) {
            throw
        }
    }

    if ($versions.ContainsKey($deployable) -and [string] $versions[$deployable] -eq $version) {
        Set-OctopusVariable -name 'Pinned' -value 'False'
        Write-Highlight "$path already pins $deployable ${version}: nothing to commit."
        return
    }
    $previous = if ($versions.ContainsKey($deployable)) { [string] $versions[$deployable] } else { '' }

    $versions[$deployable] = $version
    $ordered = [ordered] @{}
    foreach ($key in ($versions.Keys | Sort-Object)) {
        $ordered[$key] = $versions[$key]
    }
    $content = ($ordered | ConvertTo-Json -Depth 5) + "`n"
    $body = @{
        message = "Pin $deployable $version in $environmentName ($deployment)"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        branch  = 'main'
    }
    if ($sha) {
        $body.sha = $sha
    }

    try {
        $commit = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body ($body | ConvertTo-Json) -ContentType 'application/json'
        Set-OctopusVariable -name 'Pinned' -value 'True'
        Set-OctopusVariable -name 'PreviousVersion' -value $previous
        Write-Highlight "Pinned $deployable $version in ${environmentName}: $($commit.commit.html_url)"
        return
    }
    catch {
        # 409: another pin changed the file since it was read; read it again.
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 409 -and $attempt -lt 4) {
            Write-Warning "versions.json changed while pinning (attempt $attempt of 4); reading it again."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        throw
    }
}
