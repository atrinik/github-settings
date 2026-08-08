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
  if [[ ${method} == POST ]] &&
    [[ ${endpoint} == orgs/atrinik/code-security/configurations ]]; then
    printf '{"id":265377}\n'
  else
    printf '{}\n'
  fi
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
  printf 'classic\t102\ncontent\t101\n'
  ;;
"orgs/atrinik/rulesets|"*)
  printf '[{"id":900,"name":"05 - Maintenance branch - content - retired"}]\n'
  ;;
"orgs/atrinik/code-security/configurations|"*)
  if [[ ${GH_ADVANCED_CONFIG_MISSING:-false} == true ]]; then
    printf '[{"id":265376,"name":"Atrinik security baseline"}]\n'
  else
    printf '[{"id":265376,"name":"Atrinik security baseline"},{"id":265377,"name":"Atrinik advanced CodeQL baseline"}]\n'
  fi
  ;;
"repos/atrinik/classic/code-security-configuration|"*)
  if [[ ${GH_EMPTY_ADVANCED_INVENTORY:-false} == true ]]; then
    printf '{"status":"attached","configuration":{"id":265376}}\n'
  else
    printf '{"status":"attached","configuration":{"id":265377}}\n'
  fi
  ;;
"repos/atrinik/content/code-security-configuration|"*)
  printf '{"status":"attached","configuration":{"id":265376}}\n'
  ;;
"repos/atrinik/classic/code-scanning/default-setup|"*)
  printf '{"state":"configured","query_suite":"default"}\n'
  ;;
"repos/atrinik/content/code-scanning/default-setup|"*)
  printf '{"state":"not-configured"}\n'
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

assert_classic_required_ci_payload() {
  local log=$1
  local endpoint=$2
  local organization_scope=$3
  local ruleset_name="03 - Required CI"

  if [[ ${organization_scope} == true ]]; then
    ruleset_name="03 - Required CI - classic"
  fi

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --arg ruleset_name "${ruleset_name}" \
    --argjson organization_scope "${organization_scope}" '
      [
        .[] |
        select(
          .method == "POST" and
          .endpoint == $endpoint and
          .payload.name == $ruleset_name
        )
      ] as $matches |
      ($matches | length) == 1 and
      (
        ($matches[0].payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($organization_scope | not) or
        ($matches[0].payload.conditions.repository_name.include == ["classic"])
      ) and
      (
        $matches[0].payload.rules[0].parameters.required_status_checks == [
          {context: "Classic validation", integration_id: 15368},
          {context: "CodeQL validation", integration_id: 15368},
          {context: "Conventional PR title", integration_id: 15368}
        ]
      )
    ' "${log}" >/dev/null
}

assert_codeql_default_setup() {
  local log=$1

  jq -s -e '
    any(
      .[];
      .method == "PATCH" and
      .endpoint == "repos/atrinik/classic/code-scanning/default-setup" and
      .payload == {state: "not-configured"}
    ) and
    any(
      .[];
      .method == "PATCH" and
      .endpoint == "repos/atrinik/content/code-scanning/default-setup" and
      .payload == {state: "configured", query_suite: "default"}
    )
  ' "${log}" >/dev/null
}

assert_organization_codeql_configurations() {
  local log=$1

  jq -s -e '
    any(
      .[];
      .method == "PATCH" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265377" and
      .payload.name == "Atrinik advanced CodeQL baseline" and
      .payload.code_scanning_default_setup == "enabled" and
      .payload.code_scanning_options == {allow_advanced: true} and
      .payload.enforcement == "enforced"
    ) and
    any(
      .[];
      .method == "POST" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265377/attach" and
      .payload == {scope: "selected", selected_repository_ids: [102]}
    ) and
    any(
      .[];
      .method == "PATCH" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265376" and
      .payload.name == "Atrinik security baseline" and
      .payload.code_scanning_default_setup == "enabled" and
      .payload.code_scanning_options == {allow_advanced: false} and
      .payload.enforcement == "enforced"
    ) and
    any(
      .[];
      .method == "PUT" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265376/defaults" and
      .payload == {default_for_new_repos: "all"}
    ) and
    any(
      .[];
      .method == "POST" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265376/attach" and
      .payload == {scope: "selected", selected_repository_ids: [101]}
    ) and
    (
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint ==
            "orgs/atrinik/code-security/configurations/265377/attach"
        ) |
        .key
      ][0] as $attach |
      [
        to_entries[] |
        select(
          .value.method == "GET" and
          .value.endpoint ==
            "repos/atrinik/classic/code-security-configuration"
        ) |
        .key
      ][0] as $attached |
      [
        to_entries[] |
        select(
          .value.method == "PATCH" and
          .value.endpoint ==
            "repos/atrinik/classic/code-scanning/default-setup"
        ) |
        .key
      ][0] as $disable |
      $attach < $attached and $attached < $disable
    )
  ' "${log}" >/dev/null
}

assert_repository_security_preserved() {
  local log=$1

  jq -s -e '
    any(
      .[];
      .method == "PATCH" and
      .endpoint == "repos/atrinik/classic" and
      .payload.security_and_analysis.secret_scanning.status == "enabled" and
      .payload.security_and_analysis.secret_scanning_push_protection.status ==
        "enabled" and
      .payload.security_and_analysis.secret_scanning_validity_checks.status ==
        "enabled"
    ) and
    any(
      .[];
      .method == "PUT" and
      .endpoint == "repos/atrinik/classic/vulnerability-alerts"
    ) and
    any(
      .[];
      .method == "PUT" and
      .endpoint == "repos/atrinik/classic/automated-security-fixes"
    ) and
    any(
      .[];
      .method == "PUT" and
      .endpoint == "repos/atrinik/classic/private-vulnerability-reporting"
    )
  ' "${log}" >/dev/null
}

assert_advanced_configuration_created() {
  local log=$1

  jq -s -e '
    any(
      .[];
      .method == "POST" and
      .endpoint == "orgs/atrinik/code-security/configurations" and
      .payload.name == "Atrinik advanced CodeQL baseline" and
      .payload.code_scanning_options == {allow_advanced: true}
    ) and
    any(
      .[];
      .method == "POST" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265377/attach" and
      .payload == {scope: "selected", selected_repository_ids: [102]}
    )
  ' "${log}" >/dev/null
}

assert_empty_inventory_rollback() {
  local log=$1

  jq -s -e '
    all(
      .[];
      .method != "POST" or
      .endpoint !=
        "orgs/atrinik/code-security/configurations/265377/attach"
    ) and
    any(
      .[];
      .method == "POST" and
      .endpoint ==
        "orgs/atrinik/code-security/configurations/265376/attach" and
      .payload == {scope: "selected", selected_repository_ids: [102, 101]}
    ) and
    all(
      .[];
      .method != "PATCH" or
      .endpoint != "repos/atrinik/classic/code-scanning/default-setup" or
      .payload != {state: "not-configured"}
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
assert_classic_required_ci_payload \
  "${organization_log}" "orgs/atrinik/rulesets" true
assert_organization_codeql_configurations "${organization_log}"
assert_codeql_default_setup "${organization_log}"
jq -s -e '
  any(
    .[];
    .method == "DELETE" and
    .endpoint == "orgs/atrinik/rulesets/900"
  )
' "${organization_log}" >/dev/null

creation_log=${temporary}/organization-create-codeql.jsonl
GH_API_LOG=${creation_log} \
  GH_ADVANCED_CONFIG_MISSING=true \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >/dev/null
assert_advanced_configuration_created "${creation_log}"
assert_codeql_default_setup "${creation_log}"

rollback_root=${temporary}/empty-inventory
mkdir -p "${rollback_root}/bin"
cp "${root}/bin/publish" "${root}/bin/validate" "${rollback_root}/bin/"
cp -R "${root}/config" "${rollback_root}/config"
jq '.repositories = []' \
  "${root}/config/codeql-advanced-setup.json" \
  >"${rollback_root}/config/codeql-advanced-setup.json"
rollback_log=${temporary}/empty-inventory.jsonl
rollback_output=${temporary}/empty-inventory.txt
GH_API_LOG=${rollback_log} \
  GH_EMPTY_ADVANCED_INVENTORY=true \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${rollback_root}/bin/publish" --apply >"${rollback_output}"
assert_empty_inventory_rollback "${rollback_log}"
grep -F 'SKIP advanced CodeQL attachment: inventory is empty' \
  "${rollback_output}" >/dev/null
grep -F \
  'KEEP /repos/atrinik/classic/code-scanning/default-setup is configured' \
  "${rollback_output}" >/dev/null

repository_log=${temporary}/repository.jsonl
GH_API_LOG=${repository_log} \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${root}/bin/publish" --apply >/dev/null
assert_maintenance_payload \
  "${repository_log}" "repos/atrinik/content/rulesets" false
assert_classic_required_ci_payload \
  "${repository_log}" "repos/atrinik/classic/rulesets" false
assert_repository_security_preserved "${repository_log}"
assert_codeql_default_setup "${repository_log}"
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

plan_output=${temporary}/plan.txt
GH_API_LOG=${temporary}/plan.jsonl \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" >"${plan_output}"
grep -F \
  'PLAN POST /orgs/atrinik/code-security/configurations/265377/attach' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN WAIT /repos/atrinik/classic/code-security-configuration => 265377' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN PATCH /repos/atrinik/classic/code-scanning/default-setup <= config/codeql-default-setup-advanced.json' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN POST /orgs/atrinik/code-security/configurations/265376/attach' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN WAIT /repos/atrinik/content/code-security-configuration => 265376' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN PATCH /repos/atrinik/content/code-scanning/default-setup <= config/codeql-default-setup.json' \
  "${plan_output}" >/dev/null

echo "Publisher policy-scope tests passed."
