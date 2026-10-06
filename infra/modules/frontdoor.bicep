// Capability "frontdoor": the environment's public address. One Azure Front Door endpoint per app of the environment
// (a static site, hosting "staticwebapp", has an address of its own and gets none), in the system's one Front Door
// profile (Standard; the seed creates it in a resource group of its own, system.json azure.frontDoor), with the
// deployable's apps as origins: the primary region at priority 1 and, when the environment has a standbyLocation, the
// standby at priority 2. Front Door probes every origin and sends the traffic to the healthy origin of the lowest
// priority, so the standby takes over when the primary stops answering, and the address stays the same when the apps
// move.
// Unlike the other capabilities this module is not part of infra/main.bicep: the profile is shared by both tiers, so
// scripts/apply-environment.ps1 applies it as a stack of its own, stack-<slug>-<env>-edge, in the profile's resource
// group, with the origins the environment's stack reports. Its deny settings exclude only the tier's deploy identity,
// so neither tier can change the other's endpoints although both may write to the group.
targetScope = 'resourceGroup'

param slug string
param environmentName string
@description('Name of the system\'s Front Door profile in this resource group (the seed creates it).')
param profileName string
param tags object
@description('One entry per deployable: { name, origins: [{ name, hostName, priority }] }.')
param deployables array
@description('Path Front Door probes on every origin. It must not reach the database: the probes arrive from every edge location, all day, and a serverless database they wake never pauses.')
param probePath string = '/alive'
@minValue(5)
@maxValue(255)
param probeIntervalInSeconds int = 30

resource profile 'Microsoft.Cdn/profiles@2024-02-01' existing = {
  name: profileName
}

resource endpoints 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = [
  for d in deployables: {
    parent: profile
    name: '${slug}-${environmentName}-${d.name}'
    location: 'global'
    tags: union(tags, { deployable: d.name })
    properties: {
      enabledState: 'Enabled'
    }
  }
]

resource originGroups 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = [
  for d in deployables: {
    parent: profile
    name: '${slug}-${environmentName}-${d.name}'
    properties: {
      loadBalancingSettings: {
        sampleSize: 4
        successfulSamplesRequired: 3
        additionalLatencyInMilliseconds: 50
      }
      healthProbeSettings: {
        probePath: probePath
        probeRequestType: 'GET'
        probeProtocol: 'Https'
        probeIntervalInSeconds: probeIntervalInSeconds
      }
      sessionAffinityState: 'Disabled'
    }
  }
]

// Origins of one deployable are created in their own module: a nested loop over deployables and their origins.
module origins 'frontdoor-origins.bicep' = [
  for (d, i) in deployables: {
    name: 'origins-${environmentName}-${d.name}'
    params: {
      profileName: profileName
      originGroupName: originGroups[i].name
      origins: d.origins
    }
  }
]

resource routes 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = [
  for (d, i) in deployables: {
    parent: endpoints[i]
    name: 'all'
    dependsOn: [
      origins[i]
    ]
    properties: {
      originGroup: {
        id: originGroups[i].id
      }
      supportedProtocols: [
        'Http'
        'Https'
      ]
      patternsToMatch: [
        '/*'
      ]
      forwardingProtocol: 'HttpsOnly'
      httpsRedirect: 'Enabled'
      linkToDefaultDomain: 'Enabled'
      enabledState: 'Enabled'
    }
  }
]

output endpoints array = [
  for (d, i) in deployables: {
    name: d.name
    endpoint: endpoints[i].name
    url: 'https://${endpoints[i].properties.hostName}'
    originGroup: originGroups[i].name
    origins: d.origins
    probePath: probePath
  }
]
