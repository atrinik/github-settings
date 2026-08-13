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

An immutable-release inventory change must be coordinated with a merged,
verified draft-first release workflow in every selected repository. Review the
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
