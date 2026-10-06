// One tier's identities: the deploy identity Octopus signs in as (Owner of this resource group, because the
// environment stacks create role assignments) and the runtime identity of each environment of the tier.
targetScope = 'resourceGroup'

param slug string
@allowed(['nonprod', 'prod'])
param tier string
param location string
param tags object
param octopusIssuer string
param audience string

@description('Octopus OIDC subjects allowed to sign in as the deploy identity of this tier.')
param deploySubjects array

@description('Names of the environments of this tier; each gets a runtime identity id-<slug>-<env>-app.')
param appEnvironments array

resource deploy 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-deploy-${tier}'
  location: location
  tags: tags
}

// One federated credential at a time: Azure refuses concurrent writes to the credentials of one identity.
@batchSize(1)
resource deployCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for (subject, i) in deploySubjects: {
    parent: deploy
    name: 'octopus-${i}'
    properties: {
      issuer: octopusIssuer
      subject: subject
      audiences: [audience]
    }
  }
]

resource owner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploy.id, 'owner')
  properties: {
    principalId: deploy.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    description: 'id-${slug}-deploy-${tier}: Octopus applies the environment stacks of ${tier} (Bicep deployment stacks with role assignments)'
  }
}

resource apps 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for name in appEnvironments: {
    name: 'id-${slug}-${name}-app'
    location: location
    tags: union(tags, { environment: name })
  }
]

output deploy object = {
  name: deploy.name
  clientId: deploy.properties.clientId
  principalId: deploy.properties.principalId
}

output apps array = [
  for (name, i) in appEnvironments: {
    environment: name
    name: apps[i].name
    resourceId: apps[i].id
    clientId: apps[i].properties.clientId
    principalId: apps[i].properties.principalId
  }
]
