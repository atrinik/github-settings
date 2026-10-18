#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${temporary}/"
config=${temporary}/config
"${temporary}/bin/validate" >/dev/null
cp "${config}/repositories.json" "${temporary}/repositories.json"
cp "${config}/rulesets/merge-queue.json" "${temporary}/merge-queue.json"
cp "${config}/rulesets/required-ci.json" "${temporary}/required-ci.json"
cp "${config}/security-merge-protection.json" "${temporary}/security.json"

expect_invalid() {
  local file=$1 source=$2 filter=$3
  jq "${filter}" "${source}" >"${file}"
  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: accepted invalid merge-queue policy: ${filter}" >&2
    exit 1
  fi
  cp "${source}" "${file}"
}

# Queued repositories need required CI for the queue to run on each merge result.
for filter in \
  'del(.merge_queue)' '.merge_queue = "playtester"' '.merge_queue = [null]' \
  '.merge_queue = [""]' '.merge_queue = ["playtester", "playtester"]' \
  '.merge_queue = ["web-platform"]' '.merge_queue = ["legacy-client"]' \
  '.merge_queue = ["unknown"]'; do
  expect_invalid "${config}/repositories.json" "${temporary}/repositories.json" "${filter}"
done

# Parameters stay within GitHub's API ranges and the organization's merge method.
for filter in \
  '.name = "Merge queue"' '.target = "tag"' '.enforcement = "disabled"' \
  '.conditions.ref_name.include = ["refs/heads/*"]' \
  '.bypass_actors[0].bypass_mode = "always"' '.bypass_actors = []' \
  '.rules += [{type: "deletion"}]' '.rules[0].type = "pull_request"' \
  '.rules[0].parameters.merge_method = "MERGE"' \
  '.rules[0].parameters.merge_method = "REBASE"' \
  '.rules[0].parameters.merge_method = "squash"' \
  '.rules[0].parameters.grouping_strategy = "ANYGREEN"' \
  '.rules[0].parameters.check_response_timeout_minutes = 0' \
  '.rules[0].parameters.check_response_timeout_minutes = 361' \
  '.rules[0].parameters.check_response_timeout_minutes = 1.5' \
  '.rules[0].parameters.check_response_timeout_minutes = "60"' \
  '.rules[0].parameters.max_entries_to_build = 0' \
  '.rules[0].parameters.max_entries_to_build = 101' \
  '.rules[0].parameters.max_entries_to_merge = 0' \
  '.rules[0].parameters.min_entries_to_merge = 0' \
  '.rules[0].parameters.min_entries_to_merge = 6' \
  '.rules[0].parameters.min_entries_to_merge_wait_minutes = 361' \
  '.rules[0].parameters.min_entries_to_merge_wait_minutes = 5' \
  'del(.rules[0].parameters.grouping_strategy)' \
  '.rules[0].parameters.unknown_option = true'; do
  expect_invalid "${config}/rulesets/merge-queue.json" "${temporary}/merge-queue.json" "${filter}"
done
# A wait applies only while a group is below a minimum above one.
jq '.rules[0].parameters.min_entries_to_merge = 2 |
  .rules[0].parameters.min_entries_to_merge_wait_minutes = 5' \
  "${temporary}/merge-queue.json" >"${config}/rulesets/merge-queue.json"
"${temporary}/bin/validate" >/dev/null
cp "${temporary}/merge-queue.json" "${config}/rulesets/merge-queue.json"

# The publisher relaxes only a strict template, and only for queued repositories.
for filter in \
  '.rules[0].parameters.strict_required_status_checks_policy = false' \
  '.rules[0].parameters.required_status_checks = [{context: "Extra", integration_id: 15368}]' \
  '.name = "Required CI"'; do
  expect_invalid "${config}/rulesets/required-ci.json" "${temporary}/required-ci.json" "${filter}"
done

# Dependency review never reports on merge groups, so it cannot gate a queue.
expect_invalid "${config}/security-merge-protection.json" "${temporary}/security.json" \
  '.dependency_review = ["playtester"] | .activation.dependency_review = {playtester: "pending"}'
"${temporary}/bin/validate" >/dev/null
echo 'Merge-queue schema tests passed.'
