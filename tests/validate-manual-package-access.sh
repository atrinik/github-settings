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

rewrite_manual_settings() {
  local filter=$1
  local output

  output=$(mktemp)
  jq "${filter}" \
    "${temporary}/config/manual-settings.json" >"${output}"
  mv "${output}" "${temporary}/config/manual-settings.json"
}

jq -e '
  .github_packages_actions_access == [
    {
      package_owner: "atrinik",
      package_type: "container",
      package_name: "windows-build",
      package_id: 14204802,
      preserve_visibility: "private",
      actions_repository: "atrinik/classic",
      actions_repository_id: 1327289971,
      role: "read"
    }
  ]
' "${root}/config/manual-settings.json" >/dev/null

rewrite_manual_settings \
  '.github_packages_actions_access += [.github_packages_actions_access[0]]'
assert_invalid 'a duplicate package Actions-access grant'
cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"

rewrite_manual_settings \
  '.github_packages_actions_access[0].role = "write"'
assert_invalid 'a write-capable package Actions-access grant'
cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"

rewrite_manual_settings \
  'del(.github_packages_actions_access[0].actions_repository_id)'
assert_invalid 'a package grant without a stable repository ID'
cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"

rewrite_manual_settings \
  '.github_packages_actions_access[0].package_id = 0'
assert_invalid 'a package grant without a positive package ID'
cp "${root}/config/manual-settings.json" \
  "${temporary}/config/manual-settings.json"

rewrite_manual_settings \
  '.github_packages_actions_access[0].actions_repository = "classic"'
assert_invalid 'a package grant without a full repository name'

echo "Manual package Actions-access validation tests passed."
