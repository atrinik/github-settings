#!/usr/bin/env bash

# Sourced production functions consume the globals below.
# shellcheck disable=SC2034
set -euo pipefail

source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# An override permits testing the integrated candidate from an isolated worktree.
source_root=${ATRINIK_PUBLISH_TEST_ROOT:-${source_root}}
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
root=${temporary}/fixture
mkdir -p "${root}/bin" "${root}/config/rulesets"
cp "${source_root}/config/"*.json "${root}/config/"
cp "${source_root}/config/rulesets/"*.json "${root}/config/rulesets/"

# Source production functions without executing validation, authentication or
# live publication. Every API call is replaced below by a fail-closed mock.
sed -n '/^converge_organization_settings() {/,/^organization_metadata=/p' \
  "${source_root}/bin/publish" | sed '$d' >"${temporary}/functions.sh"
# shellcheck source=/dev/null
source "${temporary}/functions.sh"
# Exercise the production scope dispatch, including its following gate call.
awk '
  /^if \[\[ \$\{policy_scope\} == organization \]\]; then$/ { capture = 1 }
  capture { print }
  capture && /^publish_security_merge_rulesets$/ { exit }
' "${source_root}/bin/publish" >"${temporary}/dispatch.sh"
[[ -s ${temporary}/dispatch.sh ]]

organization=atrinik
apply=true
temporary_files=()
security_merge_config=${root}/config/security-merge-protection.json
codeql_advanced_config=${root}/config/codeql-advanced-setup.json
active_repositories=(content-toolkit)
declare -A active_repository_ids=([content-toolkit]=123)
api_log=${temporary}/api.jsonl
readiness_log=${temporary}/readiness.jsonl
export READINESS_LOG=${readiness_log}
cat >"${root}/bin/security-readiness" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg mode "$1" --arg repository "$2" \
  '{mode: $mode, repository: $repository}' >>"${READINESS_LOG}"
case ${READINESS_STATUS:-ready} in
ready) echo 'producer evidence ready'; exit 0 ;;
missing) echo 'producer is missing'; exit 1 ;;
failed) echo 'producer failed'; exit 1 ;;
unreadable) echo 'producer evidence unreadable'; exit 2 ;;
*) exit 99 ;;
esac
MOCK
chmod +x "${root}/bin/security-readiness"

# Minimal live response fixtures preserve the API shapes used by the publisher.
github_api() {
  local endpoint=$1
  jq -cn --arg endpoint "${endpoint}" \
    '{method: "GET", endpoint: $endpoint}' >>"${api_log}"
  case ${endpoint} in
  repos/atrinik/content-toolkit/code-scanning/default-setup)
    [[ ${codeql_state} != unreadable ]] || return 1
    printf '%s\n' "${codeql_state}"
    ;;
  'repos/atrinik/content-toolkit/rulesets?includes_parents=false')
    if [[ ${ruleset_state} == missing ]]; then
      echo '[]'
    else
      jq -n --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [{id: 6, name: $codeql[0].name}, {id: 7, name: $dependency[0].name}]'
    fi
    ;;
  repos/atrinik/content-toolkit/rulesets/6 | repos/atrinik/content-toolkit/rulesets/7)
    local template=code-scanning
    [[ ${endpoint##*/} != 7 ]] || template=dependency-review
    if [[ ${ruleset_state} == exact ]]; then
      jq '. + {id: 100, source_type: "Repository"}' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == owner-null ]]; then
      jq '.bypass_actors[0].actor_id = null' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == active-drift ]]; then
      jq '.bypass_actors = []' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == active-unrelated-gate ]]; then
      if [[ ${template} == code-scanning ]]; then
        jq '.rules[0].parameters.code_scanning_tools[0].tool = "Another scanner"' \
          "${root}/config/rulesets/${template}.json"
      else
        jq '.rules[0].parameters.required_status_checks[0].integration_id = 999' \
          "${root}/config/rulesets/${template}.json"
      fi
    elif [[ ${ruleset_state} == active-without-gate ]]; then
      jq '.rules = []' "${root}/config/rulesets/${template}.json"
    else
      jq '.enforcement = "disabled"' "${root}/config/rulesets/${template}.json"
    fi
    ;;
  orgs/atrinik/actions/permissions) printf '%s\n' "${actions_state}" ;;
  *) echo "unexpected mock API: ${endpoint}" >&2; return 99 ;;
  esac
}

run_api() {
  jq -cn --arg method "$1" --arg endpoint "$2" --slurpfile payload "$3" \
    '{method: $method, endpoint: $endpoint, payload: $payload[0]}' >>"${api_log}"
}
reset_case() {
  : >"${api_log}"
  : >"${readiness_log}"
  codeql_state='{"state":"configured","query_suite":"default","languages":["python","javascript-typescript"]}'
  ruleset_state=missing
  actions_state='{"enabled_repositories":"selected","allowed_actions":"all","sha_pinning_required":false}'
  sha_pinning_canary=
  export READINESS_STATUS=ready
}
assert_no_writes() {
  jq -se 'all(.[]; .method == "GET")' "${api_log}" >/dev/null
}

reset_case
converge_codeql_default_setup >"${temporary}/languages.txt"
jq -se '
  [.[] | select(.method == "PATCH")] == [{
    method: "PATCH",
    endpoint: "repos/atrinik/content-toolkit/code-scanning/default-setup",
    payload: {state: "configured", query_suite: "default",
      languages: ["javascript-typescript", "python", "rust"]}
  }]' "${api_log}" >/dev/null
reset_case
codeql_state='{"state":"configured","query_suite":"default","languages":["actions","javascript","javascript-typescript","python","typescript"]}'
converge_codeql_default_setup >"${temporary}/languages-aliases.txt"
jq -se '[.[] | select(.method == "PATCH")][0].payload.languages ==
  ["actions", "javascript-typescript", "python", "rust"]' "${api_log}" >/dev/null
reset_case
codeql_state='{"state":"configured","query_suite":"default","languages":["rust","python"]}'
converge_codeql_default_setup >"${temporary}/languages-keep.txt"
assert_no_writes
reset_case
codeql_state=unreadable
if converge_codeql_default_setup >"${temporary}/languages-error.txt" 2>&1; then
  echo 'expected unreadable language inventory to fail closed' >&2
  exit 1
fi
assert_no_writes
reset_case
codeql_state='{"state":"configured","query_suite":"default","languages":null}'
if converge_codeql_default_setup >"${temporary}/languages-malformed.txt" 2>&1; then
  echo 'expected malformed language inventory to fail closed' >&2
  exit 1
fi
assert_no_writes

# Use the actual dispatch: security producer readiness follows base convergence
# for both scopes, and these Team-compatible gates always target repositories.
publish_organization_rulesets() { echo organization-rules >>"${temporary}/order"; }
publish_organization_security() { echo organization-security >>"${temporary}/order"; }
publish_repository_rulesets() { echo repository-rules >>"${temporary}/order"; }
publish_repository_security() { echo repository-security >>"${temporary}/order"; }
for policy_scope in organization repository; do
  for producer in missing failed unreadable ready; do
    reset_case
    export READINESS_STATUS=${producer}
    : >"${temporary}/order"
    # shellcheck source=/dev/null
    source "${temporary}/dispatch.sh" >"${temporary}/${policy_scope}-${producer}.txt"
    [[ $(cat "${temporary}/order") == "${policy_scope}-rules"$'\n'"${policy_scope}-security" ]]
    if [[ ${producer} == ready ]]; then
      jq -se --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [.[] | select(.method != "GET")] == [
          {method: "POST", endpoint: "repos/atrinik/content-toolkit/rulesets", payload: $codeql[0]},
          {method: "POST", endpoint: "repos/atrinik/content-toolkit/rulesets", payload: $dependency[0]}
        ]' "${api_log}" >/dev/null
    else
      assert_no_writes
    fi
    jq -se '[.[].mode] == ["codeql", "dependency"] and
      all(.[]; .repository == "atrinik/content-toolkit")' "${readiness_log}" >/dev/null
    jq -se 'all(.[]; .endpoint | startswith("repos/atrinik/content-toolkit/"))' \
      "${api_log}" >/dev/null
  done
done

reset_case
ruleset_state=exact
export READINESS_STATUS=failed
publish_security_merge_rulesets >"${temporary}/exact.txt"
assert_no_writes
[[ ! -s ${readiness_log} ]]
reset_case
ruleset_state=owner-null
export READINESS_STATUS=failed
publish_security_merge_rulesets >"${temporary}/owner-null.txt"
assert_no_writes
[[ ! -s ${readiness_log} ]]
reset_case
ruleset_state=active-drift
export READINESS_STATUS=failed
publish_security_merge_rulesets >"${temporary}/active-drift.txt"
jq -se '[.[] | select(.method != "GET")] | length == 2 and
  all(.[]; .method == "PUT" and .payload.enforcement == "active")' \
  "${api_log}" >/dev/null
[[ ! -s ${readiness_log} ]]
for ruleset_state in disabled active-without-gate active-unrelated-gate; do
  : >"${api_log}"
  : >"${readiness_log}"
  export READINESS_STATUS=failed
  publish_security_merge_rulesets >"${temporary}/${ruleset_state}.txt"
  assert_no_writes
  jq -se '[.[].mode] == ["codeql", "dependency"]' "${readiness_log}" >/dev/null
done

# An archived or missing repository is absent from the active identity map.
reset_case
active_repository_ids=()
publish_security_merge_rulesets >"${temporary}/inactive.txt"
[[ ! -s ${api_log} && ! -s ${readiness_log} ]]
active_repository_ids=([content-toolkit]=123)

reset_case
converge_actions_permissions >"${temporary}/sha-deferred.txt"
jq -se '[.[] | select(.method == "PUT")][0].payload ==
  {enabled_repositories: "all", allowed_actions: "selected"}' "${api_log}" >/dev/null
[[ ! -s ${readiness_log} ]]
reset_case
actions_state='{"enabled_repositories":"selected","allowed_actions":"all","sha_pinning_required":true}'
converge_actions_permissions >"${temporary}/sha-retained.txt"
jq -se '[.[] | select(.method == "PUT")][0].payload.sha_pinning_required == true' \
  "${api_log}" >/dev/null
[[ ! -s ${readiness_log} ]]
reset_case
sha_pinning_canary=atrinik/github-settings/99
export READINESS_STATUS=failed
converge_actions_permissions >"${temporary}/sha-failed.txt"
jq -se '[.[] | select(.method == "PUT")][0].payload | has("sha_pinning_required") | not' \
  "${api_log}" >/dev/null
reset_case
sha_pinning_canary=atrinik/github-settings/99
converge_actions_permissions >"${temporary}/sha-ready.txt"
jq -se --slurpfile desired "${root}/config/actions-permissions.json" '
  [.[] | select(.method == "PUT")][0].payload == $desired[0]' "${api_log}" >/dev/null
jq -se '. == [{mode: "sha", repository: "atrinik/github-settings/99"}]' \
  "${readiness_log}" >/dev/null
reset_case
actions_state=$(cat "${root}/config/actions-permissions.json")
converge_actions_permissions >"${temporary}/sha-keep.txt"
assert_no_writes

rm -f "${temporary_files[@]}"
echo 'Security merge publisher tests passed.'
