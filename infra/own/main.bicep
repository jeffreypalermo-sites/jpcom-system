// What this system adds to an environment of its own: resources the kit's template does not have. This file and
// its folder (infra/own/) belong to the system: the kit puts the file here once, as it is now (it creates nothing),
// and no template sync changes it afterwards. ../main.bicep calls it in every environment, inside the environment's
// deployment stack, so what it creates is applied, previewed, protected and removed like the environment's other
// resources. Removing a resource from this file deletes it, with its data, at the next apply.
// The kit's catalog has entries to start from (the kit's .claude/skills/demo-environment/catalog/).
targetScope = 'resourceGroup'

@description('The environment this runs in, from ../main.bicep: the system\'s slug, the environment\'s name, the system\'s region, the tags of every resource, and the identity of each container deployable that has one of its own (one that declares secrets in system.json): its name, and the principal ID, client ID and resource ID of id-<slug>-<env>-<deployable>.')
#disable-next-line no-unused-params // The system uses it when it adds a resource.
param stack {
  slug: string
  environmentName: string
  location: string
  tags: object
  identities: {
    deployable: string
    principalId: string
    clientId: string
    resourceId: string
  }[]
}

@description('Settings for container deployables, by deployable and then by name: { "<deployable>": { "<NAME>": "<value>" } }. Each becomes an environment variable of that deployable\'s container app. Never a secret: a value here is readable in the deployment.')
output settings object = {}
