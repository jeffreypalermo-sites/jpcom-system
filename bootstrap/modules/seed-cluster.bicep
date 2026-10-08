// Runtime aks-argocd: what the one cluster of every environment needs before the pipeline creates it. The identity the
// system repository's cluster job signs in as (Contributor of this resource group), the cluster's own identity and
// its kubelet identity (which pulls the app images), the identity of the Octopus container feed, the storage account
// and identity of the SQL backups, and the public IP of the ingress, so the host names of the environments are known before the cluster exists and survive a rebuild of it.
targetScope = 'resourceGroup'

param slug string
param location string
param tags object
param githubIssuer string
param audience string

@description('GitHub OIDC subject of the cluster job of the system repository (environment "octopus": the job also signs in to Octopus).')
param clusterSubject string

@description('Octopus server URL without a trailing slash: the OIDC issuer of the Octopus container feed.')
param octopusIssuer string

@description('Octopus OIDC subject of the container feed that reads the registry: space:<space slug>:feed:<feed slug>.')
param feedSubject string

@description('Principal of id-<slug>-plan: reads this group for the previews and the drift check, and its cost.')
param planPrincipalId string

@description('Name of the role "Deployment what-if (<slug>)" the seed defines.')
param whatIfRoleName string

@description('Principals of id-<slug>-deploy-<tier>: Octopus uploads a static site (hosting "staticwebapp") as them.')
param deployPrincipalIds array

@description('Name of the role "Static site deployment (<slug>)" the seed defines.')
param siteDeployRoleName string

resource pipeline 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-cluster'
  location: location
  tags: tags
}

resource pipelineCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: pipeline
  name: 'github-cluster'
  properties: {
    issuer: githubIssuer
    subject: clusterSubject
    audiences: [audience]
  }
}

module pipelineContributor 'role-assignment.bicep' = {
  name: 'seed-${slug}-cluster-contributor'
  params: {
    principalId: pipeline.properties.principalId
    roleDefinitionId: 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
    description: 'id-${slug}-cluster: the cluster job applies the cluster stack and reads its admin credentials'
  }
}

module planReader 'role-assignment.bicep' = {
  name: 'seed-${slug}-cluster-reader'
  params: {
    principalId: planPrincipalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    description: 'id-${slug}-plan: what-if previews and drift checks of the cluster'
  }
}

module planCostReader 'role-assignment.bicep' = {
  name: 'seed-${slug}-cluster-cost-reader'
  params: {
    principalId: planPrincipalId
    roleDefinitionId: '72fafb9e-0641-4937-9268-a91bfd8191a3' // Cost Management Reader
    description: 'id-${slug}-plan: the cost of the cluster, for the health dashboard'
  }
}

// A deployable with hosting "staticwebapp" is a Static Web App of this group (infra/cluster.bicep creates it); its
// Octopus project finds the site and reads its deployment token as the tier's deploy identity, with the seed's own
// role for exactly that. Either tier's identity may read either tier's site: they share this group.
module deploySites 'role-assignment.bicep' = [
  for (principalId, i) in deployPrincipalIds: {
    name: 'seed-${slug}-cluster-site-deploy-${i}'
    params: {
      principalId: principalId
      roleDefinitionId: siteDeployRoleName
      description: 'id-${slug}-deploy: finds the static sites of this group and reads their deployment tokens'
    }
  }
]

module planWhatIf 'role-assignment.bicep' = {
  name: 'seed-${slug}-cluster-what-if'
  params: {
    principalId: planPrincipalId
    roleDefinitionId: whatIfRoleName
    description: 'id-${slug}-plan: what-if of the cluster'
  }
}

resource controlPlane 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-aks'
  location: location
  tags: tags
}

resource kubelet 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-kubelet'
  location: location
  tags: tags
}

// The cluster assigns the kubelet identity to its nodes: Managed Identity Operator on that identity.
resource kubeletOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kubelet.id, controlPlane.id, 'managed-identity-operator')
  scope: kubelet
  properties: {
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f1a07417-d97a-45cb-824c-7a7467783830')
    description: 'id-${slug}-aks: assigns the kubelet identity to the nodes'
  }
}

// Octopus reads the image versions of the registry as this identity (its container feed signs in with OIDC): a release
// names an image version, and the Argo CD step writes it to Git.
resource feed 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-feed'
  location: location
  tags: tags
}

resource feedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: feed
  name: 'octopus-feed'
  properties: {
    issuer: octopusIssuer
    subject: feedSubject
    audiences: [audience]
  }
}

// Backups of the environments' SQL Server containers leave the cluster: a storage account that accepts Microsoft Entra
// sign-in only, and the identity the backup jobs use through workload identity (infra/cluster.bicep adds its federated
// credentials once the cluster's issuer exists). A backup older than two weeks is deleted.
var suffix = take(uniqueString(resourceGroup().id, slug), 6)

resource backupAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${slug}bk${suffix}'
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

resource backupBlobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: backupAccount
  name: 'default'
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: backupBlobs
  name: 'sql-backups'
}

resource backupRetention 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: backupAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-old-backups'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 14
                }
              }
            }
          }
        }
      ]
    }
  }
}

resource backup 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-backup'
  location: location
  tags: tags
}

resource backupWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(backupAccount.id, backup.id, 'blob-data-contributor')
  scope: backupAccount
  properties: {
    principalId: backup.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    description: 'id-${slug}-backup: the backup jobs of the environments write and read the SQL backups'
  }
}

resource ingressIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${slug}-ingress'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// The ingress Service's load balancer uses an IP outside the node resource group: Network Contributor on that IP.
resource ingressIpUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ingressIp.id, controlPlane.id, 'network-contributor')
  scope: ingressIp
  properties: {
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    description: 'id-${slug}-aks: attaches the ingress IP to the load balancer'
  }
}

output pipeline object = {
  name: pipeline.name
  clientId: pipeline.properties.clientId
  principalId: pipeline.properties.principalId
}

output controlPlane object = {
  name: controlPlane.name
  resourceId: controlPlane.id
  principalId: controlPlane.properties.principalId
}

output kubelet object = {
  name: kubelet.name
  resourceId: kubelet.id
  clientId: kubelet.properties.clientId
  principalId: kubelet.properties.principalId
}

output feed object = {
  name: feed.name
  clientId: feed.properties.clientId
  principalId: feed.properties.principalId
}

output backupIdentity object = {
  name: backup.name
  clientId: backup.properties.clientId
  principalId: backup.properties.principalId
}

output backup object = {
  storageAccount: backupAccount.name
  container: backupContainer.name
}

output ingress object = {
  publicIpName: ingressIp.name
  ipAddress: ingressIp.properties.ipAddress
}
