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

@description('What Azure does when the database has used the month\'s free amount (100,000 vCore seconds): AutoPause stops it until the next month, BillOverUsage bills what comes after (system.sqlFreeLimitExhaustion in system.json).')
@allowed([
  'AutoPause'
  'BillOverUsage'
])
param freeLimitExhaustionBehavior string = 'AutoPause'

@description('The database\'s size: Serverless (General Purpose serverless under the Azure SQL free offer) or Basic (5 DTU, 2 GB, a fixed monthly price, always on). system.sqlSku in system.json.')
@allowed([
  'Serverless'
  'Basic'
])
param databaseSku string = 'Serverless'

var basic = databaseSku == 'Basic'

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
  // Serverless under the free offer (the default): free while it is paused or inside the month's free amount, but a
  // database that is never left alone uses that amount in about two days. Basic: 5 DTU and 2 GB at a small fixed
  // price for the month, always on, for a system whose apps never sleep (a Front Door probes them all day).
  sku: basic ? {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  } : {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: basic ? {
    maxSizeBytes: 2147483648
  } : {
    useFreeLimit: true
    freeLimitExhaustionBehavior: freeLimitExhaustionBehavior
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
  }
}

output serverName string = server.name
output databaseName string = database.name
