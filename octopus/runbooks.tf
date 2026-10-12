# Operations runbooks of <slug>-system (environment-level work, run on a schedule):
#   Restore test          weekly, first environment: point-in-time restore into a temporary database (CAP-060);
#                         only in a system with a database
#   Rotate SQL password   monthly, every environment: new administrator password through Key Vault (CAP-056); only
#                         in a system with a database
#   Health report         hourly, every environment: asks every node the environment's stack reports and its public
#                         address, one line each; the last run per environment is the system's health in Octopus
#                         (CAP-076). A deployable with hosting "own" is no node of the stack: the report asks the
#                         nodes its application recorded (environments/<env>/nodes.json, read from the repository's
#                         public address, without a token), once an hour, which wakes a node that scaled to zero; a
#                         record with "healthReport": false is left alone. An environment with nothing to ask says
#                         so and succeeds
#   Failover test         only with a standby region (environments[].standbyLocation): stops the primary app and times
#                         the Front Door endpoint's switch to the standby and back (CAP-047); it may run in every
#                         environment with a standby, and is scheduled monthly in the nonprod ones
#   Restart apps          only with a deployable that declares secrets (deployables[].secrets): restarts the container
#                         apps that read secrets of their own and waits until each answers its health path. A value
#                         the operator wrote to the vault reaches an app when Container Apps reads it, within 30
#                         minutes of the write, not with the restart: the runbook waits that long and says what it
#                         saw. On demand in every environment, never on a schedule
# A schedule runs the runbook's published snapshot; the system workflow publishes one after every apply.
# The instance's task cap is shared by every system on it, so each system's schedules start at its own time: an offset
# of 0 to 239 minutes derived from the slug (the same on every apply), after 07:00 UTC for the restore test and after
# 08:00 UTC for the rotation.

locals {
  first_environment            = local.system.environments[0].name
  schedule_offset              = parseint(substr(md5(local.slug), 0, 6), 16) % 240
  schedule_minute              = local.schedule_offset % 60
  schedule_hours               = floor(local.schedule_offset / 60)
  standby_environments         = [for name, e in local.environments : name if try(e.standbyLocation, "") != ""]
  standby_nonprod_environments = [for name in local.standby_environments : name if local.environments[name].tier != "prod"]
  # A for expression, not a conditional: both branches of a conditional must have the same object type.
  failover_runbook = { for key, runbook in {
    failover_test = {
      name         = "Failover test"
      description  = "Stops the primary app, times the Front Door endpoint's switch to the standby region and back, and starts it again (scripts/test-failover.ps1)."
      script       = "test-failover.ps1"
      environments = local.standby_environments
      scheduled_in = local.standby_nonprod_environments
      cron         = "0 ${local.schedule_minute} ${9 + local.schedule_hours} 2 * *"
      schedule     = "Monthly failover test"
    }
  } : key => runbook if length(local.standby_environments) > 0 }
  secret_deployables = [for name, d in local.container_deployables : name if length(try(d.secrets, [])) > 0]
  restart_runbook = { for key, runbook in {
    restart_apps = {
      name         = "Restart apps"
      description  = "Restarts the latest revision of every container app that reads secrets of its own from the vault (${join(", ", local.secret_deployables)}) and waits until it answers its health path. Container Apps reads a changed vault secret within 30 minutes of the write and restarts the revision itself; the restart does not fetch it, so the run can take that long, and says when an app may still hold the earlier value (scripts/restart-apps.ps1)."
      script       = "restart-apps.ps1"
      environments = [for name, e in local.environments : name]
      scheduled_in = []
      cron         = ""
      schedule     = ""
    }
  } : key => runbook if length(local.secret_deployables) > 0 }
  health_runbook = {
    health_report = {
      name         = "Health report"
      description  = "Asks every node of the environment and its public address whether it answers, one line each with region, time and version; fails when one is not healthy (scripts/report-health.ps1)."
      script       = "report-health.ps1"
      environments = [for name, e in local.environments : name]
      cron         = "0 ${local.schedule_minute} * * * *"
      schedule     = "Hourly health report"
    }
  }
  # The database runbooks exist only in a system with a database: a container deployable that uses one (database is
  # true unless it says false) or an App Service deployable (which shares it), the rule of infra/main.bicep. An app of
  # the person's own (app.source "repository") has none, so there is nothing to restore or rotate.
  has_database = length([
    for name, d in local.deployables : name
    if(try(d.hosting, "containerapp") == "containerapp" && try(d.database, true)) || try(d.hosting, "containerapp") == "appservice"
  ]) > 0
  database_runbooks = { for key, runbook in {
    restore_test = {
      name         = "Restore test"
      description  = "Restores the database to 15 minutes ago into a temporary database, checks it, and deletes it (scripts/test-restore.ps1)."
      script       = "test-restore.ps1"
      environments = [local.first_environment]
      cron         = "0 ${local.schedule_minute} ${7 + local.schedule_hours} * * Sun"
      schedule     = "Weekly restore test"
    }
    rotate_sql_password = {
      name         = "Rotate SQL password"
      description  = "New SQL administrator password through Key Vault; container apps restart and answer their health path. The logins of App Service deployables are not rotated (scripts/rotate-sql-password.ps1)."
      script       = "rotate-sql-password.ps1"
      environments = [for name, e in local.environments : name]
      cron         = "0 ${local.schedule_minute} ${8 + local.schedule_hours} 1 * *"
      schedule     = "Monthly SQL password rotation"
    }
  } : key => runbook if local.has_database }
  runbooks = merge(local.failover_runbook, local.restart_runbook, local.health_runbook, local.database_runbooks)
  # A runbook is scheduled in the environments it may run in, unless it names fewer (scheduled_in); none: no trigger.
  scheduled_runbooks = { for key, r in local.runbooks : key => merge(r, { scheduled_in = try(r.scheduled_in, r.environments) }) if length(try(r.scheduled_in, r.environments)) > 0 }
}

resource "octopusdeploy_runbook" "this" {
  for_each = local.runbooks

  project_id                  = octopusdeploy_project.system.id
  name                        = each.value.name
  description                 = each.value.description
  environment_scope           = "Specified"
  environments                = [for name in each.value.environments : octopusdeploy_environment.this[name].id]
  default_guided_failure_mode = "Off"
  force_package_download      = false
}

resource "octopusdeploy_process" "runbook" {
  for_each = local.runbooks

  project_id = octopusdeploy_project.system.id
  runbook_id = octopusdeploy_runbook.this[each.key].id
}

resource "octopusdeploy_process_step" "runbook" {
  for_each = local.runbooks

  process_id     = octopusdeploy_process.runbook[each.key].id
  name           = each.value.name
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/${each.value.script}")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "runbook" {
  for_each = local.runbooks

  process_id = octopusdeploy_process.runbook[each.key].id
  steps      = [octopusdeploy_process_step.runbook[each.key].id]
}

resource "octopusdeploy_project_scheduled_trigger" "runbook" {
  for_each = local.scheduled_runbooks

  project_id  = octopusdeploy_project.system.id
  space_id    = local.system.octopus.spaceId
  name        = each.value.schedule
  description = "${each.value.name}: ${each.value.description}"
  timezone    = "UTC"
  # While the system is dormant (azure.frontDoor.dormant) nothing asks the apps on a schedule: a call an hour wakes
  # each app, its message bus polls the database, and the database then never pauses.
  is_disabled = each.key == "health_report" && try(local.system.azure.frontDoor.dormant, false)

  cron_expression_schedule {
    cron_expression = each.value.cron
  }

  run_runbook_action {
    runbook_id             = octopusdeploy_runbook.this[each.key].id
    target_environment_ids = [for name in each.value.scheduled_in : octopusdeploy_environment.this[name].id]
  }
}
