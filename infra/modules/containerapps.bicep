// Capability "baseline": one Container Apps environment (consumption, scale to zero) and one container app per
// deployable of system.json. A deployable without a version in environments/<env>/versions.json runs a placeholder
// image, so the environment exists before the first app build; the first deployment replaces it.
// main.bicep hands each deployable over complete: name, port, healthPath, and
//   cpu          vCPU of its container: 0.5, 1, 1.5 or 2; Consumption pairs it with twice as many GiB (the lookup
//                fails for any other value). The environment's appCpu unless the deployable has a cpu of its own
//   alwaysOn     true: exactly one replica, never zero (a background service whose timers must keep running)
//   database     false: no SQL connection string (the app has no database)
//   settings     [{ name, value }]: plain environment variables
//   urlSetting   the environment variable that gets the app's own public address (https://<fqdn>), or ''
//   secrets      [{ name, env, vaultName }]: environment variable <env> from the vault secret <vaultName>, as a
//                reference (the value never passes through the deployment), read by the deployable's own identity
//   secretIdentityId  resource ID of that identity (a deployable with secrets has one, main.bicep), or ''. Such an
//                app carries two identities: its own, which reads its secrets and nothing else, and the environment's
//                shared one, which pulls the image (the seed gave it that right in both tiers) and reads the SQL
//                connection string for an app with a database. The shared one is closed to the app's code
//                (identitySettings, lifecycle None): the platform uses it, the containers cannot get its tokens.
targetScope = 'resourceGroup'

param slug string
param environmentName string

@description('Name of the Container Apps environment; main.bicep gives it a region suffix when the environment has an appLocation of its own.')
param managedEnvironmentName string = 'cae-${slug}-${environmentName}'

@description('Resource group of the Container Apps environment: this one, unless the system owns the environment (system.json azure.appEnvironment), which is in a group of its own.')
param managedEnvironmentResourceGroup string = resourceGroup().name

@description('False when the apps run in a Container Apps environment that something else creates: an earlier environment of the tier (sharesAppEnvironmentWith), or the seed (the system\'s own).')
param ownsManagedEnvironment bool = true

@description('True when the apps run in an Azure Container Apps express environment (the system\'s own, azure.appEnvironment.mode express): an app there names no workload profile and its ingress is plain HTTP/1.1 (express has no HTTP/2).')
param express bool = false

@description('Suffix of the app names when they do not run in their own default Container Apps environment, so a move creates them anew.')
param appNameSuffix string = ''
param location string
param tags object
param deployables array
param versions object
param registryServer string
param identityResourceId string
param connectionStringSecretUri string
@description('URI of the environment\'s vault, with its trailing slash; the secrets of a deployable are <vaultUri>secrets/<vaultName>.')
param vaultUri string
@description('Application Insights connection string when the environment has capability "telemetry" (not a secret: it identifies where to send telemetry).')
param applicationInsightsConnectionString string = ''

var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var placeholderPort = 80
// Telemetry: the app's OpenTelemetry SDK exports to Application Insights with the Azure Monitor exporter whenever it
// gets APPLICATIONINSIGHTS_CONNECTION_STRING (traces, logs and metrics, Live Metrics too); without the capability it
// gets none and sends nothing. OTEL_SERVICE_NAME names each app (its role in Application Insights).
var telemetryEnv = empty(applicationInsightsConnectionString)
  ? []
  : [
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: applicationInsightsConnectionString
      }
    ]

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = if (ownsManagedEnvironment) {
  name: managedEnvironmentName
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// The apps' public addresses are <app>.<default domain of the Container Apps environment>: known before the app
// exists, so an app can get its own address as a setting (urlSetting) without referring to itself.
resource hostEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!ownsManagedEnvironment) {
  name: managedEnvironmentName
  scope: resourceGroup(managedEnvironmentResourceGroup)
}
var defaultDomain = ownsManagedEnvironment ? managedEnvironment!.properties.defaultDomain : hostEnvironment!.properties.defaultDomain

resource apps 'Microsoft.App/containerApps@2025-01-01' = [
  for d in deployables: {
    name: 'ca-${slug}-${environmentName}-${d.name}${appNameSuffix}'
    location: location
    tags: union(tags, { deployable: d.name })
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: union(
        { '${identityResourceId}': {} },
        empty(d.secretIdentityId) ? {} : { '${d.secretIdentityId}': {} }
      )
    }
    properties: {
      environmentId: resourceId(managedEnvironmentResourceGroup, 'Microsoft.App/managedEnvironments', managedEnvironmentName)
      ...(express ? {} : { workloadProfileName: 'Consumption' })
      configuration: {
        ...(empty(d.secretIdentityId)
          ? {}
          : {
              identitySettings: [
                {
                  identity: identityResourceId
                  lifecycle: 'None'
                }
              ]
            })
        activeRevisionsMode: 'Single'
        ingress: {
          external: true
          targetPort: empty(versions[?d.name] ?? '') ? placeholderPort : d.port
          transport: express ? 'http' : 'auto'
          allowInsecure: false
        }
        registries: [
          {
            server: registryServer
            identity: identityResourceId
          }
        ]
        secrets: concat(
          d.database
            ? [
                {
                  name: 'sql-connection-string'
                  keyVaultUrl: connectionStringSecretUri
                  identity: identityResourceId
                }
              ]
            : [],
          map(d.secrets, s => {
            name: s.name
            // Versionless: the app picks up a new value without a new deployment (after a restart of the revision).
            keyVaultUrl: '${vaultUri}secrets/${s.vaultName}'
            identity: d.secretIdentityId
          })
        )
      }
      template: {
        containers: [
          {
            name: d.name
            image: empty(versions[?d.name] ?? '') ? placeholderImage : '${registryServer}/${slug}/${d.name}:${versions[d.name]}'
            resources: {
              cpu: json(d.cpu)
              memory: { '0.5': '1Gi', '1': '2Gi', '1.5': '3Gi', '2': '4Gi' }[d.cpu]
            }
            env: concat(
              d.database
                ? [
                    {
                      name: 'ConnectionStrings__SqlConnectionString'
                      secretRef: 'sql-connection-string'
                    }
                  ]
                : [],
              [
                {
                  name: 'OTEL_SERVICE_NAME'
                  value: '${slug}-${d.name}'
                }
              ],
              telemetryEnv,
              d.settings,
              empty(d.urlSetting)
                ? []
                : [
                    {
                      name: d.urlSetting
                      value: 'https://ca-${slug}-${environmentName}-${d.name}${appNameSuffix}.${defaultDomain}'
                    }
                  ],
              map(d.secrets, s => {
                name: s.env
                secretRef: s.name
              })
            )
          }
        ]
        scale: {
          minReplicas: d.alwaysOn ? 1 : 0
          maxReplicas: 1
        }
      }
    }
  }
]

output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    hosting: 'containerapp'
    containerApp: apps[i].name
    url: 'https://${apps[i].properties.configuration.ingress.fqdn}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]
