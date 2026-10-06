// The origins of one Front Door origin group (modules/frontdoor.bicep): one per app of the deployable, by priority.
// The origin's host header is the app's own host name: App Service routes by it.
targetScope = 'resourceGroup'

param profileName string
param originGroupName string
@description('[{ name, hostName, priority }]: priority 1 is the primary region, 2 the standby.')
param origins array

resource profile 'Microsoft.Cdn/profiles@2024-02-01' existing = {
  name: profileName
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' existing = {
  parent: profile
  name: originGroupName
}

resource items 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = [
  for origin in origins: {
    parent: originGroup
    name: origin.name
    properties: {
      hostName: origin.hostName
      originHostHeader: origin.hostName
      httpPort: 80
      httpsPort: 443
      priority: origin.priority
      weight: 1000
      enabledState: 'Enabled'
      enforceCertificateNameCheck: true
    }
  }
]
