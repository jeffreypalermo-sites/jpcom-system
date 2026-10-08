#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes cost.json: what this system cost in Azure, per environment, read from Cost Management. It changes nothing.

.DESCRIPTION
    The workflow "delivery" runs it hourly and publishes the file next to delivery.json on branch "status", where the
    health dashboard reads it from the browser (https://raw.githubusercontent.com/<org>/<repository>/status/cost.json).

    What is read: the actual cost of the system's resource groups (system.json: every group of azure.resourceGroups
    and, unless azure.frontDoor.dormant, azure.frontDoor.resourceGroup), one query per group at the scope of the
    group, by day, by the tag "environment" and by service. Every resource of infra/ carries that tag
    (infra/main.bicep), so:
      environments[]   one entry per environment of system.json, in its order, with the cost of what is tagged with it;
                       then one per other value of the tag that Azure reports (an environment that was removed)
      "shared"         the last entry: what carries no tag "environment" (the seed's resources: the registry, the
                       state account, the Front Door profile) and what Azure bills without tags
      system           everything in the groups
    An App Service plan that several environments run on carries the tag of the one that creates it
    (infra/main.bicep: the first environment of a tier owns the tier's plan asp-<slug>-<environment>, and the first
    with a standby region that region's plan asp-<slug>-<environment>-<region>; the tier's other environments with
    an App Service deployable, or with that standby region, run on them). Its cost is split evenly among the
    environments that run on it, by day and service: which they are comes from system.json as the Bicep derives it,
    and what the plan cost from one more query of its group, the same one for these plans only (a filter on their
    resource ids), per set of plans that the same environments share. A plan one environment uses alone, and a
    system without App Service, add no query.
    Three numbers each, all of complete UTC days:
      yesterday        the day asOf: the last complete UTC day
      last7Days        the seven days that end with asOf
      monthToDate      the first of asOf's month up to asOf
    topServices: per entry, the three services (Azure's ServiceName) that cost most in monthToDate, of those that
    cost a cent or more. Amounts are rounded to cents; currency is the one Azure bills in. The entries add up to
    the system's number to the cent: what rounding each entry leaves over (a cent or two) goes to the first
    environment (to the next entry, when it would make the number of an environment that cost nothing negative).

    Runtime aks-argocd (system.json system.runtime): every environment is a namespace of one cluster, whose nodes
    and disks are in the cluster's node resource group (<cluster group>-nodes: read too) and carry no environment,
    so nearly all of the cost is "shared". Each environment therefore also gets an estimate of its part of the
    cluster: "estimate" { share, yesterday, last7Days, monthToDate }, the cluster's untagged cost times the share of
    CPU and memory that the environment's namespace requests of what all running pods request now (the mean of the
    two), read from the cluster's own status file (https://<slug>-cluster.<cluster.domain>/cluster.json). It is
    today's share applied to the days read, not a bill; the amounts stay part of "shared". Without that file (a
    stopped cluster, a system without a dashboard) there is no estimate, with a SKIP line. A published file
    without the estimate is not complete once the status file answers again (the cluster woke): with -EveryHours,
    the first hourly run after that reads Azure and writes the estimate, whatever the hour.

    Azure's cost data arrives hours late and is amended for a day or two: the numbers are what Azure reports now.
    A number that cannot be determined is null, with a SKIP line that says why: a resource group whose query was
    refused or throttled to the end leaves null the numbers it is part of (an environment: the group of its tier and
    the groups that belong to no tier; "shared" and system: every group), a query of shared plans that fails leaves
    null the numbers of the environments that run on those plans, and "yesterday" is null while Azure has no cost of
    that day at all. Only Azure not answering fails the run (no sign-in, or no group answered), and then nothing is
    written, so a published file is never replaced by an empty one.

    Nor by one that knows less: with -Published (the cost.json published now, as the workflow hands it over), a run
    in which a query was refused or throttled to the end writes nothing when the published file is of the same day
    or the day before and leaves fewer numbers null than this run would. The log says so with a SKIP line, the
    published file stays, and the next hourly run reads again. A published file older than that is replaced all the
    same: its numbers are too old to stand in for today's.

    How often Azure is asked: -EveryHours (1: every run, the default). The workflow's hourly runs pass 6. A run then
    asks nothing while the published file (-Published) is of the last complete day and leaves no number null, except
    in the hours of the day that are this system's: the UTC hours h with h mod EveryHours equal to the sum of the
    slug's characters mod EveryHours, so the systems of one subscription do not all ask in the same hour. Such a run
    writes nothing, with a SKIP line, and the published file stays. A file of an earlier day, a file with a null
    number (the day's cost not there yet, a throttled read) and a run on demand are read at once, so a new day
    appears with the first hourly run that finds it and what Azure amends later within six hours.

    Cost Management throttles (HTTP 429): a throttled query is tried again after the pause Azure names, or after
    20 s times the attempt (as the kit's get-fleet-limits.ps1), up to -Attempts times. A pause above
    -MaxWaitSeconds is not waited for.

    Azure: the current az login (azure/login as id-<slug>-plan in the workflow, which the seed made Cost Management
    Reader of the groups; the operator's own login for a run by hand). -Root names the folder that holds system.json.

.EXAMPLE
    ./scripts/write-cost.ps1 -Path "$env:RUNNER_TEMP/cost.json"

.EXAMPLE
    pwsh -NoProfile -File write-cost.ps1 -Root ~/tmp/cmdemo2 -Path ~/tmp/cmdemo2/cost.json
#>
[CmdletBinding()]
param(
    # The file to write.
    [Parameter(Mandatory)] [string] $Path,
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    # How often a throttled query is tried.
    [ValidateRange(1, 20)] [int] $Attempts = 5,
    # The longest pause that is waited for; Azure asking for more ends the query of that group.
    [ValidateRange(1, 3600)] [int] $MaxWaitSeconds = 180,
    # The cost.json published now, if any: a run that could not read every query does not replace a file of the same
    # day or the day before that knows more. A path without a file is the same as none.
    [string] $Published = '',
    # Azure is asked every run (1) or, while the published file is complete and of the last complete day, only in
    # this system's hours of the day: every this many hours.
    [ValidateRange(1, 24)] [int] $EveryHours = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$subscription = [string] $system.azure.subscriptionId
$environments = @($system.environments | ForEach-Object { [string] $_.name })
$tierOf = @{}
foreach ($environment in $system.environments) { $tierOf[[string] $environment.name] = [string] $environment['tier'] }
$shared = 'shared'

# The App Service plans and the environments that run on each, as infra/main.bicep names and shares them: an
# environment with an App Service deployable runs on the plan of the first environment of its tier and, with a
# standbyLocation, on the plan of the first environment of its tier with that standby region.
$plans = [ordered] @{}
foreach ($environment in $system.environments) {
    $name = [string] $environment.name
    $hosted = @($system['deployables'] | Where-Object { $_ -and [string] $_['hosting'] -eq 'appservice' -and (-not $_.Contains('environments') -or @($_['environments']) -contains $name) })
    if ($hosted.Count -eq 0) { continue }
    $tier = [string] $environment['tier']
    $ofTier = @($system.environments | Where-Object { [string] $_['tier'] -eq $tier })
    $runsOn = @("asp-$slug-$([string] $ofTier[0].name)")
    $standby = [string] $environment['standbyLocation']
    if ($standby) { $runsOn += "asp-$slug-$([string] @($ofTier | Where-Object { [string] $_['standbyLocation'] -eq $standby })[0].name)-$standby" }
    foreach ($plan in $runsOn) {
        if (-not $plans.Contains($plan)) { $plans[$plan] = @{ Group = [string] $system.azure.resourceGroups[$tier]; Users = @() } }
        $plans[$plan].Users += $name
    }
}
# One query per set of plans of a group that the same environments share (nearly always one per tier, or none).
$splits = [ordered] @{}
foreach ($plan in $plans.Keys) {
    $group = $plans[$plan].Group
    $users = @($plans[$plan].Users)
    if ($users.Count -lt 2 -or -not $group) { continue }
    $key = "$group`: $($users -join ', ')"
    if (-not $splits.Contains($key)) { $splits[$key] = @{ Group = $group; Users = $users; Plans = @() } }
    $splits[$key].Plans += $plan
}

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Write-Skip { param([string] $Message) Write-Host "SKIP $Message" }
function Format-Day([datetime] $Day) { $Day.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
function Format-Amount($Amount) { ([double] $Amount).ToString('0.00', [cultureinfo]::InvariantCulture) }

# The groups, each with the tier it belongs to ('' for a group of no tier: the edge group, a cluster's group).
$groups = [ordered] @{}
foreach ($key in $system.azure.resourceGroups.Keys) {
    $groups[[string] $system.azure.resourceGroups[$key]] = if ($tierOf.Values -contains [string] $key) { [string] $key } else { '' }
}
# Runtime aks-argocd: the nodes, their disks and the load balancer are in the node resource group AKS creates
# (infra/cluster.bicep names it <cluster group>-nodes); the seed lets the plan identity read its cost once it exists.
$clusterGroups = @()
if ([string] $system.system['runtime'] -eq 'aks-argocd' -and $system.azure.resourceGroups['cluster']) {
    $clusterGroup = [string] $system.azure.resourceGroups.cluster
    if (-not $groups.Contains("$clusterGroup-nodes")) { $groups["$clusterGroup-nodes"] = '' }
    $clusterGroups = @($clusterGroup, "$clusterGroup-nodes")
}
$frontDoor = $system.azure['frontDoor']
if ($frontDoor -is [Collections.IDictionary] -and $frontDoor['resourceGroup']) {
    if ($frontDoor['dormant']) { Write-Host "Front Door is dormant (azure.frontDoor.dormant): $($frontDoor.resourceGroup) is not read." }
    elseif (-not $groups.Contains([string] $frontDoor.resourceGroup)) { $groups[[string] $frontDoor.resourceGroup] = '' }
}

# Complete UTC days only: the last one, the seven that end with it, and its month so far.
$now = [datetime]::UtcNow
$asOf = $now.Date.AddDays(-1)
$weekStart = $asOf.AddDays(-6)
$monthStart = [datetime]::new($asOf.Year, $asOf.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
$from = if ($weekStart -lt $monthStart) { $weekStart } else { $monthStart }
$dayKey = { param([datetime] $Day) [int] $Day.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture) }
$asOfKey = & $dayKey $asOf
$weekKey = & $dayKey $weekStart
$monthKey = & $dayKey $monthStart

$retry = @{ Attempts = $Attempts; MaxWaitSeconds = $MaxWaitSeconds }

# How many of the three numbers of the system and of each entry a cost document leaves null.
$nulls = {
    param($Of)
    $count = 0
    foreach ($part in @($Of['system']) + @($Of['environments'] | Where-Object { $_ })) {
        foreach ($key in 'yesterday', 'last7Days', 'monthToDate') { if ($null -eq $part[$key]) { $count++ } }
    }
    $count
}
# The published file, when there is one that reads as a cost document.
$before = $null
if ($Published -and (Test-Path -LiteralPath $Published -PathType Leaf)) {
    try { $before = Get-Content -LiteralPath $Published -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-Host "The published cost.json could not be read as JSON ($($_.Exception.Message)): it does not count." }
    if ($before -isnot [Collections.IDictionary] -or -not $before['asOf'] -or $before['system'] -isnot [Collections.IDictionary]) { $before = $null }
}

# Runtime aks-argocd: the cluster's own status file, which the estimate of each environment's part is read from. Asked
# once a run; $null when it does not answer (a stopped cluster, a system without a dashboard).
$statusUrl = if ($clusterGroups.Count -gt 0) { "https://$slug-cluster.$([string] $system.cluster['domain'])/cluster.json" } else { '' }
$status = $null
$statusError = ''
if ($statusUrl -and $system.cluster['dormant']) { $statusError = 'the cluster is dormant, cluster.dormant in system.json' }
elseif ($statusUrl) {
    try { $status = Invoke-RestMethod -Uri $statusUrl -TimeoutSec 30 }
    catch { $statusError = (("$($_.Exception.Message)" -split '\r?\n')[0]).Trim() }
}
# A published file without the estimate was written while the status file did not answer. Once it answers, that file
# is not complete: a check that waits for the estimate after a wake would wait up to -EveryHours hours for it.
$estimateDue = $false
if ($status -and $before) {
    $estimateDue = @($before['environments'] | Where-Object { $_ -is [Collections.IDictionary] -and $_['estimate'] }).Count -eq 0
}

# Cost changes by the day and Cost Management throttles its readers: a complete file of the last complete day is
# read again only in this system's hours.
if ($EveryHours -gt 1 -and $before -and -not $estimateDue -and [string] $before['asOf'] -eq (Format-Day $asOf) -and (& $nulls $before) -eq 0) {
    $offset = 0
    foreach ($character in $slug.ToCharArray()) { $offset += [int] $character }
    $offset = $offset % $EveryHours
    if ($now.Hour % $EveryHours -ne $offset) {
        $hours = @(0..23 | Where-Object { $_ % $EveryHours -eq $offset } | ForEach-Object { '{0:00}' -f $_ }) -join ', '
        Write-Skip "cost.json is not written: the published file is as of $($before['asOf']) and complete, and Azure is asked again at $hours UTC (every $EveryHours hours; now it is $($now.ToString('HH:mm', [cultureinfo]::InvariantCulture)) UTC)"
        exit 0
    }
}
function Invoke-CostQuery([string] $Uri, [string] $BodyPath) {
    # The kit's cost query (get-fleet-limits.ps1): az rest, and the one known transient, 429, tried again after a
    # pause (principle 004). Azure names the pause in its answer ("retry after N seconds") or not at all.
    for ($attempt = 1; ; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(az rest --method post --output json --uri $Uri --body "@$BodyPath" 2>&1)
        $succeeded = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if ($succeeded) {
            return (@($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n") | ConvertFrom-Json
        }
        $message = (@($output | ForEach-Object { "$_" }) -join ' ').Trim()
        if ($message -notmatch '(?i)\b429\b|too many requests') { throw $message }
        $named = [regex]::Match($message, '(?i)retry(?:ing)?[ -]after\D{0,12}(\d+)')
        $wait = if ($named.Success) { [int] $named.Groups[1].Value + 1 } else { 20 * $attempt }
        if ($attempt -ge $retry.Attempts) { throw "throttled (HTTP 429) on each of $($retry.Attempts) attempts" }
        if ($wait -gt $retry.MaxWaitSeconds) { throw "throttled (HTTP 429), and Azure asks to wait $wait s, more than the $($retry.MaxWaitSeconds) s this run waits" }
        Write-Host "Cost Management answered 429 (too many requests): attempt $attempt of $($retry.Attempts), next in $wait s."
        Start-Sleep -Seconds $wait
    }
}

function Get-GroupCost([string] $Group, [string] $BodyPath) {
    # Every row of the group's answer as { Day, Tag, Service, Cost, Currency }; an answer comes in pages.
    $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $rows = [Collections.Generic.List[object]]::new()
    for ($page = 1; $uri; $page++) {
        if ($page -gt 50) { throw 'more than 50 pages' }
        $answer = Invoke-CostQuery $uri $BodyPath
        $columns = @($answer.properties.columns | ForEach-Object { [string] $_.name })
        $at = @{}
        foreach ($name in 'Cost', 'UsageDate', 'TagValue', 'ServiceName', 'Currency') {
            $at[$name] = $columns.IndexOf($name)
            if ($at[$name] -lt 0) { throw "the answer has no column $name (columns: $($columns -join ', '))" }
        }
        foreach ($row in @($answer.properties.rows)) {
            $rows.Add([pscustomobject] @{
                    Day      = [int] $row[$at.UsageDate]
                    Tag      = "$($row[$at.TagValue])".Trim()
                    Service  = "$($row[$at.ServiceName])".Trim()
                    Cost     = [double] $row[$at.Cost]
                    Currency = "$($row[$at.Currency])".Trim()
                })
        }
        $uri = [string] $answer.properties.nextLink
    }
    , $rows
}

Write-Host "==> Cost of $slug`: $($groups.Count) resource groups ($($groups.Keys -join ', ')), $(Format-Day $from) to $(Format-Day $asOf) (UTC)"
$PSNativeCommandUseErrorActionPreference = $false
$null = az account show --output none 2>&1
$signedIn = $LASTEXITCODE -eq 0
$PSNativeCommandUseErrorActionPreference = $true
if (-not $signedIn) {
    Write-Fail 'no Azure sign-in: azure/login in the workflow, or az login for a run by hand'
    exit 1
}

function Set-QueryBody([string] $BodyPath, [string[]] $ResourceIds = @()) {
    # The query: the days read, by day, tag "environment" and service; of the whole scope, or of the named resources.
    $dataset = @{
        granularity = 'Daily'
        aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        grouping    = @(@{ type = 'TagKey'; name = 'environment' }, @{ type = 'Dimension'; name = 'ServiceName' })
    }
    if ($ResourceIds.Count -gt 0) { $dataset.filter = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($ResourceIds) } } }
    @{
        type       = 'ActualCost'
        timeframe  = 'Custom'
        timePeriod = @{ from = "$(Format-Day $from)T00:00:00Z"; to = "$(Format-Day $asOf)T23:59:59Z" }
        dataset    = $dataset
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $BodyPath -Encoding utf8NoBOM
}

$body = [IO.Path]::GetTempFileName()
$read = [ordered] @{}
# The split of the shared plans: rows that take a plan's cost from the entry of its tag and give each environment
# that runs on it an equal part. $planNeeds: per environment, the plan queries its numbers need; $planUnread: those
# that failed.
$splitRows = [Collections.Generic.List[object]]::new()
$planNeeds = @{}
foreach ($name in $environments) { $planNeeds[$name] = @() }
$planUnread = @()
try {
    Set-QueryBody $body
    foreach ($group in $groups.Keys) {
        try {
            $read[$group] = Get-GroupCost $group $body
            Write-Host "$group`: $($read[$group].Count) rows."
        }
        catch {
            # The first line says what Azure refused; the rest of az's message repeats the request.
            $reason = ("$($_.Exception.Message)" -split '\r?\n')[0].Trim()
            if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) + '...' }
            Write-Skip "$group`: cost not read: $reason"
        }
    }
    foreach ($key in $splits.Keys) {
        $split = $splits[$key]
        # Without the group's own answer the numbers of these environments are null anyway.
        if (-not $read.Contains($split.Group)) { continue }
        $label = "$($split.Plans -join ', ') in $($split.Group)"
        foreach ($user in $split.Users) { $planNeeds[$user] += $label }
        try {
            Set-QueryBody $body @($split.Plans | ForEach-Object { "/subscriptions/$subscription/resourceGroups/$($split.Group)/providers/Microsoft.Web/serverfarms/$_" })
            $ofPlans = Get-GroupCost $split.Group $body
            $moved = 0.0
            foreach ($row in $ofPlans) {
                if ($row.Cost -eq 0) { continue }
                $moved += $row.Cost
                $splitRows.Add([pscustomobject] @{ Day = $row.Day; Tag = $row.Tag; Service = $row.Service; Cost = - $row.Cost; Currency = $row.Currency })
                foreach ($user in $split.Users) {
                    $splitRows.Add([pscustomobject] @{ Day = $row.Day; Tag = $user; Service = $row.Service; Cost = $row.Cost / $split.Users.Count; Currency = $row.Currency })
                }
            }
            Write-Host "$label`: $($ofPlans.Count) rows, $(Format-Amount $moved) in the days read, split evenly among $($split.Users -join ', ')."
        }
        catch {
            $reason = ("$($_.Exception.Message)" -split '\r?\n')[0].Trim()
            if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) + '...' }
            $planUnread += $label
            Write-Skip "$label`: cost not read, so what $($split.Users -join ', ') cost is not known: $reason"
        }
    }
}
finally {
    Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
}
if ($read.Count -eq 0) {
    Write-Fail "Cost Management answered for none of the $($groups.Count) resource groups of ${slug}: nothing is written"
    exit 1
}

# Each row belongs to one entry: an environment of system.json (the tag, whatever its case), another value of the tag
# under its own name, or "shared" without one.
$entryOf = {
    param([string] $Tag)
    if (-not $Tag) { return $shared }
    $known = @($environments | Where-Object { $_ -eq $Tag })
    if ($known.Count -gt 0) { $known[0] } else { $Tag }
}
$rows = @(foreach ($group in $read.Keys) { foreach ($row in $read[$group]) { $row } })
$currencies = @($rows | ForEach-Object { $_.Currency } | Where-Object { $_ } | Sort-Object -Unique)
$mixed = $currencies.Count -gt 1
if ($mixed) { Write-Skip "Azure bills $slug in more than one currency ($($currencies -join ', ')): amounts are not added up" }
$hasYesterday = @($rows | Where-Object { $_.Day -eq $asOfKey }).Count -gt 0
if (-not $hasYesterday) { Write-Skip "Azure has no cost of $(Format-Day $asOf) for $slug yet: yesterday is not known" }

$unread = @($groups.Keys | Where-Object { -not $read.Contains($_) }) + $planUnread
# What Azure reports is $rows (the system's number); the entries are of $attributed: the same with the shared plans split.
$attributed = @($rows) + @($splitRows)
$unknown = 0
function Get-Amount([object[]] $Of, [string[]] $Needs) {
    # yesterday, last7Days and monthToDate of the given rows, and their services by cost; null where a group (or a
    # query of shared plans) these numbers need was not read.
    $missing = @($Needs | Where-Object { $unread -contains $_ })
    $amount = [ordered] @{ yesterday = $null; last7Days = $null; monthToDate = $null; topServices = @() }
    if ($mixed -or $missing.Count -gt 0) { $script:unknown += 3; return $amount }
    $sum = {
        param([int] $Start)
        $added = 0.0
        foreach ($row in $Of) { if ($row.Day -ge $Start -and $row.Day -le $asOfKey) { $added += $row.Cost } }
        $added
    }
    if ($hasYesterday) { $amount.yesterday = [Math]::Round((& $sum $asOfKey), 2) } else { $script:unknown++ }
    $amount.last7Days = [Math]::Round((& $sum $weekKey), 2)
    $amount.monthToDate = [Math]::Round((& $sum $monthKey), 2)
    $byService = @{}
    foreach ($row in $Of) {
        if ($row.Service -and $row.Day -ge $monthKey -and $row.Day -le $asOfKey) { $byService[$row.Service] = $row.Cost + [double] $byService[$row.Service] }
    }
    $amount.topServices = @($byService.Keys | ForEach-Object { [pscustomobject] @{ Name = [string] $_; Cost = [Math]::Round([double] $byService[$_], 2) } } |
            Where-Object { $_.Cost -ge 0.01 } | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true }, @{ Expression = 'Name' } | Select-Object -First 3 |
            ForEach-Object { [ordered] @{ name = $_.Name; monthToDate = $_.Cost } })
    $amount
}

$others = @($attributed | ForEach-Object { & $entryOf $_.Tag } | Where-Object { $_ -ne $shared -and $environments -notcontains $_ } | Sort-Object -Unique)
$entries = @(foreach ($name in @($environments) + $others + $shared) {
        # An environment's resources are in the group of its tier and in the groups of no tier; anything else may be anywhere.
        $needs = if ($environments -contains $name) { @($groups.Keys | Where-Object { $groups[$_] -in '', $tierOf[$name] }) + $planNeeds[$name] } else { @($groups.Keys) }
        $amount = Get-Amount @($attributed | Where-Object { (& $entryOf $_.Tag) -eq $name }) $needs
        $entry = [ordered] @{ name = $name }
        foreach ($key in $amount.Keys) { $entry[$key] = $amount[$key] }
        $entry
    })
# Runtime aks-argocd: each environment's part of the cluster, by what its namespace requests (see the help).
if ($clusterGroups.Count -gt 0) {
    $shares = @{}
    if ($status) {
        $running = @($status.namespaces | ForEach-Object { $space = [string] $_.name; $_.pods | Where-Object { $_ -and $_.phase -notin 'Succeeded', 'Failed' } | ForEach-Object { [pscustomobject] @{ Space = $space; Cpu = [double] $_.cpu.requests; Memory = [double] $_.memory.requests } } })
        $allCpu = ($running | Measure-Object -Property Cpu -Sum).Sum
        $allMemory = ($running | Measure-Object -Property Memory -Sum).Sum
        if ($allCpu -gt 0 -and $allMemory -gt 0) {
            foreach ($name in $environments) {
                $own = @($running | Where-Object { $_.Space -eq "$slug-$name" })
                $shares[$name] = (((($own | Measure-Object -Property Cpu -Sum).Sum) / $allCpu) + ((($own | Measure-Object -Property Memory -Sum).Sum) / $allMemory)) / 2
            }
        }
        else { Write-Skip "$statusUrl lists no pod that requests CPU and memory: no estimate of each environment's part of the cluster" }
    }
    else {
        Write-Skip "$statusUrl did not answer ($statusError): no estimate of each environment's part of the cluster"
    }
    if ($shares.Count -gt 0) {
        # What the cluster costs and no environment's tag claims: the rows of its two groups without the tag.
        $clusterRows = @(foreach ($group in $clusterGroups) { if ($read.Contains($group)) { $read[$group] | Where-Object { (& $entryOf $_.Tag) -eq $shared } } })
        $ofCluster = Get-Amount $clusterRows $clusterGroups
        foreach ($entry in $entries) {
            if (-not $shares.ContainsKey($entry.name)) { continue }
            $share = [double] $shares[$entry.name]
            $part = { param($Amount) if ($null -eq $Amount) { $null } else { [Math]::Round([double] $Amount * $share, 2) } }
            $entry.estimate = [ordered] @{
                share       = [Math]::Round($share, 4)
                yesterday   = & $part $ofCluster.yesterday
                last7Days   = & $part $ofCluster.last7Days
                monthToDate = & $part $ofCluster.monthToDate
            }
        }
        Write-Host "Estimated part of the cluster (by requested CPU and memory): $(@($environments | ForEach-Object { '{0} {1:P0}' -f $_, [double] $shares[$_] }) -join ', ')."
    }
}
$total = Get-Amount $rows @($groups.Keys)
# The entries add up to the system's number to the cent: each is rounded on its own, and the cent or two that leaves
# over goes to the first environment (to the first entry it does not make negative, when it would do that to an
# environment that cost nothing). Only where every number is known.
foreach ($key in 'yesterday', 'last7Days', 'monthToDate') {
    if ($null -eq $total[$key] -or @($entries | Where-Object { $null -eq $_[$key] }).Count -gt 0) { continue }
    $remainder = [decimal] $total[$key]
    foreach ($entry in $entries) { $remainder -= [decimal] $entry[$key] }
    if ($remainder -eq 0) { continue }
    $able = @($entries | Where-Object { [decimal] $_[$key] + $remainder -ge 0 })
    $takes = if ($able.Count -gt 0) { $able[0] } else { $entries[0] }
    $takes[$key] = [double] ([decimal] $takes[$key] + $remainder)
    Write-Host "Rounding: $(Format-Amount $remainder) of $key goes to $($takes.name), so that the entries add up to the system's $(Format-Amount $total[$key])."
}
$document = [ordered] @{
    generated    = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
    currency     = if ($currencies.Count -eq 1) { $currencies[0] } else { $null }
    asOf         = Format-Day $asOf
    system       = [ordered] @{ yesterday = $total.yesterday; last7Days = $total.last7Days; monthToDate = $total.monthToDate }
    environments = $entries
}

$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

# A run that Azure refused or throttled in part does not replace a recent file that knows more.
$unread = @($groups.Keys | Where-Object { -not $read.Contains($_) }) + $planUnread
if ($unread.Count -gt 0 -and $before) {
    $recent = @((Format-Day $asOf), (Format-Day $asOf.AddDays(-1))) -contains [string] $before['asOf']
    $beforeNulls = & $nulls $before
    $nowNulls = & $nulls $document
    if ($recent -and $beforeNulls -lt $nowNulls) {
        Write-Skip "cost.json is not written: $($unread -join '; ') could not be read, which leaves $nowNulls numbers null; the published file as of $($before['asOf']) leaves $beforeNulls null and stays"
        exit 0
    }
}

[IO.File]::WriteAllText($target, "$($document | ConvertTo-Json -Depth 10)`n")
$month = if ($null -ne $total.monthToDate) { "$(Format-Amount $total.monthToDate) $($document.currency) since $(Format-Day $monthStart)" } else { 'the month to date not known' }
Write-Pass "$target`: $slug as of $(Format-Day $asOf): $month, $($entries.Count) entries ($(@($entries | ForEach-Object { $_.name }) -join ', ')), $($read.Count) of $($groups.Count) resource groups read, $unknown numbers not determined"
