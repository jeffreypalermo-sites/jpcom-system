# Octopus configuration of the system (layer 1): environments, lifecycle, Azure OIDC accounts, feeds, and one project
# per deployable plus <slug>-system, with their processes. Everything is read from ../system.json, so adding an
# environment or a deployable there is enough. Applied by job octopus-apply of .github/workflows/system.yml on every
# push to main, as the Octopus service account of the system (GitHub OIDC, OctopusDeploy/login).
#
# State: the account the seed created (system.json azure.terraformState), key octopus.tfstate, Microsoft Entra
# authentication through GitHub OIDC (ARM_USE_OIDC, identity id-<slug>-octopus-config). The backend values are passed
# at init:
#   terraform init -backend-config=resource_group_name=<rg> -backend-config=storage_account_name=<account> \
#     -backend-config=container_name=tfstate -backend-config=key=octopus.tfstate -backend-config=use_azuread_auth=true
#
# The state holds one secret: GitHub.Token (the sensitive variable the pin step uses). The state account allows no
# shared key and no public blob access; only id-<slug>-octopus-config can read it.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "1.20.0"
    }
  }

  backend "azurerm" {}
}
