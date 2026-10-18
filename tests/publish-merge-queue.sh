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
sed -n '/^list_rulesets() {/,/^}/p' "${source_root}/bin/publish" >>"${temporary}/functions.sh"
# shellcheck source=/dev/null
source "${temporary}/functions.sh"
root=${temporary}/fixture
mkdir -p "${root}/config" "${temporary}/captured"
cp -R "${source_root}/config/rulesets" "${root}/config/rulesets"
template=${root}/config/rulesets/merge-queue.json
organization=atrinik
organization_plan=team
repositories_config=${root}/config/repositories.json
advisory_merge_windows_config=${root}/config/advisory-merge-windows.json
temporary_files=()
log=${temporary}/api.jsonl

# Live fixtures: playtester is queued, observatory is not.
github_api() {
  jq -cn --arg endpoint "$1" '{method:"GET",endpoint:$endpoint}' >>"${log}"
  case $1 in
  'repos/atrinik/playtester/rulesets?includes_parents=false' | \
    'repos/atrinik/observatory/rulesets?includes_parents=false')
    local repository=${1#repos/atrinik/}
    repository=${repository%%/*}
    cat "${temporary}/${repository}-list.json" ;;
  repos/atrinik/playtester/rulesets/8 | repos/atrinik/observatory/rulesets/8)
    local repository=${1#repos/atrinik/} reads
    repository=${repository%%/*}
    # A later read may observe a concurrent edit or fail.
    reads=$(jq -s --arg endpoint "$1" '[.[] | select(.endpoint == $endpoint)] | length' "${log}")
    if ((reads > 1)) && [[ -e ${temporary}/${repository}-later-rule.json ]]; then
      cat "${temporary}/${repository}-later-rule.json"
    elif ((reads > 1)) && [[ -e ${temporary}/${repository}-later-unreadable ]]; then
      return 1
    else
      cat "${temporary}/${repository}-rule.json"
    fi ;;
  repos/atrinik/playtester | repos/atrinik/observatory)
    cat "${temporary}/${1#repos/atrinik/}-metadata.json" ;;
  orgs/atrinik/rulesets) echo '[]' ;;
  *) echo "unexpected endpoint: $1" >&2; return 99 ;;
  esac
}
run_api() {
  if ! ${apply}; then
    echo "PLAN $1 /$2"
    return
  fi
  jq -cn --arg method "$1" --arg endpoint "$2" \
    --argjson body "$(if [[ -n ${3:-} ]]; then cat "$3"; else echo null; fi)" \
    '{method:$method,endpoint:$endpoint,body:$body}' >>"${log}"
}
writes() {
  jq -sc '[.[] | select(.method != "GET")]' "${log}"
}
# GitHub returns the owner sentinel with a null ID and the ruleset's identity.
live_rule() {
  local repository=$1
  jq --arg source "atrinik/${repository}" '
    . + {id: 8, source_type: "Repository", source: $source} |
    .bypass_actors[0].actor_id = null
  ' "${template}"
}
reset_case() {
  : >"${log}"
  apply=true
  active_repositories=(observatory playtester)
  declare -gA active_repository_ids=([observatory]=1 [playtester]=2)
  printf '{"repositories":[]}\n' >"${advisory_merge_windows_config}"
  jq -n '{
    pull_request_gate: ["observatory", "playtester"],
    required_ci: {
      observatory: ["Validate dashboard and Workers", "Conventional PR title"],
      playtester: ["Playtester validation", "Conventional PR title"]
    },
    merge_queue: ["playtester"],
    release_tags: [],
    maintenance_branches: [],
    archive: []
  }' >"${repositories_config}"
  printf '[{"id":3,"name":"03 - Required CI"}]\n' >"${temporary}/playtester-list.json"
  printf '[{"id":3,"name":"03 - Required CI"}]\n' >"${temporary}/observatory-list.json"
  rm -f "${temporary}/"*-later-rule.json "${temporary}/"*-later-unreadable
  printf '{"id":2,"full_name":"atrinik/playtester","archived":false}\n' \
    >"${temporary}/playtester-metadata.json"
  printf '{"id":1,"full_name":"atrinik/observatory","archived":false}\n' \
    >"${temporary}/observatory-metadata.json"
  live_rule playtester >"${temporary}/playtester-rule.json"
  live_rule observatory >"${temporary}/observatory-rule.json"
}
expect_failure() {
  local message=$1
  shift
  if "$@" >"${temporary}/output" 2>&1; then
    echo "expected failure: ${message}" >&2
    exit 1
  fi
  grep -Fq "${message}" "${temporary}/output"
  [[ $(writes) == '[]' ]]
}

# The pilot template is the reviewed queue for squash-only repositories.
jq -e '
  .name == "08 - Merge queue" and
  .rules == [{type: "merge_queue", parameters: {
    check_response_timeout_minutes: 60,
    grouping_strategy: "ALLGREEN",
    max_entries_to_build: 5,
    max_entries_to_merge: 5,
    merge_method: "SQUASH",
    min_entries_to_merge: 1,
    min_entries_to_merge_wait_minutes: 5
  }}]
' "${template}" >/dev/null

# A missing queue is created on the repository, never as an organization rule.
reset_case
publish_merge_queue_rulesets >"${temporary}/output"
jq -se --slurpfile desired "${template}" '
  [.[] | select(.method != "GET")] ==
    [{method: "POST", endpoint: "repos/atrinik/playtester/rulesets", body: $desired[0]}]
' "${log}" >/dev/null
if grep -q '"endpoint":"orgs/' "${log}"; then
  echo 'merge queue must remain repository-owned' >&2
  exit 1
fi

# A converged queue is kept without a write.
reset_case
printf '[{"id":3,"name":"03 - Required CI"},{"id":8,"name":"08 - Merge queue"}]\n' \
  >"${temporary}/playtester-list.json"
publish_merge_queue_rulesets >"${temporary}/output"
[[ $(writes) == '[]' ]]
grep -Fxq 'KEEP /repos/atrinik/playtester/rulesets/8 08 - Merge queue' "${temporary}/output"

# Parameter, enforcement or scope drift is converged in place.
for filter in \
  '.rules[0].parameters.check_response_timeout_minutes = 30' \
  '.rules[0].parameters.grouping_strategy = "HEADGREEN"' \
  '.rules[0].parameters.merge_method = "MERGE"' \
  '.enforcement = "disabled"' \
  '.conditions.ref_name.include = ["refs/heads/other"]' \
  '.bypass_actors[0].bypass_mode = "always"'; do
  reset_case
  printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
  jq "${filter}" "${temporary}/playtester-rule.json" >"${temporary}/changed.json"
  mv "${temporary}/changed.json" "${temporary}/playtester-rule.json"
  publish_merge_queue_rulesets >"${temporary}/output"
  jq -se --slurpfile desired "${template}" '
    [.[] | select(.method != "GET")] ==
      [{method: "PUT", endpoint: "repos/atrinik/playtester/rulesets/8", body: $desired[0]}]
  ' "${log}" >/dev/null
done

# Plan mode prints the operation and writes nothing.
reset_case
apply=false
publish_merge_queue_rulesets >"${temporary}/output"
grep -Fxq 'PLAN POST /repos/atrinik/playtester/rulesets' "${temporary}/output"
[[ $(writes) == '[]' ]]

# A same-name rule with foreign ownership is never overwritten.
for filter in '.source_type = "Organization"' '.source = "foreign/playtester"' \
  '.id = 9' '.name = "Foreign queue"'; do
  reset_case
  printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
  jq "${filter}" "${temporary}/playtester-rule.json" >"${temporary}/changed.json"
  mv "${temporary}/changed.json" "${temporary}/playtester-rule.json"
  expect_failure 'merge-queue ruleset ownership changed; retained: playtester' \
    publish_merge_queue_rulesets
done

# An inactive inventory entry is skipped, as security gates are; an ambiguous
# live inventory fails closed.
reset_case
active_repository_ids=([observatory]=1)
publish_merge_queue_rulesets >"${temporary}/output"
grep -Fxq 'SKIP atrinik/playtester is not active; 08 - Merge queue' "${temporary}/output"
jq -se 'length == 0' "${log}" >/dev/null
reset_case
printf '[{"id":8,"name":"08 - Merge queue"},{"id":9,"name":"08 - Merge queue"}]\n' \
  >"${temporary}/playtester-list.json"
expect_failure 'ambiguous complete ruleset inventory' publish_merge_queue_rulesets

# An advisory-level merge needs every reported rule bypassable.
reset_case
printf '{"repositories":["playtester"]}\n' >"${advisory_merge_windows_config}"
publish_merge_queue_rulesets >"${temporary}/output"
jq -se '
  [.[] | select(.method == "POST")][0].body.bypass_actors ==
    [{actor_id: 1, actor_type: "OrganizationAdmin", bypass_mode: "always"}]
' "${log}" >/dev/null

# Retirement removes only the unmodified repository-owned managed queue.
reset_case
jq '.merge_queue = []' "${repositories_config}" >"${temporary}/retired.json"
mv "${temporary}/retired.json" "${repositories_config}"
printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
delete_removed_merge_queue_rulesets >"${temporary}/output"
[[ $(writes) == '[{"method":"DELETE","endpoint":"repos/atrinik/playtester/rulesets/8","body":null}]' ]]
for filter in '.source_type = "Organization"' '.source = "foreign/playtester"' \
  '.id = 9' '.enforcement = "disabled"' \
  '.rules[0].parameters.check_response_timeout_minutes = 30' \
  '.rules += [{type: "deletion"}]'; do
  reset_case
  jq '.merge_queue = []' "${repositories_config}" >"${temporary}/retired.json"
  mv "${temporary}/retired.json" "${repositories_config}"
  printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
  jq "${filter}" "${temporary}/playtester-rule.json" >"${temporary}/changed.json"
  mv "${temporary}/changed.json" "${temporary}/playtester-rule.json"
  delete_removed_merge_queue_rulesets >"${temporary}/output"
  [[ $(writes) == '[]' ]]
  grep -Fxq 'SKIP atrinik/playtester 08 - Merge queue: unrecognized ownership or payload; retained' \
    "${temporary}/output"
done
# Identity drift, a concurrent edit after the first read, or an unreadable
# final read retains the queue.
retire_playtester() {
  reset_case
  jq '.merge_queue = []' "${repositories_config}" >"${temporary}/retired.json"
  mv "${temporary}/retired.json" "${repositories_config}"
  printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
}
for filter in '.id = 999' '.full_name = "foreign/playtester"' '.archived = true'; do
  retire_playtester
  jq "${filter}" "${temporary}/playtester-metadata.json" >"${temporary}/changed.json"
  mv "${temporary}/changed.json" "${temporary}/playtester-metadata.json"
  delete_removed_merge_queue_rulesets >"${temporary}/output"
  [[ $(writes) == '[]' ]]
  grep -Fxq 'SKIP atrinik/playtester 08 - Merge queue: repository identity or archive state changed; retained' \
    "${temporary}/output"
done
for filter in '.enforcement = "disabled"' '.source_type = "Organization"' \
  '.rules[0].parameters.max_entries_to_merge = 1'; do
  retire_playtester
  jq "${filter}" "${temporary}/playtester-rule.json" >"${temporary}/playtester-later-rule.json"
  delete_removed_merge_queue_rulesets >"${temporary}/output"
  [[ $(writes) == '[]' ]]
  grep -Fxq 'SKIP atrinik/playtester 08 - Merge queue: rule changed during retirement preflight; retained' \
    "${temporary}/output"
  # The final read happens after the identity fence.
  jq -se '
    [.[] | .endpoint] as $calls |
    ($calls | index("repos/atrinik/playtester")) <
      ($calls | rindex("repos/atrinik/playtester/rulesets/8"))
  ' "${log}" >/dev/null
done
retire_playtester
touch "${temporary}/playtester-later-unreadable"
expect_failure 'merge-queue final retirement read failed; retained: playtester' \
  delete_removed_merge_queue_rulesets

# Queued repositories and repositories without the rule are left alone.
reset_case
printf '[{"id":8,"name":"08 - Merge queue"}]\n' >"${temporary}/playtester-list.json"
delete_removed_merge_queue_rulesets >"${temporary}/output"
[[ $(writes) == '[]' ]]
if grep -Fq 'repos/atrinik/playtester/' "${log}"; then
  echo 'retirement must not inspect a queued repository' >&2
  exit 1
fi

# Required CI stops requiring a current branch only where the queue tests the
# merged result, in both policy scopes.
upsert_repository_ruleset() {
  cp "$2" "${temporary}/captured/repository-$1-$(jq -r .name "$2")"
}
upsert_organization_ruleset() {
  cp "$1" "${temporary}/captured/organization-$(jq -r .name "$1")"
}
delete_retired_repository_required_ci() { :; }
delete_stale_repository_maintenance_rulesets() { :; }
delete_stale_repository_advisory_rulesets() { :; }
delete_managed_organization_rulesets() { :; }
delete_managed_repository_rulesets() { :; }
reset_case
publish_repository_rulesets >/dev/null
publish_organization_rulesets >/dev/null
for scope in repository-playtester-03\ -\ Required\ CI organization-03\ -\ Required\ CI\ -\ playtester; do
  jq -e '
    .rules[0].parameters.strict_required_status_checks_policy == false and
    .rules[0].parameters.required_status_checks ==
      [{context: "Playtester validation", integration_id: 15368},
       {context: "Conventional PR title", integration_id: 15368}]
  ' "${temporary}/captured/${scope}" >/dev/null
done
for scope in repository-observatory-03\ -\ Required\ CI organization-03\ -\ Required\ CI\ -\ observatory; do
  jq -e '.rules[0].parameters.strict_required_status_checks_policy == true' \
    "${temporary}/captured/${scope}" >/dev/null
done
# A listed but inactive repository gets no queue, so its required CI stays strict.
reset_case
rm -f "${temporary}/captured/"*
active_repository_ids=([observatory]=1)
publish_repository_rulesets >/dev/null
publish_organization_rulesets >/dev/null
for scope in repository-playtester-03\ -\ Required\ CI organization-03\ -\ Required\ CI\ -\ playtester; do
  jq -e '.rules[0].parameters.strict_required_status_checks_policy == true' \
    "${temporary}/captured/${scope}" >/dev/null
done

# Install the queue before required CI is relaxed, and retire it only after
# required CI is restored. Neither step belongs to one policy scope.
order=$(grep -nE '^(publish_merge_queue_rulesets|if \[\[ \$\{policy_scope\} == organization \]\]; then|publish_security_merge_rulesets|delete_removed_merge_queue_rulesets)$' \
  "${source_root}/bin/publish" | cut -d: -f2-)
[[ ${order} == $'publish_merge_queue_rulesets\nif [[ ${policy_scope} == organization ]]; then\npublish_security_merge_rulesets\ndelete_removed_merge_queue_rulesets' ]]

# Team offers merge queue only for public repositories; fail before any write.
sed -n '/^# Team offers merge queue only/,/^done < <(jq -r .\.merge_queue\[\]. /p' \
  "${source_root}/bin/publish" >"${temporary}/preflight.sh"
grep -Fq 'merge queue requires a public repository' "${temporary}/preflight.sh"
run_preflight() {
  (
    # shellcheck source=/dev/null
    source "${temporary}/preflight.sh"
  )
}
reset_case
declare -A active_repository_visibility=([observatory]=private [playtester]=public)
run_preflight
active_repository_visibility[playtester]=private
expect_failure 'merge queue requires a public repository on the team plan: playtester' run_preflight
organization_plan=enterprise
run_preflight
organization_plan=team
active_repository_visibility[playtester]=private
active_repository_ids=([observatory]=1)
run_preflight
echo 'Merge-queue publisher tests passed.'
