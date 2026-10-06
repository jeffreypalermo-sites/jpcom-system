#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Removes the SQL firewall rule that "Open test database" added for the acceptance tests.

.DESCRIPTION
    Step "Close test database" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. It
    runs whenever "Open test database" opened the database, also after failed tests.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$server = [string] $OctopusParameters['Octopus.Action[Open test database].Output.SqlServer']
$ruleName = [string] $OctopusParameters['Octopus.Action[Open test database].Output.FirewallRule']
az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
Write-Host "Removed firewall rule $ruleName from $server"
