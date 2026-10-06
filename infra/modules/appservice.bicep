// Hosting "appservice": a Linux App Service plan on the Free tier (F1) per tier and one web app per App Service
// deployable of system.json and environment. Azure allows one Free Linux plan per resource group, so the first
// environment of a tier creates the plan (ownsPlan) and the tier's other environments share it, quotas included. No registry: the app is a zip of the published .NET app on the built-in runtime, deployed
// by Octopus (scripts/deploy-appservice.ps1). Its connection string is a Key Vault reference to a secret that only its
// own identity may read, for a login of its own in the system's database (output ownsDatabase: the deployable with a
// databasePackage, whose login may also change the schema).
// Free tier limits: 60 CPU minutes a day, no Always On (the first request after idle starts the app), 165 MB outbound a
// day, no deployment slots.
// An environment with a standbyLocation gets this module twice: the same apps in a second region (role "standby", names
// with the region), on a Free plan of that region; Azure allows one Free Linux plan per resource group and region. Both
// use the same identity and the same database.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object
param deployables array
param versions object
@description('Name of the tier\'s Free plan in this region: asp-<slug>-<first environment of the tier>, with the region for a standby.')
param planName string
@description('Suffix of the web app names: empty in the primary region, -<region> in the standby (environments[].standbyLocation).')
param nameSuffix string = ''
@description('primary, or standby: the same apps in a second region, behind the environment\'s Front Door endpoint at priority 2.')
param role string = 'primary'
@description('True in the first environment of the tier, which creates the plan; the others use it.')
param ownsPlan bool
@description('Size of the plan: F1 (Free) or B1 (Basic: a dedicated core, no daily CPU or outbound data quota). main.bicep takes it from system.json system.planSku for the tier, and F1 while the system is dormant.')
@allowed([
  'F1'
  'B1'
])
param planSku string = 'F1'
@description('User-assigned identity of each deployable, in the order of deployables.')
param identityResourceIds array
@description('Versionless Key Vault URI of each deployable\'s connection string, in the order of deployables.')
param connectionStringSecretUris array
@description('Application Insights connection string when the environment has capability "telemetry": the app exports to it with the Azure Monitor OpenTelemetry exporter.')
param applicationInsightsConnectionString string = ''
@description('Origins whose pages may read the apps\' answers (CORS), without credentials; empty: no CORS setting. main.bicep passes * when the system has a dashboard (hosting "staticwebapp"), whose page calls the apps\' health and version endpoints from the browser.')
param corsAllowedOrigins array = []

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = if (ownsPlan) {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: planSku
    tier: planSku == 'F1' ? 'Free' : 'Basic'
  }
  properties: {
    reserved: true
  }
}

resource sites 'Microsoft.Web/sites@2024-04-01' = [
  for (d, i) in deployables: {
    name: 'app-${slug}-${environmentName}-${d.name}${nameSuffix}'
    location: location
    tags: union(tags, { deployable: d.name })
    kind: 'app,linux'
    dependsOn: [
      plan
    ]
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityResourceIds[i]}': {}
      }
    }
    properties: {
      serverFarmId: resourceId('Microsoft.Web/serverfarms', planName)
      httpsOnly: true
      keyVaultReferenceIdentity: identityResourceIds[i]
      siteConfig: {
        linuxFxVersion: 'DOTNETCORE|10.0'
        // No startup command until a version is pinned: an empty site with one crash-loops, and on a shared Free plan
        // the restarts exhaust the quota of every app on it. deploy-appservice.ps1 sets it right before the first zip.
        appCommandLine: empty(versions[?d.name] ?? '') ? '' : 'dotnet ${d.startupAssembly}'
        alwaysOn: false
        ftpsState: 'Disabled'
        minTlsVersion: '1.2'
        http20Enabled: true
        // CORS only when there are origins to allow. Null is "not set": a system without a dashboard deploys the
        // site configuration it had before the setting existed, and a what-if shows no change. (The other way
        // round too: taking the dashboard out of system.json leaves the setting on the existing sites.)
        cors: empty(corsAllowedOrigins)
          ? null
          : {
              allowedOrigins: corsAllowedOrigins
              supportCredentials: false
            }
        appSettings: concat(
          [
            {
              name: 'ConnectionStrings__SqlConnectionString'
              value: '@Microsoft.KeyVault(SecretUri=${connectionStringSecretUris[i]})'
            }
            {
              name: 'OTEL_SERVICE_NAME'
              value: '${slug}-${d.name}'
            }
          ],
          empty(applicationInsightsConnectionString)
            ? []
            : [
                {
                  name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
                  value: applicationInsightsConnectionString
                }
              ]
        )
      }
    }
  }
]

output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    hosting: 'appservice'
    ownsDatabase: contains(d, 'databasePackage')
    region: location
    role: role
    webApp: sites[i].name
    startupCommand: 'dotnet ${d.startupAssembly}'
    url: 'https://${sites[i].properties.defaultHostName}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]
