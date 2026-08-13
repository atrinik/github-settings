#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

make_case() {
  local name=$1
  local case_root=${temporary}/${name}

  mkdir -p "${case_root}/bin"
  cp "${root}/bin/validate" "${case_root}/bin/validate"
  cp -R "${root}/config" "${case_root}/config"
  cp -R "${root}/community-health" "${case_root}/community-health"
  printf '%s\n' "${case_root}"
}

expect_invalid_retirement() {
  local name=$1
  local filter=$2
  local case_root output

  case_root=$(make_case "${name}")
  output=${case_root}/config/retired-maintenance-branches.next.json
  jq "${filter}" \
    "${case_root}/config/retired-maintenance-branches.json" >"${output}"
  mv "${output}" "${case_root}/config/retired-maintenance-branches.json"
  if "${case_root}/bin/validate" >/dev/null 2>&1; then
    echo "expected retired-maintenance validation failure: ${name}" >&2
    exit 1
  fi
}

"${root}/bin/validate" >/dev/null

expect_invalid_retirement invalid-commit \
  '.retirements[0].final_branch_commit = "not-a-commit"'
expect_invalid_retirement duplicate-asset \
  '.retirements[0].final_release.assets += ["SHA256SUMS"]'
expect_invalid_retirement duplicate-ci \
  '.retirements[0].ruleset.required_ci += ["Content validation"]'
expect_invalid_retirement duplicate-preserved-id '
  .retirements[0].preserved_rulesets +=
    [{id: 20522685, name: "duplicate identity"}]
'
expect_invalid_retirement duplicate-coordinate '
  .retirements += [
    .retirements[0] |
    .ruleset.id = 99999999
  ]
'
expect_invalid_retirement duplicate-ruleset-id '
  .retirements += [
    .retirements[0] |
    .repository = "other" |
    .repository_id = 99999999 |
    .ruleset.name = "05 - Maintenance branch - other - 1.x"
  ]
'

overlap_root=$(make_case active-overlap)
jq '.maintenance_branches = [{
  repository: "content",
  branch: "1.x",
  required_ci: ["Content validation", "Conventional PR title"]
}]' "${overlap_root}/config/repositories.json" \
  >"${overlap_root}/config/repositories.next.json"
mv "${overlap_root}/config/repositories.next.json" \
  "${overlap_root}/config/repositories.json"
if "${overlap_root}/bin/validate" >/dev/null 2>&1; then
  echo "expected active and retired maintenance overlap to fail" >&2
  exit 1
fi

echo "Retired-maintenance validation tests passed."
