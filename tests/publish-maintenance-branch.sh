#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir "${temporary}/bin"

cat >"${temporary}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if [[ ${1:-} != api ]]; then
  echo "unexpected gh command" >&2
  exit 1
fi
shift

method=GET
endpoint=
input=
jq_filter=
while (($#)); do
  case $1 in
  -H | --header)
    shift 2
    ;;
  --method)
    method=$2
    shift 2
    ;;
  --input)
    input=$2
    shift 2
    ;;
  --jq)
    jq_filter=$2
    shift 2
    ;;
  --paginate)
    shift
    ;;
  *)
    if [[ -n ${endpoint} ]]; then
      echo "unexpected gh api argument: $1" >&2
      exit 1
    fi
    endpoint=$1
    shift
    ;;
  esac
done

payload=null
if [[ -n ${input} ]]; then
  payload=$(jq -c . "${input}")
fi
jq -cn \
  --arg method "${method}" \
  --arg endpoint "${endpoint}" \
  --argjson payload "${payload}" \
  '{method: $method, endpoint: $endpoint, payload: $payload}' \
  >>"${GH_API_LOG}"

if [[ ${method} != GET ]]; then
  printf '{}\n'
  exit 0
fi

case "${endpoint}|${jq_filter}" in
"orgs/atrinik|.plan.name")
  printf 'team\n'
  ;;
"orgs/atrinik|.members_can_create_teams")
  printf 'false\n'
  ;;
"orgs/atrinik/repos?per_page=100&type=all|"*)
  printf 'content\n'
  ;;
"orgs/atrinik/rulesets|"*)
  printf '[{"id":900,"name":"05 - Maintenance branch - content - retired"}]\n'
  ;;
"orgs/atrinik/code-security/configurations|"*)
  printf '[{"id":265376,"name":"Atrinik security baseline"}]\n'
  ;;
"repos/atrinik/nawerhals|.archived")
  printf 'true\n'
  ;;
"repos/atrinik/legacy-client|.archived" | \
"repos/atrinik/legacy-editor|.archived" | \
"repos/atrinik/legacy-libatrinik|.archived" | \
"repos/atrinik/legacy-protocol|.archived" | \
"repos/atrinik/legacy-server|.archived")
  printf 'false\n'
  ;;
repos/atrinik/*/rulesets\?includes_parents=false\|*)
  printf '[{"id":900,"name":"05 - Maintenance branch - content - retired"}]\n'
  ;;
*)
  printf '[]\n'
  ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

assert_maintenance_payload() {
  local log=$1
  local endpoint=$2
  local organization_scope=$3

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --argjson organization_scope "${organization_scope}" '
      [
        .[] |
        select(
          .method == "POST" and
          .endpoint == $endpoint and
          .payload.name == "05 - Maintenance branch - content - 1.x"
        )
      ] as $matches |
      ($matches | length) == 1 and
      ($matches[0].payload.target == "branch") and
      ($matches[0].payload.enforcement == "active") and
      ($matches[0].payload.conditions.ref_name.include == ["refs/heads/1.x"]) and
      (
        ($matches[0].payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($organization_scope | not) or
        ($matches[0].payload.conditions.repository_name.include == ["content"])
      ) and
      (
        [$matches[0].payload.rules[].type] == [
          "deletion",
          "non_fast_forward",
          "required_linear_history",
          "pull_request",
          "required_status_checks"
        ]
      ) and
      (
        [
          $matches[0].payload.rules[] |
          select(.type == "required_status_checks") |
          .parameters.required_status_checks[]
        ] == [
          {context: "Conventional PR title", integration_id: 15368}
        ]
      ) and
      all(
        .[];
        .payload.name != "03 - Required CI - client" and
        .payload.name != "03 - Required CI - editor" and
        .payload.name != "03 - Required CI - protocol" and
        .payload.name != "03 - Required CI - renderer" and
        .payload.name != "03 - Required CI - server"
      )
    ' "${log}" >/dev/null
}

organization_log=${temporary}/organization.jsonl
GH_API_LOG=${organization_log} \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >/dev/null
assert_maintenance_payload \
  "${organization_log}" "orgs/atrinik/rulesets" true
jq -s -e '
  any(
    .[];
    .method == "DELETE" and
    .endpoint == "orgs/atrinik/rulesets/900"
  )
' "${organization_log}" >/dev/null

repository_log=${temporary}/repository.jsonl
GH_API_LOG=${repository_log} \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${root}/bin/publish" --apply >/dev/null
assert_maintenance_payload \
  "${repository_log}" "repos/atrinik/content/rulesets" false
jq -s -e '
  any(
    .[];
    .method == "DELETE" and
    .endpoint == "repos/atrinik/content/rulesets/900"
  ) and
  any(
    .[];
    .method == "DELETE" and
    .endpoint == "orgs/atrinik/rulesets/900"
  )
' "${repository_log}" >/dev/null

for repository in \
  legacy-client \
  legacy-editor \
  legacy-libatrinik \
  legacy-protocol \
  legacy-server; do
  jq -s -e \
    --arg endpoint "repos/atrinik/${repository}" '
      any(
        .[];
        .method == "PATCH" and
        .endpoint == $endpoint and
        .payload == {archived: true}
      )
    ' "${organization_log}" >/dev/null
done

echo "Maintenance branch publisher tests passed."
