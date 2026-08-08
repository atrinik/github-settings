# Atrinik GitHub settings

This repository is the source of truth for Atrinik organization settings and
repository rulesets. `bin/publish` uses the GitHub REST API to apply the policy
to every targeted repository in one run.

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
  `classic` monorepo requires its stable aggregate `Classic validation` job
  and `Conventional PR title`; its module-specific jobs remain diagnostic and
  are not independent merge gates.
- Declared maintenance branches reject deletion and non-fast-forward updates,
  require linear history and pull requests, and require only checks already
  emitted for that branch.
- Release tags in release-producing repositories cannot be moved or deleted.
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
- GitHub Actions defaults to read-only, cannot approve pull requests, and may
  use only Atrinik, GitHub, Codecov coverage, and explicitly allowed Docker
  actions.
- Historical repositories listed in `config/repositories.json` are archived.
  The five former standalone classic component repositories are already
  archived read-only after their history, active work, issues, and release
  metadata were preserved for the `atrinik/classic` transition.

The GitHub REST API does not expose every organization control. The desired
values are recorded in `config/manual-settings.json` and must be confirmed in
the organization UI under **Member privileges**, **Authentication security**,
and **GitHub Apps**. Codecov must be installed for the listed repositories so
their OIDC-authenticated coverage uploads and badges remain available.

## Usage

Requirements: `git`, `gh`, `jq`, and an authenticated organization-owner
account.

```sh
gh auth refresh -h github.com -s admin:org
bin/publish
bin/publish --apply
```

The default invocation prints the operations without changing GitHub. The
`--apply` form is idempotent: existing Atrinik rulesets and the security
configuration are updated by name and missing policy is created. On Team, the
publisher creates organization rulesets before removing their repository-level
equivalents so protection is never absent during migration.

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

## Adding a repository

Create the repository's `main` branch before applying policy. Default-branch
integrity, merge settings, and security policy are discovered dynamically and
apply to every non-archived organization repository. The Team
security configuration is also the default for newly created repositories.
Add repositories to the appropriate arrays in `config/repositories.json` when
they also need a pull-request gate, required CI, immutable release tags, or
archival.

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

If the advanced workflow cannot upload and pass promptly, do not leave Classic
without scheduled analysis. Remove Classic from the inventory in a reviewed
governance change (or revert the exception), run and review the publisher, and
confirm a successful default-setup analysis before rescheduling the migration.
Never delete the advanced workflow first and assume a later policy run will
repair coverage.
