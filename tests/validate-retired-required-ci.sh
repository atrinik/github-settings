#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${temporary}/"
"${temporary}/bin/validate" >/dev/null
printf '{"retirements":[{"repository":"web-platform","repository_id":123,"ruleset_id":3,"required_ci":["Platform validation","Conventional PR title"]}]}\n' >"${temporary}/valid.json"
cp "${temporary}/valid.json" "${temporary}/config/retired-required-ci.json"
"${temporary}/bin/validate" >/dev/null
for filter in \
  '.retirements[0].repository = "client"' '.retirements[0].repository = "legacy-client"' \
  '.retirements[0].repository = "unknown"' '.retirements[0].required_ci = []' \
  '.retirements[0].required_ci = [""]' '.retirements[0].required_ci = ["   "]' \
  '.retirements[0].required_ci = ["Duplicate", "Duplicate"]' \
  '.retirements[0].required_ci = [null]' '.retirements[0].repository_id = 0' \
  '.retirements[0].ruleset_id = -1' '.retirements[0].ruleset_id = "3"' \
  '.retirements[0].repository_id = 1.5' '.retirements += [.retirements[0]]' \
  '.retirements[0].unknown_field = true' 'del(.retirements[0].ruleset_id)'; do
  jq "${filter}" "${temporary}/valid.json" >"${temporary}/config/retired-required-ci.json"
  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: accepted invalid required-CI retirement: ${filter}" >&2
    exit 1
  fi
done
echo 'Required-CI retirement schema tests passed.'
