#Requires -Version 7.4

<#
.SYNOPSIS
    Writes deployments.json: the deployments of the system's Octopus space that are in flight, and those that ended in
    the last half hour; and what a dashboard says in words about them: what a deployment waits for and who is
    responsible, who started it, the last deployment that ended in each environment, and the deployment freezes.

.DESCRIPTION
    The system reads Octopus, once, for everything that is deployed from its space; no application reads it for
    itself. The file is what every dashboard shows a marker from: the system's own health dashboard on the node that
    is being deployed, and the fleet health dashboard on the system's box.

    One entry per deployment task of the space that is not finished, or finished less than -FinishedMinutes ago:

      project      the Octopus project (<slug>-<deployable>, and <slug>-system for the system's own release)
      environment  the environment it deploys to
      release      the release
      state        queued     waiting behind another task of the environment or the instance's task limit
                   executing  running now
                   waiting    stopped for a person: the sign-off, or the question of a guided failure (a pending
                              interruption of type ManualIntervention or GuidedFailure, whether Octopus calls the
                              task executing or queued meanwhile; a pause Octopus answers itself, such as the wait
                              for Argo CD to sync, is executing)
                   succeeded, failed, canceled   ended, at "finished"
      since        when it started, or when it was queued while it has not started (UTC)
      finished     when it ended (UTC); absent while it has not
      startedBy    who started it, as Octopus names the account; absent when Octopus does not say
      url          the task in Octopus
      waitsFor     only while it is waiting: kind ("sign-off", or "guided failure" for the question Octopus asks
                   after a step failed), title (Octopus's title of it), since, and responsible: the person who took
                   it, otherwise the teams Octopus names for it ('' when their names could not be read)

    In flight first, the one that started first at the top; then what ended, the last one first. An empty list says
    that nothing is being deployed.

    Beside the list, in the names and words of the fleet's "activity" (docs/fleet.md of the kit):

      recent[]     the last deployment that ended of each project in each environment, the last one first: project,
                   release, environment, result (succeeded, failed, canceled), finished, startedBy, url. It stays
                   after the half hour of "deployments": a dashboard says "the last thing that happened" from it.
      freezes[]    the deployment freezes that cover a project of the space now or within -FreezeHours hours: name,
                   from, to, active (in force now), environments and projects (their names)
      missing[]    the parts that could not be read: "recent", "freezes", "startedBy", "responsible". A call the
                   account may not make fails nothing: the part is left out and named here. Deployment freezes
                   belong to the Octopus instance and not to a space, and a system's account has rights in its own
                   space only; an empty "freezes" that is not named here says that no freeze covers the system.

    A name that is an e-mail address is cut at the @: the file is public.

    The requests, as the instance documents them (<octopus>/llms.txt): GET /api/{space}/tasks?name=Deploy (the newest
    deployment tasks, which carry project, release and environment in their description), and for each task that is
    paused GET /api/{space}/interruptions?regarding= (for whom, and since when); then GET /api/{space}/dashboard (the
    last deployment of every project in every environment, and the names of both), GET /api/{space}/deployments?ids=
    (who started them), GET /api/deploymentfreezes?skip=&take= (the instance asks for both), and for a deployment
    that waits GET /api/users/{id} or GET /api/{space}/teams/{id}. Only the first two can fail the run.

    Run by workflow deployments of the system repository when Octopus pins a version (the start of every
    deployment), on a five-minute schedule, and on demand, and again every half minute while a deployment is
    executing; published on branch "deployments" and read from the browser at
    https://raw.githubusercontent.com/<org>/<repository>/deployments/deployments.json, which GitHub may serve a few
    minutes old. A started deployment shows within about one to six minutes, and its end as soon; one that is only
    queued shows at the next scheduled run, which GitHub starts when it has room (up to half an hour).

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login).

.PARAMETER Path
    The file to write.

.PARAMETER Root
    The folder that holds system.json, which names the system, the Octopus server and the space.

.PARAMETER System
    For a system without a system.json: its name in the fleet. With -OctopusUrl and -Space.

.PARAMETER OctopusUrl
    For a system without a system.json: the Octopus server.

.PARAMETER Space
    For a system without a system.json: the id of its Octopus space (Spaces-123), or its name.

.PARAMETER FinishedMinutes
    How long a deployment that ended stays in "deployments".

.PARAMETER FreezeHours
    How far ahead a deployment freeze is named before it begins.

.EXAMPLE
    pwsh -NoProfile -File scripts/write-deployments.ps1 -Path deployments.json

.EXAMPLE
    pwsh -NoProfile -File write-deployments.ps1 -Path deployments.json -System cmfleet -OctopusUrl https://example.octopus.app -Space cmfleet
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string] $System = '',
    [string] $OctopusUrl = '',
    [string] $Space = '',
    [ValidateRange(0, 1440)] [int] $FinishedMinutes = 30,
    [ValidateRange(0, 720)] [int] $FreezeHours = 72
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }

if (-not $System) {
    $file = Join-Path $Root 'system.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Fail "$file not found: a system without a system.json names itself with -System, -OctopusUrl and -Space"
        exit 1
    }
    $described = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    $System = [string] $described.system.slug
    $OctopusUrl = [string] $described.octopus.url
    $Space = [string] $described.octopus.spaceId
}
if (-not $OctopusUrl -or -not $Space) {
    Write-Fail '-System needs -OctopusUrl and -Space with it'
    exit 1
}
if (-not $env:OCTOPUS_API_KEY -and -not $env:OCTOPUS_ACCESS_TOKEN) {
    Write-Fail 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY'
    exit 1
}
$OctopusUrl = $OctopusUrl.TrimEnd('/')

function Invoke-Octopus([string] $Request) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$OctopusUrl$Request" -Headers $headers
}

function Get-Utc {
    # Octopus answers in the server's offset, and PowerShell reads such a time as a date of this machine.
    param([object] $Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetimeoffset]::Parse([string] $Value, [cultureinfo]::InvariantCulture).UtcDateTime
}

function Format-Utc {
    param([object] $Value)
    $time = Get-Utc -Value $Value
    if ($null -eq $time) { return $null }
    return $time.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function Get-Field {
    # A field of an answer that may not have it: its value, or nothing.
    param([AllowNull()] [object] $Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-PublicName {
    # The name of an Octopus user as a public file may hold it: an account that is named by its e-mail address is
    # named by the part before the @.
    param([AllowNull()] [string] $Name)
    return (([string] $Name) -split '@')[0].Trim()
}

function Get-PendingHold {
    # The interruption a task waits for a person with: the oldest pending one that is a manual intervention (the
    # sign-off) or a guided failure (Octopus asks what to do after a step failed); nothing when no person is waited
    # for. Octopus pauses a task for itself too: on runtime aks-argocd it waits that way for Argo CD to sync (type
    # ArgoCDApplicationSync, in the records of cmdemo3's space), and answers it itself. The task's own flag is the
    # same for both, so the type of the pending interruption decides. One more request, and only for a task that is
    # paused.
    param([Parameter(Mandatory)] [object] $Task)
    if (-not $Task.HasPendingInterruptions) { return $null }
    return @((Invoke-Octopus "/api/$Space/interruptions?regarding=$($Task.Id)&take=100").Items |
            Where-Object { $_ -and $_.IsPending -and $_.Type -in 'ManualIntervention', 'GuidedFailure' } |
            Sort-Object { Get-Utc -Value (Get-Field -Object $_ -Name 'Created') }) | Select-Object -First 1
}

function Get-DeploymentState {
    # What a task's state means for someone who looks at the wall. -Hold is what Get-PendingHold found for it.
    param([Parameter(Mandatory)] [object] $Task, [AllowNull()] [object] $Hold = $null)
    switch ([string] $Task.State) {
        'Queued' {
            # Octopus puts a task that stops for a person at its start back in the queue, where it takes no place of
            # the task limit (cmdemo2, 2026-10-08: a promotion at its sign-off for hours, state Queued). The pending
            # manual intervention tells it from one that waits its turn.
            if ($Hold) { return 'waiting' }
            return 'queued'
        }
        'Success' { return 'succeeded' }
        'Failed' { return 'failed' }
        'TimedOut' { return 'failed' }
        'Canceled' { return 'canceled' }
        default {
            # Executing or Cancelling. Stopped for a person is its own state: somebody has to act.
            if ($Hold) { return 'waiting' }
            return 'executing'
        }
    }
}

function Get-Responsible {
    # Who is responsible for an interruption, by name: the person who took it, otherwise the teams Octopus names for
    # it. A name that cannot be read (the account may not read users, or a team of the instance) is left out, and
    # -Missing then names "responsible". -Known keeps what was asked, so a name is asked once.
    param(
        [Parameter(Mandatory)] [object] $Hold,
        [Parameter(Mandatory)] [hashtable] $Known,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $Missing
    )
    $user = [string] (Get-Field -Object $Hold -Name 'ResponsibleUserId')
    $asked = if ($user) { @("/api/users/$user") } else { @(Get-Field -Object $Hold -Name 'ResponsibleTeamIds' | Where-Object { $_ } | ForEach-Object { "/api/$Space/teams/$_" }) }
    $names = foreach ($request in $asked) {
        if (-not $Known.ContainsKey($request)) {
            $Known[$request] = try {
                $who = Invoke-Octopus $request
                $name = [string] (Get-Field -Object $who -Name 'DisplayName')
                if (-not $name) { $name = [string] (Get-Field -Object $who -Name 'Username') }
                if (-not $name) { $name = [string] (Get-Field -Object $who -Name 'Name') }
                Get-PublicName -Name $name
            }
            catch { '' }
        }
        if (-not $Known[$request] -and -not $Missing.Contains('responsible')) { $Missing.Add('responsible') }
        $Known[$request]
    }
    return (@($names | Where-Object { $_ }) -join ', ')
}

function Get-WaitsFor {
    # What a deployment that waits for a person waits for, as the file says it.
    param([Parameter(Mandatory)] [object] $Hold, [Parameter(Mandatory)] [hashtable] $Known, [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $Missing)
    return [ordered] @{
        kind        = $(if ([string] $Hold.Type -eq 'GuidedFailure') { 'guided failure' } else { 'sign-off' })
        title       = [string] (Get-Field -Object $Hold -Name 'Title')
        since       = Format-Utc -Value (Get-Field -Object $Hold -Name 'Created')
        responsible = [string] (Get-Responsible -Hold $Hold -Known $Known -Missing $Missing)
    }
}

function Get-FreezeWindow {
    # When a deployment freeze is in force: its own start and end, or for one that repeats the occurrence its
    # schedule names (RecurringSchedule.StartDate and .EndDate). The first one that has not ended and begins within
    # -Hours of -Now; nothing when there is none.
    param([Parameter(Mandatory)] [object] $Freeze, [Parameter(Mandatory)] [datetime] $Now, [int] $Hours = 72)
    $schedule = Get-Field -Object $Freeze -Name 'RecurringSchedule'
    $windows = @(
        @{ From = Get-Utc -Value (Get-Field -Object $Freeze -Name 'Start'); To = Get-Utc -Value (Get-Field -Object $Freeze -Name 'End') }
        @{ From = Get-Utc -Value (Get-Field -Object $schedule -Name 'StartDate'); To = Get-Utc -Value (Get-Field -Object $schedule -Name 'EndDate') }
    )
    return @($windows | Where-Object { $_.From -and $_.To -and $_.To -gt $Now -and $_.From -le $Now.AddHours($Hours) } | Sort-Object { $_.From }) | Select-Object -First 1
}

function Get-SpaceFreeze {
    # The deployment freezes of the instance that cover a project of this space, now or soon. A freeze names pairs of
    # project and environment (ProjectEnvironmentScope, and TenantProjectEnvironmentScope for tenants); the space's
    # own projects decide which are its.
    param(
        [AllowNull()] [object[]] $Freeze,
        [Parameter(Mandatory)] [hashtable] $ProjectName,
        [Parameter(Mandatory)] [hashtable] $EnvironmentName,
        [Parameter(Mandatory)] [datetime] $Now,
        [int] $Hours = 72
    )
    $found = foreach ($one in @($Freeze | Where-Object { $_ })) {
        $pairs = [Collections.Generic.List[object]]::new()
        $scope = Get-Field -Object $one -Name 'ProjectEnvironmentScope'
        if ($scope) {
            foreach ($property in $scope.PSObject.Properties) { foreach ($environment in @($property.Value)) { $pairs.Add(@{ Project = [string] $property.Name; Environment = [string] $environment }) } }
        }
        foreach ($entry in @(Get-Field -Object $one -Name 'TenantProjectEnvironmentScope' | Where-Object { $_ })) { $pairs.Add(@{ Project = [string] $entry.ProjectId; Environment = [string] $entry.EnvironmentId }) }
        $own = @($pairs | Where-Object { $ProjectName.ContainsKey($_.Project) })
        if ($own.Count -eq 0) { continue }
        $window = Get-FreezeWindow -Freeze $one -Now $Now -Hours $Hours
        if (-not $window) { continue }
        [ordered] @{
            name         = [string] $one.Name
            from         = Format-Utc -Value $window.From
            to           = Format-Utc -Value $window.To
            active       = [bool] ($window.From -le $Now)
            environments = @($own | ForEach-Object { if ($EnvironmentName.ContainsKey($_.Environment)) { $EnvironmentName[$_.Environment] } else { $_.Environment } } | Select-Object -Unique)
            projects     = @($own | ForEach-Object { $ProjectName[$_.Project] } | Select-Object -Unique)
        }
    }
    return @($found | Sort-Object { $_.from }, { $_.name })
}

function Get-TaskResult {
    # How a task that ended ended, in the file's words.
    param([AllowNull()] [string] $State)
    switch ($State) { 'Success' { return 'succeeded' } 'Canceled' { return 'canceled' } default { return 'failed' } }
}

function Get-LastEnded {
    # The last deployment that ended of each project in each environment, the last one first. Two sources say it, and
    # the later end wins: the space's dashboard, which has the last deployment of every pair however long ago (-Dashboard;
    # nothing when it could not be read), and the newest deployment tasks (-Ended, as this script read them), which
    # have the one before a deployment that is in flight now.
    param([AllowNull()] [object] $Dashboard, [AllowNull()] [object[]] $Ended, [Parameter(Mandatory)] [string] $Web)
    $last = @{}
    $keep = {
        param([System.Collections.IDictionary] $Entry)
        $key = "$($Entry.project)|$($Entry.environment)".ToLowerInvariant()
        if (-not $Entry.finished) { return }
        if (-not $last.ContainsKey($key) -or [string]::CompareOrdinal([string] $last[$key].finished, [string] $Entry.finished) -lt 0) { $last[$key] = $Entry }
    }
    foreach ($one in @($Ended | Where-Object { $_ })) { & $keep $one }
    if ($Dashboard) {
        $projectName = @{}
        foreach ($project in @($Dashboard.Projects)) { $projectName[[string] $project.Id] = [string] $project.Name }
        $environmentName = @{}
        foreach ($environment in @($Dashboard.Environments)) { $environmentName[[string] $environment.Id] = [string] $environment.Name }
        foreach ($item in @($Dashboard.Items | Where-Object { $_ -and (Get-Field -Object $_ -Name 'IsCompleted') })) {
            $project = [string] $item.ProjectId
            $environment = [string] $item.EnvironmentId
            if (-not $projectName.ContainsKey($project) -or -not $environmentName.ContainsKey($environment)) { continue }
            & $keep ([ordered] @{
                    project     = $projectName[$project]
                    release     = [string] $item.ReleaseVersion
                    environment = $environmentName[$environment]
                    result      = Get-TaskResult -State ([string] $item.State)
                    finished    = Format-Utc -Value $item.CompletedTime
                    url         = "$Web/tasks/$($item.TaskId)"
                    deployment  = [string] (Get-Field -Object $item -Name 'DeploymentId')
                })
        }
    }
    return @($last.Values | Sort-Object { $_.finished } -Descending)
}

function Complete-Entry {
    # The entry as the file has it: who started it in its place before the address, and without the id it was found by.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Entry, [Parameter(Mandatory)] [hashtable] $StartedBy)
    $who = [string] $StartedBy[[string] $Entry.deployment]
    $Entry.Remove('deployment')
    if ($who) { $Entry.Insert(@($Entry.Keys).IndexOf('url'), 'startedBy', $who) }
    return $Entry
}

# A space named by its name: its id is asked once.
if ($Space -notmatch '^Spaces-\d+$') {
    $named = @((Invoke-Octopus "/api/spaces?partialName=$([uri]::EscapeDataString($Space))&take=100").Items | Where-Object { $_.Name -eq $Space }) | Select-Object -First 1
    if (-not $named) {
        Write-Fail "Octopus $OctopusUrl has no space named '$Space' that this account may read"
        exit 1
    }
    $Space = [string] $named.Id
}

$now = (Get-Date).ToUniversalTime()
$web = "$OctopusUrl/app#/$Space"
$missing = [Collections.Generic.List[string]]::new()
$known = @{}
# The newest deployment tasks, whatever their state: everything in flight is among them, and what ended lately.
$tasks = @((Invoke-Octopus "/api/$Space/tasks?name=Deploy&take=100").Items)
$deployments = [Collections.Generic.List[object]]::new()
$endedTasks = [Collections.Generic.List[object]]::new()
foreach ($task in $tasks) {
    # "Deploy <project> release <release> to <environment>": Octopus's own words for the task.
    $said = [regex]::Match([string] $task.Description, '^Deploy (?<project>.+) release (?<release>\S+) to (?<environment>.+)$')
    if (-not $said.Success) { continue }
    $finished = if ($task.IsCompleted) { Get-Utc -Value $task.CompletedTime } else { $null }
    $deployment = [string] (Get-Field -Object (Get-Field -Object $task -Name 'Arguments') -Name 'DeploymentId')
    if ($task.IsCompleted) {
        if (-not $finished) { continue }
        $endedTasks.Add([ordered] @{
                project     = $said.Groups['project'].Value
                release     = $said.Groups['release'].Value
                environment = $said.Groups['environment'].Value
                result      = Get-TaskResult -State ([string] $task.State)
                finished    = Format-Utc -Value $finished
                url         = "$web/tasks/$($task.Id)"
                deployment  = $deployment
            })
        if (($now - $finished).TotalMinutes -gt $FinishedMinutes) { continue }
    }
    $started = if ($task.StartTime) { $task.StartTime } else { $task.QueueTime }
    $hold = if ($task.IsCompleted) { $null } else { Get-PendingHold -Task $task }
    $entry = [ordered] @{
        project     = $said.Groups['project'].Value
        environment = $said.Groups['environment'].Value
        release     = $said.Groups['release'].Value
        state       = Get-DeploymentState -Task $task -Hold $hold
        since       = Format-Utc -Value $started
    }
    if ($finished) { $entry.finished = Format-Utc -Value $finished }
    $entry.url = "$web/tasks/$($task.Id)"
    if ($hold -and $entry.state -eq 'waiting') { $entry.waitsFor = Get-WaitsFor -Hold $hold -Known $known -Missing $missing }
    $entry.deployment = $deployment
    $deployments.Add($entry)
}

# From here on nothing fails the run: a part that cannot be read is left out and named in "missing".
$dashboard = $null
try { $dashboard = Invoke-Octopus "/api/$Space/dashboard" }
catch { $missing.Add('recent') }
$recent = @(Get-LastEnded -Dashboard $dashboard -Ended $endedTasks.ToArray() -Web $web)

$freezes = @()
if ($dashboard) {
    $projectName = @{}
    foreach ($project in @($dashboard.Projects)) { $projectName[[string] $project.Id] = [string] $project.Name }
    $environmentName = @{}
    foreach ($environment in @($dashboard.Environments)) { $environmentName[[string] $environment.Id] = [string] $environment.Name }
    try {
        $all = @((Invoke-Octopus '/api/deploymentfreezes?skip=0&take=100').DeploymentFreezes | Where-Object { $_ })
        $freezes = @(Get-SpaceFreeze -Freeze $all -ProjectName $projectName -EnvironmentName $environmentName -Now $now -Hours $FreezeHours)
    }
    catch { $missing.Add('freezes') }
}
else {
    # Without the names of the space's projects nothing says which freeze is this system's.
    $missing.Add('freezes')
}

# Who started each: the deployment of a task says it. One request for all of them.
$ids = @(@($deployments) + @($recent) | ForEach-Object { [string] $_.deployment } | Where-Object { $_ } | Select-Object -Unique)
$startedBy = @{}
if ($ids.Count -gt 0) {
    try {
        foreach ($one in @((Invoke-Octopus "/api/$Space/deployments?ids=$($ids -join ',')&take=$($ids.Count)").Items | Where-Object { $_ })) {
            $startedBy[[string] $one.Id] = Get-PublicName -Name ([string] (Get-Field -Object $one -Name 'DeployedBy'))
        }
    }
    catch { $missing.Add('startedBy') }
}
$deployments = @($deployments | ForEach-Object { Complete-Entry -Entry $_ -StartedBy $startedBy })
$recent = @($recent | ForEach-Object { Complete-Entry -Entry $_ -StartedBy $startedBy })
$inFlight = @($deployments | Where-Object { -not $_.Contains('finished') } | Sort-Object { $_.since })
$ended = @($deployments | Where-Object { $_.Contains('finished') } | Sort-Object { $_.finished } -Descending)

[ordered] @{
    generated   = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
    system      = $System
    octopus     = $web
    deployments = @($inFlight + $ended)
    recent      = @($recent)
    freezes     = @($freezes)
    missing     = @($missing | Select-Object -Unique)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
$waiting = @($inFlight | Where-Object { $_.Contains('waitsFor') })
Write-Pass "${Path}: $($inFlight.Count) deployment(s) in flight$(if ($inFlight.Count -gt 0) { " ($(@($inFlight | ForEach-Object { "$($_.project) $($_.release) to $($_.environment): $($_.state)" }) -join '; '))" }), $($ended.Count) ended in the last $FinishedMinutes minutes; $($waiting.Count) wait(s) for a person, the last deployment of $($recent.Count) project(s) and environment(s), $($freezes.Count) deployment freeze(s) now or within $FreezeHours hours"
if ($missing.Count -gt 0) { Write-Host "SKIP not read, and named in the file's ""missing"": $(@($missing | Select-Object -Unique) -join ', ') (this account may not make the call, or Octopus did not answer it)" }
