#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Deploys the release's zip to the deployable's App Service web app.

.DESCRIPTION
    Step "Update deployable" of an Octopus project <slug>-<deployable> whose deployable is hosted on App Service
    (system.json hosting "appservice"); octopus/projects.tf inlines this file. The package reference "app" is the zip
    the app's release workflow pushed to the Octopus built-in feed (<slug>-<deployable>.<version>.zip, the published
    app). The web app is the one the stack created (stack output deployables[].webApp); the deploy identity is excluded
    from the stack's deny settings, so it may deploy to it. "Verify deployable" then waits for the health path. With
    a standby region, the same zip goes to the standby's web app first, then to the primary's.
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
$name = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$package = [string] $OctopusParameters['Octopus.Action.Package[app].PackageFilePath']

if (-not $package -or -not (Test-Path -LiteralPath $package)) {
    Fail-Step "The release has no app package for $name ($package)."
}
$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$entry = @($outputs.deployables.value | Where-Object { $_.name -eq $name -and $_['hosting'] -eq 'appservice' }) | Select-Object -First 1
if (-not $entry) {
    Fail-Step "Stack stack-$slug-$environmentName has no App Service deployable named ${name}: deploy the latest $slug-system release to $environmentName first."
}
# An environment with a standbyLocation runs the app in two regions (stack output "standby"): the standby is deployed
# first, while the primary serves, then the primary, while Front Door can send the traffic to the standby.
# @() around the if: an if statement hands a one-element array on as the element itself.
$standby = @(if ($outputs.ContainsKey('standby')) { $outputs.standby.value | Where-Object { $_.name -eq $name } })

function Publish-Site {
    param([Parameter(Mandatory)] [hashtable] $Site)
    $webApp = [string] $Site.webApp

    # The stack sets the startup command only once a version is pinned (an empty site with one would crash-loop), so
    # the first deployment sets it here, after the zip: set before, the still empty site restarts into a start that
    # fails, and the deployment below then reports "the site failed to start within 10 mins" although the app starts
    # a minute later (cmdemo2's first release).
    $startup = [string] $Site.startupCommand
    $current = ([string] (az webapp config show --resource-group $resourceGroup --name $webApp --query appCommandLine --output tsv)).Trim()

    Write-Host "Deploying $name $version ($([Math]::Round((Get-Item -LiteralPath $package).Length / 1MB)) MB) to $webApp"
    # az webapp deploy reports its progress as WARNING lines, which Octopus would log as warnings: errors only. A failed
    # deployment still fails the command.
    $PSNativeCommandUseErrorActionPreference = $false
    az webapp deploy --resource-group $resourceGroup --name $webApp --src-path $package --type zip --async false `
        --restart true --only-show-errors --output none
    $deployed = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $deployed) {
        # An app that fails at startup restarts until the Free plan's quotas stop the site ("QuotaExceeded"), which also
        # closes its logs until the quota resets: say so, and where the usual cause is.
        $siteId = ([string] (az resource show --resource-group $resourceGroup --name $webApp --resource-type Microsoft.Web/sites --query id --output tsv)).Trim()
        $siteState = (az rest --method get --url "https://management.azure.com${siteId}?api-version=2024-04-01" --output json | ConvertFrom-Json -AsHashtable).properties
        $usage = @((az rest --method get --url "https://management.azure.com$siteId/usages?api-version=2024-04-01" --output json | ConvertFrom-Json -AsHashtable).value |
                Where-Object { $_.name.value -eq 'WPStopRequests' }) | Select-Object -First 1
        $restarts = if ($usage) { [int] $usage.currentValue } else { 0 }
        Fail-Step ("$webApp did not start: state $($siteState.state), usage $($siteState.usageState), $restarts worker restarts this hour. " +
            'An app that crashes at startup restarts until the Free quota stops it; check its database login (system step "Grant database access") and its settings, then deploy again after the quota resets.')
    }
    if ($current -ne $startup) {
        az webapp config set --resource-group $resourceGroup --name $webApp --startup-file $startup --only-show-errors --output none
        Write-Host "Startup command of ${webApp}: $startup (the site restarts into the app; ""Verify deployable"" waits for it)"
    }
    Write-Highlight "$name $version deployed to $webApp in $environmentName ($($Site['role'] ?? 'primary'), $($Site['region'] ?? 'home region'))"
}

foreach ($site in @($standby) + @($entry)) {
    Publish-Site -Site $site
}
