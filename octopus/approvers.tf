# Who signs off: the space team "<slug> approvers" is the responsible team of every "Sign-off" step (the first step in
# every environment after the first, in every project). Shared by both runtimes (templates/system-aks/shared-files.txt).
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
