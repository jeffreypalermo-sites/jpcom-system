#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Library of the Octopus steps that call the GitHub API: a token of the system's own GitHub App, made at the moment
    of use, or the stored token of a system that has no App.

.DESCRIPTION
    octopus/projects.tf inlines one script per step, so a step cannot dot-source a file. For each step that asks
    GitHub for a token it joins this file and the step's own script into one script body when Terraform plans
    (join("\n", [<this file>, <the step's script>])): the functions below stand before the step's code, in the
    script Octopus stores for the step, and the step asks for its token in one line:

        $token = Get-SystemGitHubToken -Permission @{ contents = 'write' }

    So there is one copy of this code in the repository, a release keeps the copy of its own day in its process,
    and the code a step runs is fixed when the configuration is applied: nothing a step sets at run time can change
    what a later step runs. A step that Terraform does not join has no such function, and its script stops at that
    line. For the join to be one valid script this file has no param block, and neither has the script of a step it
    is joined with (tests/test-token-scope.ps1 of the kit parses every joined script).

      Get-SystemGitHubToken        The token for this step. With the variables of the system's App (GitHub.AppId,
                                   GitHub.AppInstallationId, GitHub.AppPrivateKey: system.json github.app and the
                                   repository secret SYSTEM_APP_PRIVATE_KEY): an installation token for the system
                                   repository only, with the permissions asked for only, valid one hour. Without any
                                   of them: GitHub.Token, the stored token, as before the App. One line says which
                                   identity is used. The credential is scoped to the steps that ask for it
                                   (octopus/variables.tf, token_steps): a step it did not reach fails here (Fail-Step)
                                   and says so, and so does a step of a system whose App is configured in part.
                                   Nothing falls back from the App to a stored token.
      New-GitHubInstallationToken  The exchange itself: a JWT signed with the App's key for an installation token.
                                   A failure that is known to pass (no answer, 408, 429, 5xx) is asked again, four
                                   attempts in all; what it throws then carries GitHub's status
                                   (Exception.Data['GitHubStatus']; 0: no answer), so that a step can tell GitHub
                                   not answering from an App that is not what the system says.
      New-GitHubAppJwt             The JWT (RS256) that proves the App to GitHub for ten minutes.
      ConvertTo-Base64Url          Base64 as a JWT writes it.

    The App's ids are no secret and reach every step of a project; they make no token. Without the key a step can
    ask GitHub for nothing as the App.

    Neither the key, the JWT nor a token is written anywhere: not to the log, not to a file, not into an error.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
    # GitHub accepts a JWT for at most ten minutes. It is issued one minute in the past, for a worker whose clock is
    # ahead, and ends nine minutes from now.
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $PrivateKey,
        [datetime] $Now = [datetime]::UtcNow
    )
    $issued = [DateTimeOffset]::new($Now.ToUniversalTime(), [TimeSpan]::Zero).ToUnixTimeSeconds() - 60
    $header = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $claims = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes(([ordered] @{ iat = $issued; exp = $issued + 600; iss = $AppId } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        # A secret store or a variable may hand the key over with its line breaks written as backslash n.
        $pem = if ($PrivateKey.Contains("`n")) { $PrivateKey } else { $PrivateKey.Replace('\n', "`n") }
        try { $rsa.ImportFromPem($pem) }
        catch { throw 'The private key of the GitHub App is not an RSA key in PEM form. Its text is never shown: store the key again (set-system-github-app.ps1 of the kit).' }
        $signature = $rsa.SignData([Text.Encoding]::ASCII.GetBytes("$header.$claims"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    }
    finally {
        $rsa.Dispose()
    }
    return "$header.$claims.$(ConvertTo-Base64Url -Bytes $signature)"
}

function New-GitHubInstallationToken {
    # Returns @{ Token; ExpiresAt; Asked }. -Repository <owner>/<name> restricts the token to that one repository, and
    # -Permission to those permissions (each at most what the App itself was given).
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $InstallationId,
        [Parameter(Mandatory)] [string] $PrivateKey,
        [string] $Repository = '',
        [hashtable] $Permission = @{}
    )
    $jwt = New-GitHubAppJwt -AppId $AppId -PrivateKey $PrivateKey
    $headers = @{
        Authorization          = "Bearer $jwt"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $body = @{}
    if ($Repository) { $body.repositories = @(($Repository -split '/')[-1]) }
    if ($Permission.Count -gt 0) { $body.permissions = $Permission }
    $asked = @($Permission.Keys | Sort-Object | ForEach-Object { "${_}:$($Permission[$_])" }) -join ', '
    # A failure that is known to pass is asked again (principle 004): no answer, or 408, 429, 500, 502, 503 or 504.
    # Four attempts, 5, 10 and 15 seconds apart; each retry is one line of information. The JWT lasts ten minutes.
    $answer = $null
    $given = $false
    for ($attempt = 1; -not $given; $attempt++) {
        try {
            $answer = Invoke-RestMethod -Uri "https://api.github.com/app/installations/$InstallationId/access_tokens" -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json'
            $given = $true
        }
        catch {
            # Only the status and GitHub's own sentence: the request, with the JWT in its header, is never repeated here.
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { 0 }
            $passing = $status -in 0, 408, 429, 500, 502, 503, 504
            if ($passing -and $attempt -lt 4) {
                Write-Host "GitHub did not give the App a token ($(if ($status) { "HTTP $status" } else { 'no answer' }), attempt $attempt of 4); asking again in $(5 * $attempt) seconds."
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }
            $said = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try { $said = [string] ($_.ErrorDetails.Message | ConvertFrom-Json -AsHashtable)['message'] } catch { $said = '' }
            }
            $meaning = switch ($status) {
                401 { "the key is not a key of App $AppId, or this machine's clock is more than a minute off" }
                403 { "the installation is suspended, or the App may not do this" }
                404 { "installation $InstallationId is not an installation of App ${AppId}: the App was uninstalled, or installed again under another id" }
                422 { "the installation does not cover $Repository, or the App was not given a permission asked for ($asked)" }
                0 { 'GitHub did not answer in four attempts' }
                default { if ($passing) { 'GitHub did not give one in four attempts' } else { 'GitHub refused' } }
            }
            $failure = [InvalidOperationException]::new("No token for the GitHub App $AppId (installation $InstallationId): HTTP $status, $meaning$(if ($said) { ". GitHub says: $said" }).")
            $failure.Data['GitHubStatus'] = $status
            throw $failure
        }
    }
    # ConvertFrom-Json turns the time into a date; written back in one form, whatever the worker's culture.
    $expires = $answer.expires_at
    $until = if ($expires -is [datetime]) { $expires.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' UTC' } else { [string] $expires }
    return @{ Token = [string] $answer.token; ExpiresAt = $until; Asked = $asked }
}

function Get-SystemGitHubToken {
    # The token of this step for the system repository (variable System.Repository). A credential that did not reach
    # the step, and an App that is configured in part, fail the step (Fail-Step): that is a system that does not
    # work. A token GitHub does not give is thrown by New-GitHubInstallationToken, with GitHub's status.
    param([hashtable] $Permission = @{ contents = 'read' })
    $repository = ([string] $OctopusParameters['System.Repository']).Trim()
    $step = [string] $OctopusParameters['Octopus.Step.Name']
    $app = [ordered] @{
        'GitHub.AppId'             = ([string] $OctopusParameters['GitHub.AppId']).Trim()
        'GitHub.AppInstallationId' = ([string] $OctopusParameters['GitHub.AppInstallationId']).Trim()
        'GitHub.AppPrivateKey'     = [string] $OctopusParameters['GitHub.AppPrivateKey']
    }
    $missing = @($app.Keys | Where-Object { -not $app[$_] })
    if ($missing.Count -eq $app.Count) {
        # No App: the system writes with the token its repository stores (secret OCTOPUS_GITHUB_TOKEN), as before.
        # The token is scoped to the steps that ask for it: a step that is not among them reads it empty, and says
        # so here instead of being refused by GitHub.
        $stored = [string] $OctopusParameters['GitHub.Token']
        if (-not $stored) {
            Fail-Step "GitHub.Token did not reach step '$step': octopus/variables.tf hands it only to the steps of local.token_steps. A release made before a step was replaced has that step under its old id and gets no token there: make a new release."
        }
        Write-Host "GitHub identity: the stored token GitHub.Token (this system has no GitHub App of its own)."
        return $stored
    }
    if ($missing.Count -eq 1 -and $missing[0] -eq 'GitHub.AppPrivateKey') {
        # The system has an App, and its key is scoped like the stored token: this step is not on the list, or the
        # release is older than the step.
        Fail-Step "GitHub.AppPrivateKey did not reach step '$step': octopus/github.tf hands the key of the system's GitHub App only to the steps of local.token_steps (octopus/variables.tf). A release made before a step was replaced has that step under its old id and gets no key there: make a new release. Nothing falls back to a stored token."
    }
    if ($missing.Count -gt 0) {
        Fail-Step "The GitHub App of this system is configured in part: $($missing -join ', ') $(if ($missing.Count -eq 1) { 'is' } else { 'are' }) empty in step '$step' (system.json github.app gives the ids, the repository secret SYSTEM_APP_PRIVATE_KEY the key). Nothing falls back to a stored token: complete it, or take github.app out of system.json."
    }
    # A token of the App is restricted to one repository by naming it: without a name GitHub would give one for
    # every repository the App is installed on. So without the name no token is asked for.
    if ($repository -cnotmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
        Fail-Step "System.Repository is '$repository' in step '$step', not <owner>/<name>: a token of the system's GitHub App is made for the system repository and no other, so none is made. octopus/variables.tf sets the variable from system.json (system.githubOrg, system.repository)."
    }
    $made = New-GitHubInstallationToken -AppId $app['GitHub.AppId'] -InstallationId $app['GitHub.AppInstallationId'] -PrivateKey $app['GitHub.AppPrivateKey'] -Repository $repository -Permission $Permission
    $name = ([string] $OctopusParameters['GitHub.AppSlug']).Trim()
    Write-Host "GitHub identity: the system's App $(if ($name) { "$name " })(id $($app['GitHub.AppId']), installation $($app['GitHub.AppInstallationId'])): a token for $repository only, with $($made.Asked), valid until $($made.ExpiresAt)."
    return $made.Token
}
