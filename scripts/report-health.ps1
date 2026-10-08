#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reports the health of every node of the environment in Octopus: one line per node, and a failed run when one is
    not healthy.

.DESCRIPTION
    Runbook "Health report" of the Octopus project <slug>-system (scheduled hourly in every environment;
    octopus/runbooks.tf inlines this file). Capability CAP-076. Octopus has no page for a system's own health tiles,
    so this puts the answer where Octopus shows it: the runbook's last run per environment is green or red on the
    project's Operations overview, and its highlights name every node (region, role, status, time to answer, version)
    with a link to the health dashboard, the live view.

    Nodes are what the environment's stack reports: every app, its standby in a second region, and the static sites;
    and the environment's public address when it has a Front Door endpoint. Apps are asked for /alive, not for the
    health check: the health check connects to the database, and an hourly question would keep a serverless free-offer
    database awake until its monthly allowance is used up. An app that has no release yet answers on / instead. A
    Free-plan app that idled is given time to start (three attempts).

    A deployable that brings its own runtime (system.json hosting "own"; the variable System.OwnDeployables names
    them) is no node of the stack: the system creates nothing for it and does not know what it runs on. The
    application says it: its deployment records its nodes in environments/<env>/nodes.json on main of the system
    repository (step "Record nodes"), and this report asks every recorded node, and the recorded public address.
      Which path     the recorded liveness path (alivePath); without one the recorded health path; without that /.
                     Liveness first, for the reason the nodes of the stack are asked /alive: a health check may
                     reach a database, and a question every hour would keep it awake.
      What it costs  every recorded node is asked once an hour in every environment, and that wakes a node that
                     scaled to zero. An application that does not want that records "healthReport": false: its
                     nodes are then not asked here, and the dashboard shows them all the same.
      Healthy        a status of 200. A node may have scaled to zero: an attempt waits 30 seconds, there are three,
                     10 seconds apart, and a late answer or one on a later attempt is a healthy node whose line says
                     how long it took. A redirect is not followed and is not healthy; the line says that it was one.
      Which address  only https and a public host name (the rule of the record, ConvertTo-NodeRecord): a worker
                     must not be sent to ask an address inside its own network. No credential goes with a request.
      The version    from the recorded version path, at most 16 KB of JSON; shown only when it is 1 to 64 letters,
                     digits, dots and hyphens, and as "not readable" otherwise: a node's answer is not text for
                     this log. The versions of the nodes of the stack are shown by the same rule.

    The record is read without a credential, from the repository's public address
    (https://raw.githubusercontent.com/<repository>/main/environments/<env>/nodes.json; at most 1 MB): a runbook does
    not receive GitHub.Token, which writes to main (octopus/variables.tf, token_steps), and reading one public file is
    no reason to hand it to an hourly run. The kit creates system repositories public, and the dashboard reads
    versions.json the same way. What follows from that:
      200                 every such application with an entry is asked; one without an entry is named as not asked
      404                 no record: no application reported nodes yet in this environment, or the repository is
                          private. The applications are named as not asked, and the run goes on
      anything else       the record could not be read (three attempts): the applications are named, the other nodes
                          are still asked, and the run fails, because it could not ask what it should
      an entry that breaks the rules of the record   as "could not be read", with every problem named
    An environment in which nothing can be asked (the stack is to create no deployable there: no variable
    System.StackDeployables in that environment; and no application has recorded nodes) says so and succeeds; that
    green says nothing about the applications. A stack that reports no node where it is to create a deployable
    fails the run.

    The run has 40 minutes. The runbook is hourly, and a run that is still asking when the next one starts tells
    nobody anything: a hundred nodes that do not answer would take three hours. A node that was not reached in that
    time is named as not asked, not as down, and the run fails: it could not ask what it should.
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
$edgeGroup = [string] $OctopusParameters['Azure.EdgeResourceGroup']
$repository = [string] $OctopusParameters['System.Repository']

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs

function Get-Answer {
    # One GET with up to three attempts: the status, the milliseconds of the answering attempt, and 0 when no attempt
    # was answered.
    param([Parameter(Mandatory)] [string] $Uri, [int] $TimeoutSeconds = 100)
    $status = 0
    $milliseconds = 0
    $attempts = 0
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $attempts = $attempt
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try { $status = [int] (Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
        $milliseconds = [int] $clock.ElapsedMilliseconds
        if ($status -eq 200 -or $status -eq 404) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    @{ Status = $status; Milliseconds = $milliseconds; Attempts = $attempts }
}

function ConvertTo-ShownVersion {
    # A version as a node answered it, for a line of this log: the part before "+", when that is 1 to 64 letters,
    # digits, dots and hyphens. '' when the node named none, and "not readable" for anything else: what a node
    # answers is its own text (a line break, a service message for Octopus), and it is not printed.
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return '' }
    # A version that JSON wrote as a number (2, 1.5) is a version too; a list or an object is not.
    if ($Value -isnot [string] -and $Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return 'not readable' }
    $text = ("$Value" -split '\+')[0]
    if ($text -cmatch '^[0-9A-Za-z.-]{1,64}\z') { return $text }
    return 'not readable'
}

function Invoke-PlainGet {
    # One GET that follows no redirect, sends no credential, and reads at most MaximumBytes of the answer (none of
    # it with 0), all within the timeout. Returns Status (0: no answer in time), Text, and TooLarge when the answer
    # was longer than it may be.
    param([Parameter(Mandatory)] [string] $Uri, [int] $TimeoutSeconds = 30, [int] $MaximumBytes = 0)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $limit = [Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))
    $response = $null
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $limit.Token).GetAwaiter().GetResult()
        $status = [int] $response.StatusCode
        if ($MaximumBytes -le 0 -or $status -ne 200) { return @{ Status = $status; Text = ''; TooLarge = $false } }
        $stream = $response.Content.ReadAsStreamAsync($limit.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new($MaximumBytes + 1)
        $read = 0
        while ($read -lt $buffer.Length) {
            $count = $stream.ReadAsync($buffer, $read, $buffer.Length - $read, $limit.Token).GetAwaiter().GetResult()
            if ($count -le 0) { break }
            $read += $count
        }
        if ($read -gt $MaximumBytes) { return @{ Status = $status; Text = ''; TooLarge = $true } }
        return @{ Status = $status; Text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read); TooLarge = $false }
    }
    catch { return @{ Status = 0; Text = ''; TooLarge = $false } }
    finally {
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $limit.Dispose()
    }
}

function Get-RecordedAnswer {
    # One GET of a recorded address with up to three attempts, 30 seconds each: the status, the milliseconds of the
    # last attempt, how many there were, and 0 as the status when none was answered. A redirect and a 404 are
    # answers: asking again would not change them.
    param([Parameter(Mandatory)] [string] $Uri)
    $status = 0
    $milliseconds = 0
    $attempts = 0
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $attempts = $attempt
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $status = [int] (Invoke-PlainGet -Uri $Uri -TimeoutSeconds 30).Status
        $milliseconds = [int] $clock.ElapsedMilliseconds
        if ($status -eq 200 -or $status -eq 404 -or ($status -ge 300 -and $status -lt 400)) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    @{ Status = $status; Milliseconds = $milliseconds; Attempts = $attempts }
}

function Get-RunningVersion {
    # The version the app reports (the part before "+"), or '' when it reports none.
    param([Parameter(Mandatory)] [string] $Url)
    try {
        $answer = Invoke-RestMethod -Uri "$Url/_version" -TimeoutSec 30
        return ConvertTo-ShownVersion $answer.version
    }
    catch { return '' }
}

function Get-ReportedVersion {
    # The version a node of an application with its own runtime reports at its recorded version path (JSON with
    # "version", at most 16 KB), as ConvertTo-ShownVersion shows it; '' when it answers none.
    param([Parameter(Mandatory)] [string] $Uri)
    $got = Invoke-PlainGet -Uri $Uri -TimeoutSeconds 30 -MaximumBytes 16KB
    if ($got.TooLarge) { return 'not readable' }
    if ($got.Status -ne 200) { return '' }
    $answer = try { $got.Text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
    if ($answer -isnot [Collections.IDictionary] -or -not $answer.Contains('version')) { return '' }
    return ConvertTo-ShownVersion $answer['version']
}

function ConvertTo-NodeRecord {
    # One deployable's nodes, as its verify.ps1 reported them or as environments/<env>/nodes.json records them,
    # reduced to the fields the dashboard's topology knows, in one order. Returns Record ($null when a rule is
    # broken) and Problems (every broken rule, by field; never the value, which is the application's text). It asks
    # nothing: the same input gives the same result.
    # scripts/record-nodes.ps1, scripts/deploy-staticwebapp.ps1 and scripts/report-health.ps1 hold this function,
    # line for line: octopus/ inlines one file per step, so they cannot share it.
    #
    # Every value is an application's text and ends in a public file, in the source of a diagram, in a page and in
    # addresses that are asked. So each field has an allow-list, and a value outside it makes the record invalid:
    # nothing is stripped or repaired.
    #   name, region        one line: ASCII letters, digits, space and . _ - ; a letter or a digit first; at most 100
    #                       characters for a name, 40 for a region. That holds every name Azure allows for what an
    #                       application runs on (container apps, web apps, static sites, Front Door endpoints: letters,
    #                       digits and hyphens; clusters and virtual machines: also _ and .), a host name, and a
    #                       region by its name (eastus2) or its display name (East US 2). No [ ] < > % ! $ quote,
    #                       backslash or control character can occur.
    #   url, frontDoor      https://, a public host name, optionally a port, optionally a path of letters, digits and
    #                       . _ ~ - /; at most 300 characters. No user name, no query, no fragment and no percent sign:
    #                       the address is a base the dashboard adds paths to, and it is written into a diagram as a
    #                       link. A public host name: at least two labels of letters, digits and hyphens, the last one
    #                       starting with a letter (so no IP address in any spelling) and none of localhost, local,
    #                       internal and svc. Not http, and no address inside a network: the record is read by a
    #                       page in anyone's browser, which an https page does not let ask http, and by the hourly
    #                       Health report, whose worker must not be sent to ask an address inside its own network
    #                       (a metadata service, a container engine, a cluster's own API). The real guard there is
    #                       https itself: a worker that checks certificates does not talk to a host that cannot
    #                       show one for the name. The names are refused so that such a record is not written.
    #   healthPath, alivePath, versionPath   / first, then letters, digits, . _ ~ - / ? & = and %XX; at most 200
    #                       characters.
    #   healthReport        true or false. false: the hourly Health report does not ask these nodes (it would wake
    #                       a node that scaled to zero, every hour); the dashboard shows them all the same.
    #   nodes               at most 100. An application in every Azure region has fewer; each is a tile and a box of
    #                       a diagram that is rendered at every deployment of the dashboard.
    # At most 20 problems are named, with the number of the others: a report of a hundred broken nodes is one line of
    # a log, not three hundred.
    param([AllowNull()] [object] $Value)
    $problems = [Collections.Generic.List[string]]::new()
    if ($Value -isnot [Collections.IDictionary]) {
        return @{ Record = $null; Problems = [string[]] @('one JSON object is expected') }
    }
    $label = '^[A-Za-z0-9][A-Za-z0-9 ._-]*\z'
    $longest = @{ name = 100; region = 40 }
    $path = '^/(?:[A-Za-z0-9._~/?&=-]|%[0-9A-Fa-f]{2})*\z'
    $isAddress = {
        param([AllowNull()] [object] $Text)
        $address = $null
        $Text -is [string] -and $Text.Trim().Length -le 300 -and
        $Text.Trim() -cmatch '^https://(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?<last>[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?\z' -and
        $Matches['last'] -notin 'localhost', 'local', 'internal', 'svc' -and
        [uri]::TryCreate($Text.Trim(), [UriKind]::Absolute, [ref] $address) -and $address.Scheme -ceq 'https' -and $address.HostNameType -eq [UriHostNameType]::Dns
    }
    $addressRule = 'not an https address with a public host name (https://, a host name of at least two labels whose last starts with a letter and is none of localhost, local, internal and svc, an optional port and a path of letters, digits and . _ ~ - /, at most 300 characters; no http, IP address, user name, query, fragment or percent sign)'
    $record = [ordered] @{}
    if ($Value.Contains('frontDoor') -and $null -ne $Value['frontDoor']) {
        if (& $isAddress $Value['frontDoor']) { $record.frontDoor = ([string] $Value['frontDoor']).Trim() }
        else { $problems.Add("frontDoor: $addressRule") }
    }
    foreach ($key in 'healthPath', 'alivePath', 'versionPath') {
        if (-not $Value.Contains($key) -or $null -eq $Value[$key]) { continue }
        if ($Value[$key] -is [string] -and $Value[$key].Length -le 200 -and $Value[$key] -cmatch $path) { $record[$key] = [string] $Value[$key] }
        else { $problems.Add("${key}: not a path that starts with / (then letters, digits, . _ ~ - / ? & = and %XX; at most 200 characters)") }
    }
    if ($Value.Contains('healthReport') -and $null -ne $Value['healthReport']) {
        if ($Value['healthReport'] -is [bool]) { $record.healthReport = [bool] $Value['healthReport'] }
        else { $problems.Add('healthReport: not true or false') }
    }
    # Not as the value of an if: that would unroll a list of one node into the node.
    $listed = $null
    if ($Value.Contains('nodes')) { $listed = $Value['nodes'] }
    if ($listed -isnot [array] -or $listed.Count -eq 0) {
        $problems.Add('nodes: a list of at least one node is required')
    }
    elseif ($listed.Count -gt 100) {
        $problems.Add("nodes: $($listed.Count) nodes, and a record holds at most 100")
    }
    else {
        $nodes = [Collections.Generic.List[object]]::new()
        $seen = @{}
        for ($index = 0; $index -lt $listed.Count; $index++) {
            $entry = $listed[$index]
            if ($entry -isnot [Collections.IDictionary]) { $problems.Add("nodes[$index]: not an object"); continue }
            $node = [ordered] @{}
            foreach ($key in 'name', 'region', 'role') {
                if (-not $entry.Contains($key) -or $null -eq $entry[$key]) { continue }
                if ($entry[$key] -isnot [string] -or -not $entry[$key].Trim()) { $problems.Add("nodes[$index].${key}: not a text"); continue }
                $text = $entry[$key].Trim()
                if ($key -ne 'role' -and ($text.Length -gt $longest[$key] -or $text -cnotmatch $label)) {
                    $problems.Add("nodes[$index].${key}: not one line of at most $($longest[$key]) characters of letters, digits, spaces and . _ - that starts with a letter or a digit")
                    continue
                }
                $node[$key] = $text
            }
            if ($node.Contains('role') -and $node.role -cnotin 'primary', 'standby') { $problems.Add("nodes[$index].role: not primary or standby") }
            if (-not $entry.Contains('url') -or -not (& $isAddress $entry['url'])) { $problems.Add("nodes[$index].url: missing or $addressRule"); continue }
            $node.url = ([string] $entry['url']).Trim()
            $address = $node.url.TrimEnd('/').ToLowerInvariant()
            if ($seen.ContainsKey($address)) { $problems.Add("nodes[$index].url: the same address as nodes[$($seen[$address])]"); continue }
            $seen[$address] = $index
            $nodes.Add($node)
        }
        $record.nodes = $nodes.ToArray()
    }
    if ($problems.Count -gt 20) {
        $others = $problems.Count - 20
        $problems.RemoveRange(20, $others)
        $problems.Add("and $others more")
    }
    if ($problems.Count -gt 0) { return @{ Record = $null; Problems = [string[]] $problems.ToArray() } }
    return @{ Record = $record; Problems = [string[]] @() }
}

function Read-NodeRecord {
    # environments/<env>/nodes.json on main of the system repository, from its public address, without a credential
    # (the header says why), at most 1 MB. Status: 200 with Record (the parsed file), 404 (no record, or a private
    # repository), or whatever else the last of three attempts ended with (0: no answer; -1: an answer that is no
    # JSON object; -2: an answer of more than 1 MB).
    $uri = "https://raw.githubusercontent.com/$repository/main/environments/$environmentName/nodes.json"
    $got = @{ Status = 0; Text = ''; TooLarge = $false }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $got = Invoke-PlainGet -Uri $uri -TimeoutSeconds 30 -MaximumBytes 1MB
        if ($got.Status -eq 200 -or $got.Status -eq 404) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    if ($got.TooLarge) { return @{ Status = -2; Record = $null; Uri = $uri } }
    if ($got.Status -ne 200) { return @{ Status = [int] $got.Status; Record = $null; Uri = $uri } }
    # -NoEnumerate: a file that holds a list of one object must not pass for that object.
    $record = try { $got.Text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
    if ($record -isnot [Collections.IDictionary]) { return @{ Status = -1; Record = $null; Uri = $uri } }
    return @{ Status = 200; Record = $record; Uri = $uri }
}

$nodes = [Collections.Generic.List[hashtable]]::new()
foreach ($entry in @($outputs.deployables.value)) {
    $nodes.Add(@{ Name = [string] $entry.name; Where = "$($entry['region'] ?? 'home region'), primary"; Url = ([string] $entry.url).TrimEnd('/'); Static = $entry['hosting'] -eq 'staticwebapp' })
}
foreach ($entry in @(if ($outputs.ContainsKey('standby')) { $outputs.standby.value })) {
    $nodes.Add(@{ Name = [string] $entry.name; Where = "$($entry.region), standby"; Url = ([string] $entry.url).TrimEnd('/'); Static = $false })
}
if ($edgeGroup) {
    $PSNativeCommandUseErrorActionPreference = $false
    $edgeJson = az stack group show --name "stack-$slug-$environmentName-edge" --resource-group $edgeGroup --output json 2>$null
    $hasEdge = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($endpoint in @(if ($hasEdge) { ($edgeJson | ConvertFrom-Json -AsHashtable).outputs.endpoints.value })) {
        $nodes.Add(@{ Name = [string] $endpoint.name; Where = 'public address (Front Door)'; Url = ([string] $endpoint.url).TrimEnd('/'); Static = $false })
    }
}
# What the stack is to create here, and the applications that bring their own runtime: only a system that has such an
# application has these two variables (octopus/variables.tf). A stack without a node is right only where the first
# names an application and the second names none; anywhere else it is a fault, as it was before.
$own = @(([string] $OctopusParameters['System.OwnDeployables']) -split ',' | Where-Object { $_ })
$expected = @(([string] $OctopusParameters['System.StackDeployables']) -split ',' | Where-Object { $_ })
if ($nodes.Count -eq 0 -and -not ($own.Count -gt 0 -and $expected.Count -eq 0)) {
    Fail-Step "Stack stack-$slug-$environmentName reports no node."
}

# The nodes of the applications that bring their own runtime, as each recorded them.
$notAsked = [Collections.Generic.List[string]]::new()
$unread = [Collections.Generic.List[string]]::new()
if ($own.Count -gt 0) {
    $read = Read-NodeRecord
    if ($read.Status -eq 404) {
        $notAsked.Add("$($own -join ', '): $environmentName has no record of nodes ($($read.Uri) answers 404: no application has reported nodes there yet, or the repository is private)")
    }
    elseif ($read.Status -ne 200) {
        $why = switch ($read.Status) { 0 { 'no answer' } -1 { 'the file is not a JSON object' } -2 { 'the file is larger than 1 MB' } default { "HTTP $($read.Status)" } }
        $unread.Add("$($own -join ', '): the record of nodes could not be read ($($read.Uri): $why)")
    }
    else {
        foreach ($name in $own) {
            if (-not $read.Record.Contains($name)) {
                $notAsked.Add("${name}: environments/$environmentName/nodes.json on main has no entry for it (its verify.ps1 reports no nodes, or it was not deployed to $environmentName since it does)")
                continue
            }
            $checked = ConvertTo-NodeRecord $read.Record[$name]
            if ($checked.Problems.Count -gt 0) {
                $unread.Add("${name}: its entry in environments/$environmentName/nodes.json on main breaks the rules of the record ($($checked.Problems -join '; '))")
                continue
            }
            if ($checked.Record.Contains('healthReport') -and $checked.Record.healthReport -eq $false) {
                $notAsked.Add("${name}: its record of nodes says ""healthReport"": false, so this report leaves its nodes alone (an hourly question would wake a node that scaled to zero)")
                continue
            }
            # Liveness first, as for the nodes of the stack: a health check may reach a database, and a question
            # every hour would keep it awake.
            $path = if ($checked.Record.Contains('alivePath')) { [string] $checked.Record.alivePath } elseif ($checked.Record.Contains('healthPath')) { [string] $checked.Record.healthPath } else { '/' }
            $versionPath = if ($checked.Record.Contains('versionPath')) { [string] $checked.Record.versionPath } else { '' }
            # The rule of the record is https and a public host name. Held here once more, where the worker is sent:
            # a rule that was loosened elsewhere must not become a request to an address inside the network.
            $plain = @(@($checked.Record.nodes | ForEach-Object { [string] $_.url }) + @(if ($checked.Record.Contains('frontDoor')) { [string] $checked.Record.frontDoor }) | Where-Object { -not $_.StartsWith('https://', [StringComparison]::Ordinal) })
            if ($plain.Count -gt 0) {
                $unread.Add("${name}: its entry in environments/$environmentName/nodes.json on main has $($plain.Count) address(es) that are not https, and this report asks https only")
                continue
            }
            foreach ($node in @($checked.Record.nodes)) {
                $address = ([string] $node.url).TrimEnd('/')
                $title = if ($node.Contains('name')) { "$name $($node.name)" } else { "$name $(([uri] $address).Host)" }
                $where = "$(if ($node.Contains('region')) { $node.region } else { 'region not recorded' })$(if ($node.Contains('role')) { ", $($node.role)" }), its own runtime"
                $nodes.Add(@{ Name = $title; Where = $where; Url = $address; Static = $false; Own = $true; Path = $path; VersionPath = $versionPath })
            }
            if ($checked.Record.Contains('frontDoor')) {
                $nodes.Add(@{ Name = $name; Where = 'public address, its own runtime'; Url = ([string] $checked.Record.frontDoor).TrimEnd('/'); Static = $false; Own = $true; Path = $path; VersionPath = $versionPath })
            }
        }
    }
}
foreach ($line in $notAsked) { Write-Highlight "Not asked  $line." }
if ($nodes.Count -eq 0 -and $unread.Count -eq 0) {
    # Nothing the system created runs here, and no application has recorded nodes: there is nothing to ask.
    Write-Highlight "Nothing to ask in ${environmentName}: stack stack-$slug-$environmentName reports no node, and what runs there brings its own runtime ($($own -join ', ')) and has recorded no nodes. This run says nothing about it; step 'Verify deployable' of each one's own project checks it at every deployment."
    return
}

# The run's own limit: an hourly run that is still asking when the next one starts tells nobody anything.
$minutes = 40
$started = Get-Date
$unhealthy = 0
$asked = 0
$late = [Collections.Generic.List[string]]::new()
foreach ($node in $nodes) {
    if (((Get-Date) - $started).TotalMinutes -ge $minutes) {
        # Not asked is not down: the node is named, and counted with neither the healthy nor the unhealthy ones.
        $late.Add([string] $node.Name)
        continue
    }
    $asked++
    if ($node['Own']) {
        # A node of an application's own runtime: its recorded path, and time for a node that scaled to zero. A 404
        # there is an unhealthy node, not "no release yet": the application recorded the path itself. A redirect
        # is not followed: where it leads is not what the application recorded.
        $answer = Get-RecordedAnswer -Uri "$($node.Url)$($node.Path)"
        $healthy = $answer.Status -eq 200
        $version = if ($healthy -and $node.VersionPath) { Get-ReportedVersion -Uri "$($node.Url)$($node.VersionPath)" } else { '' }
        if (-not $healthy) { $unhealthy++ }
        $state = if ($healthy) { 'Healthy' } elseif ($answer.Status -eq 0) { 'Unreachable' } else { 'Unhealthy' }
        $redirect = if ($answer.Status -ge 300 -and $answer.Status -lt 400) { ', a redirect, which this report does not follow' } else { '' }
        $took = if ($answer.Status) { "HTTP $($answer.Status) in $($answer.Milliseconds) ms$(if ($answer.Attempts -gt 1) { " on attempt $($answer.Attempts)" })$redirect" } else { 'no answer in three attempts' }
        $line = "$state  $($node.Name) in ${environmentName}, $($node.Where): $took$(if ($version) { ", version $version" })  $($node.Url)$($node.Path)"
        if ($healthy) { Write-Highlight $line } else { Write-Warning $line }
        continue
    }
    $path = if ($node.Static) { '/' } else { '/alive' }
    $answer = Get-Answer -Uri "$($node.Url)$path"
    $note = ''
    if (-not $node.Static -and $answer.Status -eq 404) {
        # No release yet: the platform's default page answers, and the app's own paths do not exist.
        $answer = Get-Answer -Uri "$($node.Url)/"
        $note = ', no release yet'
    }
    $version = if ($node.Static -or $note) { '' } else { Get-RunningVersion -Url $node.Url }
    $healthy = $answer.Status -eq 200
    if (-not $healthy) { $unhealthy++ }
    $state = if ($healthy) { 'Healthy' } elseif ($answer.Status -eq 0) { 'Unreachable' } else { 'Unhealthy' }
    $line = "$state  $($node.Name) in ${environmentName}, $($node.Where): $(if ($answer.Status) { "HTTP $($answer.Status) in $($answer.Milliseconds) ms" } else { 'no answer' })$(if ($version) { ", version $version" })$note  $($node.Url)"
    if ($healthy) { Write-Highlight $line } else { Write-Warning $line }
}

$dashboard = @($outputs.deployables.value | Where-Object { $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
if ($dashboard) {
    Write-Highlight "Live view of every node of every environment: $($dashboard.url)"
}
foreach ($line in $unread) { Write-Warning "Not asked  $line." }
if ($late.Count -gt 0) {
    Write-Warning "Not asked  $($late.Count) node(s) of ${environmentName}: the run had asked for $minutes minutes and stopped there, so that it ends before the next hourly run starts. They are not counted as down: $($late -join ', ')."
}
$found = @(
    if ($unhealthy -gt 0) { "$unhealthy of $asked node(s) of $environmentName are not healthy" }
    if ($unread.Count -gt 0) { "the nodes of $($unread.Count) application(s) of $environmentName could not be asked: their record could not be read" }
    if ($late.Count -gt 0) { "$($late.Count) node(s) of $environmentName were not asked: the run stopped after $minutes minutes" }
)
if ($found.Count -gt 0) {
    $text = $found -join '; '
    Fail-Step "$($text.Substring(0, 1).ToUpperInvariant())$($text.Substring(1)).$(if ($unhealthy -eq 0 -and $asked -gt 0) { " The $asked node(s) that were asked are healthy." })"
}
Write-Highlight "All $($nodes.Count) node(s) of $environmentName are healthy."
