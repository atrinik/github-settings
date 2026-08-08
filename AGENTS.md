# Atrinik GitHub settings repository guide

- This repository is the desired-state source for Atrinik organization
  repositories, rulesets, merge policy, Actions policy, and manual governance
  settings. It does not own component implementation.
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
- Keep required workflow job names synchronized with rulesets. Workflow or
  permissions changes also require actionlint, least-privilege review, and
  immutable action references according to policy.
- Declare protected non-default lines in `maintenance_branches`. Give each
  repository/branch pair a unique entry, and require only status checks that
  the branch's workflows already emit. Validate both Team organization rulesets
  and the retained repository-level fallback when changing this contract.
- Preserve the selected-actions entry for Codecov and the manual GitHub App
  repository-access inventory while coverage uploads use OIDC authentication.
- Treat `config/codeql-advanced-setup.json` as the exhaustive exception
  inventory for repositories whose component/path-aware CodeQL workflow cannot
  use repository-wide default setup. Keep the advanced security configuration
  identical to the ordinary enforced baseline except for its descriptive
  fields and official `code_scanning_options.allow_advanced` value. The
  organization publisher must attach exceptions first; both publisher scopes
  must explicitly converge inventory repositories to default-setup
  `not-configured` and all other active repositories to `configured` without
  weakening dependency, secret-scanning, or vulnerability-reporting features.
- Never deploy a new advanced CodeQL exception without its target workflow pull
  request open and ready to rerun. After applying policy, immediately rerun and
  verify the advanced analysis before merging the workflow. If it cannot pass
  promptly, restore the baseline/default setup through a reviewed inventory
  rollback; do not leave an unobserved scanning gap.
- Never print or commit administrative tokens, live secrets, or API responses
  containing credentials.
- Run `bin/validate`, `bash -n`, ShellCheck on governance scripts, the publisher
  policy-scope tests, actionlint for workflows, inspect plan output, and finish
  with `git diff --check`.
- Commits and pull-request titles use Conventional Commits. Every squash merge
  is released by semantic-release.
- Update this `AGENTS.md` in the same change when major rework alters governance
  ownership, policy scope, publisher behavior, required checks, or validation.
