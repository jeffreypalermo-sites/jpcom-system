// Desired state of ONE environment of the system. Octopus applies it as the deployment stack stack-<slug>-<env>
// (scripts/apply-environment.ps1); pull requests preview it with what-if (scripts/preview-environment.ps1).
// Everything about the system comes from ../system.json; this file only reads it. An environment's capabilities
// (system.json, environments[].capabilities) switch modules on: "baseline" is always on, "telemetry" adds Log
// Analytics and Application Insights. A new capability is a new module plus one condition here.
targetScope = 'resourceGroup'

@description('Name of the environment in system.json, for example tdd.')
param environmentName string

@description('Deployed version of each deployable, from environments/<env>/versions.json on main. Empty means none yet: a placeholder runs.')
param versions object = {}

@description('SQL administrator password; apply-environment.ps1 reads it from the vault, or generates it on the first apply. Empty in a system without a database (no deployable has one), which creates no SQL server.')
@secure()
param sqlAdminPassword string = ''

@description('Principal ID of the deploy identity of this tier; it may read and write the vault secrets.')
param deployPrincipalId string

@description('Password of the database login of each App Service deployable, by name; apply-environment.ps1 reads them from the vault, or generates them for a new deployable.')
@secure()
param loginPasswords object = {}

@description('Vault names (<deployable>-<secret>) of the operator-supplied secrets of container deployables that exist in the environment\'s vault; apply-environment.ps1 lists them. A container app references only the secrets named here.')
param presentSecrets array = []

@description('Value of each generated secret of a container deployable (deployables[].secrets[] with "generate": true), by vault name (<deployable>-<secret>); apply-environment.ps1 reads them from the vault, or generates them for a new secret.')
@secure()
param generatedSecrets object = {}

var system = loadJsonContent('../system.json')
var slug = system.system.slug
var location = system.system.location
// Azure SQL may need its own region: subscription offers restrict where new SQL servers can be created
// (RegionDoesNotAllowProvisioning). system.sqlLocation overrides location for the SQL server and database only.
// Optional keys come from defaults merged with union(): reading a key absent from system.json (.?key) is warning
// BCP053, and the build treats warnings as errors.
var sqlLocation = union({ sqlLocation: location }, system.system).sqlLocation
// Placement of the apps. A subscription allows only a few Container Apps environments per region
// (ManagedEnvironmentCount), so an environment may run its apps elsewhere:
//   - environments[].appLocation: its Container Apps environment and apps in that region;
//   - environments[].sharesAppEnvironmentWith: its apps in that environment's Container Apps environment (same tier,
//     listed earlier, which creates it), in that environment's region.
// Azure moves neither a Container Apps environment nor an app to another region or environment, so a placement that is
// not the default gets names of its own (a short suffix): a move is new resources next to the old ones, which the stack
// then removes. An explicit appLocation therefore always suffixes, also when it equals location.
//   - system.json azure.appEnvironment (the demo file's azure.appEnvironment "system"): the system owns one Container
//     Apps environment, which the seed created in a group of its own; every environment of both tiers places its apps
//     there, from its own tier group, and neither appLocation nor sharesAppEnvironmentWith applies
//     (scripts/test-system.ps1).
var rawEnvironment = first(filter(system.environments, e => e.name == environmentName))!
var environment = union({ appLocation: location, appCpu: '0.5' }, rawEnvironment)
var capabilities = union(['baseline'], environment.capabilities)
var systemAppEnvironment = union({ appEnvironment: {} }, system.azure).appEnvironment
var usesSystemAppEnvironment = !empty(systemAppEnvironment)
var sharedWith = string(union({ sharesAppEnvironmentWith: '' }, rawEnvironment).sharesAppEnvironmentWith)
var hostEnvironment = empty(sharedWith) ? rawEnvironment : first(filter(system.environments, e => e.name == sharedWith))!
var appLocation = usesSystemAppEnvironment ? string(systemAppEnvironment.location) : union({ appLocation: location }, hostEnvironment).appLocation
var placementSuffix = !usesSystemAppEnvironment && contains(hostEnvironment, 'appLocation') ? '-${take(uniqueString(appLocation), 4)}' : ''
var managedEnvironmentName = usesSystemAppEnvironment ? string(systemAppEnvironment.name) : 'cae-${slug}-${hostEnvironment.name}${placementSuffix}'
var ownsManagedEnvironment = !usesSystemAppEnvironment && hostEnvironment.name == environmentName
// In the system's environment the app names already carry the environment's name, so they need no suffix.
var appNameSuffix = usesSystemAppEnvironment || (ownsManagedEnvironment && empty(placementSuffix)) ? '' : '-${take(uniqueString(managedEnvironmentName), 4)}'
var app = first(filter(system.azure.identities.apps, a => a.environment == environmentName))!
var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 5)
var tags = {
  system: slug
  environment: environmentName
  tier: environment.tier
  purpose: 'demo'
}

var vaultName = take('kv${slug}${environmentName}${suffix}', 24)
// SQL server names are global, and a create refused in one region keeps the name from another for a while; a SQL
// region of its own therefore gets a name of its own (unchanged when sqlLocation is location).
var sqlSuffix = sqlLocation == location ? suffix : take(uniqueString(subscription().id, resourceGroup().id, environmentName, sqlLocation), 5)
var sqlServerName = 'sql-${slug}-${environmentName}-${sqlSuffix}'
var databaseName = 'sqldb-${slug}-${environmentName}'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'

// A deployable runs as a container app (modules/containerapps.bicep) unless deployables[].hosting is "appservice": then
// a Linux web app on the Free plan (modules/appservice.bicep). An App Service deployable reaches the system's database
// with a login of its own (scripts/grant-database-access.ps1), whose connection string only its identity may read. One
// with a databasePackage owns the database (Octopus migrates it as the administrator, and its login may change the
// schema: the app creates its message queues at startup); the others share it, read and write.
// deployables[].hosting "staticwebapp": a site of static files on Azure Static Web Apps (modules/staticwebapp.bicep):
// the health dashboard, which has no server, no identity and no database login.
// deployables[].environments (container deployables only, scripts/test-system.ps1): the environments the deployable
// exists in; left out, it exists in every environment. An environment it does not name gets none of its resources.
// A deployable with hosting "own" brings its runtime (principle 007): nothing below creates anything for it, and it
// is no entry of the output "deployables". Its own project deploys and verifies it.
var hostedDeployables = filter(
  map(system.deployables, d => union({ hosting: 'containerapp', environments: [environmentName] }, d)),
  d => contains(d.environments, environmentName)
)
// A container deployable may declare more (all optional, modules/containerapps.bicep): a size of its own (cpu), one
// replica that never scales to zero (alwaysOn), no database (database false: no SQL connection string), plain
// settings as environment variables (settings, and environmentSettings.<env> on top of them), its own public address
// as a setting (urlSetting), and secrets from the environment's vault (secrets: operator-supplied, or generated).
var containerDefaults = {
  cpu: string(environment.appCpu)
  alwaysOn: false
  database: true
  settings: {}
  environmentSettings: {}
  urlSetting: ''
  secrets: []
}
var containerDeployables = map(
  filter(hostedDeployables, d => d.hosting == 'containerapp'),
  d => union(containerDefaults, d)
)
// A secret's vault name is <deployable>-<secret>. A generated one is a secret of this stack (modules/keyvault.bicep);
// an operator-supplied one is written to the vault by the operator (the kit's set-demo-secret.ps1) and is no resource
// of the stack: the app references it once it exists (presentSecrets).
var containerSecrets = flatten(map(
  containerDeployables,
  d => map(d.secrets, s => union({ generate: false }, s, { deployable: d.name, vaultName: '${d.name}-${s.name}' }))
))
var generatedSecretNames = map(filter(containerSecrets, s => s.generate), s => s.vaultName)
// A container deployable that declares secrets reads them as an identity of its own, id-<slug>-<env>-<deployable>,
// which may read exactly its own secrets (a role on each secret, modules/keyvault.bicep). The environment's shared
// runtime identity still pulls its image, but its code cannot use that identity (modules/containerapps.bicep), and in
// an environment with such a deployable the shared identity reads only the SQL connection string, not the vault.
var secretDeployables = filter(containerDeployables, d => !empty(d.secrets))
var containerApps = map(containerDeployables, d => {
  name: d.name
  port: d.port
  healthPath: d.healthPath
  cpu: string(d.cpu)
  alwaysOn: d.alwaysOn
  database: d.database
  urlSetting: d.urlSetting
  secretIdentityId: empty(d.secrets)
    ? ''
    : resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-${slug}-${environmentName}-${d.name}')
  settings: map(
    items(union(d.settings, d.environmentSettings[?environmentName] ?? {})),
    s => { name: s.key, value: string(s.value) }
  )
  secrets: filter(
    containerSecrets,
    s => s.deployable == d.name && (s.generate || contains(presentSecrets, s.vaultName))
  )
})
var appServiceDeployables = filter(hostedDeployables, d => d.hosting == 'appservice')
var staticDeployables = filter(hostedDeployables, d => d.hosting == 'staticwebapp')
// The environment has a database when an app in it uses one: a container deployable with database (the default), or an
// App Service deployable (which shares the first app's database). Without one (an app of the person's own,
// app.source "repository"), the environment has no SQL server and its vault holds no SQL secret.
var hasDatabase = !empty(filter(containerDeployables, d => d.database)) || !empty(appServiceDeployables)
// The Free plan of Static Web Apps exists in a few regions only; the files are served from edge locations everywhere,
// so the region of the resource need not be the system's (system.staticLocation, optional).
var staticLocation = union({ staticLocation: 'centralus' }, system.system).staticLocation
// The dashboard runs in the browser and calls the health and version endpoints of every app itself, so with a static
// deployable the App Service apps answer requests from other origins (CORS). Every origin (*), not the dashboard's
// address: each environment's dashboard shows the nodes of every environment, so the origins to allow would be the
// sites of all environments, of both tiers; the endpoints it calls are public health and version endpoints that
// answer anyone anyway; and no credentials are sent or allowed. Without a static deployable nothing is set.
var corsAllowedOrigins = empty(staticDeployables) ? [] : ['*']

// In the system's region, like the vault: a placement move of the apps leaves the identity and its roles as they are.
resource secretIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for d in secretDeployables: {
    name: 'id-${slug}-${environmentName}-${d.name}'
    location: location
    tags: union(tags, { deployable: d.name })
  }
]

resource loginIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for d in appServiceDeployables: {
    name: 'id-${slug}-${environmentName}-${d.name}${placementSuffix}'
    location: appLocation
    tags: union(tags, { deployable: d.name })
  }
]

module telemetry 'modules/telemetry.bicep' = if (contains(capabilities, 'telemetry')) {
  name: 'telemetry-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: appLocation
    tags: tags
  }
}

module sql 'modules/sql.bicep' = if (hasDatabase) {
  name: 'sql-${environmentName}'
  params: {
    serverName: sqlServerName
    databaseName: databaseName
    location: sqlLocation
    tags: tags
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
  }
}

module vault 'modules/keyvault.bicep' = {
  name: 'vault-${environmentName}'
  params: {
    name: vaultName
    location: location
    tags: tags
    readerPrincipalIds: [app.principalId]
    officerPrincipalIds: [deployPrincipalId]
    database: hasDatabase
    sqlAdminPassword: sqlAdminPassword
    sqlConnectionString: hasDatabase
      ? 'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
      : ''
    logins: [
      for (d, i) in appServiceDeployables: {
        name: d.name
        // Only an identity that placement renamed gets a role assignment of its own (see modules/keyvault.bicep).
        renamedIdentity: empty(placementSuffix) ? '' : loginIdentities[i].name
        principalId: loginIdentities[i].properties.principalId
      }
    ]
    loginPasswords: loginPasswords
    generatedSecretNames: generatedSecretNames
    generatedSecrets: generatedSecrets
    narrowReaders: !empty(secretDeployables)
    secretIdentities: [
      for (d, i) in secretDeployables: {
        deployable: d.name
        principalId: secretIdentities[i].properties.principalId
      }
    ]
    // Only the secrets that exist: the generated ones, and the supplied ones the operator has written.
    secretGrants: map(
      filter(containerSecrets, s => s.generate || contains(presentSecrets, s.vaultName)),
      s => { deployable: s.deployable, vaultName: s.vaultName }
    )
    loginConnectionStrings: toObject(
      appServiceDeployables,
      d => d.name,
      d =>
        'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${d.name};Password=${loginPasswords[d.name]};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
    )
  }
}

// Azure allows one Free Linux App Service plan per resource group (FreeLinuxSkuNotAllowedInResourceGroup): the first
// environment of a tier owns the tier's plan, the others in the tier run their web apps on it. App Service uses the
// system's location (appLocation is a Container Apps quota matter).
var planOwner = first(filter(system.environments, e => e.tier == environment.tier))!.name
// system.planSku: { "<tier>": "B1" } gives a tier's plan in the system's location a size without the Free plan's daily
// quotas (60 CPU minutes, 165 MB of outbound data for the whole plan: one run of browser acceptance tests exceeds it,
// and Azure then stops every app on the plan until midnight UTC). The standby plans stay Free. While the system is
// dormant (azure.frontDoor.dormant, set-demo-frontdoor.ps1) every plan is Free again: nothing costs money between classes.
var planSkus = union({ nonprod: 'F1', prod: 'F1' }, union({ planSku: {} }, system.system).planSku)
var dormant = bool(union({ dormant: false }, union({ frontDoor: {} }, system.azure).frontDoor).dormant)
var planSku = (!dormant && string(planSkus[environment.tier]) == 'B1') ? 'B1' : 'F1'
// environments[].standbyLocation: the App Service apps a second time, in that region (primary and standby behind the
// environment's Front Door endpoint, capability "frontdoor"). The standby region's Free plan belongs to the first
// environment of the tier that has this standby region.
var standbyLocation = string(union({ standbyLocation: '' }, rawEnvironment).standbyLocation)
var standbyPlanOwner = empty(standbyLocation)
  ? environmentName
  : first(filter(system.environments, e => e.tier == environment.tier && union({ standbyLocation: '' }, e).standbyLocation == standbyLocation))!.name

module appService 'modules/appservice.bicep' = if (!empty(appServiceDeployables)) {
  name: 'appservice-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: location
    planName: 'asp-${slug}-${planOwner}'
    ownsPlan: planOwner == environmentName
    planSku: planSku
    tags: tags
    deployables: appServiceDeployables
    versions: versions
    identityResourceIds: [for (d, i) in appServiceDeployables: loginIdentities[i].id]
    connectionStringSecretUris: vault.outputs.loginConnectionStringUris
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
    corsAllowedOrigins: corsAllowedOrigins
  }
}

module appServiceStandby 'modules/appservice.bicep' = if (!empty(appServiceDeployables) && !empty(standbyLocation)) {
  name: 'appservice-${environmentName}-standby'
  params: {
    slug: slug
    environmentName: environmentName
    location: standbyLocation
    planName: 'asp-${slug}-${standbyPlanOwner}-${standbyLocation}'
    ownsPlan: standbyPlanOwner == environmentName
    nameSuffix: '-${standbyLocation}'
    role: 'standby'
    tags: tags
    deployables: appServiceDeployables
    versions: versions
    identityResourceIds: [for (d, i) in appServiceDeployables: loginIdentities[i].id]
    connectionStringSecretUris: vault.outputs.loginConnectionStringUris
    corsAllowedOrigins: corsAllowedOrigins
  }
}

// Only with a static deployable: one Static Web App per deployable, in staticLocation, on the Free plan unless the
// environment names another (environments[].staticPlan: a subscription holds at most 10 Free sites).
module staticSites 'modules/staticwebapp.bicep' = if (!empty(staticDeployables)) {
  name: 'staticwebapp-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: staticLocation
    plan: union({ staticPlan: 'Free' }, rawEnvironment).staticPlan
    tags: tags
    deployables: staticDeployables
    versions: versions
  }
}

// Only with a container deployable: a system whose apps all run on App Service has no Container Apps environment.
module apps 'modules/containerapps.bicep' = if (!empty(containerDeployables)) {
  name: 'apps-${environmentName}'
  dependsOn: [
    secretIdentities
  ]
  params: {
    slug: slug
    environmentName: environmentName
    managedEnvironmentName: managedEnvironmentName
    // The system's Container Apps environment is in a group of its own; any other is in this environment's tier group.
    managedEnvironmentResourceGroup: usesSystemAppEnvironment ? string(systemAppEnvironment.resourceGroup) : resourceGroup().name
    ownsManagedEnvironment: ownsManagedEnvironment
    // The system's environment may be an express one (system.json azure.appEnvironment.mode, from the seed).
    express: usesSystemAppEnvironment && union({ mode: 'standard' }, systemAppEnvironment).mode == 'express'
    appNameSuffix: appNameSuffix
    location: appLocation
    tags: tags
    deployables: containerApps
    vaultUri: vault.outputs.vaultUri
    versions: versions
    registryServer: system.azure.registry.loginServer
    identityResourceId: app.resourceId
    connectionStringSecretUri: vault.outputs.connectionStringSecretUri
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
  }
}

output keyVaultName string = vaultName
// Without a database (hasDatabase false) the SQL outputs are empty: apply-environment.ps1 and the runbooks then skip
// every SQL step.
output hasDatabase bool = hasDatabase
output sqlServerName string = hasDatabase ? sqlServerName : ''
output sqlServerFqdn string = hasDatabase ? sqlServerFqdn : ''
output databaseName string = hasDatabase ? databaseName : ''
output sqlAdminLogin string = hasDatabase ? sqlAdminLogin : ''
output deployables array = concat(
  empty(containerDeployables) ? [] : apps!.outputs.deployables,
  empty(appServiceDeployables) ? [] : appService!.outputs.deployables,
  empty(staticDeployables) ? [] : staticSites!.outputs.deployables
)
// The same App Service deployables in the standby region (empty without a standbyLocation): the scripts deploy to and
// verify both, and the Front Door endpoint has both as origins.
output standby array = (empty(appServiceDeployables) || empty(standbyLocation)) ? [] : appServiceStandby!.outputs.deployables
output capabilities array = capabilities
