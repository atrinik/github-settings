#!/usr/bin/env bash

# Sourced production functions consume these fixture globals.
# shellcheck disable=SC2034
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${ATRINIK_PUBLISH_TEST_ROOT:-${source_root}}
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
root=${temporary}/fixture
mkdir -p "${root}/config"
cp -R "${source_root}/config/." "${root}/config/"
cp -R "${source_root}/lib" "${root}/lib"
sed -n '/^converge_organization_settings() {/,/^organization_metadata=/p' \
  "${source_root}/bin/publish" | sed '$d' >"${temporary}/functions.sh"
sed -n '/^list_rulesets() {/,/^}/p' "${source_root}/bin/publish" >>"${temporary}/functions.sh"
# shellcheck source=/dev/null
source "${temporary}/functions.sh"
organization=atrinik
organization_plan=free
apply=true
temporary_files=()
repositories_config=${root}/config/repositories.json
security_merge_config=${root}/config/security-merge-protection.json
advisory_merge_windows_config=${root}/config/advisory-merge-windows.json
api_log=${temporary}/api.jsonl
active_repositories=(content-toolkit)
declare -A active_repository_ids=([content-toolkit]=123)
# The first 30 entries are foreign policies. Managed entries occur only on the
# next page, matching GitHub's default page size and the reported duplicate bug.
jq -cn '[range(100;130) | {id:.,name:("Foreign policy " + tostring)}]' >"${temporary}/first-page.json"
github_api() {
  local endpoint=$1
  shift
  jq -cn --arg endpoint "${endpoint}" '{method:"GET",endpoint:$endpoint}' >>"${api_log}"
  case ${endpoint} in
  orgs/atrinik/rulesets | 'repos/atrinik/content-toolkit/rulesets?includes_parents=false')
    [[ $# == 1 && $1 == --paginate ]] || {
      echo 'inventory must use supported --paginate without --slurp' >&2
      return 99
    }
    [[ ${page_state} != empty ]] || return 0
    cat "${temporary}/first-page.json"
    case ${page_state} in
    valid) cat "${temporary}/second-page.json" ;;
    failed) echo 'gh: later ruleset page failed (HTTP 503)' >&2; return 1 ;;
    malformed) echo '{' ;;
    object) echo '{"message":"API error"}' ;;
    null) echo 'null' ;;
    nested) echo '[[{"id":8,"name":"Nested"}]]' ;;
    invalid-id) echo '[{"id":null,"name":"Invalid"}]' ;;
    fractional-id) echo '[{"id":8.5,"name":"Invalid"}]' ;;
    invalid-name) echo '[{"id":8,"name":null}]' ;;
    duplicate-id) echo '[{"id":100,"name":"Changed name"}]' ;;
    duplicate-name) echo '[{"id":8,"name":"Foreign policy 100"}]' ;;
    *) return 99 ;;
    esac
    ;;
  orgs/atrinik/rulesets/1 | orgs/atrinik/rulesets/2 | orgs/atrinik/rulesets/4 | orgs/atrinik/rulesets/5)
    local template
    case ${endpoint##*/} in
      1) template=default-branch-integrity ;;
      2) template=default-branch-linear-history ;;
      4) template=pull-request-gate ;;
      5) template=immutable-release-tags ;;
    esac
    jq --argjson id "${endpoint##*/}" '
      . + {id:$id,source_type:"Organization",source:"atrinik",enforcement:"disabled"} |
      .conditions.repository_name = {include:[],exclude:[],protected:false}
    ' "${root}/config/rulesets/${template}.json" ;;
  orgs/atrinik/rulesets/31 | repos/atrinik/content-toolkit/rulesets/31)
    local source_type=Repository source=atrinik/content-toolkit
    if [[ ${endpoint} == orgs/* ]]; then source_type=Organization; source=atrinik; fi
    jq --arg source_type "${source_type}" --arg source "${source}" '
      . + {id:31,source_type:$source_type,source:$source,enforcement:"disabled"}
    ' "${root}/config/rulesets/default-branch-integrity.json" ;;
  repos/atrinik/content-toolkit)
    echo '{"id":123,"full_name":"atrinik/content-toolkit","archived":false,"default_branch":"main"}' ;;
  repos/atrinik/content-toolkit/rulesets/3 | \
    repos/atrinik/content-toolkit/rulesets/6 | repos/atrinik/content-toolkit/rulesets/7)
    cat "${temporary}/rule-${endpoint##*/}.json" ;;
  *) echo "unexpected API endpoint: ${endpoint}" >&2; return 99 ;;
  esac
}
run_api() {
  local payload=null
  [[ -z ${3:-} ]] || payload=$(cat "$3")
  jq -cn --arg method "$1" --arg endpoint "$2" --argjson payload "${payload}" \
    '{method:$method,endpoint:$endpoint,payload:$payload}' >>"${api_log}"
  [[ ${write_failed} != true ]]
}
reset_case() {
  : >"${api_log}"
  page_state=valid
  write_failed=false
  active_repositories=(content-toolkit)
  active_repository_ids=([content-toolkit]=123)
  echo '[]' >"${temporary}/second-page.json"
  echo '{"repositories":[]}' >"${advisory_merge_windows_config}"
  echo '{"pull_request_gate":["content-toolkit"],"required_ci":{"content-toolkit":["Toolkit validation"]},"release_tags":[],"maintenance_branches":[]}' >"${repositories_config}"
  echo '{"dependency_review":["content-toolkit"],"code_scanning":["content-toolkit"],"activation":{"dependency_review":{"content-toolkit":"enforced"},"code_scanning":{"content-toolkit":"enforced"}}}' >"${security_merge_config}"
  echo '{"retirements":[{"repository":"content-toolkit","repository_id":123,"ruleset_id":3,"required_ci":["Toolkit validation"]}]}' >"${root}/config/retired-required-ci.json"
  for pair in '3 required-ci' '6 code-scanning' '7 dependency-review'; do
    read -r id template <<<"${pair}"
    jq --argjson id "${id}" '. + {id:$id,source_type:"Repository",source:"atrinik/content-toolkit"} |
      if $id == 3 then .rules[0].parameters.required_status_checks = [{context:"Toolkit validation",integration_id:15368}] else . end' \
      "${root}/config/rulesets/${template}.json" >"${temporary}/rule-${id}.json"
  done
}
assert_no_writes() {
  jq -se 'all(.[]; .method == "GET")' "${api_log}" >/dev/null
}
# Ordinary repository/org upserts must update the existing off-page identity;
# complete absence alone permits POST.
for scope in repository organization; do
  for found in true false; do
    reset_case
    if ${found}; then
      echo '[{"id":31,"name":"01 - Default branch integrity"}]' >"${temporary}/second-page.json"
    fi
    if [[ ${scope} == repository ]]; then
      upsert_repository_ruleset content-toolkit "${root}/config/rulesets/default-branch-integrity.json"
      endpoint=repos/atrinik/content-toolkit/rulesets
    else
      upsert_organization_ruleset "${root}/config/rulesets/default-branch-integrity.json"
      endpoint=orgs/atrinik/rulesets
    fi
    method=POST
    if ${found}; then method=PUT; endpoint+=/31; fi
    jq -se --arg method "${method}" --arg endpoint "${endpoint}" '
      [.[] | select(.method != "GET")] | length == 1 and .[0].method == $method and .[0].endpoint == $endpoint' "${api_log}" >/dev/null
  done
done
# Security gate convergence, restoration, and retirement share full discovery
# in both scopes. Foreign same-name detail remains retained after discovery.
for policy_scope in organization repository; do
  for state in converged disabled retired foreign; do
    reset_case
    echo '[{"id":6,"name":"06 - CodeQL security"},{"id":7,"name":"07 - Dependency review"}]' >"${temporary}/second-page.json"
    if [[ ${state} == disabled ]]; then
      for id in 6 7; do
        jq '.enforcement = "disabled"' "${temporary}/rule-${id}.json" >"${temporary}/changed.json"
        mv "${temporary}/changed.json" "${temporary}/rule-${id}.json"
      done
    elif [[ ${state} == retired || ${state} == foreign ]]; then
      echo '{"dependency_review":[],"code_scanning":[],"activation":{"dependency_review":{},"code_scanning":{}}}' >"${security_merge_config}"
      if [[ ${state} == foreign ]]; then
        for id in 6 7; do
          jq '.source = "foreign/content-toolkit"' "${temporary}/rule-${id}.json" >"${temporary}/changed.json"
          mv "${temporary}/changed.json" "${temporary}/rule-${id}.json"
        done
      fi
    fi
    publish_security_merge_rulesets >"${temporary}/output"
    case ${state} in
    converged | foreign) assert_no_writes ;;
    disabled | retired)
      method=PUT
      [[ ${state} != retired ]] || method=DELETE
      jq -se --arg method "${method}" '
        [.[] | select(.method != "GET")] | length == 2 and
        all(.[]; .method == $method) and
        ([.[].endpoint] | sort) == ["repos/atrinik/content-toolkit/rulesets/6","repos/atrinik/content-toolkit/rulesets/7"]' "${api_log}" >/dev/null ;;
    esac
  done
done
# A recorded aggregate on a later page is retired only when its exact payload
# and repository provenance still match, leaving all foreign policies intact.
for state in owned foreign; do
  reset_case
  echo '[{"id":3,"name":"03 - Required CI"}]' >"${temporary}/second-page.json"
  echo '{"pull_request_gate":[],"required_ci":{},"release_tags":[],"maintenance_branches":[]}' >"${repositories_config}"
  if [[ ${state} == foreign ]]; then
    jq '.source = "foreign/content-toolkit"' "${temporary}/rule-3.json" >"${temporary}/changed.json"
    mv "${temporary}/changed.json" "${temporary}/rule-3.json"
  fi
  delete_retired_repository_required_ci >"${temporary}/output"
  if [[ ${state} == foreign ]]; then assert_no_writes; else
    jq -se '[.[] | select(.method != "GET")] | length == 1 and .[0].method == "DELETE" and .[0].endpoint == "repos/atrinik/content-toolkit/rulesets/3"' "${api_log}" >/dev/null
  fi
done
# Scope migration and stale maintenance/advisory removal also see later pages.
for consumer in delete_managed_repository_rulesets delete_managed_organization_rulesets \
  delete_stale_repository_maintenance_rulesets delete_stale_repository_advisory_rulesets; do
  reset_case
  case ${consumer} in
  delete_stale_repository_maintenance_rulesets) name='05 - Maintenance branch - content-toolkit - old' ;;
  delete_stale_repository_advisory_rulesets) name='02 - Changes through pull requests - content-toolkit' ;;
  *) name='01 - Default branch integrity' ;;
  esac
  jq -cn --arg name "${name}" '[{id:31,name:$name}]' >"${temporary}/second-page.json"
  "${consumer}" content-toolkit
  jq -se '[.[] | select(.method != "GET")] | length == 1 and .[0].method == "DELETE" and (.[0].endpoint | endswith("/31"))' "${api_log}" >/dev/null
done
# Propagating inventory failures through parent functions must also preserve
# API write failures instead of continuing a loop after a failed deletion.
for consumer in delete_managed_repository_rulesets delete_managed_organization_rulesets \
  delete_stale_repository_maintenance_rulesets delete_stale_repository_advisory_rulesets \
  delete_retired_repository_required_ci; do
  reset_case
  write_failed=true
  case ${consumer} in
  delete_stale_repository_maintenance_rulesets) name='05 - Maintenance branch - content-toolkit - old' ;;
  delete_stale_repository_advisory_rulesets) name='02 - Changes through pull requests - content-toolkit' ;;
  delete_retired_repository_required_ci)
    name='03 - Required CI'
    echo '{"required_ci":{}}' >"${repositories_config}" ;;
  *) name='01 - Default branch integrity' ;;
  esac
  jq -cn --arg name "${name}" '[{id:3,name:$name},{id:32,name:"05 - Maintenance branch - content-toolkit - older"}]' >"${temporary}/second-page.json"
  if "${consumer}" content-toolkit >"${temporary}/failure" 2>&1; then
    echo "expected ${consumer} to propagate the failed DELETE" >&2
    exit 1
  fi
  jq -se '[.[] | select(.method != "GET")] | length == 1 and .[0].method == "DELETE"' "${api_log}" >/dev/null
done
# The organization publisher's final stale-policy scan must not miss an
# off-page aggregate, nor mistake off-page desired rules for missing rules.
reset_case
active_repositories=()
echo '{"pull_request_gate":[],"required_ci":{},"release_tags":[],"maintenance_branches":[]}' >"${repositories_config}"
echo '[{"id":1,"name":"01 - Default branch integrity"},{"id":2,"name":"01 - Default branch linear history"},{"id":4,"name":"02 - Changes through pull requests"},{"id":5,"name":"04 - Immutable release tags"},{"id":31,"name":"03 - Required CI - retired"}]' >"${temporary}/second-page.json"
publish_organization_rulesets
jq -se 'all(.[]; .method != "POST") and
  ([.[] | select(.method == "DELETE") | .endpoint] == ["orgs/atrinik/rulesets/31"])' "${api_log}" >/dev/null
# No inventory consumer may use an incomplete, malformed or ambiguous page
# stream as proof of absence, even when called from a shell conditional.
for invalid in failed malformed object null nested invalid-id fractional-id invalid-name duplicate-id duplicate-name empty; do
  for consumer in upsert_repository_ruleset upsert_organization_ruleset \
    publish_repository_rulesets publish_organization_rulesets publish_security_merge_rulesets \
    delete_retired_repository_required_ci delete_removed_security_merge_rulesets \
    delete_managed_repository_rulesets delete_managed_organization_rulesets \
    delete_stale_repository_maintenance_rulesets delete_stale_repository_advisory_rulesets; do
    reset_case
    page_state=${invalid}
    case ${consumer} in
    upsert_repository_ruleset) arguments=(content-toolkit "${root}/config/rulesets/default-branch-integrity.json") ;;
    upsert_organization_ruleset) arguments=("${root}/config/rulesets/default-branch-integrity.json") ;;
    delete_retired_repository_required_ci)
      arguments=()
      echo '{"required_ci":{}}' >"${repositories_config}" ;;
    delete_removed_security_merge_rulesets)
      arguments=()
      echo '{"code_scanning":[],"dependency_review":[]}' >"${security_merge_config}" ;;
    *) arguments=(content-toolkit) ;;
    esac
    if "${consumer}" "${arguments[@]}" >"${temporary}/failure" 2>&1; then
      echo "expected ${consumer} to reject ${invalid} later-page evidence" >&2
      exit 1
    fi
    assert_no_writes
    grep -Eq 'cannot read complete ruleset inventory|invalid or ambiguous complete ruleset inventory' "${temporary}/failure"
  done
done
# Even an actionable first-page gate cannot be deleted while a later page is
# unreadable: pagination is a complete preflight, not a streaming mutation loop.
cp "${temporary}/first-page.json" "${temporary}/foreign-page.json"
for invalid in failed malformed; do
  reset_case
  page_state=${invalid}
  jq '. + [{id:6,name:"06 - CodeQL security"},{id:7,name:"07 - Dependency review"}]' \
    "${temporary}/foreign-page.json" >"${temporary}/first-page.json"
  echo '{"code_scanning":[],"dependency_review":[]}' >"${security_merge_config}"
  if delete_removed_security_merge_rulesets >"${temporary}/failure" 2>&1; then
    echo 'expected failed full enumeration to prevent first-page retirement' >&2
    exit 1
  fi
  assert_no_writes
done
printf 'Ruleset pagination publisher tests passed.\n'
