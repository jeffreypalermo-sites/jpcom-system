# Project variables. The scripts read only these names; every value comes from system.json except GitHub.Token.

locals {
  # One entry per project and variable name; environment = null means unscoped.
  project_ids = merge(
    { system = octopusdeploy_project.system.id },
    { for name, project in octopusdeploy_project.deployable : name => project.id }
  )

  shared_variables = flatten([
    for project, id in local.project_ids : [
      { key = "${project}-slug", project = id, name = "System.Slug", value = local.slug, environment = null },
      { key = "${project}-repository", project = id, name = "System.Repository", value = local.repository, environment = null },
      # The login server of the system's registry (system.json azure.registry), empty without one: only the step
      # "Update deployable" of a container app reads it, and a system that needs no registry has none.
      { key = "${project}-registry", project = id, name = "Azure.RegistryServer", value = try(local.system.azure.registry.loginServer, ""), environment = null },
      { key = "${project}-deployable", project = id, name = "Deployable.Name", value = project == "system" ? "" : project, environment = null },
      # The resource group of the system's Front Door profile (system.json azure.frontDoor), empty without one: the
      # scripts read the environment's endpoints from stack-<slug>-<env>-edge there.
      { key = "${project}-edge", project = id, name = "Azure.EdgeResourceGroup", value = try(local.system.azure.frontDoor.resourceGroup, ""), environment = null },
      [for name, e in local.environments : {
        key         = "${project}-rg-${name}"
        project     = id
        name        = "Azure.ResourceGroup"
        value       = local.system.azure.resourceGroups[e.tier]
        environment = name
      }],
      [for name, e in local.environments : {
        key         = "${project}-principal-${name}"
        project     = id
        name        = "Azure.DeployPrincipalId"
        value       = local.system.azure.identities.deploy[e.tier].principalId
        environment = name
      }],
    ]
  ])

  deployable_variables = flatten([
    for name, d in local.deployables : [
      { key = "${name}-port", project = octopusdeploy_project.deployable[name].id, name = "Deployable.Port", value = tostring(try(d.port, 0)), environment = null },
      { key = "${name}-health", project = octopusdeploy_project.deployable[name].id, name = "Deployable.HealthPath", value = try(d.healthPath, ""), environment = null },
      { key = "${name}-assembly", project = octopusdeploy_project.deployable[name].id, name = "Database.Assembly", value = try(d.databaseAssembly, ""), environment = null },
    ]
  ])

  # Deployable.Secrets: the names of the secrets a deployable declares (deployables[].secrets), joined by commas; step
  # "Update deployable" stops when the app does not reference one of them yet. Only for a deployable that has some.
  secret_variables = [
    for name, d in local.deployables : {
      key         = "${name}-secrets"
      project     = octopusdeploy_project.deployable[name].id
      name        = "Deployable.Secrets"
      value       = join(",", [for s in d.secrets : s.name])
      environment = null
    } if length(try(d.secrets, [])) > 0
  ]

  test_variables = flatten([
    for name, d in local.tested_deployables : [
      { key = "${name}-tests-assembly", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.Assembly", value = d.acceptanceTestsAssembly, environment = null },
      # 0: sized from the worker (1.5 per core, 0.5 GB of memory per browser, at most 16).
      { key = "${name}-tests-workers", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.Workers", value = tostring(try(d.acceptanceTestsWorkers, 0)), environment = null },
      { key = "${name}-tests-delay", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.InputDelayMs", value = "200", environment = null },
      # deployables[].acceptanceTestsFilter: the dotnet test filter of the run after a deployment (for example
      # TestCategory=Smoke); empty runs the full suite. The app's pull requests always run the full suite.
      { key = "${name}-tests-filter", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.Filter", value = try(d.acceptanceTestsFilter, ""), environment = null },
    ]
  ])

  # DataLoader.Assembly: the assembly of ZDataLoader (step "Acceptance tests") and of the demo-employee seeder (step
  # "Seed demo employees") in the acceptance-test package.
  loader_variables = [
    for name, d in merge(local.tested_deployables, local.seeded_deployables) : {
      key         = "${name}-loader-assembly"
      project     = octopusdeploy_project.deployable[name].id
      name        = "DataLoader.Assembly"
      value       = d.dataLoaderAssembly
      environment = null
    }
  ]

  # Per environment, the names of the deployables its stack creates: every hosting but "own", in the environments the
  # deployable exists in (deployables[].environments; without it, all of them).
  stack_deployables = {
    for environment in keys(local.environments) : environment => [
      for name, d in local.deployables : name
      if !contains(keys(local.own_deployables), name) && contains(try(d.environments, [environment]), environment)
    ]
  }

  # Only in a system that has a deployable with hosting "own" (the application brings its own runtime), in the system
  # project. System.OwnDeployables: their names, joined by commas. System.StackDeployables, per environment: the names
  # above; an environment whose stack creates no deployable has no such variable. Step "Verify environment" and the
  # runbook "Health report" pass over a stack that lists nothing only where the first names an application and the
  # second names none; in every other system neither variable exists, and such a stack fails them.
  own_variables = flatten([
    for names in [keys(local.own_deployables)] : concat(
      [{ key = "system-own-deployables", project = octopusdeploy_project.system.id, name = "System.OwnDeployables", value = join(",", names), environment = null }],
      [for environment, created in local.stack_deployables : {
        key         = "system-stack-deployables-${environment}"
        project     = octopusdeploy_project.system.id
        name        = "System.StackDeployables"
        value       = join(",", created)
        environment = environment
      } if length(created) > 0]
    ) if length(names) > 0
  ])

  # Employee.MiddleNames: the environment's employeeMiddleNames as JSON, in the environments that declare some.
  middle_name_variables = [
    for name in local.middle_name_environments : {
      key         = "system-middle-names-${name}"
      project     = octopusdeploy_project.system.id
      name        = "Employee.MiddleNames"
      value       = jsonencode(local.environments[name].employeeMiddleNames)
      environment = name
    }
  ]

  # System.HealthPaths: the health path system.json declares for each container deployable, as JSON
  # ({ "<name>": "<path>" }), in the system project once the runbook "Restart apps" exists. The runbook asks an app that
  # runs a release on that path: the stack's output names "/" for a deployable that had no version at the
  # environment's last apply, and "/" answers while the app's own health check fails.
  health_path_variables = [
    for key in ["system-health-paths"] : {
      key         = key
      project     = octopusdeploy_project.system.id
      name        = "System.HealthPaths"
      value       = jsonencode({ for name, d in local.container_deployables : name => d.healthPath })
      environment = null
    } if length(local.secret_deployables) > 0
  ]

  string_variables = { for v in concat(local.shared_variables, local.deployable_variables, local.secret_variables, local.test_variables, local.loader_variables, local.own_variables, local.middle_name_variables, local.health_path_variables) : v.key => v }
}

resource "octopusdeploy_variable" "string" {
  for_each = local.string_variables

  owner_id = each.value.project
  name     = each.value.name
  type     = "String"
  value    = each.value.value

  dynamic "scope" {
    for_each = each.value.environment == null ? [] : [each.value.environment]
    content {
      environments = [octopusdeploy_environment.this[scope.value].id]
    }
  }
}

# Azure.Account: the tier's OIDC account, scoped to each environment of the tier.
resource "octopusdeploy_variable" "azure_account" {
  for_each = { for pair in setproduct(keys(local.project_ids), keys(local.environments)) : "${pair[0]}-${pair[1]}" => { project = pair[0], environment = pair[1] } }

  owner_id = local.project_ids[each.value.project]
  name     = "Azure.Account"
  type     = "AzureAccount"
  value    = octopusdeploy_azure_openid_connect.deploy[local.environments[each.value.environment].tier].id

  scope {
    environments = [octopusdeploy_environment.this[each.value.environment].id]
  }
}

# GitHub.Token reaches only the steps whose script reads it: in the system project "Apply environment" (the versions
# of versions.json), in a deployable's project "Pin version" and "Revert pin" (the commit to versions.json), for a
# static site "Update deployable" (system.json and the recorded nodes) and, for a deployable with hosting "own",
# "Record nodes" and "Record nodes after revert" (the commit to nodes.json; they run nothing of the application's).
# Octopus hands a variable scoped to steps to no other step and to no runbook. The steps that run an application's
# own scripts ("Update deployable", "Verify deployable", "Revert deployable" and "Verify revert" of such a
# deployable: scripts/invoke-application.ps1) are not among them, and neither are the steps that run an
# application's assemblies (the migration, the seeder, the acceptance tests). A step that starts to read the token is
# added here, and tests/test-token-scope.ps1 in the kit fails until it is; a step that runs code of an application is
# never added.
locals {
  token_steps = merge(
    { system = [octopusdeploy_process_step.system_apply.action_id] },
    {
      for name in keys(local.deployables) : name => concat(
        [octopusdeploy_process_step.pin[name].action_id, octopusdeploy_process_step.revert_pin[name].action_id],
        contains(keys(local.static_deployables), name) ? [octopusdeploy_process_step.deploy_staticwebapp[name].action_id] : [],
        contains(keys(local.own_deployables), name) ? [octopusdeploy_process_step.record_nodes[name].action_id, octopusdeploy_process_step.record_reverted_nodes[name].action_id] : [],
      )
    }
  )
}

resource "octopusdeploy_variable" "github_token" {
  for_each = local.project_ids

  owner_id        = each.value
  name            = "GitHub.Token"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = var.github_token
  description     = "Reads environments/<env>/versions.json from main and, in deployable projects, commits the pin; step Record nodes of a deployable with hosting own commits its nodes (environments/<env>/nodes.json); the dashboard's deployment reads system.json and those nodes with it. Scoped to the steps that read it. From repository secret OCTOPUS_GITHUB_TOKEN."

  scope {
    actions = local.token_steps[each.key]
  }
}

# One task per environment at a time, across both projects and the runbooks: an app deployment, a system deployment
# and a restore test touch the same stack and database, and running them together fails (stack outputs read while the
# stack redeploys, ConflictingDatabaseOperation). Octopus queues tasks that share a concurrency tag.
resource "octopusdeploy_variable" "concurrency_tag" {
  for_each = local.project_ids

  owner_id    = each.value
  name        = "Octopus.Task.ConcurrencyTag"
  type        = "String"
  value       = "#{Octopus.Environment.Id}"
  description = "Serializes deployments and runbook runs per environment across projects."
}
