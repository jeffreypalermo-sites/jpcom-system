#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the application's own deploy.ps1 or verify.ps1 for one environment.

.DESCRIPTION
    Steps "Update deployable" and "Verify deployable" of an Octopus project <slug>-<deployable> whose deployable brings
    its own runtime (system.json hosting "own", principle 007); octopus/projects.tf inlines this file for both. The
    system's infra/ creates nothing for such a deployable: what it runs on, and how a version gets there, is the
    application's.

    The contract. The package reference "app" is <slug>-<deployable>.<version>.zip from the Octopus built-in feed,
    which the application's release workflow made from the content of its deploy/ folder. At its root:
      deploy.ps1   makes the environment run the version (its own infrastructure code, its own way of updating)
      verify.ps1   exits 0 when the environment runs that version and answers
    Each is started with pwsh, signed in to Azure as the tier's deploy identity (the Azure CLI of this step), with
      -Environment <name>   the environment (tdd, uat, prod, ...)
      -Version <number>     the release
      -Context <file>       a JSON file with what the system knows: system, deployable, environment, version,
                            resourceGroup (the tier's, which the identity owns), registryServer, deployPrincipalId
                            (for deny settings of the application's own stack) and systemRepository
    Exit code 0 is success; anything else fails the step, and "Revert pin" puts the previous version back.
    What the scripts write to standard output is the step's log. Standard error is logged by Octopus as an error,
    and a deployment with error lines is a broken window: a quiet script writes none.
#>
[CmdletBinding()]
param()

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
$verifying = [string] $OctopusParameters['Octopus.Step.Name'] -eq 'Verify deployable'
$entry = if ($verifying) { 'verify.ps1' } else { 'deploy.ps1' }

$script = Join-Path $package $entry
if (-not (Test-Path -LiteralPath $script)) {
    Fail-Step "The package $slug-$deployable.$version has no $entry at its root: the application's deploy/ folder holds deploy.ps1 and verify.ps1 (the kit's reference.md, 'An application that brings its own runtime')."
}

$contextFile = Join-Path ([IO.Path]::GetTempPath()) "context-$slug-$deployable-$([Guid]::NewGuid().ToString('N')).json"
[ordered] @{
    system            = $slug
    deployable        = $deployable
    environment       = $environmentName
    version           = $version
    resourceGroup     = [string] $OctopusParameters['Azure.ResourceGroup']
    registryServer    = [string] $OctopusParameters['Azure.RegistryServer']
    deployPrincipalId = [string] $OctopusParameters['Azure.DeployPrincipalId']
    systemRepository  = [string] $OctopusParameters['System.Repository']
} | ConvertTo-Json | Set-Content -LiteralPath $contextFile -Encoding utf8NoBOM

Write-Host "$entry of $deployable $version for $environmentName"
$PSNativeCommandUseErrorActionPreference = $false
try {
    & pwsh -NoProfile -NonInteractive -File $script -Environment $environmentName -Version $version -Context $contextFile
    $exitCode = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue
}
if ($exitCode -ne 0) {
    Fail-Step "$entry of $deployable $version failed in $environmentName (exit code $exitCode); its output is above."
}
if ($verifying) {
    Write-Highlight "$deployable $version runs in $environmentName (its own verify.ps1 says so)."
}
