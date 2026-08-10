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
method=GET
endpoint=
declare -a field_names=()
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  --method)
    method=$2
    shift 2
    ;;
  -f)
    field_names+=("${2%%=*}")
    if [[ ${2%%=*} == body ]]; then
      printf '%s\n' "${2#*=}" >"${FAKE_GH_BODY}"
    fi
    shift 2
    ;;
  *)
    endpoint=$1
    shift
    ;;
  esac
done
printf '%s\t%s\t%s\n' "${method}" "${endpoint}" "${field_names[*]:-}" \
  >>"${FAKE_GH_LOG}"

if [[ ${FAKE_GH_SCENARIO} == runs-api-failure && \
  ${endpoint} == *'runs?per_page=100' ]]; then
  echo "gh: workflow runs request failed" >&2
  exit 45
elif [[ ${FAKE_GH_SCENARIO} == incident-api-failure && \
  ${endpoint} == *'issues?state=all'* ]]; then
  echo "gh: incident listing failed" >&2
  exit 46
elif [[ ${FAKE_GH_SCENARIO} == alert-api-failure && \
  ${method} == POST ]]; then
  echo "gh: incident creation failed" >&2
  exit 47
fi

case ${endpoint} in
"repos/atrinik/github-settings/actions/workflows/sync-project.yml/runs?per_page=100")
  case ${FAKE_GH_SCENARIO} in
  healthy | missing-settings | recovery | recurrence-before | reopen | \
    incident-api-failure)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T04:49:00Z",
      updated_at: "2026-08-10T04:50:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/100",
      head_sha: "SUCCESS"
    }]}'
    ;;
  repeated-failure)
    jq -n '{workflow_runs: [
      {
        status: "completed", conclusion: "failure",
        created_at: "2026-08-10T04:58:00Z",
        updated_at: "2026-08-10T04:59:00Z",
        html_url: "https://github.com/atrinik/github-settings/actions/runs/102",
        head_sha: "FAIL2"
      },
      {
        status: "completed", conclusion: "failure",
        created_at: "2026-08-10T04:48:00Z",
        updated_at: "2026-08-10T04:49:00Z",
        html_url: "https://github.com/atrinik/github-settings/actions/runs/101",
        head_sha: "FAIL1"
      },
      {
        status: "completed", conclusion: "success",
        created_at: "2026-08-10T04:39:00Z",
        updated_at: "2026-08-10T04:40:00Z",
        html_url: "https://github.com/atrinik/github-settings/actions/runs/100",
        head_sha: "SUCCESS"
      }
    ]}'
    ;;
  stale | sync-failure | foreign | multiple-managed | alert-api-failure)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T01:59:00Z",
      updated_at: "2026-08-10T02:00:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/90",
      head_sha: "STALE"
    }]}'
    ;;
  no-success)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "failure",
      created_at: "2026-08-10T04:58:00Z",
      updated_at: "2026-08-10T04:59:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/103",
      head_sha: "FAIL"
    }]}'
    ;;
  never-ran)
    jq -n '{workflow_runs: []}'
    ;;
  recurrence-after)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T04:57:00Z",
      updated_at: "2026-08-10T04:58:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/104",
      head_sha: "NEW-SUCCESS"
    }]}'
    ;;
  old-success)
    jq -n '{workflow_runs: [range(0; 100) | {
      status: "completed", conclusion: "failure",
      created_at: "2026-08-10T04:00:00Z",
      updated_at: "2026-08-10T04:01:00Z",
      html_url: ("https://github.com/atrinik/github-settings/actions/runs/" + tostring),
      head_sha: "FAIL"
    }]}'
    ;;
  *) exit 1 ;;
  esac
  ;;
"repos/atrinik/github-settings/actions/workflows/sync-project.yml/runs?status=success&per_page=1")
  case ${FAKE_GH_SCENARIO} in
  healthy | missing-settings | recovery | recurrence-before | reopen | \
    incident-api-failure)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T04:49:00Z",
      updated_at: "2026-08-10T04:50:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/100",
      head_sha: "SUCCESS"
    }]}'
    ;;
  repeated-failure)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T04:39:00Z",
      updated_at: "2026-08-10T04:40:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/100",
      head_sha: "SUCCESS"
    }]}'
    ;;
  stale | sync-failure | foreign | multiple-managed | alert-api-failure)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T01:59:00Z",
      updated_at: "2026-08-10T02:00:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/90",
      head_sha: "STALE"
    }]}'
    ;;
  recurrence-after)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-10T04:57:00Z",
      updated_at: "2026-08-10T04:58:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/104",
      head_sha: "NEW-SUCCESS"
    }]}'
    ;;
  old-success)
    jq -n '{workflow_runs: [{
      status: "completed", conclusion: "success",
      created_at: "2026-08-07T00:59:00Z",
      updated_at: "2026-08-07T01:00:00Z",
      html_url: "https://github.com/atrinik/github-settings/actions/runs/1",
      head_sha: "OLD-SUCCESS"
    }]}'
    ;;
  no-success | never-ran) jq -n '{workflow_runs: []}' ;;
  *) exit 1 ;;
  esac
  ;;
"repos/atrinik/github-settings/issues?state=all&per_page=100&page=1")
  case ${FAKE_GH_SCENARIO} in
  recovery | stale | recurrence-before | recurrence-after)
    jq -n '[range(0; 100) | {
      number: (. + 1000),
      state: "closed",
      created_at: "2026-08-09T04:00:00Z",
      body: "unmanaged",
      user: {login: "someone"}
    }]'
    ;;
  reopen)
    jq -n '[{
      number: 70,
      state: "closed",
      created_at: "2026-08-01T04:00:00Z",
      body: "<!-- atrinik-project-sync-health -->\n<!-- atrinik-project-sync-health-episode: 2026-08-01T04:00:00Z -->",
      user: {login: "github-actions[bot]"}
    }]'
    ;;
  foreign)
    jq -n '[range(0; 2) | {
      number: (. + 80),
      state: "open",
      created_at: "2026-08-10T04:00:00Z",
      body: "<!-- atrinik-project-sync-health -->",
      user: {login: ("attacker-" + tostring)}
    }]'
    ;;
  multiple-managed)
    jq -n '[range(0; 2) | {
      number: (. + 90),
      state: "open",
      created_at: "2026-08-10T04:00:00Z",
      body: "<!-- atrinik-project-sync-health -->\n<!-- atrinik-project-sync-health-episode: 2026-08-10T04:00:00Z -->",
      user: {login: "github-actions[bot]"}
    }]'
    ;;
  *) jq -n '[]' ;;
  esac
  ;;
"repos/atrinik/github-settings/issues?state=all&per_page=100&page=2")
  case ${FAKE_GH_SCENARIO} in
  recovery | stale | recurrence-before | recurrence-after)
    episode="2026-08-10T04:00:00Z"
    [[ ${FAKE_GH_SCENARIO} == recurrence-before || \
      ${FAKE_GH_SCENARIO} == recurrence-after ]] && \
      episode="2026-08-10T04:55:00Z"
    jq -n --arg episode "${episode}" '{
      number: 70,
      state: "open",
      created_at: "2026-08-10T04:00:00Z",
      body: ("<!-- atrinik-project-sync-health -->\n<!-- atrinik-project-sync-health-episode: " + $episode + " -->"),
      user: {login: "github-actions[bot]"}
    } | [.]'
    ;;
  *) jq -n '[]' ;;
  esac
  ;;
repos/atrinik/github-settings/issues)
  [[ ${method} == POST ]]
  jq -n '{number: 70, state: "open"}'
  ;;
repos/atrinik/github-settings/issues/70)
  [[ ${method} == PATCH ]]
  jq -n '{number: 70}'
  ;;
*) exit 1 ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

cat >"${temporary}/bin/env" <<'EOF'
#!/usr/bin/env bash

echo "error: health check exposed the settings token through env arguments" >&2
exit 99
EOF
chmod +x "${temporary}/bin/env"

cat >"${temporary}/bin/sync-plan" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

[[ ${GH_TOKEN:-} == settings-token ]]
printf '%s\n' "${FAKE_SYNC_SCENARIO}" >>"${FAKE_SYNC_LOG}"
if [[ ${FAKE_SYNC_SCENARIO} == failure ]]; then
  echo "error: Project authorization denied" >&2
  exit 1
fi
mutations=0
[[ ${FAKE_SYNC_SCENARIO} == pending ]] && mutations=6
cat <<PLAN
PLAN project 1 (Atrinik work)
Open issues and pull requests: 10
Currently tracked items: 10
Items to add: ${mutations}
Open-item status changes: 0
Closed-item moves to Done: 0
Issue types to set: 0 (Initiative 0, Feature 0, Bug 0, Task 0)
Total mutations: ${mutations}
PLAN
EOF
chmod +x "${temporary}/bin/sync-plan"

run_health() {
  local gh_scenario=$1
  local sync_scenario=$2
  shift 2

  PATH="${temporary}/bin:${PATH}" \
    FAKE_GH_LOG="${temporary}/gh.log" \
    FAKE_GH_BODY="${temporary}/gh-body" \
    FAKE_GH_SCENARIO="${gh_scenario}" \
    FAKE_SYNC_LOG="${temporary}/sync.log" \
    FAKE_SYNC_SCENARIO="${sync_scenario}" \
    GITHUB_ACTIONS=true \
    GITHUB_REPOSITORY=atrinik/github-settings \
    GH_TOKEN=health-token \
    ATRINIK_SETTINGS_TOKEN=settings-token \
    ATRINIK_PROJECT_HEALTH_NOW=2026-08-10T05:00:00Z \
    ATRINIK_PROJECT_HEALTH_SYNC_COMMAND="${temporary}/bin/sync-plan" \
    ATRINIK_VALIDATION_TODAY=2026-08-10 \
    GITHUB_STEP_SUMMARY="${temporary}/step-summary" \
    "${root}/bin/check-project-health" "$@"
}

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
: >"${temporary}/step-summary"
output=$(run_health healthy zero)
grep -Fq 'State: **healthy**' <<<"${output}"
grep -Fq 'Convergence: converged; mutations 0' <<<"${output}"
grep -Fq 'State: **healthy**' "${temporary}/step-summary"
[[ $(wc -l <"${temporary}/gh.log") == 2 ]]

for failure in runs-api-failure:45:plan \
  incident-api-failure:46:apply alert-api-failure:47:apply; do
  scenario=${failure%%:*}
  remainder=${failure#*:}
  expected_status=${remainder%%:*}
  mode=${remainder#*:}
  arguments=()
  [[ ${mode} == apply ]] && arguments=(--apply)
  : >"${temporary}/gh.log"
  : >"${temporary}/sync.log"
  set +e
  run_health "${scenario}" pending "${arguments[@]}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
  grep -Fq 'GitHub API operation failed' "${temporary}/${scenario}.err"
done
grep -Fq 'read sync-project.yml workflow runs' \
  "${temporary}/runs-api-failure.err"
grep -Fq 'list Project health incidents (page 1)' \
  "${temporary}/incident-api-failure.err"
grep -Fq 'create Project health incident' \
  "${temporary}/alert-api-failure.err"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health repeated-failure zero --apply \
  >"${temporary}/failure.out" 2>"${temporary}/failure.err"; then
  echo "error: health check accepted repeated synchronization failures" >&2
  exit 1
fi
grep -Fq '2 consecutive synchronization runs failed' \
  "${temporary}/failure.out"
grep -Fq 'ALERT created managed Project health incident' \
  "${temporary}/failure.out"
grep -Fq $'POST\trepos/atrinik/github-settings/issues\t' \
  "${temporary}/gh.log"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health stale pending --apply \
  >"${temporary}/stale.out" 2>"${temporary}/stale.err"; then
  echo "error: health check accepted stale synchronization" >&2
  exit 1
fi
grep -Fq 'The last successful synchronization is 180 minutes old' \
  "${temporary}/stale.out"
grep -Fq 'ALERT updated managed Project health incident #70' \
  "${temporary}/stale.out"
grep -Fq $'PATCH\trepos/atrinik/github-settings/issues/70\t' \
  "${temporary}/gh.log"
! grep -Fq $'POST\trepos/atrinik/github-settings/issues\t' \
  "${temporary}/gh.log" || {
  echo "error: stale check created a duplicate incident" >&2
  exit 1
}

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=missing-settings \
  FAKE_GH_BODY="${temporary}/gh-body" \
  FAKE_SYNC_LOG="${temporary}/sync.log" FAKE_SYNC_SCENARIO=zero \
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=atrinik/github-settings \
  GH_TOKEN=health-token ATRINIK_SETTINGS_TOKEN='' \
  ATRINIK_PROJECT_HEALTH_NOW=2026-08-10T05:00:00Z \
  ATRINIK_PROJECT_HEALTH_SYNC_COMMAND="${temporary}/bin/sync-plan" \
  ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${root}/bin/check-project-health" --apply \
  >"${temporary}/missing.out" 2>"${temporary}/missing.err"; then
  echo "error: health check accepted a missing settings credential" >&2
  exit 1
fi
grep -Fq 'ATRINIK_SETTINGS_TOKEN is unavailable to the health workflow' \
  "${temporary}/missing.out"
grep -Fq 'ALERT created managed Project health incident' \
  "${temporary}/missing.out"
[[ ! -s ${temporary}/sync.log ]]

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
output=$(run_health recovery zero --apply)
grep -Fq 'State: **healthy**' <<<"${output}"
grep -Fq 'RECOVERED managed Project health incident #70' <<<"${output}"
grep -Fq $'PATCH\trepos/atrinik/github-settings/issues/70\tbody state state_reason' \
  "${temporary}/gh.log"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health recurrence-before zero --apply \
  >"${temporary}/recurrence-before.out" \
  2>"${temporary}/recurrence-before.err"; then
  echo "error: health check resolved an incident with a pre-episode success" >&2
  exit 1
fi
grep -Fq 'remains open until a newer successful run' \
  "${temporary}/recurrence-before.out"
grep -Fq 'ALERT updated managed Project health incident #70' \
  "${temporary}/recurrence-before.out"
if grep -Fq 'RECOVERED' "${temporary}/recurrence-before.out"; then
  echo "error: pre-episode success produced a recovery message" >&2
  exit 1
fi

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
output=$(run_health recurrence-after zero --apply)
grep -Fq 'RECOVERED managed Project health incident #70' <<<"${output}"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health foreign pending --apply \
  >"${temporary}/foreign.out" 2>"${temporary}/foreign.err"; then
  echo "error: health check accepted stale synchronization" >&2
  exit 1
fi
grep -Fq 'ALERT created managed Project health incident' \
  "${temporary}/foreign.out"
grep -Fq $'POST\trepos/atrinik/github-settings/issues\t' \
  "${temporary}/gh.log"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health multiple-managed pending --apply \
  >"${temporary}/multiple.out" 2>"${temporary}/multiple.err"; then
  echo "error: health check accepted multiple genuine managed incidents" >&2
  exit 1
fi
grep -Fq 'multiple managed Project health incidents exist' \
  "${temporary}/multiple.err"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
: >"${temporary}/gh-body"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=reopen \
  FAKE_GH_BODY="${temporary}/gh-body" \
  FAKE_SYNC_LOG="${temporary}/sync.log" FAKE_SYNC_SCENARIO=zero \
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=atrinik/github-settings \
  GH_TOKEN=health-token ATRINIK_SETTINGS_TOKEN='' \
  ATRINIK_PROJECT_HEALTH_NOW=2026-08-10T05:00:00Z \
  ATRINIK_PROJECT_HEALTH_SYNC_COMMAND="${temporary}/bin/sync-plan" \
  ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${root}/bin/check-project-health" --apply \
  >"${temporary}/reopen.out" 2>"${temporary}/reopen.err"; then
  echo "error: health check accepted a missing credential during recurrence" >&2
  exit 1
fi
grep -Fq '<!-- atrinik-project-sync-health-episode: 2026-08-10T05:00:00Z -->' \
  "${temporary}/gh-body"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health sync-failure failure --apply \
  >"${temporary}/sync-failure.out" 2>"${temporary}/sync-failure.err"; then
  echo "error: health check accepted a failed convergence preflight" >&2
  exit 1
fi
grep -Fq 'could not produce a read-only Project convergence plan' \
  "${temporary}/sync-failure.out"
grep -Fq 'sync preflight: error: Project authorization denied' \
  "${temporary}/sync-failure.err"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health no-success zero \
  >"${temporary}/no-success.out" 2>"${temporary}/no-success.err"; then
  echo "error: health check accepted missing successful run history" >&2
  exit 1
fi
grep -Fq 'No successful sync-project.yml run exists' \
  "${temporary}/no-success.out"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health never-ran zero \
  >"${temporary}/never-ran.out" 2>"${temporary}/never-ran.err"; then
  echo "error: health check accepted a workflow that never ran" >&2
  exit 1
fi
grep -Fq 'No successful sync-project.yml run exists' \
  "${temporary}/never-ran.out"

: >"${temporary}/gh.log"
: >"${temporary}/sync.log"
if run_health old-success zero \
  >"${temporary}/old-success.out" 2>"${temporary}/old-success.err"; then
  echo "error: health check accepted more than 100 failures" >&2
  exit 1
fi
grep -Fq '2026-08-07T01:00:00Z' "${temporary}/old-success.out"
grep -Fq 'actions/runs/1' "${temporary}/old-success.out"

if rg -n 'health-token|settings-token' "${temporary}"/*.out \
  "${temporary}"/*.err "${temporary}/step-summary" >/dev/null; then
  echo "error: health output exposed credential material" >&2
  exit 1
fi

echo "Project health checks cover freshness, failures, missing credentials, deduplication, and recovery."
