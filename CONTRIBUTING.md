# Contributing

Use a Conventional Commits pull-request title. Validate every JSON policy,
run `bin/validate`, ShellCheck on every governance script, the publisher
policy tests, and actionlint when workflows change. Review the dry-run
publisher output before applying organization changes. Never commit the
administrative token required by the manual publishing workflow. Package
Actions-access grants that lack a documented public API belong in
`config/manual-settings.json`; record stable package and repository IDs, grant
only read access to consumer workflows, and preserve the package's existing
visibility and source-repository association. Manually provisioned GitHub
Actions environments belong in the same inventory with a stable repository
ID, exact branch policy and reviewer set, and variable and secret names only.
Never commit their values, and provision them only after the workflow that uses
them is merged and reviewed.

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
