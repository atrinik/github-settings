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
actions_sha_pinning_config=${root}/config/actions-sha-pinning.json
active_repositories=(content-toolkit)
declare -A active_repository_ids=([content-toolkit]=123)
api_log=${temporary}/api.jsonl
readiness_log=${temporary}/readiness.jsonl
export READINESS_LOG=${readiness_log}
export MOCK_API_LOG=${api_log}
export MOCK_ACTIONS_POLICY=${temporary}/actions-policy.json
export MOCK_ACTIONS_SELECTED=${root}/config/actions-selected.json
cat >"${root}/bin/security-readiness" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg mode "$1" --arg repository "$2" \
  '{mode: $mode, repository: $repository}' >>"${READINESS_LOG}"
if [[ $1 == sha ]]; then
  jq -cn '{method: "PROOF", endpoint: "sha"}' >>"${MOCK_API_LOG}"
  if [[ ${CHECK_POLICY_STAGED:-false} == true ]]; then
    jq -e --slurpfile selected "${MOCK_ACTIONS_SELECTED}" '
      .permissions.allowed_actions == "selected" and
      .permissions.enabled_repositories == "all" and
      .selected == $selected[0]
    ' "${MOCK_ACTIONS_POLICY}" >/dev/null || exit 98
  fi
fi
case ${READINESS_STATUS:-ready} in
ready) echo 'producer evidence ready'; exit 0 ;;
missing) echo 'producer is missing'; exit 1 ;;
failed) echo 'producer failed'; exit 1 ;;
stale) echo 'canary base changed during preflight'; exit 1 ;;
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
  repos/atrinik/content-toolkit)
    if [[ -n ${gate_metadata_after_proof_filter} ]] &&
      jq -se 'any(.[]; .endpoint | contains("/rules/branches/"))' "${api_log}" >/dev/null; then
      [[ ${gate_metadata_after_proof_filter} != unreadable ]] || return 1
      jq "${gate_metadata_after_proof_filter}" <<<"${repository_state}"
    elif [[ -n ${gate_metadata_filter} ]]; then
      [[ ${gate_metadata_filter} != unreadable ]] || return 1
      jq "${gate_metadata_filter}" <<<"${repository_state}"
    else
      printf '%s\n' "${repository_state}"
    fi
    ;;
  repos/atrinik/content-toolkit/rules/branches/main | repos/atrinik/content-toolkit/rules/branches/release%2Fcurrent)
    if [[ ${effective_state} == covering ]]; then
      jq -n --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [$codeql[0].rules[] + {ruleset_id: 6},
         $dependency[0].rules[] + {ruleset_id: 7}]'
    elif [[ ${effective_state} == different-id ]]; then
      jq -n --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [$codeql[0].rules[] + {ruleset_id: 600},
         $dependency[0].rules[] + {ruleset_id: 700}]'
    else
      echo '[]'
    fi
    ;;
  repos/atrinik/content-toolkit/actions/permissions/workflow)
    [[ ${workflow_state} != unreadable ]] || return 1
    printf '%s\n' "${workflow_state}"
    ;;
  repos/atrinik/content-toolkit/code-scanning/default-setup)
    if [[ ${codeql_state} == http-* ]]; then
      echo "gh: default-setup read failed (HTTP ${codeql_state#http-})" >&2
      return 1
    fi
    [[ ${codeql_state} != unreadable ]] || return 1
    printf '%s\n' "${codeql_state}"
    ;;
  'repos/atrinik/content-toolkit/rulesets?includes_parents=false')
    if [[ ${ruleset_state} == missing ]]; then
      echo '[]'
    else
      jq -n --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [{id: 1, name: "01 - Default branch integrity"},
         {id: 3, name: "03 - Required CI"},
         {id: 6, name: $codeql[0].name}, {id: 7, name: $dependency[0].name}]'
    fi
    ;;
  repos/atrinik/content-toolkit/rulesets/6 | repos/atrinik/content-toolkit/rulesets/7)
    local template=code-scanning
    [[ ${endpoint##*/} != 7 ]] || template=dependency-review
    if [[ ${ruleset_state} == pending-branch-race ]]; then
      jq --argjson id "${endpoint##*/}" --argjson target "${gate_update_id}" \
        --arg branch "$(jq -r '.default_branch' <<<"${repository_state}")" '
        . + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} |
        if $id == $target then .conditions.ref_name.include = [("refs/heads/" + $branch)] else . end' \
        "${root}/config/rulesets/${template}.json"
      return
    elif [[ ${ruleset_state} == restoration-race || ${ruleset_state} == retirement-race ]]; then
      local filter=.
      if [[ ${endpoint##*/} == "${gate_update_id}" ]] &&
        (( $(jq -s --arg endpoint "${endpoint}" '[.[] | select(.endpoint == $endpoint)] | length' "${api_log}") >= 2 )); then
        [[ ${gate_update_filter} != unreadable ]] || return 1
        filter=${gate_update_filter}
      fi
      jq --argjson id "${endpoint##*/}" --argjson target "${gate_update_id}" --arg state "${ruleset_state}" '
        . + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} |
        if $id == $target and $state == "restoration-race" then .enforcement = "disabled" else . end' \
        "${root}/config/rulesets/${template}.json" | jq "${filter}"
      return
    elif [[ ${ruleset_state} == api-default-* ]]; then
      jq --argjson id "${endpoint##*/}" --arg state "${ruleset_state}" '
        . + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} |
        .bypass_actors[0].actor_id = null |
        if $id == 7 then
          .rules[0].parameters.do_not_enforce_on_create =
            (if $state == "api-default-false" then false
             elif $state == "api-default-true" then true else null end) |
          if $state == "api-default-unknown" then
            .rules[0].parameters.do_not_enforce_on_create = false |
            .rules[0].parameters.unknown_future_control = false
          else . end
        else . end' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == exact || ${ruleset_state} == removal-owned ]]; then
      jq --argjson id "${endpoint##*/}" \
        '. + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"}' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == removal-owner-null ]]; then
      jq --argjson id "${endpoint##*/}" \
        '. + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} |
         .bypass_actors[0].actor_id = null' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == removal-foreign ]]; then
      jq --argjson id "${endpoint##*/}" \
        '. + {id: $id, source_type: "Organization", source: "atrinik"}' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == removal-id-drift ]]; then
      jq '. + {id: 999, source_type: "Repository", source: "atrinik/content-toolkit"}' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == removal-name-collision ]]; then
      jq --argjson id "${endpoint##*/}" \
        '. + {id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} |
         .rules = [{type: "deletion"}, {type: "non_fast_forward"}]' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == owner-null ]]; then
      jq '.bypass_actors[0].actor_id = null' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == foreign-repository-source ]]; then
      jq '.source = "foreign/content-toolkit"' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == extra-rule ]]; then
      jq '.rules += [{type: "deletion"}]' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == unknown-rule-parameter ]]; then
      jq '.rules[0].parameters.unknown_future_control = true' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == unknown-condition ]]; then
      jq '.conditions.unknown_future_scope = {}' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == active-wrong-ref ]]; then
      jq '.conditions.ref_name.include = ["refs/heads/feature"]' \
        "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == active-drift ]]; then
      jq '.conditions.ref_name.include = ["refs/heads/main"]' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == active-bypass-drift ]]; then
      jq '.bypass_actors = []' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == unknown-ref-condition ]]; then
      jq '.conditions.ref_name.unknown_future_scope = true' "${root}/config/rulesets/${template}.json"
    elif [[ ${ruleset_state} == changed-severity ]]; then
      if [[ ${template} == code-scanning ]]; then
        jq '.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = "critical"' \
          "${root}/config/rulesets/${template}.json"
      else
        cat "${root}/config/rulesets/${template}.json"
      fi
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
    fi | jq --argjson id "${endpoint##*/}" \
      '{id: $id, source_type: "Repository", source: "atrinik/content-toolkit"} + .'
    ;;
  orgs/atrinik/actions/permissions) printf '%s\n' "${actions_state}" ;;
  orgs/atrinik/actions/permissions/selected-actions)
    # Model the API prerequisite: the dormant list cannot be read or changed
    # until the publisher has staged conservative selected mode.
    [[ $(jq -r '.allowed_actions' <<<"${actions_state}") == selected ]] || return 1
    [[ ${selected_state} != unreadable ]] || return 1
    printf '%s\n' "${selected_state}"
    ;;
  *) echo "unexpected mock API: ${endpoint}" >&2; return 99 ;;
  esac
}

run_api() {
  if [[ $1 == DELETE ]]; then
    jq -cn --arg endpoint "$2" '{method: "DELETE", endpoint: $endpoint}' >>"${api_log}"
    return
  fi
  jq -cn --arg method "$1" --arg endpoint "$2" --slurpfile payload "$3" \
    '{method: $method, endpoint: $endpoint, payload: $payload[0]}' >>"${api_log}"
  if ${apply}; then
    case $2 in
    orgs/atrinik/actions/permissions)
      actions_state=$(jq --slurpfile payload "$3" '. * $payload[0]' <<<"${actions_state}")
      ;;
    orgs/atrinik/actions/permissions/selected-actions)
      [[ $(jq -r '.allowed_actions' <<<"${actions_state}") == selected ]] || return 1
      selected_state=$(cat "$3")
      case ${staging_race} in
      disable | replace-repository)
        actions_state=$(jq '.sha_pinning_required = false' <<<"${actions_state}")
        if [[ ${staging_race} == replace-repository ]]; then
          repository_state=$(jq '.id = 999' <<<"${repository_state}")
        fi
        ;;
      malformed)
        actions_state=$(jq '.sha_pinning_required = "false"' <<<"${actions_state}")
        ;;
      esac
      ;;
    esac
    if [[ ${selected_state} != unreadable ]]; then
      jq -n --argjson permissions "${actions_state}" --argjson selected "${selected_state}" \
        '{permissions:$permissions, selected:$selected}' >"${MOCK_ACTIONS_POLICY}"
    fi
  fi
}
reset_case() {
  : >"${api_log}"
  : >"${readiness_log}"
  codeql_state='{"state":"configured","query_suite":"default","languages":["python","javascript-typescript"]}'
  ruleset_state=missing
  gate_update_id=6
  gate_update_filter=.
  gate_metadata_filter=
  gate_metadata_after_proof_filter=
  effective_state=covering
  repository_state='{"id":123,"full_name":"atrinik/content-toolkit","archived":false,"default_branch":"main"}'
  workflow_state='{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
  cp "${source_root}/config/security-merge-protection.json" "${security_merge_config}"
  cp "${source_root}/config/codeql-advanced-setup.json" "${codeql_advanced_config}"
  echo '{"phase":"pending","canary":null}' >"${actions_sha_pinning_config}"
  actions_state='{"enabled_repositories":"selected","allowed_actions":"all","sha_pinning_required":false}'
  selected_state=$(cat "${root}/config/actions-selected.json")
  sha_pinning_canary=
  staging_race=
  apply=true
  export CHECK_POLICY_STAGED=false
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

# Read failures are fatal even without a language minimum, in both setup modes.
for setup_kind in default advanced; do
  for http_status in 403 404 500; do
    reset_case
    jq '.codeql_required_languages = {}' "${security_merge_config}" >"${temporary}/no-minima.json"
    cp "${temporary}/no-minima.json" "${security_merge_config}"
    if [[ ${setup_kind} == advanced ]]; then
      echo '{"repositories":["content-toolkit"]}' >"${codeql_advanced_config}"
    fi
    codeql_state=http-${http_status}
    if converge_codeql_default_setup >"${temporary}/languages-${setup_kind}-${http_status}.txt" 2>&1; then
      echo 'expected unreadable default setup to fail publication without a language minimum' >&2
      exit 1
    fi
    grep -q 'cannot read existing CodeQL languages' "${temporary}/languages-${setup_kind}-${http_status}.txt"
    assert_no_writes
  done
done
reset_case
jq '.codeql_required_languages = {}' "${security_merge_config}" >"${temporary}/no-minima.json"
cp "${temporary}/no-minima.json" "${security_merge_config}"
codeql_state='{"state":"configured","query_suite":"default","languages":["python"]}'
converge_codeql_default_setup >"${temporary}/languages-readable-no-minimum.txt"
assert_no_writes
echo '{"repositories":["content-toolkit"]}' >"${codeql_advanced_config}"
codeql_state='{"state":"not-configured","languages":null}'
converge_codeql_default_setup >"${temporary}/languages-readable-advanced-null.txt"
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
    assert_no_writes
    if [[ ${producer} == ready ]]; then
      [[ $(grep -c '^READY ' "${temporary}/${policy_scope}-${producer}.txt") == 2 ]]
    fi
    jq -se '[.[].mode] == ["codeql", "dependency"] and
      all(.[]; .repository == "atrinik/content-toolkit")' "${readiness_log}" >/dev/null
    jq -se 'all(.[]; .endpoint | startswith("repos/atrinik/content-toolkit/"))' \
      "${api_log}" >/dev/null
  done
done

# Reviewed enforced intent precedes initial installation and survives deletion,
# disablement, and ref drift independently of current producer health.
for policy_scope in organization repository; do
  for producer in failed unreadable; do
    for state in missing disabled active-wrong-ref; do
      reset_case
      ruleset_state=${state}
      effective_state=absent
      export READINESS_STATUS=${producer}
      jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
        "${security_merge_config}" >"${temporary}/enforced.json"
      cp "${temporary}/enforced.json" "${security_merge_config}"
      # shellcheck source=/dev/null
      source "${temporary}/dispatch.sh" >"${temporary}/enforced-${policy_scope}-${producer}-${state}.txt"
      method=PUT
      [[ ${state} != missing ]] || method=POST
      jq -se --arg method "${method}" \
        --slurpfile codeql "${root}/config/rulesets/code-scanning.json" \
        --slurpfile dependency "${root}/config/rulesets/dependency-review.json" '
        [.[] | select(.method != "GET")] |
        [.[].payload] == [$codeql[0], $dependency[0]] and
        all(.[]; .method == $method)' "${api_log}" >/dev/null
      [[ ! -s ${readiness_log} ]]
    done
  done
done

# Changes made after the initial GET cannot be erased by restoration PUT.
for policy_scope in organization repository; do
  for gate_update_target in 6 7; do
    common_filters=(
      '.id = 999' '.source_type = "Organization"' '.source = "foreign/content-toolkit"'
      '.name = "Renamed gate"' '.target = "tag"' '.enforcement = "unknown"'
      '.bypass_actors[0].bypass_mode = "always"' '.bypass_actors = []'
      '.rules[0].parameters.unknown_future_control = true'
      '.conditions.ref_name.unknown_future_scope = true' '.rules += [{type:"deletion"}]'
      'unreadable'
    )
    if [[ ${gate_update_target} == 6 ]]; then
      common_filters+=(
        '.rules[0].parameters.code_scanning_tools[0].tool = "Other tool"'
        '.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = "critical"'
      )
    else
      common_filters+=(
        '.rules[0].parameters.required_status_checks[0].context = "Unrelated context"'
        '.rules[0].parameters.required_status_checks[0].integration_id = 9'
        '.rules[0].parameters.do_not_enforce_on_create = true'
        '.rules[0].parameters.do_not_enforce_on_create = null'
      )
    fi
    for filter in "${common_filters[@]}"; do
      reset_case
      ruleset_state=restoration-race
      gate_update_id=${gate_update_target}
      gate_update_filter=${filter}
      jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
        "${security_merge_config}" >"${temporary}/enforced.json"
      cp "${temporary}/enforced.json" "${security_merge_config}"
      # shellcheck source=/dev/null
      if source "${temporary}/dispatch.sh" >"${temporary}/concurrent-gate.txt" 2>&1; then
        echo "expected concurrent gate change to be retained: ${filter}" >&2
        exit 1
      fi
      assert_no_writes
      grep -Fq 'retained:' "${temporary}/concurrent-gate.txt"
      jq -se --arg endpoint "repos/atrinik/content-toolkit/rulesets/${gate_update_id}" \
        '[.[] | select(.endpoint == $endpoint)] | length == 2' "${api_log}" >/dev/null
    done
    # Unchanged ownership, explicit API defaults, and allowed enforcement/ref
    # restoration still converge; a concurrent completed repair causes KEEP.
    for filter in '.' \
      '.bypass_actors[0].actor_id = null | if .rules[0].type == "required_status_checks" then .rules[0].parameters.do_not_enforce_on_create = false else . end' \
      '.enforcement = "evaluate" | .conditions.ref_name.include = ["refs/heads/other"]' \
      '.enforcement = "active"'; do
      reset_case
      ruleset_state=restoration-race
      gate_update_id=${gate_update_target}
      gate_update_filter=${filter}
      jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
        "${security_merge_config}" >"${temporary}/enforced.json"
      cp "${temporary}/enforced.json" "${security_merge_config}"
      # shellcheck source=/dev/null
      source "${temporary}/dispatch.sh" >"${temporary}/safe-concurrent-gate.txt"
      if [[ ${filter} == '.enforcement = "active"' ]]; then
        assert_no_writes
      else
        jq -se --arg endpoint "repos/atrinik/content-toolkit/rulesets/${gate_update_id}" '
          [.[] | select(.method != "GET")] | length == 1 and
          .[0].method == "PUT" and .[0].endpoint == $endpoint' "${api_log}" >/dev/null
      fi
    done
    for filter in '.archived = true' '.id = 999' '.full_name = "foreign/content-toolkit"' unreadable; do
      reset_case
      ruleset_state=restoration-race
      gate_update_id=${gate_update_target}
      gate_metadata_filter=${filter}
      jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
        "${security_merge_config}" >"${temporary}/enforced.json"
      cp "${temporary}/enforced.json" "${security_merge_config}"
      # shellcheck source=/dev/null
      if source "${temporary}/dispatch.sh" >"${temporary}/fresh-repository.txt" 2>&1; then
        echo 'expected fresh repository identity/archive/read failure to block PUT' >&2
        exit 1
      fi
      assert_no_writes
    done
  done
done

# Pending existing-gate restoration is authorized only for the exact default
# branch whose effective protection was checked, even if another branch is valid.
for policy_scope in organization repository; do
  for pending_gate_id in 6 7; do
    for filter in '.default_branch = "new-main"' '.default_branch = "release/next"' \
      '.default_branch = null' 'del(.default_branch)' unreadable '.'; do
      reset_case
      ruleset_state=pending-branch-race
      gate_update_id=${pending_gate_id}
      gate_metadata_after_proof_filter=${filter}
      export READINESS_STATUS=failed
      jq '.activation |= with_entries(.value |= with_entries(.value = "pending"))' \
        "${security_merge_config}" >"${temporary}/pending.json"
      cp "${temporary}/pending.json" "${security_merge_config}"
      status=0
      # shellcheck source=/dev/null
      source "${temporary}/dispatch.sh" >"${temporary}/pending-branch-fence.txt" 2>&1 || status=$?
      if [[ ${filter} == '.' ]]; then
        [[ ${status} == 0 ]]
        jq -se --arg endpoint "repos/atrinik/content-toolkit/rulesets/${pending_gate_id}" '
          [.[] | select(.method != "GET")] | length == 1 and
          .[0].method == "PUT" and .[0].endpoint == $endpoint' "${api_log}" >/dev/null
      else
        [[ ${status} != 0 ]]
        assert_no_writes
        if [[ ${filter} == '.default_branch = "'* ]]; then
          grep -Fq 'default branch changed after existing security gate proof; retained' \
            "${temporary}/pending-branch-fence.txt"
        fi
      fi
      jq -se 'any(.[]; .endpoint == "repos/atrinik/content-toolkit/rules/branches/main")' \
        "${api_log}" >/dev/null
      [[ ! -s ${readiness_log} ]]
      cmp "${temporary}/pending.json" "${security_merge_config}"
    done
  done
  # Durable enforced intent still restores missing gates on the current default.
  reset_case
  ruleset_state=missing
  gate_metadata_filter='.default_branch = "new-main"'
  export READINESS_STATUS=failed
  jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
    "${security_merge_config}" >"${temporary}/enforced.json"
  cp "${temporary}/enforced.json" "${security_merge_config}"
  # shellcheck source=/dev/null
  source "${temporary}/dispatch.sh" >"${temporary}/enforced-current-default.txt"
  jq -se '[.[] | select(.method != "GET")] | length == 2 and all(.[]; .method == "POST")' \
    "${api_log}" >/dev/null
  [[ ! -s ${readiness_log} ]]
done

# The two gate phases are independent; qualification does not mutate source.
reset_case
export READINESS_STATUS=failed
jq '.activation.code_scanning["content-toolkit"] = "enforced"' \
  "${security_merge_config}" >"${temporary}/mixed.json"
cp "${temporary}/mixed.json" "${security_merge_config}"
publish_security_merge_rulesets >"${temporary}/mixed.txt"
jq -se '[.[] | select(.method != "GET")] | length == 1 and
  .[0].payload.name == "06 - CodeQL security"' "${api_log}" >/dev/null
jq -se '[.[].mode] == ["dependency"]' "${readiness_log}" >/dev/null
cmp "${temporary}/mixed.json" "${security_merge_config}"

# Enforced restoration preserves foreign/ambiguous same-name rules and rejects
# archived or replaced repositories at the point of mutation.
for state in removal-foreign removal-id-drift removal-name-collision active-unrelated-gate active-without-gate unknown-rule-parameter unknown-condition unknown-ref-condition active-bypass-drift changed-severity foreign-repository-source extra-rule; do
  reset_case
  ruleset_state=${state}
  jq '.activation |= with_entries(.value |= with_entries(.value = "enforced"))' \
    "${security_merge_config}" >"${temporary}/enforced.json"
  cp "${temporary}/enforced.json" "${security_merge_config}"
  if publish_security_merge_rulesets >"${temporary}/enforced-collision-${state}.txt" 2>&1; then
    echo 'expected enforced gate ownership collision to fail closed' >&2
    exit 1
  fi
  assert_no_writes
  [[ ! -s ${readiness_log} ]]
done
for kind in code_scanning dependency_review; do
  for metadata in \
    '{"id":123,"full_name":"atrinik/content-toolkit","archived":true,"default_branch":"main"}' \
    '{"id":999,"full_name":"atrinik/content-toolkit","archived":false,"default_branch":"main"}' \
    '{"id":123,"full_name":"atrinik/renamed-toolkit","archived":false,"default_branch":"main"}' \
    '{"id":123,"full_name":"foreign/content-toolkit","archived":false,"default_branch":"main"}'; do
    reset_case
    export READINESS_STATUS=failed
    repository_state=${metadata}
    jq --arg kind "${kind}" '.activation[$kind]["content-toolkit"] = "enforced"' \
      "${security_merge_config}" >"${temporary}/enforced.json"
    cp "${temporary}/enforced.json" "${security_merge_config}"
    if publish_security_merge_rulesets >"${temporary}/enforced-metadata-${kind}.txt" 2>&1; then
      echo 'expected enforced repository identity fence to fail closed' >&2
      exit 1
    fi
    assert_no_writes
    jq -se --arg mode "$([[ ${kind} == code_scanning ]] && echo codeql || echo dependency)" \
      'all(.[]; .mode != $mode)' "${readiness_log}" >/dev/null
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
ruleset_state=disabled
effective_state=absent
: >"${api_log}"
: >"${readiness_log}"
export READINESS_STATUS=failed
publish_security_merge_rulesets >"${temporary}/${ruleset_state}.txt"
assert_no_writes
jq -se '[.[].mode] == ["codeql", "dependency"]' "${readiness_log}" >/dev/null

# An active rule on another ref does not grandfather a new default-branch gate.
for effective_state in absent different-id; do
  : >"${api_log}"
  : >"${readiness_log}"
  ruleset_state=active-wrong-ref
  export READINESS_STATUS=missing
  publish_security_merge_rulesets >"${temporary}/wrong-ref-${effective_state}.txt"
  assert_no_writes
  jq -se '[.[].mode] == ["codeql", "dependency"]' "${readiness_log}" >/dev/null
done
reset_case
ruleset_state=active-drift
repository_state='{"id":123,"full_name":"atrinik/content-toolkit","archived":false,"default_branch":"release/current"}'
export READINESS_STATUS=failed
publish_security_merge_rulesets >"${temporary}/encoded-ref.txt"
jq -se 'any(.[]; .endpoint == "repos/atrinik/content-toolkit/rules/branches/release%2Fcurrent") and
  ([.[] | select(.method == "PUT")] | length == 2)' "${api_log}" >/dev/null
[[ ! -s ${readiness_log} ]]

# Stale identities and archived metadata cannot grandfather a gate.
for repository_state in '{"id":999,"archived":false,"default_branch":"main"}' '{"id":123,"archived":true,"default_branch":"main"}'; do
  : >"${api_log}"
  : >"${readiness_log}"
  ruleset_state=active-drift
  effective_state=covering
  export READINESS_STATUS=missing
  publish_security_merge_rulesets >"${temporary}/metadata-drift.txt"
  assert_no_writes
  jq -se '[.[].mode] == ["codeql", "dependency"]' "${readiness_log}" >/dev/null
done

# Exact repository-owned retired targets are removed; foreign collisions stay.
for removal in removal-owned removal-owner-null removal-foreign removal-id-drift removal-name-collision; do
  reset_case
  ruleset_state=${removal}
  jq '.code_scanning -= ["content-toolkit"] | .dependency_review -= ["content-toolkit"] | del(.activation.code_scanning["content-toolkit"], .activation.dependency_review["content-toolkit"])' \
    "${security_merge_config}" >"${temporary}/removed.json"
  cp "${temporary}/removed.json" "${security_merge_config}"
  publish_security_merge_rulesets >"${temporary}/${removal}.txt"
  if [[ ${removal} == removal-owned || ${removal} == removal-owner-null ]]; then
    jq -se '[.[] | select(.method != "GET")] == [
      {method: "DELETE", endpoint: "repos/atrinik/content-toolkit/rulesets/6"},
      {method: "DELETE", endpoint: "repos/atrinik/content-toolkit/rulesets/7"}
    ]' "${api_log}" >/dev/null
  else
    assert_no_writes
    grep -q '^SKIP ' "${temporary}/${removal}.txt"
  fi
  [[ ! -s ${readiness_log} ]]
done

# GitHub expands an omitted create-exemption flag to false. Both publisher
# scopes must keep exact active API payloads and retire only exact owned gates.
for policy_scope in organization repository; do
  reset_case
  ruleset_state=api-default-false
  export READINESS_STATUS=failed
  : >"${temporary}/order"
  # shellcheck source=/dev/null
  source "${temporary}/dispatch.sh" >"${temporary}/${policy_scope}-api-default-keep.txt"
  assert_no_writes
  [[ ! -s ${readiness_log} ]]
  grep -Fq 'KEEP /repos/atrinik/content-toolkit/rulesets/7 07 - Dependency review' \
    "${temporary}/${policy_scope}-api-default-keep.txt"
  for default_state in false true null unknown; do
    reset_case
    ruleset_state=api-default-${default_state}
    jq '.dependency_review -= ["content-toolkit"] | del(.activation.dependency_review["content-toolkit"])' \
      "${security_merge_config}" >"${temporary}/removed.json"
    cp "${temporary}/removed.json" "${security_merge_config}"
    : >"${temporary}/order"
    # shellcheck source=/dev/null
    source "${temporary}/dispatch.sh" >"${temporary}/${policy_scope}-api-default-${default_state}.txt"
    if [[ ${default_state} == false ]]; then
      jq -se '[.[] | select(.method != "GET")] == [
        {method: "DELETE", endpoint: "repos/atrinik/content-toolkit/rulesets/7"}
      ]' "${api_log}" >/dev/null
    else
      assert_no_writes
      grep -Fq '07 - Dependency review: unrecognized ownership or payload; retained' \
        "${temporary}/${policy_scope}-api-default-${default_state}.txt"
    fi
    [[ ! -s ${readiness_log} ]]
  done
done

# The final retirement GET must still prove exact managed ownership/payload
# after the repository fence, including for changes that PUT may restore.
for policy_scope in organization repository; do
  for retired_gate_id in 6 7; do
    retired_kind=code_scanning
    [[ ${retired_gate_id} != 7 ]] || retired_kind=dependency_review
    retirement_filters=(
      '.id = 999' '.source_type = "Organization"' '.source = "foreign/content-toolkit"'
      '.name = "Renamed gate"' '.enforcement = "disabled"' '.enforcement = "evaluate"'
      '.conditions.ref_name.include = ["refs/heads/other"]'
      '.conditions.ref_name.exclude = ["~DEFAULT_BRANCH"]'
      '.bypass_actors[0].bypass_mode = "always"' '.bypass_actors = []'
      '.rules[0].parameters.unknown_future_control = true' '.rules += [{type:"deletion"}]'
      'unreadable'
    )
    if [[ ${retired_gate_id} == 6 ]]; then
      retirement_filters+=(
        '.rules[0].parameters.code_scanning_tools[0].tool = "Other tool"'
        '.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = "critical"'
      )
    else
      retirement_filters+=(
        '.rules[0].parameters.required_status_checks[0].context = "Changed context"'
        '.rules[0].parameters.required_status_checks[0].integration_id = 9'
        '.rules[0].parameters.do_not_enforce_on_create = true'
        '.rules[0].parameters.do_not_enforce_on_create = null'
      )
    fi
    for filter in "${retirement_filters[@]}" '.' \
      '.bypass_actors[0].actor_id = null | if .rules[0].type == "required_status_checks" then .rules[0].parameters.do_not_enforce_on_create = false else . end'; do
      reset_case
      ruleset_state=retirement-race
      gate_update_id=${retired_gate_id}
      gate_update_filter=${filter}
      jq --arg kind "${retired_kind}" '.[$kind] -= ["content-toolkit"] |
        del(.activation[$kind]["content-toolkit"])' "${security_merge_config}" >"${temporary}/removed.json"
      cp "${temporary}/removed.json" "${security_merge_config}"
      status=0
      # shellcheck source=/dev/null
      source "${temporary}/dispatch.sh" >"${temporary}/retirement-race.txt" 2>&1 || status=$?
      if [[ ${filter} == unreadable ]]; then
        [[ ${status} != 0 ]]
        assert_no_writes
        grep -Fq 'final retirement read failed; retained' "${temporary}/retirement-race.txt"
      elif [[ ${filter} == '.' || ${filter} == '.bypass_actors[0].actor_id = null |'* ]]; then
        [[ ${status} == 0 ]]
        jq -se --arg endpoint "repos/atrinik/content-toolkit/rulesets/${retired_gate_id}" '
          [.[] | select(.method != "GET")] == [{method:"DELETE",endpoint:$endpoint}]' "${api_log}" >/dev/null
      else
        [[ ${status} == 0 ]]
        assert_no_writes
        grep -Fq 'rule changed during retirement preflight; retained' "${temporary}/retirement-race.txt"
      fi
      jq -se --arg endpoint "repos/atrinik/content-toolkit/rulesets/${retired_gate_id}" '
        [to_entries[] | select(.value.endpoint == $endpoint and .value.method == "GET") | .key] as $reads |
        ($reads | length) == 2 and
        any(to_entries[]; .key > $reads[0] and .key < $reads[1] and
          .value.endpoint == "repos/atrinik/content-toolkit")' "${api_log}" >/dev/null
      [[ ! -s ${readiness_log} ]]
    done
  done
done

# Retirements also fence a repository archived or replaced after enumeration.
for retired_state in '{"id":123,"archived":true}' '{"id":999,"archived":false}' \
  '{"id":123,"full_name":"foreign/content-toolkit","archived":false}'; do
  reset_case
  repository_state=${retired_state}
  ruleset_state="removal-owned"
  jq '.code_scanning -= ["content-toolkit"] | .dependency_review -= ["content-toolkit"] | del(.activation.code_scanning["content-toolkit"], .activation.dependency_review["content-toolkit"])' \
    "${security_merge_config}" >"${temporary}/removed.json"
  cp "${temporary}/removed.json" "${security_merge_config}"
  publish_security_merge_rulesets >"${temporary}/removed-state-changed.txt"
  assert_no_writes
  [[ ! -s ${readiness_log} ]]
done

# Read errors must propagate even when publication is called conditionally.
reset_case
ruleset_state="removal-owned"
gate_metadata_filter=unreadable
jq '.code_scanning -= ["content-toolkit"] | .dependency_review -= ["content-toolkit"] |
  del(.activation.code_scanning["content-toolkit"], .activation.dependency_review["content-toolkit"])' \
  "${security_merge_config}" >"${temporary}/removed.json"
cp "${temporary}/removed.json" "${security_merge_config}"
if publish_security_merge_rulesets >"${temporary}/retirement-metadata-unreadable.txt" 2>&1; then
  echo 'expected unreadable retirement repository metadata to fail closed' >&2
  exit 1
fi
assert_no_writes

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
jq -se '[.[] | select(.method == "PUT")][0].payload | has("sha_pinning_required") | not' \
  "${api_log}" >/dev/null
[[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == true ]]
[[ ! -s ${readiness_log} ]]
for producer in failed ready; do
  reset_case
  sha_pinning_canary=atrinik/content-toolkit/99
  export READINESS_STATUS=${producer}
  converge_actions_permissions >"${temporary}/sha-pending-${producer}.txt"
  jq -se '[.[] | select(.method == "PUT")][0].payload | has("sha_pinning_required") | not' \
    "${api_log}" >/dev/null
done
reset_case
echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
converge_actions_permissions >"${temporary}/sha-enforced-ready.txt"
jq -se --slurpfile desired "${root}/config/actions-permissions.json" '
  [.[] | select(.method == "PUT")][-1].payload == $desired[0]' "${api_log}" >/dev/null
jq -se '. == [{mode: "sha", repository: "atrinik/content-toolkit/99"}]' \
  "${readiness_log}" >/dev/null
for producer in failed unreadable; do
  reset_case
  echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
  export READINESS_STATUS=${producer}
  if converge_actions_permissions >"${temporary}/sha-enforced-${producer}.txt" 2>&1; then
    echo "expected enforced SHA evidence failure to fail closed: ${producer}" >&2
    exit 1
  fi
  jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null
done
reset_case
echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
actions_state=$(cat "${root}/config/actions-permissions.json")
export READINESS_STATUS=failed
converge_actions_permissions >"${temporary}/sha-keep.txt"
assert_no_writes
[[ ! -s ${readiness_log} ]]

# Explicit pending canary probes still run when SHA is already enabled.
for producer in ready failed unreadable stale; do
  reset_case
  actions_state=$(cat "${root}/config/actions-permissions.json")
  sha_pinning_canary=atrinik/content-toolkit/99
  export READINESS_STATUS=${producer}
  converge_actions_permissions >"${temporary}/sha-enabled-probe-${producer}.txt"
  jq -se '. == [{mode:"sha", repository:"atrinik/content-toolkit/99"}]' "${readiness_log}" >/dev/null
  jq -se 'all(.[]; .method == "GET" or .method == "PROOF")' "${api_log}" >/dev/null
  [[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == true ]]
  if [[ ${producer} == ready ]]; then
    grep -q '^READY canary evidence:' "${temporary}/sha-enabled-probe-${producer}.txt"
  else
    grep -q '^PENDING canary evidence:' "${temporary}/sha-enabled-probe-${producer}.txt"
  fi
done
for invalid in foreign/content-toolkit/99 atrinik/unregistered/99 replaced; do
  reset_case
  actions_state=$(cat "${root}/config/actions-permissions.json")
  sha_pinning_canary=${invalid}
  if [[ ${invalid} == replaced ]]; then
    sha_pinning_canary=atrinik/content-toolkit/99
    repository_state=$(jq '.id = 999' <<<"${repository_state}")
  fi
  if converge_actions_permissions >"${temporary}/sha-enabled-probe-invalid.txt" 2>&1; then
    echo 'expected invalid requested canary identity to fail with SHA already enabled' >&2
    exit 1
  fi
  assert_no_writes
  [[ ! -s ${readiness_log} ]]
  [[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == true ]]
done

# Simultaneous mode, patterns and SHA drift repairs conservative policy first.
for producer in ready failed unreadable; do
  reset_case
  echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
  selected_state='{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["old/action@*"]}'
  export CHECK_POLICY_STAGED=true
  export READINESS_STATUS=${producer}
  if converge_actions_permissions >"${temporary}/sha-staged-${producer}.txt" 2>&1; then
    [[ ${producer} == ready ]]
  else
    [[ ${producer} != ready ]]
  fi
  jq -se '
    [.[] | select(.method == "PUT" or .method == "PROOF")] as $events |
    $events[0].endpoint == "orgs/atrinik/actions/permissions" and
    ($events[0].payload | has("sha_pinning_required") | not) and
    $events[1].endpoint == "orgs/atrinik/actions/permissions/selected-actions" and
    $events[2].method == "PROOF"
  ' "${api_log}" >/dev/null
  if [[ ${producer} == ready ]]; then
    jq -se '[.[] | select(.method == "PUT" or .method == "PROOF")] |
      length == 4 and .[3].payload.sha_pinning_required == true' "${api_log}" >/dev/null
    # A second converged publication neither mutates nor re-proves retained SHA.
    : >"${api_log}"
    : >"${readiness_log}"
    converge_actions_permissions >"${temporary}/sha-staged-converged.txt"
    assert_no_writes
    [[ ! -s ${readiness_log} ]]
  else
    jq -se '[.[] | select(.method == "PUT" or .method == "PROOF")] | length == 3' "${api_log}" >/dev/null
    [[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == false ]]
  fi
done

# A disable concurrent with pattern staging must not reuse the initial true.
for producer in ready failed unreadable; do
  reset_case
  echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
  actions_state='{"enabled_repositories":"all","allowed_actions":"selected","sha_pinning_required":true}'
  selected_state='{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}'
  staging_race=disable
  export READINESS_STATUS=${producer}
  if converge_actions_permissions >"${temporary}/sha-concurrent-disable-${producer}.txt" 2>&1; then
    [[ ${producer} == ready ]]
  else
    [[ ${producer} != ready ]]
  fi
  jq -se '
    to_entries as $events |
    ([$events[] | select(.value.method == "PUT" and
      .value.endpoint == "orgs/atrinik/actions/permissions/selected-actions")][0].key) as $staged |
    ([$events[] | select(.key > $staged and .value.method == "GET" and
      .value.endpoint == "orgs/atrinik/actions/permissions")][0].key) as $read |
    ([$events[] | select(.key > $read and .value.method == "GET" and
      .value.endpoint == "repos/atrinik/content-toolkit")][0].key) as $identity |
    ([$events[] | select(.value.method == "PROOF")][0].key) as $proof |
    $staged < $read and $read < $identity and $identity < $proof and
    all($events[] | select(.key < $proof and .value.method == "PUT");
      .value.payload.sha_pinning_required != true)
  ' "${api_log}" >/dev/null
  if [[ ${producer} == ready ]]; then
    [[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == true ]]
    jq -se '.[-1].method == "PUT" and .[-1].payload.sha_pinning_required == true' "${api_log}" >/dev/null
  else
    [[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == false ]]
    jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null
  fi
done
for race in malformed replace-repository; do
  reset_case
  echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
  actions_state='{"enabled_repositories":"all","allowed_actions":"selected","sha_pinning_required":true}'
  selected_state='{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}'
  staging_race=${race}
  if converge_actions_permissions >"${temporary}/sha-concurrent-${race}.txt" 2>&1; then
    echo 'expected changed post-staging evidence to fail closed' >&2
    exit 1
  fi
  [[ ! -s ${readiness_log} ]]
  jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null
done
reset_case
actions_state='{"enabled_repositories":"all","allowed_actions":"selected","sha_pinning_required":true}'
selected_state='{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}'
staging_race=disable
converge_actions_permissions >"${temporary}/sha-concurrent-disable-pending.txt"
[[ $(jq -r '.sha_pinning_required' <<<"${actions_state}") == false ]]
[[ ! -s ${readiness_log} ]]
jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null

reset_case
echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
apply=false
converge_actions_permissions >"${temporary}/sha-stage-plan.txt" 2>&1
grep -q 'PLAN SHA pinning proof' "${temporary}/sha-stage-plan.txt"
if grep -Eq 'jq:|error:' "${temporary}/sha-stage-plan.txt"; then
  echo 'unexpected error in SHA staging dry run' >&2
  exit 1
fi
[[ ! -s ${readiness_log} ]]
jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null
[[ $(jq -r '.allowed_actions' <<<"${actions_state}") == all ]]

# An unreadable staged allowlist never reaches the canary or writes SHA.
reset_case
echo '{"phase":"enforced","canary":"atrinik/content-toolkit/99"}' >"${actions_sha_pinning_config}"
selected_state=unreadable
if converge_actions_permissions >"${temporary}/sha-staged-unreadable-policy.txt" 2>&1; then
  echo 'expected unreadable staged Actions policy to fail closed' >&2
  exit 1
fi
[[ ! -s ${readiness_log} ]]
jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null

# Pending rollout may repair policy and probe, but never enables SHA pinning.
reset_case
selected_state='{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}'
sha_pinning_canary=atrinik/content-toolkit/99
export CHECK_POLICY_STAGED=true
converge_actions_permissions >"${temporary}/sha-pending-staged.txt"
jq -se 'all(.[] | select(.method == "PUT"); .payload.sha_pinning_required != true)' "${api_log}" >/dev/null

# Malformed configured languages are unreadable for ordinary repositories too.
for languages in null '{}' '[false]' '[""]' '"rust"'; do
  reset_case
  jq '.codeql_required_languages = {}' "${security_merge_config}" >"${temporary}/no-minima.json"
  cp "${temporary}/no-minima.json" "${security_merge_config}"
  codeql_state=$(jq -cn --argjson languages "${languages}" \
    '{state:"configured", query_suite:"default", languages:$languages}')
  if converge_codeql_default_setup >"${temporary}/malformed-languages.txt" 2>&1; then
    echo 'expected malformed configured CodeQL languages to fail closed without minima' >&2
    exit 1
  fi
  assert_no_writes
done
reset_case
jq '.codeql_required_languages = {}' "${security_merge_config}" >"${temporary}/no-minima.json"
cp "${temporary}/no-minima.json" "${security_merge_config}"
codeql_state='{"state":"configured","query_suite":"default","languages":[]}'
converge_codeql_default_setup >"${temporary}/readable-empty-languages.txt"
assert_no_writes
reset_case
codeql_state='{"state":"not-configured","languages":null}'
converge_codeql_default_setup >"${temporary}/unconfigured-languages.txt"
jq -se '[.[] | select(.method == "PATCH")][0].payload.languages == ["rust"]' "${api_log}" >/dev/null

# Neither a foreign owner nor an unregistered repository can lend canary proof.
for phase in pending enforced; do
  for rejected_canary in foreign/content-toolkit/99 atrinik/unregistered/99; do
    reset_case
    if [[ ${phase} == enforced ]]; then
      jq -n --arg canary "${rejected_canary}" '{phase:"enforced", canary:$canary}' \
        >"${actions_sha_pinning_config}"
    else
      sha_pinning_canary=${rejected_canary}
    fi
    if converge_actions_permissions >"${temporary}/sha-identity-rejected.txt" 2>&1; then
      echo 'expected foreign or unregistered canary to be rejected' >&2
      exit 1
    fi
    assert_no_writes
    [[ ! -s ${readiness_log} ]]
  done
done
reset_case
repository_state='{"id":999,"full_name":"atrinik/content-toolkit","archived":false}'
sha_pinning_canary=atrinik/content-toolkit/99
if converge_actions_permissions >"${temporary}/sha-replaced-repository.txt" 2>&1; then
  echo 'expected a replaced canary repository to be rejected' >&2
  exit 1
fi
assert_no_writes
[[ ! -s ${readiness_log} ]]

reset_case
converge_repository_workflow_permissions >"${temporary}/workflow-drift.txt"
jq -se --slurpfile desired "${root}/config/actions-workflow.json" '
  [.[] | select(.method != "GET")] == [{method: "PUT",
    endpoint: "repos/atrinik/content-toolkit/actions/permissions/workflow", payload: $desired[0]}]
' "${api_log}" >/dev/null
reset_case
workflow_state=$(cat "${root}/config/actions-workflow.json")
converge_repository_workflow_permissions >"${temporary}/workflow-noop.txt"
assert_no_writes
for workflow_state in unreadable '{}' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":"false"}'; do
  : >"${api_log}"
  if converge_repository_workflow_permissions >"${temporary}/workflow-error.txt" 2>&1; then
    echo 'expected unreadable or malformed workflow permissions to fail closed' >&2
    exit 1
  fi
  assert_no_writes
done

rm -f "${temporary_files[@]}"
echo 'Security merge publisher tests passed.'
