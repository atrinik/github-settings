#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=${ATRINIK_PUBLISH_TEST_ROOT:-${root}}
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${temporary}/"

reject() {
  local file=$1 filter=$2
  jq "${filter}" "${root}/config/${file}" >"${temporary}/config/${file}"
  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: accepted invalid security policy ${file}: ${filter}" >&2
    exit 1
  fi
  cp "${root}/config/${file}" "${temporary}/config/${file}"
}

"${temporary}/bin/validate" >/dev/null
reject security-merge-protection.json '.dependency_review += ["legacy-client"]'
reject security-merge-protection.json '.code_scanning -= ["service-updater"]'
reject security-merge-protection.json '.dependency_review += ["web-platform"]'
reject security-merge-protection.json '.codeql_required_languages["content-toolkit"] = []'
reject security-merge-protection.json '.codeql_required_languages.classic = ["rust"]'
reject security-merge-protection.json '.codeql_required_languages.server = ["invented"]'
reject rulesets/code-scanning.json '.bypass_actors[0].bypass_mode = "always"'
reject rulesets/code-scanning.json '.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = "critical"'
reject rulesets/code-scanning.json '.rules[0].parameters.code_scanning_tools[0].alerts_threshold = "errors"'
reject rulesets/dependency-review.json '.rules[0].parameters.required_status_checks[0].integration_id = null'
reject actions-permissions.json '.sha_pinning_required = false'
reject actions-sha-pinning.json '.phase = "pending" | .canary = "atrinik/github-settings/99"'
reject actions-sha-pinning.json '.phase = "enforced" | .canary = null'
reject actions-sha-pinning.json '.phase = "enforced" | .canary = "atrinik/unregistered/99"'
reject actions-sha-pinning.json '.phase = "enforced" | .canary = "foreign/github-settings/99"'
reject actions-sha-pinning.json '.phase = "enforced" | .canary = "atrinik/github-settings/0"'
reject actions-sha-pinning.json '.phase = "unknown"'
reject actions-sha-pinning.json '.phase = null'
reject actions-sha-pinning.json '.unexpected = true'

# Reviewed enforced source binds its canary to a repository with required CI.
jq '.phase = "enforced" | .canary = "atrinik/github-settings/99"' \
  "${root}/config/actions-sha-pinning.json" >"${temporary}/config/actions-sha-pinning.json"
"${temporary}/bin/validate" >/dev/null
cp "${root}/config/actions-sha-pinning.json" "${temporary}/config/actions-sha-pinning.json"

# A coordinated target retirement is valid; unrelated governed policies stay.
jq 'del(.required_ci["service-updater"])' "${root}/config/repositories.json" \
  >"${temporary}/config/repositories.json"
jq '.code_scanning -= ["service-updater"] | .dependency_review -= ["service-updater"]' \
  "${root}/config/security-merge-protection.json" >"${temporary}/config/security-merge-protection.json"
"${temporary}/bin/validate" >/dev/null

echo 'Security merge policy validation tests passed.'
