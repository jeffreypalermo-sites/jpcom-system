#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Points the deployable's container app at the release's image.

.DESCRIPTION
    Step "Update deployable" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. The
    fast path of a deployment: the image tag <registry>/<slug>/<deployable>:<release> and the app's port, on the
    container app the stack created. The pin step already wrote the same version to Git, so the next apply of the
    stack (an environment release, or the nightly drift check) agrees with what runs. The deploy identity is excluded
    from the stack's deny settings, so it may make this change. It then waits until the new revision is ready, and fails
    at once, with the container's last console lines, when the revision cannot start.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$deployable = [string] $OctopusParameters['Deployable.Name']
$port = [string] $OctopusParameters['Deployable.Port']
$registry = [string] $OctopusParameters['Azure.RegistryServer']
$version = [string] $OctopusParameters['Octopus.Release.Number']
# The container app's name comes from the stack: a shared or moved Container Apps environment gives it a suffix.
$stackOutputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$app = [string] (@($stackOutputs.deployables.value | Where-Object { $_.name -eq $deployable -and $_['hosting'] -ne 'appservice' }) | Select-Object -First 1).containerApp
if (-not $app) {
    Fail-Step "Stack stack-$slug-$environmentName lists no container app for ${deployable}: deploy a release of $slug-system to $environmentName first."
}

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

function Write-RevisionLog {
    param([Parameter(Mandatory)] [string] $App)
    if ($express) {
        # An express environment has no console log stream for the Azure CLI; the app itself says why it failed.
        $PSNativeCommandUseErrorActionPreference = $false
        $errors = az rest --method get --url $expressAppUri --query properties.deploymentErrors --output tsv 2>$null
        $PSNativeCommandUseErrorActionPreference = $true
        Write-Host "Deployment errors of ${App}: $(if ($errors) { $errors } else { 'none reported' })"
        return
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = az containerapp logs show --name $App --resource-group $resourceGroup --type console --tail 40 --format text 2>&1
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "Last console lines of ${App}:"
    @($lines) | ForEach-Object { Write-Host "  $_" }
}
$image = "$registry/$slug/${deployable}:$version"

$PSNativeCommandUseErrorActionPreference = $false
az containerapp show --name $app --resource-group $resourceGroup --output none 2>$null
$exists = $LASTEXITCODE -eq 0
$PSNativeCommandUseErrorActionPreference = $true
if (-not $exists) {
    Fail-Step "Container app $app does not exist: deploy a release of $slug-system to $environmentName first (the environment is created by the system pipeline)."
}

# The Container Apps commands of the Azure CLI draw a console animation on stderr while they wait, whatever the CLI
# settings, which Octopus logs as errors. So the update starts with --no-wait (the ingress port goes through az rest,
# as the same PATCH "az containerapp ingress update" sends) and this script does the waiting, with a readable log.
$current = az containerapp show --name $app --resource-group $resourceGroup --output json |
    ConvertFrom-Json -AsHashtable
# The API version infra/modules/containerapps.bicep creates the app with: an older one does not know every property
# of the app (identitySettings), and this URI is also used to change it (the ingress port).
$appUri = "https://management.azure.com$($current.id)?api-version=2025-01-01"
$before = [string] $current.properties.latestRevisionName

# An Azure Container Apps express environment (system.json azure.appEnvironment.mode "express") behaves differently
# in three ways this step depends on (seen on the first express system, jpcom, 2026-10-06):
#   - the app keeps no registry setting: the identity that pulls the image must come in the request that changes the
#     image, or the pull fails ("Authentication failed when pulling container image ... Provide ... 'managedIdentityClientId'");
#   - there is one revision, always named <app>--latest, and latestReadyRevisionName stays empty: the image the app
#     shows and its provisioning state say when the change is done;
#   - "az containerapp logs show" fails there; the app reports the reason of a failed change as deploymentErrors.
$expressAppUri = "https://management.azure.com$($current.id)?api-version=2026-07-01"
$environmentMode = [string] (az rest --method get --url "https://management.azure.com$($current.properties.environmentId)?api-version=2026-07-01" --query properties.environmentMode --output tsv)
$express = $environmentMode.Trim() -eq 'Express'

# Secrets the deployable declares (system.json deployables[].secrets; variable Deployable.Secrets, the names joined by
# commas): the environment's stack makes the app reference each one once it is in the vault. A version that starts
# without one fails in ways its log may not explain, so stop before anything changes, with the reason.
$declaredSecrets = @(([string] $OctopusParameters['Deployable.Secrets']) -split ',' | Where-Object { $_ })
$referencedSecrets = @($current.properties.configuration['secrets'] | Where-Object { $_ } | ForEach-Object { [string] $_.name })
$absentSecrets = @($declaredSecrets | Where-Object { $referencedSecrets -notcontains $_ })
if ($absentSecrets.Count -gt 0) {
    Fail-Step "$app does not reference the secret(s) $($absentSecrets -join ', ') that $deployable declares: the operator writes each one to the vault of $environmentName (the kit's set-demo-secret.ps1), then the latest release of $slug-system is deployed to $environmentName again, then this release."
}

# Zero downtime, measured: while this step changes the environment, a background probe asks every app's health
# endpoint every few seconds. It follows the apps as they are, not as they were: every 15 seconds it lists the
# environment's container apps (tag "deployable"), so a move's new app is watched from the moment it exists, next to the
# old one. A deployable is available when any of its apps answers 200. Before its first 200 (an app waking from zero,
# a new environment) nothing counts; after it, two checks in a row (about 6 seconds) without a 200 are downtime.
function Start-AvailabilityProbe {
    param([Parameter(Mandatory)] [string] $Group, [Parameter(Mandatory)] [string] $Environment, [hashtable] $Outputs, [string] $Only = '')
    $paths = @{}
    $static = @{}
    if ($Outputs -and $Outputs.ContainsKey('deployables')) {
        foreach ($entry in @($Outputs.deployables.value)) {
            $paths[[string] $entry.name] = [string] $entry.healthPath
            # App Service apps and static sites keep the URL the stack reports; container apps are listed below.
            if (@('appservice', 'staticwebapp') -contains $entry['hosting']) { $static[[string] $entry.name] = [string] $entry.url }
        }
    }
    $probe = [hashtable]::Synchronized(@{ Stop = $false; Samples = [Collections.Generic.List[object]]::new(); Error = '' })
    if ($Only) { foreach ($name in @($static.Keys)) { if ($name -ne $Only) { $static.Remove($name) } } }
    $probeGroup = $Group
    $probeEnvironment = $Environment
    $job = Start-ThreadJob -ScriptBlock {
        # $using: in a thread job passes the objects themselves: $probe is the shared, synchronized table.
        $probe = $using:probe
        $group = $using:probeGroup
        $environment = $using:probeEnvironment
        $paths = $using:paths
        $static = $using:static
        $only = $using:Only
        $targets = @{}
        $listed = [datetime]::MinValue
        $tick = 0
        try {
            while (-not $probe.Stop) {
                if (([datetime]::UtcNow - $listed).TotalSeconds -ge 15) {
                    $json = az containerapp list --resource-group $group --query "[?tags.environment=='$environment'].{name: name, deployable: tags.deployable, fqdn: properties.configuration.ingress.fqdn}" --output json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $json) {
                        foreach ($app in @($json | ConvertFrom-Json)) {
                            if ($app.fqdn -and $app.deployable -and (-not $only -or $app.deployable -eq $only)) { $targets["https://$($app.fqdn)"] = @{ Deployable = [string] $app.deployable; Name = [string] $app.name } }
                        }
                    }
                    foreach ($name in $static.Keys) { $targets[$static[$name]] = @{ Deployable = $name; Name = $static[$name] } }
                    $listed = [datetime]::UtcNow
                }
                $tick++
                foreach ($url in @($targets.Keys)) {
                    $target = $targets[$url]
                    $path = if ($paths.ContainsKey($target.Deployable) -and $paths[$target.Deployable]) { $paths[$target.Deployable] } else { '/' }
                    $failure = ''
                    $status = try { [int] (Invoke-WebRequest -Uri "$url$path" -TimeoutSec 15 -SkipHttpErrorCheck).StatusCode } catch { $failure = $_.Exception.Message; 0 }
                    $probe.Samples.Add([pscustomobject] @{ Tick = $tick; Time = [datetime]::UtcNow; Deployable = $target.Deployable; App = $target.Name; Status = $status; Failure = $failure })
                }
                Start-Sleep -Seconds 3
            }
        }
        catch { $probe.Error = $_.Exception.Message }
    }
    return @{ Probe = $probe; Job = $job }
}

function Stop-AvailabilityProbe {
    # Stops the probe and reports per deployable; returns the number of downtime periods.
    param([Parameter(Mandatory)] [hashtable] $Handle)
    $Handle.Probe.Stop = $true
    $null = Wait-Job -Job $Handle.Job -Timeout 60
    Remove-Job -Job $Handle.Job -Force
    if ($Handle.Probe.Error) { Write-Host "Availability probe stopped early: $($Handle.Probe.Error)" }
    $downtimes = 0
    $samples = @($Handle.Probe.Samples)
    foreach ($group in @($samples | Group-Object Deployable)) {
        $ticks = @($group.Group | Group-Object Tick | Sort-Object { [int] $_.Name })
        $own = 0
        $seenHealthy = $false
        $missed = 0
        $gapStart = $null
        foreach ($tickGroup in $ticks) {
            $healthy = @($tickGroup.Group | Where-Object Status -eq 200).Count -gt 0
            if ($healthy) {
                if ($missed -ge 2) {
                    $own++
                    Write-Host "Downtime of $($group.Name): no app answered 200 from $($gapStart.ToString('HH:mm:ss')) to $(($tickGroup.Group[0].Time).ToString('HH:mm:ss'))"
                }
                $seenHealthy = $true
                $missed = 0
            }
            elseif ($seenHealthy) {
                if ($missed -eq 0) { $gapStart = $tickGroup.Group[0].Time }
                $missed++
            }
        }
        if ($seenHealthy -and $missed -ge 2) {
            $own++
            Write-Host "Downtime of $($group.Name): no app answered 200 from $($gapStart.ToString('HH:mm:ss')) to the end of the step"
        }
        $served = @($group.Group | Where-Object Status -eq 200 | Group-Object App | ForEach-Object {
                $first = ($_.Group | Measure-Object Time -Minimum).Minimum
                $last = ($_.Group | Measure-Object Time -Maximum).Maximum
                "$($_.Name) $($first.ToString('HH:mm:ss'))-$($last.ToString('HH:mm:ss'))"
            })
        $summary = if (-not $seenHealthy) { 'not available yet (nothing to keep up)' } elseif ($served.Count -gt 0) { "served by $($served -join ', ')" } else { '' }
        $downtimes += $own
        Write-Highlight "Availability of $($group.Name) in ${environmentName}: $($ticks.Count) checks, $(if ($own) { "$own downtime period(s)" } else { 'no downtime' }); $summary"
    }
    return $downtimes
}

# The first deployment replaces the placeholder image, which answers on another port and is not the app: between the
# port change and the app's first start nothing can answer, and that is not downtime of anything that ran. Measured
# from the second deployment on.
$overPlaceholder = -not ([string] $current.properties.template.containers[0].image).StartsWith("$registry/")
$probe = if ($overPlaceholder) { $null } else { Start-AvailabilityProbe -Group $resourceGroup -Environment $environmentName -Outputs $stackOutputs -Only $deployable }

# The port changes only on the first deployment over the placeholder image.
$currentPort = [string] $current.properties.configuration.ingress.targetPort
if ($currentPort -ne $port) {
    $body = @{ properties = @{ configuration = @{ ingress = @{ targetPort = [int] $port; exposedPort = $null } } } } |
        ConvertTo-Json -Depth 6 -Compress
    az rest --method patch --url $appUri --body $body --headers 'Content-Type=application/json' --output none
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $provisioning = [string] (az rest --method get --url $appUri --query properties.provisioningState --output tsv)
    } while ($provisioning.Trim() -notin @('Succeeded', 'Failed') -and (Get-Date) -lt $deadline)
    if ($provisioning.Trim() -ne 'Succeeded') {
        Fail-Step "The ingress of $app did not change to port $port (provisioning state $provisioning)."
    }
    Write-Host "Ingress of $app now targets port $port (was $currentPort)"
}

$currentImage = [string] $current.properties.template.containers[0].image
if ($currentImage -eq $image) {
    Write-Host "$app already runs $image"
}
else {
    Write-Host "Updating $app from $currentImage to $image"
    if ($express) {
        # The environment's shared identity pulls the image (the seed gave it AcrPull); the app carries it already.
        $pullIdentity = [string] (@($current.identity.userAssignedIdentities.Keys | Where-Object { $_ -match "/id-$([regex]::Escape($slug))-$([regex]::Escape($environmentName))-app$" }) | Select-Object -First 1)
        if (-not $pullIdentity) { Fail-Step "$app carries no identity id-$slug-$environmentName-app to pull $image with: deploy the latest release of $slug-system to $environmentName first." }
        $containers = @($current.properties.template.containers)
        $containers[0].image = $image
        $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "update-$app-$([Guid]::NewGuid().ToString('N')).json"
        @{ properties = @{ configuration = @{ registries = @(@{ server = $registry; identity = $pullIdentity }) }; template = @{ containers = $containers } } } |
            ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
        try { az rest --method patch --url $appUri --body "@$bodyFile" --headers 'Content-Type=application/json' --output none }
        finally { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
        # The change is accepted at once; a moment later the app shows it as in progress.
        Start-Sleep -Seconds 5
    }
    else {
        az containerapp update --name $app --resource-group $resourceGroup --image $image --no-wait --output none
    }
}

# Ready when a new revision (or, for an unchanged image, the current one) is the latest and the latest ready one; a
# revision that cannot start fails at once.
$deadline = (Get-Date).AddMinutes(10)
while ($true) {
    $state = az containerapp show --name $app --resource-group $resourceGroup --query '{latest: properties.latestRevisionName, ready: properties.latestReadyRevisionName, provisioning: properties.provisioningState, image: properties.template.containers[0].image}' --output json | ConvertFrom-Json -AsHashtable
    # Express: the one revision keeps its name and is never listed as the latest ready one (above).
    $isNew = $currentImage -eq $image -or $state.latest -ne $before -or ($express -and $state.image -eq $image)
    $isReady = if ($express) { $state.image -eq $image } else { $state.latest -and $state.latest -eq $state.ready }
    if ($isNew -and $state.provisioning -eq 'Succeeded' -and $isReady) {
        Write-Host "Revision $($state.latest) is ready"
        break
    }
    if ($state.provisioning -eq 'Failed') {
        Write-RevisionLog -App $app
        Fail-Step "Updating $app to $image failed (provisioning state Failed)."
    }
    $problem = if ($isNew) { Get-RevisionProblem -App $app } else { $null }
    if ($problem) {
        Write-RevisionLog -App $app
        Fail-Step "$deployable $version cannot start in ${environmentName}: $problem"
    }
    if ((Get-Date) -gt $deadline) {
        Write-RevisionLog -App $app
        Fail-Step "Revision $($state.latest) of $app was not ready within 10 minutes."
    }
    Write-Host "Waiting for the new revision (latest $($state.latest), ready $($state.ready), $($state.provisioning))"
    Start-Sleep -Seconds 10
}
if ($probe) {
    # A little longer than the update: the new revision takes the traffic once it is ready.
    Start-Sleep -Seconds 30
    $downtime = Stop-AvailabilityProbe -Handle $probe
    if ($downtime -gt 0) {
        Fail-Step "Updating $app to $version caused $downtime downtime period(s); the timeline is above."
    }
}
else {
    Write-Host "First deployment of $deployable in ${environmentName}: it replaces the placeholder, so its availability is measured from the next deployment on."
}
Write-Highlight "$deployable $version runs in $environmentName ($app)."
