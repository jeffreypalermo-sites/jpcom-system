#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Applies infra/ to one environment as the deployment stack stack-<slug>-<env>.

.DESCRIPTION
    Step "Apply environment" of the Octopus project <slug>-system; octopus/projects.tf inlines this file. The Azure
    CLI is signed in as the tier's deploy identity (Azure.Account, OIDC).

    - Templates come from the release's package <slug>-system: the commit that was already applied to the earlier
      environments, so a promotion applies exactly what was tested.
    - Versions come from environments/<env>/versions.json on main: the current desired state of the deployables,
      which the deployable projects' pin step writes.
    - The SQL administrator password is read from the environment's vault; the first apply generates it. It reaches
      the deployment through a private parameters file (mode 0600) that is removed afterwards, never a command line.
    - Secrets of a container deployable (system.json deployables[].secrets) stay in the environment's vault. One with
      "generate": true is kept like the SQL passwords: read from the vault, or generated on first use. The others are
      the operator's to write (the kit's set-demo-secret.ps1, straight into the vault): this step only looks which of
      them exist, the app references those, and a deployable with a version stops the apply while one is missing.
    - Deny settings (denyWriteAndDelete) block changes by anyone but the deploy identity: Git is the way in.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

# The Azure CLI checks once a day whether a newer Bicep exists and says so as a warning on the next command that
# reads a template: a warning in the log that is about nothing in it. The version in use is the installed one.
$env:AZURE_BICEP_CHECK_VERSION = 'false'
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$root = [string] $OctopusParameters['Octopus.Action.Package[system].ExtractedPath']
$repository = [string] $OctopusParameters['System.Repository']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$deployPrincipalId = [string] $OctopusParameters['Azure.DeployPrincipalId']
$stackName = "stack-$slug-$environmentName"

function Get-DesiredVersion {
    # environments/<env>/versions.json on main, through the API (raw.githubusercontent.com caches for minutes).
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
    $uri = "https://api.github.com/repos/$repository/contents/environments/$environmentName/versions.json?ref=main"
    try {
        $file = Invoke-RestMethod -Uri $uri -Headers $headers
    }
    catch {
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 404) {
            Write-Warning "environments/$environmentName/versions.json is not on main yet: every deployable runs its placeholder."
            return @{}
        }
        throw
    }
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
    return $text | ConvertFrom-Json -AsHashtable
}

function Get-StackOutput {
    # Only a stack that does not exist means "first apply". Any other failure to read it is retried, then stops the
    # step: an apply that wrongly takes the stack for new generates new SQL passwords (it happened in cmdemo1's prod).
    $errorFile = Join-Path ([IO.Path]::GetTempPath()) "stack-show-$([Guid]::NewGuid().ToString('N')).err"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $PSNativeCommandUseErrorActionPreference = $false
            $json = az stack group show --name $stackName --resource-group $resourceGroup --output json 2>$errorFile
            $code = $LASTEXITCODE
            $PSNativeCommandUseErrorActionPreference = $true
            if ($code -eq 0) {
                return ($json | ConvertFrom-Json -AsHashtable).outputs
            }
            $stderr = ((Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue) ?? '').Trim()
            if ($stderr -match 'DeploymentStackNotFound|ResourceNotFound|could not be found|was not found') {
                return $null
            }
            if ($attempt -eq 3) {
                Fail-Step "Cannot read ${stackName}: $stderr"
            }
            Write-Host "Reading $stackName failed (attempt $attempt of 3); retrying in 30 seconds: $stderr"
            Start-Sleep -Seconds 30
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function New-SqlPassword {
    # 32 characters with every class SQL Server's complexity rule asks for, from a cryptographic generator.
    $classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.~')
    $all = -join $classes
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }
    while ($characters.Count -lt 32) {
        $characters.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    return -join ($characters | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

function Get-SqlPassword {
    param([hashtable] $Outputs)

    if (-not $Outputs -or -not $Outputs.ContainsKey('keyVaultName')) {
        Write-Highlight "Stack $stackName does not exist yet: generating the SQL administrator password."
        return New-SqlPassword
    }
    $vault = [string] $Outputs.keyVaultName.value
    # The vault role of the deploy identity can take a few minutes to apply after the first stack.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        $value = az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv 2>$null
        $read = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if ($read -and $value) {
            return ([string] $value).Trim()
        }
        Write-Host "Waiting for read access to vault $vault (attempt $attempt of 6)"
        Start-Sleep -Seconds 30
    }
    Fail-Step "Cannot read sql-admin-password from vault $vault as the deploy identity. Check its Key Vault Secrets Officer assignment."
}

function Get-LoginPassword {
    # One database login per App Service deployable (system.json hosting "appservice"). Its password stays in the
    # vault; a new deployable or a new environment gets a generated one. Either way the grant step then sets the
    # login's password to the vault's, so a value generated after a failed read still matches.
    param([hashtable] $Outputs, [string[]] $Names)
    $result = @{}
    foreach ($name in $Names) {
        $value = $null
        if ($Outputs -and $Outputs.ContainsKey('keyVaultName')) {
            # Only a secret that does not exist yet gets a new password; another failure to read it stops the step.
            for ($attempt = 1; $attempt -le 3 -and -not $value; $attempt++) {
                $PSNativeCommandUseErrorActionPreference = $false
                $read = az keyvault secret show --vault-name ([string] $Outputs.keyVaultName.value) --name "$name-sql-password" --query value --output tsv 2>&1
                $code = $LASTEXITCODE
                $PSNativeCommandUseErrorActionPreference = $true
                if ($code -eq 0) { $value = [string] $read; break }
                if ("$read" -match 'SecretNotFound|was not found') { break }
                if ($attempt -eq 3) { Fail-Step "Cannot read $name-sql-password: the vault answered $("$read" -replace '\s+', ' ')" }
                Write-Host "Reading $name-sql-password failed (attempt $attempt of 3); retrying in 30 seconds."
                Start-Sleep -Seconds 30
            }
        }
        if ($value) {
            $result[$name] = ([string] $value).Trim()
        }
        else {
            Write-Host "Generating the database login password of $name."
            $result[$name] = New-SqlPassword
        }
    }
    return $result
}

function Read-VaultSecret {
    # The value of a vault secret, or $null when the vault or the secret does not exist yet. Any other failure to read
    # it is retried, then stops the step: taking an unreadable secret for a missing one would replace it.
    param([hashtable] $Outputs, [Parameter(Mandatory)] [string] $Name)
    if (-not $Outputs -or -not $Outputs.ContainsKey('keyVaultName')) { return $null }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        $read = az keyvault secret show --vault-name ([string] $Outputs.keyVaultName.value) --name $Name --query value --output tsv 2>&1
        $code = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $true
        if ($code -eq 0) { return ([string] $read).Trim() }
        if ("$read" -match 'SecretNotFound|was not found') { return $null }
        if ($attempt -eq 3) { Fail-Step "Cannot read ${Name}: the vault answered $("$read" -replace '\s+', ' ')" }
        Write-Host "Reading $Name failed (attempt $attempt of 3); retrying in 30 seconds."
        Start-Sleep -Seconds 30
    }
}

function Get-DeployableSecret {
    # The secrets the container deployables of this environment declare, by vault name <deployable>-<secret>:
    #   Generated  name -> value, for "generate": true: the vault's value, or a new one (64 hexadecimal characters)
    #   Present    the operator-supplied ones that exist in the vault; the app references only these
    #   Missing    deployable -> the operator-supplied ones that do not exist yet
    param([hashtable] $Outputs, [object[]] $Deployables)
    $result = @{ Generated = @{}; Present = [Collections.Generic.List[string]]::new(); Missing = [ordered] @{} }
    foreach ($deployable in $Deployables) {
        if ($deployable.ContainsKey('hosting') -and $deployable.hosting -ne 'containerapp') { continue }
        foreach ($secret in @($deployable['secrets'] | Where-Object { $_ })) {
            $vaultName = "$($deployable.name)-$($secret.name)"
            $value = Read-VaultSecret -Outputs $Outputs -Name $vaultName
            if ($secret['generate'] -eq $true) {
                if (-not $value) {
                    Write-Host "Generating secret $vaultName."
                    $value = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
                }
                $result.Generated[$vaultName] = $value
            }
            elseif ($value) {
                $result.Present.Add($vaultName)
            }
            else {
                if (-not $result.Missing.Contains([string] $deployable.name)) { $result.Missing[[string] $deployable.name] = @() }
                $result.Missing[[string] $deployable.name] += [string] $secret.name
            }
            $value = $null
        }
    }
    return $result
}

$template = Join-Path $root 'infra' 'main.bicep'
if (-not (Test-Path -LiteralPath $template)) {
    Fail-Step "Package <slug>-system has no infra/main.bicep under $root."
}

$versions = Get-DesiredVersion
$outputs = Get-StackOutput
$system = Get-Content -LiteralPath (Join-Path $root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
# deployables[].environments: a deployable may exist in some environments only; this one's are the rest of the work.
$deployablesHere = @($system.deployables | Where-Object { -not $_.ContainsKey('environments') -or @($_.environments) -contains $environmentName })
# The same rule as infra/main.bicep (hasDatabase): a container deployable uses the database unless it says
# "database": false, and an App Service deployable shares it. Without one the environment has no SQL server, and there
# is no administrator password to read or generate.
$hasDatabase = @($deployablesHere | Where-Object {
        $hosting = if ($_.ContainsKey('hosting')) { [string] $_.hosting } else { 'containerapp' }
        ($hosting -eq 'containerapp' -and -not ($_.ContainsKey('database') -and $_.database -eq $false)) -or $hosting -eq 'appservice'
    }).Count -gt 0
$password = if ($hasDatabase) { Get-SqlPassword -Outputs $outputs } else { Write-Host "No app in $environmentName uses a database: no SQL server, no SQL password."; '' }
$loginNames = @($deployablesHere | Where-Object { $_['hosting'] -eq 'appservice' } | ForEach-Object { [string] $_.name })
# A change of an App Service plan's size (system.planSku, or the dormant switch, which makes every plan Free) restarts
# the apps on that plan: Azure moves them to other workers. The plans this environment owns carry its tag; one whose
# size differs from the size system.json now declares will be resized by this apply, and the restart is then reported
# below, not counted as downtime the apply caused by mistake.
$tierName = [string] ($system.environments | Where-Object { $_.name -eq $environmentName } | Select-Object -First 1).tier
$isDormant = $system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor['dormant']
$wantedPlan = if (-not $isDormant -and $system.system.ContainsKey('planSku') -and $system.system.planSku[$tierName]) { [string] $system.system.planSku[$tierName] } else { 'F1' }
$PSNativeCommandUseErrorActionPreference = $false
$ownedPlans = @(az resource list --resource-group $resourceGroup --resource-type Microsoft.Web/serverfarms --query "[?tags.environment=='$environmentName'].{name: name, sku: sku.name}" --output json 2>$null | ConvertFrom-Json)
$PSNativeCommandUseErrorActionPreference = $true
$resizedPlans = @($ownedPlans | Where-Object { $_ -and $_.sku -ne $wantedPlan } | ForEach-Object { "$($_.name) $($_.sku) to $wantedPlan" })
if ($resizedPlans.Count -gt 0) {
    Write-Host "This apply changes a plan size ($($resizedPlans -join ', ')): the apps on it restart."
}
$loginPasswords = Get-LoginPassword -Outputs $outputs -Names $loginNames
$secrets = Get-DeployableSecret -Outputs $outputs -Deployables $deployablesHere
foreach ($name in $secrets.Missing.Keys) {
    $absent = @($secrets.Missing[$name])
    $how = "the operator writes each one to the vault with the kit's set-demo-secret.ps1 (-Environment $environmentName -Deployable $name -Name <secret>), then this release is deployed to $environmentName again"
    if ($versions[$name]) {
        # Fail fast, with the reason: the running version would restart without its secrets.
        Fail-Step "$name runs $($versions[$name]) in $environmentName, but its secret(s) $($absent -join ', ') are not in the environment's vault: $how."
    }
    Write-Highlight "$name in ${environmentName}: secret(s) $($absent -join ', ') are not in the vault yet, so its app does not reference them. Before the first release of ${name}: $how."
}
Write-Host "Environment $environmentName, resource group $resourceGroup, stack $stackName"
Write-Host "Versions on main: $(if ($versions.Count) { ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { 'none (placeholders)' })"

$parameters = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        environmentName   = @{ value = $environmentName }
        versions          = @{ value = $versions }
        sqlAdminPassword  = @{ value = $password }
        deployPrincipalId = @{ value = $deployPrincipalId }
        loginPasswords    = @{ value = $loginPasswords }
        presentSecrets    = @{ value = @($secrets.Present) }
        generatedSecrets  = @{ value = $secrets.Generated }
    }
}
$parametersFile = Join-Path ([IO.Path]::GetTempPath()) "stack-$([Guid]::NewGuid().ToString('N')).json"
New-Item -ItemType File -Path $parametersFile | Out-Null
if (-not $IsWindows) {
    [IO.File]::SetUnixFileMode($parametersFile, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
}
$parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parametersFile -Encoding utf8NoBOM

# Zero downtime, measured: while this step changes the environment, a background probe asks every app's health
# endpoint every few seconds. It follows the apps as they are, not as they were: every 15 seconds it lists the
# environment's container apps (tag "deployable"), so a move's new app is watched from the moment it exists, next to the
# old one. A deployable is available when any of its apps answers 200. Before its first 200 (an app waking from zero,
# a new environment) nothing counts; after it, two checks in a row (about 6 seconds) without a 200 are downtime.
function Start-AvailabilityProbe {
    param([Parameter(Mandatory)] [string] $Group, [Parameter(Mandatory)] [string] $Environment, [hashtable] $Outputs, [string] $Only = '', [string[]] $Ignore = @())
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
    $probeIgnore = @($Ignore)
    $job = Start-ThreadJob -ScriptBlock {
        # $using: in a thread job passes the objects themselves: $probe is the shared, synchronized table.
        $probe = $using:probe
        $group = $using:probeGroup
        $environment = $using:probeEnvironment
        $paths = $using:paths
        $static = $using:static
        $only = $using:Only
        $ignore = $using:probeIgnore
        $targets = @{}
        $listed = [datetime]::MinValue
        $tick = 0
        try {
            while (-not $probe.Stop) {
                if (([datetime]::UtcNow - $listed).TotalSeconds -ge 15) {
                    $json = az containerapp list --resource-group $group --query "[?tags.environment=='$environment'].{name: name, deployable: tags.deployable, fqdn: properties.configuration.ingress.fqdn}" --output json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $json) {
                        foreach ($app in @($json | ConvertFrom-Json)) {
                            if ($app.fqdn -and $app.deployable -and $ignore -notcontains $app.deployable -and (-not $only -or $app.deployable -eq $only)) { $targets["https://$($app.fqdn)"] = @{ Deployable = [string] $app.deployable; Name = [string] $app.name } }
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

# A deployable that brings its own runtime (hosting "own") is not this step's to keep available: its own project
# deploys and verifies it. That matters on the one apply after a deployable changes to "own": the stack removes the
# app it created, which the application's next deployment creates again, and that is the change, not downtime.
$ownRuntime = @($system.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
if ($ownRuntime.Count -gt 0) { Write-Host "Not watched here (they bring their own runtime): $($ownRuntime -join ', ')" }
$probe = Start-AvailabilityProbe -Group $resourceGroup -Environment $environmentName -Outputs $outputs -Ignore $ownRuntime
function Invoke-StackApply {
    # Applies a template as a deployment stack with deny settings; returns the stack as JSON.
    # New role assignments and identities take a few minutes to propagate, and Azure sometimes reports
    # DeploymentStackTenantRegistrationFailed on a stack with deny settings, and a runbook (restore test, password
    # rotation) may hold the database briefly (ConflictingDatabaseOperation): the apply is retried. An error the retry
    # recovers from is information, so az's stderr is kept and shown only when it is not a known transient one, or
    # when the last attempt fails (no broken windows: a healthy run logs no error).
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $ParametersFile
    )
    $transient = 'DeploymentStackTenantRegistrationFailed|PrincipalNotFound|InvalidAuthenticationToken|ConflictingDatabaseOperation'
    $errorFile = Join-Path ([IO.Path]::GetTempPath()) "stack-$([Guid]::NewGuid().ToString('N')).err"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $PSNativeCommandUseErrorActionPreference = $false
            $json = az stack group create `
                --name $Name `
                --resource-group $Group `
                --template-file $TemplateFile `
                --parameters "@$ParametersFile" `
                --action-on-unmanage deleteResources `
                --deny-settings-mode denyWriteAndDelete `
                --deny-settings-excluded-principals $deployPrincipalId `
                --yes `
                --output json 2>$errorFile
            $applied = $LASTEXITCODE -eq 0
            $PSNativeCommandUseErrorActionPreference = $true
            $stderr = (Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue) ?? ''
            if ($applied) {
                # A successful apply that still wrote something (a Bicep warning) is a finding: show it.
                if ($stderr.Trim()) { Write-Warning $stderr.Trim() }
                return $json
            }
            if ($attempt -eq 3) {
                Write-Host $stderr
                Fail-Step "az stack group create failed three times for $Name; the error is above."
            }
            $code = [regex]::Match($stderr, $transient).Value
            if ($code) {
                Write-Host "Azure reported $code, a transient error (attempt $attempt of 3); retrying in 90 seconds."
            }
            else {
                Write-Warning "az stack group create failed (attempt $attempt of 3); retrying in 90 seconds:`n$($stderr.Trim())"
            }
            Start-Sleep -Seconds 90
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

try {
    $result = Invoke-StackApply -Name $stackName -Group $resourceGroup -TemplateFile $template -ParametersFile $parametersFile
}
finally {
    Remove-Item -LiteralPath $parametersFile -Force -ErrorAction SilentlyContinue
}
# App Service resolves Key Vault references when a site starts and caches them for up to a day. A site whose identity
# the apply just replaced (a moved environment) may have tried before its new role on the secret took effect: check the
# references, and force a new resolution while one is not resolved yet (up to five minutes).
$applied = ($result | ConvertFrom-Json -AsHashtable).outputs
# The same apps in the standby region (environments[].standbyLocation); empty without one.
$standbySites = @(if ($applied.ContainsKey('standby')) { $applied.standby.value })
foreach ($site in @($applied.deployables.value | Where-Object { $_['hosting'] -eq 'appservice' }) + $standbySites) {
    $siteId = ([string] (az resource show --resource-group $resourceGroup --name ([string] $site.webApp) --resource-type Microsoft.Web/sites --query id --output tsv)).Trim()
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $pending = @((az rest --method get --url "https://management.azure.com$siteId/config/configreferences/appsettings?api-version=2022-03-01" --output json | ConvertFrom-Json -AsHashtable).value |
                Where-Object { $_.properties.status -ne 'Resolved' } | ForEach-Object { "$($_.name): $($_.properties.status)" })
        if ($pending.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { Fail-Step "Key Vault references of $($site.webApp) did not resolve within 5 minutes: $($pending -join '; ')" }
        Write-Host "Key Vault references of $($site.webApp) not resolved yet ($($pending -join '; ')); refreshing in 30 seconds."
        Start-Sleep -Seconds 30
        az rest --method post --url "https://management.azure.com$siteId/config/configreferences/appsettings/refresh?api-version=2022-03-01" --output none
    }
}

# Capability "frontdoor": the environment's public address, one Front Door endpoint per deployable in the system's
# profile (system.json azure.frontDoor; the seed creates it in a resource group of its own, shared by both tiers). It is
# a stack of its own in that group, stack-<slug>-<env>-edge, with the apps this stack reports as origins: the primary at
# priority 1 and the standby at priority 2. Its deny settings exclude only this tier's deploy identity. Without the
# capability, a stack left from before is removed with its endpoints.
$frontDoor = if ($system.azure.ContainsKey('frontDoor')) { $system.azure.frontDoor } else { @{} }
$edgeStackName = "$stackName-edge"
$endpoints = @()
# azure.frontDoor.dormant (set-demo-frontdoor.ps1 -Dormant): between classes the profile, the one part with a monthly
# fee, is deleted; the capability stays declared, and the endpoints come back when the system is awake again.
$dormant = [bool] $frontDoor['dormant']
$environmentEntry = $system.environments | Where-Object { $_.name -eq $environmentName } | Select-Object -First 1
if (@($applied.capabilities.value) -contains 'frontdoor' -and -not $dormant) {
    if (-not $frontDoor['profile']) {
        Fail-Step "Environment $environmentName has capability frontdoor, but system.json has no azure.frontDoor: run the seed with azure.frontDoor in the demo file, and add its output to system.json."
    }
    # A static site (hosting "staticwebapp") gets no endpoint: its platform already serves it from edge locations
    # under an address of its own, and it has no standby to fail over to.
    $edgeDeployables = @(foreach ($deployable in @($applied.deployables.value | Where-Object { $_['hosting'] -ne 'staticwebapp' })) {
            $origins = @(@{ name = 'primary'; hostName = ([uri] [string] $deployable.url).Host; priority = 1 })
            foreach ($site in @($standbySites | Where-Object { $_.name -eq $deployable.name })) {
                $origins += @{ name = 'standby'; hostName = ([uri] [string] $site.url).Host; priority = 2 }
            }
            @{ name = [string] $deployable.name; origins = $origins }
        })
    $edgeParameters = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            slug            = @{ value = $slug }
            environmentName = @{ value = $environmentName }
            profileName     = @{ value = [string] $frontDoor.profile }
            tags            = @{ value = @{ system = $slug; environment = $environmentName; purpose = 'demo' } }
            deployables     = @{ value = $edgeDeployables }
            # Front Door probes every origin from every edge location. Every 10 seconds on a Basic plan
            # (system.planSku for the tier); every 30 on the Free plan, where the probes' answers count against the
            # plan's 165 MB of outbound data a day.
            probeIntervalInSeconds = @{ value = $(if ($system.system.ContainsKey('planSku') -and $system.system.planSku[[string] $environmentEntry.tier] -eq 'B1') { 10 } else { 30 }) }
        }
    }
    $edgeParametersFile = Join-Path ([IO.Path]::GetTempPath()) "stack-$([Guid]::NewGuid().ToString('N')).json"
    $edgeParameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $edgeParametersFile -Encoding utf8NoBOM
    try {
        Write-Host "Front Door: stack $edgeStackName in $($frontDoor.resourceGroup), profile $($frontDoor.profile)"
        $edgeResult = Invoke-StackApply -Name $edgeStackName -Group ([string] $frontDoor.resourceGroup) `
            -TemplateFile (Join-Path $root 'infra' 'modules' 'frontdoor.bicep') -ParametersFile $edgeParametersFile
    }
    finally {
        Remove-Item -LiteralPath $edgeParametersFile -Force -ErrorAction SilentlyContinue
    }
    $endpoints = @(($edgeResult | ConvertFrom-Json -AsHashtable).outputs.endpoints.value)
}
elseif ($frontDoor['resourceGroup']) {
    $PSNativeCommandUseErrorActionPreference = $false
    az stack group show --name $edgeStackName --resource-group ([string] $frontDoor.resourceGroup) --output none 2>$null
    $hasEdgeStack = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if ($hasEdgeStack) {
        # The operator may be removing the same stack, or its group, at this moment (going dormant): only a stack
        # that is still there afterwards is a failure.
        $PSNativeCommandUseErrorActionPreference = $false
        az stack group delete --name $edgeStackName --resource-group ([string] $frontDoor.resourceGroup) --action-on-unmanage deleteResources --yes --output none 2>$null
        # A delete refused because the other one is under way leaves the stack there for a few minutes more: wait for
        # it to go before calling it a failure (cmdemo2, 2026-10-06: the stack was gone two minutes after this step failed).
        $stillThere = $true
        foreach ($attempt in 1..30) {
            az stack group show --name $edgeStackName --resource-group ([string] $frontDoor.resourceGroup) --output none 2>$null
            if ($LASTEXITCODE -ne 0) { $stillThere = $false; break }
            Start-Sleep -Seconds 20
        }
        $PSNativeCommandUseErrorActionPreference = $true
        if ($stillThere) { Fail-Step "Stack $edgeStackName could not be removed from $($frontDoor.resourceGroup)." }
        Write-Highlight "Front Door endpoints of $environmentName removed ($(if ($dormant) { 'the system is dormant' } else { 'capability frontdoor is off' }))."
    }
    elseif ($dormant) {
        Write-Host "Front Door is dormant: $environmentName has no public address until the system is awake again."
    }
}

# A little longer than the apply: the stack removes replaced apps at its end, and the new ones take over.
Start-Sleep -Seconds 30
$downtime = Stop-AvailabilityProbe -Handle $probe
if ($downtime -gt 0 -and $resizedPlans.Count -gt 0) {
    Write-Highlight "The plan size changed ($($resizedPlans -join ', ')): Azure restarts the apps on a resized plan, so the $downtime downtime period(s) above are that restart, measured and expected, and do not fail the apply."
}
elseif ($downtime -gt 0) {
    Fail-Step "The apply of $stackName caused $downtime downtime period(s); the timeline is above."
}

$stack = $result | ConvertFrom-Json -AsHashtable
foreach ($deployable in $stack.outputs.deployables.value) {
    $label = if ($deployable.version) { $deployable.version } else { 'placeholder' }
    Write-Highlight "$($deployable.name) in ${environmentName}: $($deployable.url) ($label)"
    Set-OctopusVariable -name "Url.$($deployable.name)" -value $deployable.url
}
foreach ($site in $standbySites) {
    Write-Highlight "$($site.name) in ${environmentName}, standby in $($site.region): $($site.url)"
}
foreach ($endpoint in $endpoints) {
    Write-Highlight "$($endpoint.name) in ${environmentName} behind Front Door: $($endpoint.url) ($(@($endpoint.origins).Count) origin(s), probe $($endpoint.probePath))"
    Set-OctopusVariable -name "FrontDoorUrl.$($endpoint.name)" -value $endpoint.url
}
Write-Highlight "Capabilities of ${environmentName}: $($stack.outputs.capabilities.value -join ', ')"
