#!/usr/bin/env bash

# Production functions consume these fixture globals.
# shellcheck disable=SC2034
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${ATRINIK_PUBLISH_TEST_ROOT:-${root}}
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
sed -n '/^converge_organization_settings() {/,/^organization_metadata=/p' \
  "${source_root}/bin/publish" | sed '$d' >"${temporary}/functions.sh"
# shellcheck source=/dev/null
source "${temporary}/functions.sh"
root=${temporary}/fixture
mkdir -p "${root}/config"
cp -R "${source_root}/config/rulesets" "${root}/config/rulesets"
organization=atrinik
organization_plan=free
repositories_config=${root}/config/repositories.json
advisory_merge_windows_config=${root}/config/advisory-merge-windows.json
printf '{"repositories":[]}\n' >"${advisory_merge_windows_config}"
active_repositories=(web-platform)
declare -A active_repository_ids=([web-platform]=123)
temporary_files=()
log=${temporary}/api.jsonl
repository_has_advisory_merge_window() { return 1; }
upsert_repository_ruleset() { :; }
delete_stale_repository_maintenance_rulesets() { :; }
delete_stale_repository_advisory_rulesets() { :; }
github_api() {
  jq -cn --arg endpoint "$1" '{method:"GET",endpoint:$endpoint}' >>"${log}"
  case $1 in
  'repos/atrinik/web-platform/rulesets?includes_parents=false')
    if [[ -e ${temporary}/deleted ]]; then echo '[]'; else cat "${temporary}/list.json"; fi ;;
  repos/atrinik/web-platform)
    cat "${temporary}/metadata.json" ;;
  repos/atrinik/web-platform/rulesets/3)
    if [[ -e ${temporary}/read-once && -e ${temporary}/changed.json ]]; then
      cat "${temporary}/changed.json"
    else
      cat "${temporary}/rule.json"
    fi
    touch "${temporary}/read-once" ;;
  *) echo "unexpected endpoint: $1" >&2; return 99 ;;
  esac
}
run_api() {
  [[ $1 == DELETE && $2 == repos/atrinik/web-platform/rulesets/3 ]]
  if ${apply}; then
    jq -cn --arg endpoint "$2" '{method:"DELETE",endpoint:$endpoint}' >>"${log}"
    touch "${temporary}/deleted"
  else
    jq -cn --arg endpoint "$2" '{method:"PLAN",endpoint:$endpoint}' >>"${log}"
  fi
}
reset_case() {
  : >"${log}"
  rm -f "${temporary}/deleted" "${temporary}/read-once" "${temporary}/changed.json"
  apply=true
  active_repository_ids=([web-platform]=123)
  printf '{"pull_request_gate":["web-platform"],"required_ci":{},"release_tags":[],"maintenance_branches":[]}\n' >"${repositories_config}"
  printf '{"retirements":[{"repository":"web-platform","repository_id":123,"ruleset_id":3,"required_ci":["Platform validation","Conventional PR title"]}]}\n' >"${root}/config/retired-required-ci.json"
  printf '[{"id":1,"name":"01 - Default branch integrity"},{"id":3,"name":"03 - Required CI"},{"id":5,"name":"Foreign CI"}]\n' >"${temporary}/list.json"
  printf '{"id":123,"full_name":"atrinik/web-platform","archived":false}\n' >"${temporary}/metadata.json"
  jq '. + {id:3,source_type:"Repository",source:"atrinik/web-platform"} |
    .bypass_actors[0].actor_id = null |
    .rules[0].parameters += {do_not_enforce_on_create:false,
      required_status_checks:[{context:"Conventional PR title",integration_id:15368},
                              {context:"Platform validation",integration_id:15368}]}' \
    "${root}/config/rulesets/required-ci.json" >"${temporary}/rule.json"
}
assert_retained() {
  publish_repository_rulesets >"${temporary}/output"
  jq -se 'all(.[]; .method == "GET")' "${log}" >/dev/null
  grep -Fq 'retained' "${temporary}/output"
}
reset_case
publish_repository_rulesets >"${temporary}/output"
jq -se '[.[] | select(.method == "DELETE")] == [{method:"DELETE",endpoint:"repos/atrinik/web-platform/rulesets/3"}]' "${log}" >/dev/null
# Converged retirement makes no second deletion.
: >"${log}"
publish_repository_rulesets >"${temporary}/output"
jq -se 'all(.[]; .method == "GET")' "${log}" >/dev/null
reset_case
jq 'del(.rules[0].parameters.do_not_enforce_on_create)' \
  "${temporary}/rule.json" >"${temporary}/implicit-default.json"
mv "${temporary}/implicit-default.json" "${temporary}/rule.json"
publish_repository_rulesets >"${temporary}/output"
jq -se 'any(.[]; .method == "DELETE")' "${log}" >/dev/null
reset_case
apply=false
publish_repository_rulesets >"${temporary}/output"
jq -se '[.[] | select(.method != "GET")] == [{method:"PLAN",endpoint:"repos/atrinik/web-platform/rulesets/3"}]' "${log}" >/dev/null
[[ ! -e ${temporary}/deleted ]]
for filter in \
  '.id = 999' '.source_type = "Organization"' '.source = "foreign/web-platform"' \
  '.name = "Foreign CI"' '.target = "tag"' '.enforcement = "disabled"' \
  '.bypass_actors[0].bypass_mode = "always"' '.bypass_actors[0].actor_id = 2' \
  '.conditions.ref_name.include = ["refs/heads/other"]' \
  '.rules[0].parameters.required_status_checks[0].integration_id = 9' \
  '.rules[0].parameters.required_status_checks[0].context = "Unknown check"' \
  '.rules[0].parameters.strict_required_status_checks_policy = false' \
  '.rules[0].parameters.do_not_enforce_on_create = true' \
  '.rules[0].parameters.do_not_enforce_on_create = null' \
  '.rules[0].parameters.unknown_option = false' '.rules += [{type:"deletion"}]'; do
  reset_case
  jq "${filter}" "${temporary}/rule.json" >"${temporary}/changed-rule.json"
  mv "${temporary}/changed-rule.json" "${temporary}/rule.json"
  assert_retained
done
for filter in '.id = 999' '.full_name = "foreign/web-platform"' '.archived = true'; do
  reset_case
  jq "${filter}" "${temporary}/metadata.json" >"${temporary}/changed-metadata.json"
  mv "${temporary}/changed-metadata.json" "${temporary}/metadata.json"
  assert_retained
done
reset_case
jq '.rules[0].parameters.required_status_checks[0].context = "Concurrent change"' \
  "${temporary}/rule.json" >"${temporary}/changed.json"
assert_retained
reset_case
jq '.retirements[0].repository_id = 999' "${root}/config/retired-required-ci.json" >"${temporary}/wrong-record.json"
mv "${temporary}/wrong-record.json" "${root}/config/retired-required-ci.json"
assert_retained
reset_case
printf '{"retirements":[]}\n' >"${root}/config/retired-required-ci.json"
assert_retained
grep -Fq 'config/retired-required-ci.json' "${temporary}/output"
reset_case
printf '[{"id":3,"name":"03 - Required CI"},{"id":4,"name":"03 - Required CI"}]\n' >"${temporary}/list.json"
assert_retained
reset_case
printf '[{"id":4,"name":"03 - Required CI"}]\n' >"${temporary}/list.json"
assert_retained
# Still-active CI and repositories excluded from the active identity map are untouched.
reset_case
jq '.required_ci["web-platform"] = ["Platform validation"]' "${repositories_config}" >"${temporary}/active.json"
mv "${temporary}/active.json" "${repositories_config}"
publish_repository_rulesets >"${temporary}/output"
[[ ! -s ${log} ]]
reset_case
active_repository_ids=()
publish_repository_rulesets >"${temporary}/output"
[[ ! -s ${log} ]]
echo 'Required-CI retirement publisher tests passed.'
