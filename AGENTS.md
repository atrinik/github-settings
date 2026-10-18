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
- Keep environment-scoped Cloudflare DEV credential lifecycle records bound to
  the exact metaserver repository ID, environment, workflow and declared scopes.
  Protected-branch environment verification must not request custom branch
  policies; derive an empty custom-pattern set from the verified mode. Effective
  token permissions and expiry are separate from secret-name metadata.
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
- `bin/audit` is the read-only live drift check for the complete active
  repository inventory. Run it after governance changes and on its scheduled
  workflow; it must fail closed on an unregistered active repository, merge
  policy drift, custom-property drift, missing inherited rulesets, or exposed
  security-baseline drift.
- New repositories must be registered in the desired-state inventories before
  they are treated as governed. The publishers fail closed when an active
  repository is absent from those inventories; absent archived repositories
  remain historical evidence and are skipped by the property publisher.
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
- Record a completed maintenance-line retirement in
  `config/retired-maintenance-branches.json` with stable repository/ruleset
  identities, exact final branch and release commits, recovery assets, and the
  rulesets that must remain active. Use the targeted
  `bin/publish --retire-maintenance REPOSITORY/BRANCH` plan so the authorized
  apply can remove only that exact ruleset. Branch deletion is a later,
  separately authorized operation after a second live preflight; the publisher
  never deletes a branch, tag, release, or asset.
- Preserve the selected-actions entry for Codecov and the manual GitHub App
  repository-access inventory while coverage uploads use OIDC authentication.
- Preserve external-provider App records as value-free manual state with exact
  stable identities, permissions, events, and selected repository IDs. Planned
  integrations may retain null live App/installation IDs only with an explicit
  pending owner-UI state, proposed name-only secret/variable slots, and a
  documented follow-up. A shared installation change must retain every
  unrelated reviewed repository, must never widen to all repositories, and
  requires organization-owner UI readback when the administrative API cannot
  enumerate the selected set.
- Record cross-repository private-package consumption in
  `config/manual-settings.json` with stable package and repository IDs. Grant
  consumer workflows only the `read` role through the package's **Manage
  Actions access** UI, preserve visibility and source association, and do not
  automate the grant through an undocumented API. A transition from private to
  public is a separate, effectively irreversible organization-owner action:
  merge reviewed desired-state and consumer-permission changes first, preserve
  the source association, verify anonymous digest access, and remove obsolete
  repository grants without altering foreign entries.
  The private linux-build package keeps its exact package/source identities;
  record client-only read grants separately from effective workflow pulls.
  Metadata verifies identity/source/visibility, not grants or effective pulls.
  Preserve all foreign grants and prove each owning authenticated workflow pulls
  its pinned manifest before claiming effective access; never widen visibility.
- Record manually provisioned GitHub Actions environments in
  `config/manual-settings.json` with stable repository IDs, exact deployment
  branch policies and reviewer sets, and variable and secret names only. Never
  record credential values. Provision them only after the owning workflow is
  merged and reviewed, and do not imply that `bin/publish` applies them.
- Crates.io Trusted Publishing is a value-free desired contract for protocol
  and content-toolkit. Bind exact stable repository IDs,
  `publish-crate.yml`, protected `refs/heads/main`, `crates-io-release`, and the
  official auth action with a full immutable workflow SHA; allow the reviewed
  `rust-lang/crates-io-auth-action@*` pattern for Dependabot updates without a
  redundant central action-version lock. Reviewed source/version merge approves
  automatic future publication; environments have zero reviewers/wait and no
  registry secrets. Keep pending source/environment/registration distinct from
  observations; verify live repository/ref/protection and observed environments.
  Parse both observed exact-main `publish-crate.yml` and `release.yml` structurally with the declared
  `requirements-validation.txt` dependency; comments/plain text or disabled
  jobs are not executable source proof. Reject matrix/reusable execution in the
  two automatic and source package/sign/release jobs, and recursively confine
  all step-context expressions to the exact returned upload-token input and
  reviewed confirmation condition. External registration remains sanitized
  owner evidence, not a GitHub API fact, and can precede a pending later
  automatic source/environment transition.
  Source signing alone may request attestation writes/OIDC in a separate inert
  job; build and semantic-release jobs have no OIDC. Automatic verification
  uses only contents/actions/checks/attestations read, while the isolated inert
  publisher adds contents write for atomic upload intent and OIDC. Require
  actual protected-main manifest provenance and immutable source-release proof
  in the producer helper. Before registry PUT, atomically reserve the global
  crate/version Git-reference coordinate; existing/ambiguous reservations block
  absent-version retries and must never be automatically deleted or reset.
  First owner-local API-token publication is limited to the seven declared
  toolkit libraries; exclude CLIs, revoke bootstrap credentials, and
  use OIDC only afterward. Protocol 0.2 retains its approved manual path. Before
  any broad publisher apply mutation, qualify newly added live immutable
  producer selections through fresh scoped source/environment verification;
  pending/missing inventory or drift fails closed. Initial draft-first code
  qualification is separate from later immutable-release/runtime proof, and
  does not require a pre-existing immutable release.
- Keep the crate dependency App separate from unrelated Apps. Select only
  client, exactly contents/PR write and metadata read, no events,
  bypass or auto-merge; inventory names only for repository secret
  `CRATE_DEPENDENCY_UPDATE_APP_PRIVATE_KEY` and variable
  `CRATE_DEPENDENCY_UPDATE_APP_ID`. Record observed installation and name-only
  provisioning separately from pending reviewed workflow activation and dated
  successful-owned-PR proof. Current owner-authorized early provisioning does
  not imply effective credentials or a deployed workflow. Retain exact owner UI
  or supported App-authenticated repository-selection readback; empty events
  do not independently prove a disabled webhook. Preparation must verify
  registry readiness before the isolated job writes an owned PR. Keep exact
  consumer paths, verified key creation date, verification date, rotation owner,
  and a rotate-by deadline within the existing 90-day cadence. The deadline is
  internal policy, not upstream expiry; verify replacement workflow use before
  revoking the old key. Keep a selected-set change after the recorded readback
  as pending `repository_scope_reverification` until fresh readback replaces
  it. An owner-accepted key exposure binds to the current key and a closed
  window, never extends rotate-by, and is removed on rotation.
- Record GitHub Pages sites with stable repository identity, exact provider URL,
  HTTPS enforcement, owning deployment environment, desired Actions source,
  workflow path, and immutable deployment-action marker. Before that marker is
  present on the default branch, the verifier permits only the documented
  legacy source as pending transition state; once merged, anything except the
  Actions source is drift. Switch the live source only after the consuming
  workflow is merged and reviewed.
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
- Metaserver production environment names and immutable-release selection are
  desired state only until its reviewed draft-first producer and setup are
  qualified. Preserve old mutable releases and tags as historical evidence;
  only a new immutable release can satisfy production promotion. Keep setup,
  release publication and exact-tag dispatch under their distinct authorizations.
- Treat `config/immutable-releases.json` as the exhaustive owner-enforced
  organization inventory. Record stable repository IDs as well as names, fail
  closed on live identity drift, and preserve the exact previous mode and
  selected-ID set for verified automatic rollback. Stage additions as pending
  desired state; apply only after their reviewed draft-first workflows are
  merged and qualified. Every registry upload must prove that its actual source
  release is immutable; ordinary workflow tokens cannot read administrative
  immutability settings, so do not add an unsupported pre-tag settings query. Never apply immutable-release policy from an unmerged branch.
  This release delivery activates only the exact immutable-release API policy
  after a complete snapshot, identity and freshness check, exact readback and
  verified rollback. Preserve foreign live state; do not broad-apply the
  publisher plan. Suspend only the three producer source-release workflows in
  the reviewed reversible window, retaining and restoring their original states.
- Never print or commit administrative tokens, live secrets, or API responses
  containing credentials.
- Run `bin/validate`, `bash -n`, ShellCheck on governance scripts, the publisher
  policy-scope tests, actionlint for workflows, inspect plan output, and finish
  with `git diff --check`.
- Commits and pull-request titles use Conventional Commits. Repositories with
  `release_policy: semantic-release` are released by semantic-release; active
  services without a release contract remain pull-request governed with
  `release_policy: none` and are omitted from `release_tags`.
- Remove a repository transferred out of the organization from every
  desired-state inventory, validator identity map and test fixture in one
  change, and record its transfer in `README.md#transferred-repositories`.
  Historical evidence sections stay as written.
- Update this `AGENTS.md` in the same change when major rework alters governance
  ownership, policy scope, publisher behavior, required checks, or validation.

- `config/security-merge-protection.json` owns CodeQL targets, per-gate
  `pending`/`enforced` intent, and required default-setup language minima.
  Keep CodeQL targets/activation equal to required CI. Dependency review is
  advisory across all active repositories: keep `dependency_review: []` and
  `activation.dependency_review: {}`. Never require its context as a desired
  vulnerability CI barrier. Preserve ordinary CI and zero required approvals.
- Keep repository-owned `06 - CodeQL security` in both scopes; Team has no
  organization code-scanning rules. Pending CodeQL gates only probe readiness;
  promote intent through source review after landed successful producer proof.
  Enforced gates remain required when deleted or producers fail. Keep language
  unions, owner pull-request-only bypass, and existing configuration attachment
  behavior. The retained generic `07` tooling must reject advisory producer
  evidence and retire only recognized owned old gates with fresh identity and
  payload fences; source changes never authorize live settings apply.
- Dependency review uses ordinary PR events without branch/path filters, with
  no checkout, secrets, contributor execution, or merge-group trigger. Reporting
  requires the workflow on the relevant PR/merge revision; adding it on main
  does not cover historical branches automatically or authorize backports, retired-branch
  recreation, or additional supported maintenance lines. Keep its official
  immutable action, low severity reporting, all scopes, `warn-only: true`, `license-check: true`,
  `comment-summary-in-pr: always`, and step `continue-on-error: true` so findings
  and operational failures do not block CI. Retain license findings as advice;
  license metadata is not compatibility certification, and existing repository
  license compatibility rules still apply.
  Per-PR/ref concurrency cancels superseded runs; a failure-report step warns and
  adds a job-summary notice using the action's raw outcome. Preserve available
  reports and state that vulnerability/license results are unknown if absent.
  Contents read and PR write support reporting; fork/Dependabot comment denials
  warn and fall back to job summaries.
  Implementing agents must read the latest run and job summary for the current
  PR head before merge, even when an older bot comment exists. Fix actionable
  findings, or record explicit maintainer-accepted risk. Inspect
  missing-report errors rather than treating them as a clean scan. Do not add
  advisory allowlists, human approval requirements, or a duplicate pin catalog.
- Advanced CodeQL readiness parses executable YAML with the declared validation
  dependency: bind classification outputs, matrix, scoped config, official
  full-SHA init/analyze actions, and the always-running aggregate. Reject
  duplicate keys, disconnected or disabled steps, and failure suppression.
  Require ordinary pull-request triggers covering the live default branch and
  opened/synchronize/reopened events without path filters.
  Producer helpers remain trusted; preserve owner-controlled action updates,
  category names and paths without a duplicate version/path catalog.
- `config/actions-sha-pinning.json` persists SHA rollout as `pending` with no
  canary or `enforced` with an accepted PR coordinate. Promote it through normal
  source review only after ordinary PR-bound action-update evidence passes.
  Pending command-line canaries only probe readiness; they never enable SHA
  enforcement. Enforced policy uses its stored proof to restore drift and fails
  if proof cannot be revalidated; audit reports disabled enforced policy as
  drift. Preserve existing true settings. Allow action names with `@*`; keep
  full SHAs in producer workflows instead of duplicate pin catalogs. Canary
  legacy-check absence requires verified protection evidence; a bare or
  ambiguous 404 is unreadable. Enumerate and validate every ruleset page before
  publisher identity, absence, update or retirement decisions.
- Adoption of existing security gates into enforced source intent requires the
  effective default-branch API to prove the repository-owned ruleset and desired
  tool/context. Never infer activation from target membership or silently change
  source intent. Retire target and activation entries together. Retired targets
  lose only exact repository-owned managed security rules;
  preserve archived, foreign, and modified same-name rules. Re-read and validate
  the exact rule payload after the repository metadata fence immediately before
  deletion. Audit retained named security rules on non-target repositories as
  drift even when disabled, modified or scoped to another ref. Keep repository
  workflow overrides read-only and unable to approve PRs, with delta-aware writes.
- Repository-scope `03 - Required CI` retirement requires reviewed exact prior
  repository/ruleset IDs and contexts in `config/retired-required-ci.json`.
  Delete only the unchanged Actions-bound template after fresh identity/archive
  and payload checks. Preserve modified/foreign rules and missing-provenance
  rules with actionable `SKIP`; retain records for idempotent reruns.

- Before updating an existing security gate, re-read and revalidate its identity
  and recognized payload, retaining concurrent modifications. Bind the final
  metadata default branch to the branch used for pending-gate qualification
  or existing effective-gate proof; changed branches must not activate a gate.
  Pending existing-gate proof also requires unchanged enforcement and ref
  applicability in the final rule read. Enforced intent retains recognized
  restoration. Audit full legacy
  protection on active default and declared maintenance branches; any presence
  is drift under the canonical ruleset contract. Only verified unprotected
  responses count as absent; unreadable evidence fails closed and audit never
  removes protections. Compare the complete effective default and maintenance branch policy with
  declared allowed rule types and parameters; undeclared integrity or restriction types are drift,
  even when every desired rule is present. Only the exact repository-disabled REST response may
  fall back to a fixed read-only GraphQL query with matching repository/branch
  identity, active state and explicit null legacy-rule association. Missing or
  conflicting evidence fails closed; preserve historical rules on other refs.
