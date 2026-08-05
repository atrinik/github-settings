# Atrinik GitHub settings

This repository is the source of truth for Atrinik organization settings and
repository rulesets. `bin/publish` uses the GitHub REST API to apply the policy
to every targeted repository in one run.

Atrinik currently uses GitHub Free. GitHub only supports organization-level
rulesets on Team and Enterprise plans, so the publisher installs equivalent
repository-level rulesets on each public repository. Archived repositories are
read-only and are skipped on later runs. The configuration can be consolidated
into organization rulesets after a plan upgrade without changing the policy.

## Policy

- Every active repository protects its default branch from deletion and
  non-fast-forward pushes.
- Maintained repositories require changes through pull requests.
- Repositories with reliable CI require checks from the GitHub Actions app.
- Release tags in release-producing repositories cannot be moved or deleted.
- Organization members cannot create, delete, transfer, or change the
  visibility of repositories.
- GitHub Actions defaults to read-only, cannot approve pull requests, and may
  use only Atrinik, GitHub, and explicitly allowed Docker actions.
- Historical repositories listed in `config/repositories.json` are archived.

The GitHub REST API does not expose the organization controls for requiring
2FA or restricting it to secure methods. Their desired values are recorded in
`config/manual-settings.json` and must be confirmed in **Organization settings
> Authentication security**.

## Usage

Requirements: `gh`, `jq`, and an authenticated organization-owner account.

```sh
gh auth refresh -h github.com -s admin:org
bin/publish
bin/publish --apply
```

The default invocation prints the operations without changing GitHub. The
`--apply` form is idempotent: existing Atrinik rulesets are updated by name and
missing rulesets are created.

The manual `Publish settings` workflow provides the same operation in GitHub
Actions. It requires an `ATRINIK_SETTINGS_TOKEN` repository secret with
organization administration and repository administration access. Never store
that token in this repository.

## Adding a repository

Default-branch integrity is discovered dynamically and applies to every
non-archived organization repository. Add repositories to the appropriate
arrays in `config/repositories.json` when they also need a pull-request gate,
required CI, immutable release tags, or archival.
