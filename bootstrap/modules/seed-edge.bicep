// Seed, edge group: the system's one Azure Front Door profile (Standard), shared by every environment of both tiers,
// and the grants on its resource group. The profile is the only part of this template that costs money each month.
// Each environment adds its own endpoint, origin group and route as stack-<slug>-<env>-edge in this group
// (infra/modules/frontdoor.bicep, applied by scripts/apply-environment.ps1), so both deploy identities may write here;
// the stacks' deny settings keep each tier out of the other's endpoints. The plan identity reads the group and its cost.
targetScope = 'resourceGroup'

param slug string
param tags object
@description('Principal IDs of the deploy identities of both tiers.')
param deployPrincipalIds array
param planPrincipalId string

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: 'afd-${slug}'
  location: 'global'
  tags: tags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource contributors 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in deployPrincipalIds: {
    name: guid(resourceGroup().id, principalId, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
      // No angle brackets: Azure refuses a description that looks like an HTML tag.
      description: 'Deploy identity of a tier of ${slug}: the Front Door endpoints of its environments (their edge stacks)'
    }
  }
]

// Contributor leaves out Microsoft.Resources/deploymentStacks/manageDenySetting/action, which a stack with deny settings
// needs (DeploymentStackActionForbidden on cmdemo2's first edge stack): the built-in role for stacks adds it.
resource stackOwners 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in deployPrincipalIds: {
    name: guid(resourceGroup().id, principalId, 'adb29209-aa1d-457b-a786-c913953d2891')
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'adb29209-aa1d-457b-a786-c913953d2891') // Azure Deployment Stack Owner
      description: 'Deploy identity of a tier of ${slug}: the deny settings of its environments\' edge stacks'
    }
  }
]

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, planPrincipalId, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    description: 'id-${slug}-plan: capability checks of the Front Door endpoints'
  }
}

resource costReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, planPrincipalId, '72fafb9e-0641-4937-9268-a91bfd8191a3')
  properties: {
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '72fafb9e-0641-4937-9268-a91bfd8191a3') // Cost Management Reader
    description: 'id-${slug}-plan: the cost of the Front Door profile, for the health dashboard'
  }
}

output frontDoor object = {
  resourceGroup: resourceGroup().name
  profile: profile.name
}
