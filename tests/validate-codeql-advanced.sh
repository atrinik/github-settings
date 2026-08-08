#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/validate"
cp -R "${root}/config" "${temporary}/config"

assert_invalid() {
  local description=$1

  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
}

rewrite_json() {
  local filter=$1
  local path=$2
  local output

  output=$(mktemp)
  jq "${filter}" "${path}" >"${output}"
  mv "${output}" "${path}"
}

rewrite_json '.repositories += ["classic"]' \
  "${temporary}/config/codeql-advanced-setup.json"
assert_invalid 'a duplicate advanced CodeQL inventory entry'
cp "${root}/config/codeql-advanced-setup.json" \
  "${temporary}/config/codeql-advanced-setup.json"

rewrite_json '.repositories = ["legacy-client"]' \
  "${temporary}/config/codeql-advanced-setup.json"
assert_invalid 'an archived advanced CodeQL inventory repository'
cp "${root}/config/codeql-advanced-setup.json" \
  "${temporary}/config/codeql-advanced-setup.json"

rewrite_json '.secret_scanning = "disabled"' \
  "${temporary}/config/code-security-advanced.json"
assert_invalid 'advanced security configuration drift from the baseline'
cp "${root}/config/code-security-advanced.json" \
  "${temporary}/config/code-security-advanced.json"

rewrite_json '.code_scanning_options.allow_advanced = true' \
  "${temporary}/config/code-security.json"
assert_invalid 'advanced setup in the ordinary security baseline'
cp "${root}/config/code-security.json" \
  "${temporary}/config/code-security.json"

rewrite_json '.state = "configured"' \
  "${temporary}/config/codeql-default-setup-advanced.json"
assert_invalid 'configured default setup for an advanced CodeQL repository'

echo "Advanced CodeQL validation tests passed."
