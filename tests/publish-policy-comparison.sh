#!/usr/bin/env bash

# Production functions consume the fixture globals.
# shellcheck disable=SC2034
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
sed -n '/^converge_organization_settings() {/,/^organization_metadata=/p' \
  "${source_root}/bin/publish" | sed '$d' >"${temporary}/functions.sh"
sed -n '/^list_rulesets() {/,/^}/p' "${source_root}/bin/publish" >>"${temporary}/functions.sh"
# shellcheck source=/dev/null
source "${temporary}/functions.sh"
root=${source_root}
organization=atrinik
temporary_files=()
log=${temporary}/writes
reads=${temporary}/reads
input=${temporary}/desired.json
live=${temporary}/live.json
later=${temporary}/later.json
scope=organization

github_api() {
  printf '%s\n' "$1" >>"${reads}"
  case $1 in
    orgs/atrinik/rulesets | 'repos/atrinik/example/rulesets?includes_parents=false')
      jq '[{id:42,name:.name}]' "${input}" ;;
    */rulesets/42)
      if [[ -f ${later} ]] && (($(grep -c '/rulesets/42' "${reads}") > 1)); then
        cat "${later}"
      else cat "${live}"; fi ;;
    *) cat "${live}" ;;
  esac
}
run_api() {
  jq -cn --arg method "$1" --arg endpoint "$2" --slurpfile body "$3" \
    '{method:$method,endpoint:$endpoint,body:$body[0]}' >>"${log}"
}
reset_case() {
  : >"${log}"
  : >"${reads}"
  rm -f "${later}"
  cp "${root}/config/rulesets/$1.json" "${input}"
  local source_type=Organization source=atrinik
  if [[ ${scope} == repository ]]; then source_type=Repository; source=atrinik/example; fi
  jq --arg source_type "${source_type}" --arg source "${source}" '
    . + {id:42,source_type:$source_type,source:$source,updated_at:"before"} |
    .bypass_actors |= map(.actor_id = null) |
    .rules |= map(if .type == "pull_request" then
      .parameters += {required_reviewers:[],allowed_merge_methods:["rebase","squash","merge"],
        require_extra_approval_for_unattributed_changes:true}
      elif .type == "required_status_checks" then .parameters.do_not_enforce_on_create = false
      else . end)
  ' "${input}" >"${live}"
}
change_live() {
  jq "$1" "${live}" >"${temporary}/changed"
  mv "${temporary}/changed" "${live}"
}
upsert() {
  if [[ ${scope} == organization ]]; then upsert_organization_ruleset "${input}"
  else upsert_repository_ruleset example "${input}"; fi
}
for scope in organization repository; do
  for template in pull-request-gate required-ci; do
    reset_case "${template}"
    upsert >"${temporary}/output"
    test ! -s "${log}"
    change_live '.bypass_actors |= map(.actor_id = 1) | .rules[].parameters |= del(.required_reviewers, .allowed_merge_methods, .require_extra_approval_for_unattributed_changes, .do_not_enforce_on_create)'
    upsert >"${temporary}/output"
    test ! -s "${log}"
    reset_case "${template}"
    # Real scope drift retains the exact live extension fields on the PUT.
    change_live '.conditions.ref_name.include = ["refs/heads/old"]'
    upsert >"${temporary}/output"
    jq -se --slurpfile live "${live}" --slurpfile desired "${input}" '
      length == 1 and .[0].method == "PUT" and
      .[0].body.conditions == $desired[0].conditions and
      .[0].body.rules == $live[0].rules and
      (.[0].body | has("id") or has("updated_at") | not)
    ' "${log}" >/dev/null
  done
  for mutation in \
    '.rules[0].parameters.future_gate = true' \
    '.rules[0].parameters.required_reviewers = [{reviewer:{id:42,type:"Team"},minimum_approvals:1}]' \
    '.rules[0].parameters.require_extra_approval_for_unattributed_changes = false' \
    '.rules[0].parameters.allowed_merge_methods = ["squash"]' \
    '.rules[0].parameters.required_reviewers = null' \
    '.rules += [{type:"required_deployments",parameters:{required_deployment_environments:["production"]}}]' \
    '.rules += [.rules[0]]' \
    '.conditions.repository_property = {future:true}' \
    '.bypass_actors[0].future_permission = true' \
    '.future_control = true' \
    '.source = "foreign"' \
    '.id = 99'; do
    reset_case pull-request-gate
    change_live "${mutation}"
    if upsert >"${temporary}/output" 2>&1; then
      echo "unexpectedly accepted ${scope}: ${mutation}" >&2; exit 1
    fi
    test ! -s "${log}"
  done
  for mutation in \
    '.rules[0].parameters.do_not_enforce_on_create = true' \
    '.rules[0].parameters.required_status_checks = [{context:"Unknown", integration_id:15368, future_control:true}]'; do
    reset_case required-ci
    change_live "${mutation}"
    if upsert >"${temporary}/output" 2>&1; then exit 1; fi
    test ! -s "${log}"
  done
  # A concurrent restriction appears between the initial read and PUT.
  reset_case pull-request-gate
  change_live '.enforcement = "disabled"'
  jq '.rules[0].parameters.required_reviewers = [{reviewer:{id:42,type:"Team"},minimum_approvals:1}]' \
    "${live}" >"${later}"
  if upsert >"${temporary}/output" 2>&1; then exit 1; fi
  test ! -s "${log}"
done
# Repository defaults and org workflow permissions ignore unrelated metadata,
# avoid converged writes, and still report real drift.
for settings in repository-defaults actions-workflow; do
  : >"${log}"
  jq '. + {id:42, unrelated:"metadata"}' "${root}/config/${settings}.json" >"${live}"
  converge_settings PATCH settings "${root}/config/${settings}.json" >"${temporary}/output"
  test ! -s "${log}"
  jq 'del(.[keys[0]])' "${root}/config/${settings}.json" >"${live}"
  converge_settings PATCH settings "${root}/config/${settings}.json" >"${temporary}/output"
  test "$(wc -l <"${log}")" = 1
done
echo 'Policy comparison and preservation tests passed.'
