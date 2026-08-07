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
- Preserve the selected-actions entry for Codecov and the manual GitHub App
  repository-access inventory while coverage uploads use OIDC authentication.
- Never print or commit administrative tokens, live secrets, or API responses
  containing credentials.
- Validate all JSON with `jq`, run `bash -n` and ShellCheck on changed publisher
  scripts, run actionlint for workflows, inspect plan output, and finish with
  `git diff --check`.
- Commits and pull-request titles use Conventional Commits. Every squash merge
  is released by semantic-release.
- Update this `AGENTS.md` in the same change when major rework alters governance
  ownership, policy scope, publisher behavior, required checks, or validation.
