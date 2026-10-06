// AcrPull on the shared registry for the runtime identities of the environments.
targetScope = 'resourceGroup'

param registryName string
param principalIds array

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in principalIds: {
    name: guid(registry.id, principalId, 'acrpull')
    scope: registry
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      description: 'Runtime identity: pull app images'
    }
  }
]
