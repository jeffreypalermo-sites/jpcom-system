#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the application's own deploy.ps1 or verify.ps1 for one environment.

.DESCRIPTION
    Steps "Update deployable", "Verify deployable", "Revert deployable" and "Verify revert" of an Octopus project
    <slug>-<deployable> whose deployable brings its own runtime (system.json hosting "own", principle 007);
    octopus/projects.tf inlines this file for all four. The system's infra/ creates nothing for such a deployable:
    what it runs on, and how a version gets there, is the application's.

    "Revert deployable" runs only after a failed step: deploy.ps1 again, with the version the environment ran before
    ("Pin version" recorded it), so that what runs is what versions.json names once "Revert pin" has put it back
    (principle 002). The first deployment to an environment has no version before it: there is nothing to go back to,
    and the step says so.

    "Verify revert" runs right after it, also only after a failed step: verify.ps1 with that same version before. It
    asks one thing: does the environment run the version versions.json will name once "Revert pin" has run?
      "Revert deployable" succeeded (it says so in its output variable Reverted) and verify.ps1 exits 0: the revert
        is verified. A highlight says that the deployment failed and that the version before runs again, and the
        nodes verify.ps1 reported go to "Record nodes after revert".
      "Revert deployable" succeeded and verify.ps1 exits with anything else: the step fails. The revert is not
        verified, and the environment may be down.
      "Revert deployable" did not succeed: verify.ps1 is asked all the same, because its answer tells a person
        something and it changes nothing. But its exit code alone is not taken for a verified revert: a verify.ps1
        that does not look at the version would find the release that failed healthy. A highlight says that the
        revert failed and what verify.ps1 answered, no nodes are handed on, and the step fails.
      verify.ps1 does not end within 15 minutes: it is stopped, with every process it started, and the step fails.
        The step stands between the revert and "Revert pin": a script that hangs there would keep the pin from
        being put back until someone cancelled the deployment, and a cancelled deployment runs no further step.
      No version before, or nothing pinned: nothing was put back, the step says so in one highlighted line and runs
        no script.
    In every case the deployment stays failed: these steps run because a step before them failed, and no result of
    theirs changes that.

    The contract. The package reference "app" is <slug>-<deployable>.<version>.zip from the Octopus built-in feed,
    which the application's release workflow made from the content of its deploy/ folder. At its root:
      deploy.ps1   makes the environment run the version (its own infrastructure code, its own way of updating)
      verify.ps1   exits 0 when the environment runs that version and answers
    Each is started with pwsh, signed in to Azure as the tier's deploy identity (the Azure CLI of this step), with
      -Environment <name>   the environment (tdd, uat, prod, ...)
      -Version <number>     the release
      -Context <file>       a JSON file with what the system knows: system, deployable, environment, version,
                            resourceGroup (the tier's, which the identity owns), registryServer, deployPrincipalId
                            (for deny settings of the application's own stack) and systemRepository; for verify.ps1
                            also nodesFile (below)
    Exit code 0 is success; anything else fails the step, and "Revert pin" puts the previous version back.
    What the scripts write to standard output is the step's log. Standard error is logged by Octopus as an error,
    and a deployment with error lines is a broken window: a quiet script writes none.

    One limit of the contract. deploy.ps1 must be able to deploy any earlier released version, or exit non-zero,
    and verify.ps1 must be able to say whether an earlier released version runs. "Revert deployable" and "Verify
    revert" run the scripts of the release that failed with the version before as -Version: the package is the new
    release's, only the number is the old one. A deploy.ps1 that fetches what it deploys by the number can do that;
    one whose package carries what it deploys cannot, and must exit non-zero when it is asked for a version its
    package is not: the step then fails, "Verify revert" finds that the version before does not run, and
    versions.json names the version before ("Revert pin") while the environment runs what the failed deployment
    left. Nothing here tells a script which release its package is from: an application that needs to know writes
    the version into the package when it builds it.

    The nodes of the application (steps "Verify deployable" and "Verify revert"). Only the application knows what it
    runs on, so it may report it: the context of verify.ps1 names nodesFile, the absolute path of a file that does
    not exist yet.
    When verify.ps1 exits 0 and has written that file, it holds one JSON object with the field names of a deployable
    in the dashboard's topology (the dashboard repository's README):
      nodes         required: a list of at least one node, each { "url": an https address with a public host name,
                    each once; optional "name", "region" and "role" (primary or standby) }, in the order the
                    dashboard shows them
      frontDoor     optional (or null): the public address in front of the nodes, an https address with a public
                    host name
      healthPath, alivePath, versionPath   optional: paths that start with /
      healthReport  optional: true or false. The hourly Health report asks every recorded node at alivePath (without
                    one: healthPath), which wakes a node that scaled to zero; false leaves these nodes alone
    A name and a region are one line of letters, digits, spaces and . _ - (at most 100 and 40 characters); an address
    is https://, a public host name (no IP address, no localhost, no name of one label), an optional port and a
    plain path, without user name, query or fragment (the kit's reference.md, "The nodes the application reports",
    has every rule). A report that breaks one is not recorded.
    This step does not read the file and records nothing. It runs code from the application's repository, so it does
    not receive GitHub.Token (octopus/variables.tf, token_steps) and asks the system repository nothing. It hands
    the text of the file to the next step, "Record nodes" (scripts/record-nodes.ps1), in two output variables:
    NodesReported (True or False) and Nodes (the text, as verify.ps1 wrote it; a file larger than 256 KB is no list
    of nodes and fails the step). That step, which runs nothing of the application's, checks the text against the
    rules above and commits the record to environments/<env>/nodes.json on main. A text that breaks a rule is not
    recorded, and the deployment does not fail for it: the version was verified here, and "Record nodes" ends with
    one warning. No file: both steps succeed and say that the application reported no nodes. deploy.ps1 and "Revert
    deployable" get no nodesFile.
    "Verify revert" hands on what verify.ps1 reported for the version before in the same way, and "Record nodes
    after revert" records it: the deploy.ps1 of the release that failed put that version back and may have changed
    what it runs on, and the record says what runs (principle 002).
#>
[CmdletBinding()]
param(
    # How long "Verify revert" lets the application's verify.ps1 run before it stops it. Octopus passes nothing, so
    # this is the limit; the kit's tests pass a shorter one.
    [double] $VerifyRevertMinutes = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off, also for the
# application's script, which inherits them.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$deployable = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$package = [string] $OctopusParameters['Octopus.Action.Package[app].ExtractedPath']
$step = [string] $OctopusParameters['Octopus.Step.Name']
$verifying = $step -in 'Verify deployable', 'Verify revert'
$afterRevert = $step -eq 'Verify revert'
$entry = if ($verifying) { 'verify.ps1' } else { 'deploy.ps1' }
# The release whose deployment this is, and whose package the scripts are from; $version is what they are asked for.
$release = $version
if ($step -in 'Revert deployable', 'Verify revert') {
    # Both steps run only after a failed step. What they say when nothing was put back must not read as a revert
    # that went well: "Verify revert" writes it as a highlight, on the deployment's own page.
    $previous = [string] $OctopusParameters['Octopus.Action[Pin version].Output.PreviousVersion']
    if ([string] $OctopusParameters['Octopus.Action[Pin version].Output.Pinned'] -ne 'True') {
        if ($afterRevert) { Write-Highlight "The deployment of $deployable $version to $environmentName failed, and it had not pinned the version (it failed before the pin, or the version was pinned already): nothing was put back, so there is no revert to verify. $environmentName keeps what the failed deployment left." }
        else { Write-Host "$deployable $version was not pinned in ${environmentName}: nothing was deployed, nothing to revert." }
        return
    }
    if (-not $previous) {
        if ($afterRevert) { Write-Highlight "The deployment of $deployable $version to $environmentName failed, and $environmentName ran no version before it: nothing was put back, so there is no revert to verify. $environmentName keeps what the failed deployment left." }
        else { Write-Host "$environmentName ran no version of $deployable before ${version}: there is none to go back to." }
        return
    }
    if ($afterRevert) { Write-Host "Asking whether $deployable $previous runs in $environmentName again, with the verify.ps1 of $version." }
    else { Write-Host "Going back to $deployable $previous in $environmentName, with the deploy.ps1 of $version." }
    $version = $previous
}

function Invoke-Limited {
    # Starts the application's script as a child process and stops it when it has not ended after the limit: the
    # process and every process it started. What it writes to standard output is written to this step's log line by
    # line as it comes; its standard error is this step's, as for a script that is started without a limit.
    # Returns ExitCode and TimedOut.
    param([Parameter(Mandatory)] [string] $Path, [string[]] $Argument = @(), [Parameter(Mandatory)] [timespan] $Limit)
    $start = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($item in @('-NoProfile', '-NonInteractive', '-File', $Path) + $Argument) { $start.ArgumentList.Add($item) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    $timedOut = $false
    try {
        $line = $process.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($line.Wait(200)) {
                # The end of its output: the process, and whatever it started, has closed it.
                if ($null -eq $line.Result) { break }
                Write-Host $line.Result
                $line = $process.StandardOutput.ReadLineAsync()
            }
            if ($clock.Elapsed -ge $Limit) {
                $timedOut = $true
                break
            }
        }
        if (-not $timedOut -and -not $process.WaitForExit([int] [Math]::Max(1000, ($Limit - $clock.Elapsed).TotalMilliseconds))) { $timedOut = $true }
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { Write-Host "The script could not be stopped: $($_.Exception.Message)" }
            $null = $process.WaitForExit(10000)
        }
    }
    return @{ ExitCode = $(if ($timedOut) { -1 } else { $process.ExitCode }); TimedOut = $timedOut }
}

$script = Join-Path $package $entry
if (-not (Test-Path -LiteralPath $script)) {
    Fail-Step "The package $slug-$deployable.$version has no $entry at its root: the application's deploy/ folder holds deploy.ps1 and verify.ps1 (the kit's reference.md, 'An application that brings its own runtime')."
}

$unique = "$slug-$deployable-$([Guid]::NewGuid().ToString('N'))"
$contextFile = Join-Path ([IO.Path]::GetTempPath()) "context-$unique.json"
# Only verify.ps1 is asked for the nodes: after it, the environment runs the version it reports them for.
$nodesFile = if ($verifying) { Join-Path ([IO.Path]::GetTempPath()) "nodes-$unique.json" } else { '' }
$context = [ordered] @{
    system            = $slug
    deployable        = $deployable
    environment       = $environmentName
    version           = $version
    resourceGroup     = [string] $OctopusParameters['Azure.ResourceGroup']
    registryServer    = [string] $OctopusParameters['Azure.RegistryServer']
    deployPrincipalId = [string] $OctopusParameters['Azure.DeployPrincipalId']
    systemRepository  = [string] $OctopusParameters['System.Repository']
}
if ($verifying) { $context.nodesFile = $nodesFile }
$context | ConvertTo-Json | Set-Content -LiteralPath $contextFile -Encoding utf8NoBOM

Write-Host "$entry of $deployable $version for $environmentName"
$reported = $null
# A list of nodes is a few kilobytes. More than this is not handed to Octopus as a variable.
$nodesLimit = 256KB
$size = 0
$timedOut = $false
$PSNativeCommandUseErrorActionPreference = $false
try {
    if ($afterRevert) {
        # Between the revert and "Revert pin" a script of the application's gets a limit (the header says why).
        $ended = Invoke-Limited -Path $script -Argument '-Environment', $environmentName, '-Version', $version, '-Context', $contextFile -Limit ([timespan]::FromMinutes($VerifyRevertMinutes))
        $exitCode = $ended.ExitCode
        $timedOut = $ended.TimedOut
    }
    else {
        & pwsh -NoProfile -NonInteractive -File $script -Environment $environmentName -Version $version -Context $contextFile
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -eq 0 -and $nodesFile -and (Test-Path -LiteralPath $nodesFile -PathType Leaf)) {
        $size = (Get-Item -LiteralPath $nodesFile).Length
        if ($size -le $nodesLimit) { $reported = [IO.File]::ReadAllText($nodesFile) }
    }
}
finally {
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue
    if ($nodesFile) { Remove-Item -LiteralPath $nodesFile -Force -ErrorAction SilentlyContinue }
}
$differs = "The deployment of $release failed, and versions.json names $version once 'Revert pin' has run: what runs and what is recorded differ until a deployment succeeds."
if ($timedOut) {
    Fail-Step "The revert is not verified: verify.ps1 of $deployable $release did not end within $VerifyRevertMinutes minutes when it was asked whether $version runs in $environmentName. It was stopped, with every process it had started, so that 'Revert pin' can run. $environmentName may be down. $differs"
}
if ($afterRevert -and [string] $OctopusParameters['Octopus.Action[Revert deployable].Output.Reverted'] -ne 'True') {
    # "Revert deployable" did not put the version back. An exit code of 0 here is then no proof that it runs: a
    # verify.ps1 that does not look at the version finds the release that failed healthy. What it answered is said,
    # no nodes are handed on, and the step fails.
    $answered = if ($exitCode -eq 0) { "exited 0, which does not show that $version runs: 'Revert deployable' did not put it there, and a verify.ps1 that does not check the version would find $release healthy" } else { "exited $exitCode" }
    Write-Highlight "The deployment of $deployable $release to $environmentName failed, and the revert failed too: 'Revert deployable' did not put $version back. verify.ps1 of $release, asked whether $version runs in $environmentName, $answered. The revert is not verified."
    Fail-Step "The revert is not verified: 'Revert deployable' did not put $deployable $version back in $environmentName (its step is above), and verify.ps1 $(if ($exitCode -eq 0) { 'exiting 0 does not show that it runs' } else { "exited $exitCode" }). $environmentName may be down, or still run what the failed deployment left. $differs"
}
if ($exitCode -ne 0 -and $afterRevert) {
    Fail-Step "The revert is not verified: verify.ps1 of $deployable $release says that $version does not run in $environmentName after 'Revert deployable' (exit code $exitCode; its output is above). $environmentName may be down. $differs"
}
if ($exitCode -ne 0) {
    Fail-Step "$entry of $deployable $version failed in $environmentName (exit code $exitCode); its output is above."
}
if ($step -eq 'Revert deployable') {
    # For "Verify revert": the version before was put back by a deploy.ps1 that ended with 0.
    Set-OctopusVariable -name 'Reverted' -value 'True'
}
if (-not $verifying) {
    return
}

# The nodes go to the next step, "Record nodes" (after "Verify revert": "Record nodes after revert"), as text. This
# step ran the application's code: it has no GitHub.Token, reads nothing of the text and commits nothing.
$recorder = if ($afterRevert) { 'Record nodes after revert' } else { 'Record nodes' }
if ($size -gt $nodesLimit) {
    Fail-Step "verify.ps1 of $deployable $version passed in $environmentName, but the nodesFile it wrote is larger than 256 KB ($size bytes): that is no list of nodes. The rules are in the kit's reference.md, 'An application that brings its own runtime'."
}
if ($null -eq $reported) {
    Set-OctopusVariable -name 'NodesReported' -value 'False'
    Write-Host "$deployable reported no nodes for $environmentName (its verify.ps1 wrote no nodesFile)."
}
else {
    Set-OctopusVariable -name 'NodesReported' -value 'True'
    # An empty file is a report too: no text is set, "Record nodes" reads the variable as empty and refuses it.
    if ($reported) { Set-OctopusVariable -name 'Nodes' -value $reported }
    Write-Host "$deployable reported its nodes for $environmentName ($($reported.Length) characters): step '$recorder' checks and records them."
}
if ($afterRevert) {
    Write-Highlight "The deployment of $deployable $release to $environmentName failed. The revert is verified: $version runs in $environmentName again (the verify.ps1 of $release says so)."
    return
}
Write-Highlight "$deployable $version runs in $environmentName (its own verify.ps1 says so)."
