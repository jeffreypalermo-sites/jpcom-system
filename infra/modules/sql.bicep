// Capability "baseline": an Azure SQL logical server and one database on the free offer (serverless General Purpose,
// auto-paused when the monthly free amount is used up). A subscription holds at most 10 free databases, all in one
// region. Azure services may connect (the container apps and the Octopus dynamic workers); the migration step adds
// and removes a rule for its worker's address as well.
targetScope = 'resourceGroup'

param serverName string
param databaseName string
param location string
param tags object
param administratorLogin string
@secure()
param administratorPassword string

resource server 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource azureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: server
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: server
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
  }
}

output serverName string = server.name
output databaseName string = database.name
