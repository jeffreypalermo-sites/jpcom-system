# Provider, inputs and the objects every project shares. Known provider 1.20.0 limits (from the platform this template
# comes from): sort_order 0 counts as unset, and applies run with -parallelism=1.

variable "octopus_access_token" {
  description = "OIDC access token of the system's service account (OctopusDeploy/login sets OCTOPUS_ACCESS_TOKEN)."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub token the deployments commit environments/<env>/versions.json (the pin) and nodes.json (the nodes of an application with its own runtime) with (repository secret OCTOPUS_GITHUB_TOKEN)."
  type        = string
  sensitive   = true
}

variable "test_runner_image" {
  description = "Execution container of the acceptance-test steps (on mcr.microsoft.com): Chromium, pwsh and .NET 8; the step adds .NET 10. Match the Playwright version of the app's AcceptanceTests project."
  type        = string
  default     = "playwright/dotnet:v1.54.0-noble"
}

variable "worker_tools_image" {
  description = "Execution container of every step on Hosted Ubuntu: Azure CLI and PowerShell 7."
  type        = string
  default     = "octopusdeploy/worker-tools:6.6.5-ubuntu.24.04"
}

locals {
  system       = jsondecode(file("${path.module}/../system.json"))
  slug         = local.system.system.slug
  repository   = "${local.system.system.githubOrg}/${local.system.system.repository}"
  environments = { for i, e in local.system.environments : e.name => merge(e, { sort_order = i + 1 }) }
  tiers        = toset([for e in local.system.environments : e.tier])
  deployables  = { for d in local.system.deployables : d.name => d }

  # deployables[].hosting: "containerapp" (default), "appservice" (a web app on the Free plan, zip deployed, with no
  # database of its own) or "staticwebapp" (a site of static files on Azure Static Web Apps: the health dashboard).
  # Only deployables with a databasePackage own the database: they migrate it and, in the prod tier, record a restore
  # point first; an App Service deployable gets a login of its own (system step "Grant database access"); a static
  # deployable has no database access at all.
  container_deployables  = { for name, d in local.deployables : name => d if try(d.hosting, "containerapp") == "containerapp" }
  appservice_deployables = { for name, d in local.deployables : name => d if try(d.hosting, "containerapp") == "appservice" }
  static_deployables     = { for name, d in local.deployables : name => d if try(d.hosting, "containerapp") == "staticwebapp" }
  # deployables[].hosting "own": the application brings its runtime (principle 007). infra/ creates nothing for it;
  # its release carries a package with deploy.ps1 and verify.ps1, which its project runs in every environment
  # (scripts/invoke-application.ps1).
  own_deployables      = { for name, d in local.deployables : name => d if try(d.hosting, "containerapp") == "own" }
  migrated_deployables = { for name, d in local.deployables : name => d if try(d.databasePackage, "") != "" }
  # deployables[].environments: a deployable that exists in some environments only (a container or a static site; the rule
  # is in scripts/test-system.ps1). It gets a lifecycle of its own with those environments, in the system's order, so
  # Octopus offers its releases nowhere else.
  restricted_deployables = { for name, d in local.deployables : name => d if can(d.environments) }
  # Environments whose app deployments run the acceptance tests (system.json environments[].acceptanceTests), and the
  # deployables that ship an acceptance-test package (deployables[].acceptanceTestsPackage).
  test_environments = [for name, e in local.environments : name if try(e.acceptanceTests, false)]
  tested_deployables = length(local.test_environments) == 0 ? {} : {
    for name, d in local.deployables : name => d if try(d.acceptanceTestsPackage, "") != ""
  }
  # Every other environment gets the demo employees from the app's own seeder (step "Seed demo employees", right after
  # "Migrate database"), run from the acceptance-test package of a deployable that owns the database and ships a data
  # loader assembly; in the environments above, ZDataLoader loads the same employees.
  seeded_deployables = {
    for name, d in local.migrated_deployables : name => d
    if try(d.acceptanceTestsPackage, "") != "" && try(d.dataLoaderAssembly, "") != ""
  }
  # Every environment after the first waits for a sign-off by the team "<slug> approvers" (approvers.tf: the people in
  # system.json octopus.approvers; automation answers only with a recorded reason). Prod-tier environments record a
  # restore point first.
  prod_environments    = [for name, e in local.environments : name if e.tier == "prod"]
  nonprod_environments = [for name, e in local.environments : name if e.tier != "prod"]
  # Demo data: environments[].employeeMiddleNames ({ "<user name>": "<middle name>" }); the system step "Set employee
  # middle names" writes them to the environments that declare some.
  middle_name_environments = [for name, e in local.environments : name if length(try(e.employeeMiddleNames, {})) > 0]
  # Deployment freezes from system.json: [{ "name", "start", "end", "environments" (default: the prod tier) }].
  freezes = try(local.system.freezes, [])
}

provider "octopusdeploy" {
  address      = local.system.octopus.url
  space_id     = local.system.octopus.spaceId
  access_token = var.octopus_access_token
}

resource "octopusdeploy_environment" "this" {
  for_each = local.environments

  name                         = each.key
  slug                         = each.key
  description                  = "${each.key} (${each.value.tier}) of ${local.system.system.name}; capabilities: ${join(", ", each.value.capabilities)}. Defined in system.json."
  sort_order                   = each.value.sort_order
  allow_dynamic_infrastructure = false
  use_guided_failure           = false
}

# The first environment deploys automatically; every later one is a manual promotion (an approval in the demo).
resource "octopusdeploy_lifecycle" "system" {
  name        = "${local.slug}-lifecycle"
  description = "Order of the environments in system.json: the first is automatic, the others are promoted by a person."

  dynamic "phase" {
    for_each = local.system.environments
    content {
      name                         = phase.value.name
      automatic_deployment_targets = phase.key == 0 ? [octopusdeploy_environment.this[phase.value.name].id] : []
      optional_deployment_targets  = phase.key == 0 ? [] : [octopusdeploy_environment.this[phase.value.name].id]
    }
  }
}

# A deployable with deployables[].environments: the same order and rule (the first automatic, the others by
# promotion), over its own environments only.
resource "octopusdeploy_lifecycle" "deployable" {
  for_each = local.restricted_deployables

  name        = "${local.slug}-${each.key}-lifecycle"
  description = "The environments ${each.key} exists in (system.json deployables[].environments), in the order of the system: the first is automatic, the others are promoted by a person."

  dynamic "phase" {
    for_each = [for e in local.system.environments : e.name if contains(each.value.environments, e.name)]
    content {
      name                         = phase.value
      automatic_deployment_targets = phase.key == 0 ? [octopusdeploy_environment.this[phase.value].id] : []
      optional_deployment_targets  = phase.key == 0 ? [] : [octopusdeploy_environment.this[phase.value].id]
    }
  }
}

resource "octopusdeploy_project_group" "system" {
  name        = local.slug
  description = "${local.system.system.name}: the environments (${local.slug}-system) and one project per deployable."
}

# One account per tier, restricted to that tier's environments; subjects space/project/environment match the
# federated credentials of id-<slug>-deploy-<tier> that the seed created.
resource "octopusdeploy_azure_openid_connect" "deploy" {
  for_each = local.tiers

  name                              = "azure-${local.slug}-${each.key}"
  description                       = "id-${local.slug}-deploy-${each.key}: applies the environment stacks and updates the apps of ${each.key}."
  application_id                    = local.system.azure.identities.deploy[each.key].clientId
  tenant_id                         = local.system.azure.tenantId
  subscription_id                   = local.system.azure.subscriptionId
  audience                          = "api://AzureADTokenExchange"
  execution_subject_keys            = ["space", "project", "environment"]
  environments                      = [for name, e in local.environments : octopusdeploy_environment.this[name].id if e.tier == each.key]
  tenanted_deployment_participation = "Untenanted"
}

data "octopusdeploy_feeds" "built_in" {
  feed_type = "BuiltIn"
  take      = 1
}

resource "octopusdeploy_docker_container_registry" "docker_hub" {
  name                           = "docker-hub"
  feed_uri                       = "https://index.docker.io"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

resource "octopusdeploy_docker_container_registry" "mcr" {
  name                           = "mcr"
  feed_uri                       = "https://mcr.microsoft.com"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

data "octopusdeploy_worker_pools" "hosted_ubuntu" {
  partial_name = "Hosted Ubuntu"
  take         = 10

  lifecycle {
    postcondition {
      condition     = length([for p in self.worker_pools : p if p.name == "Hosted Ubuntu"]) == 1
      error_message = "The dynamic worker pool 'Hosted Ubuntu' is missing from the space (Octopus Cloud provides it)."
    }
  }
}

locals {
  built_in_feed_id = data.octopusdeploy_feeds.built_in.feeds[0].id
  worker_pool_id   = one([for p in data.octopusdeploy_worker_pools.hosted_ubuntu.worker_pools : p.id if p.name == "Hosted Ubuntu"])
  container = {
    feed_id = octopusdeploy_docker_container_registry.docker_hub.id
    image   = var.worker_tools_image
  }
  test_container = {
    feed_id = octopusdeploy_docker_container_registry.mcr.id
    image   = var.test_runner_image
  }
}
