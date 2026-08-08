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

security_scenario=${GH_SECURITY_SCENARIO:-converged}

if [[ ${method} == PUT ]] &&
  [[ ${endpoint} == orgs/atrinik/settings/immutable-releases ]]; then
  jq -c . "${input}" >"${GH_IMMUTABLE_STATE}"
  printf '{}\n'
  exit 0
fi

attachment_was_requested() {
  local configuration_id=$1
  local repository_id=$2

  jq -s -e \
    --arg endpoint \
      "orgs/atrinik/code-security/configurations/${configuration_id}/attach" \
    --argjson repository_id "${repository_id}" '
      any(
        .[];
        .method == "POST" and
        .endpoint == $endpoint and
        (.payload.selected_repository_ids | index($repository_id)) != null
      )
  ' "${GH_API_LOG}" >/dev/null
}

print_attachment_progress() {
  local configuration_id=$1
  local repository_id=$2
  local repository=$3
  local checks

  checks=$(jq -s \
    --arg attach_endpoint \
      "orgs/atrinik/code-security/configurations/${configuration_id}/attach" \
    --arg repository_endpoint \
      "repos/atrinik/${repository}/code-security-configuration" \
    --argjson repository_id "${repository_id}" '
      . as $events |
      (
        [
          $events | to_entries[] |
          select(
            .value.method == "POST" and
            .value.endpoint == $attach_endpoint and
            (
              .value.payload.selected_repository_ids |
              index($repository_id)
            ) != null
          ) |
          .key
        ] | last
      ) as $attach |
      [
        $events | to_entries[] |
        select(
          .key > $attach and
          .value.method == "GET" and
          .value.endpoint == $repository_endpoint
        )
      ] | length
    ' "${GH_API_LOG}")

  if ((checks == 1)); then
    printf '{"status":"attached","configuration":{"id":%s}}\n' \
      "${configuration_id}"
  else
    printf '{"status":"enforced","configuration":{"id":%s}}\n' \
      "${configuration_id}"
  fi
}

print_existing_attachment_progress() {
  local configuration_id=$1
  local repository=$2
  local checks

  checks=$(jq -s \
    --arg endpoint \
      "repos/atrinik/${repository}/code-security-configuration" '
      [
        .[] |
        select(.method == "GET" and .endpoint == $endpoint)
      ] | length
    ' "${GH_API_LOG}")

  if ((checks == 1)); then
    printf '{"status":"attached","configuration":{"id":%s}}\n' \
      "${configuration_id}"
  else
    printf '{"status":"enforced","configuration":{"id":%s}}\n' \
      "${configuration_id}"
  fi
}

print_security_configuration() {
  local id=$1
  local advanced=$2
  local name description allow_advanced push_protection

  name="Atrinik security baseline"
  description="Required security features for all Atrinik repositories."
  allow_advanced=false
  if [[ ${advanced} == true ]]; then
    name="Atrinik advanced CodeQL baseline"
    description="Atrinik security baseline for repositories with governed CodeQL advanced setup."
    allow_advanced=true
  fi

  push_protection=enabled
  if [[ ${security_scenario} == drifted ]]; then
    push_protection=disabled
  fi

  jq -cn \
    --argjson id "${id}" \
    --arg name "${name}" \
    --arg description "${description}" \
    --argjson allow_advanced "${allow_advanced}" \
    --arg push_protection "${push_protection}" '
      {
        id: $id,
        name: $name,
        description: $description,
        advanced_security: "enabled",
        dependency_graph: "enabled",
        dependabot_alerts: "enabled",
        dependabot_security_updates: "enabled",
        code_scanning_default_setup: "enabled",
        code_scanning_options: {allow_advanced: $allow_advanced},
        secret_scanning: "enabled",
        secret_scanning_push_protection: $push_protection,
        secret_scanning_validity_checks: "enabled",
        private_vulnerability_reporting: "enabled",
        enforcement: "enforced"
      }
    '
}

if [[ ${method} != GET ]]; then
  if [[ ${security_scenario} == converged ]] &&
    [[ ${method} == POST ]] &&
    [[ ${endpoint} == orgs/atrinik/code-security/configurations/*/attach ]]; then
    : >"${GH_ENABLEMENT_EVENT_FILE:?}"
  fi
  if [[ ${security_scenario} == converged ]] &&
    [[ ${method} == PATCH ]] &&
    [[ ${endpoint} == orgs/atrinik/code-security/configurations/* ]] &&
    [[ -f ${GH_ENABLEMENT_EVENT_FILE:-} ]]; then
    echo "Another enablement event is in progress" >&2
    exit 1
  fi
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
  printf 'classic\t%s\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n' \
    "${GH_CLASSIC_REPOSITORY_ID:-1327289971}"
  printf 'content\t101\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n'
  printf 'classic-ghsa-8533-3vg8-r287\t999\ttrue\tprivate\tfalse\tfalse\tfalse\tfalse\tfalse\n'
  ;;
"orgs/atrinik/settings/immutable-releases|"*)
  jq '{enforced_repositories}' "${GH_IMMUTABLE_STATE}"
  ;;
"orgs/atrinik/settings/immutable-releases/repositories?per_page=100|"*)
  jq '
    {
      total_count: (.selected_repository_ids | length),
      repositories: [.selected_repository_ids[]? | {id: .}]
    }
  ' "${GH_IMMUTABLE_STATE}" | jq -r "${jq_filter}"
  ;;
"repos/atrinik/classic/immutable-releases|"*)
  if [[ ${GH_IMMUTABLE_VERIFY_FAILURE:-false} == true ]]; then
    printf '{"enabled":false,"enforced_by_owner":false}\n'
  elif jq -e '
    .enforced_repositories == "all" or
    (
      .enforced_repositories == "selected" and
      (.selected_repository_ids | index(1327289971)) != null
    )
  ' "${GH_IMMUTABLE_STATE}" >/dev/null; then
    printf '{"enabled":true,"enforced_by_owner":true}\n'
  else
    printf '{"enabled":false,"enforced_by_owner":false}\n'
  fi
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
"orgs/atrinik/code-security/configurations/265376|"*)
  print_security_configuration 265376 false
  ;;
"orgs/atrinik/code-security/configurations/265377|"*)
  print_security_configuration 265377 true
  ;;
"orgs/atrinik/code-security/configurations/defaults|"*)
  if [[ ${security_scenario} == drifted ]]; then
    printf '[]\n'
  else
    printf '[{"default_for_new_repos":"all","configuration":{"id":265376}}]\n'
  fi
  ;;
"repos/atrinik/classic/code-security-configuration|"*)
  if [[ ${GH_EMPTY_ADVANCED_INVENTORY:-false} == true ]]; then
    if attachment_was_requested 265376 1327289971; then
      print_attachment_progress 265376 1327289971 classic
    else
      printf '{"status":"enforced","configuration":{"id":265377}}\n'
    fi
  elif [[ ${security_scenario} == drifted ||
    ${security_scenario} == create ]]; then
    if attachment_was_requested 265377 1327289971; then
      print_attachment_progress 265377 1327289971 classic
    else
      printf '{"status":"enforced","configuration":{"id":265376}}\n'
    fi
  elif [[ ${security_scenario} == pending ]]; then
    print_existing_attachment_progress 265377 classic
  else
    printf '{"status":"enforced","configuration":{"id":265377}}\n'
  fi
  ;;
"repos/atrinik/content/code-security-configuration|"*)
  if [[ ${security_scenario} == drifted ]]; then
    if attachment_was_requested 265376 101; then
      print_attachment_progress 265376 101 content
    else
      printf '{"status":"enforced","configuration":{"id":265377}}\n'
    fi
  else
    printf '{"status":"enforced","configuration":{"id":265376}}\n'
  fi
  ;;
"repos/atrinik/classic/code-scanning/default-setup|"*)
  if [[ ${security_scenario} == drifted ||
    ${security_scenario} == create ||
    ${GH_EMPTY_ADVANCED_INVENTORY:-false} == true ]]; then
    printf '{"state":"configured","query_suite":"default"}\n'
  else
    printf '{"state":"not-configured","query_suite":"default"}\n'
  fi
  ;;
"repos/atrinik/content/code-scanning/default-setup|"*)
  if [[ ${security_scenario} == drifted ||
    ${security_scenario} == create ]]; then
    printf '{"state":"not-configured"}\n'
  else
    printf '{"state":"configured","query_suite":"default"}\n'
  fi
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

cat >"${temporary}/bin/sleep" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

if (($# != 1)) || [[ $1 != 2 ]]; then
  echo "unexpected security publisher sleep: $*" >&2
  exit 1
fi
EOF
chmod +x "${temporary}/bin/sleep"

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
          {context: "Content validation", integration_id: 15368},
          {context: "Conventional PR title", integration_id: 15368}
        ]
      )
    ' "${log}" >/dev/null
}

assert_replacement_required_ci_payload() {
  local log=$1
  local endpoint=$2
  local organization_scope=$3
  local repository=$4
  local validation_context=$5
  local ruleset_name="03 - Required CI"

  if [[ ${organization_scope} == true ]]; then
    ruleset_name="03 - Required CI - ${repository}"
  fi

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --arg ruleset_name "${ruleset_name}" \
    --arg repository "${repository}" \
    --arg validation_context "${validation_context}" \
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
        ($matches[0].payload.conditions.repository_name.include == [$repository])
      ) and
      (
        $matches[0].payload.rules[0].parameters.required_status_checks == [
          {context: $validation_context, integration_id: 15368},
          {context: "Conventional PR title", integration_id: 15368}
        ]
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
      .payload == {
        scope: "selected",
        selected_repository_ids: [1327289971]
      }
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
      ] as $attachment_checks |
      [
        to_entries[] |
        select(
          .value.method == "PATCH" and
          .value.endpoint ==
            "repos/atrinik/classic/code-scanning/default-setup"
        ) |
        .key
      ][0] as $disable |
      ($attachment_checks | length) >= 3 and
      $attachment_checks[0] < $attach and
      $attach < $attachment_checks[-1] and
      $attachment_checks[-1] < $disable
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
      .payload == {
        scope: "selected",
        selected_repository_ids: [1327289971]
      }
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
      .payload == {
        scope: "selected",
        selected_repository_ids: [1327289971]
      }
    ) and
    all(
      .[];
      .method != "PATCH" or
      .endpoint != "repos/atrinik/classic/code-scanning/default-setup" or
      .payload != {state: "not-configured"}
    )
  ' "${log}" >/dev/null
}

assert_immutable_release_apply() {
  local log=$1

  jq -s -e '
    . as $calls |
    [
      .[] |
      select(
        .method == "PUT" and
        .endpoint == "orgs/atrinik/settings/immutable-releases"
      )
    ] == [
      {
        method: "PUT",
        endpoint: "orgs/atrinik/settings/immutable-releases",
        payload: {
          enforced_repositories: "selected",
          selected_repository_ids: [1327289971]
        }
      }
    ] and
    (
      [
        $calls | to_entries[] |
        select(
          .value.method == "PUT" and
          .value.endpoint ==
            "orgs/atrinik/settings/immutable-releases"
        ) |
        .key
      ][0] as $put |
      any(
        $calls | to_entries[];
        .key > $put and
        .value.method == "GET" and
        .value.endpoint == "repos/atrinik/classic/immutable-releases"
      )
    )
  ' "${log}" >/dev/null
}

assert_idempotent_organization_security() {
  local log=$1

  jq -s -e '
    all(
      .[];
      .method == "GET" or
      (
        (.endpoint | startswith(
          "orgs/atrinik/code-security/configurations"
        ) | not) and
        (
          (
            .endpoint | startswith("repos/atrinik/") and
            endswith("/code-scanning/default-setup")
          ) | not
        )
      )
    )
  ' "${log}" >/dev/null
}

organization_log=${temporary}/organization.jsonl
organization_immutable_state=${temporary}/organization-immutable.json
printf '{"enforced_repositories":"none"}\n' \
  >"${organization_immutable_state}"
GH_API_LOG=${organization_log} \
  GH_IMMUTABLE_STATE=${organization_immutable_state} \
  GH_SECURITY_SCENARIO=drifted \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >"${temporary}/organization.txt"
grep -F \
  'SKIP atrinik/classic-ghsa-8533-3vg8-r287 is a temporary security-advisory workspace' \
  "${temporary}/organization.txt" >/dev/null
jq -s -e '
  all(
    .[];
    (.endpoint | contains("classic-ghsa-8533-3vg8-r287") | not)
  )
' "${organization_log}" >/dev/null
assert_immutable_release_apply "${organization_log}"
assert_maintenance_payload \
  "${organization_log}" "orgs/atrinik/rulesets" true
assert_classic_required_ci_payload \
  "${organization_log}" "orgs/atrinik/rulesets" true
while IFS=$'\t' read -r repository validation_context; do
  assert_replacement_required_ci_payload \
    "${organization_log}" "orgs/atrinik/rulesets" true \
    "${repository}" "${validation_context}"
done <<'EOF'
client	Client validation
content-toolkit	Content toolkit validation
editor	Editor validation
protocol	Protocol validation
renderer	Renderer validation
server	Server validation
website	Website validation
EOF
assert_organization_codeql_configurations "${organization_log}"
assert_codeql_default_setup "${organization_log}"
jq -s -e '
  any(
    .[];
    .method == "DELETE" and
    .endpoint == "orgs/atrinik/rulesets/900"
  )
' "${organization_log}" >/dev/null

idempotent_log=${temporary}/organization-idempotent.jsonl
idempotent_output=${temporary}/organization-idempotent.txt
enablement_event=${temporary}/enablement-event
GH_API_LOG=${idempotent_log} \
  GH_ENABLEMENT_EVENT_FILE=${enablement_event} \
  GH_IMMUTABLE_STATE=${organization_immutable_state} \
  GH_SECURITY_SCENARIO=converged \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >"${idempotent_output}"
assert_idempotent_organization_security "${idempotent_log}"
[[ ! -e ${enablement_event} ]]
grep -F \
  'KEEP /orgs/atrinik/code-security/configurations/265377 matches config/code-security-advanced.json' \
  "${idempotent_output}" >/dev/null
grep -F \
  'KEEP /orgs/atrinik/code-security/configurations/265377/attach already covers 1 repositories' \
  "${idempotent_output}" >/dev/null
grep -F \
  'KEEP /orgs/atrinik/code-security/configurations/265376/defaults is all' \
  "${idempotent_output}" >/dev/null

pending_log=${temporary}/organization-pending.jsonl
GH_API_LOG=${pending_log} \
  GH_IMMUTABLE_STATE=${organization_immutable_state} \
  GH_SECURITY_SCENARIO=pending \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >/dev/null
assert_idempotent_organization_security "${pending_log}"
jq -s -e '
  (
    [
      .[] |
      select(
        .method == "GET" and
        .endpoint ==
          "repos/atrinik/classic/code-security-configuration"
      )
    ] | length
  ) >= 2
' "${pending_log}" >/dev/null

creation_log=${temporary}/organization-create-codeql.jsonl
creation_immutable_state=${temporary}/organization-create-codeql-immutable.json
printf '{"enforced_repositories":"none"}\n' \
  >"${creation_immutable_state}"
GH_API_LOG=${creation_log} \
  GH_ADVANCED_CONFIG_MISSING=true \
  GH_IMMUTABLE_STATE=${creation_immutable_state} \
  GH_SECURITY_SCENARIO=create \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >/dev/null
assert_advanced_configuration_created "${creation_log}"
assert_codeql_default_setup "${creation_log}"

rollback_root=${temporary}/empty-inventory
mkdir -p "${rollback_root}/bin"
cp "${root}/bin/publish" "${root}/bin/validate" "${rollback_root}/bin/"
cp -R "${root}/config" "${rollback_root}/config"
cp -R "${root}/community-health" "${rollback_root}/community-health"
jq '.repositories = []' \
  "${root}/config/codeql-advanced-setup.json" \
  >"${rollback_root}/config/codeql-advanced-setup.json"
rollback_log=${temporary}/empty-inventory.jsonl
rollback_output=${temporary}/empty-inventory.txt
empty_inventory_immutable_state=${temporary}/empty-inventory-immutable.json
printf '{"enforced_repositories":"none"}\n' \
  >"${empty_inventory_immutable_state}"
GH_API_LOG=${rollback_log} \
  GH_EMPTY_ADVANCED_INVENTORY=true \
  GH_IMMUTABLE_STATE=${empty_inventory_immutable_state} \
  GH_SECURITY_SCENARIO=rollback \
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
repository_immutable_state=${temporary}/repository-immutable.json
printf '{"enforced_repositories":"none"}\n' \
  >"${repository_immutable_state}"
GH_API_LOG=${repository_log} \
  GH_IMMUTABLE_STATE=${repository_immutable_state} \
  GH_SECURITY_SCENARIO=drifted \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${root}/bin/publish" --apply >/dev/null
assert_maintenance_payload \
  "${repository_log}" "repos/atrinik/content/rulesets" false
assert_classic_required_ci_payload \
  "${repository_log}" "repos/atrinik/classic/rulesets" false
while IFS=$'\t' read -r repository validation_context; do
  assert_replacement_required_ci_payload \
    "${repository_log}" "repos/atrinik/${repository}/rulesets" false \
    "${repository}" "${validation_context}"
done <<'EOF'
client	Client validation
content-toolkit	Content toolkit validation
editor	Editor validation
protocol	Protocol validation
renderer	Renderer validation
server	Server validation
website	Website validation
EOF
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
plan_immutable_state=${temporary}/plan-immutable.json
printf '{"enforced_repositories":"none"}\n' >"${plan_immutable_state}"
GH_API_LOG=${temporary}/plan.jsonl \
  GH_IMMUTABLE_STATE=${plan_immutable_state} \
  GH_SECURITY_SCENARIO=drifted \
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
grep -F \
  'PLAN PUT /orgs/atrinik/settings/immutable-releases <= {"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN VERIFY /repos/atrinik/classic/immutable-releases => enabled=true,enforced_by_owner=true' \
  "${plan_output}" >/dev/null
jq -e '. == {enforced_repositories: "none"}' \
  "${plan_immutable_state}" >/dev/null
jq -s -e '
  all(
    .[];
    .method != "PUT" or
    .endpoint != "orgs/atrinik/settings/immutable-releases"
  )
' "${temporary}/plan.jsonl" >/dev/null

keep_log=${temporary}/immutable-keep.jsonl
keep_output=${temporary}/immutable-keep.txt
keep_immutable_state=${temporary}/immutable-keep-state.json
printf '%s\n' \
  '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' \
  >"${keep_immutable_state}"
GH_API_LOG=${keep_log} \
  GH_IMMUTABLE_STATE=${keep_immutable_state} \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${root}/bin/publish" --apply >"${keep_output}"
grep -F \
  'KEEP /orgs/atrinik/settings/immutable-releases is {"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' \
  "${keep_output}" >/dev/null
jq -s -e '
  all(
    .[];
    .method != "PUT" or
    .endpoint != "orgs/atrinik/settings/immutable-releases"
  )
' "${keep_log}" >/dev/null

immutable_rollback_log=${temporary}/immutable-rollback.jsonl
immutable_rollback_output=${temporary}/immutable-rollback.txt
immutable_rollback_state=${temporary}/immutable-rollback-state.json
printf '%s\n' \
  '{"enforced_repositories":"selected","selected_repository_ids":[101]}' \
  >"${immutable_rollback_state}"
if GH_API_LOG=${immutable_rollback_log} \
  GH_IMMUTABLE_STATE=${immutable_rollback_state} \
  GH_IMMUTABLE_VERIFY_FAILURE=true \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply \
  >"${immutable_rollback_output}" 2>&1; then
  echo "expected immutable-release verification failure" >&2
  exit 1
fi
jq -e '. == {
  enforced_repositories: "selected",
  selected_repository_ids: [101]
}' "${immutable_rollback_state}" >/dev/null
jq -s -e '
  [
    .[] |
    select(
      .method == "PUT" and
      .endpoint == "orgs/atrinik/settings/immutable-releases"
    ) |
    .payload
  ] == [
    {
      enforced_repositories: "selected",
      selected_repository_ids: [1327289971]
    },
    {
      enforced_repositories: "selected",
      selected_repository_ids: [101]
    }
  ]
' "${immutable_rollback_log}" >/dev/null
grep -F \
  'ROLLBACK verified the previous immutable-release policy' \
  "${immutable_rollback_output}" >/dev/null

identity_drift_log=${temporary}/immutable-identity-drift.jsonl
identity_drift_output=${temporary}/immutable-identity-drift.txt
identity_drift_state=${temporary}/immutable-identity-drift-state.json
printf '{"enforced_repositories":"none"}\n' >"${identity_drift_state}"
if GH_API_LOG=${identity_drift_log} \
  GH_IMMUTABLE_STATE=${identity_drift_state} \
  GH_CLASSIC_REPOSITORY_ID=999 \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" --apply >"${identity_drift_output}" 2>&1; then
  echo "expected immutable-release repository identity failure" >&2
  exit 1
fi
grep -F \
  'error: immutable-release inventory id for classic is 1327289971, but GitHub reports 999' \
  "${identity_drift_output}" >/dev/null
jq -s -e 'all(.[]; .method == "GET")' "${identity_drift_log}" >/dev/null

echo "Publisher policy-scope tests passed."
