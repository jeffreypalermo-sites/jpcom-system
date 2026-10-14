# Who signs off: the space team "<slug> approvers" is the responsible team of every "Sign-off" step (the first step in
# every environment after the first, in every project); a deployable with pipelineSignOff adds a second (below).
# Shared by both runtimes (templates/system-aks/shared-files.txt).
#
# Members: the people in system.json octopus.approvers (Octopus usernames or email addresses; an empty list, or no key,
# means only automation signs off) and the operator identity octopus.operator ("ai-ops" when left out), which answers a
# sign-off only with a recorded reason (invoke-demo-promotion.ps1 -Approve -Reason). Terraform owns the membership:
# a member added in the Octopus UI is drift and the next apply removes it.
#
# Role: the built-in "Project viewer", in this space, unrestricted within it. It is the least built-in role that may
# take responsibility for and answer a manual intervention (InterruptionViewSubmitResponsible: only where the user is in
# the responsible team); everything else it grants is viewing. The service account creates the team and assigns the
# role as a Space Manager (TeamCreate and TeamEdit in the space, UserView and UserRoleView): reference.md, "Who signs
# off".

locals {
  approvers        = try(local.system.octopus.approvers, [])
  operator         = try(local.system.octopus.operator, "ai-ops")
  approver_logins  = distinct(concat([local.operator], local.approvers))
  approver_role_id = "userroles-projectviewer"
}

# One lookup per login: Octopus filters users by username, display name or email; exactly one must match the username
# or the email address.
data "octopusdeploy_users" "approver" {
  for_each = toset(local.approver_logins)

  filter = each.key
  take   = 100

  lifecycle {
    postcondition {
      condition     = length([for u in self.users : u.id if lower(u.username) == lower(each.key) || lower(u.email_address != null ? u.email_address : "") == lower(each.key)]) == 1
      error_message = "No single Octopus user has the username or email address '${each.key}' (system.json octopus.approvers or octopus.operator). An Octopus administrator invites the person first, or the entry is corrected."
    }
  }
}

data "octopusdeploy_user_roles" "approver" {
  ids = [local.approver_role_id]

  lifecycle {
    postcondition {
      condition     = length([for r in self.user_roles : r.id if contains(r.granted_space_permissions, "InterruptionViewSubmitResponsible")]) == 1
      error_message = "The built-in role ${local.approver_role_id} no longer grants InterruptionViewSubmitResponsible, so the approvers could not sign off. Choose the least role that does (GET /api/userroles) in the kit, and record why in reference.md."
    }
  }
}

locals {
  approver_user_ids = distinct([
    for login in local.approver_logins : one([
      for u in data.octopusdeploy_users.approver[login].users : u.id
      if lower(u.username) == lower(login) || lower(u.email_address != null ? u.email_address : "") == lower(login)
    ])
  ])
  sign_off_team_id = octopusdeploy_team.approvers.id
}

resource "octopusdeploy_team" "approvers" {
  name        = "${local.slug} approvers"
  description = "Sign off the promotions of ${local.system.system.name} (step Sign-off): the people in system.json octopus.approvers, and ${local.operator} for automation with a recorded reason. Role Project viewer in this space. Managed by octopus/ of ${local.repository}."
  space_id    = local.system.octopus.spaceId
  users       = local.approver_user_ids
}

resource "octopusdeploy_scoped_user_role" "approvers" {
  team_id      = octopusdeploy_team.approvers.id
  space_id     = local.system.octopus.spaceId
  user_role_id = one(data.octopusdeploy_user_roles.approver.user_roles).id
}

# The pipeline's own sign-off (decision 0048): a deployable with "pipelineSignOff": true in system.json may also be
# signed off by the system's service account <slug>-github, which a workflow of the system repository then answers
# with a reason naming its run. The team "<slug> pipeline sign-off" holds that account alone and is a second
# responsible team of those deployables' Sign-off only; every other Sign-off stays the approvers' alone. Its role is
# Project viewer, as the approvers', in those deployables' projects only. The team exists only while a deployable
# asks for it; octopus.approvers itself never names the service account (scripts/test-system.ps1).

locals {
  pipeline_sign_off = toset([for d in local.system.deployables : d.name if try(d.pipelineSignOff, false) == true])
  pipeline_login    = "${local.slug}-github"
}

data "octopusdeploy_users" "pipeline" {
  count = length(local.pipeline_sign_off) > 0 ? 1 : 0

  filter = local.pipeline_login
  take   = 100

  lifecycle {
    postcondition {
      condition     = length([for u in self.users : u.id if lower(u.username) == local.pipeline_login]) == 1
      error_message = "No single Octopus user has the username '${local.pipeline_login}', the system's service account that a deployable with pipelineSignOff lets sign off."
    }
  }
}

resource "octopusdeploy_team" "pipeline_sign_off" {
  count = length(local.pipeline_sign_off) > 0 ? 1 : 0

  name        = "${local.slug} pipeline sign-off"
  description = "Signs off the promotions of ${join(", ", sort(tolist(local.pipeline_sign_off)))} (step Sign-off) as the pipeline, with a reason naming the workflow run: system.json deployables[].pipelineSignOff, decision 0048. Its only member is ${local.pipeline_login}. Managed by octopus/ of ${local.repository}."
  space_id    = local.system.octopus.spaceId
  users       = [one([for u in data.octopusdeploy_users.pipeline[0].users : u.id if lower(u.username) == local.pipeline_login])]
}

resource "octopusdeploy_scoped_user_role" "pipeline_sign_off" {
  count = length(local.pipeline_sign_off) > 0 ? 1 : 0

  team_id      = octopusdeploy_team.pipeline_sign_off[0].id
  space_id     = local.system.octopus.spaceId
  user_role_id = one(data.octopusdeploy_user_roles.approver.user_roles).id
  project_ids  = [for name in sort(tolist(local.pipeline_sign_off)) : octopusdeploy_project.deployable[name].id]
}

locals {
  # The responsible teams of each deployable's Sign-off, as Octopus stores them: team ids joined by commas.
  sign_off_team_ids = {
    for name, d in local.deployables : name => join(",", concat(
      [local.sign_off_team_id],
      contains(local.pipeline_sign_off, name) ? [octopusdeploy_team.pipeline_sign_off[0].id] : [],
    ))
  }
}
