#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Rotates the SQL administrator password of the environment without downtime beyond an app restart.

.DESCRIPTION
    Runbook "Rotate SQL password" of the Octopus project <slug>-system (scheduled monthly in every environment;
    octopus/runbooks.tf inlines this file). Capability CAP-056. It generates a password, sets it on the SQL server
    through the ARM API from a private file (never in an argument), writes it and the connection string to the
    environment's Key Vault, restarts each app's latest revision so it reads the new secret, and checks that every app
    answers its health path. The next "Apply environment" reads the password from the vault, so Git and the
    environment stay consistent.
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
$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$vault = [string] $outputs.keyVaultName.value

function New-SqlPassword {
    # 32 characters with every class SQL Server's complexity rule asks for, from a cryptographic generator.
    $classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.~')
    $all = -join $classes
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }
    while ($characters.Count -lt 32) {
        $characters.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    return -join ($characters | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

$folder = Join-Path ([IO.Path]::GetTempPath()) "rotate-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $folder | Out-Null
chmod 700 $folder
try {
    $password = New-SqlPassword
    $connection = ([string] (az keyvault secret show --vault-name $vault --name sql-connection-string --query value --output tsv)).Trim()
    if ($connection -notmatch 'Password=[^;]*;') {
        Fail-Step "The connection string in $vault has no Password=...; part."
    }
    $serverId = ([string] (az sql server show --resource-group $resourceGroup --name $server --query id --output tsv)).Trim()
    $body = Join-Path $folder 'server.json'
    @{ properties = @{ administratorLoginPassword = $password } } | ConvertTo-Json -Compress | Set-Content -LiteralPath $body -NoNewline
    az rest --method patch --url "https://management.azure.com${serverId}?api-version=2023-08-01" --body "@$body" `
        --headers 'Content-Type=application/json' --output none
    Write-Host "Set a new administrator password on $server"

    $secret = Join-Path $folder 'secret'
    Set-Content -LiteralPath $secret -Value $password -NoNewline
    az keyvault secret set --vault-name $vault --name sql-admin-password --file $secret --content-type text/plain --output none
    Set-Content -LiteralPath $secret -Value ($connection -replace 'Password=[^;]*;', "Password=$password;") -NoNewline
    # The same content type as infra/modules/keyvault.bicep, or the nightly drift check reports the secrets.
    az keyvault secret set --vault-name $vault --name sql-connection-string --file $secret --content-type text/plain --output none
    $password = $null
    $connection = $null
    Write-Host "Updated sql-admin-password and sql-connection-string in $vault"
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = 0
# App Service deployables use logins of their own, not the administrator password, and a static site has no database
# access at all: only container apps restart.
foreach ($deployable in @($outputs.deployables.value | Where-Object { $_['containerApp'] })) {
    $app = [string] $deployable.containerApp
    $appId = ([string] (az containerapp show --name $app --resource-group $resourceGroup --query id --output tsv)).Trim()
    $revision = ([string] (az containerapp show --name $app --resource-group $resourceGroup --query properties.latestRevisionName --output tsv)).Trim()
    az rest --method post --url "https://management.azure.com$appId/revisions/$revision/restart?api-version=2024-03-01" --output none
    $uri = "$(([string] $deployable.url).TrimEnd('/'))$($deployable.healthPath)"
    $deadline = (Get-Date).AddMinutes(10)
    $status = 0
    while ((Get-Date) -lt $deadline) {
        try { $status = [int] (Invoke-WebRequest -Uri $uri -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
        if ($status -eq 200) { break }
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        Write-Host "$app restarted ($revision) and healthy"
    }
    else {
        Write-Warning "$app did not answer 200 on $uri within 10 minutes after the rotation (last $status)."
        $failed++
    }
}
if ($failed -gt 0) {
    Fail-Step "$failed app(s) of $environmentName are unhealthy after the password rotation."
}
Write-Highlight "SQL password of $environmentName rotated; every app restarted and healthy."
