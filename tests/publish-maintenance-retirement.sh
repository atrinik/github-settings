#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir "${temporary}/bin"

cat >"${temporary}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

[[ ${1:-} == api ]]
shift
method=GET
endpoint=
while (($#)); do
  case $1 in
  -H | --header)
    shift 2
    ;;
  --method)
    method=$2
    shift 2
    ;;
  *)
    endpoint=$1
    shift
    ;;
  esac
done

jq -cn --arg method "${method}" --arg endpoint "${endpoint}" \
  '{method: $method, endpoint: $endpoint}' >>"${GH_API_LOG}"

if [[ ${method} == DELETE ]] &&
  [[ ${endpoint} == orgs/atrinik/rulesets/20571870 ]]; then
  printf 'false\n' >"${GH_RULESET_PRESENT}"
  printf '{}\n'
  exit 0
fi
[[ ${method} == GET ]]

rulesets() {
  jq -n --argjson present "$(<"${GH_RULESET_PRESENT}")" '
    [
      {id: 20522685, name: "01 - Default branch integrity", enforcement: "active"},
      {id: 20593745, name: "01 - Default branch linear history", enforcement: "active"},
      {id: 20522686, name: "02 - Changes through pull requests", enforcement: "active"},
      {id: 20522693, name: "03 - Required CI - content", enforcement: "active"},
      {id: 20522688, name: "04 - Immutable release tags", enforcement: "active"}
    ] +
    (if $present then [{
      id: 20571870,
      name: "05 - Maintenance branch - content - 1.x",
      enforcement: "active"
    }] else [] end)
  '
}

case ${endpoint} in
repos/atrinik/content)
  printf '%s\n' \
    '{"id":1325219730,"archived":false,"default_branch":"main"}'
  ;;
repos/atrinik/content/git/ref/heads/1.x)
  printf '%s\n' \
    '{"object":{"sha":"080a9ea41741e4e67adc7b09b3ccb51475d93d3a"}}'
  ;;
repos/atrinik/content/git/ref/tags/v1.8.19)
  printf '%s\n' \
    '{"object":{"sha":"566bd25f78b80b08d5f75f4b02017ab2429204db"}}'
  ;;
repos/atrinik/content/releases/tags/v1.8.19)
  printf '%s\n' '{
    "tag_name":"v1.8.19",
    "draft":false,
    "prerelease":false,
    "assets":[
      {"name":"atrinik-content-1.8.19-runtime.tar.gz"},
      {"name":"atrinik-content-1.8.19.tar.gz"},
      {"name":"SHA256SUMS"}
    ]
  }'
  ;;
'repos/atrinik/content/pulls?state=open&base=1.x&per_page=100')
  if [[ ${GH_OPEN_PULL:-false} == true ]]; then
    printf '[{"number":1}]\n'
  else
    printf '[]\n'
  fi
  ;;
orgs/atrinik/rulesets)
  rulesets
  ;;
orgs/atrinik/rulesets/20571870)
  if [[ ${GH_RULESET_DRIFT:-false} == true ]]; then
    branch=retired
  else
    branch=1.x
  fi
  jq -n --arg branch "${branch}" '{
    id: 20571870,
    name: "05 - Maintenance branch - content - 1.x",
    target: "branch",
    enforcement: "active",
    bypass_actors: [{
      actor_id: null,
      actor_type: "OrganizationAdmin",
      bypass_mode: "pull_request"
    }],
    conditions: {
      repository_name: {include: ["content"], exclude: []},
      ref_name: {include: ["refs/heads/\($branch)"], exclude: []}
    },
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "required_linear_history"},
      {
        type: "pull_request",
        parameters: {
          allowed_merge_methods: ["merge", "squash", "rebase"],
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_approving_review_count: 0,
          required_review_thread_resolution: true,
          required_reviewers: []
        }
      },
      {
        type: "required_status_checks",
        parameters: {
          do_not_enforce_on_create: false,
          required_status_checks: [
            {context: "Content validation", integration_id: 15368},
            {context: "Conventional PR title", integration_id: 15368}
          ],
          strict_required_status_checks_policy: true
        }
      }
    ]
  }'
  ;;
*)
  echo "unexpected endpoint: ${endpoint}" >&2
  exit 1
  ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

present=${temporary}/ruleset-present
printf 'true\n' >"${present}"
plan_log=${temporary}/plan.jsonl
plan_output=${temporary}/plan.txt
GH_API_LOG=${plan_log} GH_RULESET_PRESENT=${present} \
  PATH="${temporary}/bin:${PATH}" \
  "${root}/bin/publish" --retire-maintenance content/1.x >"${plan_output}"

[[ $(grep -c '^PLAN ' "${plan_output}") == 1 ]]
grep -Fx 'PLAN DELETE /orgs/atrinik/rulesets/20571870' \
  "${plan_output}" >/dev/null
jq -s -e 'all(.[]; .method == "GET")' "${plan_log}" >/dev/null
[[ $(<"${present}") == true ]]

apply_log=${temporary}/apply.jsonl
apply_output=${temporary}/apply.txt
GH_API_LOG=${apply_log} GH_RULESET_PRESENT=${present} \
  PATH="${temporary}/bin:${PATH}" \
  "${root}/bin/publish" --apply \
  --retire-maintenance content/1.x >"${apply_output}"
jq -s -e '
  [.[] | select(.method != "GET")] == [{
    method: "DELETE",
    endpoint: "orgs/atrinik/rulesets/20571870"
  }]
' "${apply_log}" >/dev/null
grep -Fx 'APPLY verified only ruleset 20571870 is absent' \
  "${apply_output}" >/dev/null
[[ $(<"${present}") == false ]]

printf 'true\n' >"${present}"
if GH_API_LOG=${temporary}/open-pr.jsonl GH_RULESET_PRESENT=${present} \
  GH_OPEN_PULL=true PATH="${temporary}/bin:${PATH}" \
  "${root}/bin/publish" --retire-maintenance content/1.x \
  >"${temporary}/open-pr.out" 2>"${temporary}/open-pr.err"; then
  echo "retirement plan accepted an open target-branch pull request" >&2
  exit 1
fi
grep -F 'open pull requests still target the retirement branch' \
  "${temporary}/open-pr.err" >/dev/null

if GH_API_LOG=${temporary}/drift.jsonl GH_RULESET_PRESENT=${present} \
  GH_RULESET_DRIFT=true PATH="${temporary}/bin:${PATH}" \
  "${root}/bin/publish" --retire-maintenance content/1.x \
  >"${temporary}/drift.out" 2>"${temporary}/drift.err"; then
  echo "retirement plan accepted ruleset scope drift" >&2
  exit 1
fi
grep -F 'exact retirement ruleset payload drift' \
  "${temporary}/drift.err" >/dev/null

echo "Targeted maintenance retirement publisher tests passed."
