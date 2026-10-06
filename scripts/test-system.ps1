#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Checks system.json and the environment folders before anything is applied.

.DESCRIPTION
    Runs in job env-checks of .github/workflows/env-checks.yml on every pull request, and locally:
      pwsh -NoProfile -File scripts/test-system.ps1
    Prints PASS or FAIL per check and exits 1 when any check fails.

    - The slug, environment and deployable names follow the naming rules every template relies on.
    - Each deployable's hosting is one the templates know: containerapp (the default), appservice or staticwebapp.
    - Each environment has a tier (nonprod or prod), a runtime identity from the seed and a folder
      environments/<env>/ with a versions.json object whose keys are deployables.
    - Each capability has a module: baseline is built in, every other one is infra/modules/<capability>.bicep.
    - employeeMiddleNames, where an environment has it, maps user names to middle names of 1 to 100 characters.
    - acceptanceTestsFilter, where a deployable has it, is a dotnet test filter (for example TestCategory=Smoke) on a
      deployable with an acceptance-test package.
    - octopus.approvers, where present, lists each person who may sign off once, by Octopus username or email address,
      without the system's service account; octopus.operator, where present, is a username.
    - A container deployable's own keys, where present, have the shape infra/ and octopus/ read: environments (the
      environments it exists in, the first one among them), alwaysOn and database (true or false), cpu, settings and
      environmentSettings (environment variable to text), urlSetting, and secrets (name, env, generate; never a value).
    - azure.appEnvironment, where present (the system owns its Container Apps environment), has the seed's shape, and
      then no environment chooses a placement of its own and every deployable is a container app.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$failures = [Collections.Generic.List[string]]::new()
function Test-Rule {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL $Name$(if ($Detail) { ": $Detail" })"
        $failures.Add($Name)
    }
}

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
Test-Rule 'slug' ($slug -cmatch '^[a-z][a-z0-9]{2,9}$') "'$slug' must be 3 to 10 lowercase letters and digits, starting with a letter"

# Who signs off (octopus/approvers.tf): octopus.approvers, the people in the space team "<slug> approvers" by Octopus
# username or email address ([] or left out: only automation signs off), and octopus.operator, the operator identity
# that answers a sign-off with a recorded reason ("ai-ops" when left out).
if ($system.octopus.ContainsKey('approvers')) {
    $approvers = $system.octopus.approvers
    $valid = $approvers -is [array] -and @($approvers | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^\S(?:.*\S)?$' }).Count -eq 0
    Test-Rule 'octopus.approvers' $valid 'a list of Octopus usernames or email addresses ([] when only automation signs off)'
    if ($valid) {
        $logins = @($approvers | ForEach-Object { $_.ToLowerInvariant() })
        Test-Rule 'octopus.approvers each once' (@($logins | Select-Object -Unique).Count -eq $logins.Count) 'a username or email address appears twice (Octopus compares them without case)'
        Test-Rule 'octopus.approvers without the service account' ($logins -notcontains "$slug-github") "$slug-github applies the configuration; the people who sign off are others"
    }
}
if ($system.octopus.ContainsKey('operator')) {
    Test-Rule 'octopus.operator' ($system.octopus.operator -is [string] -and $system.octopus.operator -cmatch '^\S(?:.*\S)?$') 'the Octopus username of the operator identity, for example ai-ops'
}

$deployableNames = @($system.deployables | ForEach-Object { [string] $_.name })
Test-Rule 'deployables present' ($deployableNames.Count -gt 0)
foreach ($name in $deployableNames) {
    # Azure names carry it: ca-<slug>-<env>-<deployable> has at most 32 characters, hyphens inside but not doubled.
    Test-Rule "deployable $name name" ($name -cmatch '^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,9}$') 'lowercase letters, digits and inner hyphens, 2 to 10'
    Test-Rule "deployable $name is not 'system'" ($name -cne 'system') 'the Octopus project <slug>-system is the environments project'
}
Test-Rule 'deployable names unique' (@($deployableNames | Select-Object -Unique).Count -eq $deployableNames.Count)
foreach ($deployable in @($system.deployables)) {
    # Optional: the dotnet test filter of the acceptance tests after a deployment (variable AcceptanceTests.Filter),
    # conditions <property><operator><value> (operators = != ~ !~) joined by & or |, parentheses allowed. Without it
    # the full suite runs; a filter that matches no test fails the step "Acceptance tests".
    if ($deployable.ContainsKey('acceptanceTestsFilter')) {
        $filter = $deployable.acceptanceTestsFilter
        $terms = @(if ($filter -is [string]) { ($filter -replace '[()]', ' ') -split '[&|]' | ForEach-Object { $_.Trim() } })
        $valid = $filter -is [string] -and $filter -cmatch '^\S(?:[^\r\n]*\S)?$' -and $terms.Count -gt 0 -and
            @($terms | Where-Object { $_ -cnotmatch '^[A-Za-z]+\s*(?:!=|!~|=|~)\s*[^\s=~!&|()](?:[^&|()]*[^\s&|()])?$' }).Count -eq 0
        Test-Rule "deployable $($deployable.name) acceptanceTestsFilter" ($valid -and [string] $deployable['acceptanceTestsPackage'] -ne '') 'a dotnet test filter such as TestCategory=Smoke (conditions <property><operator><value> with = != ~ !~, joined by & or |), on a deployable with acceptanceTestsPackage'
    }
}

# azure.appEnvironment (the seed's output with the demo file's azure.appEnvironment "system"): the system's one Container
# Apps environment, which every environment runs its container apps in (infra/main.bicep). It carries what the
# templates read, and the environments then choose no placement of their own: no appLocation, no
# sharesAppEnvironmentWith. Its deployables run on Container Apps (an App Service or static deployable has no
# Container Apps environment to share).
if ($system.azure.ContainsKey('appEnvironment')) {
    $appEnvironment = $system.azure.appEnvironment
    $shape = $appEnvironment -is [Collections.IDictionary] -and
        @('name', 'id', 'resourceGroup', 'location', 'defaultDomain' | Where-Object { -not ($appEnvironment.ContainsKey($_) -and $appEnvironment[$_] -is [string] -and $appEnvironment[$_]) }).Count -eq 0
    Test-Rule 'azure.appEnvironment' $shape 'the seed output: name, id, resourceGroup, location and defaultDomain of the system Container Apps environment'
    # mode (the demo file's azure.appEnvironmentMode): standard, or express for an Azure Container Apps express
    # environment; left out by a seed older than the choice, which made a standard one.
    Test-Rule 'azure.appEnvironment mode' (-not ($appEnvironment -is [Collections.IDictionary]) -or -not $appEnvironment.ContainsKey('mode') -or @('standard', 'express') -ccontains [string] $appEnvironment.mode) 'standard or express'
    if ($shape) {
        Test-Rule 'azure.appEnvironment id' ([string] $appEnvironment.id -cmatch "^/subscriptions/[^/]+/resourceGroups/$([regex]::Escape([string] $appEnvironment.resourceGroup))/providers/Microsoft\.App/managedEnvironments/$([regex]::Escape([string] $appEnvironment.name))$") 'the resource ID of a managed environment named name, in resourceGroup'
    }
    foreach ($environment in @($system.environments)) {
        foreach ($key in 'appLocation', 'sharesAppEnvironmentWith') {
            Test-Rule "environment $($environment.name) without $key" (-not $environment.ContainsKey($key)) "with azure.appEnvironment every environment runs in the system's Container Apps environment; remove $key"
        }
    }
    foreach ($deployable in @($system.deployables)) {
        Test-Rule "deployable $($deployable.name) on Container Apps" (-not $deployable.ContainsKey('hosting') -or $deployable.hosting -ceq 'containerapp') "with azure.appEnvironment every deployable is a container app; '$($deployable['hosting'])' has no place in it"
    }
}

# Where a deployable runs: infra/main.bicep and octopus/main.tf have a module and an "Update deployable" step per
# hosting, and a value they do not know would get neither.
$hostings = @('containerapp', 'appservice', 'staticwebapp')
foreach ($deployable in @($system.deployables)) {
    if ($deployable.ContainsKey('hosting')) {
        Test-Rule "deployable $($deployable.name) hosting" ($hostings -ccontains [string] $deployable.hosting) "'$($deployable.hosting)' is not one of $($hostings -join ', ') (containerapp when left out)"
    }
}
# A container deployable's own keys (infra/main.bicep and modules/containerapps.bicep read them; all optional):
#   environments         the environments it exists in (the others get none of its resources, and its Octopus
#                        lifecycle has only these); the system's first environment is among them, because every
#                        release starts there
#   alwaysOn             true: one replica that never scales to zero (a background service)
#   database             false: no SQL connection string
#   cpu                  0.5, 1, 1.5 or 2 vCPU, with twice as many GiB (the environment's appCpu when left out)
#   settings             { "<environment variable>": "<text>" }, in every environment
#   environmentSettings  { "<environment>": { "<environment variable>": "<text>" } }, on top of settings there
#   urlSetting           the environment variable that gets the app's own public address
#   secrets              [{ "name", "env", "generate" }]: environment variable <env> from the vault secret
#                        <deployable>-<name>. The operator writes its value to the vault (the kit's
#                        set-demo-secret.ps1); with "generate": true the deployment generates it. Never a value here.
$environmentNamesDeclared = @($system.environments | ForEach-Object { [string] $_.name })
$containerKeys = @('environments', 'alwaysOn', 'database', 'cpu', 'settings', 'environmentSettings', 'urlSetting', 'secrets')
$variableName = '^[A-Za-z_][A-Za-z0-9_]{0,254}$'
# Set by the template itself, or by Container Apps.
$reservedVariables = @('ConnectionStrings__SqlConnectionString', 'OTEL_SERVICE_NAME', 'APPLICATIONINSIGHTS_CONNECTION_STRING')
function Test-VariableName {
    param($Name)
    return $Name -is [string] -and $Name -cmatch $variableName -and $reservedVariables -cnotcontains $Name -and $Name -cnotmatch '^CONTAINER_APP_'
}
function Test-SettingMap {
    # An object of environment variable names to text.
    param($Map)
    if ($Map -isnot [Collections.IDictionary]) { return $false }
    return @($Map.GetEnumerator() | Where-Object { -not (Test-VariableName $_.Key) -or $_.Value -isnot [string] }).Count -eq 0
}
# The vault's own secrets (infra/modules/keyvault.bicep): a deployable's secret may not take one of their names.
$vaultSecretNames = [Collections.Generic.List[string]] @('sql-admin-password', 'sql-connection-string')
foreach ($login in @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' })) {
    $vaultSecretNames.Add("$($login.name)-sql-password")
    $vaultSecretNames.Add("$($login.name)-sql-connection-string")
}
foreach ($deployable in @($system.deployables)) {
    $name = [string] $deployable.name
    $used = @($containerKeys | Where-Object { $deployable.ContainsKey($_) })
    if ($used.Count -eq 0) { continue }
    $isContainer = -not $deployable.ContainsKey('hosting') -or $deployable.hosting -ceq 'containerapp'
    Test-Rule "deployable $name $($used -join ', ') on a container app" $isContainer "these keys apply to hosting containerapp only; $name has hosting '$($deployable['hosting'])'"
    if (-not $isContainer) { continue }

    $here = $environmentNamesDeclared
    if ($deployable.ContainsKey('environments')) {
        $listed = $deployable.environments
        $valid = $listed -is [array] -and $listed.Count -gt 0 -and @($listed | Where-Object { $_ -isnot [string] -or $environmentNamesDeclared -cnotcontains $_ }).Count -eq 0 -and
            @($listed | Select-Object -Unique).Count -eq $listed.Count
        Test-Rule "deployable $name environments" $valid "a list of environments of system.json, each once: $($environmentNamesDeclared -join ', ')"
        if ($valid) {
            Test-Rule "deployable $name environments with the first" ($listed -ccontains $environmentNamesDeclared[0]) "every release starts in $($environmentNamesDeclared[0]): it must be among the deployable's environments"
            $here = @($listed)
        }
    }
    foreach ($key in 'alwaysOn', 'database') {
        if ($deployable.ContainsKey($key)) { Test-Rule "deployable $name $key" ($deployable[$key] -is [bool]) 'true or false' }
    }
    if ($deployable.ContainsKey('cpu')) {
        Test-Rule "deployable $name cpu" ($deployable.cpu -is [string] -and @('0.5', '1', '1.5', '2') -ccontains $deployable.cpu) 'one of "0.5", "1", "1.5", "2" (vCPU, as text; the memory is twice as many GiB)'
    }

    # Every environment variable has one source: a setting (settings, with environmentSettings on top), the app's own
    # address (urlSetting) or a secret.
    $settingNames = [Collections.Generic.List[string]]::new()
    if ($deployable.ContainsKey('settings')) {
        $valid = Test-SettingMap $deployable.settings
        Test-Rule "deployable $name settings" $valid 'an object of environment variable names (letters, digits and _, not one the template sets itself) to text'
        if ($valid) { $settingNames.AddRange([string[]] @($deployable.settings.Keys)) }
    }
    if ($deployable.ContainsKey('environmentSettings')) {
        $perEnvironment = $deployable.environmentSettings
        $valid = $perEnvironment -is [Collections.IDictionary] -and @($perEnvironment.GetEnumerator() | Where-Object { $here -cnotcontains $_.Key -or -not (Test-SettingMap $_.Value) }).Count -eq 0
        Test-Rule "deployable $name environmentSettings" $valid "an object of environment ($($here -join ', ')) to an object of environment variable names to text"
        if ($valid) { foreach ($map in $perEnvironment.Values) { $settingNames.AddRange([string[]] @($map.Keys)) } }
    }
    $sources = [Collections.Generic.List[string]] @($settingNames | Select-Object -Unique)
    if ($deployable.ContainsKey('urlSetting')) {
        Test-Rule "deployable $name urlSetting" (Test-VariableName $deployable.urlSetting) 'the name of the environment variable that gets the app''s own public address'
        $sources.Add([string] $deployable.urlSetting)
    }
    if ($deployable.ContainsKey('secrets')) {
        $secrets = $deployable.secrets
        $valid = $secrets -is [array] -and @($secrets | Where-Object {
                $_ -isnot [Collections.IDictionary] -or @($_.Keys | Where-Object { @('name', 'env', 'generate') -cnotcontains $_ }).Count -gt 0 -or
                $_['name'] -isnot [string] -or $_['name'] -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?$' -or $_['name'] -cmatch '--' -or
                -not (Test-VariableName $_['env']) -or ($_.ContainsKey('generate') -and $_.generate -isnot [bool])
            }).Count -eq 0
        Test-Rule "deployable $name secrets" $valid 'a list of { "name": lowercase letters, digits and inner hyphens (up to 60), "env": the environment variable, "generate": true or false }; no other key: a secret''s value never goes into system.json'
        if ($valid) {
            $secretNames = @($secrets | ForEach-Object { [string] $_.name })
            Test-Rule "deployable $name secret names unique" (@($secretNames | Select-Object -Unique).Count -eq $secretNames.Count -and $secretNames -cnotcontains 'sql-connection-string') 'each name once, and not sql-connection-string (the app''s own reference to the database)'
            foreach ($secret in $secrets) {
                $vaultName = "$name-$($secret.name)"
                Test-Rule "deployable $name secret $($secret.name) vault name" ($vaultSecretNames -cnotcontains $vaultName) "the vault already has a secret $vaultName (the template's own, or another deployable's)"
                $vaultSecretNames.Add($vaultName)
                $sources.Add([string] $secret.env)
            }
        }
    }
    $twice = @($sources | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object Name)
    Test-Rule "deployable $name environment variables have one source" ($twice.Count -eq 0) "set by more than one of settings, urlSetting and secrets: $($twice -join ', ')"
}

# A static site is the dashboard of the system's apps: the first deployable is the app the checks and the operator
# scripts ask, so it is never the static site.
if (@($system.deployables).Count -gt 0) {
    Test-Rule 'first deployable is an app' (@($system.deployables)[0]['hosting'] -cne 'staticwebapp') 'the first deployable is the system''s first app; add a staticwebapp deployable after it'
}
# The Free plan of Static Web Apps exists in these regions only (system.staticLocation; centralus when left out).
if ($system.system.ContainsKey('staticLocation')) {
    $staticRegions = @('westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia')
    Test-Rule 'system staticLocation' ($staticRegions -ccontains [string] $system.system.staticLocation) "'$($system.system.staticLocation)' is not one of $($staticRegions -join ', ')"
}

$environmentNames = @($system.environments | ForEach-Object { [string] $_.name })
Test-Rule 'environments present' ($environmentNames.Count -gt 0)
Test-Rule 'environment names unique' (@($environmentNames | Select-Object -Unique).Count -eq $environmentNames.Count)

$modules = Join-Path $Root 'infra' 'modules'
foreach ($environment in $system.environments) {
    $name = [string] $environment.name
    Test-Rule "environment $name name" ($name -cmatch '^[a-z][a-z0-9]{1,7}$') 'lowercase letters and digits, 2 to 8'
    Test-Rule "environment $name tier" (@('nonprod', 'prod') -ccontains [string] $environment.tier)
    Test-Rule "environment $name runtime identity" (@($system.azure.identities.apps | Where-Object { $_.environment -eq $name }).Count -eq 1) 'the seed creates one per planned environment; re-run it for a new name'

    # Placement: sharesAppEnvironmentWith names an earlier environment of the same tier that hosts its own apps; a moved or
    # shared placement adds a 5-character suffix to the app names (ca-<slug>-<env>-<deployable>-xxxx, at most 32).
    $index = [array]::IndexOf($environmentNames, $name)
    if ($environment.ContainsKey('sharesAppEnvironmentWith')) {
        $hostName = [string] $environment.sharesAppEnvironmentWith
        $hostEntry = @($system.environments | Where-Object { $_.name -eq $hostName })[0]
        Test-Rule "environment $name shares $hostName" ($null -ne $hostEntry -and [array]::IndexOf($environmentNames, $hostName) -lt $index -and $hostEntry.tier -eq $environment.tier -and -not $hostEntry.ContainsKey('sharesAppEnvironmentWith') -and -not $environment.ContainsKey('appLocation')) 'an earlier environment of the same tier that hosts its own apps; no appLocation of its own'
    }
    if ($environment.ContainsKey('sharesAppEnvironmentWith') -or $environment.ContainsKey('appLocation')) {
        foreach ($deployableName in $deployableNames) {
            Test-Rule "environment $name app name length ($deployableName)" (("ca-$slug-$name-$deployableName-xxxx").Length -le 32) 'slug, environment and deployable too long for a suffixed container app name (32 characters)'
        }
    }

    # A standby region (the App Service apps a second time, behind the environment's Front Door endpoint) and the
    # capability "frontdoor" (an endpoint in the system's profile, azure.frontDoor).
    if ($environment.ContainsKey('standbyLocation')) {
        $standby = [string] $environment.standbyLocation
        $appServiceNames = @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' } | ForEach-Object { [string] $_.name })
        Test-Rule "environment $name standby region" ($standby -cmatch '^[a-z0-9]+$' -and $standby -cne [string] $system.system.location -and $appServiceNames.Count -gt 0 -and @($environment.capabilities) -contains 'frontdoor') 'an Azure region other than system.location, with an App Service deployable and capability frontdoor (only the Front Door endpoint sends traffic to the standby)'
        foreach ($deployableName in $appServiceNames) {
            Test-Rule "environment $name standby app name length ($deployableName)" (("app-$slug-$name-$deployableName-$standby").Length -le 60) 'slug, environment, deployable and region too long for a web app name (60 characters)'
        }
    }
    if (@($environment.capabilities) -contains 'frontdoor') {
        Test-Rule "environment $name Front Door profile" ($system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor['profile'] -and $system.azure.frontDoor['resourceGroup']) 'capability frontdoor needs azure.frontDoor { resourceGroup, profile } (the seed creates the profile)'
    }

    # Demo data, optional: user name -> middle name for the system step "Set employee middle names";
    # dbo.Employee.MiddleName holds at most 100 characters.
    if ($environment.ContainsKey('employeeMiddleNames')) {
        $middleNames = $environment.employeeMiddleNames
        $valid = $middleNames -is [Collections.IDictionary] -and @($middleNames.GetEnumerator() | Where-Object {
                [string]::IsNullOrWhiteSpace($_.Key) -or $_.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($_.Value) -or $_.Value.Length -gt 100
            }).Count -eq 0
        Test-Rule "environment $name employee middle names" $valid 'an object of user name to middle name, 1 to 100 characters each'
    }

    foreach ($capability in @($environment.capabilities)) {
        $known = $capability -eq 'baseline' -or (Test-Path -LiteralPath (Join-Path $modules "$capability.bicep"))
        Test-Rule "environment $name capability $capability" $known "no module infra/modules/$capability.bicep"
    }

    $versionsFile = Join-Path $Root 'environments' $name 'versions.json'
    if (-not (Test-Path -LiteralPath $versionsFile)) {
        Test-Rule "environment $name versions.json" $false "missing $versionsFile (start it as {})"
        continue
    }
    $versions = Get-Content -LiteralPath $versionsFile -Raw | ConvertFrom-Json -AsHashtable
    $unknown = @($versions.Keys | Where-Object { $deployableNames -notcontains $_ })
    Test-Rule "environment $name versions.json keys" ($unknown.Count -eq 0) "unknown deployables: $($unknown -join ', ')"
    # A deployable with "environments" exists only there: another environment cannot pin a version of it.
    $elsewhere = @($system.deployables | Where-Object { $_.ContainsKey('environments') -and $_.environments -is [array] -and $_.environments -cnotcontains $name -and $versions.ContainsKey([string] $_.name) } | ForEach-Object { [string] $_.name })
    if ($elsewhere.Count -gt 0) { Test-Rule "environment $name versions.json pins only its own deployables" $false "$($elsewhere -join ', ') do not exist in $name (deployables[].environments)" }
}

# Optional: the size of a tier's App Service plan, { "<tier>": "F1" | "B1" } (F1, the Free plan, when left out).
if ($system.system.ContainsKey('planSku')) {
    $sizes = $system.system.planSku
    $valid = $sizes -is [Collections.IDictionary] -and @($sizes.GetEnumerator() | Where-Object { @('nonprod', 'prod') -cnotcontains $_.Key -or @('F1', 'B1') -cnotcontains $_.Value }).Count -eq 0
    Test-Rule 'system.planSku' $valid 'an object of tier (nonprod, prod) to F1 or B1'
}

if ($system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor.ContainsKey('dormant')) {
    Test-Rule 'azure.frontDoor.dormant' ($system.azure.frontDoor.dormant -is [bool]) 'true or false (set-demo-frontdoor.ps1 writes it)'
}

foreach ($folder in Get-ChildItem -Path (Join-Path $Root 'environments') -Directory) {
    Test-Rule "folder environments/$($folder.Name) is declared" ($environmentNames -contains $folder.Name) 'add it to system.json or remove the folder'
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed."
    exit 1
}
Write-Host 'All system checks passed.'
