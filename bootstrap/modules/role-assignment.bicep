// One role assignment at the scope of the resource group this module is deployed to.
targetScope = 'resourceGroup'

param principalId string
param roleDefinitionId string
param description string
@sys.description('ServicePrincipal for an identity of the pipelines; User when the role goes to a person\'s login.')
param principalType string = 'ServicePrincipal'

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    description: description
  }
}
