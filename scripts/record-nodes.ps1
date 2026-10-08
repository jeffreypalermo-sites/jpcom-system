#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Commits the nodes an application with its own runtime reported to environments/<env>/nodes.json on main.

.DESCRIPTION
    Steps "Record nodes" and "Record nodes after revert" of the Octopus project <slug>-<deployable> whose deployable
    brings its own runtime (system.json hosting "own"); octopus/projects.tf inlines this file for both. "Record
    nodes" stands right after "Verify deployable" and runs only when that step succeeded.

    "Record nodes after revert" stands right after "Verify revert" and runs only when the deployment has failed. A
    failed deployment goes back to the version before with the deploy.ps1 of the release that failed, which may
    have changed what the application runs on (a region more, another address). When "Verify revert" found that the
    version before runs again and its verify.ps1 reported nodes, this step records them, so that the record says
    what runs (principle 002). It reads the output variables of "Verify revert" instead of those of "Verify
    deployable", and names the version before in its commit ("Pin version" recorded it). When "Verify revert" did
    not pass, or nothing was put back, there is no report: the record stays as it is.

    Why a step of its own. "Verify deployable" runs the application's verify.ps1 (scripts/invoke-application.ps1),
    and a step that runs code from an application's repository does not receive GitHub.Token, which writes to main of
    the system repository (octopus/variables.tf, token_steps). This step receives the token and runs nothing of the
    application's: it has no package, and it starts no script. All it takes from the step before is text, the output
    variables NodesReported and Nodes of "Verify deployable": what verify.ps1 wrote to its nodesFile, unread. That
    text is the application's and is treated as such: it is parsed as JSON, checked against the rules below, and
    only the known fields, with the types the rules name, are written, under the name of this project's deployable,
    in the file of this deployment's environment. A text can keep the record from being written, or record nodes
    the application does not have; it decides nothing else of what is committed.

    The limits are this step's own. "Verify deployable" hands on no file larger than 256 KB, but it is the step that
    runs the application's code, and a script may be able to write the service message that sets an output variable
    itself: nothing that step says is relied on here. Before the text is parsed it must be at most 64 KB (UTF-8).
    Parsed, it holds at most 100 nodes, and every field has its length and its characters (ConvertTo-NodeRecord
    below). 100 nodes of the longest values allowed are under 64 KB. The two variables are content to check and
    nothing else: a text is checked whatever NodesReported says.

    The rules (the contract is in the header of scripts/invoke-application.ps1). One JSON object with the field
    names of a deployable in the dashboard's topology:
      nodes         required: a list of at least one node, each { "url": an https address with a public host name,
                    each once; optional "name", "region" and "role" (primary or standby) }
      frontDoor     optional (or null): an https address with a public host name
      healthPath, alivePath, versionPath   optional: paths that start with /
      healthReport  optional: true or false (false: the hourly Health report does not ask these nodes)
    Each field has an allow-list (ConvertTo-NodeRecord below says which characters and how long), and a value
    outside it makes the report invalid: nothing is stripped or repaired.
    The record is committed as { "<deployable>": { ... } } next to the other deployables' entries, keys in order,
    through the contents API with GitHub.Token, the way "Pin version" commits versions.json (scripts/pin-version.ps1:
    read, compare, write, again after a 409). A record that is already the same is not committed again (a
    redeployment). No report: the step succeeds, says that the application reported no nodes, and leaves the record
    as it is. The dashboard's deployment (scripts/deploy-staticwebapp.ps1) reads the record; the system workflow
    ignores a push that changes only nodes.json.

    A record that cannot be written does not fail the deployment. This step runs after "Verify deployable" passed:
    the version runs and answers, and taking a healthy deployment back ("Revert deployable", "Revert pin") because
    its nodes could not be written down would put a worse state in place of a better one. So the step ends
    successfully with ONE warning line that says what was not recorded, why, and what follows: for a report that
    breaks a rule or a limit (every problem named), for a nodes.json on main that is not a JSON object, for GitHub
    not answering after the retries of a known transient failure (no answer, 408, 429, 5xx: four attempts), for a
    file that changed at each of four attempts to write it, for a request GitHub refuses, and for an error of this
    script. Octopus then shows the deployment as succeeded with warnings, which the kit's test-deployment-logs.ps1
    and the fleet's log finding report; the dashboard keeps the nodes of the last record meanwhile.
    One failure stays a failure: GitHub.Token did not reach the step. That is a system that does not work (the
    scope of the variable leaves the step out), not a record that could not be written.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$deployable = [string] $OctopusParameters['Deployable.Name']
# After a revert the nodes are those of the version before, as "Verify revert" reported them. The version is taken
# from "Pin version", a step of the system's own, not from the step that ran the application's script.
$afterRevert = [string] $OctopusParameters['Octopus.Step.Name'] -eq 'Record nodes after revert'
$source = if ($afterRevert) { 'Verify revert' } else { 'Verify deployable' }
$version = if ($afterRevert) { [string] $OctopusParameters['Octopus.Action[Pin version].Output.PreviousVersion'] } else { [string] $OctopusParameters['Octopus.Release.Number'] }
$report = [string] $OctopusParameters["Octopus.Action[$source].Output.Nodes"]
# A text is a report whatever the flag says: both are the word of a step that ran the application's code.
$reported = $report.Length -gt 0 -or [string] $OctopusParameters["Octopus.Action[$source].Output.NodesReported"] -eq 'True'
# The most a report may hold before it is parsed (the header says why the limit is here).
$largest = 64KB

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

function Get-HttpStatus {
    # The status of a failed call, 0 when it had no answer (a name that does not resolve, a timeout, a lost connection).
    param([Parameter(Mandatory)] [Management.Automation.ErrorRecord] $ErrorRecord)
    $response = if ($ErrorRecord.Exception.PSObject.Properties['Response']) { $ErrorRecord.Exception.Response } else { $null }
    if ($response) { return [int] $response.StatusCode }
    return 0
}

function Invoke-GitHub {
    # One call of the contents API, sent again only for a failure that is known to pass (principle 004): no answer,
    # or 408, 429, 500, 502, 503 or 504. Four attempts, 5, 10 and 15 seconds apart; each retry is one line of
    # information. Any other failure, and the fourth of these, is thrown as it came. The write may be sent again
    # too: it names the version of the file it replaces (sha), so a write whose answer was lost and that is sent a
    # second time is refused (409), the file is read again, and the record is found written.
    param([Parameter(Mandatory)] [hashtable] $Call, [Parameter(Mandatory)] [string] $What)
    for ($attempt = 1; $true; $attempt++) {
        try { return Invoke-RestMethod @Call }
        catch {
            $status = Get-HttpStatus -ErrorRecord $_
            if ($attempt -ge 4 -or $status -notin 0, 408, 429, 500, 502, 503, 504) { throw }
            Write-Host "GitHub did not $What ($(if ($status) { "HTTP $status" } else { 'no answer' }), attempt $attempt of 4); asking again in $(5 * $attempt) seconds."
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Save-NodeRecord {
    # Commits the record to environments/<env>/nodes.json on main: the loop of scripts/pin-version.ps1 (read,
    # compare, write, again after a 409). A conflict the next attempt gets past is information, not a warning.
    # Returns nothing when the record is on main, and otherwise why it is not (Why, and Next: what a person does).
    param([Parameter(Mandatory)] [Collections.IDictionary] $Record)
    $repository = [string] $OctopusParameters['System.Repository']
    $deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
    $path = "environments/$environmentName/nodes.json"
    $uri = "https://api.github.com/repos/$repository/contents/$path"
    $headers = @{
        Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $count = @($Record.nodes).Count
    $again = "Deploy $deployable $version to $environmentName again to record them."

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $sha = $null
        $text = '{}'
        try {
            $file = Invoke-GitHub -What "answer the read of $path" -Call @{ Uri = "${uri}?ref=main"; Headers = $headers }
            $sha = $file.sha
            $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
        }
        catch {
            # 404: the environment has no record yet.
            $status = Get-HttpStatus -ErrorRecord $_
            if ($status -ne 404) {
                return @{ Why = "$path could not be read from main of $repository ($(if ($status) { "HTTP $status" } else { "no answer: $($_.Exception.Message)" }))"; Next = $again }
            }
        }
        $recorded = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
        if ($recorded -isnot [Collections.IDictionary]) {
            return @{ Why = "$path on main of $repository is not a JSON object"; Next = "Correct the file by pull request, then deploy $deployable $version to $environmentName again." }
        }

        $before = if ($recorded.Contains($deployable)) { (ConvertTo-NodeRecord $recorded[$deployable]).Record } else { $null }
        if ($before -and ($before | ConvertTo-Json -Depth 5 -Compress) -ceq ($Record | ConvertTo-Json -Depth 5 -Compress)) {
            Write-Highlight "$path already records these $count node(s) of ${deployable}: nothing to commit."
            return
        }

        $recorded[$deployable] = $Record
        $ordered = [ordered] @{}
        foreach ($key in ($recorded.Keys | Sort-Object)) {
            $ordered[$key] = $recorded[$key]
        }
        $content = ($ordered | ConvertTo-Json -Depth 10) + "`n"
        $body = @{
            message = "Record the nodes of $deployable $version in $environmentName ($deployment)"
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
            branch  = 'main'
        }
        if ($sha) {
            $body.sha = $sha
        }

        try {
            $commit = Invoke-GitHub -What "answer the write of $path" -Call @{ Uri = $uri; Method = 'Put'; Headers = $headers; Body = ($body | ConvertTo-Json); ContentType = 'application/json' }
            Write-Highlight "Recorded $count node(s) of $deployable in ${environmentName}: $($commit.commit.html_url)"
            return
        }
        catch {
            # 409: another commit changed the file since it was read (or this write arrived and its answer was lost);
            # 422: the file was created since it was read as missing. Read it again.
            $status = Get-HttpStatus -ErrorRecord $_
            if ($status -in 409, 422 -and $attempt -lt 4) {
                Write-Host "nodes.json changed while recording (attempt $attempt of 4); reading it again."
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            if ($status -in 409, 422) {
                return @{ Why = "$path on main of $repository changed at each of four attempts to write it (HTTP $status)"; Next = $again }
            }
            return @{ Why = "$path could not be written to main of $repository ($(if ($status) { "HTTP $status" } else { "no answer: $($_.Exception.Message)" }))"; Next = $again }
        }
    }
}

function Write-NotRecorded {
    # The one warning of a record that was not written. The step ends successfully after it: Octopus shows the
    # deployment as succeeded with warnings, and the steps that run only after a failure do not run. After a revert
    # the deployment has failed already, and the warning says what holds then.
    param([Parameter(Mandatory)] [string] $Why, [Parameter(Mandatory)] [string] $Next)
    $state = if ($afterRevert) { "The deployment had failed before this step, and this changes nothing of that: the revert was verified, and $version runs." } else { 'The deployment does not fail for it: the version was verified and runs.' }
    Write-Warning "The nodes of $deployable $version in $environmentName were not recorded: $Why. $state The dashboard keeps showing the nodes of the last record (environments/$environmentName/nodes.json on main). $Next"
}

if (-not $reported -and $afterRevert) {
    Write-Host "No nodes of $deployable to record after the revert in ${environmentName}: 'Verify revert' handed none on (it did not pass, nothing was put back, or its verify.ps1 wrote no nodesFile). environments/$environmentName/nodes.json stays as it is."
    return
}
if (-not $reported) {
    Write-Host "$deployable reported no nodes for $environmentName (its verify.ps1 wrote no nodesFile): environments/$environmentName/nodes.json stays as it is, and without an entry there the dashboard leaves $deployable out of $environmentName."
    return
}

$rules = "Correct what the application's verify.ps1 writes to its nodesFile (the kit's reference.md, 'An application that brings its own runtime'), then deploy a new release."
$bytes = [Text.Encoding]::UTF8.GetByteCount($report)
if ($bytes -gt $largest) {
    Write-NotRecorded -Why "the report is $bytes bytes, and a report is at most $largest (100 nodes of the longest names and addresses are less)" -Next $rules
    return
}

# -NoEnumerate: a text that holds a list of one object must not pass for that object.
$read = $null
$isJson = $true
try { $read = $report | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $isJson = $false }
$checked = if ($isJson) { ConvertTo-NodeRecord $read } else { @{ Record = $null; Problems = [string[]] @('the file is not JSON') } }
if ($checked.Problems.Count -gt 0) {
    Write-NotRecorded -Why "the report breaks the rules of a record ($($checked.Problems -join '; '))" -Next $rules
    return
}

# GitHub.Token is scoped to the steps that read it (octopus/variables.tf, token_steps): a step that is not among them
# reads it empty. That is a system that does not work, not a record that could not be written: the step fails.
if (-not [string] $OctopusParameters['GitHub.Token']) {
    Fail-Step "GitHub.Token did not reach step '$([string] $OctopusParameters['Octopus.Step.Name'])': octopus/variables.tf hands it only to the steps of local.token_steps. A release made before a step was replaced has that step under its old id and gets no token there: make a new release."
}

# Whatever else keeps the record from main, an error of this script too, is one warning: a deployment that was just
# verified is not taken back because its nodes could not be written down.
$failed = $null
try { $failed = Save-NodeRecord -Record $checked.Record }
catch { $failed = @{ Why = "the step could not finish ($($_.Exception.Message))"; Next = "Deploy $deployable $version to $environmentName again to record them." } }
if ($failed) { Write-NotRecorded -Why $failed.Why -Next $failed.Next }
