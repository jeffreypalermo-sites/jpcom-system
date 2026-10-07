# The projects. <slug>-system applies infra/ to an environment (its releases are commits of this repository, packaged
# by job system-release); <slug>-<deployable> deploys one app release (created by the app repository's release
# workflow). The step scripts live in ../scripts and are read here, so a script change reaches Octopus on the next push.

resource "octopusdeploy_project" "system" {
  name                              = "${local.slug}-system"
  slug                              = "${local.slug}-system"
  description                       = "Environments of ${local.system.system.name}: each release is a commit of ${local.repository}; a deployment applies infra/ to one environment as a deployment stack."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

resource "octopusdeploy_project" "deployable" {
  for_each = local.deployables

  name                              = "${local.slug}-${each.key}"
  slug                              = "${local.slug}-${each.key}"
  description                       = "Deployable ${each.key} from ${local.system.system.githubOrg}/${each.value.repository}: pin, migrate, update, verify."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = contains(keys(local.restricted_deployables), each.key) ? octopusdeploy_lifecycle.deployable[each.key].id : octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

# ---------------------------------------------------------------- <slug>-system

resource "octopusdeploy_process" "system" {
  project_id = octopusdeploy_project.system.id
}

# Every environment but the first: the step excludes the first instead of naming the others, because a release keeps
# the process as it was when the release was created. A release made before an environment existed then still stops
# at the sign-off when it is promoted there.
# Systems synced while the step had a count keep their step instead of losing it and getting a new one.
moved {
  from = octopusdeploy_process_step.system_sign_off[0]
  to   = octopusdeploy_process_step.system_sign_off
}

resource "octopusdeploy_process_step" "system_sign_off" {
  process_id            = octopusdeploy_process.system.id
  name                  = "Sign-off"
  type                  = "Octopus.Manual"
  excluded_environments = [octopusdeploy_environment.this[local.first_environment].id]

  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "false"
    "Octopus.Action.Manual.Instructions"               = "Sign off #{Octopus.Project.Name} #{Octopus.Release.Number} for #{Octopus.Environment.Name}: check the earlier environments, then Proceed with a note, or Abort."
    "Octopus.Action.Manual.ResponsibleTeamIds"         = local.sign_off_team_id
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "False"
  }
}

resource "octopusdeploy_process_step" "system_apply" {
  process_id     = octopusdeploy_process.system.id
  name           = "Apply environment"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    system = {
      package_id           = "${local.slug}-system"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/apply-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "system_verify" {
  process_id     = octopusdeploy_process.system.id
  name           = "Verify environment"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/verify-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Only with an App Service deployable: its database login (scripts/grant-database-access.ps1), right after the apply
# that keeps the login's password in the vault.
resource "octopusdeploy_process_step" "system_grant" {
  count = length(local.appservice_deployables) > 0 ? 1 : 0

  process_id     = octopusdeploy_process.system.id
  name           = "Grant database access"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/grant-database-access.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Only where an environment declares employeeMiddleNames in system.json, and only in those environments: the demo data
# (scripts/set-employee-middle-names.ps1, variable Employee.MiddleNames), after the database logins.
resource "octopusdeploy_process_step" "system_middle_names" {
  count = length(local.middle_name_environments) > 0 ? 1 : 0

  process_id     = octopusdeploy_process.system.id
  name           = "Set employee middle names"
  type           = "Octopus.AzurePowerShell"
  environments   = [for name in local.middle_name_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/set-employee-middle-names.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "system" {
  process_id = octopusdeploy_process.system.id
  steps = concat(
    [octopusdeploy_process_step.system_sign_off.id],
    [octopusdeploy_process_step.system_apply.id],
    [for step in octopusdeploy_process_step.system_grant : step.id],
    [for step in octopusdeploy_process_step.system_middle_names : step.id],
    [octopusdeploy_process_step.system_verify.id],
  )
}

# ---------------------------------------------------------------- <slug>-<deployable>

resource "octopusdeploy_process" "deployable" {
  for_each = local.deployables

  project_id = octopusdeploy_project.deployable[each.key].id
}

resource "octopusdeploy_process_step" "sign_off" {
  for_each = local.deployables

  process_id            = octopusdeploy_process.deployable[each.key].id
  name                  = "Sign-off"
  type                  = "Octopus.Manual"
  excluded_environments = [octopusdeploy_environment.this[local.first_environment].id]

  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "false"
    "Octopus.Action.Manual.Instructions"               = "Sign off #{Octopus.Project.Name} #{Octopus.Release.Number} for #{Octopus.Environment.Name}: check the earlier environments, then Proceed with a note, or Abort."
    "Octopus.Action.Manual.ResponsibleTeamIds"         = local.sign_off_team_id
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "False"
  }
}

# Prod tier: the restore point of the database before the release changes anything (scripts/record-restore-point.ps1).
# The step excludes the nonprod environments instead of naming the prod ones, and is in the process from the start: a
# release keeps the process of its creation, so a release made before prod existed still records its restore point
# there. (Such a release also records one in a nonprod environment added after it, which only adds a log line.)
resource "octopusdeploy_process_step" "restore_point" {
  for_each = local.migrated_deployables

  process_id            = octopusdeploy_process.deployable[each.key].id
  name                  = "Record restore point"
  type                  = "Octopus.AzurePowerShell"
  excluded_environments = [for name in local.nonprod_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id        = local.worker_pool_id
  container             = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/record-restore-point.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Desired state first: the new version is committed to environments/<env>/versions.json before anything changes;
# step "Revert pin" puts the previous version back when a later step fails.
resource "octopusdeploy_process_step" "pin" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Pin version"
  type           = "Octopus.Script"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/pin-version.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "migrate" {
  for_each = local.migrated_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Migrate database"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    database = {
      package_id           = each.value.databasePackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/migrate-database.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Outside the acceptance-test environments: the demo employees from the app's own seeder (scripts/seed-demo-employees.ps1),
# an explicit test of the data loader assembly in the release's acceptance-test package. It only inserts what is missing,
# so it runs on every deployment; in the acceptance-test environments ZDataLoader loads the same employees.
resource "octopusdeploy_process_step" "seed_demo_employees" {
  for_each = local.seeded_deployables

  process_id = octopusdeploy_process.deployable[each.key].id
  name       = "Seed demo employees"
  type       = "Octopus.AzurePowerShell"
  # The test environments excluded, not the others named: a release made before an environment existed seeds it too.
  excluded_environments = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id        = local.worker_pool_id
  container             = local.container

  packages = {
    tests = {
      package_id           = each.value.acceptanceTestsPackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/seed-demo-employees.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Acceptance tests, in the environments with "acceptanceTests": true only: the full suite, or the tests of the
# deployable's acceptanceTestsFilter. "Prepare test runner" starts with "Migrate database" and pulls the test image
# meanwhile; the test steps follow "Revert pin", so a failed test keeps the pin (the version runs) but fails the
# deployment, which blocks its promotion.
resource "octopusdeploy_process_step" "prepare_tests" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Prepare test runner"
  type           = "Octopus.Script"
  start_trigger  = "StartWithPrevious"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.test_container

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/prepare-test-runner.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "open_test_database" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Open test database"
  type           = "Octopus.AzurePowerShell"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/open-test-database.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "acceptance_tests" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Acceptance tests"
  type           = "Octopus.Script"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.test_container

  packages = {
    tests = {
      package_id           = each.value.acceptanceTestsPackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/run-acceptance-tests.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Whenever the database was opened for the tests, also after they failed.
resource "octopusdeploy_process_step" "close_test_database" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Close test database"
  type           = "Octopus.AzurePowerShell"
  condition      = "Variable"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.container

  properties = {
    "Octopus.Step.ConditionVariableExpression" = "#{if Octopus.Action[Open test database].Output.Opened}True#{/if}"
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/close-test-database.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "update" {
  for_each = local.container_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/update-deployable.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# App Service deployables: the release's zip (package <slug>-<deployable> in the built-in feed, not extracted) onto the
# web app the stack created (scripts/deploy-appservice.ps1).
resource "octopusdeploy_process_step" "deploy_appservice" {
  for_each = local.appservice_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    app = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "False"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/deploy-appservice.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Static deployables (the health dashboard): the release's zip (package <slug>-<deployable> in the built-in feed,
# extracted) onto the Static Web App the stack created, with the topology.json the step writes into it
# (scripts/deploy-staticwebapp.ps1).
resource "octopusdeploy_process_step" "deploy_staticwebapp" {
  for_each = local.static_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    site = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/deploy-staticwebapp.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# hosting "own": the application's own deploy.ps1 and verify.ps1, from the package its release carries (the content of
# the application repository's deploy/ folder), run as the tier's deploy identity. Same step names as every other
# deployable, so the lifecycle, the pin and the checks read alike.
resource "octopusdeploy_process_step" "deploy_own" {
  for_each = local.own_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    app = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/invoke-application.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "verify_own" {
  for_each = local.own_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    app = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/invoke-application.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Runs only when an earlier step failed, before "Revert pin": the application's deploy.ps1 again, with the version the
# environment ran before. For any other deployable the next apply of the stack puts the pinned version back; nothing
# of the system's applies an application's own runtime, so without this step a failed verification would leave the
# environment on the release that failed while versions.json names the one before (principle 002).
resource "octopusdeploy_process_step" "revert_own" {
  for_each = local.own_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Revert deployable"
  type           = "Octopus.AzurePowerShell"
  condition      = "Failure"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    app = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/invoke-application.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Every deployable the system's infra/ creates is verified through the stack's outputs; one with hosting "own"
# verifies itself (verify_own above).
resource "octopusdeploy_process_step" "verify" {
  for_each = { for name, d in local.deployables : name => d if !contains(keys(local.own_deployables), name) }

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/verify-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Runs only when an earlier step failed: puts the previous version back into versions.json (scripts/revert-pin.ps1).
resource "octopusdeploy_process_step" "revert_pin" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Revert pin"
  type           = "Octopus.Script"
  condition      = "Failure"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/revert-pin.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "deployable" {
  for_each = local.deployables

  process_id = octopusdeploy_process.deployable[each.key].id
  steps = concat(
    [octopusdeploy_process_step.sign_off[each.key].id],
    contains(keys(octopusdeploy_process_step.restore_point), each.key) ? [octopusdeploy_process_step.restore_point[each.key].id] : [],
    [octopusdeploy_process_step.pin[each.key].id],
    contains(keys(local.migrated_deployables), each.key) ? [octopusdeploy_process_step.migrate[each.key].id] : [],
    contains(keys(local.tested_deployables), each.key) ? [octopusdeploy_process_step.prepare_tests[each.key].id] : [],
    contains(keys(local.seeded_deployables), each.key) ? [octopusdeploy_process_step.seed_demo_employees[each.key].id] : [],
    contains(keys(local.container_deployables), each.key) ? [octopusdeploy_process_step.update[each.key].id] : [],
    contains(keys(local.appservice_deployables), each.key) ? [octopusdeploy_process_step.deploy_appservice[each.key].id] : [],
    contains(keys(local.static_deployables), each.key) ? [octopusdeploy_process_step.deploy_staticwebapp[each.key].id] : [],
    contains(keys(local.own_deployables), each.key) ? [
      octopusdeploy_process_step.deploy_own[each.key].id,
      octopusdeploy_process_step.verify_own[each.key].id,
      octopusdeploy_process_step.revert_own[each.key].id,
    ] : [octopusdeploy_process_step.verify[each.key].id],
    [octopusdeploy_process_step.revert_pin[each.key].id],
    contains(keys(local.tested_deployables), each.key) ? [
      octopusdeploy_process_step.open_test_database[each.key].id,
      octopusdeploy_process_step.acceptance_tests[each.key].id,
      octopusdeploy_process_step.close_test_database[each.key].id,
    ] : [],
  )
}

# ---------------------------------------------------------------- deployment freezes

# One freeze per project and entry of system.json "freezes"; while it runs, Octopus refuses deployments to its
# environments (prod tier unless the entry lists others).
resource "octopusdeploy_project_deployment_freeze" "this" {
  for_each = {
    for pair in setproduct(keys(local.project_ids), range(length(local.freezes))) :
    "${pair[0]}-${local.freezes[pair[1]].name}" => { project = pair[0], freeze = local.freezes[pair[1]] }
  }

  owner_id        = local.project_ids[each.value.project]
  name            = each.value.freeze.name
  start           = each.value.freeze.start
  end             = each.value.freeze.end
  environment_ids = [for name in try(each.value.freeze.environments, local.prod_environments) : octopusdeploy_environment.this[name].id]
}
