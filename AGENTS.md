# Atrinik GitHub settings repository guide

- This repository is the desired-state source for Atrinik organization
  repositories, rulesets, merge policy, Actions policy, and manual governance
  settings. It also owns organization issue metadata, the shared Project and
  synchronization contract, repository custom properties, and generated
  community-health defaults. It does not own component implementation.
- Atrinik uses GitHub Team. Keep organization controls Team-compatible and
  record unavailable or manual settings explicitly rather than pretending they
  were applied.
- Read `README.md`, `CONTRIBUTING.md`, all affected `config/*.json`, and the
  publisher before changing policy. Keep repository inventories, archived
  status, default branches, rulesets, required checks, merge methods, Actions
  allowlists, and security settings coherent.
- Run `bin/publish` in plan mode first and review its entire diff. `--apply`
  mutates live organization state and requires explicit authorization; never
  use it as routine validation.
- Apply planning state only in the documented dependency order: plan and apply
  `bin/publish-planning`, then `bin/sync-project`,
  `bin/publish-community-health`, and finally
  `bin/publish-repository-properties`. Each script is plan-only by default and
  needs the same explicit live-mutation authorization for `--apply`.
- Keep Project synchronization conservative and idempotent. Add every open
  issue and pull request from non-archived repositories, preserve a person's
  status on open work, set intake status only when absent or reopened, infer
  only missing issue types, and converge tracked closed work to `Done`. Do not
  infer Priority, Effort, or dates from weak signals.
- Atrinik uses the central synchronizer instead of Team's five-workflow
  Project auto-add limit. The scheduled workflow and one-time backfill require
  `ATRINIK_SETTINGS_TOKEN` to have the classic PAT `project` scope as well as
  the existing organization and repository administration scopes. Personal
  issue-dashboard saved views remain documented manual state because GitHub
  exposes no public API for them.
- Keep every administrative Actions credential value out of Git. Inventory its
  stable repository, secret placement, scopes, consumers, accountable owner,
  verification date, rotate-by deadline, cadence, and runbook in
  `config/manual-settings.json`. Run `bin/verify-manual-settings` to check only
  live name/identity metadata, then prove permissions with the owning workflow;
  never claim the metadata API verifies a value, expiry, or effective scope.
- Keep Project apply preflight ahead of every mutation: require the advertised
  classic-PAT scopes, Project update capability, repository write access for
  issue-type changes, and a stable result count exactly matching unique nodes
  within GitHub's 1,000-item search window. Exceeding a capability or inventory
  boundary fails closed.
- Treat GitHub cron as best-effort. Preserve the separate Project health
  workflow, its configured freshness and consecutive-failure thresholds, and
  its single bot-authored, marker-owned incident and outage-episode timestamp.
  Alert with the ordinary least-privilege `GITHUB_TOKEN` so an absent
  administration PAT remains reportable; resolve only after a newer successful
  sync in the current episode and a converged zero-mutation plan.
- `community-health/` is authoritative; `atrinik/.github` is a generated
  deployment target. Never hand-edit that repository, add independent release
  automation to it, or add its issue forms' `projects:` key: public
  contributors may not have the Project write permission that key requires.
- Keep the game-first organization description and canonical website in
  `config/organization.json`, and publish them only on real drift. Keep the
  generated public profile in `community-health/profile/README.md`. Record the
  six ordered public pins with stable repository IDs in
  `config/manual-settings.json`, verify them read-only through GraphQL, and use
  the documented organization-owner UI step instead of an undocumented writer.
- Keep required workflow job names synchronized with rulesets. Workflow or
  permissions changes also require actionlint, least-privilege review, and
  immutable action references according to policy.
- Keep default-branch deletion and non-fast-forward rules non-bypassable during
  normal operation. Isolate the organization-owner security-advisory exception
  to the explicitly authorized window, and use pull-request-only bypass mode
  outside that window so direct pushes never inherit the exception.
- A specifically authorized Classic advisory merge may temporarily split
  Classic from those shared rules and use organization-owner `always` bypass.
  Keep that window Classic-only, include the integrity rules only because
  GitHub requires every reported rule to be bypassable for the advisory merge,
  record it only in `config/advisory-merge-windows.json`, and merge and apply
  the reviewed empty-inventory rollback immediately after the advisory merge.
- Declare protected non-default lines in `maintenance_branches`. Give each
  repository/branch pair a unique entry, and require only status checks that
  the branch's workflows already emit. Validate both Team organization rulesets
  and the retained repository-level fallback when changing this contract.
- Preserve the selected-actions entry for Codecov and the manual GitHub App
  repository-access inventory while coverage uploads use OIDC authentication.
- Record cross-repository private-package consumption in
  `config/manual-settings.json` with stable package and repository IDs. Grant
  consumer workflows only the `read` role through the package's **Manage
  Actions access** UI, preserve visibility and source association, and do not
  automate the grant through an undocumented API. A transition from private to
  public is a separate, effectively irreversible organization-owner action:
  merge reviewed desired-state and consumer-permission changes first, preserve
  the source association, verify anonymous digest access, and remove obsolete
  repository grants without altering foreign entries.
- Record manually provisioned GitHub Actions environments in
  `config/manual-settings.json` with stable repository IDs, exact deployment
  branch policies and reviewer sets, and variable and secret names only. Never
  record credential values. Provision them only after the owning workflow is
  merged and reviewed, and do not imply that `bin/publish` applies them.
- Treat `config/codeql-advanced-setup.json` as the exhaustive exception
  inventory for repositories whose component/path-aware CodeQL workflow cannot
  use repository-wide default setup. Keep the advanced security configuration
  identical to the ordinary enforced baseline except for its descriptive
  fields and official `code_scanning_options.allow_advanced` value. The
  organization publisher must attach exceptions first; both publisher scopes
  must explicitly converge inventory repositories to default-setup
  `not-configured` and all other active repositories to `configured` without
  weakening dependency, secret-scanning, or vulnerability-reporting features.
- Keep organization security publication delta-aware. Normalize GitHub's
  legacy aggregate security response before comparing desired configuration,
  update only real configuration/default drift, and never re-attach a
  repository that is already attached or enforced on the intended
  configuration. Preserve regression coverage for GitHub's asynchronous
  enablement-event behavior.
- Never deploy a new advanced CodeQL exception without its target workflow pull
  request open and ready to rerun. After applying policy, immediately rerun and
  verify the advanced analysis before merging the workflow. If it cannot pass
  promptly, restore the baseline/default setup through a reviewed inventory
  rollback; do not leave an unobserved scanning gap.
- Treat `config/immutable-releases.json` as the exhaustive owner-enforced
  organization inventory. Record stable repository IDs as well as names, fail
  closed on live identity drift, and preserve the exact previous mode and
  selected-ID set for verified automatic rollback. Add a repository only after
  its draft-first, complete-before-publication release workflow is merged and
  proven. Never apply immutable-release policy from an unmerged branch.
- Never print or commit administrative tokens, live secrets, or API responses
  containing credentials.
- Run `bin/validate`, `bash -n`, ShellCheck on governance scripts, the publisher
  policy-scope tests, actionlint for workflows, inspect plan output, and finish
  with `git diff --check`.
- Commits and pull-request titles use Conventional Commits. Every squash merge
  is released by semantic-release.
- Update this `AGENTS.md` in the same change when major rework alters governance
  ownership, policy scope, publisher behavior, required checks, or validation.
