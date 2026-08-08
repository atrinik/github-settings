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
- Every repository uses the enforced security baseline in
  `config/code-security.json`: dependency graph, Dependabot alerts and security
  updates, CodeQL default setup, secret scanning, push protection, validity
  checks, and private vulnerability reporting. The same baseline is the
  default for new repositories.
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
  The former standalone classic component repositories are archived only after
  their history, active work, issues, and release metadata have been preserved
  in `atrinik/classic`.

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

This applies merge settings, security features, CodeQL default setup, and all
rulesets repository by repository. It removes the managed organization
rulesets only after their repository equivalents exist.

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
tests/publish-maintenance-branch.sh
bin/publish
```
