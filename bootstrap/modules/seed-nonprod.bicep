// The nonprod group of the seed: the shared registry, the Terraform state account of octopus/, the identities of the
// GitHub workflows (plan, octopus-config, acr-push), and the nonprod tier (seed-tier.bicep). With containerRegistry
// false (a system whose apps are no container images) there is no registry, and nothing that exists for it: no
// acr-push identity, no ACR role and no ACR role assignment.
targetScope = 'resourceGroup'

param slug string
param location string
param tags object
param githubIssuer string
param octopusIssuer string
param audience string
param planSubject string
param octopusConfigSubject string

@description('GitHub OIDC subject of the nightly capability checks of the system repository (environment "capabilities"); they sign in as the plan identity.')
param capabilitiesSubject string

@description('False for a system that needs no container registry: the registry, the acr-push identity and every ACR role and role assignment are left out, and the outputs registry and acrPush are {}.')
param containerRegistry bool
param acrPushSubjects array
param deploySubjects array
param appEnvironments array

var suffix = take(uniqueString(resourceGroup().id, slug), 6)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (containerRegistry) {
  name: 'acr${slug}${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource state 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${slug}tf${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: state
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'tfstate'
}

// The plan identity: what-if previews of pull requests, the nightly drift check (Reader) and the cost the health
// dashboard shows (Cost Management Reader).
resource plan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-plan'
  location: location
  tags: tags
}

resource planCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: plan
  name: 'github-azure-read'
  properties: {
    issuer: githubIssuer
    subject: planSubject
    audiences: [audience]
  }
}

resource planCapabilitiesCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: plan
  name: 'github-capabilities'
  properties: {
    issuer: githubIssuer
    subject: capabilitiesSubject
    audiences: [audience]
  }
  dependsOn: [planCredential]
}

module planReader 'role-assignment.bicep' = {
  name: 'seed-${slug}-nonprod-reader'
  params: {
    principalId: plan.properties.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    description: 'id-${slug}-plan: what-if previews and drift checks of nonprod'
  }
}

// What the environments cost, for the health dashboard (workflow "delivery", scripts/write-cost.ps1): the plan identity
// asks Cost Management at the scope of each of the system's groups, so the role is assigned per group, never on the
// subscription.
module planCostReader 'role-assignment.bicep' = {
  name: 'seed-${slug}-nonprod-cost-reader'
  params: {
    principalId: plan.properties.principalId
    roleDefinitionId: '72fafb9e-0641-4937-9268-a91bfd8191a3' // Cost Management Reader
    description: 'id-${slug}-plan: the cost of nonprod, for the health dashboard'
  }
}

// The octopus-config identity: the Terraform state of octopus/ only (Storage Blob Data Contributor on the account).
resource octopusConfig 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-octopus-config'
  location: location
  tags: tags
}

resource octopusConfigCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: octopusConfig
  name: 'github-octopus'
  properties: {
    issuer: githubIssuer
    subject: octopusConfigSubject
    audiences: [audience]
  }
}

resource stateWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(state.id, octopusConfig.id, 'blob-data-contributor')
  scope: state
  properties: {
    principalId: octopusConfig.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    description: 'id-${slug}-octopus-config: Terraform state of octopus/'
  }
}

// The acr-push identity: the release workflows of the app repositories push images (AcrPush on the registry).
resource acrPush 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (containerRegistry) {
  name: 'id-${slug}-acr-push'
  location: location
  tags: tags
}

@batchSize(1)
resource acrPushCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for (subject, i) in acrPushSubjects: if (containerRegistry) {
    parent: acrPush
    name: 'github-release-${i}'
    properties: {
      issuer: githubIssuer
      subject: subject
      audiences: [audience]
    }
  }
]

resource acrPusher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (containerRegistry) {
  name: guid(registry.id, acrPush.id, 'acrpush')
  scope: registry
  properties: {
    principalId: acrPush!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
    description: 'id-${slug}-acr-push: release workflows of the app repositories'
  }
}

// Released images are write-locked by the release workflow (az acr repository update --write-enabled false), which
// AcrPush does not allow: this role adds only the repository metadata rights, on this registry.
resource tagLockRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (containerRegistry) {
  name: guid(registry.id, 'acr-tag-lock')
  properties: {
    roleName: 'ACR tag lock (${slug})'
    description: 'Lock released image tags of the ${slug} registry (repository metadata read and write).'
    type: 'CustomRole'
    permissions: [
      {
        // Registry permission mode "legacy" (the default): repository metadata rights are control-plane actions.
        actions: [
          'Microsoft.ContainerRegistry/registries/metadata/read'
          'Microsoft.ContainerRegistry/registries/metadata/write'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      registry.id
    ]
  }
}

resource tagLocker 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (containerRegistry) {
  name: guid(registry.id, acrPush.id, 'acr-tag-lock')
  scope: registry
  properties: {
    principalId: acrPush!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tagLockRole.id
    description: 'id-${slug}-acr-push: write-lock released image tags'
  }
}

// The capability checks read the lock state of released images. In permission mode "legacy" the registry hands out a
// data-plane token only to an identity with pull rights, so metadata read alone fails the token exchange ("Unable to
// authenticate using AAD"); both are read-only.
resource registryMetadataReadRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (containerRegistry) {
  name: guid(registry.id, 'acr-metadata-read')
  properties: {
    roleName: 'ACR metadata read (${slug})'
    description: 'Read images and repository metadata of the ${slug} registry, such as the lock state of released images.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.ContainerRegistry/registries/pull/read'
          'Microsoft.ContainerRegistry/registries/metadata/read'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      registry.id
    ]
  }
}

resource planMetadataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (containerRegistry) {
  name: guid(registry.id, plan.id, 'acr-metadata-read')
  scope: registry
  properties: {
    principalId: plan.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: registryMetadataReadRole.id
    description: 'id-${slug}-plan: lock state of released images (capability checks)'
  }
}

module tier 'seed-tier.bicep' = {
  name: 'seed-${slug}-nonprod-tier'
  params: {
    slug: slug
    tier: 'nonprod'
    location: location
    tags: tags
    octopusIssuer: octopusIssuer
    audience: audience
    deploySubjects: deploySubjects
    appEnvironments: appEnvironments
  }
}

module nonprodAcrPull 'registry-pull.bicep' = if (containerRegistry) {
  name: 'seed-${slug}-nonprod-acr-pull'
  params: {
    registryName: registry.name
    principalIds: map(tier.outputs.apps, a => a.principalId)
  }
}

// Without a registry: {} for registry and for acrPush (seed.bicep then leaves acrPush out of its identities).
output registry object = containerRegistry
  ? {
      name: registry.name
      loginServer: registry!.properties.loginServer
    }
  : {}

output terraformState object = {
  resourceGroup: resourceGroup().name
  storageAccount: state.name
  container: stateContainer.name
}

output plan object = {
  name: plan.name
  clientId: plan.properties.clientId
  principalId: plan.properties.principalId
}

output octopusConfig object = {
  name: octopusConfig.name
  clientId: octopusConfig.properties.clientId
  principalId: octopusConfig.properties.principalId
}

output acrPush object = containerRegistry
  ? {
      name: acrPush.name
      clientId: acrPush!.properties.clientId
      principalId: acrPush!.properties.principalId
    }
  : {}

output deploy object = tier.outputs.deploy
output apps array = tier.outputs.apps
