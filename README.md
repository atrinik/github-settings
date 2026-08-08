# Atrinik GitHub settings

This repository is the source of truth for Atrinik organization settings and
repository rulesets. `bin/publish` uses the GitHub REST API to apply the policy
to every targeted repository in one run.

The same repository owns Atrinik's cross-repository planning system:
organization issue types and fields, the public **Atrinik work** Project and
shared views, scheduled item synchronization, repository custom properties,
and the generated organization community-health repository.

Atrinik uses GitHub Team. The publisher detects the organization plan and uses
organization-level rulesets on Team or Enterprise. On GitHub Free it installs
equivalent repository-level rulesets instead. Archived repositories are
read-only and are skipped on later runs.

## Policy

- Every active repository protects its default branch from deletion and
  non-fast-forward pushes.
- Every active repository uses `main` as its default branch.
- Maintained repositories require changes through pull requests.
- Repositories with reliable CI require checks from the GitHub Actions app.
  Replacement repositories receive their required-check rules only after their
  bootstrap workflows publish stable aggregate job names; renamed repositories
  retain their established check contracts during the transition. The
  `classic` monorepo requires its stable aggregate `Classic validation` and
  `CodeQL validation` jobs plus `Conventional PR title`; its component-specific
  jobs remain diagnostic and are not independent merge gates.
- Declared maintenance branches reject deletion and non-fast-forward updates,
  require linear history and pull requests, and require only checks already
  emitted for that branch.
- Release tags in release-producing repositories cannot be moved or deleted.
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
  read-only workflow grants recorded in `config/manual-settings.json`. The
  package's visibility, permission inheritance, and source-repository link are
  not changed by these grants.
- GitHub Actions defaults to read-only, cannot approve pull requests, and may
  use only Atrinik, GitHub, Codecov coverage, and explicitly allowed Docker
  actions.
- Historical repositories listed in `config/repositories.json` are archived.
  The five former standalone classic component repositories are already
  archived read-only after their history, active work, issues, and release
  metadata were preserved for the `atrinik/classic` transition.
- `config/planning.json` defines one public organization Project, its workflow
  statuses and shared views, enabled issue types, and public organization issue
  fields. New issues enter **Inbox**, pull requests enter **Review**, and the
  pre-existing portfolio enters **Backlog**. Human status changes on open work
  are preserved; closed work converges to **Done**.
- Unset issue types are inferred conservatively: parent issues become
  **Initiative**, `bug` becomes **Bug**, `enhancement` or `new feature` becomes
  **Feature**, and everything else becomes **Task**. Existing issue types are
  never overwritten.
- `config/repository-properties.json` declares a complete taxonomy for active
  and archived repositories: component role, provider set, lifecycle, and
  release policy.
- `community-health/` is the source for organization-wide issue forms,
  pull-request guidance, contribution guidance, conduct policy, and security
  reporting. `bin/publish-community-health` generates `atrinik/.github`
  directly from this released source; the generated repository is not edited
  or released independently.

The GitHub REST API does not expose every organization control. The desired
values are recorded in `config/manual-settings.json` and must be confirmed in
the organization UI under **Member privileges**, **Authentication security**,
**GitHub Apps**, and each listed package's **Manage Actions access** section.
Codecov must be installed for the listed repositories so their
OIDC-authenticated coverage uploads and badges remain available.

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
items to **Done**. The scheduled `Synchronize project` workflow repeats this
every 30 minutes. The first apply intentionally performs a large one-time
backfill; later runs are incremental and idempotent.

`bin/publish-community-health` creates the public `atrinik/.github` deployment
repository if needed and converges every file listed in
`config/community-health.json`. Local community-health files in a component
repository continue to take precedence over these defaults.

`bin/publish-repository-properties` creates the organization property schema
and assigns the complete desired value set to every repository. It runs after
the generated `.github` repository exists so the inventory and live repository
set agree.

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
Add repositories to the appropriate arrays in `config/repositories.json` when
they also need a pull-request gate, required CI, immutable release tags, or
archival.

Immutable releases require a stricter release contract than an immutable tag
alone. Add a repository to `config/immutable-releases.json` only after its
release workflow creates a draft, uploads and verifies every intended asset,
and publishes the draft as its final step. Record both the repository name and
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

## Protecting a maintenance branch

Add a unique repository/branch entry to `maintenance_branches` in
`config/repositories.json`. Branch names are repository-relative, so `1.x`
becomes the exact ruleset ref `refs/heads/1.x`. Every entry receives deletion,
non-fast-forward, linear-history, and pull-request rules. Its `required_ci`
array may contain only stable checks already declared for that repository and
emitted by workflows on the maintenance branch.

`content/1.x` initially requires `Conventional PR title`, whose unfiltered
pull-request policy already runs for that branch. `Content validation` remains
deliberately absent until the content workflow is enabled and proven on `1.x`;
add it to this entry in that implementation change before applying the tighter
policy.

On GitHub Team the publisher creates one organization ruleset per maintenance
branch. The repository-policy fallback creates the equivalent repository
ruleset. Both paths remove stale managed maintenance rulesets, and migration
creates the destination protection before deleting the previous scope.

Validate semantic configuration and both publisher scopes before reviewing the
live plan:

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

## Enabling immutable releases for Classic

The initial desired state is the organization-level `selected` mode with only
repository ID `1327289971` (`atrinik/classic`). Do not apply it until the
Classic draft-first release workflow is merged and its build, packaging,
retry/recovery, and publication paths have passed on `main`. A published
release must be complete because its tag and assets can no longer be replaced.

Use this rollout order:

1. Merge and verify the Classic release workflow. Confirm it creates or
   recovers a draft, attaches the complete release payload, and publishes only
   after all validation succeeds.
2. Merge this governance policy. Run `bin/publish` and inspect the exact
   `PUT /orgs/atrinik/settings/immutable-releases` payload. It must select only
   `[1327289971]`.
3. With explicit deployment authorization, run `bin/publish --apply`. The
   publisher verifies the organization selection and the repository's
   `enabled=true,enforced_by_owner=true` state before continuing.
4. Confirm the live state independently:

   ```sh
   gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
     orgs/atrinik/settings/immutable-releases
   gh api --paginate -H 'X-GitHub-Api-Version: 2026-03-10' \
     'orgs/atrinik/settings/immutable-releases/repositories?per_page=100' \
     --jq '.repositories[] | [.name, .id]'
   gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
     repos/atrinik/classic/immutable-releases
   ```

If the apply or its verification fails, the publisher automatically sends the
pre-change mode and complete selected-ID set back to GitHub and verifies the
rollback. Preserve its full error output and stop; do not retry with an ad hoc
payload. For a later intentional rollback, review and merge a desired-state
change first, then run the normal plan and explicitly authorized apply flow so
the previous selection is not guessed or partially overwritten.

## Granting Classic access to the Windows build image

The private `ghcr.io/atrinik/windows-build` image is owned by the
`atrinik/windows-build` container package (package ID `14204802`) and remains
linked to `atrinik/devcontainer`. Classic release workflows run from the public
`atrinik/classic` repository (repository ID `1327289971`). They need an
explicit **Read** grant under the package's **Manage Actions access** section;
connecting the package to Classic, changing inherited permissions, making the
package public, or adding a personal access token are not substitutes for this
grant.

Before changing the manual setting, an organization owner with package
administration access must verify the stable identities and the pinned build
image version:

```sh
gh api /orgs/atrinik/packages/container/windows-build \
  --jq '{id, name, package_type, visibility, source: .repository.full_name}'
gh api /repos/atrinik/classic \
  --jq '{id, full_name, visibility, archived, default_branch}'
gh api --paginate \
  '/orgs/atrinik/packages/container/windows-build/versions?per_page=100' \
  --jq '.[] | select(.id == 1107232303) | {id, name, tags: .metadata.container.tags}'
```

The expected values are:

- package `windows-build`, ID `14204802`, type `container`, visibility
  `private`, source `atrinik/devcontainer`;
- repository `atrinik/classic`, ID `1327289971`, visibility `public`, not
  archived, default branch `main`;
- package version ID `1107232303`, digest
  `sha256:9cc373f620a577328fc0a7a7fa823bddaca6d7dc75ac73bcf21be421c49676f7`,
  with tag `1.0.5`.

Open the
[Windows build package settings](https://github.com/orgs/atrinik/packages/container/windows-build/settings),
find **Manage Actions access**, select **Add repository**, add
`atrinik/classic`, and leave its role at **Read**. Do not modify the package's
**Private** visibility, repository source, or permission-inheritance setting.
The public Packages REST API does not expose this workflow-grant list, so the
package settings UI is the authoritative verification surface: it must list
`atrinik/classic` exactly once with **Read** access.

After confirming the UI state, rerun the failed read-only release rehearsal and
inspect both Windows jobs:

```sh
gh run rerun 31239475233 --repo atrinik/classic --failed
gh run watch 31239475233 --repo atrinik/classic --exit-status
gh run view 31239475233 --repo atrinik/classic \
  --json jobs \
  --jq '.jobs[] | select(.name | test("Build Windows (client|server) package$")) | [.name, .conclusion] | @tsv'
```

Both Windows package jobs must succeed, including the digest-pinned
`docker pull`. If they still report `manifest unknown`, recheck the **Manage
Actions access** entry; do not weaken package visibility or add a repository
secret.

To roll back the grant, first merge a reviewed change removing its entry from
`github_packages_actions_access`. Then return to the same package settings,
remove only `atrinik/classic` from **Manage Actions access**, and confirm the
repository is absent while the package remains private and linked to
`atrinik/devcontainer`. No `bin/publish --apply` run is involved in either
direction because this setting has no supported publisher API.
