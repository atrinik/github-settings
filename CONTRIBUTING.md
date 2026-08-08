# Contributing

Use a Conventional Commits pull-request title. Validate every JSON policy,
run `bin/validate`, ShellCheck on every governance script, the publisher
policy-scope tests, and actionlint when workflows change. Review the dry-run
publisher output before applying organization changes. Never commit the
administrative token required by the manual publishing workflow.

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
