#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/validate"
cp -R "${root}/.github" "${temporary}/.github"
cp -R "${root}/config" "${temporary}/config"
cp -R "${root}/community-health" "${temporary}/community-health"

assert_invalid() {
  local description=$1

  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
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
  [.github_packages_actions_access[] | select(.package_name != "linux-build")] == [] and
  [.github_packages_actions_access[].actions_repository] == ["atrinik/client", "atrinik/editor"] and
  all(.github_packages_actions_access[]; .package_id == 14205615 and .preserve_visibility == "private" and
    .source_repository == "atrinik/devcontainer" and .source_repository_id == 1322185908 and
    .role == "read" and .grant_state == "owner-observed-read-grant" and
    .observed_on == "2026-10-11" and .evidence_location == "README.md#private-linux-updater-build-image")
' "${root}/config/manual-settings.json" >/dev/null

reset_valid_access() {
  cp "${root}/config/manual-settings.json" \
    "${temporary}/config/manual-settings.json"
  rewrite_manual_settings '
    .github_packages_actions_access = [
    {
      package_owner: "atrinik",
      package_type: "container",
      package_name: "classic-build",
      package_id: 14345002,
      preserve_visibility: "private",
      actions_repository: "atrinik/classic",
      actions_repository_id: 1327289971,
      role: "read"
    }
    ]'
  "${temporary}/bin/validate" >/dev/null
}

reset_valid_access
rewrite_manual_settings \
  '.github_packages_actions_access += [.github_packages_actions_access[0]]'
assert_invalid 'a duplicate package Actions-access grant'

reset_valid_access
rewrite_manual_settings \
  '.github_packages_actions_access[0].role = "write"'
assert_invalid 'a write-capable package Actions-access grant'

reset_valid_access
rewrite_manual_settings \
  'del(.github_packages_actions_access[0].actions_repository_id)'
assert_invalid 'a package grant without a stable repository ID'

reset_valid_access
rewrite_manual_settings \
  '.github_packages_actions_access[0].package_id = 0'
assert_invalid 'a package grant without a positive package ID'

reset_valid_access
rewrite_manual_settings \
  '.github_packages_actions_access[0].actions_repository = "classic"'
assert_invalid 'a package grant without a full repository name'

for filter in \
  '.github_packages_actions_access[0].source_repository_id = 1' \
  '.github_packages_actions_access[0].preserve_visibility = "public"' \
  '.github_packages_actions_access[0].actions_repository_id = 1' \
  '.github_packages_actions_access[0].grant_state = "active"' \
  '.github_packages_actions_access[0].grant_state = "pending-owner-ui-read-grant"' \
  '.github_packages_actions_access[0].evidence_location = null'; do
  cp "${root}/config/manual-settings.json" "${temporary}/config/manual-settings.json"
  rewrite_manual_settings "${filter}"
  assert_invalid "${filter}"
done
cp "${root}/config/manual-settings.json" "${temporary}/config/manual-settings.json"
rewrite_manual_settings '.github_packages_actions_access[] |= (.grant_state="owner-observed-read-grant" |
  .observed_on="2026-10-11" | .evidence_location="README.md#private-linux-updater-build-image")'
"${temporary}/bin/validate" >/dev/null
rewrite_manual_settings '.github_packages_actions_access[] |= (.grant_state="pending-owner-ui-read-grant" |
  .observed_on=null | .evidence_location=null)'
"${temporary}/bin/validate" >/dev/null

echo "Manual package Actions-access validation tests passed."
