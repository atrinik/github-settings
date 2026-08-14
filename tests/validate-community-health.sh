#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
cp -R "${root}/." "${temporary}/repository"

forms=${temporary}/repository/community-health/.github/ISSUE_TEMPLATE
profile=${temporary}/repository/community-health/profile/README.md

assert_invalid() {
  local description=$1

  if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
}

reset_repository() {
  rm -rf "${temporary}/repository"
  cp -R "${root}/." "${temporary}/repository"
}

"${temporary}/repository/bin/validate" >/dev/null

rm "${profile}"
assert_invalid 'a missing organization profile source'
reset_repository

sed -i 's/GPL-licensed/GPL-compatible/' "${profile}"
assert_invalid 'an organization profile without the Classic license boundary'
reset_repository

sed -i 's/MIT by default/MIT-only/' "${profile}"
assert_invalid 'an organization profile without the tools mixed-license boundary'
reset_repository

# shellcheck disable=SC2016 # Markdown code markers are intentionally literal.
sed -i \
  's/GPL-2.0-or-later `map-checker-qt\/` exception/GPL-2.0-or-later `wrong-checker\/` exception/' \
  "${profile}"
printf '\nUnrelated replacement tracker: map-checker-qt/.\n' >>"${profile}"
assert_invalid 'an organization profile without the tools path-scoped exception'
reset_repository

jq 'del(.files[] | select(.target == "profile/README.md"))' \
  "${temporary}/repository/config/community-health.json" \
  >"${temporary}/community-health.json"
mv "${temporary}/community-health.json" \
  "${temporary}/repository/config/community-health.json"
assert_invalid 'an undeclared generated organization profile'
reset_repository

jq '.description = "Developer tools for Atrinik"' \
  "${temporary}/repository/config/organization.json" \
  >"${temporary}/organization.json"
mv "${temporary}/organization.json" \
  "${temporary}/repository/config/organization.json"
assert_invalid 'organization identity drift'
reset_repository

jq '.organization_pins.repositories |= reverse' \
  "${temporary}/repository/config/manual-settings.json" \
  >"${temporary}/manual-settings.json"
mv "${temporary}/manual-settings.json" \
  "${temporary}/repository/config/manual-settings.json"
assert_invalid 'organization pin order drift'
reset_repository

jq '.organization_pins.apply_path = "https://github.com/organizations/atrinik/settings/profile"' \
  "${temporary}/repository/config/manual-settings.json" \
  >"${temporary}/manual-settings.json"
mv "${temporary}/manual-settings.json" \
  "${temporary}/repository/config/manual-settings.json"
assert_invalid 'an organization pin path that omits the public profile flow'
reset_repository

sed -i '2a title: ""' "${forms}/bug.yml"
assert_invalid 'an empty issue-form title'
reset_repository

sed -i '2a type: Bug' "${forms}/bug.yml"
assert_invalid 'direct issue-form type metadata'
reset_repository

sed -i 's/^labels: \["bug"\]$/labels: []/' "${forms}/bug.yml"
assert_invalid 'an empty issue-form labels array'
reset_repository

sed -i '/^labels:/d' "${forms}/bug.yml"
assert_invalid 'a bug form without an inference label'
reset_repository

sed -i 's/^labels: \["enhancement"\]$/labels: ["documentation"]/' \
  "${forms}/feature.yml"
assert_invalid 'a feature form label outside feature type inference'
reset_repository

sed -i '2a labels: ["bug"]' "${forms}/task.yml"
assert_invalid 'a labeled task form that bypasses default type inference'
reset_repository

jq '.type_inference.default = "Feature"' \
  "${temporary}/repository/config/planning.json" \
  >"${temporary}/planning.json"
mv "${temporary}/planning.json" \
  "${temporary}/repository/config/planning.json"
assert_invalid 'a non-Task default issue type'

echo "Community-health validation rejects incompatible issue-form metadata."
