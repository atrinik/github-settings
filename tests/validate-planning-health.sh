#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
cp -R "${root}/." "${temporary}/repository"

assert_invalid() {
  local filter=$1
  local description=$2

  jq "${filter}" "${root}/config/planning-health.json" \
    >"${temporary}/repository/config/planning-health.json"
  if ATRINIK_VALIDATION_TODAY=2026-08-11 \
    "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
    echo "error: validator accepted ${description}" >&2
    exit 1
  fi
}

ATRINIK_VALIDATION_TODAY=2026-08-11 \
  "${temporary}/repository/bin/validate" >/dev/null

assert_invalid '.freshness_threshold_minutes = 30' \
  'a freshness threshold below the best-effort schedule tolerance'
assert_invalid '.consecutive_failure_threshold = 1' \
  'an alert on the first synchronization failure'
assert_invalid '.incident_marker = "<!-- changed -->"' \
  'an unstable managed-incident marker'
assert_invalid '.incident_actor = "untrusted-user"' \
  'an untrusted managed-incident actor'
assert_invalid '.monitoring_owner = ""' \
  'planning health without an accountable owner'
assert_invalid '.monitor_workflow = "missing.yml"' \
  'a missing monitoring workflow'
assert_invalid '.credential_value = "secret"' \
  'an unexpected planning-health field'

echo "Planning health validation tests passed."
