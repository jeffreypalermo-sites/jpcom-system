// Capability "baseline": the environment's vault (RBAC authorization, no purge protection so a torn-down demo can be
// purged) with the SQL secrets. The runtime identity reads secrets; the deploy identity reads and writes them. In an
// environment without a database (database false: no app in it has one) the vault holds no SQL secret, only the
// secrets of the container deployables.
targetScope = 'resourceGroup'

param name string
param location string
param tags object
param readerPrincipalIds array
param officerPrincipalIds array
@description('False in an environment without a database: no SQL secrets.')
param database bool = true
@secure()
param sqlAdminPassword string = ''
@secure()
param sqlConnectionString string = ''

@description('Database logins of App Service deployables: name, and the principal ID of the one identity that may read its connection string.')
param logins array = []
@description('Password of each login, by name.')
@secure()
param loginPasswords object = {}
@description('Connection string of each login, by name.')
@secure()
param loginConnectionStrings object = {}

@description('Vault names of the generated secrets of container deployables (<deployable>-<secret>).')
param generatedSecretNames array = []
@description('Value of each generated secret, by vault name.')
@secure()
param generatedSecrets object = {}

@description('True in an environment with a container deployable that has an identity of its own for its secrets: the reader identities (the shared runtime identity) then read only the SQL connection string, not every secret of the vault.')
param narrowReaders bool = false
@description('The identity of each container deployable that declares secrets: { deployable, principalId }.')
param secretIdentities array = []
@description('The existing secrets of those deployables, each read by its deployable\'s identity only: { deployable, vaultName }.')
param secretGrants array = []

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in (narrowReaders ? [] : readerPrincipalIds): {
    name: guid(vault.id, principalId, 'secrets-user')
    scope: vault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
  }
]

resource officers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in officerPrincipalIds: {
    name: guid(vault.id, principalId, 'secrets-officer')
    scope: vault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    }
  }
]

resource adminPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (database) {
  parent: vault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
    contentType: 'text/plain'
  }
}

resource connectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (database) {
  parent: vault
  name: 'sql-connection-string'
  properties: {
    value: sqlConnectionString
    contentType: 'text/plain'
  }
  dependsOn: [
    readers
  ]
}

// With narrowReaders the shared runtime identity gets the one secret its apps reference instead of the vault: the
// secrets of a deployable with an identity of its own are then out of its reach. The stack removes the vault-wide
// assignment at the end of the apply that adds this one, so the apps never lack access in between.
resource connectionStringReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in (narrowReaders && database ? readerPrincipalIds : []): {
    name: guid(vault.id, principalId, 'sql-connection-string-user')
    scope: connectionString
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
  }
]

// A login's password (read by the deploy identity's grant step) and its connection string, which only the
// deployable's own identity may read: the role is assigned on the secret, not on the vault.
resource loginPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for l in logins: {
    parent: vault
    name: '${l.name}-sql-password'
    properties: {
      value: loginPasswords[l.name]
      contentType: 'text/plain'
    }
  }
]

resource loginConnectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for l in logins: {
    parent: vault
    name: '${l.name}-sql-connection-string'
    properties: {
      value: loginConnectionStrings[l.name]
      contentType: 'text/plain'
    }
  }
]

resource loginReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (l, i) in logins: {
    // A role assignment cannot change its principal, and an identity, role and scope allow only one assignment. So the
    // assignment keeps its name while the identity keeps its name, and an identity that placement renamed (a moved
    // environment: a new principal) gets an assignment of its own, next to the old one, which the stack then removes.
    name: empty(l.renamedIdentity) ? guid(vault.id, l.name, 'login-secret-user') : guid(vault.id, l.name, l.renamedIdentity, 'login-secret-user')
    scope: loginConnectionString[i]
    properties: {
      principalId: l.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
  }
]

// A secret the deployment generates for a container deployable (system.json deployables[].secrets[] with "generate":
// true): apply-environment.ps1 keeps its value, as it keeps the SQL passwords. Operator-supplied secrets are not here:
// the operator writes them to the vault (data plane), and the container app references them by name.
resource generatedSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for name in generatedSecretNames: {
    parent: vault
    name: name
    properties: {
      value: generatedSecrets[name]
      contentType: 'text/plain'
    }
  }
]

// Each secret of a container deployable, generated or supplied, is read by that deployable's own identity and by no
// other runtime identity: the role is on the secret, not on the vault. A supplied secret is no resource of this stack
// (the operator wrote it), so it is referred to as existing; its role assignment is the stack's.
resource grantedSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = [
  for g in secretGrants: {
    parent: vault
    name: g.vaultName
  }
]

resource secretReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (g, i) in secretGrants: {
    name: guid(vault.id, g.vaultName, g.deployable, 'deployable-secret-user')
    scope: grantedSecrets[i]
    properties: {
      principalId: first(filter(secretIdentities, s => s.deployable == g.deployable))!.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
    dependsOn: [
      generatedSecret
    ]
  }
]

output name string = vault.name
output vaultUri string = vault.properties.vaultUri
output loginConnectionStringUris array = [
  for (l, i) in logins: '${vault.properties.vaultUri}secrets/${loginConnectionString[i].name}'
]
// Versionless URI: the container app picks up a rotated value without a new revision. Empty without a database.
output connectionStringSecretUri string = database ? '${vault.properties.vaultUri}secrets/sql-connection-string' : ''
