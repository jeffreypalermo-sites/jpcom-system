#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves the capabilities of this system: one read-only check per capability, against GitHub, Octopus and Azure.

.DESCRIPTION
    The nightly workflow "capabilities" runs it as the system's own identities (environment "capabilities": the plan
    identity in Azure, the system's service account in Octopus); the operator runs the same file through the kit's
    test-capabilities.ps1. It changes nothing. Each check names the capability it proves (CAP-NNN in the kit's
    docs/capabilities.md); a failed check fails the run, and the workflow opens an issue labelled "capability".

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login). GitHub: gh
    with GH_TOKEN or its own login. Azure: the current az login.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Only = @(),
    [switch] $ListChecks,
    # Only wait until no Octopus task runs, then stop (the workflow waits before it signs in to Azure; see capabilities.yml).
    [switch] $WaitOnly,
    [int] $WaitMinutes = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

# pwsh -File passes "CAP-001,CAP-002" as one string.
$Only = @($Only | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if (-not $ListChecks) {
    $system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
    $slug = [string] $system.system.slug
    $org = [string] $system.system.githubOrg
    $systemRepo = "$org/$($system.system.repository)"
    $deployable = [string] $system.deployables[0].name
    $appRepo = "$org/$($system.deployables[0].repository)"
    $systemProject = "$slug-system"
    $deployableProject = "$slug-$deployable"
    $space = [string] $system.octopus.spaceId
    $environments = @($system.environments | ForEach-Object { [string] $_.name })
    $first = $environments[0]
    # The first app runs as a container app, or on App Service (deployables[].hosting "appservice"): the checks of
    # the artifact, the size, the idle cost and the placement ask the hosting it has.
    $onAppService = $system.deployables[0]['hosting'] -eq 'appservice'
    # ... or brings its own runtime (hosting "own"): the system's infra/ creates nothing for it, so the checks of what
    # the stack creates for the first app do not apply; its release's package and its own verify step answer for it.
    $ownRuntime = $system.deployables[0]['hosting'] -eq 'own'
}

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Invoke-Octopus([string] $Path) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$($system.octopus.url)$Path" -Headers $headers
}
function Get-RepoFile([string] $Repo, [string] $Path) {
    $content = gh api "repos/$Repo/contents/$Path" --jq .content
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($content -join '') -replace '\s', '')))
}
function Get-RequiredCheck([string] $Repo) {
    $id = gh api "repos/$Repo/rulesets" --jq '.[] | select(.name=="default-branch") | .id'
    @(gh api "repos/$Repo/rulesets/$id" --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context')
}
function Get-Project([string] $Slug) { Invoke-Octopus "/api/$space/projects/$Slug" }
function Get-ProcessStep([string] $Slug) { @((Invoke-Octopus "/api/$space/projects/$((Get-Project $Slug).Id)/deploymentprocesses").Steps) }
function Get-EnvironmentId([string] $Name) { @((Invoke-Octopus "/api/$space/environments?partialName=$Name&take=100").Items | Where-Object Name -eq $Name)[0].Id }
# A capability whose precondition does not exist yet (no app deployment, no prod-tier environment, a runbook not due
# yet) is skipped with the reason, not failed: a new system's first builds run every check. Only facts skip a check;
# once the precondition exists, the check proves or fails.
class CheckSkipped : System.Exception {
    CheckSkipped([string] $Message) : base($Message) {}
}
function Skip-Check([string] $Reason) { throw [CheckSkipped]::new($Reason) }
function Find-LastDeployment([string] $Slug, [string] $Environment) {
    # The latest successful deployment of a project to an environment, or $null when there is none yet.
    $project = Get-Project $Slug
    $deployment = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $Environment)&take=10").Items |
            Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' }) | Select-Object -First 1
    if (-not $deployment) { return $null }
    $deployment | Add-Member -NotePropertyName Log -NotePropertyValue (Invoke-Octopus "/api/tasks/$($deployment.TaskId)/raw") -PassThru |
        Add-Member -NotePropertyName Version -NotePropertyValue (Invoke-Octopus "/api/$space/releases/$($deployment.ReleaseId)").Version -PassThru
}
function Get-LastDeployment([string] $Slug, [string] $Environment) {
    $deployment = Find-LastDeployment $Slug $Environment
    if (-not $deployment) { Skip-Check "no successful $Slug deployment in $Environment yet" }
    $deployment
}
function Get-ProdEnvironment {
    $prod = @($environments | Where-Object { (Get-Group $_) -eq $system.azure.resourceGroups.prod })
    if ($prod.Count -eq 0) { Skip-Check 'no prod-tier environment yet' }
    $prod
}
function Assert-AppRepository {
    $PSNativeCommandUseErrorActionPreference = $false
    gh api "repos/$appRepo" --jq .id *> $null
    $exists = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $exists) { Skip-Check "app repository $appRepo does not exist yet" }
}
# A system without a database (no app uses one: an app of the person's own, app.source "repository") has nothing to
# migrate, restore or rotate, and a first app without an acceptance-test package runs its tests in its own Build. Those
# are facts of the system's design: their checks say so instead of failing.
function Assert-Database {
    $uses = @($system.deployables | Where-Object {
            $hosting = if ($_.ContainsKey('hosting')) { [string] $_.hosting } else { 'containerapp' }
            ($hosting -eq 'containerapp' -and -not ($_.ContainsKey('database') -and $_.database -eq $false)) -or $hosting -eq 'appservice'
        })
    if ($uses.Count -eq 0) { Skip-Check 'the system has no database: no app uses one' }
}
function Assert-AcceptanceTestPackage {
    if (-not $system.deployables[0]['acceptanceTestsPackage']) { Skip-Check "$deployable has no acceptance-test package: it runs its tests in its own Build" }
}
function Get-SystemAge {
    # Days since the system's first release: a runbook on a schedule cannot have run before its first due date.
    $project = Get-Project $systemProject
    $releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?take=1000").Items)
    if ($releases.Count -eq 0) { return 0 }
    ([datetimeoffset]::UtcNow - [datetimeoffset] $releases[-1].Assembled).TotalDays
}
function Get-NoisyDeployment {
    # No broken windows: the deployment each environment runs now, per project, logged no Error or Warning line and did
    # not end SuccessWithWarning. Current deployments rather than the last N: a fixed warning stops counting once the
    # environment is redeployed, without deployments made only to push it out of a window.
    foreach ($project in $systemProject, $deployableProject) {
        foreach ($e in $environments) {
            $deployment = Find-LastDeployment $project $e
            if (-not $deployment) { continue }
            $details = Invoke-Octopus "/api/tasks/$($deployment.TaskId)/details?verbose=false"
            $warned = @($details.ActivityLogs[0].Children | Where-Object { $_.Status -eq 'SuccessWithWarning' })
            $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match '^\S+\s+(Error|Warning)\s+\|' })
            if ($warned.Count -gt 0 -or $lines.Count -gt 0) { "$project $($deployment.Version) in $e" }
        }
    }
}
function Get-Group([string] $Environment) {
    $tier = @($system.environments | Where-Object name -eq $Environment)[0].tier
    [string] $system.azure.resourceGroups[$tier]
}
function Get-App([string] $Environment) {
    if ($ownRuntime) { Skip-Check "$deployable brings its own runtime: the system creates no app for it to inspect" }
    # By the name the stack reports: a shared or moved Container Apps environment gives the app a suffix.
    $name = ([string] (az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.deployables.value[?name=='$deployable'].containerApp | [0]" --output tsv)).Trim()
    if (-not $name) { throw "stack-$slug-$Environment lists no container app for $deployable (a failed or unfinished apply?)" }
    az containerapp show --name $name --resource-group (Get-Group $Environment) --output json | ConvertFrom-Json -AsHashtable
}
function Get-ContainerApp([string] $Environment) {
    # Every container app of the environment, by the names the stack reports, each with the deployable it runs.
    $entries = az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query 'outputs.deployables.value[?containerApp].{name: name, app: containerApp}' --output json | ConvertFrom-Json -AsHashtable
    foreach ($entry in @($entries)) {
        $app = az containerapp show --name $entry.app --resource-group (Get-Group $Environment) --output json | ConvertFrom-Json -AsHashtable
        $app.deployable = [string] $entry.name
        $app
    }
}
function Get-Site([string] $Environment) {
    # The App Service web app of the first deployable, by the name the stack reports, with its plan's SKU.
    $entry = az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.deployables.value[?name=='$deployable'] | [0]" --output json | ConvertFrom-Json -AsHashtable
    if (-not $entry -or -not $entry['webApp']) { throw "stack-$slug-$Environment lists no web app for $deployable (a failed or unfinished apply?)" }
    # As plain resources: az webapp show also asks for the site's publishing profile, which a reader may not have and
    # the stack's deny settings refuse.
    $site = az resource show --name $entry.webApp --resource-group (Get-Group $Environment) --resource-type Microsoft.Web/sites --query '{name: name, location: location, plan: properties.serverFarmId}' --output json | ConvertFrom-Json -AsHashtable
    $site.url = [string] $entry.url
    $site.sku = az resource show --ids $site.plan --query '{name: sku.name, tier: sku.tier}' --output json | ConvertFrom-Json -AsHashtable
    $site
}
function Get-DeployedPackage([string] $Environment) {
    # The version of the app package (the zip in the Octopus built-in feed) the environment's current release deploys.
    $deployment = Get-LastDeployment $deployableProject $Environment
    $release = Invoke-Octopus "/api/$space/releases/$($deployment.ReleaseId)"
    # A release made before the deployable had a package (it changed to hosting "own" later) selects none.
    $package = @($release.SelectedPackages | Where-Object { $_.ActionName -eq 'Update deployable' }) | Select-Object -First 1
    @{ release = [string] $release.Version; package = if ($package) { [string] $package.Version } else { '' } }
}
function Get-DeclaredPlan([string] $Environment) {
    # The plan size system.json declares for the environment's tier: system.planSku, F1 without it, and F1 for every
    # tier while the system is dormant (azure.frontDoor.dormant).
    $tier = [string] @($system.environments | Where-Object name -eq $Environment)[0].tier
    $dormant = $system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor['dormant']
    if (-not $dormant -and $system.system.ContainsKey('planSku') -and $system.system.planSku[$tier]) { return [string] $system.system.planSku[$tier] }
    'F1'
}
function Get-RoleName([string] $Group, [string] $PrincipalId) {
    # Assignments at, above and below the group that name the principal; role names from their definitions.
    $subscription = [string] $system.azure.subscriptionId
    $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$PrincipalId')"
    foreach ($assignment in @((az rest --method get --url $uri --output json | ConvertFrom-Json -AsHashtable).value)) {
        $definition = ($assignment.properties.roleDefinitionId -split '/')[-1]
        [string] (az rest --method get --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleDefinitions/$($definition)?api-version=2022-04-01" --query properties.roleName --output tsv)
    }
}
function Get-RecentRun([string] $Runbook, [int] $Days) {
    $runs = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&take=100").Items |
            Where-Object { $_.Description -like "*$Runbook*" -and $_.State -eq 'Success' -and [datetimeoffset] $_.CompletedTime -gt [datetimeoffset]::UtcNow.AddDays(-$Days) })
    if ($runs.Count -eq 0 -and (Get-SystemAge) -lt $Days) { Skip-Check "the system is younger than $Days days: $Runbook is not due yet" }
    $runs
}
function Assert-That([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$checks = [ordered] @{
    'CAP-001' = { $rules = gh api "repos/$systemRepo/rulesets" --jq '[.[] | select(.name=="default-branch" and .enforcement=="active")] | length'; Assert-That ([int] $rules -eq 1) 'no active default-branch ruleset'; 'ruleset default-branch active' }
    'CAP-002' = { Assert-That ((Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'preview-environment\.ps1') 'env-checks has no preview'; 'env-checks previews every environment' }
    'CAP-003' = { Assert-AppRepository; $s = Get-RequiredCheck $systemRepo; $a = Get-RequiredCheck $appRepo; Assert-That ($s -contains 'env-checks' -and $a -contains 'Build result') "required: $s / $a"; "system: $($s -join ', '); app: $($a -join ', ')" }
    'CAP-004' = {
        $checked = @(foreach ($e in $environments) {
                $deployment = Find-LastDeployment $deployableProject $e
                if (-not $deployment) { continue }
                $pinned = (Get-RepoFile $systemRepo "environments/$e/versions.json" | ConvertFrom-Json -AsHashtable)[$deployable]
                Assert-That ($pinned -eq $deployment.Version) "$e pins $pinned, Octopus deployed $($deployment.Version)"
                $e
            })
        if ($checked.Count -eq 0) { Skip-Check "no successful $deployableProject deployment yet" }
        "versions.json equals the deployed release in $($checked -join ', ')"
    }
    'CAP-005' = { $step = @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Revert pin'); Assert-That ($step.Count -eq 1 -and $step[0].Condition -eq 'Failure') 'no Revert pin on failure'; 'Revert pin runs on failure' }
    'CAP-010' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'Build result') 'Build result not required'; 'Build result required on the app' }
    'CAP-011' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the current deployment of every project and environment logged no warning or error' }
    'CAP-012' = { Assert-That ((Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'head\.repo\.full_name == github\.repository') 'preview runs for forks'; 'the credentialed preview runs only for branches of the repository' }
    'CAP-013' = {
        $v = (Get-LastDeployment $deployableProject $first).Version
        if ($ownRuntime) {
            # The release's package (the application's deploy and verify code) carries the release's number; the
            # application's own verify step compares it with what runs.
            Assert-That ((Get-DeployedPackage $first).package -eq $v) "release $v deploys package $((Get-DeployedPackage $first).package)"
            return "release $v = package version in $first; $deployable verifies the running version itself"
        }
        if ($onAppService) {
            # The build stamps the version into the app, which reports it; the release's package carries the same number.
            $running = [string] (Invoke-RestMethod -Uri "$((Get-Site $first).url)/_version" -TimeoutSec 120).version
            Assert-That ($running -eq $v -or $running.StartsWith("$v+")) "$first runs $running for release $v"
            Assert-That ((Get-DeployedPackage $first).package -eq $v) "release $v deploys package $((Get-DeployedPackage $first).package)"
            return "release $v = package version = the version the app reports in $first"
        }
        $image = [string] (Get-App $first).properties.template.containers[0].image; Assert-That ($image.EndsWith(":$v")) "$first runs $image for release $v"; "release $v = image tag in $first"
    }
    'CAP-014' = {
        $files = @(gh api "repos/$systemRepo/contents/scripts" --jq '.[].name' | Where-Object { $_ -like '*.ps1' })
        foreach ($f in $files) { $t = Get-RepoFile $systemRepo "scripts/$f"; Assert-That ($t -match "ErrorActionPreference = 'Stop'" -and $t -match 'PSNativeCommandUseErrorActionPreference = \$true') "$f lacks the preamble" }
        "$($files.Count) step scripts stop on errors"
    }
    'CAP-020' = {
        if ($onAppService -or $ownRuntime) {
            # One zip per version in the built-in feed; every environment's release deploys the package of its own number.
            $shown = foreach ($e in $environments) {
                if (-not (Find-LastDeployment $deployableProject $e)) { continue }
                $p = Get-DeployedPackage $e
                # An environment still on a release from before the application brought its runtime has no package yet.
                if ($ownRuntime -and -not $p.package) { "$e $($p.release) (released before $deployable had a package)"; continue }
                Assert-That ($p.release -eq $p.package) "$e runs release $($p.release) with package $($p.package)"
                "$e $($p.package)"
            }
            if (-not $shown) { Skip-Check "no successful $deployableProject deployment yet" }
            return "one package per version: $($shown -join ', ')"
        }
        $byVersion = @{}
        foreach ($e in $environments) { $img = [string] (Get-App $e).properties.template.containers[0].image; $v = $img.Split(':')[-1]; if ($byVersion.ContainsKey($v)) { Assert-That ($byVersion[$v] -eq $img) "$v differs: $($byVersion[$v]) / $img" } else { $byVersion[$v] = $img } }
        "one image per version across $($environments -join ', ')"
    }
    'CAP-021' = {
        if ($onAppService -or $ownRuntime) {
            # The package feed keeps the first upload of a version: the release workflow pushes with IgnoreIfExists only.
            Assert-AppRepository
            $modes = @([regex]::Matches((Get-RepoFile $appRepo '.github/workflows/release.yml'), 'overwrite_mode:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
            Assert-That ($modes.Count -gt 0 -and @($modes | Where-Object { $_ -ne 'IgnoreIfExists' }).Count -eq 0) "release.yml pushes with $($modes -join ', ')"
            return "release.yml never replaces a pushed package ($($modes.Count) pushes, IgnoreIfExists)"
        }
        $v = (Get-LastDeployment $deployableProject $first).Version; $w = az acr repository show --name $system.azure.registry.name --image "$($slug)/${deployable}:$v" --query 'changeableAttributes.writeEnabled' --output tsv; Assert-That ($w -eq 'false') "$v is writable"; "$($slug)/${deployable}:$v is write-locked"
    }
    'CAP-030' = { $l = @((Invoke-Octopus "/api/$space/lifecycles?partialName=$($slug)-lifecycle&take=100").Items | Where-Object { $_.Name -eq "$($slug)-lifecycle" })[0]; Assert-That (@($l.Phases[0].AutomaticDeploymentTargets).Count -eq 1 -and @($l.Phases | Select-Object -Skip 1 | Where-Object { $_.AutomaticDeploymentTargets.Count -gt 0 }).Count -eq 0) 'lifecycle phases wrong'; "first phase automatic, $($l.Phases.Count - 1) by promotion" }
    'CAP-031' = { foreach ($e in $environments) { Assert-That ([bool] (Get-EnvironmentId $e)) "$e missing in Octopus"; az stack group show --name "stack-$($slug)-$e" --resource-group (Get-Group $e) --query name --output tsv | Out-Null }; "$($environments.Count) environments in Octopus and Azure" }
    'CAP-032' = { foreach ($e in $environments) { $st = az stack group show --name "stack-$($slug)-$e" --resource-group (Get-Group $e) --query '{p: provisioningState, d: denySettings.mode}' --output json | ConvertFrom-Json; Assert-That ($st.p -eq 'succeeded' -and $st.d -eq 'denyWriteAndDelete') "$e stack $($st.p) $($st.d)" }; 'every stack succeeded, deny write and delete' }
    'CAP-033' = {
        if ($onAppService) {
            # App Service: every environment's app runs on its tier's plan, of the size system.json declares (F1 without).
            $sizes = foreach ($e in $environments) { $want = Get-DeclaredPlan $e; $s = Get-Site $e; Assert-That ($s.sku.name -eq $want) "$e runs on $($s.sku.name), system.json declares $want"; "$e $want" }
            return "every app runs on the plan size system.json declares ($($sizes -join ', '))"
        }
        foreach ($entry in $system.environments) { $want = if ($entry.ContainsKey('appCpu')) { [double] $entry.appCpu } else { 0.5 }; $got = [double] (Get-App $entry.name).properties.template.containers[0].resources.cpu; Assert-That ($want -eq $got) "$($entry.name) has $got vCPU, system.json $want" }; 'app sizes follow system.json'
    }
    'CAP-034' = { Assert-Database; $n = @(Get-ProcessStep $deployableProject | ForEach-Object Name); Assert-That ($n.IndexOf('Migrate database') -lt $n.IndexOf('Update deployable')) 'Update before Migrate'; 'Migrate database before Update deployable' }
    'CAP-035' = { foreach ($f in 'update-deployable.ps1', 'verify-environment.ps1') { Assert-That ((Get-RepoFile $systemRepo "scripts/$f") -match 'Get-RevisionProblem') "$f does not fail fast" }; 'Update and Verify fail fast on a revision that cannot start' }
    'CAP-036' = { Assert-That (@(Get-ProcessStep $systemProject | Where-Object Name -eq 'Verify environment').Count -eq 1 -and @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Verify deployable').Count -eq 1) 'a verify step is missing'; 'both projects end with a verify step' }
    'CAP-037' = {
        $project = Get-Project $deployableProject
        $versions = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $first)&take=30").Items |
                Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' } |
                ForEach-Object { [version] (Invoke-Octopus "/api/$space/releases/$($_.ReleaseId)").Version })
        if (@($versions | Select-Object -Unique).Count -lt 2) { Skip-Check "fewer than two releases deployed in $first" }
        $rolledBack = $false; for ($i = 0; $i -lt $versions.Count - 1; $i++) { if ($versions[$i] -lt $versions[$i + 1]) { $rolledBack = $true } }
        Assert-That $rolledBack "no successful redeployment of an older release in $first"; "an older release was redeployed successfully in $first (test-rollback.ps1)"
    }
    'CAP-038' = {
        # The sign-off step is in the process from the start (it excludes the first environment), so a release made
        # while the system had one environment still stops at it in every environment added later. Its responsible
        # team is "<slug> approvers" (octopus/approvers.tf: the people of system.json octopus.approvers and the operator).
        $teamName = "$slug approvers"
        $team = @((Invoke-Octopus "/api/$space/teams?partialName=$([uri]::EscapeDataString($teamName))&take=100").Items | Where-Object { $_.Name -eq $teamName -and $_.SpaceId -eq $space }) | Select-Object -First 1
        Assert-That ($null -ne $team) "no team '$teamName' in the space"
        foreach ($project in $systemProject, $deployableProject) {
            $s = @(Get-ProcessStep $project)[0]
            Assert-That ($s.Name -eq 'Sign-off' -and $s.Actions[0].ActionType -eq 'Octopus.Manual') "$project does not start with Sign-off"
            $responsible = $s.Actions[0].Properties.PSObject.Properties['Octopus.Action.Manual.ResponsibleTeamIds']
            $responsibleIds = if ($responsible) { [string] $responsible.Value } else { '' }
            Assert-That ($responsibleIds -eq $team.Id) "the Sign-off of $project is for '$responsibleIds', not for team '$teamName' ($($team.Id))"
        }
        Assert-That ((Get-RepoFile $systemRepo 'octopus/projects.tf') -match 'octopusdeploy_project_deployment_freeze') 'no freeze support'; "Sign-off first in both projects, for team '$teamName'; freezes from system.json"
    }
    'CAP-039' = {
        if ($onAppService) {
            # Free plans cost nothing; a tier may declare a Basic plan (system.planSku), which the dormant switch turns
            # back to Free between classes. Either way no plan is larger than declared.
            $paid = foreach ($e in $environments) { $want = Get-DeclaredPlan $e; $s = Get-Site $e; Assert-That ($s.sku.name -eq $want) "$e runs on $($s.sku.name), system.json declares $want"; if ($want -ne 'F1') { $e } }
            if ($paid) { return "Free plans, except the declared Basic plan of $($paid -join ', '), which is Free while the system is dormant" }
            return 'every app runs on a Free plan'
        }
        if ($ownRuntime -and @($system.deployables).Count -eq 1) { Skip-Check "$deployable brings its own runtime: the system creates no app whose idle cost it could declare" }
        # Every container app scales to zero, except a deployable that system.json declares always on ("alwaysOn":
        # true: a background service), which keeps exactly one replica: a declared cost, not an accident.
        $alwaysOn = @($system.deployables | Where-Object { $_['alwaysOn'] -eq $true } | ForEach-Object { [string] $_.name })
        foreach ($e in $environments) {
            foreach ($a in @(Get-ContainerApp $e)) {
                $want = if ($alwaysOn -contains $a.deployable) { 1 } else { 0 }
                Assert-That ($a.properties.template.scale.minReplicas -eq $want) "$($a.name) in $e has min replicas $($a.properties.template.scale.minReplicas); system.json declares $want"
            }
        }
        if ($alwaysOn.Count -gt 0) { "every app scales to zero, except the declared always-on $($alwaysOn -join ', ') (one replica)" } else { 'every app scales to zero' }
    }
    'CAP-040' = { Assert-AcceptanceTestPackage; $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'Acceptance tests passed') "the last deployment to $first ran no passing acceptance tests"; "$($d.Version) passed the acceptance tests in $first" }
    'CAP-041' = { Assert-AcceptanceTestPackage; $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'test data was reloaded') 'no ZDataLoader'; "test data reloaded after $($d.Version)" }
    'CAP-042' = { Assert-AcceptanceTestPackage; $d = Get-LastDeployment $deployableProject $first; $m = [regex]::Match($d.Log, 'effective parallelism ([\d.]+)'); Assert-That $m.Success 'no parallelism reported'; "effective parallelism $($m.Groups[1].Value)" }
    'CAP-043' = { Assert-AcceptanceTestPackage; $d = Get-LastDeployment $deployableProject $first; $a = @((Invoke-Octopus "/api/$space/artifacts?regarding=$($d.TaskId)").Items | Where-Object Filename -like '*.trx'); Assert-That ($a.Count -ge 1) 'no TRX artifact'; "$($a[0].Filename)" }
    'CAP-044' = {
        # Every current deployment that ran the availability probe logged no downtime.
        $measured = 0
        foreach ($project in $systemProject, $deployableProject) {
            foreach ($e in $environments) {
                $deployment = Find-LastDeployment $project $e
                if (-not $deployment) { continue }
                $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match 'Availability of ' })
                if ($lines.Count -eq 0) { continue }
                $down = @($lines | Where-Object { $_ -match 'downtime period' })
                if ($down.Count -gt 0) { throw "$project $($deployment.Version) in ${e}: $($down[0])" }
                $measured++
            }
        }
        if ($measured -eq 0) { Skip-Check 'no current deployment has run the availability probe yet' }
        "$measured current deployments measured, no downtime"
    }
    'CAP-045' = {
        # Every environment's apps run where system.json places them: region and Container Apps environment.
        if ($onAppService) {
            foreach ($e in $environments) { $actual = (([string] (Get-Site $e).location) -replace '\s', '').ToLowerInvariant(); Assert-That ($actual -eq [string] $system.system.location) "$e runs in $actual; system.json places it in $($system.system.location)" }
            return "every environment's apps run where system.json places them"
        }
        # azure.appEnvironment: the system owns one Container Apps environment, and every environment runs there.
        if ($system.azure.ContainsKey('appEnvironment')) {
            $owned = $system.azure.appEnvironment
            foreach ($e in $environments) {
                $app = Get-App $e
                Assert-That ([string] $app.properties.environmentId -eq [string] $owned.id) "$e runs in $($app.properties.environmentId); system.json places it in $($owned.id)"
                $actual = (([string] $app.location) -replace '\s', '').ToLowerInvariant()
                Assert-That ($actual -eq [string] $owned.location) "$e runs in $($app.location); the system's Container Apps environment is in $($owned.location)"
            }
            return "every environment's apps run in the system's Container Apps environment $($owned.name)"
        }
        foreach ($entry in $system.environments) {
            $e = [string] $entry.name
            $app = Get-App $e
            $hostName = if ($entry.ContainsKey('sharesAppEnvironmentWith')) { [string] $entry.sharesAppEnvironmentWith } else { $e }
            $hostEntry = @($system.environments | Where-Object { $_.name -eq $hostName })[0]
            $region = if ($hostEntry.ContainsKey('appLocation')) { [string] $hostEntry.appLocation } else { [string] $system.system.location }
            $actual = (([string] $app.location) -replace '\s', '').ToLowerInvariant()
            Assert-That ($actual -eq $region) "$e runs in $($app.location); system.json places it in $region"
            $managed = ([string] $app.properties.environmentId -split '/')[-1]
            Assert-That ($managed -like "cae-$slug-$hostName*") "$e runs in $managed; system.json places it in the Container Apps environment of $hostName"
        }
        "every environment's apps run where system.json places them"
    }
    'CAP-046' = {
        # One public address per environment with capability frontdoor: its Front Door endpoint answers, its stack is
        # protected, and its origins are exactly the apps the environment's stack reports (primary and standby).
        $on = @($system.environments | Where-Object { @($_.capabilities) -contains 'frontdoor' } | ForEach-Object { [string] $_.name })
        if ($on.Count -eq 0) { Skip-Check 'no environment has capability frontdoor yet' }
        if ($system.azure.frontDoor['dormant']) { Skip-Check 'Front Door is dormant (azure.frontDoor.dormant): the profile is removed between classes' }
        $edge = [string] $system.azure.frontDoor.resourceGroup
        $shown = foreach ($e in $on) {
            $st = az stack group show --name "stack-$slug-$e-edge" --resource-group $edge --query '{p: provisioningState, d: denySettings.mode, endpoints: outputs.endpoints.value}' --output json | ConvertFrom-Json -AsHashtable
            Assert-That ($st.p -eq 'succeeded' -and $st.d -eq 'denyWriteAndDelete') "$e edge stack $($st.p) $($st.d)"
            $apps = az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query '{primary: outputs.deployables.value, standby: outputs.standby.value}' --output json | ConvertFrom-Json -AsHashtable
            # Before the first app release the app has no liveness path yet: the default page answers on /.
            $path = if (Find-LastDeployment $deployableProject $e) { $null } else { '/' }
            foreach ($endpoint in @($st.endpoints)) {
                $want = @(@($apps.primary) + @($apps.standby) | Where-Object { $_ -and $_.name -eq $endpoint.name } | ForEach-Object { ([uri] [string] $_.url).Host } | Sort-Object)
                $got = @(@($endpoint.origins) | ForEach-Object { [string] $_.hostName } | Sort-Object)
                Assert-That (($want -join ',') -eq ($got -join ',')) "$e $($endpoint.name): origins $($got -join ', '), apps $($want -join ', ')"
                $uri = "$($endpoint.url)$($path ?? [string] $endpoint.probePath)"
                $status = [int] (Invoke-WebRequest -Uri $uri -TimeoutSec 120 -SkipHttpErrorCheck).StatusCode
                Assert-That ($status -eq 200) "$uri answered $status"
                "$e $($endpoint.url) ($($got.Count) origin(s))"
            }
        }
        "one public address per environment: $($shown -join '; ')"
    }
    'CAP-047' = {
        # A measured failover: a "Failover test" run of the last 35 days whose log shows the public address answering
        # from the standby after the primary was stopped.
        $with = @($system.environments | Where-Object { $_.ContainsKey('standbyLocation') } | ForEach-Object { [string] $_.name })
        if ($with.Count -eq 0) { Skip-Check 'no environment has a standby region yet' }
        if ($system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor['dormant']) { Skip-Check 'Front Door is dormant (azure.frontDoor.dormant): no public address to fail over' }
        $measured = foreach ($run in @(Get-RecentRun 'Failover test' 35)) {
            $line = [regex]::Match((Invoke-Octopus "/api/tasks/$($run.Id)/raw"), 'Failover of [^\r\n]*answered from the standby[^\r\n]*').Value
            if ($line) { $line; break }
        }
        if (-not $measured -and (Get-SystemAge) -lt 35) { Skip-Check 'the system is younger than 35 days: no failover has been measured yet' }
        Assert-That ([bool] $measured) 'no measured failover in 35 days'
        [string] $measured
    }
    'CAP-051' = {
        $ids = $system.azure.identities
        $expect = @(
            @{ id = $ids.plan.principalId; role = 'Reader'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.acrPush.principalId; role = 'AcrPush'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.deploy.nonprod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.deploy.prod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.prod })
        foreach ($x in $expect) { $roles = @(Get-RoleName -Group $x.group -PrincipalId $x.id); Assert-That ($roles -contains $x.role -and $roles -notcontains 'Contributor') "$($x.id): $($roles -join ', ')" }
        'plan Reader, push AcrPush, deploy Owner of its group only'
    }
    'CAP-052' = { $prod = @(Get-ProdEnvironment); Assert-That ($prod.Count -ge 1) 'no prod-tier environment'; "$($prod -join ', ') in $($system.azure.resourceGroups.prod) with id-$($slug)-deploy-prod" }
    'CAP-053' = { $u = az account show --query user.type --output tsv; $me = Invoke-Octopus '/api/users/me'; Assert-That ($u -eq 'servicePrincipal' -and $me.IsService) "az $u, Octopus service $($me.IsService)"; "az as a service principal, Octopus as $($me.Username)" }
    'CAP-055' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'secret-scan' -and (Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'gitleaks') 'secret scanning not enforced'; 'gitleaks in env-checks and the required check secret-scan' }
    'CAP-056' = { Assert-Database; $r = Get-RecentRun 'Rotate SQL password' 35; Assert-That ($r.Count -ge 1) 'no successful rotation in 35 days'; "rotated $($r[0].CompletedTime)" }
    'CAP-057' = {
        # A secret a deployable declares (system.json deployables[].secrets) reaches its app from the environment's
        # vault by reference, as <deployable>-<name>; the app holds no secret as a stored value. The reference is read
        # by the deployable's own identity (id-<slug>-<env>-<deployable>), not by the environment's shared runtime
        # identity, which in that environment has no role on the vault as a whole and is closed to the app's code.
        # Checked wherever the deployable has been deployed.
        $with = @($system.deployables | Where-Object { @($_['secrets'] | Where-Object { $_ }).Count -gt 0 })
        if ($with.Count -eq 0) { Skip-Check 'no deployable declares secrets yet' }
        $shown = foreach ($entry in $with) {
            $name = [string] $entry.name
            foreach ($e in $environments) {
                if ($entry.ContainsKey('environments') -and @($entry.environments) -notcontains $e) { continue }
                if (-not (Find-LastDeployment "$slug-$name" $e)) { continue }
                $app = @(Get-ContainerApp $e | Where-Object { $_.deployable -eq $name })[0]
                Assert-That ($null -ne $app) "stack-$slug-$e lists no container app for $name (a failed or unfinished apply?)"
                $shared = @($system.azure.identities.apps | Where-Object { $_.environment -eq $e })[0]
                $held = @($app.properties.configuration['secrets'] | Where-Object { $_ })
                $inline = @($held | Where-Object { -not $_['keyVaultUrl'] } | ForEach-Object { [string] $_.name })
                Assert-That ($inline.Count -eq 0) "$($app.name) in $e holds $($inline -join ', ') as a stored value, not as a vault reference"
                foreach ($secret in @($entry.secrets)) {
                    $reference = @($held | Where-Object { $_.name -eq $secret.name })[0]
                    Assert-That ($null -ne $reference -and ([string] $reference['keyVaultUrl']).EndsWith("/secrets/$name-$($secret.name)") -and $reference['identity']) "$($app.name) in $e does not reference the vault secret $name-$($secret.name) for $($secret.name)"
                    Assert-That ([string] $reference.identity -like "*/userAssignedIdentities/id-$slug-$e-$name") "$($app.name) in $e reads $($secret.name) as $((([string] $reference.identity) -split '/')[-1]), not as its own identity id-$slug-$e-$name"
                    $variable = @($app.properties.template.containers[0].env | Where-Object { $_.name -eq $secret.env })[0]
                    Assert-That ($null -ne $variable -and $variable['secretRef'] -eq $secret.name) "$($app.name) in $e does not get $($secret.env) from the secret $($secret.name)"
                }
                # The shared identity pulls the image; the app's code must not be able to use it, and it must not
                # read the vault as a whole (through the ARM API of the version that knows identitySettings).
                $settings = @(az rest --method get --url "https://management.azure.com$($app.id)?api-version=2025-01-01" --query 'properties.configuration.identitySettings' --output json | ConvertFrom-Json -AsHashtable | Where-Object { $_ })
                Assert-That (@($settings | Where-Object { [string] $_.identity -like "*/userAssignedIdentities/$($shared.name)" -and $_.lifecycle -eq 'None' }).Count -eq 1) "the code of $($app.name) in $e can use the shared runtime identity $($shared.name) (no identitySettings entry with lifecycle None)"
                $vault = ([string] (az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query outputs.keyVaultName.value --output tsv)).Trim()
                $vaultId = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$(Get-Group $e)/providers/Microsoft.KeyVault/vaults/$vault"
                $wide = @(az role assignment list --scope $vaultId --query "[?principalId=='$($shared.principalId)'].roleDefinitionName" --output tsv | Where-Object { $_ })
                Assert-That ($wide.Count -eq 0) "the shared runtime identity $($shared.name) holds $($wide -join ', ') on the whole vault $vault in ${e}: it could read the secrets of $name"
                "$name in $e ($(@($entry.secrets).Count))"
            }
        }
        if (-not $shown) { Skip-Check 'no deployable that declares secrets has been deployed yet' }
        "every declared secret is a vault reference read by the deployable's own identity, out of reach of the shared runtime identity: $($shown -join ', ')"
    }
    'CAP-060' = { Assert-Database; $r = Get-RecentRun 'Restore test' 8; Assert-That ($r.Count -ge 1) 'no successful restore test in 8 days'; "restore test passed $($r[0].CompletedTime)" }
    'CAP-061' = { Assert-Database; $prod = @(Get-ProdEnvironment)[0]; $d = Get-LastDeployment $deployableProject $prod; Assert-That ($d.Log -match 'Restore point before') "no restore point in the last $prod deployment"; "restore point recorded before $($d.Version) in $prod" }
    'CAP-070' = {
        # Telemetry is proven where it lands: in every environment with the capability, the app gets the Application
        # Insights connection string, and requests under its own name (OTEL_SERVICE_NAME, <slug>-<deployable>) arrived
        # in the last 30 days through the app's OpenTelemetry SDK (Azure Monitor exporter).
        $on = @($system.environments | Where-Object { @($_.capabilities) -contains 'telemetry' } | ForEach-Object { [string] $_.name })
        if ($on.Count -eq 0) { Skip-Check 'no environment has capability telemetry yet' }
        $role = "$slug-$deployable"
        foreach ($e in $on) {
            $variables = @((Get-App $e).properties.template.containers[0].env | ForEach-Object { [string] $_.name })
            Assert-That ($variables -contains 'APPLICATIONINSIGHTS_CONNECTION_STRING') "the app in $e has no APPLICATIONINSIGHTS_CONNECTION_STRING"
            $component = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$(Get-Group $e)/providers/Microsoft.Insights/components/appi-$slug-$e"
            $body = @{ query = "requests | where cloud_RoleName == '$role' | summarize count()"; timespan = 'P30D' } | ConvertTo-Json -Compress
            $count = [int] (az rest --method post --url "https://management.azure.com$component/query?api-version=2018-04-20" --body $body --query 'tables[0].rows[0][0]' --output tsv)
            Assert-That ($count -gt 0) "no requests of $role in appi-$slug-$e in 30 days"
        }
        "requests of $role arriving in Application Insights in $($on -join ', ')"
    }
    'CAP-071' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the logs of every current deployment are clean' }
    'CAP-074' = {
        # Metrics land where telemetry does: in every environment with the capability, metrics of the app under its own
        # name (OTEL_SERVICE_NAME, <slug>-<deployable>) arrived in Application Insights in the last 30 days.
        $on = @($system.environments | Where-Object { @($_.capabilities) -contains 'telemetry' } | ForEach-Object { [string] $_.name })
        if ($on.Count -eq 0) { Skip-Check 'no environment has capability telemetry yet' }
        $role = "$slug-$deployable"
        foreach ($e in $on) {
            $component = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$(Get-Group $e)/providers/Microsoft.Insights/components/appi-$slug-$e"
            $body = @{ query = "customMetrics | where cloud_RoleName == '$role' | summarize count()"; timespan = 'P30D' } | ConvertTo-Json -Compress
            $count = [int] (az rest --method post --url "https://management.azure.com$component/query?api-version=2018-04-20" --body $body --query 'tables[0].rows[0][0]' --output tsv)
            Assert-That ($count -gt 0) "no metrics of $role in appi-$slug-$e in 30 days"
        }
        "metrics of $role arriving in Application Insights in $($on -join ', ')"
    }
    'CAP-075' = {
        # One page shows every node: the dashboard (the deployable with hosting "staticwebapp") serves the topology its
        # deployment wrote, and in every environment it runs in, that topology lists every environment of system.json
        # and, for each App Service deployable, the nodes the naming convention gives (primary, and standby where the
        # environment has a standbyLocation). A topology older than system.json fails: deploy the dashboard again.
        $dashboard = @($system.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
        if (-not $dashboard) { Skip-Check 'no deployable with hosting staticwebapp yet' }
        $dashboardName = [string] $dashboard.name
        $apps = @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' } | ForEach-Object { [string] $_.name })
        $want = @(foreach ($entry in $system.environments) {
                foreach ($app in $apps) {
                    "$($entry.name)/$app/app-$slug-$($entry.name)-$app"
                    if ($entry['standbyLocation']) { "$($entry.name)/$app/app-$slug-$($entry.name)-$app-$($entry.standbyLocation)" }
                }
            })
        $shown = foreach ($e in $environments) {
            if (-not (Find-LastDeployment "$slug-$dashboardName" $e)) { continue }
            $url = ([string] (az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query "outputs.deployables.value[?name=='$dashboardName'].url | [0]" --output tsv)).Trim()
            Assert-That ([bool] $url) "stack-$slug-$e lists no site for $dashboardName (a failed or unfinished apply?)"
            $content = (Invoke-WebRequest -Uri "$url/topology.json" -TimeoutSec 120).Content
            $topology = $(if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { [string] $content }) | ConvertFrom-Json -AsHashtable
            $listed = @($topology['environments'] | Where-Object { $_ })
            $absent = @($environments | Where-Object { @($listed | ForEach-Object { [string] $_['name'] }) -notcontains $_ })
            Assert-That ($absent.Count -eq 0) "the dashboard in $e does not list $($absent -join ', '): deploy the release of $slug-$dashboardName to $e again"
            $got = @(foreach ($entry in $listed) { foreach ($d in @($entry['deployables'] | Where-Object { $_ })) { foreach ($node in @($d['nodes'] | Where-Object { $_ })) { "$($entry['name'])/$($d['name'])/$($node['name'])" } } })
            $lost = @($want | Where-Object { $got -notcontains $_ })
            Assert-That ($lost.Count -eq 0) "the dashboard in $e does not list the node(s) $($lost -join ', '): deploy the release of $slug-$dashboardName to $e again"
            "$e $url"
        }
        if (-not $shown) { Skip-Check "no successful $slug-$dashboardName deployment yet" }
        "$($environments.Count) environment(s) and $($want.Count) node(s) on one page: $($shown -join '; ')"
    }
    'CAP-080' = { $files = @(gh api "repos/$systemRepo/contents/docs/architecture" --jq '.[].name'); $missing = @($files | Where-Object { $_ -like '*.puml' -and $files -notcontains ($_ -replace '\.puml$', '.png') }); Assert-That ($missing.Count -eq 0 -and $files.Count -gt 0) "not rendered: $missing"; "$(@($files | Where-Object { $_ -like '*.png' }).Count) diagrams rendered" }
    'CAP-081' = {
        $build = Get-RepoFile $systemRepo '.github/workflows/system.yml'; $nightly = Get-RepoFile $systemRepo '.github/workflows/capabilities.yml'
        Assert-That ($build -match 'uses: \./\.github/workflows/capabilities\.yml' -and $nightly -match 'schedule:') 'the checks do not run with every system build and nightly'
        "$($checks.Count) checks, after every system build and nightly"
    }
}


if ($ListChecks) {
    $checks.Keys
    return
}
# Checks compare Git, Octopus and Azure; in the middle of a deployment or runbook run they differ by design, so the
# run waits until the space is quiet.
$deadline = [datetimeoffset]::UtcNow.AddMinutes($WaitMinutes)
while (@((Invoke-Octopus "/api/$space/tasks?states=Executing,Queued,Cancelling&take=10").Items).Count -gt 0) {
    if ([datetimeoffset]::UtcNow -gt $deadline) {
        if ($WaitOnly) { Write-Host "Octopus is still busy after $WaitMinutes minutes; the checks wait on."; exit 0 }
        Write-Fail "the space did not become quiet in $WaitMinutes minutes"
        exit 1
    }
    Write-Host 'Waiting for running Octopus tasks to finish.'
    Start-Sleep -Seconds 60
}
if ($WaitOnly) {
    Write-Host 'Octopus is quiet.'
    exit 0
}
# @(...) around the whole if: a single -Only ID would otherwise become a string, which has no Count in strict mode.
$ids = @(if ($Only) { $Only } else { $checks.Keys })
$failed = 0
$skipped = 0
foreach ($id in $ids) {
    if (-not $checks.Contains($id)) { Write-Fail "${id}: no check"; $failed++; continue }
    try { Write-Pass "${id}: $(& $checks[$id])" }
    catch [CheckSkipped] { Write-Host "SKIP ${id}: $($_.Exception.Message)"; $skipped++ }
    catch { Write-Fail "${id}: $($_.Exception.Message)"; $failed++ }
}
$skippedNote = if ($skipped -gt 0) { " ($skipped skipped: their preconditions do not exist yet)" } else { '' }
if ($failed -gt 0) {
    Write-Host "$failed of $($ids.Count) capabilities failed$skippedNote."
    exit 1
}
Write-Host "All $($ids.Count - $skipped) checked capabilities are proven$skippedNote."
