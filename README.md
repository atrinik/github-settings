# Atrinik GitHub settings

[![Project synchronization health](https://github.com/atrinik/github-settings/actions/workflows/check-project-health.yml/badge.svg)](https://github.com/atrinik/github-settings/actions/workflows/check-project-health.yml)

This repository is the source of truth for Atrinik organization settings and
repository rulesets. `bin/publish` uses the GitHub REST API to apply the policy
to every targeted repository in one run.

The same repository owns Atrinik's cross-repository planning system:
organization issue types and fields, the public **Atrinik work** Project and
shared views, scheduled item synchronization, repository custom properties,
and the generated organization community-health repository.

The organization description and canonical website are also governed here.
The public profile README is generated from `community-health/profile/README.md`,
while the six public organization pins remain explicit, read-only-verified
manual state because GitHub exposes no supported pin mutation API.

Atrinik uses GitHub Team. The publisher detects the organization plan and uses
organization-level rulesets on Team or Enterprise. On GitHub Free it installs
equivalent repository-level rulesets instead. Archived repositories are
read-only and are skipped on later runs.

## Policy

- Every active repository protects its default branch from deletion and
  non-fast-forward pushes without a bypass. A separate linear-history rule
  permits organization owners to bypass only through a pull request, preserving
  an audit trail for GitHub's security-advisory merge lifecycle.
- Every active repository uses `main` as its default branch.
- Maintained repositories require changes through pull requests. Organization
  owners may bypass this gate only through a pull request, including the
  temporary private pull request GitHub associates with a security advisory.
- Repositories with reliable CI require checks from the GitHub Actions app.
  Replacement repositories require their proven stable aggregate validation
  job plus `Conventional PR title`; component/platform jobs remain diagnostic
  and are not independent merge gates. The `classic` monorepo requires its
  stable aggregate `Classic validation` and `CodeQL validation` jobs plus
  `Conventional PR title`.
- Declared maintenance branches reject deletion and non-fast-forward updates,
  require linear history and pull requests, and require only checks already
  emitted for that branch.
- Release tags in release-producing repositories cannot be moved or deleted.
- Active services without an established release contract may use
  `release_policy: none` while remaining in the pull-request and required-CI
  inventories; they must be omitted from `release_tags` until that contract
  exists.
- Published releases in the exhaustive `config/immutable-releases.json`
  inventory are owner-enforced immutable releases. The inventory initially
  selects only `atrinik/classic` by its stable repository ID. This organization
  policy is independent of the release-tag ruleset and applies in both
  publisher policy scopes.
- Active repositories allow squash merges only. The squash commit uses the
  pull-request title and description, and merged head branches are deleted.
- Every repository uses an enforced security baseline: dependency graph,
  Dependabot alerts and security updates, secret scanning, push protection,
  validity checks, and private vulnerability reporting remain enabled in both
  security configurations. Ordinary repositories use CodeQL default setup from
  `config/code-security.json`. Repositories in
  `config/codeql-advanced-setup.json` instead receive the otherwise-identical
  `config/code-security-advanced.json` configuration, whose supported
  `code_scanning_options.allow_advanced` setting permits their governed
  component-aware workflow. The publisher explicitly disables default setup
  for those repositories and configures it everywhere else. The ordinary
  baseline remains the default for new repositories.
- Organization members cannot create repositories. Deletion, transfer, and
  visibility changes are recorded as required UI settings because GitHub does
  not expose them through the public API.
- Only organization owners may create teams or install GitHub Apps. Members may
  request GitHub Apps for owner review. These UI-only settings are recorded in
  `config/manual-settings.json`.
- Private GitHub Packages consumed across repositories have explicit,
  read-only workflow grants recorded in `config/manual-settings.json`. Public
  reusable build images instead require anonymous immutable-digest access and
  no consumer grant or package permission. A private-to-public transition is a
  separately reviewed, effectively irreversible owner action that preserves
  the source-repository link.
- GitHub Actions environments that depend on externally issued credentials
  have name-only contracts in `config/manual-settings.json`. The inventory
  records the stable repository identity, exact deployment branch policy and
  reviewer set, and variable and secret names; credential values remain manual
  and are never committed.
- Administrative Actions credentials have value-free lifecycle contracts in
  `config/manual-settings.json`: stable repository identity, secret placement,
  PAT type and scopes, consumers, accountable ownership, verification date,
  rotate-by deadline, cadence, and runbook. Validation rejects expired records
  and any value-like field. `bin/verify-manual-settings` checks credential
  secret-name presence plus inventoried environment identity, deployment
  branches, reviewer rules, and exact secret and variable name sets without
  reading or proving any value.
- Repository-scoped GitHub Apps used by Actions have separate value-free
  lifecycle contracts in `config/manual-settings.json`. The inventory binds
  the stable App and installation IDs, exact permissions and event set,
  intended repository and consumer, credential metadata names, accountable
  owner, verification date, rotation deadline, and runbook. The App private
  key and installation tokens never belong in this repository.
- External provider GitHub Apps have a distinct value-free inventory. Active
  installations bind stable App and installation identities, exact permissions
  and events, exact selected repository IDs, provider purpose, review owner and
  deadline, revocation procedure, and status producer. Planned integrations
  explicitly retain null live IDs, the proposed selected set, and a pending
  owner-UI verification state. Provider credentials and account coordinates
  remain outside GitHub and this repository.
- GitHub Actions defaults to read-only, cannot approve pull requests, and may
  use only Atrinik, GitHub, Codecov coverage, explicitly allowed Docker
  actions, and the exact reviewed crates.io authentication action commit.
- Historical repositories listed in `config/repositories.json` are archived.
  The five former standalone classic component repositories are already
  archived read-only after their history, active work, issues, and release
  metadata were preserved for the `atrinik/classic` transition.
- `config/planning.json` defines one public organization Project, its workflow
  statuses and shared views, enabled issue types, and public organization issue
  fields. New issues enter **Inbox**, pull requests enter **Review**, and the
  pre-existing portfolio enters **Backlog**. Human status changes on open work
  are preserved; closed work converges to **Done**.
- Organization-wide issue forms omit empty optional metadata and the top-level
  `type` key so they pass GitHub's live validator. The Bug and Feature forms
  apply `bug` and `enhancement`; the synchronizer maps those labels to **Bug**
  and **Feature**, while the unlabeled Task form uses the **Task** fallback.
  Parent issues still become **Initiative**, `new feature` remains a recognized
  Feature alias, and existing issue types are never overwritten.
- `config/repository-properties.json` declares a complete taxonomy for active
  and archived repositories: component role, provider set, lifecycle, and
  release policy.
- `community-health/` is the source for organization-wide issue forms,
  pull-request guidance, contribution guidance, conduct policy, and security
  reporting, including the public organization profile.
  `bin/publish-community-health` generates `atrinik/.github` directly from this
  released source; the generated repository is not edited or released
  independently.
- `config/organization.json` owns the game-first organization description and
  preserves `https://atrinik.org` as the canonical website. The publisher
  compares every owned field and patches only when live state differs.
- `config/manual-settings.json` owns the exact public repository pin order:
  `classic`, `atrinik`, `website`, `content`, `protocol`, and `playtester`, with
  stable repository IDs. `bin/verify-manual-settings` reads the ordered pins
  through GraphQL and fails closed on count, identity, visibility, archival, or
  order drift; it never mutates them.

The GitHub REST API does not expose every organization control. The desired
values are recorded in `config/manual-settings.json` and must be confirmed in
the organization UI under **Member privileges**, **Authentication security**,
**GitHub Apps**, each listed repository's **Environments** settings, and each
listed private package's **Manage Actions access** section. Public package
identity, visibility, source association, and anonymous digest access use the
separate checked procedure below. Codecov must be installed for the listed
repositories so their OIDC-authenticated coverage uploads and badges remain
available.

## Usage

Requirements: `git`, `gh`, `jq`, and an authenticated organization-owner
account.

```sh
gh auth refresh -h github.com -s admin:org,project,repo
bin/publish
bin/publish --apply
```

The default invocation prints the operations without changing GitHub. The
`--apply` form is idempotent: existing Atrinik rulesets, immutable-release
selection, and the security configuration are converged to the declared
policy. On Team, the publisher creates organization rulesets before removing
their repository-level equivalents so protection is never absent during
migration. Before changing immutable releases, it snapshots the exact current
organization mode and selected repository IDs. A failed update or verification
automatically restores and verifies that snapshot.

The organization security phase compares GitHub's normalized configuration,
default, and repository-association state before writing. It updates only
drifted configurations and attaches only repositories that are not already
attached or enforced on the intended configuration. This is a correctness
boundary as well as an optimization: GitHub handles attachment as an
asynchronous enablement event, including when an already-associated repository
is submitted again, so a no-op publish must not start a replacement event.

To force the per-repository implementation before or after a downgrade to
GitHub Free, use the retained fallback publisher:

```sh
bin/publish-repositories
bin/publish-repositories --apply
```

This applies merge settings, security features, the inventory-specific CodeQL
setup state, and all rulesets repository by repository. It removes the managed
organization rulesets only after their repository equivalents exist. The
fallback preserves every non-CodeQL security feature for advanced-setup
repositories while converging their default setup to `not-configured`.

The manual `Publish settings` workflow provides the same operation in GitHub
Actions. It requires an `ATRINIK_SETTINGS_TOKEN` repository secret with
organization administration and repository administration access. Never store
that token in this repository.

### Settings automation credential

`ATRINIK_SETTINGS_TOKEN` is a repository-scoped Actions secret on
`atrinik/github-settings`. Its value-free lifecycle record lives in
`config/manual-settings.json`; the current record's `rotate_by` date is an
enforced maximum, not a suggestion. The credential value belongs only in an
approved private credential manager and GitHub Actions.

Provision or rotate it as an Atrinik organization owner:

1. Before the current `rotate_by` date, prepare a pull request that updates
   `last_verified_on` and a new `rotate_by` no later than the declared rotation
   cadence. Keep ownership, consumers, and required scopes accurate.
2. Create a classic PAT with exactly `admin:org`, `project`, and `repo`, an
   expiration no later than the recorded deadline, and organization access if
   GitHub requires separate authorization.
3. Store it without echoing the value:

   ```sh
   gh secret set ATRINIK_SETTINGS_TOKEN --repo atrinik/github-settings
   ```

4. Verify repository identity and secret-name presence, then dispatch only the
   synchronization workflow:

   ```sh
   bin/verify-manual-settings
   gh workflow run sync-project.yml --repo atrinik/github-settings
   gh run list --repo atrinik/github-settings --workflow sync-project.yml --limit 2
   bin/sync-project
   ```

5. Require the manual run to succeed, the read-only plan to report
   `Items to add: 0` and `Total mutations: 0`, and a later scheduled run plus
   Project health check to succeed before revoking the previous credential.

If verification fails, do not run a publisher or expose the token while
debugging. Restore the prior unexpired credential from the approved private
credential manager, or issue a replacement; then repeat the complete check.
For suspected disclosure, revoke the affected PAT immediately, provision a new
one, review Actions logs and organization audit events, and verify every
consumer workflow. `bin/verify-manual-settings` proves only that GitHub exposes
the declared secret name at the stable repository—it cannot inspect the value,
expiry, or effective scopes. The synchronization preflight is the scope and
functionality proof: apply mode verifies the classic PAT's advertised scopes,
Project update capability, and write access for every repository needing an
issue-type change before the first mutation.

### Classic dependency update App

`atrinik-classic-dependency-updater` is an organization-owned GitHub App used
only by the planned `atrinik/classic` consumer workflow
`.github/workflows/update-content.yml`. App ID `4564008` and installation ID
`153045686` are public stable identifiers. The installation selects only
`atrinik/classic`, repository ID `1327289971`, and has exactly these repository
permissions:

- metadata: read;
- contents: write;
- pull requests: write.

The App subscribes to no webhook events and has no Actions, checks,
deployments, environments, issues, packages, secrets, organization
administration, or ruleset-bypass permission. Organization Actions defaults
remain read-only and Actions cannot approve pull-request reviews. The App ID
is stored as the repository Actions variable `DEPENDENCY_UPDATE_APP_ID`; its
private key is stored as the repository Actions secret
`DEPENDENCY_UPDATE_APP_PRIVATE_KEY`. Never commit, print, cache, artifact, or
place either the private key or an installation token in a pull-request body,
step output, command line, fixture, or log.

The public REST response available to the settings administration credential
proves the organization owner, stable App and installation IDs, selected-mode
installation, exact effective permissions, empty event set, and unsuspended
state. GitHub does not expose the installation's exact selected-repository list
to that credential. An organization owner must therefore also inspect
<https://github.com/organizations/atrinik/settings/installations/153045686>
and confirm that the only selected repository is `classic` whenever the record
is created, rotated, or reviewed. `repository_scope_verification` records this
manual boundary; `bin/verify-manual-settings` additionally verifies Classic's
stable repository identity and both credential metadata names without reading
or logging their values.

GitHub App installation access tokens expire after one hour. The consumer must
mint a token only in the branch/PR mutation job, scope it to `classic`, avoid
exporting it beyond the necessary steps, and allow the pinned token action to
revoke it when the job finishes. The automation boundary is the single stable
branch `automation/content-update` and one open pull request from that branch.
Use one non-cancelling concurrency group, `classic-content-update`; a queued
run re-evaluates current state after the prior run completes. A run updates the
existing App-owned branch and PR only when their base, head owner, author, and
changed-path contract are intact. Zero matching PRs permits creation, one
permits refresh, and multiple matches or unexpected commits fail closed.

GitHub has no branch-only App permission: `contents: write`, which is required
to update the automation branch, also authorizes Git-reference and release API
operations. GitHub likewise has no separate create-or-update-PR permission that
excludes review APIs: `pull requests: write` covers both. The App credential
therefore cannot by itself prove that tag, release, or review calls are
technically impossible. Because the App owns its generated pull request, it
cannot provide the distinct human approval required by the ordinary gate, and
it has no bypass. The consumer must never review, approve, merge, tag, publish,
dispatch a release, write the default branch, or change repository settings.
Its reviewed code, exact branch and changed-path checks, ordinary pull-request
gate, protected release-tag rules, workflow contract tests, and audit trail
jointly enforce that operational boundary. Do not describe the credential as
release- or review-incapable; treat any use outside the exact automation branch
and pull-request operations as an incident.

Provision or rotate the key as an Atrinik organization owner:

1. Prepare a reviewed change that advances `last_verified_on` and `rotate_by`
   by no more than the recorded 90-day cadence. Reconfirm the App owner,
   installation ID, Classic-only selection, empty event set, and exact three
   permissions in the GitHub UI before changing credentials.
2. Generate a new App private key while the prior key remains valid. Store the
   complete new PEM in the approved private credential manager and replace the
   `DEPENDENCY_UPDATE_APP_PRIVATE_KEY` repository secret without echoing it.
   Keep `DEPENDENCY_UPDATE_APP_ID` equal to the public numeric App ID.
3. Run `bin/verify-manual-settings`. This proves metadata and name presence,
   not the key value. After the Classic consumer exists, dispatch only
   `update-content.yml` and require one App-authored disposable pull request to
   receive ordinary `Classic validation`, `CodeQL validation`, and
   `Conventional PR title` checks.
4. Confirm the App-authored pull request cannot satisfy its own human approval
   or merge gate, close the disposable pull request, remove its branch, and
   only then delete the previous private key. A later scheduled run must also
   succeed before rotation is considered complete.

For suspected disclosure or misuse, disable the Classic updater workflow,
suspend installation `153045686`, delete the repository secret, and revoke the
affected private key immediately. Review Actions logs, App and organization
audit events, open pull requests, branches, tags, and releases; remove only
verified App-owned disposable state. Rotate to a new key and repeat the full
proof before re-enabling. To revoke permanently, uninstall the App from
Classic, delete its keys plus the repository secret and variable, and reconcile
`config/manual-settings.json` through a reviewed rollback. Do not leave a
credential inventory entry claiming a revoked installation is active.

Read non-secret live metadata and run the complete verifier with:

```sh
gh api orgs/atrinik/installations \
  --jq '[.installations[] | {id, app_id, app_slug, repository_selection, permissions, events, suspended_at}]'
gh api repos/atrinik/classic/actions/secrets \
  --jq '{total_count, names: [.secrets[].name]}'
gh api repos/atrinik/classic/actions/variables \
  --jq '{total_count, names: [.variables[].name]}'
bin/verify-manual-settings
```

If any ID, permission, event, suspension state, selected repository, or
credential name differs, stop. Disable the consumer and reconcile reviewed
desired state before minting another installation token.

## Cloudflare GitHub App

The existing organization installation for the **Cloudflare Workers and
Pages** GitHub App is App ID `85455`, installation ID `152311798`, and selected-
repository mode. Its exact effective GitHub permissions are administration,
checks, contents, deployments, and pull requests write plus metadata read; its
event subscriptions are exactly `pull_request` and `push`. These broad App
permissions are provider-managed GitHub capabilities, not the Cloudflare build
token or runtime authority. Issue
[`atrinik/metaserver-worker#56`](https://github.com/atrinik/metaserver-worker/issues/56)
separately owns the least-privilege Cloudflare identities and provider
connection.

The selected set must be exactly these two stable repositories:

- `atrinik/website`, ID `1327107093`, preserving its existing Pages
  integration; and
- `atrinik/metaserver-worker`, ID `1324297032`, for the serialized Workers
  Builds topology reviewed in metaserver-worker issues 53-56.

No other repository and never **All repositories** is authorized. GitHub's
organization-installations API verifies the public installation identity,
mode, effective permissions, events, organization owner, and suspension state.
It does not give this administrative token an authoritative enumeration of the
selected set, so an organization owner must verify that exact two-repository
set in
<https://github.com/organizations/atrinik/settings/installations/152311798>.
`bin/verify-manual-settings` deliberately reports this remaining manual proof;
it also verifies both repository IDs read-only and never reads a credential
value.

After the metaserver-worker production and review contracts are merged and
validated, a separately authorized organization owner may edit only this
installation: preserve `website`, add only `metaserver-worker`, save selected-
repository mode, and immediately re-open the selection to confirm the exact
two entries. Do not change App permissions, events, the website connection,
repository rulesets, or any unrelated installation. Run
`bin/verify-manual-settings` before and after the UI step and retain the owner
confirmation in the owner-controlled
`atrinik/metaserver-worker#56-private-provider-evidence` record. That stable
coordinate is public governance metadata; the evidence contents remain private
and contain no credential values. `bin/publish` remains plan-only for this
record and never changes installation access.

The App may publish its native Cloudflare check/deployment result. For
`metaserver-worker`, `main` remains the sole automatic production branch and a
normal protected-branch pull-request merge is the routine authorization; do
not add another production branch, an Actions environment approval, a release
or tag gate, Deploy Hook, privileged dispatch, bypass actor, or GitHub Actions
deployment credential. The existing PR-only `main` rule remains unchanged.
The provider's post-merge production result is evidence, not a pre-merge merge
gate. Any review-branch result described by issue #55 must be observed as
stable and unambiguous before a later reviewed governance change can make it a
required check.

Migration or separately authorized control-plane recovery may retry only the
provider build for the exact SHA that is still current `main`. It is not a
GitHub branch-policy bypass: never push a recovery ref, create a second
long-lived production branch, invoke a privileged GitHub dispatch, or weaken
the pull-request gate. If `main` advances, abandon that retry and re-evaluate
the new current revision through the provider-owned recovery contract.

To revoke metaserver access, first disconnect the repository in Cloudflare and
stop its Builds triggers under the recovery procedure owned by #56. Then merge
a reviewed desired-state removal and, with separate organization-owner
authorization, remove only `atrinik/metaserver-worker` from installation
`152311798`. Preserve `atrinik/website` and selected-repository mode. Re-run the
verifier, confirm the website still builds through Pages, and confirm the
metaserver repository no longer appears in the installation UI. Suspending or
deleting the shared installation is not an acceptable metaserver rollback.

## Deploy-control repository and GitHub App

`atrinik/deploy-control` is a public MIT seed repository with stable repository
ID `1352850539`, default branch `main`, and no release-tag or semantic-release
contract. Its desired repository properties are `service`, `replacement`,
`seed`, and `none`. It remains pull-request governed and requires the two
contexts emitted by its current workflows:

- `Deploy-control validation`, from the Check workflow's `npm run check` job;
  and
- `Conventional PR title`, from the Pull Request Policy workflow.

The repository's Dependabot and CodeQL workflows remain enabled, but they are
not merge gates until a stable aggregate check contract exists. The existing
Actions allowlist, read-only default permissions, merge settings, security
baseline, community-health defaults, and Team-compatible rulesets apply. No
Cloudflare resource, package grant, environment, or deployment is part of this
repository registration.

The future control-plane integration is recorded in
`config/manual-settings.json` as the planned GitHub App
`atrinik-deploy-control`. The App and installation do not exist yet: both live
numeric IDs are deliberately `null`, while the control-plane repository is
recorded as `atrinik/deploy-control`, ID `1352850539`. After owner provisioning,
the installation must select exactly one repository, `atrinik/classic`, ID
`1327289971`, and subscribe only to `workflow_run` with these exact read-only
permissions:

- `actions: read`;
- `metadata: read`.

The App is intended to receive successful Classic workflow-run completion for
the reviewed staging-image handoff. It has no authorization for metaserver,
packages, environments, organization-wide selection, source writes, or any
other repository. Its value-free name-only slots are:

- secrets: `DEPLOY_CONTROL_AGENT_ENROLLMENT_SECRET`,
  `DEPLOY_CONTROL_GITHUB_APP_PRIVATE_KEY`, and
  `DEPLOY_CONTROL_GITHUB_WEBHOOK_SECRET`;
- variables: `CLOUDFLARE_ACCOUNT_ID`,
  `CLOUDFLARE_DURABLE_OBJECT_BINDING`, `CLOUDFLARE_WORKER_NAME`,
  `DEPLOY_CONTROL_GITHUB_APP_ID`, and
  `DEPLOY_CONTROL_GITHUB_INSTALLATION_ID`.

These are future secret and variable names only; no values, private key,
installation token, webhook payload, Cloudflare binding, or account credential
is recorded. Atrinik organization owners own the record and review it every 90
days. `atrinik/deploy-control#3` owns the control-plane follow-up and the
provisioning runbook. `repository_scope_verification` remains
`pending_provisioning` until an owner creates the App, installs it in selected
mode, and reads back the exact Classic-only selection in the GitHub UI.

GitHub App creation and installation remain owner-only manual UI operations on
Team. `bin/verify-manual-settings` verifies the stable repository identities and
reports this planned integration as `PENDING`; it does not pretend that an
absent App is live. `bin/publish` remains plan-only for this record and never
creates the App or changes an installation. The existing Cloudflare Workers and
Pages installation and its `atrinik/metaserver-worker` boundary remain
unchanged.

To revoke the future integration, first stop workflow-run delivery and disable
the control-plane consumer, revoke the App keys and webhook secret, remove only
the named control-plane secret and variable slots, uninstall the App from Classic,
and verify the selected set is empty. Preserve the existing Cloudflare
installation and metaserver access record; do not use this runbook to alter
unrelated Apps or repositories.

## Cross-repository planning

Review and apply the planning layers in their dependency order:

```sh
bin/publish-planning
bin/publish-planning --apply
bin/sync-project
bin/sync-project --apply
bin/publish-community-health
bin/publish-community-health --apply
bin/publish-repository-properties
bin/publish-repository-properties --apply
```

`bin/publish-planning` creates or updates organization issue metadata, the
single public Project, its Status options, linked organization fields, and the
six shared views. It reuses the new Project's default `View 1` as **Triage**
and preserves any additional manually created shared views.

`bin/sync-project` is the Team-compatible alternative to Project auto-add
workflows, which are limited to five repository-specific workflows and do not
backfill existing work. It discovers every non-archived repository, adds all
open issues and pull requests, sets intake status only when missing or when
work is reopened, infers only missing issue types, and moves tracked closed
items to **Done**. The scheduled `Synchronize project` workflow requests runs
twice per hour, but GitHub schedules are best-effort and can be delayed or
dropped. The first apply intentionally performs a large one-time backfill;
later runs are incremental and idempotent.

GitHub caps each GraphQL search at 1,000 results. The synchronizer reads the
reported count, requires it to remain stable across pages, and reconciles it
with the exact number of unique returned node IDs. It fails before mutation or
a success summary if either search is inconsistent or exceeds that window; it
must be changed to enumerate or partition the inventory before a larger
organization can be safely synchronized.

`config/planning-health.json` sets a 90-minute maximum freshness age and alerts
after two consecutive failed synchronization runs. The separate
`Project synchronization health` workflow runs on its own schedule, after each
completed synchronization, and on manual dispatch. It uses the ordinary
least-privilege `GITHUB_TOKEN` to read Actions and maintain one deduplicated
health incident, so a missing `ATRINIK_SETTINGS_TOKEN` cannot suppress the
alert. It recognizes only marker-bearing incidents authored by
`github-actions[bot]`, ignores foreign copies of the public marker, and records
a hidden timestamp for each new or reopened outage episode. The administration
PAT is used only for the optional read-only convergence plan.

Inspect health without changing GitHub:

```sh
bin/check-project-health
gh run list --repo atrinik/github-settings \
  --workflow check-project-health.yml --limit 5
```

The health summary reports the last run, last successful run and revision,
age, consecutive failures, and pending Project mutations. A managed incident
opens or updates after the threshold is crossed. It closes only after a newer
successful synchronization in the current outage episode and a zero-mutation
plan. Do not remove its hidden marker or episode timestamp, create one incident
per missed window, or use the administration PAT for alert publication. The
monitoring owner is the Atrinik organization-owner role. If organization-wide
GitHub scheduling itself becomes an unacceptable single point of failure,
provision an external dispatcher/monitor under a separately reviewed owner and
lifecycle contract; the repository workflow does not pretend to provide that
external guarantee.

Retire or replace this monitor only through a reviewed governance change.
Establish and prove the replacement signal first, remove the health workflow's
triggers, then remove its badge, configuration, validator rules, and tests in
the same change. Close any marker-owned incident with a final note pointing to
the replacement; preserve the issue and Actions history rather than deleting
the operational record.

`bin/publish-community-health` creates the public `atrinik/.github` deployment
repository if needed and converges every file listed in
`config/community-health.json`. Local community-health files in a component
repository continue to take precedence over these defaults.

### Organization identity and public pins

Review and deploy organization identity only after the governing pull request
is merged. First inspect both complete plans:

```sh
bin/publish
bin/publish-community-health
```

With separate live-mutation authorization, `bin/publish --apply` converges the
description while preserving the canonical website and the other owned
organization defaults. `bin/publish-community-health --apply` publishes
`community-health/profile/README.md` as `.github/profile/README.md`; never edit
the generated repository directly.

GitHub does not provide a supported public API for organization pins. An
organization owner must open <https://github.com/atrinik>, choose **View as:
Public**, select **Customize pins** in the Pinned section (or **pin
repositories** when the section is empty), select exactly six repositories,
arrange them in this order, and select **Save pins**:

1. `classic`
2. `atrinik`
3. `website`
4. `content`
5. `protocol`
6. `playtester`

After saving, verify the exact live order and stable identities without
mutation:

```sh
bin/verify-manual-settings
```

Do not use browser automation or an undocumented endpoint to apply pins. A
change is complete only after the public organization view renders the profile
README and links correctly and the verifier reports the governed pin order.

`bin/publish-repository-properties` creates the organization property schema
and assigns the complete desired value set to every repository. It runs after
the generated `.github` repository exists so the inventory and live repository
set agree.

`bin/audit` is the read-only live drift check. It compares every active
repository with the merge defaults, custom-property inventory, inherited
organization rulesets, and exposed security baseline. It also fails when an
active repository is missing from the desired-state inventory or when a
governed active repository is absent or archived. The `Governance drift audit`
workflow runs it on the default branch and on a schedule; repository creation
must therefore be followed by a desired-state change before the new repository
can pass the audit.

When creating a repository, register it in `config/repositories.json` and
`config/repository-properties.json` in the same pull request. Add required
status checks only after the repository emits the named workflow jobs. Review
`bin/publish` and `bin/publish-repository-properties` in plan mode, apply them
with the organization settings credential, and finish with `bin/audit`.

The manual `Publish planning` workflow performs those four apply steps in the
same order. Both planning workflows use `ATRINIK_SETTINGS_TOKEN`; in addition
to the existing organization and repository administration access, that token
must have the classic PAT `project` scope. The current GitHub Actions
`GITHUB_TOKEN` cannot administer an organization Project.

GitHub exposes shared Project views through GraphQL but does not expose a
public API for a person's issue-dashboard saved views. The desired personal
views are therefore recorded in `personal_saved_views` in
`config/planning.json`. Each user creates them once at
<https://github.com/issues> using these queries:

- **My issues:** `org:atrinik is:open is:issue assignee:@me`
- **Review requests:** `org:atrinik is:open is:pr review-requested:@me`
- **Mentions:** `org:atrinik is:open mentions:@me`
- **Unassigned issues:** `org:atrinik is:open is:issue no:assignee`

## Adding a repository

Create the repository's `main` branch before applying policy. Default-branch
integrity, merge settings, and security policy are discovered dynamically and
apply to every non-archived organization repository. The Team
security configuration is also the default for newly created repositories.
GitHub's temporary private security-advisory workspaces are the sole discovery
exception: the publisher recognizes their strict `<governed-repository>-ghsa-`
name and disabled collaboration-feature signature and leaves them under
GitHub's advisory lifecycle. A private repository that merely resembles that
name, or whose base repository is not governed, remains in policy scope.
Because integrations and status checks cannot access these workspaces, the
base repository's linear-history, pull-request, and required-CI rules allow
organization-owner bypass in pull-request-only mode. Deletion and
non-fast-forward protections remain non-bypassable.
GitHub does not classify the final advisory-level merge as a pull-request
action. During a specifically authorized Classic advisory merge window,
Classic is split from the shared integrity, linear-history, and pull-request
rules and organization owners receive `always` bypass for those Classic rules
and Classic required CI. GitHub requires every rule reported for the target
branch to be bypassable before enabling the advisory-level merge, including
deletion and non-fast-forward. The window is recorded exhaustively in
`config/advisory-merge-windows.json`, and must be rolled back to an empty
inventory and pull-request-only bypass immediately after the advisory merge.
Add repositories to the appropriate arrays in `config/repositories.json` when
they also need a pull-request gate, required CI, immutable release tags, or
archival.

Immutable releases require a stricter release contract than an immutable tag
alone. Stage repository additions in `config/immutable-releases.json` as pending
activation, then apply only after reviewed workflow qualification proves draft
creation/recovery, complete verified assets, and publication as the final step.
Every registry upload must verify that the actual complete source release is
immutable; a desired inventory entry alone is not publication evidence. Record both the repository name and
the ID reported by GitHub. Validation requires every selected repository to be
active, pull-request governed, and protected by the release-tag ruleset; the
publisher fails closed if a live repository ID differs from the inventory.

Do not add a repository to `config/codeql-advanced-setup.json` merely because
default setup needs tuning. The inventory is reserved for a reviewed advanced
CodeQL workflow that needs repository-specific build, component, or path
coverage. Both security configurations must remain identical except for their
name, description, and `code_scanning_options.allow_advanced` value.

Moving a repository to `archive` is an executable policy change: the next
`bin/publish --apply` makes it read-only. Before applying an archival change,
confirm that remaining pull requests and branches have been preserved at their
new location. For `atrinik/classic`, also complete any intentional tag rebuild
before applying immutable release-tag policy.

## Protecting and retiring a maintenance branch

Add a unique repository/branch entry to `maintenance_branches` in
`config/repositories.json`. Branch names are repository-relative, so `1.x`
becomes the exact ruleset ref `refs/heads/1.x`. Every entry receives deletion,
non-fast-forward, linear-history, and pull-request rules. Its `required_ci`
array may contain only stable checks already declared for that repository and
emitted by workflows on the maintenance branch.

Retired maintenance lines move out of that active array and into
`config/retired-maintenance-branches.json`. The immutable record binds the
stable repository and ruleset IDs, exact final branch commit, final rollback
tag/commit and asset names, and every default-branch/tag ruleset that must stay
active. The targeted publisher refuses missing, ambiguous, or drifted live
state and emits only the exact maintenance-ruleset deletion:

```sh
bin/validate
bin/publish --retire-maintenance content/1.x
```

For the completed content cutover, the final rollback anchor is
`v1.8.19@566bd25f78b80b08d5f75f4b02017ab2429204db`; the preserved retirement
branch tip is `080a9ea41741e4e67adc7b09b3ccb51475d93d3a`. The source archive,
Classic runtime archive, and `SHA256SUMS` must remain accessible and checksum
clean. `content@main` is the sole authored and released source, and the Classic
updater remains justified only for proposing locks to verified main-built
Classic artifacts.

After the desired-state pull request merges, an organization owner may
explicitly authorize this one policy mutation:

```sh
bin/publish --apply --retire-maintenance content/1.x
```

The targeted apply verifies that only ruleset `20571870` is absent and that
the recorded main and immutable-tag protections remain active. It does not
delete the branch. Before deleting `refs/heads/1.x`, repeat the live repository,
ruleset, open-PR, consumer, tag, release, asset, checksum, and reachability
preflight and obtain a second explicit organization-owner authorization for
that exact Git-reference deletion. After deletion, verify the branch is absent
and every preserved tag/release asset and commit remains reachable. Recreating
`1.x` is a new organization-owner recovery decision, not automatic rollback.

On GitHub Team the publisher creates one organization ruleset per maintenance
branch. The repository-policy fallback creates the equivalent repository
ruleset. Both paths remove stale managed maintenance rulesets, and migration
creates the destination protection before deleting the previous scope.

Validate semantic configuration and both publisher scopes when adding or
changing active maintenance protection. For a recorded retirement, additionally
review the targeted plan above before any live authorization:

```sh
bin/validate
for test in tests/*.sh; do "$test"; done
bin/publish
```

## Transitioning a repository to advanced CodeQL

The inventory currently contains only `classic`. GitHub's
[security configuration API](https://docs.github.com/en/rest/code-security/configurations)
represents its exception as **default setup enabled with advanced setup
allowed**. The publisher attaches that configuration only to the inventory,
then uses the
[repository default-setup API](https://docs.github.com/en/rest/code-scanning/code-scanning#update-a-code-scanning-default-setup-configuration)
to set it explicitly to `not-configured`. All other active repositories are
attached to the enforced ordinary baseline and explicitly set to `configured`.

Use this order for the first Classic transition so default and advanced scans
do not compete and a failed handoff cannot become a silent permanent gap:

1. Open the Classic advanced-workflow pull request and let its non-CodeQL
   validation complete. Keep the pull request open; do not merge it while
   repository-wide default setup still controls CodeQL uploads.
2. Merge this governance policy and, while that Classic pull request is ready,
   review `bin/publish` in plan mode and run the explicitly authorized
   `bin/publish --apply`. The plan must attach Classic to the advanced-allowed
   configuration before setting its default setup to `not-configured`, while
   attaching every other active repository to the ordinary baseline and
   setting it to `configured`.
3. Immediately rerun the Classic pull request's advanced CodeQL workflow.
   Confirm every intended component/path partition completes and GitHub accepts
   each CodeQL upload. The short interval after default setup is disabled is an
   observed transition window, not a state that may be left unattended.
4. Merge the Classic workflow only after its advanced analysis is green, then
   confirm a successful advanced analysis on `main` and that no repository-wide
   default CodeQL workflow is scheduled.
5. Only after the Classic workflow is merged and its `CodeQL validation`
   aggregate exists on `main`, merge and apply the governance change that adds
   that context to Classic's required CI. For the initial release-pipeline
   rollout, activate this gate after Classic pull request #20 and before the
   separate phase-two change that enables automatic releases.

If the advanced workflow cannot upload and pass promptly, do not leave Classic
without scheduled analysis. Remove Classic from the inventory in a reviewed
governance change (or revert the exception), run and review the publisher, and
confirm a successful default-setup analysis before rescheduling the migration.
Never delete the advanced workflow first and assume a later policy run will
repair coverage.

## Enabling immutable source releases

The desired organization-level `selected` inventory preserves Classic
(`1327289971`) and adds protocol (`1327106950`), renderer (`1327106998`), and
content-toolkit (`1327107043`). These additions are pending activation until
reviewed source workflows are merged and qualified. Their release producers
must assemble and verify the complete crate/archive/manifest payload on a draft
before publishing it. A published immutable release must be complete because
its tag and assets can no longer be replaced. Before any registry upload, the crate publication helper verifies the actual
source release has `immutable=true`. Ordinary `GITHUB_TOKEN` cannot read the
administrative immutable-settings endpoint, so source workflows do not add an
unsupported pre-tag query or administrative credentials. This inventory is
activated only after reviewed draft-first source qualification.

For protocol, separately verify that the actual immutable pinned
semantic-release GitHub plugin supports the configured draft-first publication
and the complete asset payload. A configured flag alone is not release proof.
Qualification includes build, packaging, draft assembly, retry/recovery,
actual immutable-release upload gating, and publication paths.

Use this narrow rollout order for this release activation:

1. Qualify each reviewed draft-first producer candidate and retain its exact
   revision and validation evidence. Before merging, inspect the three
   Semantic Release workflows, verify no in-flight run, record their original
   enabled states, and temporarily disable only those three workflows. This
   reversible window prevents a first mutable automatic source release while
   immutable policy awaits activation; preserve Classic and all other workflows.
2. Merge the accepted producer and governance source. Run `bin/publish` in
   read-only plan mode and inspect every mutation. The broad plan can include
   unrelated drift, so **do not run `bin/publish --apply` for this activation**.
   Provision crate environments only after their owning workflows are merged.
3. The authorized coordinator verifies the live organization and repository
   identities and snapshots `GET /orgs/atrinik/settings/immutable-releases`
   plus the complete paginated
   `GET /orgs/atrinik/settings/immutable-releases/repositories` selection.
   Normalize the snapshot exactly as `current_immutable_release_payload` in
   `bin/publish`: mode `all`/`none`, or mode `selected` with the complete sorted
   unique selected IDs. Retain the snapshot privately for verified rollback.
4. Derive the targeted payload from the merged desired inventory, adding only
   the three producer IDs and retaining the complete accepted prior selection.
   For this inventory it is `enforced_repositories: selected` and
   `selected_repository_ids: [1327106950,1327106998,1327107043,1327289971]`.
   Require all four current names/IDs to match and preserve Classic. Re-read the
   complete live policy immediately before writing; it must still equal the
   snapshot. Unexpected mode, unknown selection, identity or concurrent drift
   stops activation until the accepted desired state is reconciled.
5. Issue only `PUT /orgs/atrinik/settings/immutable-releases` with that reviewed
   payload through the supported API and the coordinator's existing authority.
   Do not apply repository settings, rulesets, other Actions policy or other
   organization changes from the broad plan. Re-read the organization mode and
   complete selection, require exact equality with the attempted payload, then
   require every selected repository's immutable-release readback to report
   `enabled=true,enforced_by_owner=true`.
6. Restore only the three workflows to their recorded enabled states. Dispatch
   exact merged main as authorized and verify a complete immutable source
   release, its protected-main provenance, and registry readiness before any
   upload or downstream migration.

Readback uses the same supported endpoints as the publisher:

```sh
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  orgs/atrinik/settings/immutable-releases
gh api --paginate -H 'X-GitHub-Api-Version: 2026-03-10' \
  'orgs/atrinik/settings/immutable-releases/repositories?per_page=100' \
  --jq '.repositories[] | [.name, .id]'
for repository in classic protocol renderer content-toolkit; do
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/atrinik/${repository}/immutable-releases"
done
```

If the targeted write or verification fails, keep the producer workflows
suspended and read the policy again. Restore the exact pre-change snapshot only
when the live state still matches the attempted payload in the coordinator's
owned window; verify the complete restored mode and selection before restoring
workflow states. Ambiguous readback or concurrent foreign drift is a stop
condition, not permission to overwrite it. Retain bounded sanitized evidence
and resolve the conflict before retrying. A later intentional policy removal
requires reviewed desired source and the same narrow snapshot/readback/rollback
procedure. Preserve published releases, tags, assets and durable upload intents.

## Provisioning the Classic Discord release environment

The `discord-release` environment is manual desired state for
`atrinik/classic` (repository ID `1327289971`). It permits deployments only
from the selected `main` branch for checked recovery and immutable `v*` tags
for normal releases, has no required reviewers or environment variables, and
contains one value-free secret-name contract:
`DISCORD_APPLICATION_ID`. The Application ID is public package configuration,
but its value remains outside Git so release packaging can be enabled only
through the reviewed environment boundary. `bin/publish` reports this manual
state but does not create, update, or delete it.

Provision it only after the consuming Classic workflow has been merged and
reviewed. From an organization-owner account with repository administration
access, first verify the stable repository identity and default branch:

```sh
gh api repos/atrinik/classic \
  --jq '{id, full_name, archived, default_branch}'
```

Require exactly `id: 1327289971`, `full_name: atrinik/classic`,
`archived: false`, and `default_branch: main`. Before any mutation, check
whether the environment already exists:

```sh
gh api --include -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/atrinik/classic/environments/discord-release
```

Proceed with the creation commands below only when GitHub returns an explicit
`404 Not Found`. Any authentication, authorization, transport, or other error
is a stop condition. If GitHub returns environment metadata, do not run the
`PUT`, `POST`, or `gh secret set` commands: inspect the complete live state
with the read-only verification commands below and reconcile any difference
through a separately reviewed change. The secret command is an upsert, so an
existing same-name secret must not be replaced without separately authorized
rotation.

For a confirmed absent environment, create it with no reviewers, no wait timer,
and an exact custom-branch policy, then provide the initial secret:

```sh
printf '%s\n' '{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}' | gh api --method PUT \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/atrinik/classic/environments/discord-release \
  --input - &&
printf '%s\n' '{"name":"main","type":"branch"}' | \
  gh api --method POST \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    repos/atrinik/classic/environments/discord-release/deployment-branch-policies \
    --input - &&
printf '%s\n' '{"name":"v*","type":"tag"}' | \
  gh api --method POST \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    repos/atrinik/classic/environments/discord-release/deployment-branch-policies \
    --input - &&
gh secret set DISCORD_APPLICATION_ID \
  --env discord-release --repo atrinik/classic
```

Enter the Application ID only at the final prompt; never place it in a shell
argument, environment variable, file in this repository, log, fixture, or pull
request. If either policy creation reports that its exact policy already
exists, stop and verify the complete live state instead of adding a duplicate.

Verify the exact environment contract without reading the secret value:

```sh
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/atrinik/classic/environments/discord-release \
  --jq '{name, deployment_branch_policy, protection_rule_types: [.protection_rules[].type]}'
gh api --paginate -H 'X-GitHub-Api-Version: 2026-03-10' \
  'repos/atrinik/classic/environments/discord-release/deployment-branch-policies?per_page=100' \
  --jq '[.branch_policies[] | {name, type}]'
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/atrinik/classic/environments/discord-release/secrets \
  --jq '{total_count, names: [.secrets[].name]}'
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/atrinik/classic/environments/discord-release/variables \
  --jq '{total_count, names: [.variables[].name]}'
bin/verify-manual-settings
```

Require the environment name to be `discord-release`; the deployment policy
to have custom branch policies enabled and protected-branch mode disabled;
`protection_rule_types` to equal `["branch_policy"]`; the deployment
branch-policy list to equal
`[{"name":"main","type":"branch"},{"name":"v*","type":"tag"}]` (in
either API order); the secret result to equal
`{"total_count":1,"names":["DISCORD_APPLICATION_ID"]}`; and the variable
result to equal `{"total_count":0,"names":[]}`. Finally, run the Classic
release rehearsal and confirm its Discord configuration job is skipped and no
production Application ID appears in rehearsal artifacts. Then run an
explicitly authorized production package workflow for a reviewed release tag
and require its environment-bound configuration job and Windows package
verification to succeed. If any identity, policy, reviewer, name, or count
differs, stop: do not delete or overwrite unknown live settings. Reconcile the
reviewed desired-state contract first, then repeat the complete verification.

## Activating the Classic performance Pages site

`atrinik/classic` (repository ID `1327289971`) owns the provider-managed
`https://atrinik.github.io/classic/` site and the `github-pages` deployment
environment. The environment permits only the exact `main` branch and has no
required reviewers, secrets, or variables. The desired Pages build type is
`workflow`; the consuming workflow is
`.github/workflows/daily-client-performance.yml`, bound by the immutable
`actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e` marker.

The live legacy `main`-root source is a bounded pre-activation state only while
that marker is absent from the default-branch workflow.
`bin/verify-manual-settings` reports it as `PENDING`. Once the reviewed Classic
workflow is merged, the same verifier requires the Actions source and fails on
any lingering legacy source. It never changes the source itself.

Before activation, verify the repository, current Pages site, environment, and
the merged workflow without changing live state:

```sh
gh api repos/atrinik/classic --jq '{id,full_name,archived,default_branch}'
gh api repos/atrinik/classic/pages \
  --jq '{html_url,build_type,source,public,https_enforced,cname}'
gh api repos/atrinik/classic/environments/github-pages \
  --jq '{name,deployment_branch_policy,protection_rule_types:[.protection_rules[].type]}'
gh api --paginate \
  'repos/atrinik/classic/environments/github-pages/deployment-branch-policies?per_page=100' \
  --jq '[.branch_policies[] | {name,type}]'
gh api repos/atrinik/classic/environments/github-pages/secrets \
  --jq '{total_count,names:[.secrets[].name]}'
gh api repos/atrinik/classic/environments/github-pages/variables \
  --jq '{total_count,names:[.variables[].name]}'
gh api 'repos/atrinik/classic/contents/.github/workflows/daily-client-performance.yml?ref=main' \
  --jq -r .content | base64 --decode | \
  grep -F 'actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e'
```

Require the stable repository identity and `main` default branch, exact site
URL, public HTTPS with no custom hostname, the exact custom `main` environment
branch policy, no other protection rule, and empty secret/variable lists. Stop
on any difference. Only after the workflow marker is present on `main`, an
organization owner with repository administration access may switch the exact
site to the Actions source:

```sh
printf '%s\n' '{"build_type":"workflow"}' | gh api --method PUT \
  repos/atrinik/classic/pages --input -
```

Immediately run `bin/verify-manual-settings` and require `KEEP atrinik/classic
Pages uses the reviewed Actions workflow source`. Then dispatch `Daily Classic
client performance` from `main` with checkpoint source `final-benchmark-data`,
verify the attempt-qualified evidence/checkpoint artifacts and successful
`github-pages` deployment, and confirm `https://atrinik.github.io/classic/`,
`trend.json`, `v1/state.json`, and `v1/manifest.json`. Subsequent manual and
scheduled runs must use the default `pages` checkpoint. If activation or the
bootstrap run fails, leave or restore the last known-good Pages deployment,
preserve the final `benchmark-data` commit, and do not delete the historical
branch.

## Retiring a manually inventoried Actions environment

Removing an entry from `github_actions_environments` records the desired
absence but does not delete the live environment or revoke credentials held by
an external provider. Complete every retirement in this order:

1. Merge the reviewed desired-state removal only after the consuming workflow
   has been removed from its default branch.
2. Record the repository's other environment names, delete only the exact
   retired environment through **Settings → Environments**, confirm its API
   lookup returns `404`, and confirm the other environments are unchanged.
3. Remove any exact external DNS, domain, or deployment resource owned solely
   by that environment, preserving unrelated production resources.
4. Revoke the dedicated external-provider token separately and clear retained
   local copies. Deleting a GitHub environment removes its stored secret but
   does not revoke the underlying credential.

`bin/publish --apply` does not provision or delete these manual environments.
Record the exact environment and external-token names in the retirement pull
request handoff without recording their values.

## Public reusable build images

`ghcr.io/atrinik/classic-build` (package ID `14345002`) and
`ghcr.io/atrinik/windows-build` (package ID `14204802`) are public reusable
toolchain images linked to `atrinik/devcontainer`. Their public visibility lets
fork-controlled pull-request workflows consume immutable digests without a
package permission, registry login, repository secret, or cross-repository
**Manage Actions access** grant. Accordingly,
`github_packages_actions_access` contains no entry for either package.

Changing a GitHub Container Registry package from private to public is an
effectively irreversible organization-owner action. Before the change, merge a
reviewed desired-state removal, verify both stable package identities and the
`atrinik/devcontainer` source association, and confirm that every intended
consumer change removes package permissions and registry login. Never change
permission inheritance, detach the source repository, or alter a foreign
Actions-access entry.

Verify the live contract read-only:

```sh
gh api /orgs/atrinik/packages/container/classic-build \
  --jq '{id, name, package_type, visibility, source: .repository.full_name}'
gh api /orgs/atrinik/packages/container/windows-build \
  --jq '{id, name, package_type, visibility, source: .repository.full_name}'
gh api /repos/atrinik/classic \
  --jq '{id, full_name, visibility, archived, default_branch}'
```

Require the exact package IDs above, type `container`, visibility `public`, and
source `atrinik/devcontainer`. Require Classic repository ID `1327289971`,
visibility `public`, `archived: false`, and default branch `main`. An API
failure, missing field, identity mismatch, private package, detached source, or
unexpected state is a stop condition.

Then use a new empty Docker configuration to prove anonymous access to every
consumer-pinned digest:

```sh
anonymous_docker_config=$(mktemp -d)
DOCKER_CONFIG="${anonymous_docker_config}" \
  docker buildx imagetools inspect \
  'ghcr.io/atrinik/classic-build:1.2.3@sha256:d0ec0a31f97fa1d699f62b81bbe697d95b335f44f1c99fde8704dfc528e2102f'
DOCKER_CONFIG="${anonymous_docker_config}" \
  docker buildx imagetools inspect \
  'ghcr.io/atrinik/windows-build:1.2.1@sha256:d1f082eb28891600a9cf018a1d4310b9f3e1f985f82139fa48fbd4ac77b623bb'
```

Both inspections must succeed without `docker login`. The package settings UI
must not list an obsolete `atrinik/classic` Actions-access grant; remove only
that exact entry if it remains after the visibility transition. Finally, run a
real fork pull request and require its digest pulls and complete required
checks to succeed without package permissions or registry authentication.

## Private Linux updater build image

`ghcr.io/atrinik/linux-build` is a private container package, ID `14205615`,
linked to `atrinik/devcontainer` (repository ID `1322185908`). Preserve that
visibility and source association. The owner verified the pinned manifest with
authenticated registry access; the client owning workflow authenticated but
could not resolve that manifest. An owner's successful pull cannot prove a
repository workflow's package access.

`github_packages_actions_access` records read-only Actions-access setup for
`atrinik/client` (`1327106844`) and `atrinik/editor` (`1327106902`). The owner
confirmed those two **Manage Actions access** read grants on 2026-10-11; their
`grant_state` is `owner-observed-read-grant`, with dated sanitized owner evidence.
Effective owning workflow pulls remain pending. This is owner UI observation,
not API enumeration of the grant list. Retain permission inheritance, private
visibility, linked source and every foreign entry. Do not broaden to
organization/all repositories or change a foreign grant. The publisher never
writes these manual grants.

The read-only verifier checks consumer/source identities, exact package ID,
private visibility and linked source. GitHub package metadata does not expose
proof of the manual grant or effective registry access. Future unprovisioned
intent uses `pending-owner-ui-read-grant` with null `observed_on` and
`evidence_location`; observation requires sanitized owner UI readback and dated
evidence. Separately prove each exact merged owning workflow pulls the pinned
manifest and completes its ordinary required validation. Registry login success
and secret-name presence alone are insufficient. Host registry credentials must
be removed before credential-free Cargo/build preparation; the updater App
remains isolated to its PR-writing job. No package grant supplies a
registry-publication token or proves the dependency App key effective.

Rollback stops the owning updater workflows first and removes only these two
read grants through supported owner UI after reviewed inventory removal.
Preserve the package, published versions, source, visibility, foreign grants,
and unrelated App credentials.

## Automatic crate Trusted Publishing

`config/manual-settings.json` records the desired, value-free contracts below.
Automatic source/environment setup remains **pending** until observed.
Protocol registration was owner-observed on 2026-10-11 and its manual 0.2 upload
succeeded in [run 38156755961](https://github.com/atrinik/protocol/actions/runs/38156755961).
That registration does not imply the future automatic source workflow or
zero-review environment is ready: the current protocol environment still uses
the manually approved reviewer policy until the reviewed transition is applied. This change does not register a crates.io publisher, provision an
Actions environment, upload a crate, or install a GitHub App.

| Repository | Stable repository ID | Published libraries |
| --- | --- | --- |
| `atrinik/protocol` | `1327106950` | `atrinik-protocol` |
| `atrinik/renderer` | `1327106998` | `atrinik-render-api`, `atrinik-render-resources`, `atrinik-render-sdl3`, `atrinik-render-testkit`, `atrinik-render-ui`, `atrinik-render-wgpu`, `atrinik-scene` |
| `atrinik/content-toolkit` | `1327107043` | `atrinik-artifact`, `atrinik-catalog`, `atrinik-diagnostics`, `atrinik-schema`, `atrinik-source`, `atrinik-testkit`, `atrinik-transaction` |

Every Trusted Publisher binds the exact repository, `publish-crate.yml`, and
`crates-io-release` environment. Publication runs on protected `refs/heads/main`
through `workflow_dispatch`; the owning hourly reconciliation path dispatches eligible reviewed releases after
credential-free preparation. The release approval is the reviewed source and
version merge. Once onboarding is complete, eligible releases publish without
another release confirmation or environment approval. Hourly schedules are
best-effort; manual reconciliation dispatch remains available.

The desired environment has exactly one selected branch policy, branch `main`,
no required reviewers, zero wait, administrator bypass disabled, and no secret
or variable slots. The actual `main` branch must be protected: a custom branch
pattern alone does not prove that protection. The existing protocol
`crates-io-bootstrap` environment and published 0.1 crate are historical state;
this contract does not modify them. Protocol 0.2 retains its current approved
manual publication path and exact release proof. The generic automatic path
applies to later eligible reviewed versions.

The reviewed selected-actions allowance is
`rust-lang/crates-io-auth-action@*`, so ordinary Dependabot pin updates do not
require a redundant central version change. Actual executable workflows must
use a full immutable SHA for the official action. The initial observed action
reference is `rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18`
(upstream `v1.0.5`); that inventory observation is not a permanent version lock.
The
[pinned official action](https://github.com/rust-lang/crates-io-auth-action/blob/c6f97d42243bad5fab37ca0427f495c86d5b1a18/README.md)
exchanges GitHub OIDC for a temporary crates.io token and revokes it in its
post step. Within `publish-crate.yml`, only the guarded automatic and retained historical
protocol 0.2 upload jobs request
`id-token: write`; crate preparation
and reconciliation have no OIDC permission. The source workflow has a separate
inert manifest-signing job with only contents read, OIDC write and attestation
write; its build and semantic-release jobs have no OIDC. The automatic publisher
requests only contents write for durable upload intent, actions/checks/attestations
read and OIDC write. Only the inert upload helper receives the temporary registry
token and the step-scoped Git-reference intent token; it runs no Cargo, npm or builds. Preserve the other action allowances and GitHub-owned
Actions access. Registry credentials never belong in GitHub secrets, inventory,
workflow inputs, logs, or committed credential files.

The [GitHub environment controls](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
and [crates.io Trusted Publishing documentation](https://crates.io/docs/trusted-publishing)
are the supported provisioning references. Activation proceeds in this order:

1. Qualify and merge governance and owning workflow source using the narrow
   reversible immutable-release activation window above. Run the complete
   `bin/publish` read-only plan and inspect every planned mutation; activate only
   the authorized exact policy through scoped API/UI operations. Preserve
   unrelated live policy and never broad-apply this release delivery.
2. Verify live repository ID/name, active status, default branch, exact main
   ref, protected main, and both merged publication/source-signing workflows. Record
   `source_state: observed-reviewed-workflow` only after that observation.
3. The fourteen renderer and toolkit names above require a first owner-local
   publication because Trusted Publishing cannot create their initial crate
   records. Prepare, review, and verify the exact release archives, package
   dependency order, versions, digests, native prerequisites, and registry
   readiness first. The owner uses a narrowly scoped local API token only for
   that initial bootstrap, then revokes it. Exclude the renderer CLI
   `atrinik-render` and toolkit applications `atrinik-content` and
   `atrinik-content-mcp`. Protocol already exists and needs no bootstrap.
   No bootstrap token is sent to GitHub or stored in this inventory.
4. Provision each `crates-io-release` environment with the exact branch,
   reviewer, wait, bypass, and empty-secret/variable contract. Verify the live
   settings, then record `environment_state: observed` in reviewed source.
5. Use the supported crates.io owner UI to register each listed crate against
   its exact repository, workflow filename, and environment. Capture sanitized
   owner evidence, registration date, and the exact selected identities.
   Record `publisher_registration.state: owner-observed-registration`,
   `observed_on`, and `evidence_location` only after observation. All future
   publication uses OIDC; local API-token publication is not a fallback.
6. Run credential-free readiness and the approved publication paths. Verify
   registry version/checksum visibility and release evidence before downstream
   migration. Later eligible releases reconcile automatically after merge.

`bin/publish` reports this manual setup but never performs it.
`bin/verify-manual-settings` always checks actual repository identity, exact
main ref, and protected main. Pending source/environment/registration states
remain explicit. Observed source parses both `publish-crate.yml` and `release.yml` on the same
exact main revision through
`lib/verify_crate_workflow.py`. Install the declared
`requirements-validation.txt` dependency before local observed-source checks;
the policy and publication workflows install it before verification. The
parser rejects duplicate YAML keys, comment-only/plain text, disabled automatic
jobs, missing OIDC, mutable action refs, extra OIDC jobs, widened guards,
inexact checkout/input bindings, shell/workspace overrides, ignored critical
failures, and skipped verification/auth/upload steps.
It verifies executable dispatch, repository/ID/protected-main conditions,
credential-free dependency, environment, scoped permissions, an unconditional
full-SHA official auth action, and only the returned temporary upload token.
Source qualification also verifies a separate inert signer, successful package
and signer dependencies, exact prepared revision/same-run payload, and the
full-SHA official `actions/attest-build-provenance` action over
`build/release/crate-release.json`. Existing `github_owned_allowed: true` covers
that official action and its internal `actions/attest` dependency; actual refs
stay immutable and ordinary Dependabot updates need no central SHA lock.
Safe schedule reconciliation may coexist; its jobs receive no OIDC. Observed
environments require the exact selected main branch, no reviewer or wait
protection rule, disabled administrator bypass, and empty secret/variable name
metadata. Any identity/protection drift fails closed. The verifier reports
crates.io registration as owner-observed evidence: GitHub metadata cannot prove
external registration, token scope, successful upload, or future readiness.
Runtime qualification belongs to the producer helper. It cryptographically
verifies the actual manifest attestation against the exact repository ID,
protected main source/signer revision, source workflow and run attempt; matching
asset digests alone cannot authenticate uploaded release metadata. It also
requires the actual source release to be immutable before registry upload.
Before each new crate PUT, the inert upload helper atomically creates only the
global `refs/tags/crate-upload-intent/<crate>/<version>` coordinate through the
Git-reference API. Only a successful create response plus exact readback permits
that upload. An existing or ambiguous reservation with an absent registry version
blocks retries, including a retry from another source release; registry absence
alone cannot authorize another PUT. Do not automatically delete/reset these
intents. Reconcile an interrupted upload with owner-observed registry evidence
and the documented producer recovery procedure before any separately reviewed
recovery action. Structural workflow verification does not duplicate runtime
certificate or reservation logic or prove that those live operations succeeded.

Change each pending state only through reviewed source with its corresponding
observation. External registration can be observed before a later automatic
source/environment transition; it does not activate that transition. A status
edit alone cannot prove publication readiness.

Rollback begins by stopping new reconciliation/publication through reviewed
source and revoking the exact crates.io publisher through its supported owner
UI. Review removal of only matching environments/action allowance when no
remaining registered contract needs them. Preserve published crate versions,
release assets, tags, unrelated environments, and unrelated Actions access.
Removing unactivated inventory intent is also a valid reviewed rollback.

## Protocol crate Trusted Publishing

The automatic contract above replaces the former planned per-release
maintainer-review policy. Protocol 0.2 keeps its approved manual release path;
future reviewed source/version merges use the automatic path after observed
onboarding. Protocol registration is owner-observed with the successful manual 0.2 run;
its automatic source/environment transition remains pending. Renderer/toolkit registration remains pending owner actions; the dependency
App is provisioned with workflow activation still pending.

## Crate dependency update App

`crate_dependency_update_app` records owner-observed App setup on 2026-10-11,
while owning workflow activation remains `pending-reviewed-workflows`.
The live App is `atrinik-crate-dependency-update`, App ID `5276152`, installation
ID `170332148`, with **selected repositories** exactly `atrinik/client` (ID
`1327106844`) and `atrinik/editor` (ID `1327106902`). App-authenticated supported
API readback confirmed that complete selected set, exact contents write/pull
requests write/metadata read permissions, no subscribed events, and the external
homepage `https://www.atrinik.org`. Preserve every other App and installation,
including the existing Classic updater and provider Apps. The desired disabled
webhook is a separate owner UI setting; `events: []` proves no subscriptions and
does not independently prove the webhook switch is disabled.

The owner expressly authorized provisioning before the consumer workflows
merge. Each selected repository now has secret name
`CRATE_DEPENDENCY_UPDATE_APP_PRIVATE_KEY` and variable name
`CRATE_DEPENDENCY_UPDATE_APP_ID`; the observed App ID is `5276152`. Name metadata
was verified after creation on 2026-10-11. Never display or copy private-key/token
values or local credential paths into inventory, logs, or public evidence. The
secret value is not readable through GitHub's metadata API, and name presence
cannot prove that a key is valid or effective. These observations do not grant
workflow activation, bypass, self-approval, or self-merge authority.

The read-only verifier checks live installation identity, exact permissions,
empty events, active state, selected repository identities, and credential
**names**. An administrative-token API cannot enumerate the complete selected
repository set; retain current supported App-authenticated readback or owner UI
proof. It reports `credential_state: observed-name-metadata` separately from
workflow activation. Merge both reviewed `released-dependencies.yml` workflows,
then prove effective App credentials with an owned PR and its ordinary required
checks before recording `observed-successful-owned-pr` with dated evidence.
Current activation evidence remains null; an observed setup status alone cannot
prove a successful owning workflow.

The updaters run hourly (`17 * * * *`) and through `workflow_dispatch`. Their
credential-free preparation verifies exact released versions and registry
checksums, resolves dependencies, updates Cargo locks, and runs aggregate
validation before requesting an App token in the isolated PR-writing job. They
maintain only their owned `automation/released-crate-dependencies` branch and
pull request; ordinary required checks and human review still govern merging.
Missing registry readiness produces no migration PR. They never upload crates,
approve a pull request, merge it, or loosen branch protection. Prove initial
App permissions with a disposable/owned PR and current ordinary checks, without
exposing credentials. On retirement, stop these workflows and revoke the
App/key and only the two named repository credential slots; preserve unrelated
installations and secrets.
