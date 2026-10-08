// Seed, apps group (only with azure.appEnvironment "system"): the system's one Container Apps environment, which every
// environment of both tiers runs its apps in, and who may use it. The system owns it, not an environment: no
// environment's stack creates, changes or removes it, so adding, moving or tearing down an environment leaves it as it
// is. Each environment's stack creates its container apps in it (infra/modules/containerapps.bicep, from
// system.json azure.appEnvironment), from the environment's own tier group: the apps, their identities and their
// vaults stay in the tier, and only the shared runtime is shared.
// The deploy identities of both tiers may read the environment and place apps in it (the custom role
// "Container Apps environment user (<slug>)": read and join, nothing else); the plan identity reads the group for the
// previews and the drift check, and its cost for the health dashboard (scripts/write-cost.ps1 asks Cost Management
// at the scope of every group of system.json azure.resourceGroups, and this group is one of them).
// azure.appEnvironmentMode "express": an Azure Container Apps express environment instead of one with workload
// profiles. It counts against the quota ExpressEnvironmentCount (200 a region, where a subscription may get a single
// standard environment), exists in seconds and starts an app from zero faster. It takes no custom domain, no Key Vault
// secret reference and no workload profile: reference.md, "A Container Apps environment the system owns".
// This template does not create an express environment: the validation of a template deployment counts one against
// the subscription's standard limits (ManagedEnvironmentCount, and the limit for all regions together), so it is
// refused wherever those are used up, although the service accepts it. new-demo-seed.ps1 creates it with one direct
// request before this deployment, and the template takes it as it is: who may use it, and what system.json records.
targetScope = 'resourceGroup'

param slug string
param location string
param tags object
@description('Principal IDs of the deploy identities of both tiers.')
param deployPrincipalIds array
param planPrincipalId string
@description('Name (GUID) of the custom role "Container Apps environment user (<slug>)", defined by seed.bicep.')
param environmentUserRoleName string
@description('True: an Azure Container Apps express environment (azure.appEnvironmentMode express), which new-demo-seed.ps1 created before this deployment.')
param express bool = false

resource standardEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = if (!express) {
  name: 'cae-${slug}'
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

// The environment by its name, whichever way it came to be: the standard one above, or the express one of the seed
// script. API version 2026-07-01 knows the express mode; the Bicep versions in use (0.47) carry no types for it, so
// the one warning about that is turned off here.
#disable-next-line BCP081
resource environment 'Microsoft.App/managedEnvironments@2026-07-01' existing = {
  name: 'cae-${slug}'
}

resource users 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in deployPrincipalIds: {
    name: guid(environment.id, principalId, environmentUserRoleName)
    scope: environment
    dependsOn: [
      standardEnvironment
    ]
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', environmentUserRoleName)
      // No angle brackets: Azure refuses a description that looks like an HTML tag.
      description: 'Deploy identity of a tier of ${slug}: the container apps of its environments, in the system Container Apps environment'
    }
  }
]

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, planPrincipalId, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    description: 'id-${slug}-plan: previews, drift and capability checks of the system Container Apps environment'
  }
}

resource costReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, planPrincipalId, '72fafb9e-0641-4937-9268-a91bfd8191a3')
  properties: {
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '72fafb9e-0641-4937-9268-a91bfd8191a3') // Cost Management Reader
    description: 'id-${slug}-plan: the cost of the system Container Apps environment, for the health dashboard'
  }
}

// system.json azure.appEnvironment (new-system-repository.ps1). The static IP is the target of an apex domain's A
// record, should an environment get a custom domain; an express environment has neither.
output appEnvironment object = {
  name: environment.name
  id: environment.id
  resourceGroup: resourceGroup().name
  location: location
  mode: express ? 'express' : 'standard'
  defaultDomain: express ? environment.properties.defaultDomain : standardEnvironment!.properties.defaultDomain
  staticIp: express ? '' : standardEnvironment!.properties.staticIp
}
