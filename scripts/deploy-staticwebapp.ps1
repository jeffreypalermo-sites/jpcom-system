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
       an eighth, the marks of its detailed health check, for a deployable with healthDetailPath). The script downloads the PlantUML release jar of the pinned version from GitHub,
       verifies its SHA-256, renders every diagram in one Java process (layout engine smetana: no Graphviz; security
       profile SANDBOX) and checks that each SVG has every element the manifest names; a missing one fails the step.
       Java's output is logged as information; the download and the render are timed.
    3. The deployment, with the Static Web Apps CLI and the site's deployment token. The token is read from Azure
       when the step runs (the deploy identity may; the stack's deny settings keep everyone else from listing it),
       reaches the CLI through an environment variable, and is never stored, printed or passed as an argument.
    4. The proof: the site serves the topology this step wrote.

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
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [hashtable] $EndpointHost = @{},
        [hashtable] $SqlServer = @{},
        [hashtable] $NodeRecord = @{},
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
            [ordered] @{
                name               = $environmentName
                tier               = [string] $environment['tier']
                versionsUrl        = if ($repository) { "https://raw.githubusercontent.com/$repository/$versionsPath" } else { $null }
                versionsHistoryUrl = if ($repository) { "https://github.com/$repository/commits/$versionsPath" } else { $null }
                links              = $environmentLinks
                deployables        = $deployables
            }
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
    # The text of a file of the system repository on main, or $null when main has no such file (404).
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $file = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/contents/${Path}?ref=main" -Headers $headers
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
    param(
        [Parameter(Mandatory)] [hashtable] $System,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Topology,
        [Parameter(Mandatory)] [string] $Environment,
        [hashtable] $DashboardUrl = @{}
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
    # healthDetailPath. A Front Door endpoint's has three lines; a database's, a static site's and a dependency's one.
    # The widths are what the widest line needs and no more: the diagram of an environment with a standby is five
    # boxes and three number lines wide, and every pixel here is paid for by the page's scale.
    $tileWidth = 232
    $tileSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height 146)>"
    $tileSlotWithChecks = "<img:$(New-TransparentPng -Width $tileWidth -Height 161)>"
    $endpointSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height 98)>"
    $smallTileSlot = "<img:$(New-TransparentPng -Width $tileWidth -Height 46)>"
    $regionSlot = "<img:$(New-TransparentPng -Width 190 -Height 22)>"
    # A relationship's number line (the number, its unit and its trend in a frame) and, under it, its role in words
    # ("app queries · 55 background").
    $edgeSlot = "<img:$(New-TransparentPng -Width 144 -Height 34)>"

    # The dependencies the deployables declare (system.json deployables[].dependencies), by deployable: each is drawn
    # outside the subscription. The alias is made of both names; two that give the same alias are an error.
    $dependenciesOf = [ordered] @{}
    $dependencyAlias = @{}
    foreach ($app in @($apps) + @($owns)) {
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
    $edgeLines = [Collections.Generic.List[string]]::new()
    function Add-Node {
        param([System.Collections.Specialized.OrderedDictionary] $Node)
        $nodes.Add($Node)
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

    if ($hasFrontDoor -and $apps.Count -gt 0) {
        $profileName = [string] $frontDoor.profile
        $lines.Add("  Boundary(rg_edge, $(Get-Quoted ([string] $frontDoor.resourceGroup)), `$type=`"resource group`", `$tags=`"scope`") {")
        $lines.Add("    Deployment_Node(afd, $(Get-Quoted $profileName), `"Front Door profile, Standard: global`", `$tags=`"plan`") {")
        foreach ($app in $apps) {
            $alias = "fd_$(Get-DeployableAlias $app.name)"
            $endpoint = "$slug-$Environment-$($app.name)"
            $lines.Add("      Container($alias, $(Get-Quoted $endpoint), `"Front Door endpoint`", $(Get-Quoted $endpointSlot))")
            Add-Node ([ordered] @{ alias = $alias; qualifiedName = "sub.rg_edge.afd.$alias"; kind = 'frontdoor'; deployable = [string] $app.name; name = $endpoint; url = $app.frontDoor })
        }
        $lines.Add('    }')
        $lines.Add('  }')
    }

    $lines.Add("  Boundary(rg_tier, $(Get-Quoted $tierGroup), `$type=`"resource group`", `$tags=`"scope`") {")
    foreach ($region in $regions.Values) {
        $roles = @($region.roles | ForEach-Object { switch ($_) { 'static' { 'static sites' } default { $_ } } })
        $type = "Azure region: $($roles -join ', ')"
        $lines.Add("    Deployment_Node($($region.alias), $(Get-Quoted $region.name), $(Get-Quoted $type), $(Get-Quoted $regionSlot), `$tags=`"region`") {")
        $regionManifest.Add([ordered] @{ alias = $region.alias; qualifiedName = "sub.rg_tier.$($region.alias)"; name = $region.name; roles = @($region.roles) })
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
                $lines.Add("      Container($alias, $(Get-Quoted $site), $(Get-Quoted "Static Web App: $($static.name)"), $(Get-Quoted $smallTileSlot))")
                $address = if ($DashboardUrl[$Environment]) { [string] $DashboardUrl[$Environment] } else { $null }
                Add-Node ([ordered] @{ alias = $alias; qualifiedName = "sub.rg_tier.$($region.alias).$alias"; kind = 'staticsite'; deployable = [string] $static.name; name = $site; region = $region.name; regionAlias = $region.alias; url = $address })
            }
        }
        $lines.Add('    }')
    }
    $lines.Add('  }')
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
        if ($own['frontDoor']) {
            $address = [string] $own.frontDoor
            $lines.Add("  Container(fd_$key, $(Get-Quoted (Get-ShortHost $address 40)), $(Get-Quoted "public address of $ownName"), $(Get-Quoted $endpointSlot))")
            Add-Node ([ordered] @{ alias = "fd_$key"; qualifiedName = "$boundary.fd_$key"; kind = 'frontdoor'; deployable = [string] $own.name; name = Get-ReportedHost $address; url = $(if (Get-ReportedLink $address) { $address } else { $null }) })
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
            $regionManifest.Add([ordered] @{ alias = $regionAlias; qualifiedName = "$boundary.$regionAlias"; name = $shown; roles = @($byRegion[$regionName] | ForEach-Object { $_.role } | Select-Object -Unique) })
            foreach ($entry in $byRegion[$regionName]) {
                $lines.Add("    Container($($entry.alias), $(Get-Quoted $entry.name), $(Get-Quoted "node of $ownName"), $(Get-Quoted $slot))")
                Add-Node ([ordered] @{ alias = $entry.alias; qualifiedName = "$boundary.$regionAlias.$($entry.alias)"; kind = 'webapp'; deployable = [string] $own.name; name = $entry.name; role = $entry.role; region = $(if ($regionName) { $shown } else { $null }); regionAlias = $regionAlias; url = $(if (Get-ReportedLink $entry.url) { $entry.url } else { $null }) })
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
    foreach ($app in @($apps) + @($owns)) {
        if (-not $dependenciesOf.Contains([string] $app.name)) { continue }
        foreach ($alias in $webApps[[string] $app.name]) {
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
    $lines.AddRange($edgeLines)
    $lines.Add('@enduml')

    return [ordered] @{
        puml     = ($lines -join "`n") + "`n"
        manifest = [ordered] @{
            environment = $Environment
            svg         = "$Environment.svg"
            nodes       = @($nodes)
            regions     = @($regionManifest)
            edges       = @($edges)
        }
    }
}

function Test-RuntimeSvg {
    # The handles the dashboard relies on, in an SVG PlantUML rendered: one <g class="entity"> per node (with its slot
    # image; a dependency outside the subscription is such a node too), one <g class="cluster"> per region and one
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
        elseif ($node.kind -ne 'person' -and $entities[$node.qualifiedName] -lt 1) { $missing.Add("slot of $($node.qualifiedName)") }
    }
    foreach ($region in $Manifest.regions) {
        if ($clusters -notcontains $region.qualifiedName) { $missing.Add("region $($region.qualifiedName)") }
    }
    foreach ($edge in $Manifest.edges) {
        if ($paths -notcontains $edge.id) { $missing.Add("relationship $($edge.id)") }
    }
    return @($missing)
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
        [hashtable] $DashboardUrl = @{}
    )
    # The package carries the sample's runtime/ (and so may an older release): none of it may outlive this deployment.
    $runtime = Join-Path $Folder 'runtime'
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    New-Item -ItemType Directory -Path $runtime | Out-Null
    $diagrams = [ordered] @{}
    foreach ($environment in @($System.environments)) {
        $name = [string] $environment.name
        $diagram = ConvertTo-RuntimeDiagram -System $System -Topology $Topology -Environment $name -DashboardUrl $DashboardUrl
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
$entry = @($outputs.deployables.value | Where-Object { $_.name -eq $name -and $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
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

$topology = ConvertTo-Topology -System $system -EndpointHost $endpointHosts -SqlServer $sqlServers -NodeRecord $nodeRecords -Dashboard $name
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
    $rendered = Write-RuntimeDiagram -System $system -Topology $topology -Folder $folder -Jar $jar.path -Version $plantUmlVersion -DashboardUrl @{ $environmentName = $url }
    $rendered.log | ForEach-Object { Write-Host $_ }
    Write-Host ('runtime/: {0} diagram(s) rendered and checked in {1:0.0} s ({2:0} KB of SVG)' -f $rendered.count, $rendered.seconds, $rendered.kilobytes)
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
