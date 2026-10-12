#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Deploys the release's static site to the deployable's Static Web App, with the topology of the whole system.

.DESCRIPTION
    Step "Update deployable" of an Octopus project <slug>-<deployable> whose deployable is a static site (system.json
    hosting "staticwebapp": the health dashboard); octopus/projects.tf inlines this file. The package reference "site"
    is the zip the dashboard's release workflow pushed to the Octopus built-in feed (<slug>-<deployable>.<version>.zip,
    index.html at its root), extracted. The site is the one the stack created (stack output deployables[].staticSite).

    1. topology.json, written next to index.html (the contract is in the dashboard repository's README): every
       environment of system.json on main and, in each, the deployables whose nodes are known:
       - hosting "appservice": its nodes by naming convention, app-<slug>-<env>-<deployable> in system.location
         (primary) and, when the environment has a standbyLocation, app-<slug>-<env>-<deployable>-<region>
         (standby). An environment with capability "frontdoor" also gets the address of its Front Door endpoint,
         read from the system's profile (azure.frontDoor).
       - hosting "own": what the application reported when it was last verified there, the deployable's entry in
         environments/<env>/nodes.json on main (scripts/record-nodes.ps1 records it): its nodes, its paths and
         its own public address. What system.json says of every deployable comes with it (projectUrl, telemetryPath,
         trafficPaths, buildPath, healthDetailPath, below); a health path it did not report is the deployable's
         healthPath of system.json. It has no links: the system does not know the application's resources. Without
         a record in an environment the deployable is left out of that environment, and the log says so. A record
         that breaks the rules stops the step: it would break the dashboard's page.
       Container-app deployables are left out: their address is not a convention (the platform generates it, and a
       placement changes it), so the dashboard does not show them.
       The topology also says where the dashboard finds what the deployments pinned. Every address is a convention
       over system.json and none is a secret:
         system.repository      https://github.com/<system.githubOrg>/<system.repository>, the system repository
         versionsUrl            per environment: environments/<env>/versions.json on main, as
                                raw.githubusercontent.com serves it to a browser without a token (the repository is
                                public)
         versionsHistoryUrl     per environment: the commits of that file on github.com
         projectUrl             per deployable: <octopus.url>/app#/<octopus.spaceId>/projects/<slug>-<deployable>,
                                its Octopus project
       The dashboard compares the pinned version with the version each node reports and links to the project and to
       the history. An address whose parts system.json does not give is null, and the dashboard leaves that part out.
       What the dashboard shows beyond health comes the same way, each part optional:
         telemetryPath, buildPath, trafficPaths, healthDetailPath
                                per deployable, carried from system.json (deployables[]): where a node reports its
                                calls and its process, where it reports the build it runs, what the traffic button
                                calls, and where it answers its detailed health check (one entry per dependency
                                it checks: name, status, description, duration)
         system.deliveryUrl     https://raw.githubusercontent.com/<githubOrg>/<repository>/status/delivery.json: the
                                delivery facts a workflow of the system repository publishes to its branch "status"
         system.costUrl         https://raw.githubusercontent.com/<githubOrg>/<repository>/status/cost.json: what each
                                environment cost in Azure, which the same workflow publishes next to it
         system.deploymentsUrl  https://raw.githubusercontent.com/<githubOrg>/<repository>/deployments/deployments.json:
                                the deployments in flight, which workflow deployments publishes to its branch
                                "deployments" (scripts/write-deployments.ps1)
         system.dashboard       { name, buildPath }: this deployable itself, when system.json gives it a buildPath
                                (deployables[<this deployable>].buildPath, "/build-facts.json": the file the
                                dashboard's Build writes next to index.html) and the release has that file. The page
                                reads it from its own address and shows the Code card of the dashboard. Without the
                                key in system.json the topology has no such entry and is as before; a release from
                                before the Build wrote the file gets none either, which is logged as information
         links                  where a number or a name of the page leads, all in the Azure portal, which asks the
                                viewer to sign in (the page holds no credential). Resource ids are conventions over
                                system.json (azure.subscriptionId, azure.resourceGroups, the names the stack gives):
                                  nodes[].links        portal (the web app) and, in an environment with capability
                                                       "telemetry", liveMetrics, performance, failures (blades of
                                                       appi-<slug>-<env>) and dependencies (a Logs query of the
                                                       dependency calls of role <slug>-<deployable>)
                                  deployables[].links  frontDoor (the profile azure.frontDoor, where the environment
                                                       has an endpoint) and logs (a Logs query of the role's requests)
                                  environments[].pages a page of the system itself, per deployable that names one
                                                       (dashboardLink in system.json): its words and the address the
                                                       deployable has in that environment, read from the stack
                                  environments[].links resourceGroup, applicationInsights and applicationMap (with
                                                       "telemetry") and database (sqldb-<slug>-<env>)
                                The database's server has a generated suffix, so its name is read from Azure
                                (az sql server list in the tier's resource group). A read that fails or is denied
                                (the deploy identity of one tier may not read the other's group) is logged as
                                information and leaves that link out.
    2. runtime/, next to topology.json: per environment of system.json a C4 deployment diagram (PlantUML source
       <env>.puml, the SVG <env>.svg and its manifest <env>.json), and index.json, the list of them (the contract is in
       the dashboard repository's README, "The runtime view"). The diagram is drawn from the topology and system.json:
       Azure subscription > resource group (the tier's, and azure.frontDoor.resourceGroup) > region (primary
       system.location, standby, the database's system.sqlLocation, the static sites' system.staticLocation) > App
       Service plan (asp-<slug>-<first environment of the tier>, asp-<slug>-<first environment of the tier with that
       standby>-<region>; size system.planSku.<tier>, F1 without it and while azure.frontDoor.dormant) > web app; the
       Front Door endpoint in the profile; the database sqldb-<slug>-<env>, in an environment that has one (an app in
       it uses it: the rule of infra/main.bicep); the static sites; the browser. An application that brings its own
       runtime (hosting "own") is drawn outside the subscription, in a boundary of its own, because the system does
       not know where it runs: its public address when it reported one, and its nodes by the regions they name, each
       with the tile of a web app; the browser calls the public address, or each node without one. Outside the
       subscription, one box per dependency a deployable declares (system.json deployables[].dependencies, a list of
       { "name": "LLM gateway", "healthCheck": "LlmGateway", "kind": "external" }: the name shown, the entry of the
       detailed health check that tells its state, and what it is, free text), with an arrow from each of the
       deployable's web apps; the manifest lists it as a node of kind "dependency" with that entry's name. Without
       dependencies the diagram has none of this. Every node, region and Front Door, database or dependency
       relationship has a slot, a transparent image of a fixed size, where the dashboard draws the live values (a web
       app's slot holds seven lines under its badge: version, pin, traffic, failures, process, uptime and role, and
       an eighth, the marks of its detailed health check, for a deployable with healthDetailPath; then two more, as
       the slot of every node a deployment changes has: what is being deployed there and what just happened, in
       words, from deployments.json). The script downloads the PlantUML release jar of the pinned version from GitHub,
       verifies its SHA-256, renders every diagram in one Java process (layout engine smetana: no Graphviz; security
       profile SANDBOX) and checks that each SVG has every element the manifest names; a missing one fails the step.
       Java's output is logged as information; the download and the render are timed.
       The manifest also says where each box leads that topology.json has no link for (the frames, the regions, the
       Static Web App, the browser: "links", see ConvertTo-RuntimeDiagram), so a click on any box of the page's
       runtime view opens what the box stands for.
       The database view (decision 0040), in the same folder: per environment that has a record of its tables on main
       (environments/<env>/database.json, committed by step "Record database schema" of a deployable that migrates
       the database), a C4 diagram <env>.database.puml, its SVG and its manifest <env>.database.json, with a box per
       table (its row count and its columns), an arrow per pair of tables a foreign key joins, and the entry
       "database" of that environment in index.json; the dashboard zooms from the database box into it. The names
       are an application's and are written as text only (ConvertTo-DatabaseDiagram). A record that cannot be read
       or drawn is one warning and no view; "databaseView": false on "system" in system.json switches it off.
       The application view (decision 0041): the manifest's node of a web app or a container app names, as
       "architecture", the public address where the repository of its deployable (deployables[].repository) publishes
       the logical architecture of each release (https://raw.githubusercontent.com/<org>/<repository>/architecture/
       <deployable>; <version>.json and <version>.svg, written by workflow Architecture of that repository). The page
       zooms from the box into the diagram of the version that runs. Nothing is read or drawn here for it;
       "applicationView": false on "system" in system.json leaves the address out.
    3. The deployment, with the Static Web Apps CLI and the site's deployment token. The token is read from Azure
       when the step runs (the deploy identity may; the stack's deny settings keep everyone else from listing it),
       reaches the CLI through an environment variable, and is never stored, printed or passed as an argument.
    4. The proof: the site serves the topology this step wrote.
    With hosting "storagewebsite", 3 and 4 are Publish-StorageWebsite of scripts/deploy-storagewebsite.ps1, which
    octopus/projects.tf joins in before this script: the static website of the storage account the stack created.

    The topology is a picture of system.json and the recorded nodes at the time of the deployment. After a change to
    the environments, a standby region or a Front Door endpoint, or a deployment of an application with hosting "own"
    that changed its nodes, deploy the dashboard's release again in every environment that has it:
    until then its page shows the old picture, the runtime diagrams too. An environment that is in system.json but not applied yet shows its
    nodes as unreachable. The pinned versions are not part of the picture: the dashboard reads versions.json itself,
    every time it checks the nodes.
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

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

# The Static Web Apps CLI, at a fixed version: a promotion deploys with the tool the earlier environments used.
$swaCliVersion = '2.0.10'
$swaCliNodeVersion = 18

# PlantUML, at a fixed version, for the runtime diagrams: the release jar of github.com/plantuml/plantuml, checked
# against this SHA-256 before it runs. The dashboard finds the drawn elements by attributes of PlantUML's SVG that are
# not a documented contract (they changed in 1.2026.3 and 1.2026.4), so a new version is a change of this script,
# checked by rendering (Write-RuntimeDiagram fails the step when a handle is missing).
$plantUmlVersion = '1.2026.8'
$plantUmlSha256 = '5E1ECFA8ECD32C90B03BBF3B1EB6F020943F98AB0FCF4032BE31A0002EE2C462'

function Get-PortalAddress {
    # The address of a resource's page (a "blade" of its menu, such as overview or performance) in the Azure portal.
    # With the tenant the portal opens the right directory for a viewer who has several.
    param(
        [Parameter(Mandatory)] [string] $ResourceId,
        [string] $Blade = 'overview',
        [string] $TenantId = ''
    )
    $directory = if ($TenantId) { "@$TenantId/" } else { '' }
    return "https://portal.azure.com/#${directory}resource$ResourceId/$Blade"
}

function Get-LogsAddress {
    # The address of the Logs blade of a resource (an Application Insights component) with a query filled in: the
    # portal's own "share a link to the query" form, the query gzipped, base64-encoded and URL-encoded.
    param(
        [Parameter(Mandatory)] [string] $ResourceId,
        [Parameter(Mandatory)] [string] $Query,
        [string] $Timespan = 'PT1H',
        [string] $TenantId = ''
    )
    $buffer = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Query)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Dispose()
    $packed = [Uri]::EscapeDataString([Convert]::ToBase64String($buffer.ToArray()))
    $directory = if ($TenantId) { "@$TenantId/" } else { '' }
    return "https://portal.azure.com/#${directory}blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/resourceId/$([Uri]::EscapeDataString($ResourceId))/source/LogsBlade.AnalyticsShareLinkToQuery/q/$packed/timespan/$Timespan"
}

function Get-ResourcesAddress {
    # The address of Azure Resource Graph Explorer with a query filled in: the resources of one resource group in one
    # region, by type and name. A region is no resource and has no page of its own in the portal; this list is what
    # the region's frame of the runtime diagram stands for.
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Location,
        [string] $TenantId = ''
    )
    $query = @(
        'resources'
        "| where subscriptionId == `"$SubscriptionId`" and resourceGroup =~ `"$ResourceGroup`" and location =~ `"$Location`""
        '| project name, type, location, id'
        '| order by type asc, name asc'
    ) -join "`n"
    $directory = if ($TenantId) { "@$TenantId/" } else { '' }
    return "https://portal.azure.com/#${directory}blade/HubsExtension/ArgQueryBlade/query/$([Uri]::EscapeDataString($query))"
}

function ConvertTo-Topology {
    # The dashboard's topology from system.json (parsed, as a hashtable), the host name of each Front Door endpoint
    # by endpoint name (<slug>-<env>-<deployable>), and the recorded nodes of the deployables with hosting "own" by
    # environment and deployable (each as ConvertTo-NodeRecord returns it). It asks nothing: the same input gives the
    # same topology. The deployables keep the order of system.json.
    # The addresses of the pinned versions and of the Octopus projects are conventions over system.json; one whose
    # parts system.json lacks is null, which the dashboard reads as "not there".
    # The links (where a number of the page leads in the Azure portal) are conventions too, over the subscription, the
    # resource groups and the names the stack gives its resources; without azure.subscriptionId there are none. Only
    # the SQL server's name is not a convention (it ends in a generated suffix): -SqlServer gives it per environment,
    # and an environment without an entry gets no database link.
    # -Dashboard names the deployable that is the dashboard itself (the one this step deploys): when system.json gives
    # it a buildPath, the topology says so as system.dashboard, and the page shows its own Code card. Without the
    # parameter, or without the buildPath, the topology has no such key.
    # A deployable with hosting "own" has the same entry as any other, from two sources: its nodes, its public
    # address and its paths are what its application reported (-NodeRecord; a path it did not report is the
    # deployable's healthPath of system.json, or left out, and the dashboard then asks its own default), and
    # everything else is what system.json says of every deployable (projectUrl, telemetryPath, trafficPaths,
    # buildPath, healthDetailPath). It has no links: the system does not know the application's resources.
    # A deployable that names a page of its own for the dashboard (deployables[].dashboardLink: text and path) gives
    # each environment it exists in an entry of "pages": the words, the deployable, and the path under the address the
    # deployable has in that environment (-PageAddress, by environment and deployable: the address the environment's
    # stack reports). Without an address there, the environment has no such entry; an environment without any has no
    # key "pages".
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [hashtable] $EndpointHost = @{},
        [hashtable] $SqlServer = @{},
        [hashtable] $NodeRecord = @{},
        [hashtable] $PageAddress = @{},
        [datetime] $Generated = [datetime]::UtcNow,
        [string] $Dashboard = ''
    )
    $slug = [string] $System.system.slug
    $location = [string] $System.system.location
    $githubOrg = [string] $System.system['githubOrg']
    $repositoryName = [string] $System.system['repository']
    $repository = if ($githubOrg -and $repositoryName) { "$githubOrg/$repositoryName" } else { '' }
    $octopus = if ($System['octopus']) { $System.octopus } else { @{} }
    $octopusUrl = ([string] $octopus['url']).TrimEnd('/')
    $spaceId = [string] $octopus['spaceId']
    $projects = if ($octopusUrl -and $spaceId) { "$octopusUrl/app#/$spaceId/projects" } else { '' }
    $azure = if ($System['azure']) { $System.azure } else { @{} }
    $tenantId = [string] $azure['tenantId']
    $subscription = if ($azure['subscriptionId']) { "/subscriptions/$([string] $azure.subscriptionId)" } else { '' }
    $groups = if ($azure['resourceGroups']) { $azure.resourceGroups } else { @{} }
    $frontDoor = if ($azure['frontDoor']) { $azure.frontDoor } else { @{} }
    $frontDoorId = if ($subscription -and $frontDoor['profile'] -and $frontDoor['resourceGroup'] -and -not $frontDoor['dormant']) {
        "$subscription/resourceGroups/$([string] $frontDoor.resourceGroup)/providers/Microsoft.Cdn/profiles/$([string] $frontDoor.profile)"
    }
    else { '' }
    $environments = @(foreach ($environment in @($System.environments)) {
            $environmentName = [string] $environment.name
            $versionsPath = "main/environments/$environmentName/versions.json"
            $standbyLocation = [string] $environment['standbyLocation']
            $hasFrontDoor = @($environment['capabilities']) -contains 'frontdoor'
            # The environment's resources by their ids; empty where system.json does not say enough to name one.
            $groupName = [string] $groups[[string] $environment['tier']]
            $group = if ($subscription -and $groupName) { "$subscription/resourceGroups/$groupName" } else { '' }
            $insights = if ($group -and @($environment['capabilities']) -contains 'telemetry') { "$group/providers/microsoft.insights/components/appi-$slug-$environmentName" } else { '' }
            $server = [string] $SqlServer[$environmentName]
            $environmentLinks = [ordered] @{}
            if ($insights) {
                $environmentLinks.applicationInsights = Get-PortalAddress -ResourceId $insights -TenantId $tenantId
                $environmentLinks.applicationMap = Get-PortalAddress -ResourceId $insights -Blade 'applicationMap' -TenantId $tenantId
            }
            if ($group -and $server) {
                $environmentLinks.database = Get-PortalAddress -ResourceId "$group/providers/Microsoft.Sql/servers/$server/databases/sqldb-$slug-$environmentName" -TenantId $tenantId
            }
            if ($group) { $environmentLinks.resourceGroup = Get-PortalAddress -ResourceId $group -TenantId $tenantId }
            $recorded = if ($NodeRecord[$environmentName] -is [Collections.IDictionary]) { $NodeRecord[$environmentName] } else { @{} }
            $deployables = @(foreach ($app in @($System.deployables)) {
                    if ($app['hosting'] -eq 'own') {
                        # What the application reported when it was last verified here; without a record it is left
                        # out of this environment.
                        $record = $recorded[[string] $app.name]
                        if ($record -isnot [Collections.IDictionary]) { continue }
                        $entry = [ordered] @{
                            name       = [string] $app.name
                            projectUrl = if ($projects) { "$projects/$slug-$($app.name)" } else { $null }
                            frontDoor  = if ($record.Contains('frontDoor')) { $record['frontDoor'] } else { $null }
                        }
                        if ($record.Contains('healthPath')) { $entry.healthPath = $record['healthPath'] }
                        elseif ($app['healthPath']) { $entry.healthPath = [string] $app.healthPath }
                        foreach ($key in 'alivePath', 'versionPath') {
                            if ($record.Contains($key)) { $entry[$key] = $record[$key] }
                        }
                        $entry.telemetryPath = if ($app['telemetryPath']) { [string] $app.telemetryPath } else { $null }
                        $entry.trafficPaths = if ($app['trafficPaths']) { , @($app.trafficPaths | ForEach-Object { [string] $_ }) } else { $null }
                        $entry.buildPath = if ($app['buildPath']) { [string] $app.buildPath } else { $null }
                        $entry.healthDetailPath = if ($app['healthDetailPath']) { [string] $app.healthDetailPath } else { $null }
                        $entry.links = [ordered] @{}
                        $entry.nodes = @($record['nodes'])
                        $entry
                        continue
                    }
                    if ($app['hosting'] -ne 'appservice') { continue }
                    $primary = "app-$slug-$environmentName-$($app.name)"
                    $nodes = @([ordered] @{ name = $primary; region = $location; role = 'primary'; url = "https://$primary.azurewebsites.net" })
                    if ($standbyLocation) {
                        $standby = "$primary-$standbyLocation"
                        $nodes += [ordered] @{ name = $standby; region = $standbyLocation; role = 'standby'; url = "https://$standby.azurewebsites.net" }
                    }
                    # Where each node's numbers lead. Application Insights is one component per environment: its
                    # blades show every role, and the Logs queries are filtered to this app's role (OTEL_SERVICE_NAME,
                    # <slug>-<deployable>), which both regions' web apps report under.
                    $role = "$slug-$($app.name)"
                    foreach ($node in $nodes) {
                        $nodeLinks = [ordered] @{}
                        if ($group) { $nodeLinks.portal = Get-PortalAddress -ResourceId "$group/providers/Microsoft.Web/sites/$($node.name)" -Blade 'appServices' -TenantId $tenantId }
                        if ($insights) {
                            $nodeLinks.liveMetrics = Get-PortalAddress -ResourceId $insights -Blade 'quickPulse' -TenantId $tenantId
                            $nodeLinks.performance = Get-PortalAddress -ResourceId $insights -Blade 'performance' -TenantId $tenantId
                            $nodeLinks.failures = Get-PortalAddress -ResourceId $insights -Blade 'failures' -TenantId $tenantId
                            $nodeLinks.dependencies = Get-LogsAddress -ResourceId $insights -TenantId $tenantId -Query (@(
                                    'dependencies'
                                    "| where cloud_RoleName == `"$role`""
                                    '| summarize calls = count(), failed = countif(success == false), avgMs = round(avg(duration), 1), p95Ms = round(percentile(duration, 95), 1) by type, target, name'
                                    '| order by calls desc'
                                ) -join "`n")
                        }
                        if ($nodeLinks.Count -gt 0) { $node.links = $nodeLinks }
                    }
                    $deployableLinks = [ordered] @{}
                    if ($hasFrontDoor -and $frontDoorId) { $deployableLinks.frontDoor = Get-PortalAddress -ResourceId $frontDoorId -TenantId $tenantId }
                    if ($insights) {
                        $deployableLinks.logs = Get-LogsAddress -ResourceId $insights -TenantId $tenantId -Query (@(
                                'requests'
                                "| where cloud_RoleName == `"$role`""
                                '| summarize requests = count(), failed = countif(success == false), p95Ms = round(percentile(duration, 95), 1) by bin(timestamp, 5m), cloud_RoleInstance'
                                '| order by timestamp desc'
                            ) -join "`n")
                    }
                    $hostName = [string] $EndpointHost["$slug-$environmentName-$($app.name)"]
                    [ordered] @{
                        name        = [string] $app.name
                        projectUrl  = if ($projects) { "$projects/$slug-$($app.name)" } else { $null }
                        frontDoor   = if ($hasFrontDoor -and $hostName) { "https://$hostName" } else { $null }
                        healthPath  = if ($app['healthPath']) { [string] $app.healthPath } else { '/_healthcheck' }
                        alivePath   = '/alive'
                        versionPath = '/_version'
                        # The app's own count of its calls (deployables[].telemetryPath), and what the traffic button
                        # calls (deployables[].trafficPaths): null without them, so an app without the endpoint shows dashes.
                        telemetryPath = if ($app['telemetryPath']) { [string] $app.telemetryPath } else { $null }
                        trafficPaths  = if ($app['trafficPaths']) { , @($app.trafficPaths | ForEach-Object { [string] $_ }) } else { $null }
                        # Where the primary node reports the build it runs (deployables[].buildPath): null without it,
                        # and the dashboard then shows no "Code" card.
                        buildPath   = if ($app['buildPath']) { [string] $app.buildPath } else { $null }
                        # Where a node answers its detailed health check (deployables[].healthDetailPath): one entry
                        # per dependency it checks. Null without it, and the dashboard then shows no such marks.
                        healthDetailPath = if ($app['healthDetailPath']) { [string] $app.healthDetailPath } else { $null }
                        links       = $deployableLinks
                        nodes       = $nodes
                    }
                })
            $addresses = if ($PageAddress[$environmentName] -is [Collections.IDictionary]) { $PageAddress[$environmentName] } else { @{} }
            $pages = @(foreach ($app in @($System.deployables)) {
                    $link = $app['dashboardLink']
                    if ($link -isnot [Collections.IDictionary] -or -not $link['text'] -or -not $link['path']) { continue }
                    if ($app['environments'] -and @($app.environments) -notcontains $environmentName) { continue }
                    $address = ([string] $addresses[[string] $app.name]).TrimEnd('/')
                    if ($address -notmatch '^https?://') { continue }
                    [ordered] @{ name = [string] $link.text; url = "$address/$(([string] $link.path).TrimStart('/'))"; deployable = [string] $app.name }
                })
            $listed = [ordered] @{
                name               = $environmentName
                tier               = [string] $environment['tier']
                versionsUrl        = if ($repository) { "https://raw.githubusercontent.com/$repository/$versionsPath" } else { $null }
                versionsHistoryUrl = if ($repository) { "https://github.com/$repository/commits/$versionsPath" } else { $null }
                links              = $environmentLinks
                deployables        = $deployables
            }
            if ($pages.Count -gt 0) { $listed.pages = $pages }
            $listed
        })
    $about = [ordered] @{
        slug           = $slug
        name           = [string] $System.system['name']
        repository     = if ($repository) { "https://github.com/$repository" } else { $null }
        # The delivery facts (who deployed what when, lead time, the last failover test): a workflow of the system
        # repository publishes them to its branch "status"; until it has, the address answers 404 and the
        # dashboard shows no delivery.
        deliveryUrl    = if ($repository) { "https://raw.githubusercontent.com/$repository/status/delivery.json" } else { $null }
        # What each environment cost in Azure (yesterday, seven days, the month to date): the same workflow publishes
        # it next to the delivery facts, hourly; until it has, the dashboard shows no cost.
        costUrl        = if ($repository) { "https://raw.githubusercontent.com/$repository/status/cost.json" } else { $null }
        # What is being deployed (queued, running, waiting for a sign-off, just ended): workflow deployments of the
        # system repository publishes it to its branch "deployments"; until it has, the dashboard marks nothing.
        deploymentsUrl = if ($repository) { "https://raw.githubusercontent.com/$repository/deployments/deployments.json" } else { $null }
    }
    # The dashboard itself and where its site serves the facts of its own build (deployables[].buildPath of the
    # dashboard's deployable): the page reads that file from its own address. No key without it.
    $self = @($System.deployables | Where-Object { $Dashboard -and $_ -and [string] $_['name'] -eq $Dashboard -and $_['buildPath'] }) | Select-Object -First 1
    if ($self) { $about.dashboard = [ordered] @{ name = [string] $self.name; buildPath = [string] $self.buildPath } }
    return [ordered] @{
        system       = $about
        generated    = $Generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        environments = $environments
    }
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

function Measure-Topology {
    # What a topology holds, for the step's summary line: its environments, its nodes (those by naming convention and
    # those an application reported) and its public addresses.
    param([Parameter(Mandatory)] [Collections.IDictionary] $Topology)
    $nodes = 0
    $addresses = 0
    foreach ($environment in @($Topology['environments'])) {
        foreach ($deployable in @($environment['deployables'])) {
            $nodes += @($deployable['nodes']).Count
            if ($deployable['frontDoor']) { $addresses++ }
        }
    }
    return @{ Environments = @($Topology['environments']).Count; Nodes = $nodes; Addresses = $addresses }
}

function Read-MainFile {
    # The text of a file of the system repository on main (-Ref: another branch), or $null when it has no such file (404).
    param([Parameter(Mandatory)] [string] $Path, [string] $Ref = 'main')
    try {
        $file = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/contents/${Path}?ref=$Ref" -Headers $headers
    }
    catch {
        # Not every failure has a response (a name that does not resolve).
        $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
        if ($response -and [int] $response.StatusCode -eq 404) { return $null }
        throw
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
}

function Read-NodeRecord {
    # The nodes of the deployables with hosting "own", by environment and deployable: only the application knows what
    # it runs on, and its step "Record nodes" records what it reported in environments/<env>/nodes.json on main
    # (scripts/record-nodes.ps1). Read for every environment, as the topology shows them all. A deployable
    # without a record in an environment is left out there, with one line that says so; a record that breaks the
    # rules stops the step, because the dashboard shows nothing at all when one entry of its topology is wrong.
    param([Parameter(Mandatory)] [hashtable] $System)
    $records = @{}
    $owners = @($System.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
    if ($owners.Count -eq 0) { return $records }
    foreach ($environment in @($System.environments | ForEach-Object { [string] $_.name })) {
        $path = "environments/$environment/nodes.json"
        $text = Read-MainFile -Path $path
        $recorded = $null
        if ($null -ne $text) {
            $recorded = try { $text | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
            if ($recorded -isnot [Collections.IDictionary]) {
                Fail-Step "$path on main of $repository is not a JSON object: correct it by pull request, then deploy $name $version to $environmentName again."
            }
        }
        $records[$environment] = @{}
        foreach ($owner in $owners) {
            if ($null -eq $recorded -or -not $recorded.Contains($owner)) {
                Write-Host "No nodes of $owner are recorded for $environment ($path on main): the dashboard leaves $owner out of $environment until its application reports them there and this release is deployed again."
                continue
            }
            $checked = ConvertTo-NodeRecord $recorded[$owner]
            if ($checked.Problems.Count -gt 0) {
                Fail-Step "$path on main of $repository records nodes of $owner that break the rules: $($checked.Problems -join '; '). The next deployment of $owner to $environment writes the record anew; then deploy $name $version to $environmentName again."
            }
            $records[$environment][$owner] = $checked.Record
        }
    }
    return $records
}

function New-TransparentPng {
    # A fully transparent PNG of the given size, as a data: URI. The runtime diagrams reserve the room the browser draws
    # into with such an image (a "slot"): PlantUML lays it out like any image, and its size never depends on text.
    param(
        [Parameter(Mandatory)] [int] $Width,
        [Parameter(Mandatory)] [int] $Height
    )
    function ConvertTo-BigEndian { param([uint32] $Value) [byte[]] @((($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255)) }
    function Get-Crc32 {
        param([byte[]] $Bytes)
        [uint32] $crc = [uint32]::MaxValue
        foreach ($byte in $Bytes) {
            $crc = [uint32] ($crc -bxor $byte)
            for ($bit = 0; $bit -lt 8; $bit++) {
                $crc = if ($crc -band 1) { [uint32] (($crc -shr 1) -bxor 0xEDB88320u) } else { [uint32] ($crc -shr 1) }
            }
        }
        [uint32] ($crc -bxor [uint32]::MaxValue)
    }
    function New-Chunk {
        param([string] $Type, [byte[]] $Data)
        $typed = [byte[]] ([Text.Encoding]::ASCII.GetBytes($Type) + $Data)
        [byte[]] ((ConvertTo-BigEndian ([uint32] $Data.Length)) + $typed + (ConvertTo-BigEndian (Get-Crc32 $typed)))
    }
    # Every row: filter byte 0, then width RGBA pixels of 0 (transparent black).
    $raw = [byte[]]::new(($Width * 4 + 1) * $Height)
    $buffer = [IO.MemoryStream]::new()
    $zlib = [IO.Compression.ZLibStream]::new($buffer, [IO.Compression.CompressionLevel]::SmallestSize, $true)
    $zlib.Write($raw, 0, $raw.Length)
    $zlib.Dispose()
    $header = [byte[]] ((ConvertTo-BigEndian ([uint32] $Width)) + (ConvertTo-BigEndian ([uint32] $Height)) + [byte[]] @(8, 6, 0, 0, 0))
    $png = [byte[]] @(137, 80, 78, 71, 13, 10, 26, 10) + (New-Chunk 'IHDR' $header) + (New-Chunk 'IDAT' $buffer.ToArray()) + (New-Chunk 'IEND' ([byte[]] @()))
    return "data:image/png;base64,$([Convert]::ToBase64String([byte[]] $png))"
}

function ConvertTo-RuntimeDiagram {
    # The runtime diagram of one environment: PlantUML source (C4 deployment view) and the manifest that tells the
    # dashboard which drawn element is which. It asks nothing: the same input gives the same diagram.
    #
    # Input: system.json (parsed, as a hashtable), the topology ConvertTo-Topology made of it (the nodes, their
    # addresses and the Front Door addresses), the environment's name, and the dashboard's address per environment when
    # known (the stack of the environment that deploys knows its own; the others' are not conventions).
    #
    # Aliases (PlantUML's names of the elements; the dashboard finds the drawn elements by them, and the manifest maps
    # each to what the browser knows). <d> is a deployable's name with every character but a letter or a digit as "_":
    #   browser                     the person: a browser on the internet
    #   sub                         boundary: the Azure subscription
    #   rg_edge, rg_tier            boundaries: the Front Door's resource group, the environment's tier's group
    #   afd                         the Front Door profile (azure.frontDoor.profile)
    #   region_primary, region_standby, region_data, region_static
    #                               boundaries: one per Azure region, named after its first role: the primary region
    #                               (system.location), the standby (environments[].standbyLocation), the database's
    #                               (system.sqlLocation) and the static sites' (system.staticLocation). A region with
    #                               two roles is one boundary.
    #   plan_primary, plan_standby  the App Service plans
    #   fd_<d>                      the Front Door endpoint of an App Service deployable
    #   app_<d>_primary, app_<d>_standby   its web apps
    #   sqldb                       the environment's Azure SQL database
    #   swa_<d>                     the Static Web App of a static deployable (the dashboard)
    #   dep_<d>_<n>                 a dependency of a deployable (system.json deployables[].dependencies), outside the
    #                               subscription; <n> is its name, written as <d> is
    #   own_<d>                     boundary: the runtime of a deployable with hosting "own", outside the subscription,
    #                               because the system does not know where the application runs. In it, what the
    #                               application reported for this environment (the deployable's entry of the topology):
    #   fd_<d>                        its public address, when it reported one
    #   region_own_<d>_<n>            boundaries: one per region its nodes name, numbered in the order of the report
    #                                 (nodes without a region share one)
    #   app_<d>_<n>                   its nodes, numbered in the order of the report; kind "webapp" in the manifest, so
    #                                 the dashboard draws the same tile as for a web app
    # Every relationship has the id "<from>-to-<to>" (PlantUML's own form): browser-to-fd_<d>, fd_<d>-to-app_<d>_primary
    # (origin, priority 1), fd_<d>-to-app_<d>_standby (priority 2), app_<d>_<role>-to-sqldb, browser-to-swa_<d>, and
    # without a Front Door endpoint browser-to-app_<d>_<role>. The id is how the SVG names the drawn link, and a web
    # app's relationship to a dependency is drawn from the dependency's side (see Add-Edge): its id is
    # dep_<d>_<n>-to-app_<d>_<role>, while its "from" is the web app and its "to" the dependency.
    # A deployable with hosting "own": browser-to-fd_<d> and fd_<d>-to-app_<d>_<n> (origin; priority 1 for a node with
    # the role primary, 2 for a standby: the system does not know how the application's public address routes), or
    # browser-to-app_<d>_<n> without a public address. No relationship to the database: the system does not know
    # what such an application stores its data in.
    #
    # Slots: every node's description is a transparent image of a fixed size, and so is the description of every
    # origin, database and dependency relationship and of every region: the dashboard draws the live values into those
    # rectangles.
    #
    # Links: where a box leads when the topology has no link for it. The manifest lists every frame that is no region
    # ("frames": alias, qualifiedName, kind, name) and gives a frame, a region or a node "links", a map of one key:
    #   portal     the resource's page in the Azure portal, from its id: the subscription, a resource group, the Front
    #              Door profile, an App Service plan, a Static Web App. Without azure.subscriptionId there is none.
    #   resources  a region of the system: the resources of the tier's resource group in that region, a query in Azure
    #              Resource Graph Explorer (Get-ResourcesAddress)
    #   project    the boundary of an application with its own runtime: its Octopus project (the topology's projectUrl)
    #   site       an address a browser opens: the browser's box (the first public address of the diagram), and the
    #              public address and the nodes of an application with its own runtime
    # A web app, a Front Door endpoint and the database have their links in topology.json, as before; a dependency
    # and the region of an application with its own runtime have none: the system knows no address for them.
    #
    # The container apps the system creates (hosting "containerapp", the default) are drawn too, from -ContainerApp
    # (environment, then deployable, to the address the environment's stack reports: their addresses are generated, no
    # convention names them). A Container Apps environment is a box under the subscription, named after its address
    # (the part of the host name the platform generates) and its region, with a box per app:
    #   cae_<n>                     the Container Apps environment, numbered in the order system.json lists the apps
    #   ca_<d>                      a container app; kind "containerapp" in the manifest, its address in "url" and in
    #                               its "links" (site), its deployable's "healthPath" (a plain path only), and "ids"
    #                               (its resource id) where the groups' list has it. The page probes it once a minute
    #                               while it shows the diagram (decision 0038). Its slot also has rows for what the
    #                               hourly health report last found there
    #   browser-to-ca_<d>           its public address (kind "direct": the page marks no number on it)
    #   ca_<d>-to-sqldb             where the app uses the database (kind "sql", as a web app's)
    # A declared app without an address (the environment has none yet, or its stack is not readable from here) is not
    # drawn from the stack.
    #
    # Everything else the system's resource groups hold is drawn too, from -Resource (the key of azure.resourceGroups,
    # then what its group lists: type, name, environment tag, location, id, group, and for a container app its address
    # and its Container Apps environment), so that the diagram shows the entire system and not only what the registry
    # declares: the vault, the identities, the telemetry, the SQL server, a container app nobody declared, a storage
    # account the system added in infra/own, whatever else is there, in every group and whatever its tag. Left out: a
    # child of another resource (a database of the SQL server, a secret), a role assignment, what another environment
    # of the system carries as its tag (its own diagram draws it), and what the diagram draws already, by type and
    # name: the web apps, the plans, the static sites, the Front Door profile, the container apps, and the Container
    # Apps environment of a drawn app (the database is a child of its server). One box per type, named after the
    # resource when there is one and "<type> (<n>)" with the names below when there are several:
    #   supporting                  this environment's resources of the tier's group, inside its boundary
    #   supporting_edge             those of the Front Door's group, inside rg_edge
    #   rg_<n>, supporting_<n>      those of any other group: its boundary, and the box inside it
    #   unplaced                    "In no environment": the system's resources with no environment tag, or a tag
    #                               that names no environment of system.json, in every diagram; each box says its
    #                               group and its tag (or that it has none)
    #   res_<n>                     one box per type (in "unplaced", per type, group and tag), numbered in the order of
    #                               the types' names; kind "resource" in the manifest, with its "names", "group",
    #                               "environmentTag" in "unplaced", "ids" (the members' resource ids), and its page in
    #                               the Azure portal (for several, the group's)
    #   cax_<n>                     a container app system.json does not declare, from the list: kind "containerapp",
    #                               no deployable and no health path, its address where it has a public one, and its
    #                               id; in its Container Apps environment's box when it is of this environment, in
    #                               "unplaced" otherwise. The page probes its address as a declared one's
    # The browser cannot ask a resource: its box has a slot of one line, where the page says what Azure Resource Health
    # last said of its members (containers.json on branch status, by "ids"). The static sites and the database get
    # "ids" too, from the same list (the database is a child of its server, found by its name).
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Topology,
        [Parameter(Mandatory)] [string] $Environment,
        [hashtable] $DashboardUrl = @{},
        [hashtable] $ContainerApp = @{},
        [hashtable] $Resource = @{}
    )
    $slug = [string] $System.system.slug
    $location = [string] $System.system.location
    $sqlLocation = if ($System.system['sqlLocation']) { [string] $System.system.sqlLocation } else { $location }
    $staticLocation = if ($System.system['staticLocation']) { [string] $System.system.staticLocation } else { 'centralus' }
    $entry = @($System.environments | Where-Object { [string] $_.name -eq $Environment }) | Select-Object -First 1
    if (-not $entry) { throw "system.json has no environment $Environment." }
    $tier = [string] $entry['tier']
    $standbyLocation = [string] $entry['standbyLocation']
    $tierGroup = [string] $System.azure.resourceGroups[$tier]
    $frontDoor = if ($System.azure.ContainsKey('frontDoor')) { $System.azure.frontDoor } else { @{} }
    $dormant = [bool] $frontDoor['dormant']
    $hasFrontDoor = (@($entry['capabilities']) -contains 'frontdoor') -and $frontDoor['profile'] -and -not $dormant
    # The ids the links are made of: empty where system.json does not say enough to name the resource.
    $tenantId = [string] $System.azure['tenantId']
    $subscriptionId = [string] $System.azure['subscriptionId']
    $subscription = if ($subscriptionId) { "/subscriptions/$subscriptionId" } else { '' }
    $tierGroupId = if ($subscription -and $tierGroup) { "$subscription/resourceGroups/$tierGroup" } else { '' }
    $edgeGroupId = if ($subscription -and $frontDoor['resourceGroup']) { "$subscription/resourceGroups/$([string] $frontDoor.resourceGroup)" } else { '' }
    $planSkus = if ($System.system['planSku']) { $System.system.planSku } else { @{} }
    $size = if (-not $dormant -and $planSkus[$tier]) { [string] $planSkus[$tier] } else { 'F1' }
    $sameTier = @($System.environments | Where-Object { [string] $_['tier'] -eq $tier })
    # A static site may name the environments it exists in (deployables[].environments): it is drawn only there.
    $statics = @($System.deployables | Where-Object { $_['hosting'] -eq 'staticwebapp' -and (-not $_['environments'] -or @($_['environments']) -contains $Environment) })
    $topologyEnvironment = @($Topology.environments | Where-Object { $_.name -eq $Environment }) | Select-Object -First 1
    # The deployables of the topology by their hosting in system.json: the App Service apps are drawn in the system's
    # own resources (plans, regions, the Front Door profile), the applications that bring their own runtime (hosting
    # "own") in a boundary of their own with what they reported.
    $hostingOf = @{}
    foreach ($declared in @($System.deployables)) { $hostingOf[[string] $declared.name] = if ($declared['hosting']) { [string] $declared.hosting } else { 'containerapp' } }
    $listed = if ($topologyEnvironment) { @($topologyEnvironment.deployables) } else { @() }
    $apps = @($listed | Where-Object { $hostingOf[[string] $_.name] -ne 'own' })
    $owns = @($listed | Where-Object { $hostingOf[[string] $_.name] -eq 'own' })
    # The environment has a database when an app in it uses one: the rule of infra/main.bicep (hasDatabase). A
    # container deployable uses it unless it says "database": false, and an App Service deployable shares it; a
    # deployable exists in every environment unless it names some (deployables[].environments).
    $hasDatabase = @($System.deployables | Where-Object {
            $hosting = if ($_['hosting']) { [string] $_.hosting } else { 'containerapp' }
            $here = -not $_['environments'] -or @($_['environments']) -contains $Environment
            $here -and (($hosting -eq 'containerapp' -and $_['database'] -ne $false) -or $hosting -eq 'appservice')
        }).Count -gt 0

    $aliasOf = @{}
    function Get-DeployableAlias {
        param([string] $Name)
        $alias = $Name -replace '[^A-Za-z0-9]', '_'
        if ($aliasOf.ContainsKey($alias) -and $aliasOf[$alias] -ne $Name) {
            throw "Deployables $($aliasOf[$alias]) and $Name have the same alias $alias in the runtime diagram: rename one."
        }
        $aliasOf[$alias] = $Name
        $alias
    }
    function Get-Quoted { param([string] $Text) '"' + ($Text -replace '"', "'") + '"' }
    # What an application reported (a name, a region, an address) is not the kit's text, and PlantUML reads more than
    # words: [[ ]] is a link, < > a tag, %name() a function of its preprocessor, a line that starts with ! a
    # directive. ConvertTo-NodeRecord refuses such a value before it is recorded; the record on main may still be
    # older than that rule, or written by hand, so the source is not built on trust. A reported text is written with
    # letters, digits, space and . _ - only (the characters the record allows), every other character (a line break
    # too) as "_", and cut at its length; a reported address becomes a link only when it is an https address with a
    # public host name, by the rule of the record. Neither can fail: a diagram with an odd label is drawn, where a refused one would stop the dashboard's
    # deployment.
    function Get-Reported {
        param([AllowNull()] [AllowEmptyString()] [string] $Text, [int] $Longest = 100)
        $plain = "$Text" -replace '[^A-Za-z0-9 ._-]', '_'
        if ($plain.Length -gt $Longest) { $plain = $plain.Substring(0, $Longest) }
        $plain
    }
    function Get-ReportedHost {
        # The host name of a reported address, '' when it has none that can be read.
        param([AllowNull()] [AllowEmptyString()] [string] $Url)
        $address = $null
        if ([uri]::TryCreate("$Url", [UriKind]::Absolute, [ref] $address) -and $address.Scheme -cin 'http', 'https') { return Get-Reported ([string] $address.Host) 253 }
        return ''
    }
    function Get-ReportedLink {
        # A reported address as the target of a link in the diagram, '' when it is not an https address with a public
        # host name (the rule of ConvertTo-NodeRecord).
        param([AllowNull()] [AllowEmptyString()] [string] $Url)
        if ("$Url".Length -le 300 -and "$Url" -cmatch '^https://(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?<last>[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?\z' -and $Matches['last'] -notin 'localhost', 'local', 'internal', 'svc') { return "$Url" }
        return ''
    }

    # Slots: the room for a tile, a region's label and a number line of a relationship (pixels; the dashboard's
    # runtime.js draws into them and assumes nothing about their size but what the SVG says).
    # A web app's tile: the badge, seven lines 15 px apart (version, pin, traffic, failures, process, uptime, role)
    # and the history strip; one line more, the marks of the detailed health check, for a deployable with
    # healthDetailPath. A Front Door endpoint's has three lines; a database's, a static site's and a dependency's one;
    # a container app's three: its address, and what the pipeline's hourly health report last found there and counted
    # (delivery.json), which the page shows in place of a probe of its own.
    # A node a deployment changes (a web app, a Front Door endpoint, a static site: every node with a deployable) has
    # two lines more, 30 px: the activity lines, where the dashboard says in words what is being deployed there, a
    # deployment freeze and the last deployment that ended (deployments.json). They are the last lines of a tile, so
    # a diagram rendered before them has no row for them and loses nothing else.
    # The widths are what the widest line needs and no more: the diagram of an environment with a standby is five
    # boxes and three number lines wide, and every pixel here is paid for by the page's scale.
    $tileWidth = 232
    $activityRows = 30
    $tileSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height (146 + $activityRows))>"
    $tileSlotWithChecks = "<img:$(New-TransparentPng -Width $tileWidth -Height (161 + $activityRows))>"
    $endpointSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height (98 + $activityRows))>"
    $smallTileSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height 46)>"
    $siteSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height (46 + $activityRows))>"
    $containerSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height (76 + $activityRows))>"
    # A resource's: the badge and one line of Resource Health, under the box's own words.
    $resourceSlot = "<img:$(New-TransparentPng -Width 200 -Height 46)>"
    $regionSlot = "<img:$(New-TransparentPng -Width 190 -Height 22)>"
    # A relationship's number line (the number, its unit and its trend in a frame) and, under it, its role in words
    # ("app queries · 55 background").
    $edgeSlot = "<img:$(New-TransparentPng -Width 144 -Height 34)>"

    # The container apps the system creates, in the Container Apps environment the platform made for them: named as the
    # platform names it in the apps' addresses, <app>.<environment>.<region>.azurecontainerapps.io.
    $containerAddresses = if ($ContainerApp[$Environment] -is [System.Collections.IDictionary]) { $ContainerApp[$Environment] } else { @{} }
    $containers = @($System.deployables | Where-Object {
            (-not $_['hosting'] -or $_['hosting'] -eq 'containerapp') -and
            (-not $_['environments'] -or @($_['environments']) -contains $Environment) -and
            ([string] $containerAddresses[[string] $_.name]) -match '^https://[^/]+'
        } | ForEach-Object {
            $address = ([string] $containerAddresses[[string] $_.name]).TrimEnd('/')
            $hostName = ([uri] $address).Host
            $parts = $hostName -split '\.', 2
            $domain = if ($parts.Count -gt 1) { $parts[1] } else { $hostName }
            $region = ''
            if ($domain -match '^(?<environment>[^.]+)\.(?<region>[^.]+)\.azurecontainerapps\.io$') { $domain = $Matches.environment; $region = $Matches.region }
            $healthPath = if ([string] $_['healthPath'] -cmatch '^/(?!/)[A-Za-z0-9._~/-]{0,199}\z') { [string] $_.healthPath } else { '' }
            [pscustomobject] @{ Deployable = [string] $_.name; Address = $address; App = $parts[0]; Environment = $domain; Region = $region; Database = ($_['database'] -ne $false); Alias = "ca_$(Get-DeployableAlias ([string] $_.name))"; Words = "container app: $([string] $_.name)"; Links = $null; Group = $domain; EnvironmentId = ''; Tag = ''; Id = ''; HealthPath = $healthPath }
        })
    $containerApps = @($containers | ForEach-Object { [pscustomobject] @{ name = $_.Deployable } })

    # The dependencies the deployables declare (system.json deployables[].dependencies), by deployable: each is drawn
    # outside the subscription. The alias is made of both names; two that give the same alias are an error.
    $dependenciesOf = [ordered] @{}
    $dependencyAlias = @{}
    foreach ($app in @($apps) + @($owns) + @($containerApps)) {
        $declared = @($System.deployables | Where-Object { [string] $_.name -eq [string] $app.name }) | Select-Object -First 1
        if (-not $declared -or -not $declared['dependencies']) { continue }
        $position = 0
        $dependenciesOf[[string] $app.name] = @(foreach ($dependency in @($declared.dependencies)) {
                $dependencyName = if ($dependency -is [System.Collections.IDictionary]) { ([string] $dependency['name']).Trim() } else { '' }
                if (-not $dependencyName) { throw "system.json: deployables '$($app.name)', dependencies[$position] has no name." }
                $alias = "dep_$(Get-DeployableAlias $app.name)_$($dependencyName -replace '[^A-Za-z0-9]', '_')"
                if ($dependencyAlias.ContainsKey($alias)) {
                    throw "Dependencies '$($dependencyAlias[$alias])' and '$dependencyName' of $($app.name) have the same alias $alias in the runtime diagram: rename one."
                }
                $dependencyAlias[$alias] = $dependencyName
                $position++
                [ordered] @{
                    alias       = $alias
                    name        = $dependencyName
                    healthCheck = if ($dependency['healthCheck']) { ([string] $dependency.healthCheck).Trim() } else { $null }
                    kind        = if ($dependency['kind']) { ([string] $dependency.kind).Trim() } else { 'external' }
                }
            })
    }

    # The regions, a region with two roles once, named after its first role. The standby is declared before the
    # primary: PlantUML's layout engine (smetana) stacks the last declared on top, and the primary belongs there.
    $regions = [ordered] @{}
    function Add-Region {
        param([string] $Name, [string] $Role)
        if (-not $Name) { return }
        if (-not $regions.Contains($Name)) { $regions[$Name] = [ordered] @{ alias = "region_$Role"; name = $Name; roles = [Collections.Generic.List[string]]::new() } }
        if (-not $regions[$Name].roles.Contains($Role)) { $regions[$Name].roles.Add($Role) }
    }
    if ($apps.Count -gt 0) {
        if ($standbyLocation) { Add-Region $standbyLocation 'standby' }
        Add-Region $location 'primary'
    }
    if ($hasDatabase) { Add-Region $sqlLocation 'data' }
    if ($statics.Count -gt 0) { Add-Region $staticLocation 'static' }

    $nodes = [Collections.Generic.List[object]]::new()
    $edges = [Collections.Generic.List[object]]::new()
    $regionManifest = [Collections.Generic.List[object]]::new()
    $frames = [Collections.Generic.List[object]]::new()
    $publicAddress = [Collections.Generic.List[string]]::new()
    $edgeLines = [Collections.Generic.List[string]]::new()
    function Get-PortalLink {
        # The "links" of a resource by its id: its page in the Azure portal; nothing without the id.
        param([AllowEmptyString()] [string] $ResourceId)
        if (-not $ResourceId) { return $null }
        return [ordered] @{ portal = Get-PortalAddress -ResourceId $ResourceId -TenantId $tenantId }
    }
    function Add-Node {
        param([System.Collections.Specialized.OrderedDictionary] $Node, [AllowNull()] [System.Collections.IDictionary] $Links = $null)
        if ($Links -and $Links.Count -gt 0) { $Node.links = $Links }
        $nodes.Add($Node)
    }
    function Add-Frame {
        # A frame that is no region: the dashboard knows it by its alias, and its name leads where "links" says.
        param([string] $Alias, [string] $QualifiedName, [string] $Kind, [string] $Name, [AllowNull()] [System.Collections.IDictionary] $Links = $null)
        $frame = [ordered] @{ alias = $Alias; qualifiedName = $QualifiedName; kind = $Kind; name = $Name }
        if ($Links -and $Links.Count -gt 0) { $frame.links = $Links }
        $frames.Add($frame)
    }
    function Add-RegionFrame {
        param([System.Collections.Specialized.OrderedDictionary] $Region, [AllowNull()] [System.Collections.IDictionary] $Links = $null)
        if ($Links -and $Links.Count -gt 0) { $Region.links = $Links }
        $regionManifest.Add($Region)
    }
    function Add-Edge {
        # -Upstream draws the relationship with Rel_U: in this left-to-right layout the target is then ranked before
        # the source (to its left), and PlantUML names the link by that order, so the id is "<to>-to-<from>".
        param([string] $From, [string] $To, [string] $Kind, [string] $Label, [string] $Technology, [bool] $Slot, [int] $Priority = 0, [string] $Link = '', [switch] $Upstream)
        $id = if ($Upstream) { "$To-to-$From" } else { "$From-to-$To" }
        $macro = if ($Upstream) { 'Rel_U' } else { 'Rel' }
        $edge = [ordered] @{ id = $id; from = $From; to = $To; kind = $Kind }
        if ($Priority) { $edge.priority = $Priority }
        $edges.Add($edge)
        if ($Kind -eq 'public' -and $Link) { $publicAddress.Add($Link) }
        $description = if ($Slot) { $edgeSlot + '\n<U+00A0>' } else { '' }
        $address = if ($Link) { ", `$link=$(Get-Quoted $Link)" } else { '' }
        $edgeLines.Add("$macro($From, $To, $(Get-Quoted $Label), $(Get-Quoted $Technology), $(Get-Quoted $description)$address)")
    }
    function Get-ShortHost {
        # A public address as the arrow's label: the host name, and when that is long its start, an ellipsis and the
        # registered domain, so "cmdemo2-prod-ui-a2b5hkfrchg3ckew.z02.azurefd.net" reads "cmdemo2-prod-ui-a2…azurefd.net".
        param([string] $Url, [int] $Length = 30)
        $name = Get-ReportedHost $Url
        if ($name.Length -le $Length) { return $name }
        $domain = ($name -split '\.' | Select-Object -Last 2) -join '.'
        $start = [Math]::Max(4, $Length - $domain.Length - 1)
        return $name.Substring(0, $start) + [char] 0x2026 + $domain
    }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('@startuml')
    $lines.Add('!pragma layout smetana')
    $lines.Add('!include <C4/C4_Deployment>')
    $lines.Add('LAYOUT_LEFT_RIGHT()')
    $lines.Add('HIDE_STEREOTYPE()')
    $lines.Add('SHOW_PERSON_OUTLINE()')
    $lines.Add('skinparam wrapWidth 300')
    $lines.Add('skinparam maxMessageSize 220')
    # A public address on an arrow is a link, in the page's link colour, that opens in a new tab.
    $lines.Add('skinparam svgLinkTarget _blank')
    $lines.Add('skinparam hyperlinkColor #1f5fae')
    $lines.Add('skinparam hyperlinkUnderline true')
    $lines.Add('skinparam nodesep 30')
    $lines.Add('skinparam ranksep 40')
    # The look before the dashboard updates it (and of a diagram opened on its own): neutral, nothing claims a state.
    $lines.Add('UpdateElementStyle("container", $bgColor="#607d8b", $fontColor="#ffffff", $borderColor="#455a64")')
    $lines.Add('UpdateElementStyle("person", $bgColor="#37474f", $fontColor="#ffffff", $borderColor="#263238")')
    if ($dependenciesOf.Count -gt 0) {
        $lines.Add('UpdateElementStyle("external_system", $bgColor="#607d8b", $fontColor="#ffffff", $borderColor="#455a64")')
    }
    $lines.Add('AddBoundaryTag("scope", $bgColor="#ffffff", $fontColor="#263238", $borderColor="#78909c", $borderStyle=DottedLine())')
    $lines.Add('AddNodeTag("region", $bgColor="#fafafa", $fontColor="#37474f", $borderColor="#90a4ae", $borderStyle=DashedLine())')
    $lines.Add('AddNodeTag("plan", $bgColor="#ffffff", $fontColor="#37474f", $borderColor="#b0bec5")')
    $lines.Add('UpdateRelStyle($textColor="#455a64", $lineColor="#78909c")')
    $lines.Add('')
    $lines.Add('Person(browser, "Browser", "a user, or this dashboard")')
    $nodes.Add([ordered] @{ alias = 'browser'; qualifiedName = 'browser'; kind = 'person'; name = 'Browser' })
    $lines.Add('Boundary(sub, "Azure subscription", $type="subscription", $tags="scope") {')
    Add-Frame 'sub' 'sub' 'subscription' 'Azure subscription' (Get-PortalLink $subscription)

    $edgeGroupEnd = -1
    if ($hasFrontDoor -and $apps.Count -gt 0) {
        $profileName = [string] $frontDoor.profile
        $lines.Add("  Boundary(rg_edge, $(Get-Quoted ([string] $frontDoor.resourceGroup)), `$type=`"resource group`", `$tags=`"scope`") {")
        Add-Frame 'rg_edge' 'sub.rg_edge' 'resourceGroup' ([string] $frontDoor.resourceGroup) (Get-PortalLink $edgeGroupId)
        $lines.Add("    Deployment_Node(afd, $(Get-Quoted $profileName), `"Front Door profile, Standard: global`", `$tags=`"plan`") {")
        Add-Frame 'afd' 'sub.rg_edge.afd' 'frontDoorProfile' $profileName (Get-PortalLink $(if ($edgeGroupId) { "$edgeGroupId/providers/Microsoft.Cdn/profiles/$profileName" } else { '' }))
        foreach ($app in $apps) {
            $alias = "fd_$(Get-DeployableAlias $app.name)"
            $endpoint = "$slug-$Environment-$($app.name)"
            $lines.Add("      Container($alias, $(Get-Quoted $endpoint), `"Front Door endpoint`", $(Get-Quoted $endpointSlot))")
            Add-Node ([ordered] @{ alias = $alias; qualifiedName = "sub.rg_edge.afd.$alias"; kind = 'frontdoor'; deployable = [string] $app.name; name = $endpoint; url = $app.frontDoor })
        }
        $lines.Add('    }')
        # Where this environment's other resources of the Front Door's group go, once they are known (below).
        $edgeGroupEnd = $lines.Count
        $lines.Add('  }')
    }

    $lines.Add("  Boundary(rg_tier, $(Get-Quoted $tierGroup), `$type=`"resource group`", `$tags=`"scope`") {")
    Add-Frame 'rg_tier' 'sub.rg_tier' 'resourceGroup' $tierGroup (Get-PortalLink $tierGroupId)
    foreach ($region in $regions.Values) {
        $roles = @($region.roles | ForEach-Object { switch ($_) { 'static' { 'static sites' } default { $_ } } })
        $type = "Azure region: $($roles -join ', ')"
        $lines.Add("    Deployment_Node($($region.alias), $(Get-Quoted $region.name), $(Get-Quoted $type), $(Get-Quoted $regionSlot), `$tags=`"region`") {")
        $regionLinks = if ($tierGroupId) { [ordered] @{ resources = Get-ResourcesAddress -SubscriptionId $subscriptionId -ResourceGroup $tierGroup -Location $region.name -TenantId $tenantId } } else { $null }
        Add-RegionFrame ([ordered] @{ alias = $region.alias; qualifiedName = "sub.rg_tier.$($region.alias)"; name = $region.name; roles = @($region.roles) }) $regionLinks
        foreach ($role in 'primary', 'standby') {
            if (-not $region.roles.Contains($role)) { continue }
            if ($role -eq 'primary') {
                $owner = [string] $sameTier[0].name
                $plan = "asp-$slug-$owner"
                $sharing = @($sameTier | ForEach-Object { [string] $_.name })
            }
            else {
                $withStandby = @($sameTier | Where-Object { [string] $_['standbyLocation'] -eq $standbyLocation })
                $plan = "asp-$slug-$([string] $withStandby[0].name)-$standbyLocation"
                $sharing = @($withStandby | ForEach-Object { [string] $_.name })
            }
            $shared = if ($sharing.Count -gt 1) { "shared by $($sharing -join ', ')" } else { '' }
            $lines.Add("      Deployment_Node(plan_$role, $(Get-Quoted $plan), `"App Service plan, $size`", $(Get-Quoted $shared), `$tags=`"plan`") {")
            Add-Frame "plan_$role" "sub.rg_tier.$($region.alias).plan_$role" 'plan' $plan (Get-PortalLink $(if ($tierGroupId) { "$tierGroupId/providers/Microsoft.Web/serverfarms/$plan" } else { '' }))
            foreach ($app in $apps) {
                $node = @($app.nodes | Where-Object { $_.role -eq $role }) | Select-Object -First 1
                if (-not $node) { continue }
                $alias = "app_$(Get-DeployableAlias $app.name)_$role"
                $slot = if ($app['healthDetailPath']) { $tileSlotWithChecks } else { $tileSlot }
                $lines.Add("        Container($alias, $(Get-Quoted $node.name), $(Get-Quoted "web app: $($app.name)"), $(Get-Quoted $slot))")
                Add-Node ([ordered] @{ alias = $alias; qualifiedName = "sub.rg_tier.$($region.alias).plan_$role.$alias"; kind = 'webapp'; deployable = [string] $app.name; name = [string] $node.name; role = $role; region = [string] $node.region; regionAlias = $region.alias; url = [string] $node.url })
            }
            $lines.Add('      }')
        }
        if ($region.roles.Contains('data')) {
            $database = "sqldb-$slug-$Environment"
            $lines.Add("      ContainerDb(sqldb, $(Get-Quoted $database), `"Azure SQL database`", $(Get-Quoted $smallTileSlot))")
            Add-Node ([ordered] @{ alias = 'sqldb'; qualifiedName = "sub.rg_tier.$($region.alias).sqldb"; kind = 'sql'; name = $database; region = $region.name; regionAlias = $region.alias; url = $null })
        }
        if ($region.roles.Contains('static')) {
            foreach ($static in $statics) {
                $alias = "swa_$(Get-DeployableAlias $static.name)"
                $site = "swa-$slug-$Environment-$($static.name)"
                $lines.Add("      Container($alias, $(Get-Quoted $site), $(Get-Quoted "Static Web App: $($static.name)"), $(Get-Quoted $siteSlot))")
                $address = if ($DashboardUrl[$Environment]) { [string] $DashboardUrl[$Environment] } else { $null }
                Add-Node ([ordered] @{ alias = $alias; qualifiedName = "sub.rg_tier.$($region.alias).$alias"; kind = 'staticsite'; deployable = [string] $static.name; name = $site; region = $region.name; regionAlias = $region.alias; url = $address }) (Get-PortalLink $(if ($tierGroupId) { "$tierGroupId/providers/Microsoft.Web/staticSites/$site" } else { '' }))
            }
        }
        $lines.Add('    }')
    }

    # Everything else the resource groups hold (see -Resource above), placed by its environment tag.
    # What the diagram draws already, by type and name, is not drawn twice: the web apps, the plans, the static sites,
    # the Front Door profile and the container apps (their environment below). The database is a child of its server,
    # and is left out with every child.
    $drawnResource = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($drawn in $nodes) {
        if ($drawn['kind'] -eq 'webapp') { $null = $drawnResource.Add("microsoft.web/sites/$([string] $drawn['name'])") }
        if ($drawn['kind'] -eq 'staticsite') { $null = $drawnResource.Add("microsoft.web/staticsites/$([string] $drawn['name'])") }
    }
    foreach ($drawn in @($frames | Where-Object { $_['kind'] -eq 'plan' })) { $null = $drawnResource.Add("microsoft.web/serverfarms/$([string] $drawn['name'])") }
    if ($edgeGroupEnd -ge 0) { $null = $drawnResource.Add("microsoft.cdn/profiles/$([string] $frontDoor.profile)") }
    foreach ($container in $containers) { $null = $drawnResource.Add("microsoft.app/containerapps/$([string] $container.App)") }
    $typeLabel = @{
        'microsoft.keyvault/vaults'                              = 'Key Vault'
        'microsoft.managedidentity/userassignedidentities'       = 'Managed identity'
        'microsoft.insights/components'                          = 'Application Insights'
        'microsoft.operationalinsights/workspaces'               = 'Log Analytics workspace'
        'microsoft.storage/storageaccounts'                      = 'Storage account'
        'microsoft.containerregistry/registries'                 = 'Container registry'
        'microsoft.sql/servers'                                  = 'Azure SQL server'
        'microsoft.app/managedenvironments'                      = 'Container Apps environment'
        'microsoft.app/containerapps'                            = 'Container app'
        'microsoft.web/sites'                                    = 'Web app'
        'microsoft.web/serverfarms'                              = 'App Service plan'
        'microsoft.web/staticsites'                              = 'Static Web App'
        'microsoft.cdn/profiles'                                 = 'Front Door profile'
        'microsoft.alertsmanagement/smartdetectoralertrules'     = 'Smart Detector alert rule'
        'microsoft.cognitiveservices/accounts'                   = 'Azure AI services account'
        'microsoft.servicebus/namespaces'                        = 'Service Bus namespace'
        'microsoft.cache/redis'                                  = 'Azure Cache for Redis'
    }
    $labelOf = {
        param([string] $Key)
        if ($typeLabel.ContainsKey($Key)) { return [string] $typeLabel[$Key] }
        $segments = $Key -split '/'
        return "$(($segments[0] -replace '^microsoft\.', ''))/$($segments[1])"
    }
    # Every group's list, once per resource. A resource tagged with another environment of the system is drawn in that
    # environment's diagram; one with no environment tag, or a tag that names no environment, in every diagram, in the
    # frame of the system that is in no environment ("unplaced").
    $environmentNames = @($System.environments | ForEach-Object { [string] $_.name })
    $groupOfKey = if ($System.azure['resourceGroups'] -is [System.Collections.IDictionary]) { $System.azure.resourceGroups } else { @{} }
    $seenResource = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $listedResources = [Collections.Generic.List[object]]::new()
    foreach ($groupKey in @($Resource.Keys | ForEach-Object { [string] $_ } | Sort-Object)) {
        $value = $Resource[$groupKey]
        if ($value -isnot [System.Collections.IEnumerable] -or $value -is [string]) { continue }
        foreach ($item in @($value)) {
            if ($item -isnot [System.Collections.IDictionary]) { continue }
            $type = [string] $item['type']
            $resourceName = [string] $item['name']
            if (-not $type -or -not $resourceName) { continue }
            # A child of another resource (a database of a server, a secret of a vault) is part of its parent.
            if (@($type -split '/').Count -ne 2) { continue }
            if ($type -ieq 'Microsoft.Authorization/roleAssignments') { continue }
            $group = if ($item['group']) { [string] $item['group'] } else { [string] $groupOfKey[$groupKey] }
            if (-not $seenResource.Add("$group/$type/$resourceName")) { continue }
            # The tag is a set: a shared resource (the cluster, a tier's identity, the registry) names every environment
            # it serves, "tdd,uat", and is drawn in each of them.
            $tag = [string] $item['environment']
            $served = @($tag -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $environmentNames -icontains $_ })
            $placement = if (-not $tag.Trim()) { 'none' } elseif ($served -icontains $Environment) { 'here' } elseif ($served.Count -gt 0) { 'elsewhere' } else { 'unknown' }
            if ($placement -eq 'elsewhere') { continue }
            $words = switch ($placement) { 'none' { 'no environment tag' } 'unknown' { "tagged $((@($tag -split ',' | ForEach-Object { Get-Reported $_.Trim() 40 } | Where-Object { $_ }) -join ', ')): no such environment" } default { '' } }
            $listedResources.Add([pscustomobject] @{
                    Key = $type.ToLowerInvariant(); Name = $resourceName; Group = $group; Tag = $tag; Placement = $placement; Words = $words
                    Location = [string] $item['location']; Id = [string] $item['id']; Address = [string] $item['address']; ManagedEnvironment = [string] $item['managedEnvironment']
                    Box = if ($placement -eq 'here') { $type.ToLowerInvariant() } else { "$($type.ToLowerInvariant())|$($group.ToLowerInvariant())|$($tag.ToLowerInvariant())" }
                })
        }
    }

    # The ids of the drawn static sites and of the database, by which the page finds what Resource Health said of them.
    foreach ($drawn in @($nodes | Where-Object { $_['kind'] -in 'staticsite', 'sql' })) {
        $drawnIds = @(@(if ($drawn['kind'] -eq 'staticsite') {
                    $listedResources | Where-Object { $_.Key -eq 'microsoft.web/staticsites' -and $_.Name -ieq [string] $drawn['name'] -and $_.Id } | ForEach-Object { $_.Id }
                }
                else {
                    foreach ($listedGroup in @($Resource.Values | Where-Object { $_ -is [System.Collections.IEnumerable] -and $_ -isnot [string] })) {
                        @($listedGroup) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string] $_['type'] -ieq 'Microsoft.Sql/servers/databases' -and ([string] $_['name']) -like "*/$([string] $drawn['name'])" -and $_['id'] } | ForEach-Object { [string] $_['id'] }
                    }
                }) | Select-Object -Unique)
        if ($drawnIds.Count -gt 0) { $drawn.ids = @($drawnIds) }
    }

    # The container apps: those the system declares are drawn from the stacks (above), and every other one the groups
    # hold from the list alone, with its address where it has a public one; the page probes each address it has. One
    # of this environment joins its Container Apps environment; one in no environment is drawn in the system's frame. A
    # box of a Container Apps environment is the environment's resource: it is not drawn again.
    foreach ($container in $containers) {
        $record = @($listedResources | Where-Object { $_.Key -eq 'microsoft.app/containerapps' -and $_.Name -ieq $container.App -and $_.ManagedEnvironment }) | Select-Object -First 1
        if ($record) { $container.EnvironmentId = $record.ManagedEnvironment }
        $listedApp = @($listedResources | Where-Object { $_.Key -eq 'microsoft.app/containerapps' -and $_.Name -ieq $container.App -and $_.Id }) | Select-Object -First 1
        if ($listedApp) { $container.Id = $listedApp.Id }
    }
    # A declared app whose stack gave no address, found in the list by the name the infrastructure gives it.
    $declaredHere = @($System.deployables | Where-Object { (-not $_['hosting'] -or $_['hosting'] -eq 'containerapp') -and (-not $_['environments'] -or @($_['environments']) -contains $Environment) } | ForEach-Object { [string] $_.name })
    $unplacedApps = [Collections.Generic.List[object]]::new()
    $undeclared = 0
    # A container app that is the node of an application with its own runtime is that node, not a box of its own
    # (jpcom, 2026-10-12: the app its Front Door routes to stood a second time in "In no environment"). The
    # application reported the node's address, and the list gives the container app's: where the two are the same host,
    # the node's box takes the resource (its name, its id, its page in the portal), in the diagram of the environment
    # that recorded the node, and no other diagram draws the resource.
    $ownHost = @{}
    foreach ($listedEnvironment in @($Topology['environments'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        foreach ($listedOwn in @($listedEnvironment['deployables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $hostingOf[[string] $_['name']] -eq 'own' })) {
            foreach ($listedNode in @($listedOwn['nodes'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['url'] })) {
                $reportedHost = Get-ReportedHost ([string] $listedNode['url'])
                if ($reportedHost -and -not $ownHost.ContainsKey($reportedHost)) { $ownHost[$reportedHost] = [string] $listedEnvironment['name'] }
            }
        }
    }
    $nodeResource = @{}
    foreach ($record in @($listedResources | Where-Object { $_.Key -eq 'microsoft.app/containerapps' -and -not $drawnResource.Contains("$($_.Key)/$($_.Name)") } | Sort-Object Name)) {
        $address = if ($record.Address -match '^https://[^/\s]+$') { $record.Address.TrimEnd('/') } else { '' }
        $addressHost = if ($address) { Get-ReportedHost $address } else { '' }
        if ($addressHost -and $ownHost.ContainsKey($addressHost)) {
            $null = $drawnResource.Add("$($record.Key)/$($record.Name)")
            if ($ownHost[$addressHost] -eq $Environment) { $nodeResource[$addressHost] = $record }
            continue
        }
        $undeclared++
        $null = $drawnResource.Add("$($record.Key)/$($record.Name)")
        $domain = if ($record.ManagedEnvironment) { ($record.ManagedEnvironment -split '/')[-1] } else { 'Container Apps environment not known' }
        $region = $record.Location
        if ($address) {
            $parts = ([uri] $address).Host -split '\.', 2
            if ($parts.Count -gt 1 -and $parts[1] -match '^(?<environment>[^.]+)\.(?<region>[^.]+)\.azurecontainerapps\.io$') { $domain = $Matches.environment; $region = $Matches.region }
        }
        $declaredAs = if ($record.Placement -eq 'here') { @($declaredHere | Where-Object { $record.Name -match "^ca-$([regex]::Escape($slug))-$([regex]::Escape($Environment))-$([regex]::Escape($_))(-[a-z0-9]{4})?$" }) | Select-Object -First 1 } else { $null }
        $words = if ($record.Placement -ne 'here') { "container app, $(Get-Reported $record.Group 90): $($record.Words)" } elseif ($declaredAs) { "container app: $declaredAs, address not read" } else { 'container app, not in system.json' }
        $box = [pscustomobject] @{
            Deployable = ''; Address = $address; App = $record.Name; Environment = $domain; Region = $region; Database = $false; Alias = "cax_$undeclared"
            Words = $words; Links = $(if ($address) { [ordered] @{ site = $address } } else { Get-PortalLink $record.Id }); EnvironmentId = $record.ManagedEnvironment; Group = ''; Tag = $record.Tag
            Id = $record.Id; HealthPath = ''
        }
        if ($record.Placement -eq 'here') { $containers = @($containers) + $box } else { $unplacedApps.Add($box) }
    }
    # One box per Container Apps environment: by its id where the list gives it (also to an app of the same address
    # whose list does not), by the generated part of the address otherwise. Where a declared app's environment is not
    # known (a list from before it said), every Container Apps environment of this environment and with no tag is taken
    # for its box, as before.
    $idOfDomain = @{}
    foreach ($container in $containers) { if ($container.EnvironmentId -and $container.Address) { $idOfDomain[$container.Environment] = $container.EnvironmentId } }
    $environmentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $environmentUnknown = $false
    foreach ($container in $containers) {
        $known = if ($container.EnvironmentId) { $container.EnvironmentId } elseif ($container.Address -and $idOfDomain[$container.Environment]) { $idOfDomain[$container.Environment] } else { '' }
        $container.Group = if ($known) { $known } else { $container.Environment }
        if ($known) { $null = $environmentIds.Add($known) } elseif ($container.Deployable) { $environmentUnknown = $true }
    }

    # What is left: this environment's, by group, and the system's in no environment. A Container Apps environment
    # whose apps are drawn is their box; where the list does not say which environment an app is in (a list from before
    # it did), every one of this environment and with no tag is taken for theirs.
    $placed = [ordered] @{}
    $unplaced = [Collections.Generic.List[object]]::new()
    foreach ($record in $listedResources) {
        if ($drawnResource.Contains("$($record.Key)/$($record.Name)")) { continue }
        if ($record.Key -eq 'microsoft.app/managedenvironments') {
            if ($environmentIds.Contains($record.Id)) { continue }
            if ($environmentUnknown -and $record.Placement -in 'here', 'none') { continue }
        }
        if ($record.Placement -ne 'here') { $unplaced.Add($record); continue }
        if (-not $placed.Contains($record.Group)) { $placed[$record.Group] = [Collections.Generic.List[object]]::new() }
        $placed[$record.Group].Add($record)
    }
    $boxNumber = @{ n = 0 }
    function Add-ResourceBox {
        # One box per type of $Member (in no environment, per type, group and tag), as PlantUML lines into $Into at the
        # indent, each a node of kind "resource" in the frame $Parent, numbered on from the boxes before.
        param([System.Collections.Generic.List[string]] $Into, [string] $Indent, [string] $Parent, [object[]] $Member)
        foreach ($set in @($Member | Group-Object Box | Sort-Object { & $labelOf $_.Group[0].Key }, Name)) {
            $boxNumber.n++
            $alias = "res_$($boxNumber.n)"
            $members = @($set.Group | Sort-Object Name)
            $first = $members[0]
            $label = & $labelOf $first.Key
            $names = @($members | ForEach-Object { Get-Reported $_.Name 60 })
            $where = if ($first.Placement -eq 'here') { '' } else { "\n$(Get-Reported $first.Group 90): $($first.Words)" }
            if ($members.Count -eq 1) {
                $title = $names[0]
                $detail = (Get-Reported $first.Location 40) + $where
                $link = Get-PortalLink $first.Id
            }
            else {
                $title = "$label ($($members.Count))"
                $shown = @($names | Select-Object -First 8)
                if ($names.Count -gt $shown.Count) { $shown += "and $($names.Count - $shown.Count) more" }
                $detail = ($shown -join '\n') + $where
                $link = Get-PortalLink $(if ($subscription -and $first.Group) { "$subscription/resourceGroups/$($first.Group)" } else { '' })
            }
            $description = if ($detail) { "$detail\n$resourceSlot" } else { $resourceSlot }
            $Into.Add("$Indent      Container($alias, $(Get-Quoted $title), $(Get-Quoted $label), $(Get-Quoted $description))")
            $node = [ordered] @{ alias = $alias; qualifiedName = "$Parent.$alias"; kind = 'resource'; name = $title; type = $label; count = $members.Count; names = @($names); group = $first.Group }
            if ($first.Placement -ne 'here') { $node.environmentTag = $(if ($first.Tag) { $first.Tag } else { $null }) }
            $memberIds = @($members | ForEach-Object { [string] $_.Id } | Where-Object { $_ })
            if ($memberIds.Count -gt 0) { $node.ids = $memberIds }
            Add-Node $node $link
        }
    }
    function Add-SupportingBox {
        # The box that holds this environment's resources of one group, inside that group's boundary.
        param([System.Collections.Generic.List[string]] $Into, [string] $Indent, [string] $Alias, [string] $Parent, [string] $Group, [object[]] $Member)
        $holder = "$($Member.Count) resource(s) of $Environment"
        $Into.Add("$Indent    Deployment_Node($Alias, `"Supporting resources`", $(Get-Quoted $holder), `"`", `$tags=`"region`") {")
        Add-Frame $Alias "$Parent.$Alias" 'supportingResources' 'Supporting resources' (Get-PortalLink $(if ($subscription -and $Group) { "$subscription/resourceGroups/$Group" } else { '' }))
        Add-ResourceBox $Into $Indent "$Parent.$Alias" $Member
        $Into.Add("$Indent    }")
    }
    $tierMembers = @(foreach ($groupName in @($placed.Keys)) { if ($groupName -ieq $tierGroup) { $placed[$groupName] } })
    if ($tierMembers.Count -gt 0) { Add-SupportingBox $lines '' 'supporting' 'sub.rg_tier' $tierGroup $tierMembers }
    $lines.Add('  }')
    $groupNumber = 0
    foreach ($groupName in @($placed.Keys | Where-Object { $_ -ine $tierGroup })) {
        if ($edgeGroupEnd -ge 0 -and $groupName -ieq [string] $frontDoor.resourceGroup) {
            $edgeGroupLines = [Collections.Generic.List[string]]::new()
            Add-SupportingBox $edgeGroupLines '' 'supporting_edge' 'sub.rg_edge' $groupName @($placed[$groupName])
            $lines.InsertRange($edgeGroupEnd, $edgeGroupLines)
            continue
        }
        $groupNumber++
        $groupAlias = "rg_$groupNumber"
        $lines.Add("  Boundary($groupAlias, $(Get-Quoted $groupName), `$type=`"resource group`", `$tags=`"scope`") {")
        Add-Frame $groupAlias "sub.$groupAlias" 'resourceGroup' $groupName (Get-PortalLink $(if ($subscription) { "$subscription/resourceGroups/$groupName" } else { '' }))
        Add-SupportingBox $lines '' "supporting_$groupNumber" "sub.$groupAlias" $groupName @($placed[$groupName])
        $lines.Add('  }')
    }

    $containerBoxes = [ordered] @{}
    $caeNumber = 0
    foreach ($group in @($containers | Group-Object Group)) {
        $caeNumber++
        $cae = "cae_$caeNumber"
        $named = @($group.Group | Where-Object { $_.Address }) | Select-Object -First 1
        if (-not $named) { $named = $group.Group[0] }
        $region = [string] $named.Region
        $type = if ($region) { "Container Apps environment, $region" } else { 'Container Apps environment' }
        $caeName = Get-Reported $named.Environment 60
        $lines.Add("  Deployment_Node($cae, $(Get-Quoted $caeName), $(Get-Quoted $type), `"`", `$tags=`"region`") {")
        Add-Frame $cae "sub.$cae" 'containerAppsEnvironment' $caeName $null
        foreach ($container in $group.Group) {
            $appName = Get-Reported $container.App 60
            $lines.Add("    Container($($container.Alias), $(Get-Quoted $appName), $(Get-Quoted $container.Words), $(Get-Quoted $containerSlot))")
            $node = [ordered] @{ alias = $container.Alias; qualifiedName = "sub.$cae.$($container.Alias)"; kind = 'containerapp'; name = $appName; url = $(if ($container.Address) { $container.Address } else { $null }) }
            if ($container.Deployable) { $node.deployable = $container.Deployable; $containerBoxes[$container.Deployable] = $container.Alias }
            if ($container.HealthPath) { $node.healthPath = $container.HealthPath }
            if ($container.Id) { $node.ids = @($container.Id) }
            Add-Node $node $(if ($container.Links) { $container.Links } else { [ordered] @{ site = $container.Address } })
        }
        $lines.Add('  }')
    }

    # The system's resources in no environment, in every environment's diagram, each saying its group and its tag.
    if ($unplaced.Count -gt 0 -or $unplacedApps.Count -gt 0) {
        $holder = "$($unplaced.Count + $unplacedApps.Count) resource(s) of the system that no environment tag places"
        $lines.Add("  Deployment_Node(unplaced, `"In no environment`", $(Get-Quoted $holder), `"`", `$tags=`"region`") {")
        Add-Frame 'unplaced' 'sub.unplaced' 'systemResources' 'In no environment' (Get-PortalLink $subscription)
        foreach ($container in $unplacedApps) {
            $appName = Get-Reported $container.App 60
            $lines.Add("    Container($($container.Alias), $(Get-Quoted $appName), $(Get-Quoted $container.Words), $(Get-Quoted $containerSlot))")
            $node = [ordered] @{ alias = $container.Alias; qualifiedName = "sub.unplaced.$($container.Alias)"; kind = 'containerapp'; name = $appName; url = $(if ($container.Address) { $container.Address } else { $null }); environmentTag = $(if ($container.Tag) { $container.Tag } else { $null }) }
            if ($container.Id) { $node.ids = @($container.Id) }
            Add-Node $node $container.Links
        }
        Add-ResourceBox $lines '  ' 'sub.unplaced' @($unplaced)
        $lines.Add('  }')
    }
    $lines.Add('}')

    # The applications that bring their own runtime, each in a boundary of its own outside the subscription: its public
    # address when it reported one, and its nodes by the region they name. $webApps: the aliases of every deployable's
    # drawn nodes, for the relationships below.
    $webApps = [ordered] @{}
    foreach ($app in $apps) {
        $key = Get-DeployableAlias $app.name
        $webApps[[string] $app.name] = @($app.nodes | ForEach-Object { [string] $_.role } | Where-Object { $_ -in 'primary', 'standby' } | ForEach-Object { "app_${key}_$_" })
    }
    $ownNodes = [ordered] @{}
    foreach ($own in $owns) {
        $key = Get-DeployableAlias $own.name
        $boundary = "own_$key"
        $slot = if ($own['healthDetailPath']) { $tileSlotWithChecks } else { $tileSlot }
        $ownName = Get-Reported ([string] $own.name)
        $lines.Add("Boundary($boundary, $(Get-Quoted $ownName), `$type=`"runtime of its own`", `$tags=`"scope`") {")
        # The system knows no resource of such an application: its boundary leads to the project that deploys it,
        # and its public address and its nodes to themselves.
        Add-Frame $boundary $boundary 'runtime' $ownName $(if ($own['projectUrl']) { [ordered] @{ project = [string] $own.projectUrl } } else { $null })
        if ($own['frontDoor']) {
            $address = [string] $own.frontDoor
            $lines.Add("  Container(fd_$key, $(Get-Quoted (Get-ShortHost $address 40)), $(Get-Quoted "public address of $ownName"), $(Get-Quoted $endpointSlot))")
            Add-Node ([ordered] @{ alias = "fd_$key"; qualifiedName = "$boundary.fd_$key"; kind = 'frontdoor'; deployable = [string] $own.name; name = Get-ReportedHost $address; url = $(if (Get-ReportedLink $address) { $address } else { $null }) }) $(if (Get-ReportedLink $address) { [ordered] @{ site = $address } } else { $null })
        }
        # The nodes by region, in the order of the report; a node without a role is the primary when it is the first
        # and a standby otherwise, as the dashboard reads the topology.
        $byRegion = [ordered] @{}
        $position = 0
        $drawn = [Collections.Generic.List[object]]::new()
        foreach ($node in @($own.nodes)) {
            $position++
            $regionName = if ($node['region']) { [string] $node.region } else { '' }
            if (-not $byRegion.Contains($regionName)) { $byRegion[$regionName] = [Collections.Generic.List[object]]::new() }
            $entry = [ordered] @{
                alias = "app_${key}_$position"
                name  = if ($node['name']) { Get-Reported ([string] $node.name) } else { Get-ReportedHost ([string] $node.url) }
                role  = if ([string] $node['role'] -cin 'primary', 'standby') { [string] $node.role } elseif ($position -eq 1) { 'primary' } else { 'standby' }
                url   = [string] $node.url
            }
            $byRegion[$regionName].Add($entry)
            $drawn.Add($entry)
        }
        $number = 0
        foreach ($regionName in $byRegion.Keys) {
            $number++
            $regionAlias = "region_own_${key}_$number"
            $shown = if ($regionName) { Get-Reported $regionName 40 } else { 'region not reported' }
            $lines.Add("  Deployment_Node($regionAlias, $(Get-Quoted $shown), $(Get-Quoted "region of $ownName"), $(Get-Quoted $regionSlot), `$tags=`"region`") {")
            Add-RegionFrame ([ordered] @{ alias = $regionAlias; qualifiedName = "$boundary.$regionAlias"; name = $shown; roles = @($byRegion[$regionName] | ForEach-Object { $_.role } | Select-Object -Unique) })
            foreach ($entry in $byRegion[$regionName]) {
                # The container app the node is, where the system's groups hold one at the node's address.
                $resourceOfNode = $nodeResource[(Get-ReportedHost $entry.url)]
                $lines.Add("    Container($($entry.alias), $(Get-Quoted $entry.name), $(Get-Quoted $(if ($resourceOfNode) { "node of ${ownName}: container app $(Get-Reported $resourceOfNode.Name 60)" } else { "node of $ownName" })), $(Get-Quoted $slot))")
                Add-Node ([ordered] @{ alias = $entry.alias; qualifiedName = "$boundary.$regionAlias.$($entry.alias)"; kind = 'webapp'; deployable = [string] $own.name; name = $entry.name; role = $entry.role; region = $(if ($regionName) { $shown } else { $null }); regionAlias = $regionAlias; url = $(if (Get-ReportedLink $entry.url) { $entry.url } else { $null }) }) $(if (Get-ReportedLink $entry.url) { [ordered] @{ site = [string] $entry.url } } else { $null })
                if ($resourceOfNode) {
                    $merged = $nodes[$nodes.Count - 1]
                    $merged.names = @(Get-Reported $resourceOfNode.Name 60)
                    if ($resourceOfNode.Id) {
                        $merged.ids = @($resourceOfNode.Id)
                        if (-not $merged.Contains('links')) { $merged.links = [ordered] @{} }
                        $merged.links.portal = Get-PortalAddress -ResourceId $resourceOfNode.Id -TenantId $tenantId
                    }
                }
            }
            $lines.Add('  }')
        }
        $lines.Add('}')
        $ownNodes[[string] $own.name] = @($drawn)
        $webApps[[string] $own.name] = @($drawn | ForEach-Object { $_.alias })
    }

    # What the deployables depend on and the system does not own: outside the subscription, each with a small tile.
    foreach ($name in $dependenciesOf.Keys) {
        foreach ($dependency in $dependenciesOf[$name]) {
            $lines.Add("System_Ext($($dependency.alias), $(Get-Quoted $dependency.name), $(Get-Quoted $smallTileSlot), `$type=$(Get-Quoted "$($dependency.kind) dependency of $name"))")
            Add-Node ([ordered] @{ alias = $dependency.alias; qualifiedName = $dependency.alias; kind = 'dependency'; deployable = $name; name = $dependency.name; healthCheck = $dependency.healthCheck; dependencyKind = $dependency.kind; url = $null })
        }
    }

    # The relationships, after the boundaries: the browser to the public addresses, Front Door to its origins, every
    # web app to the database and to what its deployable depends on.
    foreach ($app in $apps) {
        $key = Get-DeployableAlias $app.name
        $roles = @($app.nodes | ForEach-Object { [string] $_.role } | Where-Object { $_ -in 'primary', 'standby' })
        if ($hasFrontDoor) {
            # The address itself, shortened and clickable, where the endpoint has one; the words until it does.
            if ($app['frontDoor']) { Add-Edge 'browser' "fd_$key" 'public' (Get-ShortHost ([string] $app.frontDoor)) 'HTTPS' $true 0 ([string] $app.frontDoor) }
            else { Add-Edge 'browser' "fd_$key" 'public' 'HTTPS' "public address of $($app.name)" $true }
            if ($roles -contains 'primary') { Add-Edge "fd_$key" "app_${key}_primary" 'origin' 'origin, priority 1' 'HTTPS' $true 1 }
            if ($roles -contains 'standby') { Add-Edge "fd_$key" "app_${key}_standby" 'origin' 'origin, priority 2' 'HTTPS' $true 2 }
        }
        else {
            foreach ($role in $roles) {
                $own = [string] (@($app.nodes | Where-Object { $_.role -eq $role }) | Select-Object -First 1).url
                Add-Edge 'browser' "app_${key}_$role" 'public' (Get-ShortHost $own) 'HTTPS' $true 0 $own
            }
        }
    }
    # An application with its own runtime: the browser to its public address and that to every node, or the browser
    # to each node where it reported no public address.
    foreach ($own in $owns) {
        $key = Get-DeployableAlias $own.name
        if ($own['frontDoor']) {
            Add-Edge 'browser' "fd_$key" 'public' (Get-ShortHost ([string] $own.frontDoor)) 'HTTPS' $true 0 (Get-ReportedLink ([string] $own.frontDoor))
            foreach ($entry in $ownNodes[[string] $own.name]) {
                $priority = if ($entry.role -eq 'primary') { 1 } else { 2 }
                Add-Edge "fd_$key" $entry.alias 'origin' "origin, $($entry.role)" 'HTTPS' $true $priority
            }
        }
        else {
            foreach ($entry in $ownNodes[[string] $own.name]) {
                Add-Edge 'browser' $entry.alias 'public' (Get-ShortHost $entry.url) 'HTTPS' $true 0 (Get-ReportedLink $entry.url)
            }
        }
    }
    if ($hasDatabase) {
        foreach ($app in $apps) {
            foreach ($alias in $webApps[[string] $app.name]) {
                Add-Edge $alias 'sqldb' 'sql' 'reads and writes' 'TCP 1433' $true
            }
        }
    }
    foreach ($app in @($apps) + @($owns) + @($containerApps)) {
        if (-not $dependenciesOf.Contains([string] $app.name)) { continue }
        # A container app is one box; the others have a node per region.
        $callers = if ($containerBoxes.Contains([string] $app.name)) { @($containerBoxes[[string] $app.name]) } else { $webApps[[string] $app.name] }
        foreach ($alias in $callers) {
            foreach ($dependency in $dependenciesOf[[string] $app.name]) {
                # Upstream: the layout engine then puts the dependency's box under the subscription, below the
                # public addresses, and the arrows' number lines in the free column between the resource groups. A
                # plain Rel puts the box above the subscription and the first number line onto the resource group's
                # title.
                Add-Edge $alias $dependency.alias 'dependency' 'calls' 'HTTP' $true -Upstream
            }
        }
    }
    foreach ($static in $statics) {
        Add-Edge 'browser' "swa_$(Get-DeployableAlias $static.name)" 'dashboard' 'loads the dashboard' 'HTTPS' $false
    }
    # A container app: the browser to its address, and the app to the database it uses. Kind "direct" for the first:
    # the app reports no calls to the page, which draws the arrow as it is.
    # One the system does not declare has no relationship to the database: the system does not know what it uses.
    foreach ($container in $containers) {
        if ($container.Address) { Add-Edge 'browser' $container.Alias 'direct' 'public address' 'HTTPS' $false 0 $container.Address }
        if ($hasDatabase -and $container.Database) { Add-Edge $container.Alias 'sqldb' 'sql' 'reads and writes' 'TCP 1433' $true }
    }
    $lines.AddRange($edgeLines)
    $lines.Add('@enduml')
    # The browser's box leads where a browser goes first: the first public address the diagram draws an arrow to.
    # With no App Service app (a system of container apps only) it is the first container app's address.
    $firstContainer = @($containers | Where-Object { $_.Address }) | Select-Object -First 1
    if ($publicAddress.Count -eq 0 -and $firstContainer) { $publicAddress.Add([string] $firstContainer.Address) }
    if ($publicAddress.Count -gt 0) { $nodes[0].links = [ordered] @{ site = $publicAddress[0] } }

    # The application view (decision 0041): a web app's and a container app's box says where the repository of its
    # deployable publishes the logical architecture of each release (branch "architecture", workflow Architecture of
    # templates/app), and the page zooms from the box into the diagram of the version that runs. Only for a deployable
    # that names its repository, with names GitHub allows; "applicationView": false on "system" leaves it out.
    $organization = [string] $System.system['githubOrg']
    if ($System.system['applicationView'] -ne $false -and $organization -cmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') {
        $repositoryOf = @{}
        foreach ($declared in @($System.deployables | Where-Object { $_ -is [System.Collections.IDictionary] })) {
            if ([string] $declared['name'] -cmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -and [string] $declared['repository'] -cmatch '^[A-Za-z0-9._-]{1,100}$' -and [string] $declared['repository'] -notin '.', '..') {
                $repositoryOf[[string] $declared['name']] = [string] $declared['repository']
            }
        }
        foreach ($node in @($nodes | Where-Object { $_['kind'] -in 'webapp', 'containerapp' -and $_.Contains('deployable') -and $repositoryOf.ContainsKey([string] $_['deployable']) })) {
            $node.architecture = "https://raw.githubusercontent.com/$organization/$($repositoryOf[[string] $node['deployable']])/architecture/$([string] $node['deployable'])"
        }
    }

    return [ordered] @{
        puml     = ($lines -join "`n") + "`n"
        manifest = [ordered] @{
            environment = $Environment
            svg         = "$Environment.svg"
            nodes       = @($nodes)
            regions     = @($regionManifest)
            frames      = @($frames)
            edges       = @($edges)
        }
    }
}

function Test-RuntimeSvg {
    # The handles the dashboard relies on, in an SVG PlantUML rendered: one <g class="entity"> per node (with its slot
    # image; a dependency outside the subscription is such a node too), one <g class="cluster"> per region and frame and one
    # <g class="link"> per relationship, by the manifest. They are not a documented contract of PlantUML (they changed
    # in 1.2026.3 and 1.2026.4), so every render is checked. Returns what is missing, as text; nothing when all is there.
    param(
        [Parameter(Mandatory)] [string] $Svg,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Manifest
    )
    $document = [xml] $Svg
    $entities = @{}
    foreach ($group in @($document.SelectNodes("//*[local-name()='g'][@class='entity'][@data-qualified-name]"))) {
        $entities[$group.GetAttribute('data-qualified-name')] = @($group.SelectNodes("./*[local-name()='image']")).Count
    }
    $clusters = @($document.SelectNodes("//*[local-name()='g'][@class='cluster'][@data-qualified-name]") | ForEach-Object { $_.GetAttribute('data-qualified-name') })
    # A relationship is a <g class="link"> whose data-entity-1 and data-entity-2 are the ids of the two elements' groups
    # (PlantUML's own layout engine, smetana, gives the <path> no id; Graphviz names it "<from>-to-<to>" too).
    $aliasById = @{}
    foreach ($group in @($document.SelectNodes("//*[local-name()='g'][@data-qualified-name][@id]"))) {
        $aliasById[$group.GetAttribute('id')] = ($group.GetAttribute('data-qualified-name') -split '\.')[-1]
    }
    $paths = @(foreach ($link in @($document.SelectNodes("//*[local-name()='g'][@class='link']"))) {
            $from = $aliasById[$link.GetAttribute('data-entity-1')]
            $to = $aliasById[$link.GetAttribute('data-entity-2')]
            if ($from -and $to) { "$from-to-$to" }
        })
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($node in $Manifest.nodes) {
        if (-not $entities.ContainsKey($node.qualifiedName)) { $missing.Add("node $($node.qualifiedName)") }
        # A person is drawn as it is: nothing is drawn into it, so it has no slot. A resource has one for its health.
        elseif ($node.kind -ne 'person' -and $entities[$node.qualifiedName] -lt 1) { $missing.Add("slot of $($node.qualifiedName)") }
    }
    foreach ($region in $Manifest.regions) {
        if ($clusters -notcontains $region.qualifiedName) { $missing.Add("region $($region.qualifiedName)") }
    }
    # A manifest from before the frames were listed has none.
    foreach ($frame in @($Manifest['frames'])) {
        if ($frame -and $clusters -notcontains $frame.qualifiedName) { $missing.Add("frame $($frame.qualifiedName)") }
    }
    foreach ($edge in $Manifest.edges) {
        if ($paths -notcontains $edge.id) { $missing.Add("relationship $($edge.id)") }
    }
    return @($missing)
}

function ConvertTo-DatabaseDiagram {
    # The database view of one environment (decision 0040): PlantUML source (C4, a box per table with its row count
    # and its columns, an arrow per pair of tables a foreign key joins) and the manifest that tells the dashboard
    # which drawn element is which. It asks nothing: the same record gives the same diagram.
    #
    # Input: the record step "Record database schema" committed to environments/<env>/database.json (parsed, as a
    # hashtable). The names in it are what an application called its tables and columns, and the file may be older
    # than the step's rules or written by hand, so nothing of it is trusted: a name is written with letters, digits,
    # space and . _ - only (a type also with its length in brackets, "nvarchar(50)", "decimal(18,2)"), every other
    # character as "_", and cut at its length; a
    # value of the wrong type is left out. Returns $null for a record without a table.
    #
    # A table's alias is "t_<schema>_<name>" with every character outside A-Z a-z 0-9 _ as "_" (a second table that
    # comes to the same alias gets "_2"), its qualified name "db.<alias>". The row count is a line of its own,
    # "<count> rows" with thousands separators and a no-break space (U+00A0) for the space: the page finds that text and
    # replaces it with the count of the last deployment. A relationship has the id "<from>-to-<to>"; several foreign keys between the same two tables are
    # one arrow that names the columns of each.
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Record,
        [Parameter(Mandatory)] [string] $Environment,
        [string] $Source = '',
        [int] $MostTables = 120,
        [int] $MostColumns = 60
    )
    function Get-Name { param([AllowNull()] [string] $Text, [int] $Longest = 128) $plain = ("$Text" -replace '[^\p{L}\p{Nd} ._-]', '_').Trim(); if ($plain.Length -gt $Longest) { $plain.Substring(0, $Longest) } else { $plain } }
    # A type keeps ( ) and , only in the one form a type has them, "name(50)", "name(max)" or "name(18,2)": PlantUML's
    # preprocessor reads brackets and commas inside a quoted text too, and one that does not close ends the diagram.
    function Get-Type {
        param([AllowNull()] [string] $Text)
        $plain = "$Text".Trim()
        if ($plain -cnotmatch '^[A-Za-z0-9_ ]+(\((max|[0-9]+)(,[0-9]+)?\))?$') { $plain = $plain -replace '[^A-Za-z0-9 _]', '_' }
        if ($plain.Length -gt 64) { $plain.Substring(0, 64) } else { $plain }
    }
    function Get-Count { param([long] $Rows) if ($Rows -eq 1) { '1 row' } else { $Rows.ToString('N0', [cultureinfo]::InvariantCulture) + ' rows' } }

    $listed = @($Record['tables'] | Where-Object { $_ -is [System.Collections.IDictionary] -and "$($_['name'])".Trim() })
    if ($listed.Count -eq 0) { return $null }
    $truncated = $Record['truncated'] -eq $true -or $listed.Count -gt $MostTables
    $database = Get-Name ([string] $Record['database'])
    if (-not $database) { $database = 'database' }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('@startuml')
    # PlantUML's own layout engine: the worker container has no Graphviz, and without it PlantUML draws an error.
    $lines.Add('!pragma layout smetana')
    $lines.Add('!include <C4/C4_Component>')
    $lines.Add('HIDE_STEREOTYPE()')
    $lines.Add('skinparam wrapWidth 900')
    $lines.Add('skinparam maxMessageSize 300')
    $lines.Add('skinparam nodesep 40')
    $lines.Add('skinparam ranksep 60')
    $lines.Add('UpdateElementStyle("component", $bgColor="#eceff1", $fontColor="#1c2b33", $borderColor="#455a64")')
    $lines.Add("Boundary(db, `"$database`", `"Azure SQL database, $(Get-Name $Environment 64)`") {")

    $tables = [Collections.Generic.List[object]]::new()
    $aliasOf = @{}
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($table in @($listed | Select-Object -First $MostTables)) {
        $schema = Get-Name ([string] $table['schema'])
        $name = Get-Name ([string] $table['name'])
        $alias = ("t_${schema}_$name" -replace '[^A-Za-z0-9_]', '_')
        for ($again = 2; -not $used.Add($alias); $again++) { $alias = ("t_${schema}_$name" -replace '[^A-Za-z0-9_]', '_') + "_$again" }
        $aliasOf["$schema.$name"] = $alias
        $rows = 0L
        $null = [long]::TryParse("$($table['rows'])", [ref] $rows)
        if ($rows -lt 0) { $rows = 0 }
        $columns = @($table['columns'] | Where-Object { $_ -is [System.Collections.IDictionary] -and "$($_['name'])".Trim() })
        $text = [Collections.Generic.List[string]]::new()
        $text.Add((Get-Count $rows))
        foreach ($column in @($columns | Select-Object -First $MostColumns)) {
            $marks = @(@("$($column['key'])" -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ -in 'PK', 'FK' } | Select-Object -Unique); if ($column['nullable'] -eq $true) { 'null' })
            $text.Add("$(Get-Name ([string] $column['name'])) : $(Get-Type ([string] $column['type']))$(if ($marks.Count -gt 0) { " - $($marks -join ', ')" })")
        }
        $more = 0
        $null = [int]::TryParse("$($table['moreColumns'])", [ref] $more)
        $left = [Math]::Max(0, $columns.Count - $MostColumns) + [Math]::Max(0, $more)
        if ($left -gt 0) { $text.Add("and $left more column$(if ($left -ne 1) { 's' })") }
        $label = if ($schema -and $schema -ne 'dbo') { "$schema.$name" } else { $name }
        # PlantUML writes a <text> per word. A line whose words are joined by no-break spaces is one word, so one
        # <text>: the page finds the row count as one element, and the SVG is a fifth of the size.
        $lines.Add("  Component($alias, `"$label`", `$descr=`"$(@($text | ForEach-Object { $_ -replace ' ', [string] [char] 0xA0 }) -join '\n')`")")
        $tables.Add([ordered] @{ alias = $alias; qualifiedName = "db.$alias"; schema = $schema; name = $name; rows = $rows; columns = $columns.Count + [Math]::Max(0, $more) })
    }
    $lines.Add('}')

    $references = [ordered] @{}
    foreach ($reference in @($Record['references'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        $fromName = @("$($reference['from'])" -split '\.', 2 | ForEach-Object { Get-Name $_ }) -join '.'
        $toName = @("$($reference['to'])" -split '\.', 2 | ForEach-Object { Get-Name $_ }) -join '.'
        $from = $aliasOf[$fromName]
        $to = $aliasOf[$toName]
        if (-not $from -or -not $to) { continue }
        $id = "$from-to-$to"
        if (-not $references.Contains($id)) { $references[$id] = [ordered] @{ id = $id; from = $from; to = $to; name = ''; columns = [Collections.Generic.List[string]]::new() } }
        $entry = $references[$id]
        $constraint = Get-Name ([string] $reference['name'])
        if ($constraint) { $entry.name = if ($entry.name) { "$($entry.name), $constraint" } else { $constraint } }
        foreach ($column in @($reference['columns'] | Where-Object { "$_".Trim() } | Select-Object -First 16)) { $entry.columns.Add((Get-Name ([string] $column))) }
    }
    foreach ($entry in $references.Values) {
        $label = (@($entry.columns | Select-Object -First 6) -join ', ') + $(if ($entry.columns.Count -gt 6) { ', ...' })
        $lines.Add("Rel($($entry.from), $($entry.to), `"$label`")")
    }
    $lines.Add('@enduml')

    $readAt = ''
    $parsed = [datetime]::MinValue
    $generated = $Record['generated']
    if ($generated -is [datetime]) { $readAt = ([datetime] $generated).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) }
    elseif ([datetime]::TryParse("$generated", [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) {
        $readAt = $parsed.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
    }
    return [ordered] @{
        puml     = ($lines -join "`n") + "`n"
        manifest = [ordered] @{
            environment = $Environment
            database    = $database
            readAt      = $readAt
            source      = $Source
            truncated   = [bool] $truncated
            drawn       = $tables.Count
            tables      = @($tables)
            references  = @($references.Values)
        }
    }
}

function Test-DatabaseSvg {
    # The handles the dashboard relies on in a rendered database view: one <g class="entity"> per table, by its
    # qualified name, with one <text> that is exactly its row count. Returns what is missing, as text.
    param(
        [Parameter(Mandatory)] [string] $Svg,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Manifest
    )
    $document = [xml] $Svg
    $entities = @{}
    foreach ($group in @($document.SelectNodes("//*[local-name()='g'][@class='entity'][@data-qualified-name]"))) {
        # The words of a line are joined by no-break spaces (ConvertTo-DatabaseDiagram): read as spaces here.
        $entities[$group.GetAttribute('data-qualified-name')] = @($group.SelectNodes(".//*[local-name()='text']") | ForEach-Object { ("$($_.InnerText)" -replace [string] [char] 0xA0, ' ').Trim() })
    }
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($table in $Manifest.tables) {
        $count = if ([long] $table.rows -eq 1) { '1 row' } else { ([long] $table.rows).ToString('N0', [cultureinfo]::InvariantCulture) + ' rows' }
        if (-not $entities.ContainsKey($table.qualifiedName)) { $missing.Add("table $($table.qualifiedName)") }
        elseif (@($entities[$table.qualifiedName] | Where-Object { $_ -ceq $count }).Count -ne 1) { $missing.Add("row count of $($table.qualifiedName)") }
    }
    return @($missing)
}

function Write-DatabaseDiagram {
    # runtime/<env>.database.puml, .svg and .json in the site folder for every environment that has a record, and the
    # entry "database" of that environment in runtime/index.json, which Write-RuntimeDiagram wrote before. One Java
    # process of its own renders them, in PlantUML's most restrictive security profile. A record that cannot be drawn
    # does not stop the dashboard's deployment: the names in it are an application's, and a page without the database
    # view is better than no page. Returns the count, the timings and, for what was left out, why.
    param(
        [Parameter(Mandatory)] [hashtable] $Record,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Jar,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Repository
    )
    $runtime = Join-Path $Folder 'runtime'
    $indexPath = Join-Path $runtime 'index.json'
    $result = [ordered] @{ count = 0; seconds = 0.0; kilobytes = 0.0; problems = [Collections.Generic.List[string]]::new() }
    $diagrams = [ordered] @{}
    foreach ($name in @($Record.Keys | Sort-Object)) {
        if ($Record[$name] -isnot [System.Collections.IDictionary]) { continue }
        try {
            $diagram = ConvertTo-DatabaseDiagram -Record $Record[$name] -Environment $name -Source "https://raw.githubusercontent.com/$Repository/main/environments/$name/database.json"
            if (-not $diagram) { continue }
            $diagram.manifest.plantuml = $Version
            $diagrams[$name] = $diagram
            Set-Content -LiteralPath (Join-Path $runtime "$name.database.puml") -Value $diagram.puml -Encoding utf8NoBOM -NoNewline
        }
        catch { $result.problems.Add("${name}: $($_.Exception.Message)") }
    }
    if ($diagrams.Count -eq 0) { return $result }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sources = @($diagrams.Keys | ForEach-Object { Join-Path $runtime "$_.database.puml" })
    $env:PLANTUML_SECURITY_PROFILE = 'SANDBOX'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(java '-Djava.awt.headless=true' -jar $Jar -tsvg -charset UTF-8 -nometadata @sources 2>&1 | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ })
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $result.seconds = $clock.Elapsed.TotalSeconds

    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -AsHashtable
    # The time is text in the file and stays the same text.
    if ($index['generated'] -is [datetime]) { $index['generated'] = ([datetime] $index['generated']).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) }
    foreach ($name in $diagrams.Keys) {
        $svgPath = Join-Path $runtime "$name.database.svg"
        $problem = $null
        if (-not (Test-Path -LiteralPath $svgPath)) { $problem = "PlantUML wrote no $name.database.svg (exit code $code$(if ($output.Count -gt 0) { ": $($output[0])" }))" }
        else {
            $svg = Get-Content -LiteralPath $svgPath -Raw
            # PlantUML draws its error into the picture: then the tables are not in it.
            $missing = @(try { Test-DatabaseSvg -Svg $svg -Manifest $diagrams[$name].manifest } catch { "the SVG is not read ($($_.Exception.Message))" })
            if ($missing.Count -gt 0) { $problem = "the rendered view lacks $(@($missing | Select-Object -First 3) -join ', ')$(if ($missing.Count -gt 3) { " and $($missing.Count - 3) more" })" }
        }
        if ($problem) {
            $result.problems.Add("${name}: $problem")
            Remove-Item -LiteralPath $svgPath -Force -ErrorAction SilentlyContinue
            continue
        }
        ($diagrams[$name].manifest | ConvertTo-Json -Depth 8) + "`n" | Set-Content -LiteralPath (Join-Path $runtime "$name.database.json") -Encoding utf8NoBOM -NoNewline
        foreach ($entry in @($index['environments'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string] $_['name'] -eq $name })) {
            $entry['database'] = [ordered] @{ manifest = "$name.database.json"; svg = "$name.database.svg" }
        }
        $result.count++
        $result.kilobytes += (Get-Item -LiteralPath $svgPath).Length / 1KB
    }
    ($index | ConvertTo-Json -Depth 5) + "`n" | Set-Content -LiteralPath $indexPath -Encoding utf8NoBOM -NoNewline
    return $result
}

function Get-PlantUmlJar {
    # The PlantUML release jar of the pinned version, from the project's GitHub releases, into the folder; it fails when
    # its SHA-256 is not the pinned one. Returns the path and the seconds the download took.
    param(
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Folder
    )
    $path = Join-Path $Folder "plantuml-$Version.jar"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri "https://github.com/plantuml/plantuml/releases/download/v$Version/plantuml-$Version.jar" -OutFile $path -TimeoutSec 300
    $seconds = $clock.Elapsed.TotalSeconds
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        Remove-Item -LiteralPath $path -Force
        throw "plantuml-$Version.jar from GitHub has SHA-256 $actual, not the pinned $($Sha256.ToUpperInvariant()): it was not used."
    }
    return [ordered] @{ path = $path; seconds = $seconds; megabytes = (Get-Item -LiteralPath $path).Length / 1MB }
}

function Write-RuntimeDiagram {
    # runtime/ in the site folder: per environment of system.json the PlantUML source (<env>.puml), the SVG
    # (<env>.svg) and its manifest (<env>.json), and index.json, the list the dashboard starts from. One Java process
    # renders every diagram (PlantUML's own layout engine, smetana: no Graphviz), in PlantUML's most restrictive
    # security profile: the source includes nothing but the C4 library inside the jar. Every SVG is checked for the
    # handles of its manifest (Test-RuntimeSvg). Java's and PlantUML's output is returned as information; a render
    # that fails or lacks a handle throws, with that output in the message. Returns the log lines and the timings.
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Topology,
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string] $Jar,
        [Parameter(Mandatory)] [string] $Version,
        [hashtable] $DashboardUrl = @{},
        [hashtable] $ContainerApp = @{},
        [hashtable] $Resource = @{}
    )
    # The package carries the sample's runtime/ (and so may an older release): none of it may outlive this deployment.
    $runtime = Join-Path $Folder 'runtime'
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    New-Item -ItemType Directory -Path $runtime | Out-Null
    $diagrams = [ordered] @{}
    foreach ($environment in @($System.environments)) {
        $name = [string] $environment.name
        $diagram = ConvertTo-RuntimeDiagram -System $System -Topology $Topology -Environment $name -DashboardUrl $DashboardUrl -ContainerApp $ContainerApp -Resource $Resource
        $diagram.manifest.generated = $Topology.generated
        $diagram.manifest.plantuml = $Version
        $diagrams[$name] = $diagram
        Set-Content -LiteralPath (Join-Path $runtime "$name.puml") -Value $diagram.puml -Encoding utf8NoBOM -NoNewline
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sources = @($diagrams.Keys | ForEach-Object { Join-Path $runtime "$_.puml" })
    $env:PLANTUML_SECURITY_PROFILE = 'SANDBOX'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(java '-Djava.awt.headless=true' -jar $Jar -tsvg -charset UTF-8 -nometadata -failfast2 @sources 2>&1 | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ })
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $seconds = $clock.Elapsed.TotalSeconds
    $log = @($output | ForEach-Object { "  java: $_" })
    if ($code -ne 0) {
        throw "PlantUML $Version ended with exit code $code while rendering $($sources.Count) runtime diagram(s).$([Environment]::NewLine)$($log -join [Environment]::NewLine)"
    }

    $problems = [Collections.Generic.List[string]]::new()
    foreach ($name in $diagrams.Keys) {
        $svgPath = Join-Path $runtime "$name.svg"
        if (-not (Test-Path -LiteralPath $svgPath)) {
            $problems.Add("${name}: no $name.svg")
            continue
        }
        $missing = @(Test-RuntimeSvg -Svg (Get-Content -LiteralPath $svgPath -Raw) -Manifest $diagrams[$name].manifest)
        if ($missing.Count -gt 0) { $problems.Add("${name}: $($missing -join ', ')") }
        ($diagrams[$name].manifest | ConvertTo-Json -Depth 10) + "`n" | Set-Content -LiteralPath (Join-Path $runtime "$name.json") -Encoding utf8NoBOM -NoNewline
    }
    if ($problems.Count -gt 0) {
        throw "The runtime diagrams PlantUML $Version rendered lack elements the dashboard finds by name (the SVG's data-qualified-name and path ids are not a documented contract of PlantUML; pin a version that has them): $($problems -join '; ').$([Environment]::NewLine)$($log -join [Environment]::NewLine)"
    }
    $index = [ordered] @{
        generated    = $Topology.generated
        plantuml     = $Version
        environments = @($diagrams.Keys | ForEach-Object { [ordered] @{ name = $_; manifest = "$_.json"; svg = "$_.svg" } })
    }
    ($index | ConvertTo-Json -Depth 5) + "`n" | Set-Content -LiteralPath (Join-Path $runtime 'index.json') -Encoding utf8NoBOM -NoNewline
    $kilobytes = (@($diagrams.Keys | ForEach-Object { (Get-Item -LiteralPath (Join-Path $runtime "$_.svg")).Length }) | Measure-Object -Sum).Sum / 1KB
    return [ordered] @{ log = $log; seconds = $seconds; count = $diagrams.Count; kilobytes = $kilobytes }
}

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$repository = [string] $OctopusParameters['System.Repository']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$name = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$folder = [string] $OctopusParameters['Octopus.Action.Package[site].ExtractedPath']

if (-not $folder -or -not (Test-Path -LiteralPath (Join-Path $folder 'index.html'))) {
    Fail-Step "The release has no site package for $name with index.html at its root ($folder)."
}
$folder = (Resolve-Path -LiteralPath $folder).Path

# The Static Web Apps CLI is a Node.js tool, run with npx: the worker container must bring both.
foreach ($tool in 'node', 'npx') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail-Step "The worker container has no $tool, which the Static Web Apps CLI needs: use a worker-tools image with Node.js $swaCliNodeVersion or later (octopus/main.tf, worker_tools_image)."
    }
}
$nodeVersion = ([string] (node --version)).Trim()
if ([int] ($nodeVersion -replace '^v(\d+).*$', '$1') -lt $swaCliNodeVersion) {
    Fail-Step "The worker container has Node.js $nodeVersion; the Static Web Apps CLI $swaCliVersion needs $swaCliNodeVersion or later (octopus/main.tf, worker_tools_image)."
}

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$entry = @($outputs.deployables.value | Where-Object { $_.name -eq $name -and $_['hosting'] -in 'staticwebapp', 'storagewebsite' }) | Select-Object -First 1
if (-not $entry) {
    Fail-Step "Stack stack-$slug-$environmentName has no static site named ${name}: deploy the latest $slug-system release to $environmentName first."
}
$staticSite = [string] $entry.staticSite
$url = ([string] $entry.url).TrimEnd('/')

# system.json on main, through the API (raw.githubusercontent.com caches for minutes): the current desired state of
# the whole system, not the commit of an older release.
# As the system's own GitHub App, with a token made now for this repository, or with the stored token of a system
# that has no App: Get-SystemGitHubToken of scripts/github-token.ps1, which octopus/projects.tf joins with this
# script into the step's one script body.
$headers = @{
    Authorization          = "Bearer $(Get-SystemGitHubToken -Permission @{ contents = 'read' })"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$systemText = Read-MainFile -Path 'system.json'
if ($null -eq $systemText) {
    Fail-Step "$repository has no system.json on main."
}
$system = $systemText | ConvertFrom-Json -AsHashtable
$ownDeployables = @($system.deployables | Where-Object { $_['hosting'] -eq 'own' } | ForEach-Object { [string] $_.name })
$nodeRecords = Read-NodeRecord -System $system

# The public address of an environment with capability "frontdoor" is the host name of its endpoint
# <slug>-<env>-<deployable> in the system's Front Door profile, which the deploy identities of both tiers may read.
$endpointHosts = @{}
$frontDoor = if ($system.azure.ContainsKey('frontDoor')) { $system.azure.frontDoor } else { @{} }
$withFrontDoor = @($system.environments | Where-Object { @($_['capabilities']) -contains 'frontdoor' } | ForEach-Object { [string] $_.name })
# A dormant Front Door (azure.frontDoor.dormant) has no profile to ask: the dashboard then shows the nodes only.
if ($withFrontDoor.Count -gt 0 -and $frontDoor['profile'] -and -not $frontDoor['dormant']) {
    $listed = az afd endpoint list --resource-group ([string] $frontDoor.resourceGroup) --profile-name ([string] $frontDoor.profile) `
        --query '[].{name: name, hostName: hostName}' --only-show-errors --output json | ConvertFrom-Json -AsHashtable
    foreach ($endpoint in @($listed | Where-Object { $_ })) {
        $endpointHosts[[string] $endpoint.name] = [string] $endpoint.hostName
    }
}

# The name of each environment's SQL server, for the link to its database: it ends in a generated suffix, so it is read
# (one list per tier's resource group). The deploy identity of one tier may not read the other tier's group: a read
# that fails is information, and the dashboard then shows that environment's database without a link.
$sqlServers = @{}
$tierGroups = if ($system.azure['resourceGroups']) { $system.azure.resourceGroups } else { @{} }
foreach ($tier in @($system.environments | ForEach-Object { [string] $_['tier'] } | Where-Object { $_ } | Select-Object -Unique)) {
    $group = [string] $tierGroups[$tier]
    if (-not $group) { continue }
    $PSNativeCommandUseErrorActionPreference = $false
    $listed = @(az sql server list --resource-group $group --query '[].name' --only-show-errors --output tsv 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $listCode = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    if ($listCode -ne 0) {
        $reason = if ($listed.Count -gt 0) { $listed[0] } else { "exit code $listCode" }
        Write-Host "The SQL servers of $group could not be listed ($reason): the dashboard links to no database in tier $tier."
        continue
    }
    foreach ($environment in @($system.environments | Where-Object { [string] $_['tier'] -eq $tier })) {
        $server = @($listed | Where-Object { $_ -like "sql-$slug-$([string] $environment.name)-*" }) | Select-Object -First 1
        if ($server) { $sqlServers[[string] $environment.name] = [string] $server }
    }
}

# The address of each container app of the system, in every environment it exists in: what that environment's stack
# reports for it (a container app's address is generated by the platform, so no convention names it). Two uses: the
# link of a deployable that names a page of its own for the dashboard (deployables[].dashboardLink), and the box of
# every container app in the runtime diagram. This environment's stack is read already; another tier's group may be
# closed to this tier's deploy identity, and an environment may not have the app yet: a read that gives no address is
# information, and the dashboard then shows that environment without the link and the box.
$pageAddresses = @{}
$status = $null
$statusRead = $false
function Get-PublishedStatus {
    # containers.json of branch status (workflow delivery writes it as the plan identity, which reads every group), read
    # once; $null when the branch has none yet or it could not be read, with a line saying which.
    if (-not $script:statusRead) {
        $script:statusRead = $true
        try {
            $statusText = Read-MainFile -Path 'containers.json' -Ref 'status'
            if ($statusText) { $script:status = $statusText | ConvertFrom-Json -AsHashtable }
            else { Write-Host 'Branch status of the system repository has no containers.json yet (workflow delivery writes it hourly).' }
        }
        catch { Write-Host "containers.json of branch status could not be read ($($_.Exception.Message))." }
    }
    return $script:status
}
$containerApps = @($system.deployables | Where-Object { -not $_['hosting'] -or $_['hosting'] -eq 'containerapp' })
if ($containerApps.Count -gt 0) {
    foreach ($environment in @($system.environments)) {
        $pageEnvironment = [string] $environment.name
        $wanted = @($containerApps | Where-Object { -not $_['environments'] -or @($_.environments) -contains $pageEnvironment } | ForEach-Object { [string] $_.name })
        if ($wanted.Count -eq 0) { continue }
        $reported = @()
        $reason = ''
        if ($pageEnvironment -eq $environmentName) { $reported = @($outputs.deployables.value) }
        else {
            $pageGroup = [string] $tierGroups[[string] $environment['tier']]
            $PSNativeCommandUseErrorActionPreference = $false
            $read = @(az stack group show --name "stack-$slug-$pageEnvironment" --resource-group $pageGroup --query 'outputs.deployables.value' --only-show-errors --output json 2>&1 | ForEach-Object { "$_" })
            $readCode = $LASTEXITCODE
            $PSNativeCommandUseErrorActionPreference = $true
            if ($readCode -eq 0 -and ($read -join '').Trim()) { $reported = @(($read -join "`n") | ConvertFrom-Json -AsHashtable) }
            else { $reason = if ($read.Count -gt 0) { ($read[0] -split "`n")[0] } else { "exit code $readCode" } }
        }
        # A stack this identity may not read: what the workflow delivery published of it (containers.json on branch
        # status, written as the plan identity, which reads every environment's stack; as old as its last run).
        if ($reason) {
            $published = Get-PublishedStatus
            if ($published -and $published['environments'] -is [Collections.IDictionary] -and $published.environments[$pageEnvironment] -is [Collections.IDictionary]) {
                $reported = @($published.environments[$pageEnvironment].GetEnumerator() | ForEach-Object { @{ name = [string] $_.Key; url = [string] $_.Value } })
                Write-Host "The stack of $pageEnvironment could not be read ($reason): its container apps are those of containers.json on branch status, written $($published['generated'])."
                $reason = ''
            }
        }
        $pageAddresses[$pageEnvironment] = @{}
        $without = [Collections.Generic.List[string]]::new()
        foreach ($deployableName in $wanted) {
            $found = @($reported | Where-Object { $_ -is [Collections.IDictionary] -and $_['name'] -eq $deployableName -and $_['url'] }) | Select-Object -First 1
            if ($found) { $pageAddresses[$pageEnvironment][$deployableName] = [string] $found.url } else { $without.Add($deployableName) }
        }
        if ($without.Count -gt 0 -and $reason) {
            Write-Host "The stack of $pageEnvironment could not be read ($reason): the runtime diagram and the links show no box or link for $($without -join ', ') there."
        }
        elseif ($without.Count -gt 0) {
            Write-Host "The stack of $pageEnvironment reports no address for $($without -join ', '): the diagram shows no box and the page no link for $(if ($without.Count -eq 1) { 'it' } else { 'them' }) there until the environment has $(if ($without.Count -eq 1) { 'it' } else { 'them' }) and the dashboard is deployed again."
        }
    }
}

# Everything the resource groups of the system hold, for the runtime diagram (the entire system, not only what the
# kit names): every group of azure.resourceGroups, whatever the environment tag of what it holds. The group of this
# environment's tier, and a group of no tier, are listed here, as this identity may read them; another tier's, and a
# group this identity may not list, is what workflow delivery published of it (containers.json, "resources"). A group
# that cannot be read leaves the diagram without what it holds, and the log says so.
function Add-ContainerAppFact {
    # The public address and the Container Apps environment of the container apps among the listed resources, in one
    # read (as write-containers.ps1 records them); a refused read leaves them without.
    param([object[]] $Item, [string] $Group)
    $ids = @($Item | Where-Object { [string] $_['type'] -ieq 'Microsoft.App/containerApps' -and $_['id'] } | ForEach-Object { [string] $_['id'] })
    if ($ids.Count -eq 0) { return }
    $PSNativeCommandUseErrorActionPreference = $false
    $answer = @(az resource show --ids $ids --only-show-errors --output json 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    if ($code -ne 0 -or -not ($answer -join '').Trim()) {
        Write-Host "The container apps of $Group could not be read ($(if ($answer.Count -gt 0) { ($answer[0] -split "`n")[0] } else { "exit code $code" })): the diagram draws them without their addresses."
        return
    }
    $byId = @{}
    foreach ($shown in @(($answer -join "`n") | ConvertFrom-Json -AsHashtable | Where-Object { $_ -is [Collections.IDictionary] })) {
        $properties = if ($shown['properties'] -is [Collections.IDictionary]) { $shown['properties'] } else { @{} }
        $configuration = if ($properties['configuration'] -is [Collections.IDictionary]) { $properties['configuration'] } else { @{} }
        $ingress = if ($configuration['ingress'] -is [Collections.IDictionary]) { $configuration['ingress'] } else { @{} }
        $byId[([string] $shown['id']).ToLowerInvariant()] = @{
            address            = if ($ingress['external'] -eq $true -and $ingress['fqdn']) { "https://$([string] $ingress['fqdn'])" } else { '' }
            managedEnvironment = if ($properties['managedEnvironmentId']) { [string] $properties['managedEnvironmentId'] } elseif ($properties['environmentId']) { [string] $properties['environmentId'] } else { '' }
        }
    }
    foreach ($entry in $Item) {
        $fact = $byId[([string] $entry['id']).ToLowerInvariant()]
        if (-not $fact) { continue }
        $entry['address'] = $fact.address
        $entry['managedEnvironment'] = $fact.managedEnvironment
    }
}
$tierResources = @{}
$ownTier = [string] (@($system.environments | Where-Object { [string] $_.name -eq $environmentName }) | Select-Object -First 1).tier
$tierNames = @($system.environments | ForEach-Object { [string] $_['tier'] } | Where-Object { $_ } | Select-Object -Unique)
foreach ($groupKey in @($tierGroups.Keys | ForEach-Object { [string] $_ } | Sort-Object)) {
    $group = [string] $tierGroups[$groupKey]
    if (-not $group) { continue }
    $listed = $null
    $why = ''
    if ($groupKey -eq $ownTier -or $tierNames -notcontains $groupKey) {
        $PSNativeCommandUseErrorActionPreference = $false
        $read = @(az resource list --resource-group $group --query '[].{id:id,type:type,name:name,location:location,environment:tags.environment}' --only-show-errors --output json 2>&1 | ForEach-Object { "$_" })
        $readCode = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $true
        if ($readCode -eq 0) {
            $listed = @(($read -join "`n") | ConvertFrom-Json -AsHashtable | Where-Object { $_ -is [Collections.IDictionary] })
            foreach ($item in $listed) { $item['group'] = $group }
            Add-ContainerAppFact -Item $listed -Group $group
        }
        else { $why = if ($read.Count -gt 0) { ($read[0] -split "`n")[0] } else { "exit code $readCode" } }
    }
    if ($null -eq $listed) {
        $published = Get-PublishedStatus
        if ($published -and $published['resources'] -is [Collections.IDictionary] -and $published.resources[$groupKey] -is [System.Collections.IEnumerable] -and $published.resources[$groupKey] -isnot [string]) {
            $listed = @($published.resources[$groupKey])
            Write-Host "The resources of $group$(if ($why) { " could not be listed ($why)" } else { ' are not read by this identity' }): the diagram uses those of containers.json on branch status, written $($published['generated'])."
        }
        else {
            Write-Host "The resources of $group are not known here$(if ($why) { " ($why)" } else { '' }) and containers.json of branch status has none: the diagrams show nothing of what it holds."
        }
    }
    if ($null -ne $listed) { $tierResources[$groupKey] = @($listed) }
}

$topology = ConvertTo-Topology -System $system -EndpointHost $endpointHosts -SqlServer $sqlServers -NodeRecord $nodeRecords -PageAddress $pageAddresses -Dashboard $name
# The page reads its own build facts only where the release has them: a release from before the dashboard's Build wrote
# the file would have the page ask for a file its site does not serve.
if ($topology.system.Contains('dashboard')) {
    $ownFacts = [string] $topology.system.dashboard.buildPath
    if (Test-Path -LiteralPath (Join-Path $folder $ownFacts.TrimStart('/')) -PathType Leaf) {
        Write-Host "Code metrics of $name itself: the page reads $ownFacts from its own address (system.json, buildPath of $name)."
    }
    else {
        Write-Host "system.json says $name serves its code metrics at $ownFacts, and release $version has no such file (a release from before the dashboard's Build wrote it): the page shows no Code card of its own until a newer release is deployed."
        $topology.system.Remove('dashboard')
    }
}
foreach ($environment in $topology.environments) {
    foreach ($deployable in $environment.deployables) {
        # The system's Front Door serves the App Service deployables; an application's own public address is in its record.
        if (-not $deployable['frontDoor'] -and $withFrontDoor -contains $environment.name -and $ownDeployables -notcontains $deployable.name) {
            Write-Host "No Front Door endpoint $slug-$($environment.name)-$($deployable.name) in $($frontDoor['profile']) yet: the dashboard shows $($deployable.name) in $($environment.name) without a public address until it is deployed again."
        }
    }
}
($topology | ConvertTo-Json -Depth 10) + "`n" | Set-Content -LiteralPath (Join-Path $folder 'topology.json') -Encoding utf8NoBOM -NoNewline
$counted = Measure-Topology -Topology $topology
$summary = "$($counted.Environments) environment(s), $($counted.Nodes) node(s), $($counted.Addresses) public address(es)"
Write-Host "topology.json of $($topology.generated): $summary"
if ($topology.system.repository) {
    Write-Host "Pinned versions: the dashboard reads environments/<env>/versions.json on main of $($topology.system.repository) and compares it with what the nodes report."
}
else {
    Write-Host 'system.json names no GitHub organization and repository (system.githubOrg, system.repository): the dashboard shows no pinned versions.'
}
if (-not ($system['octopus'] -and $system.octopus['url'] -and $system.octopus['spaceId'])) {
    Write-Host 'system.json names no Octopus address and space (octopus.url, octopus.spaceId): the dashboard links to no Octopus project.'
}
$linkCount = 0
foreach ($environment in $topology.environments) {
    $linkCount += $environment.links.Count
    foreach ($deployable in $environment.deployables) {
        $linkCount += $deployable.links.Count
        foreach ($node in $deployable.nodes) { if ($node.Contains('links')) { $linkCount += $node.links.Count } }
    }
}
Write-Host "Links into the Azure portal: $linkCount (web apps, Application Insights, databases, Front Door, resource groups); the portal asks the viewer to sign in.$(if ($ownDeployables.Count -gt 0) { " None for $($ownDeployables -join ', '): the system does not know the resources of an application that brings its own runtime." })"
if ($topology.system.deliveryUrl) {
    Write-Host "Delivery facts: the dashboard reads $($topology.system.deliveryUrl) (published by the system repository's workflow; shown once the file exists)."
}
if ($topology.system.costUrl) {
    Write-Host "Cost: the dashboard reads $($topology.system.costUrl) (published by the same workflow, hourly; shown once the file exists)."
}

# The runtime diagrams, next to topology.json: one C4 deployment view per environment, rendered here (the browser has
# no PlantUML) by the jar of the pinned version, on the worker's Java. The time each part takes is logged: it is paid
# by every deployment of the dashboard.
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Fail-Step "The worker container has no java, which renders the dashboard's runtime diagrams with PlantUML ${plantUmlVersion}: use a worker-tools image with a Java runtime (octopus/main.tf, worker_tools_image)."
}
$javaVersion = "$(@(java -version 2>&1)[0])".Trim()
# PlantUML measures text through Java's font manager, which needs a font and three native libraries. The worker image
# installs Java with --no-install-recommends, and on Ubuntu 24.04 openjdk-21-jre-headless only recommends them:
# libharfbuzz0b, libfreetype6, libfontconfig1 (cmdemo2's first runtime view stopped at "libharfbuzz.so.0: cannot open
# shared object file"). What is missing is installed from the container's own package source before the render; the
# step runs as root in the worker-tools container.
# @() around each if: an if statement hands on an empty list as nothing at all, whose .Count fails under strict mode.
$fonts = @(if (Get-Command fc-list -ErrorAction SilentlyContinue) { fc-list 2>$null | Where-Object { $_ } })
$libraries = @(if (Get-Command ldconfig -ErrorAction SilentlyContinue) { ldconfig -p 2>$null | Where-Object { $_ } })
$needed = [ordered] @{
    'libharfbuzz0b'     = 'libharfbuzz\.so\.0'
    'libfreetype6'      = 'libfreetype\.so\.6'
    'libfontconfig1'    = 'libfontconfig\.so\.1'
    'fontconfig'        = ''
    'fonts-dejavu-core' = ''
}
$missing = @(foreach ($package in $needed.Keys) {
        $library = $needed[$package]
        if ($library) { if (-not @($libraries | Where-Object { $_ -match $library }).Count) { $package } }
        elseif ($fonts.Count -eq 0) { $package }
    })
if ($missing.Count -gt 0) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $env:DEBIAN_FRONTEND = 'noninteractive'
    $PSNativeCommandUseErrorActionPreference = $false
    $aptOutput = @(apt-get update -qq 2>&1) + @(apt-get install -y -qq --no-install-recommends @missing 2>&1)
    $aptCode = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $aptOutput | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host "  apt: $_" }
    if ($aptCode -ne 0) {
        Fail-Step "Java needs $($missing -join ', ') to render the runtime diagrams with PlantUML, and installing them failed (exit code $aptCode); its output is above."
    }
    Write-Host ('Installed for PlantUML in {0:0.0} s: {1} (the worker container lacked them).' -f $clock.Elapsed.TotalSeconds, ($missing -join ', '))
}
$tools = Join-Path ([IO.Path]::GetTempPath()) "plantuml-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tools | Out-Null
$runtimeProblem = $null
try {
    $jar = Get-PlantUmlJar -Version $plantUmlVersion -Sha256 $plantUmlSha256 -Folder $tools
    Write-Host ('PlantUML {0} downloaded from GitHub in {1:0.0} s ({2:0.0} MB, SHA-256 as pinned); {3}' -f $plantUmlVersion, $jar.seconds, $jar.megabytes, $javaVersion)
    $rendered = Write-RuntimeDiagram -System $system -Topology $topology -Folder $folder -Jar $jar.path -Version $plantUmlVersion -DashboardUrl @{ $environmentName = $url } -ContainerApp $pageAddresses -Resource $tierResources
    $rendered.log | ForEach-Object { Write-Host $_ }
    Write-Host ('runtime/: {0} diagram(s) rendered and checked in {1:0.0} s ({2:0} KB of SVG)' -f $rendered.count, $rendered.seconds, $rendered.kilobytes)

    # The database view (decision 0040): per environment the tables step "Record database schema" last committed to
    # environments/<env>/database.json, unless the system switched the view off. An environment without a record has
    # no view, and its database box is as before. A record that cannot be read or drawn is one warning, not a failed
    # deployment: the rest of the page is made.
    if ($system.system['databaseView'] -eq $false) { Write-Host 'runtime/: no database view, system.json switches it off ("databaseView": false).' }
    else {
        $databaseRecords = @{}
        $databaseProblems = [Collections.Generic.List[string]]::new()
        foreach ($e in @($system.environments)) {
            $recordPath = "environments/$([string] $e.name)/database.json"
            try {
                $recordText = Read-MainFile -Path $recordPath
                if ($null -eq $recordText) { continue }
                $parsedRecord = if ($recordText.Trim()) { $recordText | ConvertFrom-Json -AsHashtable -NoEnumerate } else { $null }
                if ($parsedRecord -is [System.Collections.IDictionary]) { $databaseRecords[[string] $e.name] = $parsedRecord }
                else { $databaseProblems.Add("$recordPath is not a JSON object (or is larger than 1 MB)") }
            }
            catch { $databaseProblems.Add("$recordPath is not read ($((("$($_.Exception.Message)" -split '\r?\n')[0]).Trim()))") }
        }
        if ($databaseRecords.Count -eq 0 -and $databaseProblems.Count -eq 0) { Write-Host 'runtime/: no database view, no environment has a record yet (environments/<env>/database.json, written by step "Record database schema").' }
        else {
            $drawn = Write-DatabaseDiagram -Record $databaseRecords -Folder $folder -Jar $jar.path -Version $plantUmlVersion -Repository $repository
            foreach ($problem in $drawn.problems) { $databaseProblems.Add($problem) }
            Write-Host ('runtime/: {0} database view(s) rendered and checked in {1:0.0} s ({2:0} KB of SVG)' -f $drawn.count, $drawn.seconds, $drawn.kilobytes)
        }
        if ($databaseProblems.Count -gt 0) { Write-Warning "The database view is left out where it could not be made: $($databaseProblems -join '; '). The rest of the dashboard is deployed; the database box of those environments leads to the Azure portal as before." }
    }
}
catch {
    $runtimeProblem = $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $tools -Recurse -Force -ErrorAction SilentlyContinue
}
if ($runtimeProblem) {
    # The whole problem as information first: Octopus shows a long failure message (PlantUML's output in it) as nothing
    # but the exit code, as the first deployment of the runtime view on cmdemo2 showed.
    @("$runtimeProblem" -split '\r?\n') | Where-Object { $_.Trim() } | ForEach-Object { Write-Host $_ }
    Fail-Step "The dashboard's runtime diagrams could not be made: $((@("$runtimeProblem" -split '\r?\n'))[0]) (the full output is above)"
}

if ($entry['hosting'] -eq 'storagewebsite') {
    Publish-StorageWebsite -Account ([string] $entry.storageAccount) -Folder $folder -Url $url -Generated ([string] $topology.generated)
    Write-Highlight "$name $version deployed to the static website of $($entry.storageAccount) in ${environmentName}: $url ($summary)"
    return
}

# The deployment token of the site: read now, kept in this variable only, handed to the CLI through its environment
# variable (never an argument, which a process list shows), and removed from the environment when the CLI has ended.
$token = ([string] (az staticwebapp secrets list --name $staticSite --resource-group $resourceGroup --query properties.apiKey --only-show-errors --output tsv)).Trim()
if (-not $token) {
    Fail-Step "Azure returned no deployment token for $staticSite."
}

# The CLI (and npx before it) reports its progress on stderr, which Octopus would log as errors: everything it writes
# is captured and shown as information, and its exit code decides. The CLI takes its working directory as the "app
# location", which it searches for an api folder, workflow files and a configuration file: it runs in a folder of its
# own that holds nothing but the site.
Write-Host "Deploying $name $version to $staticSite with the Static Web Apps CLI $swaCliVersion (Node.js $nodeVersion)"
$env:NO_COLOR = '1'
$env:npm_config_update_notifier = 'false'
$stage = Join-Path ([IO.Path]::GetTempPath()) "site-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -LiteralPath $folder -Destination (Join-Path $stage 'site') -Recurse
Push-Location -LiteralPath $stage
try {
    $env:SWA_CLI_DEPLOYMENT_TOKEN = $token
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(npx --yes "@azure/static-web-apps-cli@$swaCliVersion" deploy ./site --env production 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $true
    Remove-Item -LiteralPath Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue
    Pop-Location
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
# Colour codes out, and the token too, should a tool ever echo it.
$lines = @($output | ForEach-Object { ($_ -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '').Replace($token, '***').TrimEnd() } | Where-Object { $_ })
$token = $null
$lines | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) {
    Fail-Step "The Static Web Apps CLI ended with exit code $code while deploying $name $version to ${staticSite}; its output is above."
}

# The proof that this release is what the site serves: the topology written above, by its time stamp. A deployment
# takes the platform a moment to publish everywhere.
$deadline = (Get-Date).AddMinutes(5)
$served = ''
while ($true) {
    try {
        $answer = Invoke-WebRequest -Uri "$url/topology.json" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 60 -SkipHttpErrorCheck
        $text = if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }
        # By pattern, not as JSON: ConvertFrom-Json turns the time stamp into a date, in the worker's own format.
        $served = if ([int] $answer.StatusCode -eq 200) { [regex]::Match($text, '"generated"\s*:\s*"([^"]*)"').Groups[1].Value } else { "HTTP $([int] $answer.StatusCode)" }
    }
    catch {
        $served = $_.Exception.Message
    }
    if ($served -eq $topology.generated) { break }
    if ((Get-Date) -gt $deadline) {
        Fail-Step "$url/topology.json does not serve the topology of this deployment ($($topology.generated)) after 5 minutes: it answered '$served'. The CLI's output is above."
    }
    Write-Host "$url/topology.json answered '$served', not $($topology.generated) yet; retrying"
    Start-Sleep -Seconds 10
}
Write-Highlight "$name $version deployed to $staticSite in ${environmentName}: $url ($summary)"
