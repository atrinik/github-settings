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

  if ATRINIK_VALIDATION_TODAY=2026-08-11 \
    "${temporary}/bin/validate" >/dev/null 2>&1; then
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
  jq "${filter}" "${temporary}/config/manual-settings.json" >"${output}"
  mv "${output}" "${temporary}/config/manual-settings.json"
}

ATRINIK_VALIDATION_TODAY=2026-08-11 \
  "${temporary}/bin/validate" >/dev/null
jq -e '
  .github_actions_apps == [{
    app_id: 4564008,
    app_slug: "atrinik-classic-dependency-updater",
    consumers: [".github/workflows/update-content.yml"],
    events: [],
    installation_id: 153045686,
    last_verified_on: "2026-08-11",
    owner: "Atrinik organization owners",
    permissions: {
      contents: "write",
      metadata: "read",
      pull_requests: "write"
    },
    purpose: "Authenticate the branch and pull-request operations for one reviewed Classic content-lock update without access to other Atrinik repositories.",
    repository: "atrinik/classic",
    repository_id: 1327289971,
    repository_scope_verification: "organization_owner_ui",
    repository_selection: "selected",
    rotate_by: "2026-11-09",
    rotation_cadence_days: 90,
    rotation_owner: "Atrinik organization owners",
    runbook: "README.md#classic-dependency-update-app",
    secret_name: "DEPENDENCY_UPDATE_APP_PRIVATE_KEY",
    secret_scope: "repository",
    variable_name: "DEPENDENCY_UPDATE_APP_ID",
    variable_scope: "repository"
  }]
' "${root}/config/manual-settings.json" >/dev/null
jq -e '
  .github_actions_credentials == [{
    credential_type: "classic_pat",
    consumers: [
      ".github/workflows/check-project-health.yml",
      ".github/workflows/publish-planning.yml",
      ".github/workflows/publish.yml",
      ".github/workflows/sync-project.yml"
    ],
    last_verified_on: "2026-08-10",
    owner: "Atrinik organization owners",
    purpose: "Administer Atrinik organization governance and synchronize the shared organization Project from GitHub Actions.",
    repository: "atrinik/github-settings",
    repository_id: 1324382941,
    required_scopes: ["admin:org", "project", "repo"],
    rotate_by: "2026-11-08",
    rotation_cadence_days: 90,
    rotation_owner: "Atrinik organization owners",
    runbook: "README.md#settings-automation-credential",
    secret_name: "ATRINIK_SETTINGS_TOKEN",
    secret_scope: "repository"
  }]
' "${root}/config/manual-settings.json" >/dev/null

rewrite_manual_settings \
  '.github_actions_apps += [.github_actions_apps[0]]'
assert_invalid 'a duplicate GitHub App record'
reset_manual_settings

rewrite_manual_settings \
  'del(.github_actions_apps[0].installation_id)'
assert_invalid 'a GitHub App without an installation ID'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].permissions.actions = "write"'
assert_invalid 'a GitHub App with Actions permission'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].permissions.contents = "read"'
assert_invalid 'a GitHub App without contents write permission'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].events = ["push"]'
assert_invalid 'a GitHub App with webhook events'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].repository_selection = "all"'
assert_invalid 'a GitHub App installed on all repositories'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].repository_scope_verification = "unverified"'
assert_invalid 'a GitHub App without owner-verified repository scope'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].repository = "atrinik/unknown"'
assert_invalid 'a GitHub App for an ungoverned repository'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].secret_name = "private-key"'
assert_invalid 'a malformed GitHub App Actions secret name'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].variable_name = "app-id"'
assert_invalid 'a malformed GitHub App Actions variable name'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].rotate_by = "2026-08-10"'
assert_invalid 'a stale GitHub App rotate-by date'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_apps[0].private_key = "secret"'
assert_invalid 'GitHub App private-key material'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials += [.github_actions_credentials[0]]'
assert_invalid 'a duplicate repository credential'
reset_manual_settings

rewrite_manual_settings \
  'del(.github_actions_credentials[0].repository_id)'
assert_invalid 'a credential without a stable repository ID'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].repository = "atrinik/unknown"'
assert_invalid 'a credential for an ungoverned repository'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].credential_type = "fine_grained_pat"'
assert_invalid 'an unsupported credential type'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].required_scopes += ["delete:packages"]'
assert_invalid 'an unsupported credential scope'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].required_scopes += ["project"]'
assert_invalid 'a duplicate credential scope'
reset_manual_settings

for scope in admin:org project repo; do
  rewrite_manual_settings \
    ".github_actions_credentials[0].required_scopes -= [\"${scope}\"]"
  assert_invalid "a credential missing the required ${scope} scope"
  reset_manual_settings
done

rewrite_manual_settings \
  '.github_actions_credentials[0].secret_name = "settings-token"'
assert_invalid 'a malformed Actions secret name'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].owner = ""'
assert_invalid 'a credential without accountable ownership'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].rotate_by = "2026-08-09"'
assert_invalid 'a stale rotate-by date'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].rotate_by = "2026-02-30"'
assert_invalid 'an impossible calendar day'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].last_verified_on = "2025-02-29"'
assert_invalid 'a non-leap-year February 29'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].last_verified_on = "2026-08-12"'
assert_invalid 'a future verification date'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].rotate_by = "2026-12-31"'
assert_invalid 'a rotate-by date beyond the declared cadence'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].consumers = [".github/workflows/missing.yml"]'
assert_invalid 'a missing credential consumer workflow'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credentials[0].credential_value = "secret"'
assert_invalid 'a credential-value field'
reset_manual_settings

rewrite_manual_settings \
  '.github_actions_credential_values = {ATRINIK_SETTINGS_TOKEN: "secret"}'
assert_invalid 'a top-level credential-value field'

reset_manual_settings
rewrite_manual_settings '
  .github_actions_apps[0].last_verified_on = "2028-02-29" |
  .github_actions_apps[0].rotate_by = "2028-05-29" |
  .github_actions_credentials[0].last_verified_on = "2028-02-29" |
  .github_actions_credentials[0].rotate_by = "2028-05-29"
'
ATRINIK_VALIDATION_TODAY=2028-02-29 \
  "${temporary}/bin/validate" >/dev/null

if ATRINIK_VALIDATION_TODAY=2026-02-30 \
  "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: validator accepted an impossible validation date" >&2
  exit 1
fi

echo "Manual GitHub Actions credential validation tests passed."
