#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reads the tables of the environment's database (columns, keys, references, row counts) and commits them to
    environments/<env>/database.json on main.

.DESCRIPTION
    Step "Record database schema" of the Octopus project <slug>-<deployable> whose deployable migrates the
    environment's database; octopus/projects.tf inlines this file. It stands after "Migrate database" and the
    seeder, when the database is awake anyway: the databases are serverless and pause when idle, and a read at any
    other time would wake one (decision 0040). The record is therefore as old as the environment's last deployment.

    What reads it. The dashboard's deployment (scripts/deploy-staticwebapp.ps1) draws the database view from the
    record: a C4 diagram with a box per table, its columns and its row count, and an arrow per foreign key. The page
    reads the same file from the repository's public address for the row counts of the last deployment. The file is
    public like the page: table names, column names, column types and row counts. A system that does not want that
    sets "databaseView": false on "system" in system.json; the step is then not part of the process.

    Why a step of its own. "Migrate database" runs the application's assemblies, and a step that runs code of an
    application does not receive the credential that writes to main of the system repository (octopus/variables.tf,
    token_steps). This step receives it and runs nothing of the application's: it has no package and starts no
    program. What it reads of the application is the names in its database, and those are text: every name is
    written with letters, digits, space and . _ - only (a type also with its length in brackets; any other character as "_") and cut at 128 characters
    (ConvertTo-SchemaText), and the record has its limits (ConvertTo-DatabaseRecord): 200 tables, 60 columns of a
    table, 600 references. What is left out is counted in the record ("truncated", "moreColumns").

    The login is the one "Migrate database" uses: the server's administrator, its password from the environment's
    vault, and a firewall rule for the worker's address for the duration of the step. On runtime aks-argocd, which
    takes this same file (templates/system-aks/shared-files.txt), SQL Server runs in the environment's namespace:
    the step runs on the worker in the cluster and logs in as sa with the password of Secret db-credentials, with
    no firewall rule and nothing of Azure. Which of the two it is, the project says: only that runtime has the
    variable Database.Name. The step only reads: the
    catalog views sys.tables, sys.columns, sys.types, sys.indexes, sys.foreign_keys and sys.partitions. A row count
    is what sys.partitions says, which SQL Server keeps without counting the rows.

    The record: { "generated", "database", "tables": [ { "schema", "name", "rows", "columns": [ { "name", "type",
    "nullable", "key" } ], "moreColumns" } ], "references": [ { "name", "from", "columns", "to", "toColumns" } ],
    "truncated" }. "key" is "", "pk", "fk" or "pk,fk"; "from" and "to" are "<schema>.<name>". A record that says
    the same as the one on main, but for its time, is not committed again.

    A record that cannot be read or written does not fail the deployment: the database is migrated, and taking a
    deployment back because a diagram's data could not be written down would put a worse state in place of a better
    one. The step then ends successfully with ONE warning line that says what was not recorded, why, and what
    follows. What stays a failure is a system that does not work: the credential did not reach the step, the
    system's GitHub App is configured in part, or GitHub refuses the App a token for a reason that does not pass by
    itself (the function of scripts/github-token.ps1 that makes the token says which).
#>
# No param block: octopus/projects.tf joins scripts/github-token.ps1 and this file into one script, this one second.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# An Azure step can drop the result message of Fail-Step (exit code 255, no reason): the reason is a plain line too.
$octopusFailStep = if (Test-Path -LiteralPath function:Fail-Step) { ${function:Fail-Step} } else { $null }
function Fail-Step {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param([string] $Message)
    Write-Host $Message
    if ($octopusFailStep) { & $octopusFailStep $Message }
    exit -1
}

# The Azure CLI writes progress spinners to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn them off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$deployable = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$ruleName = "octopus-schema-$(([string] $OctopusParameters['Octopus.Deployment.Id']) -replace '[^A-Za-z0-9-]', '-')"
$again = "Deploy $deployable $version to $environmentName again to record it."
# Runtime aks-argocd names its database in a variable of the project; the other runtime reads it from the stack.
$inCluster = [bool] [string] $OctopusParameters['Database.Name']

function ConvertTo-SchemaText {
    # A name of the database as the record writes it: letters, digits, space and . _ - only, any other character as
    # "_", at most 128 characters (the longest name SQL Server allows). The names are the application's text.
    param([AllowNull()] [string] $Text, [int] $Longest = 128, [switch] $Type)
    # A type keeps ( ) and , in the one form a type has them: nvarchar(50), nvarchar(max), decimal(18,2).
    $asType = $Type -and "$Text".Trim() -cmatch '^[A-Za-z0-9_ ]+(\((max|[0-9]+)(,[0-9]+)?\))?$'
    $clean = ("$Text" -replace $(if ($asType) { '[^A-Za-z0-9 _(),]' } elseif ($Type) { '[^A-Za-z0-9 _]' } else { '[^\p{L}\p{Nd} ._-]' }), '_').Trim()
    if ($clean.Length -gt $Longest) { $clean = $clean.Substring(0, $Longest) }
    return $clean
}

function Get-SchemaQuery {
    # The three reads of the catalog, by name. Each returns plain columns; nothing of the tables' rows is read.
    $type = @"
CASE WHEN ty.name IN ('varchar', 'char', 'varbinary', 'binary') THEN ty.name + '(' + IIF(c.max_length = -1, 'max', CAST(c.max_length AS varchar(10))) + ')'
     WHEN ty.name IN ('nvarchar', 'nchar') THEN ty.name + '(' + IIF(c.max_length = -1, 'max', CAST(c.max_length / 2 AS varchar(10))) + ')'
     WHEN ty.name IN ('decimal', 'numeric') THEN ty.name + '(' + CAST(c.precision AS varchar(10)) + ',' + CAST(c.scale AS varchar(10)) + ')'
     WHEN ty.name IN ('datetime2', 'datetimeoffset', 'time') THEN ty.name + '(' + CAST(c.scale AS varchar(10)) + ')'
     ELSE ty.name END
"@
    return [ordered] @{
        tables     = @"
SELECT t.object_id AS id, s.name AS [schema], t.name AS [name],
       ISNULL((SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0) AS [rows]
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name
"@
        columns    = @"
SELECT c.object_id AS id, c.column_id AS position, c.name AS [name], $type AS [type], CAST(c.is_nullable AS int) AS nullable,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                         WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END AS pk,
       CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_key_columns f WHERE f.parent_object_id = c.object_id AND f.parent_column_id = c.column_id) THEN 1 ELSE 0 END AS fk
FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
ORDER BY c.object_id, c.column_id
"@
        references = @"
SELECT fk.object_id AS id, fk.name AS [name], fk.parent_object_id AS fromId, fk.referenced_object_id AS toId,
       fkc.constraint_column_id AS position, pc.name AS fromColumn, rc.name AS toColumn
FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
ORDER BY fk.name, fk.object_id, fkc.constraint_column_id
"@
    }
}

function ConvertTo-DatabaseRecord {
    # The record of one database, from the rows of the three reads (each row a dictionary with the queries' column
    # names). It asks nothing: the same rows give the same record, but for the time. The limits are the record's own:
    # 200 tables, 60 columns of a table, 600 references; a reference to or from a table that is left out is left out.
    param(
        [Parameter(Mandatory)] [string] $Database,
        [object[]] $Table = @(),
        [object[]] $Column = @(),
        [object[]] $Reference = @(),
        [datetime] $Generated = [datetime]::UtcNow,
        [int] $MostTables = 200,
        [int] $MostColumns = 60,
        [int] $MostReferences = 600
    )
    $truncated = $false
    $kept = [ordered] @{}
    foreach ($row in @($Table | Where-Object { $_ })) {
        if ($kept.Count -ge $MostTables) { $truncated = $true; break }
        $kept["$($row['id'])"] = [ordered] @{
            schema  = ConvertTo-SchemaText ([string] $row['schema'])
            name    = ConvertTo-SchemaText ([string] $row['name'])
            rows    = [long] $row['rows']
            columns = [Collections.Generic.List[object]]::new()
        }
    }
    $more = @{}
    foreach ($row in @($Column | Where-Object { $_ })) {
        # Not $table: PowerShell's names have no case, and that is the parameter.
        $owner = $kept["$($row['id'])"]
        if (-not $owner) { continue }
        if ($owner.columns.Count -ge $MostColumns) { $more["$($row['id'])"] = 1 + [int] $more["$($row['id'])"]; continue }
        $key = @(if ([int] $row['pk'] -eq 1) { 'pk' }; if ([int] $row['fk'] -eq 1) { 'fk' }) -join ','
        $owner.columns.Add([ordered] @{
                name     = ConvertTo-SchemaText ([string] $row['name'])
                type     = ConvertTo-SchemaText ([string] $row['type']) 64 -Type
                nullable = [int] $row['nullable'] -eq 1
                key      = $key
            })
    }
    foreach ($id in $more.Keys) { $kept[$id].moreColumns = [int] $more[$id] }

    $references = [ordered] @{}
    foreach ($row in @($Reference | Where-Object { $_ })) {
        $from = $kept["$($row['fromId'])"]
        $to = $kept["$($row['toId'])"]
        if (-not $from -or -not $to) { continue }
        $id = "$($row['id'])"
        if (-not $references.Contains($id)) {
            if ($references.Count -ge $MostReferences) { $truncated = $true; continue }
            $references[$id] = [ordered] @{
                name      = ConvertTo-SchemaText ([string] $row['name'])
                from      = "$($from.schema).$($from.name)"
                columns   = [Collections.Generic.List[string]]::new()
                to        = "$($to.schema).$($to.name)"
                toColumns = [Collections.Generic.List[string]]::new()
            }
        }
        $references[$id].columns.Add((ConvertTo-SchemaText ([string] $row['fromColumn'])))
        $references[$id].toColumns.Add((ConvertTo-SchemaText ([string] $row['toColumn'])))
    }
    return [ordered] @{
        generated  = $Generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        database   = ConvertTo-SchemaText $Database
        tables     = @($kept.Values)
        references = @($references.Values)
        truncated  = $truncated
    }
}

function Get-RecordText {
    # The record as the file holds it; -WithoutTime leaves "generated" out, to compare two records.
    param([Parameter(Mandatory)] [Collections.IDictionary] $Record, [switch] $WithoutTime)
    $copy = [ordered] @{}
    foreach ($key in $Record.Keys) { if (-not ($WithoutTime -and $key -eq 'generated')) { $copy[$key] = $Record[$key] } }
    return ($copy | ConvertTo-Json -Depth 8 -Compress)
}

function Read-CatalogRow {
    # The rows of one read, each as a dictionary by column name.
    param([Parameter(Mandatory)] $Connection, [Parameter(Mandatory)] [string] $Query)
    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = 120
    $reader = $command.ExecuteReader()
    try {
        $rows = [Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $row = @{}
            for ($index = 0; $index -lt $reader.FieldCount; $index++) { $row[$reader.GetName($index)] = if ($reader.IsDBNull($index)) { $null } else { $reader.GetValue($index) } }
            $rows.Add($row)
        }
        return , $rows.ToArray()
    }
    finally { $reader.Dispose() }
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
    # information. Any other failure, and the fourth of these, is thrown as it came.
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

function Save-DatabaseRecord {
    # Commits the record to environments/<env>/database.json on main: the loop of scripts/pin-version.ps1 (read,
    # compare, write, again after a 409). Returns nothing when the record is on main, and otherwise why it is not
    # (Why, and Next: what a person does).
    param([Parameter(Mandatory)] [Collections.IDictionary] $Record, [Parameter(Mandatory)] [string] $Token)
    $repository = [string] $OctopusParameters['System.Repository']
    $deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
    $path = "environments/$environmentName/database.json"
    $uri = "https://api.github.com/repos/$repository/contents/$path"
    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $count = @($Record.tables).Count

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $sha = $null
        $before = $null
        try {
            $file = Invoke-GitHub -What "answer the read of $path" -Call @{ Uri = "${uri}?ref=main"; Headers = $headers }
            $sha = $file.sha
            # A file of more than 1 MB comes without its content: it is then replaced, not compared.
            $text = if ($file.content) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', ''))) } else { '' }
            $before = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
        }
        catch {
            # 404: the environment has no record yet.
            $status = Get-HttpStatus -ErrorRecord $_
            if ($status -ne 404) {
                return @{ Why = "$path could not be read from main of $repository ($(if ($status) { "HTTP $status" } else { "no answer: $($_.Exception.Message)" }))"; Next = $again }
            }
        }
        if ($before -is [Collections.IDictionary] -and (Get-RecordText $before -WithoutTime) -ceq (Get-RecordText $Record -WithoutTime)) {
            Write-Highlight "$path already records these $count table(s) with these row counts: nothing to commit."
            return
        }

        $body = @{
            message = "Record the database schema of $environmentName after $deployable $version ($deployment)"
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-RecordText $Record) + "`n"))
            branch  = 'main'
        }
        if ($sha) { $body.sha = $sha }
        try {
            $commit = Invoke-GitHub -What "answer the write of $path" -Call @{ Uri = $uri; Method = 'Put'; Headers = $headers; Body = ($body | ConvertTo-Json); ContentType = 'application/json' }
            Write-Highlight "Recorded $count table(s) of $($Record.database) in ${environmentName}: $($commit.commit.html_url)"
            return
        }
        catch {
            # 409: another commit changed the file since it was read; 422: it was created since it was read as missing.
            $status = Get-HttpStatus -ErrorRecord $_
            if ($status -in 409, 422 -and $attempt -lt 4) {
                Write-Host "database.json changed while recording (attempt $attempt of 4); reading it again."
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
    # deployment as succeeded with warnings.
    param([Parameter(Mandatory)] [string] $Why, [Parameter(Mandatory)] [string] $Next)
    Write-Warning "The database schema of $environmentName was not recorded: $Why. The deployment does not fail for it: the database is migrated. The dashboard keeps showing the last record (environments/$environmentName/database.json on main). $Next"
}

# The read. Whatever keeps it from succeeding is the one warning; the firewall rule is taken away in any case.
$record = $null
$notRead = $null
$opened = $false
$server = ''
try {
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    if ($inCluster) {
        # Runtime aks-argocd: SQL Server is a StatefulSet of the environment's namespace, reachable only from the
        # cluster, where this step runs. The login is the migration's: sa, with the password of Secret db-credentials.
        $namespace = "$slug-$environmentName"
        $database = [string] $OctopusParameters['Database.Name']
        $secret = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
        $builder['Data Source'] = "tcp:db-localhost.$namespace.svc.cluster.local,1433"
        $builder['User ID'] = 'sa'
        $builder['Password'] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'sa-password'))
        # SQL Server's own certificate is self-signed.
        $builder['TrustServerCertificate'] = $true
    }
    else {
        $outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
        $server = [string] $outputs.sqlServerName.value
        $serverFqdn = [string] $outputs.sqlServerFqdn.value
        $database = [string] $outputs.databaseName.value
        $vault = [string] $outputs.keyVaultName.value

        $workerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
        Write-Host "Opening $server to the worker ($workerIp) as rule $ruleName"
        az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
            --start-ip-address $workerIp --end-ip-address $workerIp --output none
        $opened = $true

        $builder['Data Source'] = "tcp:$serverFqdn,1433"
        $builder['User ID'] = [string] $outputs.sqlAdminLogin.value
        $builder['Password'] = ([string] (az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv)).Trim()
    }
    $builder['Initial Catalog'] = $database
    $builder['Encrypt'] = $true
    $builder['Connect Timeout'] = 30
    # The firewall rule takes a moment to hold, and a database that paused since the migration resumes on a login.
    $deadline = (Get-Date).AddMinutes(5)
    for ($attempt = 1; $true; $attempt++) {
        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        $reason = $null
        try {
            $connection.Open()
            $queries = Get-SchemaQuery
            $record = ConvertTo-DatabaseRecord -Database $database `
                -Table (Read-CatalogRow -Connection $connection -Query $queries.tables) `
                -Column (Read-CatalogRow -Connection $connection -Query $queries.columns) `
                -Reference (Read-CatalogRow -Connection $connection -Query $queries.references)
        }
        catch { $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
        finally { $connection.Dispose() }
        if (-not $reason) { break }
        if ((Get-Date) -gt $deadline) { throw "database $database did not answer the read within 5 minutes: $reason" }
        Write-Host "Waiting for database $database to accept the read (attempt $attempt)."
        Start-Sleep -Seconds 15
    }
    Write-Host "Read $(@($record.tables).Count) table(s) and $(@($record.references).Count) reference(s) of $database$(if ($record.truncated) { ' (more than the record holds: it is marked truncated)' })."
}
catch { $notRead = (("$($_.Exception.Message)" -split '\r?\n')[0]).Trim() }
finally {
    if ($opened) {
        $PSNativeCommandUseErrorActionPreference = $false
        az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
        $PSNativeCommandUseErrorActionPreference = $true
    }
}
if ($notRead -or -not $record) {
    Write-NotRecorded -Why "the schema could not be read ($(if ($notRead) { $notRead } else { 'no record' }))" -Next $again
    return
}

# The credential, only now that there is a record to write (Get-SystemGitHubToken of scripts/github-token.ps1, which
# stands before this script in the step's script body). A step the credential did not reach, an App configured in
# part and a token GitHub refuses for a reason that does not pass by itself fail the step: the next deployment would
# fail at "Pin version" for the same reason. GitHub not answering after its four attempts is the one warning.
$token = ''
$refused = $null
try { $token = Get-SystemGitHubToken -Permission @{ contents = 'write' } }
catch { $refused = $_ }
if ($refused) {
    $status = if ($refused.Exception.Data.Contains('GitHubStatus')) { [int] $refused.Exception.Data['GitHubStatus'] } else { -1 }
    if ($status -notin 0, 408, 429, 500, 502, 503, 504) { Fail-Step $refused.Exception.Message }
    Write-NotRecorded -Why "GitHub gave the system's App no token ($(if ($status) { "HTTP $status" } else { 'no answer' }), four attempts)" -Next $again
    return
}

$failed = $null
try { $failed = Save-DatabaseRecord -Record $record -Token $token }
catch { $failed = @{ Why = "the step could not finish ($($_.Exception.Message))"; Next = $again } }
if ($failed) { Write-NotRecorded -Why $failed.Why -Next $failed.Next }
