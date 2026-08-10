#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir "${temporary}/bin"

cat >"${temporary}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

[[ ${1:-} == api ]] || exit 1
shift
endpoint=
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  *)
    endpoint=$1
    shift
    ;;
  esac
done
printf '%s\n' "${endpoint}" >>"${FAKE_GH_LOG}"

if [[ ${FAKE_GH_SCENARIO} == api-failure ]]; then
  echo "gh: repository administration denied" >&2
  exit 41
fi
case ${endpoint} in
repos/atrinik/github-settings)
  if [[ ${FAKE_GH_SCENARIO} == identity-drift ]]; then
    jq -n '{id: 1}'
  else
    jq -n '{id: 1324382941}'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing ]]; then
    jq -n '{total_count: 0, secrets: []}'
  elif [[ ${FAKE_GH_SCENARIO} == page2 || \
    ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    jq -n '{
      total_count: 101,
      secrets: [range(0; 100) | {
        name: ("UNRELATED_" + tostring),
        created_at: "2026-08-01T00:00:00Z",
        updated_at: "2026-08-01T00:00:00Z"
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == shared-repository ]]; then
    jq -n '{
      total_count: 2,
      secrets: [
        {
          name: "ATRINIK_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        },
        {
          name: "SECOND_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        }
      ]
    }'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "ATRINIK_SETTINGS_TOKEN",
        created_at: "2026-08-10T02:13:48Z",
        updated_at: "2026-08-10T02:13:48Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    echo "gh: second secret page failed" >&2
    exit 42
  fi
  [[ ${FAKE_GH_SCENARIO} == page2 ]]
  jq -n '{
    total_count: 101,
    secrets: [{
      name: "ATRINIK_SETTINGS_TOKEN",
      created_at: "2026-08-10T02:13:48Z",
      updated_at: "2026-08-10T02:13:48Z"
    }]
  }'
  ;;
*) exit 1 ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

run_verify() {
  local scenario=$1

  PATH="${temporary}/bin:${PATH}" \
    FAKE_GH_LOG="${temporary}/gh.log" \
    FAKE_GH_SCENARIO="${scenario}" \
    GITHUB_ACTIONS=true GH_TOKEN=test-token \
    ATRINIK_VALIDATION_TODAY=2026-08-10 \
    "${root}/bin/verify-manual-settings"
}

: >"${temporary}/gh.log"
output=$(run_verify present)
grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'Manual settings live credential metadata is present.' <<<"${output}"

: >"${temporary}/gh.log"
output=$(run_verify page2)
grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'page=2' "${temporary}/gh.log"

shared_root=${temporary}/shared-repository
mkdir -p "${shared_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" \
  "${shared_root}/bin/"
cp -R "${root}/config" "${shared_root}/config"
cp -R "${root}/community-health" "${shared_root}/community-health"
cp -R "${root}/.github" "${shared_root}/.github"
jq '
  .github_actions_credentials += [
    .github_actions_credentials[0] |
    .secret_name = "SECOND_SETTINGS_TOKEN"
  ]
' "${root}/config/manual-settings.json" \
  >"${shared_root}/config/manual-settings.json"
: >"${temporary}/gh.log"
output=$(PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" \
  FAKE_GH_SCENARIO=shared-repository \
  GITHUB_ACTIONS=true GH_TOKEN=test-token \
  ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${shared_root}/bin/verify-manual-settings")
grep -Fq 'SECOND_SETTINGS_TOKEN' <<<"${output}"
[[ $(grep -Fc 'repos/atrinik/github-settings' "${temporary}/gh.log") == 2 ]]

for scenario in missing identity-drift api-failure page2-failure; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'MISSING atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  "${temporary}/missing.err"
grep -Fq 'repository identity drift' "${temporary}/identity-drift.err"
grep -Fq 'gh: repository administration denied' "${temporary}/api-failure.err"
grep -Fq 'read atrinik/github-settings identity' "${temporary}/api-failure.err"
grep -Fq 'gh: second secret page failed' "${temporary}/page2-failure.err"
grep -Fq 'page 2' "${temporary}/page2-failure.err"

for failure in api-failure:41 page2-failure:42; do
  scenario=${failure%%:*}
  expected_status=${failure#*:}
  : >"${temporary}/gh.log"
  set +e
  run_verify "${scenario}" \
    >"${temporary}/${scenario}-status.out" \
    2>"${temporary}/${scenario}-status.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
done

: >"${temporary}/gh.log"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=present \
  GITHUB_ACTIONS=true GH_TOKEN='' ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${root}/bin/verify-manual-settings" \
  >"${temporary}/empty.out" 2>"${temporary}/empty.err"; then
  echo "error: manual-settings verifier accepted an empty workflow credential" >&2
  exit 1
fi
grep -Fq 'ATRINIK_SETTINGS_TOKEN is unavailable' "${temporary}/empty.err"
[[ ! -s ${temporary}/gh.log ]]

echo "Manual settings live credential verification tests passed."
