# Contributing

Use a Conventional Commits pull-request title. Validate every JSON policy,
run `bin/validate`, ShellCheck on every governance script, the publisher
policy tests, and actionlint when workflows change. Review the dry-run
publisher output before applying organization changes. Never commit the
administrative token required by the manual publishing workflow. Package
Actions-access grants that lack a documented public API belong in
`config/manual-settings.json`; record stable package and repository IDs, grant
only read access to consumer workflows, and preserve the package's existing
visibility and source-repository association.

An advanced CodeQL inventory change must be coordinated with an open,
review-ready workflow pull request in the target repository. Validate that the
plan attaches the advanced-allowed security configuration before disabling
default setup, and include the immediate workflow rerun and rollback owner in
the deployment handoff.

Do not require a new workflow context until that exact aggregate context has
landed and passed on the protected branch. In particular, add Classic's
`CodeQL validation` requirement only after its advanced workflow is merged;
otherwise the required check would prevent the workflow pull request itself
from merging.
