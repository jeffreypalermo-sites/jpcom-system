// Hosting "staticwebapp": one Azure Static Web App on the Free plan per static deployable of system.json and
// environment (the health dashboard: a site of static files, with no server and no database). No repository is linked:
// Octopus deploys the release's files with the site's deployment token, which it reads at deploy time and never stores
// (scripts/deploy-staticwebapp.ps1). The properties stay empty for the same reason: the platform records who deployed
// last (provider) itself, and a value here would show as drift after every deployment.
// Free plan limits: 100 GB of bandwidth a month and 250 MB per site, no SLA; custom domains are not used here.
// The Free plan exists in a few regions only (westus2, centralus, eastus2, westeurope, eastasia). The region holds the
// resource and its management endpoint; the files are served from the platform's edge locations everywhere, so the
// region need not be the system's (system.json system.staticLocation, centralus unless set).
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object
param deployables array
param versions object

resource sites 'Microsoft.Web/staticSites@2024-04-01' = [
  for d in deployables: {
    name: 'swa-${slug}-${environmentName}-${d.name}'
    location: location
    tags: union(tags, { deployable: d.name })
    sku: {
      name: 'Free'
      tier: 'Free'
    }
    properties: {}
  }
]

// A new site answers 200 on / with the platform's own page until the first release is deployed, so the health path
// is / before and after it.
output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    hosting: 'staticwebapp'
    staticSite: sites[i].name
    url: 'https://${sites[i].properties.defaultHostname}'
    healthPath: '/'
    version: versions[?d.name] ?? ''
  }
]
