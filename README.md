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
- Repositories in the `merge_queue` inventory merge through GitHub's merge
  queue, and their required CI no longer requires an up-to-date branch because
  the queue tests each merged result. `playtester` is the pilot. See
  [Enabling a merge queue](#enabling-a-merge-queue).
- Declared maintenance branches reject deletion and non-fast-forward updates,
  require linear history and pull requests, and require only checks already
  emitted for that branch.
- Release tags in release-producing repositories cannot be moved or deleted.
- Active services without an established release contract may use
  `release_policy: none` while remaining in the pull-request and required-CI
  inventories; they must be omitted from `release_tags` until that contract
  exists.
- Published releases in the exhaustive `config/immutable-releases.json`
  inventory declare owner-enforced immutable releases. The inventory preserves
  Classic and the qualified library producers and stages metaserver-worker
  until its draft-first producer is merged and qualified. This organization
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
  credential type and scopes, consumers, accountable ownership, verification date,
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
  actions, and `rust-lang/crates-io-auth-action@*`. Workflow references remain
  full commit SHAs; the action allowlist permits routine pin updates. The
  publisher also restores per-repository workflow permission overrides to
  read-only with PR approvals disabled, applying only real drift.
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

## Staged security merge protection

`config/security-merge-protection.json` targets the 22 repositories in
`required_ci` for CodeQL, including `service-updater`; `.github` and
`web-platform` are excluded from that CodeQL cohort. Its CodeQL `activation`
map records each target's reviewed `pending` or `enforced` intent. `enforced`
means protection is required, including when the live rule is missing; it is
not evidence of a successful installation. Existing aggregate checks and zero
required approvals remain intact. The publisher also restores
`service-updater`'s inventoried PR, `Updater validation`/title CI, and release-tag
protections.

Both policy scopes install repository-owned `06 - CodeQL security` rules:
GitHub Team does not support organization code-scanning rules. CodeQL blocks
high and critical security findings (`high_or_higher`), with ordinary quality
alerts disabled (`none`). Only organization owners may bypass through a pull
request; direct pushes gain no exception.

Dependency review is advisory across all active Atrinik repositories, including
those outside the CodeQL cohort. Its required-gate inventory is empty:
`dependency_review: []` and `activation.dependency_review: {}`. The publisher
will not install `07 - Dependency review`. A separately authorized settings
apply can retire only an exact recognized repository-owned old `07` rule, with
the existing identity, archive, payload and final-read fences. Modified or
foreign rules are retained for review; a source merge alone does not remove
live protection.

The dependency workflow reports on eligible ordinary pull-request runs when
opened, updated, reopened, or edited, including a base-branch retarget. It has
no target-branch filter, but the workflow must exist on the relevant PR/merge
revision; adding it on main does not automatically cover historical branches.
It does not run on merge queue groups. Reporting visibility does not declare a branch
supported or maintained or authorize backports or recreating retired branches.
The pinned official action reads event revisions without checkout, contributor
code execution, secrets, or `pull_request_target`. It requests contents read
and pull-request write solely for its report. It reports low through critical
vulnerabilities in runtime, development, and unknown scopes with `warn-only:
true`, keeps license findings advisory, and always attempts a PR summary comment.
License metadata is not a compatibility certification; existing repository
license compatibility rules still apply.
Fork and Dependabot tokens may deny comment writes; the action warns and keeps
its job summary. Operational errors remain visible in logs but step-level
`continue-on-error: true` keeps this advisory job nonblocking. A following
failure-report step warns and adds a job-summary notice without claiming the
action produced no analysis; absent reports mean vulnerability and license
results are unknown. It also attempts to refresh the uniquely identified action
comment with the current head and run link; denied or uncertain comment writes
retain the summary fallback. The action has a five-minute timeout and reporting
a separate two-minute timeout within the ten-minute job. Per-PR/ref concurrency
cancels superseded review runs.

Implementing agents must read the latest dependency-review run and job summary
for the current PR head before merging, even when an older bot comment exists.
Fix actionable findings, or record a maintainer's explicit acceptance of the
remaining risk. A missing report is not a clean vulnerability result;
inspect the log and explain the reporting failure. This review process adds
no required human approval and no vulnerability CI barrier. Ordinary PR CI
trusts repository writers, who can change a workflow in the same PR; neither
its check context nor the GitHub Actions app attests immutable workflow bytes.

Dependency review relies on GitHub's dependency graph and submitted snapshots;
unsupported or missing manifests cannot provide comprehensive coverage. GitHub's
[Dependabot alert limitations](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-alerts#limitations)
exclude advisory alerts for Actions referenced by commit SHA. SHA pinning and
a clean advisory report therefore do not prove an Action commit is free of
known vulnerabilities; review upstream advisories when updating pins.

Default CodeQL setup similarly analyzes supported languages and its detected build
coverage; enabling it alone does not prove a successful analysis. Rust in
`content-toolkit` is an explicit minimum, unioned with its existing languages.
Legacy `javascript`/`typescript` aliases use `javascript-typescript` in the
PATCH payload, preserving that coverage and other live language entries.
Read failures never replace that live language set with an incomplete set.

GitHub's [code-scanning merge-protection limitations](https://docs.github.com/en/code-security/concepts/code-scanning/merge-protection)
exclude Dependabot pull requests analyzed by default setup and merge queue
groups. Advisory dependency review reports on eligible Dependabot pull requests
where its workflow is present. CodeQL merge protection also depends
on the alert's affected lines appearing in the PR diff. Ordinary quality alerts
remain excluded by `alerts_threshold: none`.

Classic readiness parses the executable workflow with the declared PyYAML
validation dependency. It binds classification outputs to the analysis matrix,
regenerates each selected scope's configuration, and follows that output into
the official CodeQL initialization and analysis steps and the always-running
validation aggregate. Disabled steps, failure suppression, disconnected inputs,
and ambiguous YAML fail closed. The current producer uses `build-mode: none`;
full-SHA action updates remain producer-owned, and classifier source owns path
selection and category names. This structural check trusts repository writers
and their Python helpers; it does not attest that arbitrary writer-controlled
classifier or aggregate code behaves honestly. It adds no approval requirement.

Rollout is owned by an organization administrator:

1. Merge the advisory workflow and policy PRs, inspect their dependency reports,
   and review `bin/publish`'s plan. Dependency findings do not block CI; CodeQL
   retains its separate staged protection.
2. Apply only with separate live-settings authorization. Existing governance,
   the wildcard action allowance, and the Rust language correction can converge
   while security gates remain `PENDING`. Pending gates only probe
   `bin/security-readiness`; even a successful probe cannot activate protection
   or silently promote source intent. The retained generic dependency readiness
   helper rejects advisory producers as required-gate evidence. CodeQL requires current-head coverage for every configured default-setup
   language plus policy minima. Classic instead requires its successful full
   advanced producer and all current source-derived analysis partitions. The
   advanced inventory independently requires Classic’s client, server, and core
   C/C++, Python, and GitHub Actions scope/language pairs, so reducing producer
   declarations or executed jobs cannot silently reduce required coverage;
   changed-path PR subsets cannot establish readiness. The bounded newest-first
   query stops once current coverage is proven; retired categories and old
   analysis history do not require manual cleanup.
3. After successful initial producer qualification, promote that gate's
   `activation` entry to `enforced` through source review and merge, retaining
   the qualification evidence in the policy PR. Adoption of existing protection
   instead requires read-only evidence of an active, repository-owned gate with
   the intended tool/context applying to the live default branch. Desired target
   membership alone never proves activation. Review the next plan and apply only
   with live-settings authorization. Persisted intent precedes the first write,
   so interrupted installation or later deletion cannot revert to pending.
   The publisher creates or restores enforced protection without requiring a
   currently healthy producer; audit reports missing or modified protection as
   drift even when producer evidence fails or cannot be read. Scope migrations
   preserve these repository-owned gates. A converged security gate or language
   configuration causes no mutation or security-configuration reattachment.
   Existing-rule repair accepts only recognized enforcement and ref-scope drift
   on the exact repository-owned rule. Changed bypass, tool, context, severity,
   or unknown policy fields are retained and reported for explicit review.
   Retiring a CodeQL target removes its required-CI, CodeQL target, and activation
   entries together through source review. Dependency advice does not require
   removing ordinary CI. The publisher removes only matching
   repository-owned security rules from active retired targets, preserving foreign or modified same-name
   rules for explicit review and leaving archived repositories untouched. It re-reads
   the exact rule payload after the repository metadata fence immediately before
   deletion to retain concurrent modifications. Audit reports retained named
   security rules on non-target repositories as drift even when disabled,
   modified or scoped to another ref.
4. Desired organization `sha_pinning_required` is true. Its durable rollout
   contract is `config/actions-sha-pinning.json`: the initial `pending` phase
   has no accepted canary and never enables the field. Verify an ordinary
   action-pin update PR with `bin/security-readiness sha OWNER/REPOSITORY/PR`.
   Qualifying changes update action pins only. Reusable workflow references are
   [excluded from GitHub's action SHA enforcement](https://docs.github.com/en/organizations/managing-organization-settings/disabling-or-limiting-github-actions-for-your-organization), so changing one cannot qualify
   a canary, even alongside an action update. Unchanged reusable references and
   real action subpaths remain supported.
   The optional publisher `--sha-pinning-canary` argument only reports readiness
   while pending. After successful PR evidence, promote the source to
   `{"phase":"enforced","canary":"OWNER/REPOSITORY/PR"}` through the normal
   review and merge process before the first separately authorized live apply.
   This records the accepted PR, with no duplicate action-version inventory.
   The verifier checks the active conservative organization Actions mode,
   repository enablement, exact PR changes, and successful PR-bound current-head
   checks. These include configured CI and all effective ruleset and legacy
   branch-protection status
   contexts, with trusted app identities. Advisory dependency review is not a
   desired required context; an old effective gate remains part of the live
   proof until separately retired. Legacy-check absence requires verified
   protection evidence; bare or ambiguous 404 responses fail closed. This proves current policy and PR-run
   evidence; it does not attest historical organization settings.
   Ordinary subsequent publication uses that stored canary. It first converges
   selected mode, then allowed-action patterns, then revalidates the canary
   before restoring a disabled SHA setting. A dry run reports the required
   staging without claiming that planned settings are active. Unreadable or
   failed proof blocks SHA restoration while retaining conservative policy
   repairs; the audit reports disabled enforced policy
   as drift, never as initial rollout pending. A live true setting is always
   preserved. Full SHA pinning does not prove an allowed action is trustworthy.

Advanced CodeQL qualification also requires ordinary pull-request triggers
covering the live default branch and opened, synchronize and reopened events,
without workflow path filters. Successful manual or scheduled analysis cannot
qualify a missing or retargeted pull-request producer. Before updating an
existing security gate, publication rechecks its ownership and recognized
payload immediately before the write, retaining concurrent policy changes.
Pending-gate qualification and existing effective-gate proof bind the same
default branch as the final metadata fence; a changed branch cannot activate
a gate using proof from the earlier branch. Pending existing-gate proof also
requires unchanged enforcement and ref applicability in the final rule read;
concurrent disabling or retargeting invalidates that proof. Enforced intent
retains its recognized restoration behavior.

Rulesets are the canonical branch protection contract. Audit also reads legacy
protection on every active default branch and declared maintenance branch. Any
legacy protection is drift requiring separate reviewed manual remediation;
unreadable responses fail closed. Only a verified unprotected-branch response
counts as absent. For the exact repository-disabled REST response, a fixed
read-only GraphQL query may instead prove that the identified active repository
and exact existing branch have an explicitly null legacy-rule association.
Missing, conflicting or unreadable evidence remains drift. Historical rules on
other branches remain untouched. Audit compares the complete effective default and maintenance branch
policy with declared allowed rule types and parameters; extra integrity or restriction types remain
drift even when every desired rule is present. The audit never removes branch protections.

Publisher identity, absence, update and retirement decisions use the complete
validated ruleset inventory across all pages, including ordinary organization
and repository rules. Unreadable pages cannot count as absent rules.

Repository-scope retirement of an existing `03 - Required CI` rule also needs a
reviewed `config/retired-required-ci.json` record with its exact repository and
ruleset IDs and previous required contexts. Remove the repository from
`required_ci` and both security target/activation inventories in the same source
change. Publication deletes only the unchanged GitHub Actions-bound template
after fresh repository identity, archive-state and rule-payload checks. Missing
provenance or modified/foreign rules are retained with an actionable `SKIP`;
keep retirement records for idempotent reruns. This does not delete branches or
ordinary branch protections.

Read-only preflight failures and unfinished producers are explicit pending
controls, never successful rollout evidence. The audit reports pending controls
separately and rejects unreadable evidence. No paid subscription is introduced.
Rollback requires reviewed desired-state changes and separately authorized
apply; reverting a producer while its required gate remains active can prevent
merges. Do not remove a gate merely because a vulnerable PR fails it.

## Usage

Requirements: `git`, `gh`, `jq`, `python3`, the packages in
`requirements-validation.txt`, and an authenticated organization-owner account.
Install the declared validation dependencies before local publisher, audit, or
advanced CodeQL readiness checks; the owning workflows install them too.

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

Repository merge defaults and organization workflow permissions are written only
when their declared fields differ. Ordinary ruleset updates compare normalized
policy, treating the ignored `OrganizationAdmin.actor_id` and array ordering as
semantically equivalent. Publisher and audit share the comparison contract in
`lib/ruleset-policy.jq`.

GitHub's additional PR/CI parameters are writable controls. Existing empty
`required_reviewers`, all three `allowed_merge_methods`,
`require_extra_approval_for_unattributed_changes: true`, and
`do_not_enforce_on_create: false` are compatible with this policy and are copied
unchanged into replacement payloads. Other values, unknown parameters, extra
rules (including deployment gates), and unknown condition fields require manual
review; the publisher stops instead of dropping them. Managed fields still
converge on real drift. Existing ruleset updates verify the listed identity and
re-read the full document before PUT, refusing observed concurrent changes.
These reads are not an atomic API transaction. Review the complete plan before
any authorized apply; normalization does not authorize rule retirement or a
live policy change. Queue installation and verification still precede relaxed
required CI.

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

## Metaserver development credentials

The `development` environment of `atrinik/metaserver-worker` (repository ID
1324297032) holds the three value-free lifecycle entries consumed only by
`.github/workflows/deploy-development.yml`. Zoey Seraphina Rose, an Atrinik
organization owner, is accountable for verification and rotation.

`CLOUDFLARE_API_TOKEN` is account-owned with intended Workers Scripts Edit and
D1 Read permissions. Its account-wide edit authority can also edit PROD; the
workflow's exact DEV configuration and resource fences provide the target
boundary. `ATRINIK_DELIVERY_RESOURCE_READ_TOKEN` is account-owned with intended
Workers Scripts Read. `ATRINIK_PRODUCTION_BUILDS_READ_TOKEN` is user-scoped
with intended Workers CI Read and Workers Scripts Read for the retained-writer
fence. Do not describe any of these credentials as restricted to one Worker.

All three environment names were installed and verified on 2026-10-11; bounded
runtime GET checks passed. Effective provider permission metadata is unreadable,
and the deployment token's write permission has not yet been proven by its
owning workflow. Name metadata does not verify values, scope or expiry.
The 2027-01-09 rotate-by deadline is the internal 90-day policy, not a provider
expiry claim; provider expiry remains unverified.

Before that deadline, prepare a reviewed lifecycle update, provision replacement
credentials under separately authorized scope, and install them without printing
values. Run `bin/verify-manual-settings` for stable repository and environment
secret-name presence, then prove the bounded read paths and the owning DEV
workflow under its normal target gates before revoking predecessors. Retain
private qualification receipts and never change PROD targets or provider
permissions merely to validate rotation. Publishers do not provision tokens.

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
technically impossible. Ordinary pull requests require zero human approvals;
required checks and the pull-request process still apply, and the App has no
bypass. The consumer must never review, approve, merge, tag, publish,
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
4. Confirm the App-authored pull request receives the required checks, the App
   has no bypass, and the consumer does not approve or merge the pull request.
   Close the disposable pull request, remove its branch, and only then delete
   the previous private key. A later scheduled run must also succeed before
   rotation is considered complete.

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

The App connection and its former production/review history do not authorize
current metaserver deployment. DEV now runs through its reviewed GitHub Actions
main workflow. PROD accepts only an explicit owner-approved immutable-tag
promotion dispatch with exact digests and predecessor. Retained Cloudflare
Builds require their reviewed command fence and stopped-Build readback; a
branch pause alone cannot fence manual/retry execution. Preserve the shared
website installation and PR-only main policy. Historical #55/#56 automatic
production instructions are evidence, not current activation authority.

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
coverage. Its `required_partitions` records semantic scope/language minima,
while the current producer owns display names and upload categories. Readiness
reads literal partition declarations without executing repository Python and
requires a distinct successful job and matching upload for every declaration,
including additions. Changing action versions needs no coverage-inventory edit.
Remove the matching minima when removing an advanced repository; an empty
inventory with an empty minima object is valid. Both security configurations
must remain identical except for their
name, description, and `code_scanning_options.allow_advanced` value.

Moving a repository to `archive` is an executable policy change: the next
`bin/publish --apply` makes it read-only. Before applying an archival change,
confirm that remaining pull requests and branches have been preserved at their
new location. For `atrinik/classic`, also complete any intentional tag rebuild
before applying immutable release-tag policy.

## Enabling a merge queue

`merge_queue` in `config/repositories.json` is the exhaustive list of
repositories that merge through GitHub's merge queue. GitHub accepts the
`merge_queue` rule only in repository rulesets, so both policy scopes install a
repository-owned `08 - Merge queue` ruleset on each listed repository's default
branch, as they do for `06 - CodeQL security`. The rule comes from
`config/rulesets/merge-queue.json`:

- squash merges, the organization's only merge method;
- `ALLGREEN` grouping, so every queued pull request's own merge result must
  pass the required checks, not only the head of its group;
- a build concurrency of 5 and groups of 1 to 5 pull requests, with no wait:
  a single queued pull request merges as soon as its checks pass, and pull
  requests queued together share a group;
- a 60-minute timeout for required checks to report on a merge group.

Organization owners keep the usual pull-request-only bypass. During an
advisory merge window, the queue rule gets `always` bypass like that
repository's required CI.

A queued repository's `03 - Required CI` rule sets
`strict_required_status_checks_policy` to `false`. The queue already tests each
pull request merged onto the latest base, so the branch itself no longer has
to be current. When applying, the publisher re-reads the queue just before it
publishes required CI and relaxes the rule only if that read shows the exact
repository-owned queue. Otherwise it prints a `SKIP` and keeps required CI
strict. Every other repository keeps the strict policy. Validation requires
each listed repository to be in `required_ci`. It also keeps the template's
parameters within GitHub's API ranges and the allowed merge method, and allows
a wait only with a minimum group size above one.
GitHub Team offers merge queue only for public repositories, so the publisher
fails before any write if a listed active repository is private. Like the
security gates, it skips a listed repository that is not active; that
repository's required CI stays strict because no queue was installed.

Before adding a repository:

1. Merge a change in that repository so every required check also runs on the
   `merge_group` event and reports under its existing name. A required check
   that never reports on a merge group stalls the queue until the timeout.
   Dependency review stays advisory, has no merge-group trigger, and must never
   be a required gate on a queued repository; validation enforces that.
2. Add the repository to `merge_queue`, merge the reviewed change, and review
   the `bin/publish` plan. It should create `08 - Merge queue` on that
   repository. The publisher re-PUTs every managed ruleset on each run, and
   that repository's `03 - Required CI` payload should be the only one whose
   content changes. Then apply the plan with the usual explicit
   authorization.

The publisher installs the queue before it relaxes required CI. When a
repository is removed from the inventory, it restores the strict policy first
and only then deletes the managed queue. It deletes only an unmodified,
repository-owned `08 - Merge queue` rule, and checks the repository's identity
and re-reads the rule immediately before the deletion. A modified, foreign or
concurrently edited rule with that name is retained with a `SKIP`, and `bin/audit` reports it until someone
reviews it. The audit also requires each listed repository's exact queue rule,
repository ownership, and non-strict required CI.

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

## Metaserver immutable releases and production environment

The desired selected inventory adds only `atrinik/metaserver-worker`, stable
repository ID `1324297032`, while preserving Classic, content-toolkit and
protocol. This is pending activation until the reviewed metaserver producer
creates a draft, finishes and verifies every release asset, and only then
publishes that draft. Before any broad publisher mutation introducing this
selection, the read-only preflight checks the exact authenticated current-main
draft-first plugin order, both finalizer files, successful main-push `Check`
workflow and unchanged main. Retain that qualified SHA and re-read it after
all library/environment preflights and immediately before the first immutable
policy write; movement stops without mutation. This source check complements independent producer
qualification; marker text alone is not proof of asset assembly. Merge and
qualify that source first. This governance
source neither publishes a release nor promotes a Worker.

GitHub supports a narrow selected-repository operation,
`PUT /orgs/atrinik/settings/immutable-releases/repositories/1324297032`, when
the organization mode is `selected`. Its
[documented API](https://docs.github.com/en/rest/orgs/orgs#enable-a-selected-repository-for-immutable-releases-in-an-organization)
adds one repository without replacing the existing set. Before any separately
authorized apply, inspect the read-only publisher plan, verify exact repository
and actor identity, and snapshot the complete current selected set and repository
state privately. Do not apply the publisher's unrelated drift. Re-read the
complete selected set and `GET /repos/atrinik/metaserver-worker/immutable-releases`
after the narrow write, requiring `enabled=true` and `enforced_by_owner=true`
with every prior selection preserved. A failed write/readback stops release
publication; reconcile the actual state before any separately reviewed rollback.

The supported repository-only alternative is
`PUT /repos/atrinik/metaserver-worker/immutable-releases`, which requires
repository administration write, but it does not satisfy this owner-enforced
organization inventory by itself. The UI alternatives are the Releases section
of [repository settings](https://github.com/atrinik/metaserver-worker/settings)
and the selected repository set under
[organization repository settings](https://github.com/organizations/atrinik/settings/repositories).
Follow [GitHub's instructions](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes).

The optional metaserver-only `activation_variable` names
`ATRINIK_RELEASE_IMMUTABILITY_ACTIVE` in repository scope. Publishers never set
it. The producer leaves a verified complete draft while this variable is absent
or disabled; it may publish only after the reviewed draft-first producer is
merged, its exact source passes `Check`, current main remains qualified, and
fresh target immutability readback proves enablement. Recheck source and target
at the point of use before separately authorized activation and publication.
The plain `enabled` value is a release gate, never a substitute for actual
target API proof. The ordinary workflow token cannot read administrative
immutability settings, so retain the authorized owner readback privately and
verify the published release's own `immutable=true` response. Do not publish a
mutable draft and try to repair immutability afterward.

Immutability applies only to future releases. Existing mutable releases,
including `v4.34.0`, remain historical and cannot satisfy promotion's immutable
release proof. Never delete/recreate one, move its tag, or weaken the promotion
check. Produce a new reviewed stable release after enablement and retain its
exact immutable tag/SHA, successful main validation, completed assets and
provenance for the promotion review.

The names-only `production` environment inventory declares the reviewed
production-promotion contract: protected branches enabled,
custom policies disabled, no custom patterns and no required reviewers. Solo
owner dispatch of the exact reviewed inputs remains the approval boundary.
The eight secret names and two variable names are desired state, not proof that
the environment or effective credentials exist. The recovery public-key input
remains pending the owning workflow merge; provision it only after that reviewed
consumer is merged. Provision through supported
GitHub environment operations only after source review and separately granted
setup authority. `ATRINIK_PRODUCTION_RECOVERY_PUBLIC_KEY` contains only the
owner's public RSA SPKI PEM (at least 3072 bits). It selects the recipient for
standard JWE RSA-OAEP-256 with A256GCM encryption; the protected recovery policy
pins its canonical DER SPKI SHA-256 and 90-day retention. The private key stays
owner-only outside Actions. Only ciphertext recovery artifacts enter Actions;
verify the completed pre-mutation intent artifact download before any secret
PATCH, and retain a separate post-readback receipt. This public recipient name
confers no mutation authority. Keep DEV and PROD configurations and runtime secrets disjoint;
do not copy a DEV deployment token into PROD. Any new administrative credential
also needs a truthful lifecycle inventory before use, with separately verified
scope and rotation metadata. `bin/verify-manual-settings` verifies names and
identity without reading values; it derives an empty custom-policy list in
protected-branch mode. Publishers never create this environment or dispatch
promotion. Stop until the owner approves the exact future tag and operation.

## Metaserver production credentials

Production lifecycle records bind `atrinik/metaserver-worker`, stable repository
ID `1324297032`, environment `production`, consumer
`.github/workflows/promote-production.yml` and this runbook. The schema permits
these exact bindings alongside the existing DEV records; it does not assert
that a production credential has been created, verified or installed.
Environment names distinguish lifecycle entries for otherwise identical secret
names. Duplicate names within one environment remain invalid.

Use a dedicated account-owned production deployment token with only
`Workers Scripts Edit` and `D1 Read` for the exact reviewed account. These
account-wide permissions can edit either cohort; the reviewed workflow and
resource fences enforce the deployment target. Do not copy the DEV deployment
token. Qualified read-only control-plane credentials may serve both environments
only with separately reviewed production placement and lifecycle evidence;
they are distinct from Worker runtime secrets, which remain disjoint.

Capture requires only the token through a hidden local prompt. Record dates from
actual qualification and an internal rotation deadline within 90 days, capped
by any observed provider expiry. Missing creation or expiry metadata does not
block capture; never invent it. Preserve any observed date or timestamp precision.
Token verification may prove active status and expose expiry; it does not prove
effective permissions. Retain available permission and account evidence privately
and run bounded read-only Worker and D1 metadata checks. State any unverified
permission or expiry explicitly. Write permission remains unproven until the
owning workflow succeeds. GitHub secret-name metadata proves
placement only. Keep token values, provider token identifiers and private
qualification evidence out of this inventory, commits and logs.

The dedicated production token was verified on 2026-10-12 as active and distinct
from DEV, with bounded reads of all three PROD Worker settings and the exact D1
database identity. Required `Workers Scripts Edit` and `D1 Read` permissions
remain the intended deployment contract; provider permission metadata and
write capability are unproven. Provider creation and expiry remain unknown.
Its 2027-01-10 rotation deadline is internal 90-day policy, not provider expiry.
The two owner-authorized shared read-only control-plane credentials retain their
2026-10-11 qualification and 2027-01-09 internal deadlines; expiry remains unknown.
Their separate production lifecycle entries declare desired placement, not
installation or successful use by the production workflow. Provision and verify
only after this inventory is reviewed and accepted.

## Enabling immutable source releases

The desired organization-level `selected` inventory preserves Classic
(`1327289971`) and adds protocol (`1327106950`) and content-toolkit
(`1327107043`). Renderer (`1327106998`) was part of the same addition until it
left the organization on 2026-10-17 (see
[Transferred repositories](#transferred-repositories)); the desired inventory
no longer selects it. These additions are pending activation until
reviewed source workflows are merged and qualified. Their release producers
must assemble and verify the complete crate/archive/manifest payload on a draft
before publishing it. A published immutable release must be complete because
its tag and assets can no longer be replaced. Before any registry upload, the crate publication helper verifies the actual
source release has `immutable=true`. Ordinary `GITHUB_TOKEN` cannot read the
administrative immutable-settings endpoint, so source workflows do not add an
unsupported pre-tag query or administrative credentials. This inventory is
activated only after reviewed draft-first source qualification.

Initial qualification establishes producer code and setup; it does not require
an already published immutable release. The independently accepted producer
candidates and merged main revisions had identical complete Git trees:

| Repository | Reviewed candidate | Merged main |
| --- | --- | --- |
| protocol | `5f843a69ec52233a5ff66bebe7d04a025ff7295c` | `f9e72b9ebc4f8516f3a1e1f6383ab4484c3c1444` |
| renderer | `9a7e1afcc378cd14d28e56468f6a7cdd16de630c` | `ef70471c87579f3cef0027bf8e126fbaae515f6f` |
| content-toolkit | `c04755ba3936c30171a85ec7ce003413eb75d174` | `0caed7763c1c8d2d83bb3f2636a33d94f3962a71` |

Local draft-first complete-asset validation, independent source review, and
exact-candidate CI establish this initial code qualification. These historical
revisions do not lock future source or action updates. Workflow parsing alone
does not prove draft assembly; real signing, immutable release assets, and
registry uploads remain runtime proof obligations.

Before any broad `bin/publish --apply` mutation, its preflight computes producer
IDs newly entering the live immutable selection. Each new producer requires an
observed source/environment inventory record and a fresh scoped
`bin/verify-manual-settings --crate-publication-setup atrinik/REPOSITORY` check.
Pending or missing records, workflow/environment drift, or concurrent immutable
policy changes stop apply before mutation. Existing selected producers and an
already enforced `all` policy need no initial-addition qualification. This guard
does not authorize broad apply for the narrow rollout below.

For protocol, separately verify that the actual immutable pinned
semantic-release GitHub plugin supports the configured draft-first publication
and the complete asset payload. A configured flag alone is not release proof.
Qualification includes build, packaging, draft assembly, retry/recovery,
actual immutable-release upload gating, and publication paths.

The rollout order below is the record of the activation that added protocol,
renderer and content-toolkit, and it stays as written. Its three-producer
payload and four-repository checks describe the selection at that time, before
renderer left the organization. Derive the payload for any later change,
including the pending metaserver addition, a rollback or an intentional removal,
from the current `config/immutable-releases.json`, and never select or query
`atrinik/renderer`.

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
for repository in classic protocol content-toolkit; do
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
`atrinik/client` (`1327106844`) only. The owner confirmed its **Manage Actions
access** read grant on 2026-10-11; its `grant_state` is
`owner-observed-read-grant`, with dated sanitized owner evidence. The same
2026-10-11 owner observation also covered a read grant for `atrinik/editor`
(`1327106902`); that entry is historical, because the editor left the
organization on 2026-10-17 (see
[Transferred repositories](#transferred-repositories)) and is no longer in the
inventory.
Client's exact-main post-grant run
[38164640476](https://github.com/atrinik/client/actions/runs/38164640476)
subsequently proved a repository-token pull of the pinned image and complete
read-only preparation/application validation. It correctly produced no migration
PR before registry readiness; App-writing jobs were skipped, so no effective
App writer was proved. The grant observation comes from owner UI, not API
enumeration of the grant list. Retain permission inheritance, private
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

Rollback stops the client's owning updater workflow first and removes only the
client's read grant through supported owner UI after reviewed inventory removal.
Preserve the package, published versions, source, visibility, foreign grants,
and unrelated App credentials.

## Automatic crate Trusted Publishing

`config/manual-settings.json` records the desired, value-free contracts below.
The remaining source contracts are `observed-reviewed-workflow`, and their
environments are `observed`: supported live readback qualified both workflow
files at the same protected-main revision, exact repository identities, and
main-only environments with no reviewers, wait, administrator bypass, secrets,
or variables. The narrow immutable-policy activation window is complete;
reviewed source workflows produced the signed immutable releases used for the
initial library publications.
Protocol registration was owner-observed on 2026-10-11 and its manual 0.2 upload
succeeded in [run 38156755961](https://github.com/atrinik/protocol/actions/runs/38156755961).
The fourteen initial renderer/toolkit libraries have been bootstrapped and their
exact Trusted Publisher registrations are owner-observed: the seven
content-toolkit libraries in the table below, and the seven renderer libraries
that were registered for `atrinik/renderer` before it left the organization
(see [Renderer Trusted Publisher revocation](#renderer-trusted-publisher-revocation)).
Their automatic jobs passed OIDC authentication and reconciliation of the
existing published coordinates;
[the onboarding evidence below](#initial-library-onboarding-evidence) records
that scope. A source inventory update records these observations; it does not
perform external registration or publication.

| Repository | Stable repository ID | Published libraries |
| --- | --- | --- |
| `atrinik/protocol` | `1327106950` | `atrinik-protocol` |
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
3. The fourteen initial renderer and toolkit names (the toolkit libraries in
   the table above and the seven renderer libraries listed under
   [Renderer Trusted Publisher revocation](#renderer-trusted-publisher-revocation))
   require a first owner-local publication because Trusted Publishing cannot
   create their initial crate records. Prepare, review, and verify the exact
   release archives, package dependency order, versions, digests, native
   prerequisites, and registry readiness first. The owner uses a narrowly
   scoped local API token only for that initial bootstrap, then revokes it.
   Exclude the renderer CLI
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

### Initial library onboarding evidence

On 2026-10-12 (UTC), the owner confirmed Trusted Publisher registration for all
fourteen renderer/toolkit names, with their respective exact repository,
`publish-crate.yml` and `crates-io-release` environment: the seven
`atrinik/content-toolkit` libraries in the table above, and the seven
`atrinik/renderer` (`1327106998`) libraries `atrinik-render-api`,
`atrinik-render-resources`, `atrinik-render-sdl3`, `atrinik-render-testkit`,
`atrinik-render-ui`, `atrinik-render-wgpu` and `atrinik-scene`. The table no
longer lists the renderer because it left the organization on 2026-10-17.
Registration is external owner evidence; the GitHub metadata API does not
enumerate it.

The initial renderer libraries are bound to the signed immutable
[v1.8.0 source release](https://github.com/atrinik/renderer/releases/tag/v1.8.0)
at `de7fe1c3f178937c1fb1e655587a169eff9468cd`; toolkit libraries are bound to
[v2.11.0](https://github.com/atrinik/content-toolkit/releases/tag/v2.11.0) at
`e5889d2fe3afcd1ee7b3db45e8924792753136cf`. All fourteen initial 0.1.0 registry
versions were verified against the signed source archives, public version API,
sparse-index checksums and canonical CDN bytes, with owner `zoeyrose` (ID
`437663`) and their permanent upload intents. Later source releases with empty
crate manifests do not replace these initial archive bindings. The inventory's
`bootstrap_crates` lists remain the exact one-time first-publication scope,
not a request to bootstrap those existing coordinates again.

[Renderer run 38192681802](https://github.com/atrinik/renderer/actions/runs/38192681802)
and [toolkit run 38192866448](https://github.com/atrinik/content-toolkit/actions/runs/38192866448)
succeeded through the guarded automatic jobs: the official action exchanged
OIDC for the temporary registry credential, the helper skipped already published
coordinates and confirmation passed. Subsequent registry/owner/intent checks
matched the prior evidence. These runs prove authentication and reconciliation
of all seven known coordinates per repository. They made no new-coordinate
registry PUT; the first future eligible upload still depends on its reviewed
source/version, actual immutable release, runtime provenance and fresh intent.
Revoke the one-use bootstrap credential after confirmation and use OIDC only
for future publication.

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
failures, matrix/reusable execution, credential references outside the exact
upload input, and skipped verification/auth/upload steps. Recursive expression
checks include job outputs, names, concurrency, checkout inputs, and nested
step fields, including indexed, case-varied, or aggregate step references.
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

### Renderer Trusted Publisher revocation

The seven renderer libraries `atrinik-render-api`, `atrinik-render-resources`,
`atrinik-render-sdl3`, `atrinik-render-testkit`, `atrinik-render-ui`,
`atrinik-render-wgpu` and `atrinik-scene` are still registered on crates.io with
a Trusted Publisher for `atrinik/renderer`, `publish-crate.yml` and
`crates-io-release`, owner-observed on 2026-10-12. `atrinik/renderer`
(`1327106998`) became `seraphinastudios/tilewright-renderer` on 2026-10-17 (see
[Transferred repositories](#transferred-repositories)), so no contract in this
repository covers those registrations any more. The former name can be reused:
creating a new `atrinik/renderer` in the organization ends GitHub's redirect to
the transferred repository. A new repository with that name, a matching
`publish-crate.yml` workflow and a `crates-io-release` environment would then
match the registrations and could publish new versions of those crates.

On 2026-10-18 the owner decided to revoke the `atrinik/renderer` Trusted
Publisher from all seven crates through the crates.io owner UI, the first step
of the rollback above. **The revocation is an owner action pending
confirmation.** It has not been observed yet, so treat all seven registrations
as live until it is. After the owner confirms it, record the dated, sanitized
owner observation for each crate here through reviewed source. Revoking a
Trusted Publisher does not yank or delete any published version.

## Protocol crate Trusted Publishing

The automatic contract above replaces the former planned per-release
maintainer-review policy. Protocol 0.2 keeps its approved manual release path;
future reviewed source/version merges use the automatic path after observed
onboarding. Protocol registration is owner-observed with the successful manual 0.2 run;
its automatic source/environment setup is observed. Renderer/toolkit initial
publication and owner registration are complete, with the known-coordinate OIDC
proofs above. The renderer's seven registrations now await the owner's
revocation (see
[Renderer Trusted Publisher revocation](#renderer-trusted-publisher-revocation)).
The dependency App's workflow activation is pending: its only
remaining consumer, the client, has not yet run its PR-writing job.

## Crate dependency update App

`crate_dependency_update_app` records owner-observed App setup on 2026-10-11.
Its `workflow_activation` is `pending-reviewed-workflows`: the client's reviewed
updater workflow has merged, but no client-owned PR has been observed yet.
Client [run 38192029425](https://github.com/atrinik/client/actions/runs/38192029425)
completed preparation as a no-op and skipped the isolated PR-writing job, so it
does not prove that the writer works. Record `observed-successful-owned-pr` only
after a client run creates its own PR that passes ordinary checks and review.

Before the editor left the organization, its run 38193476856 created the App's
first owned PR (editor PR 36) on 2026-10-12. The App bot authored the verified
signed commit, all ordinary checks passed, independent review accepted it, and
the maintainer merged it through the ordinary process. That observation belongs
to the transferred repository and does not count as client activation.
The live App is `atrinik-crate-dependency-update`, App ID `5276152`, installation
ID `170332148`. Its expected **selected repositories** set is exactly
`atrinik/client` (ID `1327106844`). App-authenticated supported API readback on
2026-10-11 confirmed the selected set at that time, `atrinik/client` and
`atrinik/editor` (ID `1327106902`), exact contents write/pull requests
write/metadata read permissions, no subscribed events, and the external homepage
`https://www.atrinik.org`. The editor left the organization on 2026-10-17 (see
[Transferred repositories](#transferred-repositories)), which changed the
installation's repository set after that readback. The client-only set is
therefore recorded as pending re-verification: `repository_scope_reverification`
has state `pending-reverification`, reason `repository-transfer-after-readback`,
the 2026-10-11 readback date, the 2026-10-17 change date and the removed editor
identity. No readback of the client-only set has been recorded yet.

To re-verify, the owner confirms in the installation's organization-owner UI,
or through supported App-authenticated readback, that the selected set is
exactly `atrinik/client`. Reviewed source then records that method in
`repository_scope_verification`, the readback date in `observed_on`, and sets
`repository_scope_reverification` to `null`. Validation pins the record to the
editor transfer. While `observed_on` is on or before 2026-10-17, the pending
record must name exactly that readback, the 2026-10-17 change and
`atrinik/editor` (`1327106902`). It can be cleared only together with a
readback dated after the transfer, and must be cleared once one is recorded.
Preserve every other App and installation,
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

The value-free key lifecycle records creation and verification on 2026-10-11,
the consumer path of the client's `released-dependencies.yml` workflow, and
rotation owner `Atrinik organization owners`. Its 90-day internal rotation
deadline is 2027-01-09; this is not an upstream key expiry. Validation rejects
missing, future, overdue, or over-cadence lifecycle dates. Rotate by issuing a
replacement App key, verifying the App identity with it, securely updating only
the client's existing repository secret slot, and proving the client's
PR-writing workflow. Revoke the old key after successful replacement proof;
retain name-only evidence and update creation/verification/deadline metadata
through reviewed source. If replacement proof fails, stop the client's writing
workflow and preserve the old working key until the owner restores service or
explicitly revokes it.

The editor's transfer also carried a copy of the current key. On 2026-10-17
`atrinik/editor` became `seraphinastudios/tilewright-editor` (same ID
`1327106902`). GitHub keeps repository secrets and variables with a transferred
repository, so the editor's `CRATE_DEPENDENCY_UPDATE_APP_PRIVATE_KEY` secret and
`CRATE_DEPENDENCY_UPDATE_APP_ID` variable moved with it. Only the Atrinik owner
controls that repository and its organization, and the copy was deleted within
hours: a names-only readback on 2026-10-18 listed no Actions secrets or
variables in the transferred repository. **On 2026-10-18 the owner explicitly
accepted that exposure window instead of rotating the key early.**
`accepted_key_exposures` records the acceptance: the exposure type, the exposed
names, the former and current repository identity, the exposure start, the
removal readback and the acceptance date. The key keeps its ordinary 2027-01-09
rotate-by deadline; the acceptance does not extend it. Validation pins the
record to the editor transfer (former and current name, ID, the 2026-10-17
start and both exposed names), and requires an observed removal with the
acceptance on or after it. The record must stay while the current key was
created on or before the transfer. Once a rotation records a newer
`key_created_on`, the list must be empty, so remove the record in that same
reviewed change.

The read-only verifier checks live installation identity, exact permissions,
empty events, active state, selected repository identities, and credential
**names**. An administrative-token API cannot enumerate the complete selected
repository set; retain current supported App-authenticated readback or owner UI
proof. While `repository_scope_reverification` is pending, the verifier reports
`PENDING` with the recorded change instead of the ordinary `MANUAL` reminder.
It reports `credential_state: observed-name-metadata` separately from
workflow activation. The client's reviewed `released-dependencies.yml` workflow
has merged. The dated editor run/PR above is historical evidence of effective
App use by the transferred repository's writer and does not prove the client's
writer. A no-op run or setup/name metadata alone cannot
prove a successful PR-writing job. Keep new or replacement credential acceptance
bound to the actual owning workflow and its required checks.

The client's updater runs hourly (`17 * * * *`) and through
`workflow_dispatch`. Its credential-free preparation verifies exact released
versions and registry checksums, resolves dependencies, updates Cargo locks, and
runs aggregate validation before requesting an App token in the isolated
PR-writing job. It maintains only its owned
`automation/released-crate-dependencies` branch and pull request; ordinary
required checks and the pull-request process still govern merging, with zero
required human approvals.
Missing registry readiness produces no migration PR. It never uploads crates,
approves a pull request, merges it, or loosens branch protection. Prove initial
App permissions with a disposable/owned PR and current ordinary checks, without
exposing credentials. On retirement, stop the client's workflow and revoke the
App/key and only the client's named secret and variable slots; preserve
unrelated installations and secrets.

## Transferred repositories

On 2026-10-17 two repositories left the organization by GitHub transfer:

| Former repository | Stable repository ID | New location |
| --- | --- | --- |
| `atrinik/editor` | `1327106902` | `seraphinastudios/tilewright-editor` |
| `atrinik/renderer` | `1327106998` | `seraphinastudios/tilewright-renderer` |

They are no longer governed here: they are removed from the repository,
required-CI, release-tag, immutable-release, custom-property, CodeQL, Codecov,
Trusted Publishing, package-access and crate dependency App inventories. The
organization rulesets that named them stop matching anything; an authorized
`bin/publish --apply` removes the obsolete `03 - Required CI` rulesets. Atrinik
consumes both projects as external MIT dependencies. Historical evidence in the
sections above that names them is preserved. Where that evidence pointed at a
table row that left with the renderer, it now names the renderer crates
directly.

Three owner decisions from 2026-10-18 follow up on the transfer:

- The editor's retained copy of the crate dependency App key is an accepted
  exposure, and the key keeps its 2027-01-09 rotate-by deadline (see
  [Crate dependency update App](#crate-dependency-update-app)).
- The App's client-only selected set is pending re-verification, because the
  transfer changed it after the 2026-10-11 readback (same section).
- The owner is revoking the renderer's crates.io Trusted Publishers; that
  revocation is pending confirmation (see
  [Renderer Trusted Publisher revocation](#renderer-trusted-publisher-revocation)).
