// Seed of a demo system (layer 0): the two resource groups, the shared registry (only for a system that needs one,
// containerRegistry), the Terraform state account for the Octopus configuration, and every identity the pipelines sign
// in as, with their federated credentials and grants.
// Applied once by the operator as subscription Owner (the demo-environment skill, new-demo-seed.ps1):
//   az deployment sub create --location <region> --template-file bootstrap/seed.bicep --parameters @<file>
// Nothing else creates identities or role assignments outside a resource group; every later Azure change goes through
// the pipelines (infra/, applied by Octopus). Federated credentials exist for every environment from the start, so
// adding uat or prod later is a pull request, not a re-run of the seed.
targetScope = 'subscription'

@description('System slug: 3 to 10 lowercase letters and digits, starting with a letter. Every name derives from it.')
@minLength(3)
@maxLength(10)
param slug string

@description('Azure region of every resource of the system.')
param location string

param nonprodResourceGroupName string
param prodResourceGroupName string

@description('Runtime aks-argocd: the resource group of the one AKS cluster every environment runs in. Empty for runtime containerapps.')
param clusterResourceGroupName string = ''

@description('Runtime aks-argocd: the cluster\'s node resource group (<cluster group>-nodes), once AKS has created it; empty before, and for Container Apps. The plan identity reads its cost for the health dashboard.')
param clusterNodeResourceGroupName string = ''

@description('GitHub organization that owns the system and app repositories.')
param githubOrg string

@description('Name of the system (GitOps) repository.')
param systemRepository string

@description('Names of the app repositories whose release workflow pushes images (environment "release").')
param appRepositories array

@description('OIDC subject prefix per repository, as GitHub reports it once the repository exists (sub_claim_prefix of actions/oidc/customization/sub). Repositories created after 2026-07-15 use immutable subjects, repo:<org>@<org-id>/<repo>@<repo-id>; a repository without an entry yet uses repo:<org>/<repo>. new-system-repository.ps1 and new-app-repository.ps1 fill it in before their first push.')
param githubSubjectPrefixes object = {}

@description('Octopus server URL without a trailing slash; it is the OIDC issuer of the Octopus Azure accounts.')
param octopusUrl string

@description('Slug of the Octopus space that holds the system projects.')
param octopusSpaceSlug string

@description('Slugs of the Octopus projects that sign in to Azure: <slug>-system and one per deployable.')
param octopusProjectSlugs array

@description('Every environment the system may ever have, with its tier: [{ name: "tdd", tier: "nonprod" }, ...].')
param environments array

@description('True for a system with a public address per environment: the seed then creates the resource group rg-<slug>-edge with the system\'s one Azure Front Door profile (Standard, a monthly base fee), which every environment with capability "frontdoor" adds its endpoint to.')
param frontDoor bool = false

@description('True once a deployable takes secrets the operator supplies (system.json deployables[].secrets): the identity that applies this seed then gets a role on the two tier groups that may set a secret in the environments\' vaults and list secret names, but not read a value (the skill\'s set-demo-secret.ps1).')
param operatorSecretWriter bool = false

@description('With azure.appEnvironment "system": the resource group of the system\'s one Container Apps environment (cae-<slug>), which every environment of both tiers runs its apps in. Empty: each environment owns its Container Apps environment.')
param appsResourceGroupName string = ''

@description('With azure.appEnvironment "system": the kind of that environment. standard: workload profiles (Consumption). express: Azure Container Apps express, which has a quota of its own and no custom domains.')
@allowed(['standard', 'express'])
param appEnvironmentMode string = 'standard'

@description('ServicePrincipal when the operator identity applies the seed; User for a person\'s login.')
@allowed(['ServicePrincipal', 'User'])
param operatorPrincipalType string = 'ServicePrincipal'

@description('True (the default) for a system whose apps are container images: runtime aks-argocd, or a first app hosted as a container app. False for a system that needs no registry (first app on App Service: zips in the Octopus built-in feed): the seed then creates no registry, no identity id-<slug>-acr-push, no ACR role and no ACR role assignment; the output registry is {} and identities has no acrPush. The deployment is incremental: false deletes nothing that an earlier run created (remove-demo-registry.ps1 of the demo-environment skill does).')
param containerRegistry bool = true

param tags object = {}

var githubIssuer = 'https://token.actions.githubusercontent.com'
var audience = 'api://AzureADTokenExchange'
var nonprodEnvironments = filter(environments, e => e.tier == 'nonprod')
var prodEnvironments = filter(environments, e => e.tier == 'prod')
var allTags = union(tags, { system: slug, purpose: 'demo' })
var hasCluster = !empty(clusterResourceGroupName)
// The cluster of runtime aks-argocd pulls its images from the registry, whatever containerRegistry says.
var hasRegistry = containerRegistry || hasCluster
var hasSystemAppEnvironment = !empty(appsResourceGroupName)
var systemSubjectPrefix = githubSubjectPrefixes[?systemRepository] ?? 'repo:${githubOrg}/${systemRepository}'

resource nonprodGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: nonprodResourceGroupName
  location: location
  tags: union(allTags, { tier: 'nonprod' })
}

resource prodGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: prodResourceGroupName
  location: location
  tags: union(allTags, { tier: 'prod' })
}

// Runtime aks-argocd: the group of the cluster, which holds every environment of both tiers.
resource clusterGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (hasCluster) {
  name: hasCluster ? clusterResourceGroupName : 'unused'
  location: location
  tags: union(allTags, { tier: 'cluster' })
}

// azure.appEnvironment "system": the group of the one Container Apps environment both tiers run their apps in.
resource appsGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (hasSystemAppEnvironment) {
  name: hasSystemAppEnvironment ? appsResourceGroupName : 'unused'
  location: location
  tags: union(allTags, { tier: 'shared' })
}

// Placing a container app in an environment takes Microsoft.App/managedEnvironments/join/action on it, which only broad
// roles (Contributor) hold: this role holds that and read, assignable to the apps group only.
resource environmentUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (hasSystemAppEnvironment) {
  name: guid(subscription().id, slug, 'container-apps-environment-user')
  properties: {
    roleName: 'Container Apps environment user (${slug})'
    description: 'Read the system Container Apps environment of ${slug} and place container apps in it: the deploy identities of both tiers.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.App/managedEnvironments/read'
          'Microsoft.App/managedEnvironments/join/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: [appsGroup.id]
  }
}

module apps 'modules/seed-apps.bicep' = if (hasSystemAppEnvironment) {
  name: 'seed-${slug}-apps'
  scope: appsGroup
  params: {
    slug: slug
    location: location
    tags: union(allTags, { tier: 'shared' })
    deployPrincipalIds: [
      nonprod.outputs.deploy.principalId
      prod.outputs.deploy.principalId
    ]
    planPrincipalId: nonprod.outputs.plan.principalId
    environmentUserRoleName: environmentUserRole!.name
    express: appEnvironmentMode == 'express'
  }
}

resource edgeGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (frontDoor) {
  name: 'rg-${slug}-edge'
  location: location
  tags: union(allTags, { tier: 'shared' })
}

// Edge group (only with frontDoor): the Front Door profile both tiers share, and who may write there.
module edge 'modules/seed-edge.bicep' = if (frontDoor) {
  name: 'seed-${slug}-edge'
  scope: edgeGroup
  params: {
    slug: slug
    tags: union(allTags, { tier: 'shared' })
    deployPrincipalIds: [
      nonprod.outputs.deploy.principalId
      prod.outputs.deploy.principalId
    ]
    planPrincipalId: nonprod.outputs.plan.principalId
  }
}

// Nonprod group: the registry (with containerRegistry), the state account, the identities of the pipelines and of tdd
// and uat.
module nonprod 'modules/seed-nonprod.bicep' = {
  name: 'seed-${slug}-nonprod'
  scope: nonprodGroup
  params: {
    slug: slug
    location: location
    tags: union(allTags, { tier: 'nonprod' })
    githubIssuer: githubIssuer
    octopusIssuer: octopusUrl
    audience: audience
    planSubject: '${githubSubjectPrefixes[?systemRepository] ?? 'repo:${githubOrg}/${systemRepository}'}:environment:azure-read'
    octopusConfigSubject: '${githubSubjectPrefixes[?systemRepository] ?? 'repo:${githubOrg}/${systemRepository}'}:environment:octopus'
    capabilitiesSubject: '${githubSubjectPrefixes[?systemRepository] ?? 'repo:${githubOrg}/${systemRepository}'}:environment:capabilities'
    containerRegistry: hasRegistry
    acrPushSubjects: [for repository in appRepositories: '${githubSubjectPrefixes[?repository] ?? 'repo:${githubOrg}/${repository}'}:environment:release']
    deploySubjects: flatten(map(nonprodEnvironments, e => map(octopusProjectSlugs, p => 'space:${octopusSpaceSlug}:project:${p}:environment:${e.name}')))
    appEnvironments: map(nonprodEnvironments, e => e.name)
  }
}

// Prod group: the deploy identity of prod and the runtime identity of each prod environment.
module prod 'modules/seed-tier.bicep' = {
  name: 'seed-${slug}-prod'
  scope: prodGroup
  params: {
    slug: slug
    tier: 'prod'
    location: location
    tags: union(allTags, { tier: 'prod' })
    octopusIssuer: octopusUrl
    audience: audience
    deploySubjects: flatten(map(prodEnvironments, e => map(octopusProjectSlugs, p => 'space:${octopusSpaceSlug}:project:${p}:environment:${e.name}')))
    appEnvironments: map(prodEnvironments, e => e.name)
  }
}

// What-if needs Microsoft.Resources/deployments/whatIf/action, which Reader lacks (first live run): this role adds only
// that and validate/action, assignable to the system's two groups.
resource whatIfRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, slug, 'deployment-what-if')
  properties: {
    roleName: 'Deployment what-if (${slug})'
    description: 'What-if and validation of deployments, for the previews and drift checks of id-${slug}-plan (with Reader).'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Resources/deployments/whatIf/action'
          'Microsoft.Resources/deployments/validate/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: concat([nonprodGroup.id, prodGroup.id], hasCluster ? [clusterGroup.id] : [])
  }
}

// Runtime aks-argocd, a dashboard on Azure Static Web Apps (hosting "staticwebapp"): its Octopus project finds the
// site and reads its deployment token as the tier's deploy identity. No built-in role has those two actions without
// far more (Website Contributor covers web apps, Microsoft.Web/sites, not static sites: lesson 58), so the seed
// defines this one, assignable to the cluster's group only.
resource siteDeployRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (hasCluster) {
  name: guid(subscription().id, slug, 'static-site-deploy')
  properties: {
    roleName: 'Static site deployment (${slug})'
    // No angle brackets: Azure refuses a role whose name or description looks like it holds an HTML tag.
    description: 'Reads a Static Web App and its deployment token, for the uploads by the deploy identities of ${slug}.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Web/staticSites/read'
          'Microsoft.Web/staticSites/listSecrets/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: [clusterGroup.id]
  }
}

module nonprodWhatIf 'modules/role-assignment.bicep' = {
  name: 'seed-${slug}-nonprod-what-if'
  scope: nonprodGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: whatIfRole.name
    description: 'id-${slug}-plan: what-if of nonprod'
  }
}

module prodWhatIf 'modules/role-assignment.bicep' = {
  name: 'seed-${slug}-prod-what-if'
  scope: prodGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: whatIfRole.name
    description: 'id-${slug}-plan: what-if of prod'
  }
}

// Operator-supplied secrets (system.json deployables[].secrets without "generate"): their values go from the operator
// straight into an environment's vault, never through a repository, a pipeline variable or a log. A stack's deny
// settings cover the control plane only, so what the operator lacks for that is a data-plane role: this one sets a
// secret and lists names, and cannot read a value. On the tier groups, so it reaches the vaults of environments that
// do not exist yet.
resource secretWriterRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (operatorSecretWriter) {
  name: guid(subscription().id, slug, 'key-vault-secret-writer')
  properties: {
    roleName: 'Key Vault secret writer (${slug})'
    description: 'Set a secret in the vaults of ${slug} and list secret names, without reading a value: the operator supplies the secrets of a deployable (set-demo-secret.ps1).'
    type: 'CustomRole'
    permissions: [
      {
        actions: []
        notActions: []
        dataActions: [
          'Microsoft.KeyVault/vaults/secrets/setSecret/action'
          'Microsoft.KeyVault/vaults/secrets/readMetadata/action'
        ]
        notDataActions: []
      }
    ]
    assignableScopes: [nonprodGroup.id, prodGroup.id]
  }
}

module nonprodSecretWriter 'modules/role-assignment.bicep' = if (operatorSecretWriter) {
  name: 'seed-${slug}-nonprod-secret-writer'
  scope: nonprodGroup
  params: {
    principalId: deployer().objectId
    principalType: operatorPrincipalType
    roleDefinitionId: secretWriterRole!.name
    description: 'The operator: secret values of the deployables of nonprod (set-demo-secret.ps1)'
  }
}

module prodSecretWriter 'modules/role-assignment.bicep' = if (operatorSecretWriter) {
  name: 'seed-${slug}-prod-secret-writer'
  scope: prodGroup
  params: {
    principalId: deployer().objectId
    principalType: operatorPrincipalType
    roleDefinitionId: secretWriterRole!.name
    description: 'The operator: secret values of the deployables of prod (set-demo-secret.ps1)'
  }
}

// Cross-group grants: the plan identity reads prod and its cost (scripts/write-cost.ps1; every group of the system
// has the same assignment, in its own module), and (with a registry) prod's runtime identities pull from the registry
// in nonprod.
module prodReader 'modules/role-assignment.bicep' = {
  name: 'seed-${slug}-prod-reader'
  scope: prodGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    description: 'id-${slug}-plan: what-if previews and drift checks of prod'
  }
}

module prodCostReader 'modules/role-assignment.bicep' = {
  name: 'seed-${slug}-prod-cost-reader'
  scope: prodGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: '72fafb9e-0641-4937-9268-a91bfd8191a3' // Cost Management Reader
    description: 'id-${slug}-plan: the cost of prod, for the health dashboard'
  }
}

module prodAcrPull 'modules/registry-pull.bicep' = if (hasRegistry) {
  name: 'seed-${slug}-prod-acr-pull'
  scope: nonprodGroup
  params: {
    registryName: nonprod.outputs.registry.name
    principalIds: map(prod.outputs.apps, a => a.principalId)
  }
}

// Runtime aks-argocd: the cluster's identities and ingress IP; the kubelet identity pulls from the registry in nonprod.
module cluster 'modules/seed-cluster.bicep' = if (hasCluster) {
  name: 'seed-${slug}-cluster'
  scope: clusterGroup
  params: {
    slug: slug
    location: location
    tags: union(allTags, { tier: 'cluster' })
    githubIssuer: githubIssuer
    audience: audience
    clusterSubject: '${systemSubjectPrefix}:environment:octopus'
    octopusIssuer: octopusUrl
    feedSubject: 'space:${octopusSpaceSlug}:feed:acr-${slug}'
    planPrincipalId: nonprod.outputs.plan.principalId
    whatIfRoleName: whatIfRole.name
    deployPrincipalIds: [nonprod.outputs.deploy.principalId, prod.outputs.deploy.principalId]
    siteDeployRoleName: siteDeployRole!.name
  }
}

// The nodes, their disks and the load balancer are in the group AKS creates for them: most of what the cluster costs.
// The seed cannot create that group (AKS must), so the grant comes with the first seed that finds it.
resource clusterNodeGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (!empty(clusterNodeResourceGroupName)) {
  name: empty(clusterNodeResourceGroupName) ? 'unused' : clusterNodeResourceGroupName
}

module clusterNodesCostReader 'modules/role-assignment.bicep' = if (!empty(clusterNodeResourceGroupName)) {
  name: 'seed-${slug}-cluster-nodes-cost-reader'
  scope: clusterNodeGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: '72fafb9e-0641-4937-9268-a91bfd8191a3' // Cost Management Reader
    description: 'id-${slug}-plan: the cost of the cluster\'s nodes, for the health dashboard'
  }
}

module clusterAcrPull 'modules/registry-pull.bicep' = if (hasCluster) {
  name: 'seed-${slug}-cluster-acr-pull'
  scope: nonprodGroup
  params: {
    registryName: nonprod.outputs.registry.name
    principalIds: [cluster!.outputs.kubelet.principalId, cluster!.outputs.feed.principalId]
  }
}

output subscriptionId string = subscription().subscriptionId
output tenantId string = tenant().tenantId
output resourceGroups object = union(
  {
    nonprod: nonprodGroup.name
    prod: prodGroup.name
  },
  hasCluster ? { cluster: clusterGroup!.name } : {},
  hasSystemAppEnvironment ? { apps: appsGroup!.name } : {}
)
// azure.appEnvironment "system": the system's Container Apps environment (system.json azure.appEnvironment); {} otherwise.
output appEnvironment object = hasSystemAppEnvironment ? apps!.outputs.appEnvironment : {}
output registry object = nonprod.outputs.registry
output terraformState object = nonprod.outputs.terraformState
output frontDoor object = frontDoor ? edge!.outputs.frontDoor : {}
// Without a registry: registry is {} and identities has no acrPush (as frontDoor is {} without a profile).
output identities object = union(
  {
    plan: nonprod.outputs.plan
    octopusConfig: nonprod.outputs.octopusConfig
  },
  hasRegistry ? { acrPush: nonprod.outputs.acrPush } : {},
  {
    deploy: {
      nonprod: nonprod.outputs.deploy
      prod: prod.outputs.deploy
    }
    apps: concat(nonprod.outputs.apps, prod.outputs.apps)
  },
  hasCluster
    ? {
        cluster: cluster!.outputs.pipeline
        aks: cluster!.outputs.controlPlane
        kubelet: cluster!.outputs.kubelet
        feed: cluster!.outputs.feed
        backup: cluster!.outputs.backupIdentity
      }
    : {}
)
output ingress object = hasCluster ? cluster!.outputs.ingress : {}
output backup object = hasCluster ? cluster!.outputs.backup : {}
