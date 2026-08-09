#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/validate"
cp -R "${root}/config" "${temporary}/config"
cp -R "${root}/community-health" "${temporary}/community-health"

assert_invalid() {
  local description=$1

  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
}

reset_manual_settings() {
  cp "${root}/config/manual-settings.json" \
    "${temporary}/config/manual-settings.json"
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
  .github_actions_environments == [
    {
      deployment_branch_policy: {
        custom_branch_policies: true,
        patterns: [{name: "main", type: "branch"}],
        protected_branches: false
      },
      environment: "cloudflare-preview-domains",
      repository: "atrinik/website",
      repository_id: 1327107093,
      required_reviewers: [],
      secret_names: ["CLOUDFLARE_PREVIEW_TOKEN"],
      variable_names: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_ZONE_ID"]
    }
  ]
' "${root}/config/manual-settings.json" >/dev/null

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
  '.github_actions_environments[0].deployment_branch_policy.patterns[0].type = "tag"'
assert_invalid 'a tag deployment policy'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].secret_values = {}'
assert_invalid 'an environment secret-value field'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environment_secret_values = {CLOUDFLARE_PREVIEW_TOKEN: "secret"}'
assert_invalid 'a top-level environment secret-value field'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].variable_names +=
    [.github_actions_environments[0].variable_names[0]]
'
assert_invalid 'a duplicate environment variable name'
reset_manual_settings

rewrite_manual_settings '
  .github_actions_environments[0].secret_names =
    [.github_actions_environments[0].variable_names[0]]
'
assert_invalid 'a name declared as both a variable and a secret'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_environments[0].secret_names = ["cloudflare_preview_token"]'
assert_invalid 'a malformed environment secret name'

echo "Manual GitHub Actions environment validation tests passed."
