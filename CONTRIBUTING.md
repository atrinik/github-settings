# Contributing

Use a Conventional Commits pull-request title. Validate every JSON policy,
run `bin/validate`, ShellCheck on every governance script, the publisher
policy tests, and actionlint when workflows change. Review the dry-run
publisher output before applying organization changes. Never commit the
administrative token required by the manual publishing workflow. Package
Actions-access grants that lack a documented public API belong in
`config/manual-settings.json`; record stable package and repository IDs, grant
only read access to consumer workflows, and preserve the package's existing
visibility and source-repository association. Making a reusable package public
requires a reviewed desired-state removal, explicit organization-owner
authorization, anonymous immutable-digest verification, and removal of only
the obsolete consumer grant; treat the visibility change as effectively
irreversible. Manually provisioned GitHub
Actions environments belong in the same inventory with a stable repository
ID, exact branch policy and reviewer set, and variable and secret names only.
Never commit their values, and provision them only after the workflow that uses
them is merged and reviewed.
GitHub Pages records likewise bind stable repository identity, the provider
URL, HTTPS, the deployment environment, and an immutable marker in the owning
workflow. Keep a pre-merge legacy source only as the verifier's explicit
pending state, then activate the Actions source after that exact workflow lands.

Administrative Actions credentials require a value-free lifecycle entry in
`config/manual-settings.json`. Record stable repository identity, secret scope
and name, credential type and required scopes, consumers, accountable owner,
verification and rotate-by dates, cadence, and the runbook. Never add value,
token ID, authorization header, fixture secret, or recoverable credential
material. Changes require credential-schema negative tests, the read-only
`bin/verify-manual-settings` plan, and the documented manual and scheduled
post-rotation checks.

Actions GitHub Apps require their own value-free inventory entry with stable
App, installation, and repository IDs; exact permissions and event set;
selected-repository verification; consumer paths; secret and variable names;
accountable ownership; verification and rotation dates; and a runbook. Never
store a private key, installation token, token response, or credential value.
Changes require negative schema tests, read-only installation and metadata-name
verification, and organization-owner confirmation of the exact selected
repository set in GitHub's installation UI. Keep the App out of bypass lists,
preserve read-only Actions defaults, and prove the consumer's disposable pull
request receives ordinary checks without self-approval or self-merge.

External provider GitHub Apps use a separate value-free inventory entry with
stable App, installation, and selected repository IDs; exact permissions and
events; provider purpose and status producer; accountable review ownership;
and a revocation runbook. Preserve every existing selected repository unless a
separate reviewed retirement authorizes its removal, never select all
repositories, and require organization-owner UI proof of the exact set when
GitHub's administrative API cannot enumerate it. Provider tokens, account
coordinates, and credential values do not belong in this repository.

Organization identity changes must preserve the exact public description and
canonical website in `config/organization.json`, remain delta-aware in plan and
apply modes, and include unchanged-state coverage. Keep the public profile in
`community-health/profile/README.md`; never edit `atrinik/.github` directly.
Public pins are stable-ID manual state in `config/manual-settings.json`. Verify
their exact count, public/active identity, and order read-only through GraphQL,
and document the organization-owner profile-settings step rather than using an
undocumented mutation interface.

Synchronization authentication tests must distinguish readable from writable
credentials, preserve exact CLI failure statuses, reject missing advertised
classic-PAT scopes and write capabilities before mutation, and fail closed on
GraphQL searches beyond GitHub's 1,000-result window.

Project synchronization health changes must preserve the separate monitoring
path, the 90-minute freshness/failure contract, one marker-owned incident, and
least-privilege alerting through `GITHUB_TOKEN`. Test fresh, stale, repeated
failure, missing administration credential, trusted ownership, deduplication,
recurrent-outage boundaries, and recovery paths. Do not imply that GitHub's
best-effort cron is an exact 30-minute guarantee or that a monitor on GitHub
Actions is external to GitHub's scheduler.

When changing organization issue forms, keep them compatible with GitHub's
live validator: omit empty optional metadata and do not add a top-level `type`
key while the live renderer rejects it. Keep form labels synchronized with
`config/planning.json` type inference, and validate the Bug, Feature, and Task
mappings before publishing.

Keep default-branch deletion and non-fast-forward rules non-bypassable during
normal operation. Any organization-owner exception needed for GitHub's
security-advisory lifecycle must remain isolated to an explicitly authorized
window and must use pull-request-only bypass mode outside that window.

GitHub does not classify an advisory-level merge as a pull-request action. A
specifically authorized Classic advisory merge window may therefore use
organization-owner `always` bypass for the five Classic rules GitHub reports:
deletion, non-fast-forward, linear history, the pull-request gate, and required
CI. The reviewed rollback must empty `config/advisory-merge-windows.json` and
be applied immediately after the advisory merge.

An advanced CodeQL inventory change must be coordinated with an open,
review-ready workflow pull request in the target repository. Validate that the
plan attaches the advanced-allowed security configuration before disabling
default setup, and include the immediate workflow rerun and rollback owner in
the deployment handoff.

An immutable-release inventory change stages desired state and must be activated
only with a merged, qualified draft-first release workflow in every newly
selected repository. Every registry upload must verify the actual source
release is immutable. Ordinary workflow tokens cannot query administrative
immutability settings; keep the supported source-release evidence boundary. Review the
repository name and stable numeric ID, the exact organization selected set,
owner-enforcement verification, and snapshot rollback tests. Merge the policy
before requesting explicit authorization for `bin/publish --apply`; never
deploy the setting from an unmerged policy branch.

Security publisher changes must test both real drift convergence and a fully
converged rerun. The converged case must not update a security configuration,
replace its default, or re-attach repositories, because attachment starts an
asynchronous enablement event.

Do not require a new workflow context until that exact aggregate context has
landed and passed on the protected branch. In particular, add Classic's
`CodeQL validation` requirement only after its advanced workflow is merged;
otherwise the required check would prevent the workflow pull request itself
from merging.

Maintenance-branch retirement removes the active entry from
`config/repositories.json` and adds an immutable recovery record to
`config/retired-maintenance-branches.json`. Validate the complete repository,
then review the targeted `bin/publish --retire-maintenance
REPOSITORY/BRANCH` output. It must contain exactly one planned mutation: the
declared ruleset deletion. Merge the desired state before requesting explicit
organization-owner authorization for `--apply`. Re-run the complete preflight
after apply and again before separately authorized exact branch deletion;
never combine either operation with tag, release, asset, default-branch, or
unrelated policy changes.

Security merge controls use repository-level rules in both publisher scopes.
Keep `config/security-merge-protection.json` aligned with `required_ci` and
preserve ordinary aggregates. New dependency gates require the reviewed
workflow on the default branch and a successful corresponding PR run; CodeQL
gates require successful current-head analyses, including required languages.
Record successful initial qualification in the policy PR and promote the gate's
`activation` entry from `pending` to `enforced` through source review before its
first live installation. Pending publication only probes readiness. Enforced
intent survives missing rules and later producer failures, allowing restoration
without fresh initial proof; it does not claim live installation success. Remove
activation entries with retired targets, preserving exact owned-rule rollback.
Re-read the exact security-rule payload after the repository metadata fence
immediately before deletion, retaining concurrent modifications. Audit retained
named security rules on non-target repositories as drift regardless of their
enforcement or ref applicability.
For an existing repository-owned `03 - Required CI` rule, also record exact repository
and ruleset IDs and its prior contexts in `config/retired-required-ci.json`.
Validate retained/modified/foreign rules and fresh identity checks; keep records
for idempotent retirement. Missing provenance must retain the rule.
Tests must cover missing/failed producers, unreadable evidence, archived targets, language unions, both scopes,
and zero security mutations on a converged rerun. SHA enforcement must remain
pending until an ordinary action-update canary proves successful PR-bound
current-head CI without an allowlist edit and the persistent rollout source is
promoted to `enforced` with that accepted PR. Later disabled enforcement is drift,
not pending rollout; ordinary publication revalidates the recorded proof before
restoring it. Test rule retirement, effective default-branch applicability, and
repository workflow permission overrides. Action allowances use owner/action wildcards;
full commit pins belong in workflows, not redundant version assertions.

Advanced CodeQL readiness must validate executable YAML wiring from classifier
invocation and outputs through the dynamic analysis matrix, scoped generated
configuration, official full-SHA CodeQL actions, and the unconditional aggregate.
Require the live default branch's ordinary pull-request trigger without path
filters, including opened, synchronize and reopened events. Use the existing
validation dependency with duplicate-key rejection. Test
comments-only markers, disconnected inputs, disabled or failure-suppressed steps,
checkout revision drift, and ambiguous YAML; preserve full-SHA updates, formatting
changes, additional partitions, and category renames. Classification path
semantics remain in trusted producer helpers; do not add a central source-path or
action-version catalog or claim resistance to malicious repository writers.

Security gate updates must re-read and validate ownership and the recognized
payload immediately before PUT, preserving concurrent modifications. Audit
legacy protection on active default and maintenance branches as drift under the
canonical ruleset contract; distinguish verified unprotected responses from
unreadable evidence, and never remove protection during audit. The exact
repository-disabled REST response may use the fixed read-only GraphQL fallback;
require matching repository identity and branch, active state and an explicit
null legacy-rule association. Errors and missing or conflicting fields fail
closed; preserve unrelated historical rules.

Crates.io publication contracts bind exact repository/workflow/environment and
official auth-action identities with full immutable workflow SHA references;
preserve the reviewed `rust-lang/crates-io-auth-action@*` allowance for normal
Dependabot updates without a central version lock. Automatic publication follows reviewed
source/version merges with zero environment reviewers/wait and no registry
secrets. Keep pending onboarding distinct from observed source/environment and
owner-observed external registration; verify live protected main and exact
refs. First owner-local API-token bootstrap is restricted to the fourteen
listed renderer/toolkit libraries and ends with revocation; subsequent releases
use OIDC only. Protocol 0.2 retains its approved manual path. Crate
publication must qualify both exact-main workflows, isolate inert source
signing from build/semantic-release OIDC, and keep automatic verify permissions
read-only. The inert publisher alone adds contents write for the global
crate/version upload intent and receives its intent token only in the upload
step. Runtime certificate/source-run verification and create-only reservation
readback precede upload. Reject matrix/reusable execution in the automatic
verify/publish and source package/sign/release jobs; recursively reject step
references outside the exact upload-token input and confirmation condition. An
existing/ambiguous intent blocks absent-version
retries and is never automatically reset. Activate immutable-release policy
only through the documented narrow snapshot/readback/verified-rollback window;
do not broad-apply unrelated publisher-plan mutations. Broad apply must qualify
newly added live producer selections before its first mutation, with observed
inventory and fresh scoped source/environment checks. Initial independently
qualified draft-first code is sufficient for setup; actual immutable public
release and registry proof remain later runtime obligations. Dependency-update
App setup is client/editor only, exact contents/PR write and metadata read,
repository credential names only, registry readiness before owned PR creation,
and ordinary review/checks without auto-merge. Distinguish observed installation
and credential-name provisioning from pending reviewed workflow activation and
real successful-owned-PR proof; owner-authorized early setup does not prove
effective secret values. Inventory exact workflow consumer paths, observed key
creation/verification dates, rotation owner, and a deadline within 90 days of key
creation; that internal deadline does not assert upstream expiry. Verify a
replacement key in the owning writing workflow before revoking the old key.
Keep App-authenticated selected-set readback or owner
UI evidence, and do not infer the webhook switch from an empty event set.
Private linux-build consumption needs separate client/editor-only read grants
through owner UI. Keep exact private package/source identities and pending grant
state until observed; metadata and owner pulls do not prove an effective owning
workflow pull. Preserve foreign grants and visibility. Changes require negative schema
and live-metadata fixture tests plus a complete publisher plan; publishers do
not provision these integrations.
