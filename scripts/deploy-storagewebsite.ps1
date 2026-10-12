#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Library of step "Update deployable" for a static site with hosting "storagewebsite": the release's files onto the
    static website of the storage account the stack created (infra/modules/storagewebsite.bicep; decision 0035).

.DESCRIPTION
    octopus/projects.tf joins this file between scripts/github-token.ps1 and scripts/deploy-staticwebapp.ps1 into the
    step's one script body. That script writes topology.json and runtime/ as for a Static Web App, then calls
    Publish-StorageWebsite in place of the Static Web Apps CLI. No param block: the file is joined into a script.

      Publish-StorageWebsite   Switches the static website on (index.html; 404.html for a path the site does not
                               have), uploads the folder to $web with az storage blob upload-batch as the step's
                               identity (Microsoft Entra ID: the account takes no shared key), deletes what the
                               release no longer has, checks that $web holds exactly the release, and that the site
                               serves the topology this step wrote, index.html as text/html and its WebAssembly as
                               application/wasm. One batch per Content-Type: the files of _framework/ first (their
                               names carry a fingerprint), then the others with Cache-Control no-cache (their names
                               stay from release to release), index.html last, so a page that loads meanwhile finds
                               every file it names.
      Get-StorageContentType   The Content-Type of a file by its extension; application/octet-stream for any other.
      Invoke-StorageCommand    One az command: its lines on standard output, its exit code, and its lines on
                               standard error when it failed. upload-batch reports a file it did not upload as an
                               ERROR line and still ends with 0, so such a line is a failure too.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-StorageContentType {
    # Set explicitly: what az guesses depends on the worker's az and Python versions.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Extension)
    $types = @{
        '.html'        = 'text/html; charset=utf-8'
        '.htm'         = 'text/html; charset=utf-8'
        '.css'         = 'text/css; charset=utf-8'
        '.js'          = 'text/javascript; charset=utf-8'
        '.mjs'         = 'text/javascript; charset=utf-8'
        '.json'        = 'application/json; charset=utf-8'
        '.map'         = 'application/json; charset=utf-8'
        '.webmanifest' = 'application/manifest+json'
        '.wasm'        = 'application/wasm'
        '.dat'         = 'application/octet-stream'
        '.blat'        = 'application/octet-stream'
        '.dll'         = 'application/octet-stream'
        '.pdb'         = 'application/octet-stream'
        '.svg'         = 'image/svg+xml'
        '.png'         = 'image/png'
        '.jpg'         = 'image/jpeg'
        '.jpeg'        = 'image/jpeg'
        '.gif'         = 'image/gif'
        '.webp'        = 'image/webp'
        '.ico'         = 'image/x-icon'
        '.woff'        = 'font/woff'
        '.woff2'       = 'font/woff2'
        '.ttf'         = 'font/ttf'
        '.otf'         = 'font/otf'
        '.txt'         = 'text/plain; charset=utf-8'
        '.puml'        = 'text/plain; charset=utf-8'
        '.xml'         = 'application/xml'
        '.gz'          = 'application/gzip'
    }
    $type = $types[$Extension.ToLowerInvariant()]
    if ($type) { return $type }
    return 'application/octet-stream'
}

function Invoke-StorageCommand {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $written = @(az @Arguments 2>&1)
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $output = @($written | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $lines = @($written | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { ("$_" -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '').Trim() } | Where-Object { $_ })
    # Anything else on standard error of a command that succeeded (a warning of Python's) is information.
    $failed = $code -ne 0 -or @($lines | Where-Object { $_ -cmatch '^ERROR' }).Count -gt 0
    $errors = [string[]] @()
    if ($failed) { $errors = [string[]] $lines }
    else { foreach ($line in $lines) { Write-Host "  az: $line" } }
    return @{ Output = [string[]] $output; Errors = $errors; Code = [int] $code }
}

function Publish-StorageWebsite {
    # -Folder (the release's files and the topology this step wrote) onto the static website of storage account
    # -Account; -Url is the site's address, and -Generated the time stamp of the topology it must then serve.
    param(
        [Parameter(Mandatory)] [string] $Account,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Generated
    )
    $login = @('--account-name', $Account, '--auth-mode', 'login', '--only-show-errors')
    $list = @('storage', 'blob', 'list', '--container-name', '$web', '--num-results', '*', '--query', '[].name', '--output', 'tsv') + $login
    $switched = Invoke-StorageCommand -Arguments (@('storage', 'blob', 'service-properties', 'update', '--static-website', 'true', '--index-document', 'index.html', '--404-document', '404.html', '--output', 'none') + $login)
    if ($switched.Code -ne 0 -or $switched.Errors.Count -gt 0) {
        Fail-Step "The static website of $Account could not be switched on (exit code $($switched.Code)): $($switched.Errors -join ' ')"
    }
    Write-Host "Static website of ${Account}: on, index document index.html, error document 404.html"

    # A role the stack assigned at its last apply can take minutes to reach the data plane, and $web a moment to exist.
    $deadline = (Get-Date).AddMinutes(10)
    while ($true) {
        $listing = Invoke-StorageCommand -Arguments $list
        if ($listing.Code -eq 0 -and $listing.Errors.Count -eq 0) { break }
        $reason = if ($listing.Errors.Count -gt 0) { $listing.Errors -join ' ' } else { "exit code $($listing.Code)" }
        if ($reason -notmatch 'AuthorizationPermissionMismatch|required permissions needed to perform this operation|ContainerNotFound|specified container does not exist' -or (Get-Date) -gt $deadline) {
            Fail-Step "The files of $Account could not be listed: $reason"
        }
        Write-Host "The files of $Account cannot be listed yet (a role assigned moments ago, or a new `$web container); retrying in 30 seconds."
        Start-Sleep -Seconds 30
    }
    $before = @($listing.Output | Where-Object { $_ })

    $names = [Collections.Generic.List[string]]::new()
    $batches = [ordered] @{}
    $stage = Join-Path ([IO.Path]::GetTempPath()) "website-$([Guid]::NewGuid().ToString('N'))"
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force)) {
            $blob = [IO.Path]::GetRelativePath($Folder, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
            $names.Add($blob)
            $order = if ($blob -ceq 'index.html') { 3 } elseif ($blob.StartsWith('_framework/', [StringComparison]::Ordinal)) { 1 } else { 2 }
            $type = Get-StorageContentType -Extension $file.Extension
            $key = "$order $type"
            if (-not $batches.Contains($key)) { $batches[$key] = @{ Order = $order; Type = $type; Folder = (Join-Path $stage "$($batches.Count)"); Files = 0 } }
            $batch = $batches[$key]
            $target = Join-Path $batch.Folder $blob
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
            $batch.Files += 1
        }
        Write-Host "Uploading $($names.Count) file(s) to `$web of $Account in $($batches.Count) batch(es):"
        foreach ($batch in @($batches.Values | Sort-Object { $_.Order }, { $_.Type })) {
            $cache = @(if ($batch.Order -ne 1) { '--content-cache-control', 'no-cache' })
            $uploaded = Invoke-StorageCommand -Arguments (@('storage', 'blob', 'upload-batch', '--destination', '$web', '--source', $batch.Folder, '--content-type', $batch.Type, '--overwrite', 'true', '--no-progress', '--output', 'none') + $cache + $login)
            if ($uploaded.Code -ne 0 -or $uploaded.Errors.Count -gt 0) {
                Fail-Step "Uploading $($batch.Files) file(s) as $($batch.Type) to $Account failed (exit code $($uploaded.Code)): $($uploaded.Errors -join ' ')"
            }
            Write-Host "  $($batch.Files) as $($batch.Type)$(if ($cache.Count -gt 0) { ', Cache-Control no-cache' })"
        }
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    $stale = @($before | Where-Object { $names -cnotcontains $_ })
    foreach ($blob in $stale) {
        $removed = Invoke-StorageCommand -Arguments (@('storage', 'blob', 'delete', '--container-name', '$web', '--name', $blob, '--output', 'none') + $login)
        if ($removed.Code -ne 0 -or $removed.Errors.Count -gt 0) {
            Fail-Step "$blob of an earlier release could not be deleted from $Account (exit code $($removed.Code)): $($removed.Errors -join ' ')"
        }
    }
    if ($stale.Count -gt 0) { Write-Host "Deleted $($stale.Count) file(s) of earlier releases that this one does not have." }

    $after = Invoke-StorageCommand -Arguments $list
    if ($after.Code -ne 0 -or $after.Errors.Count -gt 0) {
        Fail-Step "The files of $Account could not be listed after the upload (exit code $($after.Code)): $($after.Errors -join ' ')"
    }
    $held = @($after.Output | Where-Object { $_ })
    $missing = @($names | Where-Object { $held -cnotcontains $_ })
    $extra = @($held | Where-Object { $names -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        Fail-Step "`$web of $Account does not hold exactly this release: $($missing.Count) file(s) missing ($(@($missing | Select-Object -First 5) -join ', ')), $($extra.Count) not of it ($(@($extra | Select-Object -First 5) -join ', '))."
    }

    # The proof: the topology of this deployment, by its time stamp, then the types a browser needs.
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $served = ''
        try {
            $answer = Invoke-WebRequest -Uri "$Url/topology.json" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 60 -SkipHttpErrorCheck
            $text = if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }
            $served = if ([int] $answer.StatusCode -eq 200) { [regex]::Match($text, '"generated"\s*:\s*"([^"]*)"').Groups[1].Value } else { "HTTP $([int] $answer.StatusCode)" }
        }
        catch {
            $served = $_.Exception.Message
        }
        if ($served -eq $Generated) { break }
        if ((Get-Date) -gt $deadline) {
            Fail-Step "$Url/topology.json does not serve the topology of this deployment ($Generated) after 5 minutes: it answered '$served'."
        }
        Write-Host "$Url/topology.json answered '$served', not $Generated yet; retrying"
        Start-Sleep -Seconds 10
    }
    $checks = [ordered] @{ '/' = 'text/html' }
    $wasm = @($names | Where-Object { $_.EndsWith('.wasm', [StringComparison]::OrdinalIgnoreCase) } | Sort-Object) | Select-Object -First 1
    if ($wasm) { $checks["/$wasm"] = 'application/wasm' }
    foreach ($path in @($checks.Keys)) {
        $answer = Invoke-WebRequest -Uri "$Url$path" -Method Head -TimeoutSec 60 -SkipHttpErrorCheck
        $type = [string] @($answer.Headers['Content-Type'])[0]
        if ([int] $answer.StatusCode -ne 200 -or -not $type.StartsWith($checks[$path], [StringComparison]::OrdinalIgnoreCase)) {
            Fail-Step "$Url$path answers HTTP $([int] $answer.StatusCode) with Content-Type '$type'; $($checks[$path]) was uploaded."
        }
    }
    Write-Host "$Url serves the topology of $Generated, and $(@($checks.Keys) -join ' and ') with the Content-Type a browser needs."
}
