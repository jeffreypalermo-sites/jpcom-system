// Hosting "storagewebsite" (decision 0035): one storage account with a static website per deployable and environment.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object
param deployables array
param versions object
@description('Principal ID of the deploy identity of this tier: it switches the static website on and writes the files.')
param deployPrincipalId string

// Storage Blob Data Contributor.
var blobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

// ARM has no static website property: scripts/deploy-storagewebsite.ps1 switches it on before each upload.
resource accounts 'Microsoft.Storage/storageAccounts@2024-01-01' = [
  for d in deployables: {
    name: take('st${slug}${environmentName}${uniqueString(resourceGroup().id, environmentName, d.name)}', 24)
    location: location
    tags: union(tags, { deployable: d.name })
    kind: 'StorageV2'
    sku: {
      name: 'Standard_LRS'
    }
    properties: {
      accessTier: 'Hot'
      // The website is public regardless; this keeps the blob endpoint closed to anonymous reads.
      allowBlobPublicAccess: false
      allowSharedKeyAccess: false
      defaultToOAuthAuthentication: true
      minimumTlsVersion: 'TLS1_2'
      supportsHttpsTrafficOnly: true
    }
  }
]

// Shared keys are off, so the deploy identity uploads with a data role of its own.
resource writers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (d, i) in deployables: {
    name: guid(accounts[i].id, deployPrincipalId, 'blob-data-contributor')
    scope: accounts[i]
    properties: {
      principalId: deployPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: blobDataContributor
    }
  }
]

output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    hosting: 'storagewebsite'
    storageAccount: accounts[i].name
    // The web endpoint's zone (z<n>) is Azure's choice, so the address is read, without its trailing slash.
    url: 'https://${split(accounts[i].properties.primaryEndpoints.web, '/')[2]}'
    healthPath: '/'
    version: versions[?d.name] ?? ''
  }
]
