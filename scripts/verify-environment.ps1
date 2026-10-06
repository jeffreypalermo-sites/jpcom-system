#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Verifies the deployables of one environment answer over HTTPS.

.DESCRIPTION
    Last step of every Octopus project of the system ("Verify environment" in <slug>-system, "Verify deployable" in
    <slug>-<deployable>); octopus/projects.tf inlines this file. Reads the stack outputs of stack-<slug>-<env> and
    polls each deployable's URL (its health path once a version runs, / for a placeholder) until it answers 200.
    Deployable.Name limits the check to one deployable. The deadline covers a scale-from-zero start and a SQL
    database resuming from auto-pause; a revision that cannot start (crash loop, image pull failure, failed
    provisioning) fails the step at once, with the container's last console lines. A static site (hosting
    "staticwebapp") has no revision and no plan to ask: only its URL is polled.
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
$only = [string] $OctopusParameters['Deployable.Name']
$deadlineMinutes = 10

$stack = az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable
$deployables = @($stack.outputs.deployables.value | Where-Object { -not $only -or $_.name -eq $only })
# The same apps in the standby region (environments[].standbyLocation) are verified like the primary ones.
if ($stack.outputs.ContainsKey('standby')) {
    $deployables += @($stack.outputs.standby.value | Where-Object { -not $only -or $_.name -eq $only })
}
if ($deployables.Count -eq 0) {
    Fail-Step "Stack stack-$slug-$environmentName lists no deployable$(if ($only) { " named $only" })."
}

# A deployable project verifies right after its update step, before the stack is applied again: the health path of
# the running version applies even when the stack output still describes the placeholder.
$healthPath = [string] $OctopusParameters['Deployable.HealthPath']

# Container Apps reports a revision that cannot start long before its URL times out: read the latest revision and its
# replicas, and give the reason with the container's last console lines (the deploy identity may read them; the
# stack's deny settings keep everyone else from streaming logs).
function Get-RevisionProblem {
    # Through the ARM REST API, so it does not depend on the Azure CLI version of the worker image.
    param([Parameter(Mandatory)] [string] $App)
    $api = 'api-version=2024-03-01'
    $PSNativeCommandUseErrorActionPreference = $false
    $subscription = ([string] (az account show --query id --output tsv 2>$null)).Trim()
    $appId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/containerApps/$App"
    $appJson = az rest --method get --url "https://management.azure.com${appId}?$api" --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $PSNativeCommandUseErrorActionPreference = $true
        Write-Warning "Could not read ${App}: $appJson"
        return $null
    }
    $latest = [string] ($appJson | ConvertFrom-Json -AsHashtable).properties.latestRevisionName
    $revisionJson = az rest --method get --url "https://management.azure.com$appId/revisions/${latest}?$api" --output json 2>$null
    $replicasJson = az rest --method get --url "https://management.azure.com$appId/revisions/$latest/replicas?$api" --output json 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
    $revision = if ($revisionJson) { $revisionJson | ConvertFrom-Json -AsHashtable } else { $null }
    $replicas = if ($replicasJson) { @(($replicasJson | ConvertFrom-Json -AsHashtable).value) } else { @() }
    if ($revision -and ($revision.properties.provisioningState -eq 'Failed' -or $revision.properties.runningState -eq 'Failed')) {
        return "revision $latest is $($revision.properties.provisioningState)/$($revision.properties.runningState)"
    }
    foreach ($replica in $replicas) {
        foreach ($container in @($replica.properties.containers)) {
            $detail = [string] $container.runningStateDetails
            if ($detail -match 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError' -or [int] $container.restartCount -ge 3) {
                return "revision ${latest}: container $($container.name) is $($container.runningState) ($detail) after $($container.restartCount) restart(s)"
            }
        }
    }
    return $null
}

# An App Service site on a Free plan that exhausted a quota answers 403 until the quota resets (hourly or daily): say
# so at once instead of waiting out the deadline. A crash-looping app on the tier's shared plan is the usual cause.
function Get-SiteProblem {
    param([Parameter(Mandatory)] [string] $WebApp)
    $PSNativeCommandUseErrorActionPreference = $false
    $siteId = ([string] (az resource show --resource-group $resourceGroup --name $WebApp --resource-type Microsoft.Web/sites --query id --output tsv 2>$null)).Trim()
    $siteJson = if ($siteId) { az rest --method get --url "https://management.azure.com${siteId}?api-version=2024-04-01" --output json 2>$null } else { $null }
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $siteJson) { return $null }
    $site = ($siteJson | ConvertFrom-Json -AsHashtable).properties
    if ($site.usageState -eq 'Exceeded') {
        return "site $WebApp is $($site.state): its Free plan exhausted a quota; an app crash-looping on the same plan is the usual cause"
    }
    return $null
}

function Write-RevisionLog {
    param([Parameter(Mandatory)] [string] $App)
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = az containerapp logs show --name $App --resource-group $resourceGroup --type console --tail 40 --format text 2>&1
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "Last console lines of ${App}:"
    @($lines) | ForEach-Object { Write-Host "  $_" }
}

$failed = 0
foreach ($deployable in $deployables) {
    # Only a container app has one: empty for App Service and for a static site.
    $app = [string] $deployable['containerApp']
    $path = if ($only -and $healthPath) { $healthPath } else { [string] $deployable.healthPath }
    $uri = "$($deployable.url.TrimEnd('/'))$path"
    $deadline = (Get-Date).AddMinutes($deadlineMinutes)
    $status = 0
    while ((Get-Date) -lt $deadline) {
        try {
            $status = [int] (Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode
        }
        catch {
            $status = 0
        }
        if ($status -eq 200) {
            break
        }
        # What the platform says about an app that does not answer: the site for App Service, the revision for a
        # container app. A static site (hosting "staticwebapp") has neither: its URL is all there is to ask.
        $problem = switch ([string] $deployable['hosting']) {
            'appservice' { Get-SiteProblem -WebApp ([string] $deployable.webApp) }
            'staticwebapp' { $null }
            default { Get-RevisionProblem -App $app }
        }
        if ($problem) {
            Write-Warning "FAIL $($deployable.name) in ${environmentName}: $problem"
            if ($app) { Write-RevisionLog -App $app }
            $status = -1
            break
        }
        Write-Host "$uri answered $status; retrying"
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        Write-Highlight "PASS $($deployable.name) in ${environmentName}$(if ($deployable['role'] -eq 'standby') { " (standby, $($deployable.region))" }): $uri"
    }
    elseif ($status -eq -1) {
        $failed++
    }
    else {
        Write-Warning "FAIL $($deployable.name) in ${environmentName}: $uri did not answer 200 within $deadlineMinutes minutes (last $status)"
        if ($app) { Write-RevisionLog -App $app }
        $failed++
    }
}

# Capability "frontdoor": the environment's public address answers too. The endpoints are in stack-<slug>-<env>-edge
# in the Front Door profile's resource group (variable Azure.EdgeResourceGroup, empty without a profile). A new endpoint
# or route takes Front Door several minutes to reach every edge location, so this waits longer than for an app.
$edgeGroup = [string] $OctopusParameters['Azure.EdgeResourceGroup']
if ($edgeGroup) {
    $PSNativeCommandUseErrorActionPreference = $false
    $edgeJson = az stack group show --name "stack-$slug-$environmentName-edge" --resource-group $edgeGroup --output json 2>$null
    $hasEdge = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    $endpoints = if ($hasEdge) { @(($edgeJson | ConvertFrom-Json -AsHashtable).outputs.endpoints.value | Where-Object { -not $only -or $_.name -eq $only }) } else { @() }
    foreach ($endpoint in $endpoints) {
        $deployable = @($stack.outputs.deployables.value | Where-Object { $_.name -eq $endpoint.name })[0]
        $path = if ($only -and $healthPath) { $healthPath } else { [string] $deployable.healthPath }
        $uri = "$(([string] $endpoint.url).TrimEnd('/'))$path"
        $deadline = (Get-Date).AddMinutes(30)
        $status = 0
        while ((Get-Date) -lt $deadline) {
            try { $status = [int] (Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
            if ($status -eq 200) { break }
            Write-Host "$uri answered $status; retrying"
            Start-Sleep -Seconds 30
        }
        if ($status -eq 200) {
            Write-Highlight "PASS $($endpoint.name) in ${environmentName} behind Front Door: $uri"
        }
        else {
            Write-Warning "FAIL $($endpoint.name) in ${environmentName}: the Front Door endpoint $uri did not answer 200 within 30 minutes (last $status)"
            $failed++
        }
    }
}

if ($failed -gt 0) {
    Fail-Step "$failed deployable(s) of $environmentName did not answer."
}
