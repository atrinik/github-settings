#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/validate"
cp -R "${root}/config" "${temporary}/config"
cp -R "${root}/community-health" "${temporary}/community-health"
cp -R "${root}/.github" "${temporary}/.github"

assert_invalid() {
  local description=$1

  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
}

reset_manual_settings() {
  jq '
    .github_pages_sites = [] |
    .github_actions_environments = [
      {
        deployment_branch_policy: {
          custom_branch_policies: true,
          patterns: [
            {name: "main", type: "branch"},
            {name: "v*", type: "tag"}
          ],
          protected_branches: false
        },
        environment: "test-deployment",
        repository: "atrinik/classic",
        repository_id: 1327289971,
        required_reviewers: [],
        secret_names: ["EXTERNAL_TOKEN"],
        variable_names: ["EXTERNAL_ACCOUNT_ID"]
      }
    ]
  ' "${root}/config/manual-settings.json" \
    >"${temporary}/config/manual-settings.json"
}

rewrite_manual_settings() {
  local filter=$1
  local output

  output=$(mktemp)
  jq "${filter}" \
    "${temporary}/config/manual-settings.json" >"${output}"
  mv "${output}" "${temporary}/config/manual-settings.json"
}

jq -e '
  (.github_actions_environments | length) == 2 and
  any(.github_actions_environments[]; . == {
      deployment_branch_policy: {
        custom_branch_policies: true,
        patterns: [
          {name: "main", type: "branch"},
          {name: "v*", type: "tag"}
        ],
        protected_branches: false
      },
      environment: "discord-release",
      repository: "atrinik/classic",
      repository_id: 1327289971,
      required_reviewers: [],
      secret_names: ["DISCORD_APPLICATION_ID"],
      variable_names: []
    }) and
  any(.github_actions_environments[]; . == {
      deployment_branch_policy: {
        custom_branch_policies: true,
        patterns: [{name: "main", type: "branch"}],
        protected_branches: false
      },
      environment: "github-pages",
      repository: "atrinik/classic",
      repository_id: 1327289971,
      required_reviewers: [],
      secret_names: [],
      variable_names: []
    }) and
  .github_pages_sites == [{
    activation_marker: "actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e",
    build_type: "workflow",
    environment: "github-pages",
    https_enforced: true,
    repository: "atrinik/classic",
    repository_id: 1327289971,
    site_url: "https://atrinik.github.io/classic/",
    workflow_path: ".github/workflows/daily-client-performance.yml"
  }]
' "${root}/config/manual-settings.json" >/dev/null

"${temporary}/bin/validate" >/dev/null
reset_manual_settings
"${temporary}/bin/validate" >/dev/null

rewrite_manual_settings \
  '.github_actions_environments[0].variable_names = []'
"${temporary}/bin/validate" >/dev/null
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments += [.github_actions_environments[0]]'
assert_invalid 'a duplicate repository environment'
reset_manual_settings

rewrite_manual_settings \
  'del(.github_actions_environments[0].repository_id)'
assert_invalid 'an environment without a stable repository ID'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].repository = "atrinik/unknown"'
assert_invalid 'an environment for an ungoverned repository'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].required_reviewers = [{type: "User", id: 1}]'
assert_invalid 'a required reviewer outside the declared empty set'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].deployment_branch_policy = {
    custom_branch_policies: false,
    patterns: [],
    protected_branches: true
  }
'
assert_invalid 'a protected-branches policy instead of an exact custom policy'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].deployment_branch_policy.patterns[0].name = "*"'
assert_invalid 'a wildcard deployment branch policy'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].deployment_branch_policy.patterns[1].name = "*"'
assert_invalid 'an unrestricted tag deployment policy'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].deployment_branch_policy.patterns[1].name = "release-*"'
assert_invalid 'a noncanonical release tag deployment policy'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].deployment_branch_policy.patterns[1].type = "environment"'
assert_invalid 'an unsupported deployment policy type'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].secret_values = {}'
assert_invalid 'an environment secret-value field'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environment_secret_values = {EXTERNAL_TOKEN: "secret"}'
assert_invalid 'a top-level environment secret-value field'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].variable_names +=
    [.github_actions_environments[0].variable_names[0]]
'
assert_invalid 'a duplicate environment variable name'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].variable_names = ["external_account_id"]'
assert_invalid 'a malformed environment variable name'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].secret_names +=
    [.github_actions_environments[0].secret_names[0]]
'
assert_invalid 'a duplicate environment secret name'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].secret_names =
    [.github_actions_environments[0].variable_names[0]]
'
assert_invalid 'a name declared as both a variable and a secret'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].secret_names = ["external_token"]'
assert_invalid 'a malformed environment secret name'

cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"
rewrite_manual_settings \
  '.github_pages_sites[0].build_type = "legacy"'
assert_invalid 'a non-workflow desired Pages source'

cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"
rewrite_manual_settings \
  '.github_pages_sites[0].site_url = "https://example.test/classic/"'
assert_invalid 'a Pages URL outside the repository identity'

cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"
rewrite_manual_settings \
  '.github_pages_sites[0].activation_marker = "actions/deploy-pages@v4"'
assert_invalid 'a mutable Pages activation marker'

cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"
rewrite_manual_settings \
  '.github_pages_sites[0].environment = "production"'
assert_invalid 'a Pages site without its exact environment'

echo "Manual GitHub Actions environment validation tests passed."
