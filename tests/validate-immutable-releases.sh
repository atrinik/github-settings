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

expect_invalid() {
  local name=$1
  local filter=$2
  local case_root output

  case_root=$(make_case "${name}")
  output=${case_root}/config/immutable-releases.next.json
  jq "${filter}" \
    "${case_root}/config/immutable-releases.json" >"${output}"
  mv "${output}" "${case_root}/config/immutable-releases.json"
  if "${case_root}/bin/validate" >/dev/null 2>&1; then
    echo "expected immutable-release validation failure: ${name}" >&2
    exit 1
  fi
}

"${root}/bin/validate" >/dev/null

expect_invalid mode-all '.enforced_repositories = "all"'
expect_invalid invalid-id '.repositories[0].id = 0'
expect_invalid duplicate-id '
  .repositories += [{id: .repositories[0].id, name: "content"}]
'
expect_invalid archived-repository '
  .repositories = [{id: 1, name: "nawerhals"}]
'
expect_invalid unsorted-repositories '
  .repositories = [
    {id: 101, name: "content"},
    {id: 1327289971, name: "classic"}
  ]
'

echo "Immutable-release validation tests passed."
