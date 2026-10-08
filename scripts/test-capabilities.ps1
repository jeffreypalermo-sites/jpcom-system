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

    The checks compare Git, Octopus and Azure at rest. The run first waits until no Octopus task runs (-WaitMinutes).
    A deployment or runbook run that starts after that is noticed when a check fails: the run then asks Octopus once
    whether a deployment or runbook run ran since the checks began, and if so waits for the space to be quiet again
    (-AgainMinutes) and runs the failed checks once more. Only what fails then is a failure; the output names the
    checks that ran again and the task that was the reason. FAIL lines come after the last check for that reason.

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
    [int] $WaitMinutes = 90,
    # How long the failed checks wait for Octopus to become quiet again before they run once more (see the end of this
    # file). Short: the workflow's sign-ins to Azure and Octopus last an hour.
    [int] $AgainMinutes = 20
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
function Find-RepoFile([string] $Repo, [string] $Path) {
    # The text of a file on the repository's default branch, or nothing when the branch has no such file (404).
    $PSNativeCommandUseErrorActionPreference = $false
    $answer = @(gh api "repos/$Repo/contents/$Path" --jq .content 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    if ($code -eq 0) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($answer -join '') -replace '\s', ''))) }
    if (($answer -join ' ') -notmatch 'HTTP 404') { throw "cannot read $Path of ${Repo}: $($answer -join ' ')" }
}
function Find-PublicFile([string] $Repo, [string] $Path) {
    # The text of a file on main as anyone reads it: from the repository's public address, without a credential and
    # without following a redirect. Nothing when that address has none (404: no such file, or a private repository).
    # This is how the runbook "Health report" reads environments/<env>/nodes.json (scripts/report-health.ps1), and a
    # check of what the runbook asked reads the same way: gh would also read a private repository, which the
    # runbook cannot.
    $answer = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/main/$Path" -Method Get -TimeoutSec 60 -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    $status = [int] $answer.StatusCode
    if ($status -eq 404) { return }
    if ($status -ne 200) { throw "cannot read $Path of $Repo at its public address: HTTP $status" }
    if ($answer.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($answer.Content) }
    return [string] $answer.Content
}
function Get-HealthQuestion([hashtable] $System, [string[]] $Environment, [hashtable] $Recorded = @{}) {
    # Which applications that bring their own runtime the hourly health report asks, and which not, each as
    # "<deployable> in <environment>": asked where the environment's record (environments/<env>/nodes.json as the
    # runbook reads it; $Recorded: environment to that file, parsed, no entry where it reads none) has an entry for
    # the deployable that does not say "healthReport": false. It asks nothing: the same input gives the same lists.
    $own = @($System.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
    $asked = [Collections.Generic.List[string]]::new()
    $notAsked = [Collections.Generic.List[string]]::new()
    foreach ($e in $Environment) {
        $record = $Recorded[$e]
        foreach ($name in $own) {
            $entry = if ($record -is [Collections.IDictionary]) { $record[$name] } else { $null }
            if ($entry -isnot [Collections.IDictionary]) { $notAsked.Add("$name in $e (no record of nodes)") }
            elseif ($entry['healthReport'] -eq $false) { $notAsked.Add("$name in $e (its record says healthReport false)") }
            else { $asked.Add("$name in $e") }
        }
    }
    return @{ Own = $own; Asked = [string[]] $asked.ToArray(); NotAsked = [string[]] $notAsked.ToArray(); Every = $own.Count -gt 0 -and $own.Count -eq @($System.deployables).Count }
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
    $name = "$(az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.deployables.value[?name=='$deployable'].containerApp | [0]" --output tsv)".Trim()
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
function Get-StandbyPlan([string] $Environment) {
    # The plan size of the first deployable's standby app, or $null without a standby region.
    # "$(...)", not [string] (...): a command that prints nothing (no standby here) casts to $null, and .Trim() then throws.
    $webApp = "$(az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.standby.value[?name=='$deployable'].webApp | [0]" --output tsv)".Trim()
    if (-not $webApp) { return $null }
    $plan = ([string] (az resource show --name $webApp --resource-group (Get-Group $Environment) --resource-type Microsoft.Web/sites --query properties.serverFarmId --output tsv)).Trim()
    ([string] (az resource show --ids $plan --query sku.name --output tsv)).Trim()
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
    # The runbook's own successful runs, newest first. Asked by runbook: the hourly "Health report" alone fills the
    # first page of all runbook runs within a day and a half, and a monthly run would drop out of it.
    # Into a variable first: a JSON array answer goes down a pipeline as one object, and nothing would match.
    $runbooks = Invoke-Octopus "/api/$space/runbooks/all"
    $ids = @($runbooks | Where-Object { $_.Name -eq $Runbook } | ForEach-Object { [string] $_.Id })
    $all = @(foreach ($id in $ids) { (Invoke-Octopus "/api/$space/tasks?name=RunbookRun&runbook=$id&states=Success&take=100").Items })
    $runs = @($all | Where-Object { $_ -and [datetimeoffset] $_.CompletedTime -gt [datetimeoffset]::UtcNow.AddDays(-$Days) } |
            Sort-Object { [datetimeoffset] $_.CompletedTime } -Descending)
    if ($runs.Count -eq 0 -and (Get-SystemAge) -lt $Days) { Skip-Check "the system is younger than $Days days: $Runbook is not due yet" }
    $runs
}
function Assert-That([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Get-ContainerDeployable([hashtable] $System) {
    # The names of the deployables that run as container apps the system's infra/ creates (hosting "containerapp",
    # also when left out).
    @($System.deployables | Where-Object { -not $_.ContainsKey('hosting') -or $_.hosting -eq 'containerapp' } | ForEach-Object { [string] $_.name })
}
function Get-ExpectedNode([hashtable] $System, [hashtable] $Recorded = @{}) {
    # The nodes the dashboard's topology must list, each as "<environment>/<deployable>/<node>". An App Service
    # deployable: the names the naming convention gives (primary, and standby where the environment has a
    # standbyLocation). A deployable with hosting "own": the addresses its application reported, from
    # environments/<env>/nodes.json on main ($Recorded: environment to that file, parsed; no entry where main has
    # none). It asks nothing: the same input gives the same list.
    foreach ($entry in @($System.environments)) {
        $e = [string] $entry.name
        foreach ($d in @($System.deployables)) {
            $name = [string] $d.name
            if ($d['hosting'] -eq 'appservice') {
                "$e/$name/app-$($System.system.slug)-$e-$name"
                if ($entry['standbyLocation']) { "$e/$name/app-$($System.system.slug)-$e-$name-$($entry.standbyLocation)" }
            }
            elseif ($d['hosting'] -eq 'own' -and $Recorded[$e] -is [Collections.IDictionary] -and $Recorded[$e][$name] -is [Collections.IDictionary]) {
                foreach ($node in @($Recorded[$e][$name]['nodes'] | Where-Object { $_ -is [Collections.IDictionary] })) { "$e/$name/$(([string] $node['url']).TrimEnd('/'))" }
            }
        }
    }
}
function Get-ListedNode([hashtable] $Topology) {
    # The nodes a served topology lists, in the same form: each one by its name and by its address.
    foreach ($entry in @($Topology['environments'] | Where-Object { $_ })) {
        foreach ($d in @($entry['deployables'] | Where-Object { $_ })) {
            foreach ($node in @($d['nodes'] | Where-Object { $_ })) {
                "$($entry['name'])/$($d['name'])/$($node['name'])"
                "$($entry['name'])/$($d['name'])/$(([string] $node['url']).TrimEnd('/'))"
            }
        }
    }
}

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
    'CAP-005' = {
        $steps = @(Get-ProcessStep $deployableProject)
        $step = @($steps | Where-Object Name -eq 'Revert pin')
        Assert-That ($step.Count -eq 1 -and $step[0].Condition -eq 'Failure') 'no Revert pin on failure'
        if (-not $ownRuntime) { return 'Revert pin runs on failure' }
        # An application that brings its own runtime: nothing of the system's puts the version before back, so its
        # own deploy.ps1 does, in a step of its own that stands before "Revert pin".
        $names = @($steps | ForEach-Object { [string] $_.Name })
        $revert = @($steps | Where-Object Name -eq 'Revert deployable')
        Assert-That ($revert.Count -eq 1 -and $revert[0].Condition -eq 'Failure') 'no Revert deployable on failure'
        Assert-That ($names.IndexOf('Revert deployable') -lt $names.IndexOf('Revert pin')) 'Revert deployable does not stand before Revert pin'
        # A rollback is verified like an update (decision 0018): the application's verify.ps1 right after the revert,
        # on failure only, waiting for it; then the nodes it reported, and the pin last.
        $verify = @($steps | Where-Object Name -eq 'Verify revert')
        Assert-That ($verify.Count -eq 1 -and $verify[0].Condition -eq 'Failure' -and [string] $verify[0].StartTrigger -ne 'StartWithPrevious') 'no Verify revert on failure that waits for the revert'
        Assert-That ($names.IndexOf('Verify revert') -eq $names.IndexOf('Revert deployable') + 1) 'Verify revert does not stand right after Revert deployable'
        $record = @($steps | Where-Object Name -eq 'Record nodes after revert')
        Assert-That ($record.Count -eq 1 -and $record[0].Condition -eq 'Failure') 'no Record nodes after revert on failure'
        Assert-That ($names.IndexOf('Verify revert') -lt $names.IndexOf('Record nodes after revert') -and $names.IndexOf('Record nodes after revert') -lt $names.IndexOf('Revert pin')) 'the failure steps are not in the order revert, verify, record, pin'
        'Revert deployable, Verify revert, Record nodes after revert, then Revert pin, run on failure'
    }
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
            $sizes = foreach ($e in $environments) {
                $want = Get-DeclaredPlan $e; $s = Get-Site $e; Assert-That ($s.sku.name -eq $want) "$e runs on $($s.sku.name), system.json declares $want"
                # The standby region's plan has the tier's size too: a failover must not land on a smaller plan.
                $standbyPlan = Get-StandbyPlan $e
                if ($standbyPlan) { Assert-That ($standbyPlan -eq $want) "the standby of $e runs on $standbyPlan, system.json declares $want" }
                "$e $want$(if ($standbyPlan) { ' (standby too)' })"
            }
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
        # Nothing to ask where no deployable is a container app of the system's: an application with its own runtime,
        # alone or next to the dashboard (a static site on the Free plan).
        if ($ownRuntime -and @(Get-ContainerDeployable $system).Count -eq 0) { Skip-Check "$deployable brings its own runtime, and no other deployable is a container app: the system creates no app whose idle cost it could declare" }
        # Every container app scales to zero, except a deployable that system.json declares always on ("alwaysOn":
        # true: a background service), which keeps exactly one replica: a declared cost, not an accident. With
        # "alwaysOnEnvironments" it keeps that replica in those environments only and scales to zero in the others.
        $declared = @($system.deployables | Where-Object { $_['alwaysOn'] -eq $true })
        $alwaysOn = @($declared | ForEach-Object { [string] $_.name })
        foreach ($e in $environments) {
            foreach ($a in @(Get-ContainerApp $e)) {
                $kept = @($declared | Where-Object { [string] $_.name -eq $a.deployable -and (-not $_['alwaysOnEnvironments'] -or @($_['alwaysOnEnvironments']) -ccontains $e) })
                $want = if ($kept.Count -gt 0) { 1 } else { 0 }
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
        # The push identity exists only with a registry (system.json azure.registry): a system whose apps are zips in
        # the Octopus feed has neither.
        $hasRegistry = $system.azure.ContainsKey('registry') -and $system.azure.registry['name']
        $expect = @(
            @{ id = $ids.plan.principalId; role = 'Reader'; group = $system.azure.resourceGroups.nonprod }
            if ($hasRegistry) { @{ id = $ids.acrPush.principalId; role = 'AcrPush'; group = $system.azure.resourceGroups.nonprod } }
            @{ id = $ids.deploy.nonprod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.nonprod }
            @{ id = $ids.deploy.prod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.prod })
        foreach ($x in $expect) { $roles = @(Get-RoleName -Group $x.group -PrincipalId $x.id); Assert-That ($roles -contains $x.role -and $roles -notcontains 'Contributor') "$($x.id): $($roles -join ', ')" }
        if (-not $hasRegistry) {
            Assert-That (-not $ids.ContainsKey('acrPush')) 'azure.identities.acrPush without azure.registry'
            return 'plan Reader, deploy Owner of its group only; no registry, so no push identity'
        }
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
            # A container app's settings are readable; a web app's are not (listing them is an action the reader lacks
            # and the stack denies), so on App Service the arriving requests below are the proof.
            if (-not $onAppService) {
                $variables = @((Get-App $e).properties.template.containers[0].env | ForEach-Object { [string] $_.name })
                Assert-That ($variables -contains 'APPLICATIONINSIGHTS_CONNECTION_STRING') "the app in $e has no APPLICATIONINSIGHTS_CONNECTION_STRING"
            }
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
        # and every node that is known: for each App Service deployable the nodes the naming convention gives (primary,
        # and standby where the environment has a standbyLocation), and for each deployable with hosting "own" the
        # nodes its application reported (environments/<env>/nodes.json on main). A topology older than system.json or
        # than that record fails: deploy the dashboard again.
        # Its Runtime view has, in runtime/index.json, every environment with a manifest and an SVG the site serves.
        $dashboard = @($system.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
        if (-not $dashboard) { Skip-Check 'no deployable with hosting staticwebapp yet' }
        $dashboardName = [string] $dashboard.name
        $recorded = @{}
        if (@($system.deployables | Where-Object { $_['hosting'] -eq 'own' }).Count -gt 0) {
            foreach ($e in $environments) {
                $text = Find-RepoFile $systemRepo "environments/$e/nodes.json"
                if ($text) { $recorded[$e] = $text | ConvertFrom-Json -AsHashtable }
            }
        }
        $want = @(Get-ExpectedNode $system $recorded)
        $shown = foreach ($e in $environments) {
            if (-not (Find-LastDeployment "$slug-$dashboardName" $e)) { continue }
            $url = "$(az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query "outputs.deployables.value[?name=='$dashboardName'].url | [0]" --output tsv)".Trim()
            Assert-That ([bool] $url) "stack-$slug-$e lists no site for $dashboardName (a failed or unfinished apply?)"
            $content = (Invoke-WebRequest -Uri "$url/topology.json" -TimeoutSec 120).Content
            $topology = $(if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { [string] $content }) | ConvertFrom-Json -AsHashtable
            $listed = @($topology['environments'] | Where-Object { $_ })
            $absent = @($environments | Where-Object { @($listed | ForEach-Object { [string] $_['name'] }) -notcontains $_ })
            Assert-That ($absent.Count -eq 0) "the dashboard in $e does not list $($absent -join ', '): deploy the release of $slug-$dashboardName to $e again"
            $got = @(Get-ListedNode $topology)
            $lost = @($want | Where-Object { $got -notcontains $_ })
            Assert-That ($lost.Count -eq 0) "the dashboard in $e does not list the node(s) $($lost -join ', '): deploy the release of $slug-$dashboardName to $e again"
            $content = (Invoke-WebRequest -Uri "$url/runtime/index.json" -TimeoutSec 120 -SkipHttpErrorCheck)
            Assert-That ($content.StatusCode -eq 200) "the dashboard in $e has no runtime/index.json (HTTP $($content.StatusCode)): deploy the release of $slug-$dashboardName to $e again"
            $index = $(if ($content.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content.Content) } else { [string] $content.Content }) | ConvertFrom-Json -AsHashtable
            $drawn = @($index['environments'] | Where-Object { $_ })
            $undrawn = @($environments | Where-Object { @($drawn | ForEach-Object { [string] $_['name'] }) -notcontains $_ })
            Assert-That ($undrawn.Count -eq 0) "the Runtime view in $e has no diagram of $($undrawn -join ', '): deploy the release of $slug-$dashboardName to $e again"
            foreach ($entry in $drawn) {
                foreach ($file in @([string] $entry['manifest'], [string] $entry['svg'])) {
                    $answer = Invoke-WebRequest -Uri "$url/runtime/$file" -TimeoutSec 120 -SkipHttpErrorCheck
                    Assert-That ($answer.StatusCode -eq 200 -and $answer.RawContentLength -gt 0) "the Runtime view in $e does not serve runtime/$file (HTTP $($answer.StatusCode))"
                }
            }
            "$e $url"
        }
        if (-not $shown) { Skip-Check "no successful $slug-$dashboardName deployment yet" }
        "$($environments.Count) environment(s) and $($want.Count) node(s) on one page, with a runtime diagram each: $($shown -join '; ')"
    }
    'CAP-076' = {
        # The delivery tool shows each environment's health: a "Health report" run of the last three hours succeeded
        # in every environment (the runbook is hourly, and fails when a node does not answer). The report asks the
        # nodes of the stack and, for an application that brings its own runtime (hosting "own"), the nodes it
        # recorded in environments/<env>/nodes.json on main, unless that record says "healthReport": false. One
        # without a record in an environment is not asked there. The record is read here as the runbook reads it,
        # from the repository's public address: for a private repository both read none. A system of nothing but
        # such applications, none of them asked anywhere, has no node the report asks, and its green runs prove
        # nothing about health: the check skips.
        $recorded = @{}
        if (@($system.deployables | Where-Object { $_['hosting'] -eq 'own' }).Count -gt 0) {
            foreach ($e in $environments) {
                $text = Find-PublicFile $systemRepo "environments/$e/nodes.json"
                if ($text) { $recorded[$e] = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null } }
            }
        }
        $question = Get-HealthQuestion $system $environments $recorded
        if ($question.Every -and $question.Asked.Count -eq 0) { Skip-Check "every deployable brings its own runtime ($($question.Own -join ', ')) and the health report asks none of them: $($question.NotAsked -join ', ') (environments/<env>/nodes.json on main, read from the repository's public address as the runbook reads it)" }
        if ($system.azure.ContainsKey('frontDoor') -and $system.azure.frontDoor['dormant']) { Skip-Check 'the system is dormant: the hourly health report is off so the apps and their databases can sleep' }
        $since = [datetimeoffset]::UtcNow.AddHours(-3)
        $runs = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&take=200").Items | Where-Object { $_.Description -like '*Health report*' -and [datetimeoffset] $_.QueueTime -gt $since })
        if ($runs.Count -eq 0 -and (Get-SystemAge) -lt 0.125) { Skip-Check 'the system is younger than three hours: no health report is due yet' }
        $shown = foreach ($e in $environments) {
            $last = @($runs | Where-Object { $_.Description -like "* $e" -or $_.Description -like "* $e *" }) | Sort-Object { [datetimeoffset] $_.QueueTime } -Descending | Select-Object -First 1
            Assert-That ($null -ne $last) "no Health report run in $e in three hours"
            Assert-That ($last.State -eq 'Success') "the last Health report in $e is $($last.State)"
            "$e $(([datetimeoffset] $last.QueueTime).ToString('HH:mm'))"
        }
        "the last hourly health report succeeded in $($shown -join ', ') (UTC)$(if ($question.Asked.Count -gt 0) { "; asked from its record of nodes: $($question.Asked -join ', ')" })$(if ($question.NotAsked.Count -gt 0) { "; not asked: $($question.NotAsked -join ', ')" })"
    }
    'CAP-077' = {
        # Calls are counted where they happen: every web app of an App Service deployable with a telemetryPath (primary
        # and standby, every environment) answers it with its counts of the last minute, readable from any origin, so
        # the dashboard's runtime view shows calls per minute on Front Door's routes and the database's.
        $counted = @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' -and $_['telemetryPath'] })
        if ($counted.Count -eq 0) { Skip-Check 'no App Service deployable has a telemetryPath in system.json' }
        $shown = foreach ($app in $counted) {
            foreach ($entry in $system.environments) {
                $names = @("app-$slug-$($entry.name)-$($app.name)")
                if ($entry['standbyLocation']) { $names += "app-$slug-$($entry.name)-$($app.name)-$($entry.standbyLocation)" }
                foreach ($name in $names) {
                    $answer = Invoke-WebRequest -Uri "https://$name.azurewebsites.net$($app.telemetryPath)" -Headers @{ Origin = 'https://capability-check.example' } -TimeoutSec 120 -SkipHttpErrorCheck
                    Assert-That ($answer.StatusCode -eq 200) "$name answers $($app.telemetryPath) with HTTP $($answer.StatusCode): deploy a release of $slug-$($app.name) that has the endpoint"
                    Assert-That ("$($answer.Headers['Access-Control-Allow-Origin'])" -eq '*') "$name does not allow other origins to read $($app.telemetryPath)"
                    $counts = $(if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }) | ConvertFrom-Json -AsHashtable
                    Assert-That ($counts['requests'] -is [hashtable] -and $null -ne $counts.requests['perMinute'] -and $counts['sql'] -is [hashtable]) "$name answers $($app.telemetryPath) without the counts of requests and SQL commands"
                    "$name $($counts.requests.perMinute) req/min, $($counts.sql.perMinute) SQL/min"
                }
            }
        }
        "every web app counts its calls: $($shown -join '; ')"
    }
    'CAP-078' = {
        # Delivery facts where a browser can read them: workflow delivery publishes delivery.json on branch status
        # (one commit, no commit on main), with every environment and, in each, the first app and the system project
        # at the release Octopus last deployed. A deployment of the last 90 minutes may be ahead of the file: the
        # workflow waits for the deployment that triggered it.
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'status') { Skip-Check 'workflow delivery has not published branch status yet' }
        $delivery = Get-RepoFile $systemRepo 'delivery.json?ref=status' | ConvertFrom-Json -AsHashtable
        $listed = @($delivery['environments'] | Where-Object { $_ })
        $compared = foreach ($e in $environments) {
            $entry = @($listed | Where-Object { $_['name'] -eq $e }) | Select-Object -First 1
            Assert-That ($null -ne $entry) "delivery.json on branch status does not list $e"
            foreach ($name in @($deployable, 'system')) {
                $fact = @($entry['deployables'] | Where-Object { $_ -and $_['name'] -eq $name }) | Select-Object -First 1
                Assert-That ($null -ne $fact) "delivery.json does not list $name in $e"
                $deployment = Find-LastDeployment "$slug-$(if ($name -eq 'system') { 'system' } else { $name })" $e
                if (-not $deployment) { continue }
                $settled = [datetimeoffset] (Invoke-Octopus "/api/tasks/$($deployment.TaskId)").CompletedTime -lt [datetimeoffset]::UtcNow.AddMinutes(-90)
                Assert-That (-not $settled -or [string] $fact['version'] -eq $deployment.Version) "delivery.json says $name $($fact['version']) in $e, Octopus deployed $($deployment.Version): run workflow delivery"
                "$e $name $($fact['version'])"
            }
        }
        "delivery facts on branch status: $(@($compared).Count) deployment(s) match Octopus"
    }
    'CAP-079' = {
        # Each deployed process says what it was built from: every web app of an App Service deployable with a
        # buildPath answers it, from any origin, with the version Octopus last deployed there, the commit and the
        # count of its lines of code. The quality sections (tests, coverage, complexity, CRAP, analysis) may be null:
        # the Build run's artifacts expire.
        $described = @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' -and $_['buildPath'] })
        if ($described.Count -eq 0 -and @($system.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' -and $_['buildPath'] }).Count -eq 0) { Skip-Check 'no deployable has a buildPath in system.json' }
        $shown = foreach ($app in $described) {
            foreach ($entry in $system.environments) {
                $deployment = Find-LastDeployment "$slug-$($app.name)" ([string] $entry.name)
                if (-not $deployment) { continue }
                $names = @("app-$slug-$($entry.name)-$($app.name)")
                if ($entry['standbyLocation']) { $names += "app-$slug-$($entry.name)-$($app.name)-$($entry.standbyLocation)" }
                foreach ($name in $names) {
                    $answer = Invoke-WebRequest -Uri "https://$name.azurewebsites.net$($app.buildPath)" -Headers @{ Origin = 'https://capability-check.example' } -TimeoutSec 120 -SkipHttpErrorCheck
                    Assert-That ($answer.StatusCode -eq 200) "$name answers $($app.buildPath) with HTTP $($answer.StatusCode): deploy a release of $slug-$($app.name) that has the endpoint"
                    Assert-That ("$($answer.Headers['Access-Control-Allow-Origin'])" -eq '*') "$name does not allow other origins to read $($app.buildPath)"
                    $facts = $(if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }) | ConvertFrom-Json -AsHashtable
                    Assert-That ([string] $facts['version'] -eq $deployment.Version) "$name says it is build $($facts['version']), Octopus deployed $($deployment.Version)"
                    Assert-That ([string] $facts['commit'] -match '^[0-9a-f]{40}$') "$name names no commit at $($app.buildPath)"
                    Assert-That ($facts['code'] -is [hashtable] -and [int] $facts.code['linesOfCode'] -gt 0) "$name counts no lines of code at $($app.buildPath)"
                    "$name $($facts['version']) $(([string] $facts['commit']).Substring(0, 7))"
                }
            }
        }
        # A static deployable (the dashboard) with a buildPath serves its build facts from its own site, and the
        # topology it serves names the path, so the page shows its own Code card. No CORS: the page reads its own origin.
        $sites = @($system.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' -and $_['buildPath'] })
        $shownSites = foreach ($site in $sites) {
            foreach ($e in $environments) {
                $deployment = Find-LastDeployment "$slug-$($site.name)" $e
                if (-not $deployment) { continue }
                $url = "$(az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query "outputs.deployables.value[?name=='$($site.name)'].url | [0]" --output tsv)".Trim()
                Assert-That ([bool] $url) "stack-$slug-$e lists no site for $($site.name)"
                $answer = Invoke-WebRequest -Uri "$url$($site.buildPath)" -TimeoutSec 120 -SkipHttpErrorCheck
                Assert-That ($answer.StatusCode -eq 200) "$($site.name) in $e answers $($site.buildPath) with HTTP $($answer.StatusCode): deploy a release of $slug-$($site.name) whose build writes the file"
                $facts = $(if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }) | ConvertFrom-Json -AsHashtable
                Assert-That ([string] $facts['version'] -eq $deployment.Version) "$($site.name) in $e says it is build $($facts['version']), Octopus deployed $($deployment.Version)"
                Assert-That ([string] $facts['commit'] -match '^[0-9a-f]{40}$') "$($site.name) in $e names no commit at $($site.buildPath)"
                Assert-That ($facts['code'] -is [hashtable] -and [int] $facts.code['linesOfCode'] -gt 0) "$($site.name) in $e counts no lines of code at $($site.buildPath)"
                $content = (Invoke-WebRequest -Uri "$url/topology.json" -TimeoutSec 120).Content
                $topology = $(if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { [string] $content }) | ConvertFrom-Json -AsHashtable
                $named = if ($topology['system'] -is [hashtable] -and $topology.system['dashboard'] -is [hashtable]) { [string] $topology.system.dashboard['buildPath'] } else { '' }
                Assert-That ($named -eq [string] $site.buildPath) "the topology $($site.name) serves in $e does not name its build facts ($($site.buildPath)): deploy the release of $slug-$($site.name) to $e again"
                "$($site.name) in $e $($facts['version']) $(([string] $facts['commit']).Substring(0, 7))"
            }
        }
        $shown = @($shown) + @($shownSites) | Where-Object { $_ }
        if (-not $shown) { Skip-Check 'no successful deployment of a deployable with a buildPath yet' }
        "every deployed application describes its build: $(@($shown) -join '; ')"
    }
    'CAP-083' = {
        # What each environment costs, where a browser can read it: workflow delivery publishes cost.json next to
        # delivery.json on branch status, no older than two days (Azure's cost data is a day behind), with every
        # environment, what they share, and the system's month so far.
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'status') { Skip-Check 'workflow delivery has not published branch status yet' }
        $files = @(gh api "repos/$systemRepo/contents?ref=status" --jq '.[].name')
        if ($files -notcontains 'cost.json') { Skip-Check 'branch status has no cost.json yet: the hourly run of workflow delivery writes it' }
        $cost = Get-RepoFile $systemRepo 'cost.json?ref=status' | ConvertFrom-Json -AsHashtable
        $asOf = [datetime]::ParseExact([string] $cost['asOf'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        Assert-That ($asOf -gt [datetime]::UtcNow.AddDays(-3)) "cost.json on branch status is as of $($cost['asOf']): workflow delivery has not read the cost for more than two days"
        $named = @($cost['environments'] | Where-Object { $_ } | ForEach-Object { [string] $_['name'] })
        $absent = @(@($environments) + 'shared' | Where-Object { $named -notcontains $_ })
        Assert-That ($absent.Count -eq 0) "cost.json does not list $($absent -join ', ')"
        Assert-That ($cost['system'] -is [hashtable] -and $null -ne $cost.system['monthToDate']) 'cost.json has no cost of the system for the month: a resource group could not be read'
        "cost as of $($cost['asOf']): $($cost['currency']) $($cost.system['monthToDate']) this month for $($named -join ', ')"
    }
    'CAP-086' = {
        # A node that is not healthy says which of its checks failed: every web app of an App Service deployable with a
        # healthDetailPath answers it, from any origin, with named entries and their states, and the topology every
        # deployed dashboard serves carries the path, so the page shows a mark per entry.
        $detailed = @($system.deployables | Where-Object { $_['hosting'] -eq 'appservice' -and $_['healthDetailPath'] })
        if ($detailed.Count -eq 0) { Skip-Check 'no App Service deployable has a healthDetailPath in system.json' }
        $shown = foreach ($app in $detailed) {
            foreach ($entry in $system.environments) {
                if (-not (Find-LastDeployment "$slug-$($app.name)" ([string] $entry.name))) { continue }
                $name = "app-$slug-$($entry.name)-$($app.name)"
                $answer = Invoke-WebRequest -Uri "https://$name.azurewebsites.net$($app.healthDetailPath)" -Headers @{ Origin = 'https://capability-check.example' } -TimeoutSec 120 -SkipHttpErrorCheck
                Assert-That ($answer.StatusCode -in 200, 503) "$name answers $($app.healthDetailPath) with HTTP $($answer.StatusCode)"
                Assert-That ("$($answer.Headers['Access-Control-Allow-Origin'])" -eq '*') "$name does not allow other origins to read $($app.healthDetailPath)"
                $detail = $(if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }) | ConvertFrom-Json -AsHashtable
                $entries = @($detail['entries'] | Where-Object { $_ -and $_['name'] -and $_['status'] })
                Assert-That ($entries.Count -gt 0) "$name names no health-check entries at $($app.healthDetailPath)"
                "$name $($entries.Count) checks"
            }
        }
        if (-not $shown) { Skip-Check 'no successful deployment of a deployable with a healthDetailPath yet' }
        "every primary web app names its health checks: $(@($shown) -join '; ')"
    }
    'CAP-087' = {
        # What the system depends on outside Azure is on the runtime diagram with its state: every dependency of
        # system.json (deployables[].dependencies) is a node of kind "dependency" in the runtime manifest of every
        # environment that every deployed dashboard serves.
        $declared = @(foreach ($app in $system.deployables) { foreach ($d in @($app['dependencies'] | Where-Object { $_ })) { [string] $d['name'] } })
        if ($declared.Count -eq 0) { Skip-Check 'no deployable declares dependencies in system.json' }
        $dashboard = @($system.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
        if (-not $dashboard) { Skip-Check 'no deployable with hosting staticwebapp yet' }
        $shown = foreach ($e in $environments) {
            if (-not (Find-LastDeployment "$slug-$($dashboard.name)" $e)) { continue }
            $url = "$(az stack group show --name "stack-$slug-$e" --resource-group (Get-Group $e) --query "outputs.deployables.value[?name=='$($dashboard.name)'].url | [0]" --output tsv)".Trim()
            Assert-That ([bool] $url) "stack-$slug-$e lists no site for $($dashboard.name)"
            foreach ($drawn in $environments) {
                $content = (Invoke-WebRequest -Uri "$url/runtime/$drawn.json" -TimeoutSec 120).Content
                $manifest = $(if ($content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($content) } else { [string] $content }) | ConvertFrom-Json -AsHashtable
                $names = @($manifest['nodes'] | Where-Object { $_ -and $_['kind'] -eq 'dependency' } | ForEach-Object { [string] $_['name'] })
                $lost = @($declared | Where-Object { $names -notcontains $_ })
                Assert-That ($lost.Count -eq 0) "the dashboard in $e does not draw $($lost -join ', ') in the diagram of ${drawn}: deploy the release of $slug-$($dashboard.name) to $e again"
            }
            $e
        }
        if (-not $shown) { Skip-Check "no successful $slug-$($dashboard.name) deployment yet" }
        "$($declared -join ', ') on the runtime diagrams served in $(@($shown) -join ', ')"
    }
    'CAP-088' = {
        # Deployments in flight where a browser can read them: workflow deployments publishes deployments.json on
        # branch deployments (one commit, none on main) when a deployment pins its version and on a five-minute
        # schedule, and only when something changed, so the file's own time says nothing about its age. It is
        # compared with Octopus both ways instead, with an hour for the schedule (GitHub started it every twenty to
        # thirty minutes on 2026-10-08): every deployment task of the space that has been in flight that long is in
        # the file, and nothing the file calls in flight ended that long ago.
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'deployments') { Skip-Check 'workflow deployments has not published branch deployments yet' }
        $published = Get-RepoFile $systemRepo 'deployments.json?ref=deployments' | ConvertFrom-Json -AsHashtable
        Assert-That ([string] $published['system'] -eq $slug) "deployments.json on branch deployments is of system '$($published['system'])', not $slug"
        $listed = @($published['deployments'] | Where-Object { $_ })
        $states = 'queued', 'executing', 'waiting', 'succeeded', 'failed', 'canceled'
        $unreadable = @($listed | Where-Object { $states -notcontains [string] $_['state'] -or -not $_['project'] -or -not $_['environment'] -or [string] $_['url'] -notmatch '/tasks/ServerTasks-\d+$' })
        Assert-That ($unreadable.Count -eq 0) "deployments.json has $($unreadable.Count) entr(ies) without a project, an environment, a task or one of the states $($states -join ', ')"
        $inFlight = @($listed | Where-Object { -not $_['finished'] })
        $limit = [datetimeoffset]::UtcNow.AddMinutes(-60)
        foreach ($task in @((Invoke-Octopus "/api/$space/tasks?name=Deploy&states=Queued,Executing,Cancelling&take=100").Items | Where-Object { $_ })) {
            if ([datetimeoffset] $task.QueueTime -gt $limit) { continue }
            Assert-That (@($inFlight | Where-Object { [string] $_['url'] -like "*/tasks/$($task.Id)" }).Count -eq 1) "deployments.json does not list '$($task.Description)', in flight in Octopus for over an hour ($($task.Id)): run workflow deployments"
        }
        foreach ($entry in $inFlight) {
            $task = Invoke-Octopus "/api/tasks/$(([string] $entry['url']) -replace '^.*/tasks/', '')"
            Assert-That (-not $task.IsCompleted -or [datetimeoffset] $task.CompletedTime -gt $limit) "deployments.json calls $($entry['project']) $($entry['release']) to $($entry['environment']) $($entry['state']); in Octopus it ended over an hour ago ($($task.Id)): run workflow deployments"
        }
        "deployments.json on branch deployments: $($inFlight.Count) in flight, as in Octopus; $($listed.Count - $inFlight.Count) ended in the last half hour"
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
function Test-WaitsForPerson($Task) {
    # A task Octopus paused at a sign-off, which a person answers (a pending interruption of type ManualIntervention):
    # at rest. The task's own flag does not decide by itself: Octopus also pauses a task with interruptions it answers
    # itself (runtime aks-argocd: the wait for Argo CD to sync), and such a task is changing the environment.
    if (-not $Task.HasPendingInterruptions) { return $false }
    @((Invoke-Octopus "/api/$space/interruptions?regarding=$($Task.Id)&take=100").Items | Where-Object { $_.IsPending -and $_.Type -eq 'ManualIntervention' }).Count -gt 0
}
function Wait-QuietSpace([int] $Minutes) {
    # $true once no task of the space runs or waits for Octopus; $false when that takes longer than $Minutes. One read
    # a minute. A task that waits for a person (a deployment at its sign-off) is at rest: nothing changes until
    # somebody answers, which can take a night, and what the environment runs meanwhile is what the checks read
    # (write-delivery.ps1 waits the same way).
    $deadline = [datetimeoffset]::UtcNow.AddMinutes($Minutes)
    $said = $false
    while ($true) {
        $tasks = @((Invoke-Octopus "/api/$space/tasks?states=Executing,Queued,Cancelling&take=10").Items)
        $atSignOff = @($tasks | Where-Object { Test-WaitsForPerson $_ })
        if ($atSignOff.Count -gt 0 -and -not $said) {
            $said = $true
            Write-Host "At rest, waiting for a person: $(@($atSignOff | ForEach-Object { "$($_.Description) ($($_.Id))" }) -join '; ')."
        }
        if ($tasks.Count -eq $atSignOff.Count) { return $true }
        if ([datetimeoffset]::UtcNow -gt $deadline) { return $false }
        Write-Host 'Waiting for running Octopus tasks to finish.'
        Start-Sleep -Seconds 60
    }
}
function Get-TaskSince([datetimeoffset] $Since) {
    # The deployments and runbook runs of the space that run now or ended after $Since, newest first: one read of the
    # space's latest tasks. One that waits for a person changes nothing meanwhile (Wait-QuietSpace) and does not count.
    @((Invoke-Octopus "/api/$space/tasks?take=50").Items | Where-Object {
            $_.Name -in 'Deploy', 'RunbookRun' -and ((-not $_.IsCompleted -and -not (Test-WaitsForPerson $_)) -or ($_.CompletedTime -and [datetimeoffset] $_.CompletedTime -ge $Since))
        })
}
function Invoke-Check([string] $Id) {
    # One check: Result PASS, SKIP or FAIL, and what it found.
    try { @{ Id = $Id; Result = 'PASS'; Message = "$(& $checks[$Id])" } }
    catch [CheckSkipped] { @{ Id = $Id; Result = 'SKIP'; Message = $_.Exception.Message } }
    catch { @{ Id = $Id; Result = 'FAIL'; Message = $_.Exception.Message } }
}
function Write-Check([hashtable] $Check, [string] $Note = '') {
    if ($Check.Result -eq 'FAIL') { Write-Fail "$($Check.Id): $($Check.Message)$Note" }
    elseif ($Check.Result -eq 'SKIP') { Write-Host "SKIP $($Check.Id): $($Check.Message)$Note" }
    else { Write-Pass "$($Check.Id): $($Check.Message)$Note" }
}

if (-not (Wait-QuietSpace $WaitMinutes)) {
    if ($WaitOnly) { Write-Host "Octopus is still busy after $WaitMinutes minutes; the checks wait on."; exit 0 }
    Write-Fail "the space did not become quiet in $WaitMinutes minutes"
    exit 1
}
if ($WaitOnly) {
    Write-Host 'Octopus is quiet.'
    exit 0
}
# The checks begin here, with the space quiet. Ten seconds back: the clocks of this machine and of Octopus may differ.
$began = [datetimeoffset]::UtcNow.AddSeconds(-10)
# @(...) around the whole if: a single -Only ID would otherwise become a string, which has no Count in strict mode.
$ids = @(if ($Only) { $Only } else { $checks.Keys })
$failed = 0
$skipped = 0
# A failed check is not a FAIL line yet: a deployment or runbook run that started after the wait above makes Git,
# Octopus and Azure differ while it runs (cmdemo2, 2026-10-07: a rollout applied prod during the nightly run, three
# checks failed on its half-applied stack and an issue was opened for nothing). So the failures are judged after the
# last check, with one read of the space's tasks.
$unproven = @()
foreach ($id in $ids) {
    if (-not $checks.Contains($id)) { Write-Fail "${id}: no check"; $failed++; continue }
    $outcome = Invoke-Check $id
    if ($outcome.Result -eq 'FAIL') { $unproven += $outcome; continue }
    if ($outcome.Result -eq 'SKIP') { $skipped++ }
    Write-Check $outcome
}
if ($unproven.Count -gt 0) {
    $rerun = $false
    try {
        $ranSince = @(Get-TaskSince $began)
        if ($ranSince.Count -gt 0) {
            $ranNames = @($ranSince | Select-Object -First 3 | ForEach-Object { "$($_.Description) ($($_.Id), $($_.State))" }) -join '; '
            $ranMore = if ($ranSince.Count -gt 3) { " and $($ranSince.Count - 3) more" } else { '' }
            Write-Host "Octopus was not quiet while the checks ran: $ranNames$ranMore. In the middle of a deployment or runbook run Git, Octopus and Azure differ by design, so what failed runs once more when the space is quiet: $(@($unproven | ForEach-Object { $_.Id }) -join ', ')."
            $rerun = Wait-QuietSpace $AgainMinutes
            if (-not $rerun) { Write-Host "The space did not become quiet in $AgainMinutes minutes: the failed checks are not run again, and their first result stands." }
        }
    }
    catch {
        Write-Host "Octopus could not be asked whether a task ran while the checks ran, or whether it is quiet again ($($_.Exception.Message)): the failed checks are not run again, and their first result stands."
        $rerun = $false
    }
    foreach ($firstResult in $unproven) {
        $outcome = if ($rerun) { Invoke-Check $firstResult.Id } else { $firstResult }
        if ($outcome.Result -eq 'FAIL') { $failed++ } elseif ($outcome.Result -eq 'SKIP') { $skipped++ }
        $rerunNote = if (-not $rerun) { '' } elseif ($outcome.Result -eq 'FAIL') { ' (run again after Octopus became quiet: it still fails)' } else { " (run again after Octopus became quiet; during the task it failed with: $($firstResult.Message))" }
        Write-Check $outcome $rerunNote
    }
}
$skippedNote = if ($skipped -gt 0) { " ($skipped skipped: their preconditions do not exist yet)" } else { '' }
if ($failed -gt 0) {
    Write-Host "$failed of $($ids.Count) capabilities failed$skippedNote."
    exit 1
}
Write-Host "All $($ids.Count - $skipped) checked capabilities are proven$skippedNote."
