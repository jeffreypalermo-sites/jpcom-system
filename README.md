# System repository (GitOps)

This repository is the desired state of a whole software system: which environments exist, what Azure resources each one has, and which version of each deployable runs where. App code lives in the app repositories. Their builds publish versioned artifacts that this repository points to.

Every change to an environment is a pull request here:
- the pull request previews what would change in Azure;
- merging it applies the change through Octopus;
- a check proves the result.

## What lives where

| Path | What | Written by |
|---|---|---|
| `system.json` | The system: slug, Azure and Octopus identifiers, the deployables, the environments with their tier and capabilities | People, by pull request |
| `environments/<env>/versions.json` | The version of each deployable in that environment, `{}` before the first deployment | Octopus only (step "Pin version"), straight to `main` |
| `infra/` | Bicep for one environment: `main.bicep` reads `system.json`; `modules/` holds one module per capability | People, by pull request |
| `octopus/` | Terraform for the Octopus configuration, also read from `system.json` | People, by pull request |
| `scripts/` | The Octopus step scripts and the checks | People, by pull request |
| `docs/architecture/` | The architecture after each phase of the demo-environment skill: C4-PlantUML sources and rendered PNG files | The operator, by pull request after each phase |
| `bootstrap/seed.bicep` | The resource groups, registry, state account and identities. Applied once by the operator, never by a pipeline | The operator |

## Pipelines

| Workflow | When | What |
|---|---|---|
| `env-checks` | Every pull request | Required check: `system.json` rules, Bicep build, Terraform format and validate. A what-if preview per environment appears in the job summary, but doesn't block |
| `system` | Every merge to `main`, except pin commits | Configures Octopus from `octopus/`, packages the commit, then creates a release of `<slug>-system`. Octopus deploys it to the first environment automatically and to later ones on promotion |
| `drift` | Nightly | What-if of `main` against every environment; the run turns red when an environment differs from Git |

In Octopus, two kinds of project run against these environments:
- **`<slug>-system`** applies `infra/` to one environment as the deployment stack `stack-<slug>-<env>`. Deny settings block changes from anyone except the deploy identity.
- **`<slug>-<deployable>`** deploys one app release in four steps:
  1. pin the version in Git;
  2. migrate the database;
  3. update the container app;
  4. verify.

## Common changes

| Change | Edit |
|---|---|
| Add an environment | Append it to `environments` in `system.json` with its tier, and add `environments/<env>/versions.json` containing `{}`. After the merge, promote the new `<slug>-system` release to it in Octopus, then promote the app release |
| Add a capability | Add its name to the environment's `capabilities`; a new capability also adds `infra/modules/<capability>.bicep` and one condition in `infra/main.bicep` (see `telemetry`) |
| Add a deployable | Append it to `deployables` in `system.json`. A new project `<slug>-<name>` appears in Octopus, and the new app repository's release workflow creates its releases. Its `hosting` says where it runs: `containerapp` (a container app, when left out), `appservice` (a web app on the tier's Free plan, deployed as a zip) or `staticwebapp` (a site of static files on Azure Static Web Apps: the health dashboard, whose deployment writes the list of nodes it shows) |
| Keep a deployable to some environments | Add `environments` to a container deployable in `system.json`: the list of environments it exists in, the first environment among them. The others get none of its resources, and its Octopus project gets a lifecycle of its own with only those environments |
| Keep a background service running | `"alwaysOn": true` on a container deployable: exactly one replica, never zero. `"cpu"` (`"0.5"`, `"1"`, `"1.5"`, `"2"`) gives it a size of its own, and `"database": false` leaves the SQL connection string out |
| Change an app's settings | `settings` on a container deployable (`{ "<environment variable>": "<text>" }`), and `environmentSettings` (`{ "<environment>": { ... } }`) for what differs in one environment; `urlSetting` names the variable that gets the app's own public address. They reach an environment when the `<slug>-system` release is deployed there |
| Give an app a secret | Add `{ "name": "<secret>", "env": "<environment variable>" }` to the deployable's `secrets`. Never a value: the operator writes it to the environment's vault first (the kit's `set-demo-secret.ps1`), as the secret `<deployable>-<secret>`, and the app reads it by reference. With `"generate": true` the deployment creates the value itself. "Apply environment" stops while a deployable that runs a version lacks a secret. After changing a value, run the runbook "Restart apps" |
| Choose the acceptance tests after a deployment | Add `acceptanceTestsFilter` to the deployable in `system.json`: a `dotnet test` filter such as `"TestCategory=Smoke"`. The step "Acceptance tests" then runs only those tests (the app's pull requests still run the full suite); a filter that runs no test fails the step. A release snapshots the process, so the change reaches the releases created after the merge: `gh workflow run Build --ref master` in the app repository makes one |
| Set employee middle names (demo data) | Add `employeeMiddleNames` (`{ "<user name>": "<middle name>" }`) to the environment in `system.json`. The `<slug>-system` step "Set employee middle names", present only in environments that declare some, writes them to that environment's database when the release is deployed there |
| Change who signs off | Edit `octopus.approvers` in `system.json`: the Octopus usernames or email addresses of the people in the team `<slug> approvers`, the responsible team of every "Sign-off" step (`[]`: only automation signs off). Each must already be an Octopus user. The operator identity (`octopus.operator`) stays in the team for sign-offs with a recorded reason |
| Remove an environment | Delete it from `system.json` and its folder, and delete its stack (`az stack group delete --action-on-unmanage deleteResources`) |

Local check before a pull request: `pwsh -NoProfile -File scripts/test-system.ps1`.
