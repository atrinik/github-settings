#!/usr/bin/env bash

set -euo pipefail

# This harness supplies a fake `gh` on PATH for every publisher invocation.
# Keep its CI credential synthetic even when the surrounding test runner
# deliberately clears GH_TOKEN to exercise other scripts' production gate.
export GH_TOKEN=test-token

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
source_root=${root}
# Retain the original Classic rollout/recovery scenarios as a bounded fixture.
root=${temporary}/classic-policy
mkdir -p "${root}/bin"
cp "${source_root}/bin/publish" "${source_root}/bin/validate" \
  "${source_root}/bin/security-readiness" "${root}/bin/"
cp -R "${source_root}/lib" "${root}/lib"
cp -R "${source_root}/config" "${source_root}/community-health" "${source_root}/.github" "${root}/"
jq '.repositories |= map(select(.name == "classic"))' \
  "${source_root}/config/immutable-releases.json" >"${root}/config/immutable-releases.json"
mkdir "${temporary}/bin"
export GH_SELECTED_ACTIONS_POLICY=${root}/config/actions-selected.json

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

crate_repository_id() {
  case $1 in
  protocol) printf '%s\n' 1327106950 ;;
  content-toolkit) printf '%s\n' 1327107043 ;;
  *) return 1 ;;
  esac
}

crate_workflow_content() {
  local repository=$1
  local workflow=$2
  local fixture=${GH_CRATE_FIXTURE_ROOT:?}/tests/fixtures
  local identifier

  identifier=$(crate_repository_id "${repository}")
  if [[ ${GH_CRATE_SETUP_SCENARIO:-qualified} == malformed-workflow ]] &&
    [[ ${workflow} == publish-crate.yml ]]; then
    printf 'not: [a reviewed workflow\n'
    return
  fi
  if [[ ${workflow} == publish-crate.yml ]]; then
    sed -e "s|atrinik/protocol|atrinik/${repository}|g" \
      -e "s/1327106950/${identifier}/g" "${fixture}/crate-publication.yml"
  else
    cat "${fixture}/crate-source-release.yml"
  fi
}

crate_environment() {
  local bypass=false
  if [[ ${GH_CRATE_SETUP_SCENARIO:-qualified} == environment-drift ]]; then
    bypass=true
  fi
  jq -cn --argjson bypass "${bypass}" '{
    name: "crates-io-release",
    deployment_branch_policy: {protected_branches: false, custom_branch_policies: true},
    protection_rules: [{type: "branch_policy"}],
    can_admins_bypass: $bypass
  }'
}

immutable_release_snapshot() {
  if [[ ${GH_CRATE_SNAPSHOT_DRIFT:-false} == true ]] &&
    (( $(jq -s '[.[] | select(.method == "GET" and .endpoint == "orgs/atrinik/settings/immutable-releases")] | length' "${GH_API_LOG}") >= 2 )); then
    printf '{"enforced_repositories":"none"}\n'
  else
    jq '{enforced_repositories}' "${GH_IMMUTABLE_STATE}"
  fi
}

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
repos/atrinik/*/actions/permissions/workflow\|*)
  printf '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}\n'
  ;;
"orgs/atrinik/actions/permissions/selected-actions|")
  cat "${GH_SELECTED_ACTIONS_POLICY}"
  ;;
"orgs/atrinik/actions/permissions|")
  printf '{"enabled_repositories":"all","allowed_actions":"selected","sha_pinning_required":false}\n'
  ;;
"orgs/atrinik|")
  if [[ ${GH_ORGANIZATION_SCENARIO:-converged} == drifted ]]; then
    jq -n '{
      plan: {name: "team"},
      description: "",
      blog: "https://atrinik.org",
      default_repository_permission: "none",
      members_can_create_repositories: false,
      members_can_create_public_repositories: false,
      members_can_create_private_repositories: false,
      members_can_create_teams: false
    }'
  else
    jq -n '{
      plan: {name: "team"},
      description: "A cooperative, open-source fantasy world founded by Zoey Seraphina Rose (https://zoeysr.com). Playable in Classic and rebuilding for the future.",
      blog: "https://atrinik.org",
      default_repository_permission: "none",
      members_can_create_repositories: false,
      members_can_create_public_repositories: false,
      members_can_create_private_repositories: false,
      members_can_create_teams: false
    }'
  fi
  ;;
"orgs/atrinik/repos?per_page=100&type=all|"*)
  printf 'classic\t%s\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n' \
    "${GH_CLASSIC_REPOSITORY_ID:-1327289971}"
  printf 'content\t101\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n'
  if [[ ${GH_CRATE_IMMUTABLE_INVENTORY:-false} == true ]]; then
    printf 'metaserver-worker\t1324297032\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n'
    printf 'protocol\t%s\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n' "${GH_PROTOCOL_REPOSITORY_ID:-1327106950}"
    printf 'content-toolkit\t1327107043\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n'
  fi
  printf 'classic-ghsa-8533-3vg8-r287\t999\ttrue\tprivate\tfalse\tfalse\tfalse\tfalse\tfalse\n'
  ;;
"orgs/atrinik/settings/immutable-releases|"*)
  immutable_release_snapshot
  ;;
"orgs/atrinik/settings/immutable-releases/repositories?per_page=100|"*)
  jq '
    {
      total_count: (.selected_repository_ids | length),
      repositories: [.selected_repository_ids[]? | {id: .}]
    }
  ' "${GH_IMMUTABLE_STATE}" | jq -r "${jq_filter}"
  ;;
"repos/atrinik/metaserver-worker/immutable-releases|"* | "repos/atrinik/protocol/immutable-releases|"* | "repos/atrinik/content-toolkit/immutable-releases|"*)
  case ${endpoint} in
  */metaserver-worker/*) repository_id=1324297032 ;;
  */protocol/*) repository_id=1327106950 ;;
  */content-toolkit/*) repository_id=1327107043 ;;
  esac
  if [[ ${GH_CRATE_IMMUTABLE_VERIFY_FAILURE:-false} == true && ${repository_id} == 1327107043 ]]; then
    printf '{"enabled":false,"enforced_by_owner":false}\n'
  elif jq -e --argjson id "${repository_id}" '.enforced_repositories == "selected" and (.selected_repository_ids | index($id)) != null' "${GH_IMMUTABLE_STATE}" >/dev/null; then
    printf '{"enabled":true,"enforced_by_owner":true}\n'
  else
    printf '{"enabled":false,"enforced_by_owner":false}\n'
  fi
  ;;
"repos/atrinik/metaserver-worker/code-security-configuration|"* | "repos/atrinik/protocol/code-security-configuration|"* | "repos/atrinik/content-toolkit/code-security-configuration|"*)
  printf '{"status":"enforced","configuration":{"id":265376}}\n'
  ;;
"repos/atrinik/metaserver-worker/code-scanning/default-setup|"*)
  printf '{"state":"configured","query_suite":"default","languages":["javascript-typescript","python","actions"]}\n'
  ;;
"repos/atrinik/protocol/code-scanning/default-setup|"* | "repos/atrinik/content-toolkit/code-scanning/default-setup|"*)
  printf '{"state":"configured","query_suite":"default","languages":["rust"]}\n'
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
repos/atrinik/protocol\| | repos/atrinik/content-toolkit\|)
  repository=${endpoint#repos/atrinik/}
  jq -cn --arg repository "${repository}" --argjson id "$(crate_repository_id "${repository}")" \
    '{id: $id, full_name: ("atrinik/" + $repository), archived: false, default_branch: "main"}'
  ;;
repos/atrinik/protocol/branches/main\| | repos/atrinik/content-toolkit/branches/main\|)
  printf '{"name":"main","protected":true,"commit":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
  ;;
repos/atrinik/metaserver-worker/git/ref/heads/main\|)
  if [[ ${GH_METASERVER_SOURCE_SCENARIO:-valid} == late-main-drift ]] &&
    jq -se 'any(.[]; .endpoint == "repos/atrinik/protocol/git/ref/heads/main")' "${GH_API_LOG}" >/dev/null; then
    printf '%s\n' '{"ref":"refs/heads/main","object":{"type":"commit","sha":"2222222222222222222222222222222222222222"}}'
    exit 0
  fi
  printf '%s\n' '{"ref":"refs/heads/main","object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}'
  ;;
repos/atrinik/metaserver-worker/contents/.releaserc.json*\|)
  if [[ ${GH_METASERVER_SOURCE_SCENARIO:-valid} == partial-producer ]]; then
    source='{"plugins":[["@semantic-release/github",{"draftRelease":false}]]}'
  else
    source='{"plugins":[["@semantic-release/github",{"draftRelease":true}],"./scripts/release/publish-complete-release.cjs"]}'
  fi
  encoded=$(printf '%s' "${source}" | base64 -w 0)
  jq -n --arg content "${encoded}" '{type:"file",encoding:"base64",content:$content}'
  ;;
repos/atrinik/metaserver-worker/contents/scripts/release/publish-complete-release.*\|)
  jq -n '{type:"file",encoding:"base64",size:1,content:"eA=="}'
  ;;
repos/atrinik/metaserver-worker/actions/workflows/check.yml/runs*\|)
  conclusion=success
  if [[ ${GH_METASERVER_SOURCE_SCENARIO:-valid} == failed-source-check ]]; then conclusion=failure; fi
  jq -n --arg conclusion "${conclusion}" '{workflow_runs:[{
    head_sha:"1111111111111111111111111111111111111111",head_branch:"main",event:"push",
    head_repository:{full_name:"atrinik/metaserver-worker"},status:"completed",conclusion:$conclusion
  }]}'
  ;;
repos/atrinik/protocol/git/ref/heads/main\| | repos/atrinik/content-toolkit/git/ref/heads/main\|)
  printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
  ;;
repos/atrinik/*/contents/.github/workflows/publish-crate.yml*\|)
  repository=${endpoint#repos/atrinik/}
  repository=${repository%%/*}
  crate_workflow_content "${repository}" publish-crate.yml | base64 | tr -d '\n' | \
    jq -R '{type: "file", encoding: "base64", content: .}'
  ;;
repos/atrinik/*/contents/.github/workflows/release.yml*\|)
  repository=${endpoint#repos/atrinik/}
  repository=${repository%%/*}
  crate_workflow_content "${repository}" release.yml | base64 | tr -d '\n' | \
    jq -R '{type: "file", encoding: "base64", content: .}'
  ;;
repos/atrinik/*/environments/crates-io-release\|)
  crate_environment
  ;;
repos/atrinik/*/environments/crates-io-release/deployment-branch-policies\?per_page=100\&page=1\|)
  printf '{"total_count":1,"branch_policies":[{"name":"main","type":"branch"}]}\n'
  ;;
repos/atrinik/*/environments/crates-io-release/secrets\?per_page=100\&page=1\|)
  printf '{"total_count":0,"secrets":[]}\n'
  ;;
repos/atrinik/*/environments/crates-io-release/variables\?per_page=100\&page=1\|)
  printf '{"total_count":0,"variables":[]}\n'
  ;;
"orgs/atrinik/rulesets|"*)
  if [[ ${GH_ADVISORY_RULESETS_PRESENT:-false} == true ]]; then
    printf '%s\n' '[{"id":900,"name":"05 - Maintenance branch - content - retired"},{"id":901,"name":"01 - Default branch linear history - classic"},{"id":902,"name":"02 - Changes through pull requests - classic"},{"id":903,"name":"01 - Default branch integrity - classic"}]'
  else
    printf '[{"id":900,"name":"05 - Maintenance branch - content - retired"}]\n'
  fi
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
    printf '{"state":"configured","query_suite":"default","languages":["c-cpp"]}\n'
  else
    printf '{"state":"not-configured","query_suite":"default","languages":null}\n'
  fi
  ;;
"repos/atrinik/content/code-scanning/default-setup|"*)
  if [[ ${security_scenario} == drifted ||
    ${security_scenario} == create ]]; then
    printf '{"state":"not-configured","languages":null}\n'
  else
    printf '{"state":"configured","query_suite":"default","languages":["python"]}\n'
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
  if [[ ${GH_ADVISORY_RULESETS_PRESENT:-false} == true ]]; then
    printf '%s\n' '[{"id":900,"name":"05 - Maintenance branch - content - retired"},{"id":901,"name":"01 - Default branch linear history - classic"},{"id":902,"name":"02 - Changes through pull requests - classic"},{"id":903,"name":"01 - Default branch integrity - classic"}]'
  elif [[ ${GH_SHARED_RULESETS_PRESENT:-false} == true &&
    ${endpoint} == repos/atrinik/classic/* ]]; then
    printf '%s\n' '[{"id":904,"name":"01 - Default branch integrity"},{"id":905,"name":"01 - Default branch linear history"},{"id":906,"name":"02 - Changes through pull requests"}]'
  else
    printf '[{"id":900,"name":"05 - Maintenance branch - content - retired"}]\n'
  fi
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

assert_default_branch_policy_payloads() {
  local log=$1
  local endpoint=$2
  local organization_scope=$3

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --argjson organization_scope "${organization_scope}" '
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == "01 - Default branch linear history"
        )
      ] as $linear |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == "01 - Default branch integrity"
        )
      ] as $integrity |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == "02 - Changes through pull requests"
        )
      ] as $pull_request |
      ($linear | length) == 1 and
      ($integrity | length) == 1 and
      ($pull_request | length) == 1 and
      $linear[0].key < $integrity[0].key and
      ($linear[0].value.payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "pull_request"
      }]) and
      ($linear[0].value.payload.rules == [{
        type: "required_linear_history"
      }]) and
      ($integrity[0].value.payload.bypass_actors == []) and
      ([$integrity[0].value.payload.rules[].type] == [
        "deletion",
        "non_fast_forward"
      ]) and
      ($pull_request[0].value.payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "pull_request"
      }]) and
      ([$pull_request[0].value.payload.rules[].type] == ["pull_request"]) and
      (
        ($linear[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($integrity[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($pull_request[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($organization_scope | not) or
        (
          $linear[0].value.payload.conditions.repository_name.include ==
            ["~ALL"] and
          $linear[0].value.payload.conditions.repository_name.exclude ==
            ["classic"] and
          $integrity[0].value.payload.conditions.repository_name.include ==
            ["~ALL"] and
          $integrity[0].value.payload.conditions.repository_name.exclude ==
            ["classic"] and
          (
            $pull_request[0].value.payload.conditions.repository_name.include |
            index("classic")
          ) == null
        )
      )
    ' "${log}" >/dev/null
}

assert_classic_advisory_bypass_payloads() {
  local log=$1
  local endpoint=$2
  local organization_scope=$3

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --argjson organization_scope "${organization_scope}" '
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name ==
            "01 - Default branch linear history - classic"
        )
      ] as $linear |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name ==
            "02 - Changes through pull requests - classic"
        )
      ] as $pull_request |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name ==
            "01 - Default branch integrity - classic"
        )
      ] as $integrity |
      ($linear | length) == 1 and
      ($pull_request | length) == 1 and
      ($integrity | length) == 1 and
      ($integrity[0].value.payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "always"
      }]) and
      ([$integrity[0].value.payload.rules[].type] == [
        "deletion",
        "non_fast_forward"
      ]) and
      ($linear[0].value.payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "always"
      }]) and
      ($linear[0].value.payload.rules == [{
        type: "required_linear_history"
      }]) and
      ($pull_request[0].value.payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "always"
      }]) and
      ([$pull_request[0].value.payload.rules[].type] == ["pull_request"]) and
      (
        ($integrity[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($linear[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        ($pull_request[0].value.payload.conditions | has("repository_name")) ==
          $organization_scope
      ) and
      (
        if $organization_scope then
          $integrity[0].value.payload.conditions.repository_name.include ==
            ["classic"] and
          $integrity[0].value.payload.conditions.repository_name.exclude ==
            [] and
          $linear[0].value.payload.conditions.repository_name.include ==
            ["classic"] and
          $linear[0].value.payload.conditions.repository_name.exclude == [] and
          $pull_request[0].value.payload.conditions.repository_name.include ==
            ["classic"] and
          $pull_request[0].value.payload.conditions.repository_name.exclude ==
            [] and
          $integrity[0].key < ([
            to_entries[] |
            select(
              .value.method == "POST" and
              .value.endpoint == $endpoint and
              .value.payload.name == "01 - Default branch integrity"
            ) |
            .key
          ][0]) and
          $linear[0].key < ([
            to_entries[] |
            select(
              .value.method == "POST" and
              .value.endpoint == $endpoint and
              .value.payload.name == "01 - Default branch linear history"
            ) |
            .key
          ][0]) and
          $pull_request[0].key < ([
            to_entries[] |
            select(
              .value.method == "POST" and
              .value.endpoint == $endpoint and
              .value.payload.name == "02 - Changes through pull requests"
            ) |
            .key
          ][0])
        else true end
      )
    ' "${log}" >/dev/null
}

assert_advisory_window_closed() {
  local log=$1
  local endpoint=$2
  local delete_prefix=$3
  local organization_scope=$4
  local ci_name="03 - Required CI"

  if [[ ${organization_scope} == true ]]; then
    ci_name="03 - Required CI - classic"
  fi

  jq -s -e \
    --arg endpoint "${endpoint}" \
    --arg delete_prefix "${delete_prefix}" \
    --arg ci_name "${ci_name}" \
    --argjson organization_scope "${organization_scope}" '
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == "01 - Default branch linear history"
        )
      ] as $linear |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == "02 - Changes through pull requests"
        )
      ] as $pull_request |
      [
        to_entries[] |
        select(
          .value.method == "POST" and
          .value.endpoint == $endpoint and
          .value.payload.name == $ci_name
        )
      ] as $ci |
      [
        to_entries[] |
        select(
          .value.method == "DELETE" and
          (
            .value.endpoint == "\($delete_prefix)/901" or
            .value.endpoint == "\($delete_prefix)/902" or
            .value.endpoint == "\($delete_prefix)/903"
          )
        )
      ] as $deletes |
      ($linear | length) == 1 and
      ($pull_request | length) == 1 and
      ($ci | length) == 1 and
      ($deletes | length) == 3 and
      ($linear[0].value.payload.bypass_actors[0].bypass_mode ==
        "pull_request") and
      ($pull_request[0].value.payload.bypass_actors[0].bypass_mode ==
        "pull_request") and
      ($ci[0].value.payload.bypass_actors[0].bypass_mode == "pull_request") and
      (
        if $organization_scope then
          $linear[0].value.payload.conditions.repository_name.exclude == [] and
          (
            $pull_request[0].value.payload.conditions.repository_name.include |
            index("classic")
          ) != null
        else
          ($linear[0].value.payload.conditions | has("repository_name") | not) and
          (
            $pull_request[0].value.payload.conditions |
            has("repository_name") |
            not
          )
        end
      ) and
      all(
        $deletes[];
        .key > $linear[0].key and
        .key > $pull_request[0].key and
        .key > $ci[0].key
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
      ($matches[0].payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "pull_request"
      }]) and
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
      ($matches[0].payload.bypass_actors == [{
        actor_id: 1,
        actor_type: "OrganizationAdmin",
        bypass_mode: "always"
      }]) and
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

advisory_active_root=${temporary}/advisory-window-active
mkdir -p "${advisory_active_root}/bin"
cp "${root}/bin/publish" "${root}/bin/validate" "${root}/bin/security-readiness" \
  "${advisory_active_root}/bin/"
cp -R "${root}/lib" "${advisory_active_root}/lib"
cp -R "${root}/config" "${advisory_active_root}/config"
cp -R "${root}/community-health" \
  "${advisory_active_root}/community-health"
mkdir -p "${advisory_active_root}/.github"
cp -R "${root}/.github/workflows" "${advisory_active_root}/.github/workflows"
jq '.repositories = ["classic"]' \
  "${root}/config/advisory-merge-windows.json" \
  >"${advisory_active_root}/config/advisory-merge-windows.json"
jq '.maintenance_branches = [{
  repository: "content",
  branch: "1.x",
  required_ci: ["Content validation", "Conventional PR title"]
}]' "${root}/config/repositories.json" \
  >"${advisory_active_root}/config/repositories.json"
jq '.retirements = []' "${root}/config/retired-maintenance-branches.json" \
  >"${advisory_active_root}/config/retired-maintenance-branches.json"

organization_log=${temporary}/organization.jsonl
organization_immutable_state=${temporary}/organization-immutable.json
printf '{"enforced_repositories":"none"}\n' \
  >"${organization_immutable_state}"
GH_API_LOG=${organization_log} \
  GH_IMMUTABLE_STATE=${organization_immutable_state} \
  GH_ORGANIZATION_SCENARIO=drifted \
  GH_SECURITY_SCENARIO=drifted \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${advisory_active_root}/bin/publish" --apply \
  >"${temporary}/organization.txt"
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
jq -s -e '
  [
    .[] |
    select(.method == "PATCH" and .endpoint == "orgs/atrinik") |
    .payload
  ] == [{
    description: "A cooperative, open-source fantasy world founded by Zoey Seraphina Rose (https://zoeysr.com). Playable in Classic and rebuilding for the future.",
    blog: "https://atrinik.org",
    default_repository_permission: "none",
    members_can_create_repositories: false,
    members_can_create_public_repositories: false,
    members_can_create_private_repositories: false
  }]
' "${organization_log}" >/dev/null
assert_maintenance_payload \
  "${organization_log}" "orgs/atrinik/rulesets" true
assert_default_branch_policy_payloads \
  "${organization_log}" "orgs/atrinik/rulesets" true
assert_classic_advisory_bypass_payloads \
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
protocol	Protocol validation
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
jq -s -e '
  all(
    .[];
    .method != "PATCH" or .endpoint != "orgs/atrinik"
  )
' "${idempotent_log}" >/dev/null
[[ ! -e ${enablement_event} ]]
grep -F \
  'KEEP /orgs/atrinik metadata and repository defaults' \
  "${idempotent_output}" >/dev/null
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
cp "${root}/bin/publish" "${root}/bin/validate" "${root}/bin/security-readiness" "${rollback_root}/bin/"
cp -R "${root}/lib" "${rollback_root}/lib"
cp -R "${root}/config" "${rollback_root}/config"
cp -R "${root}/community-health" "${rollback_root}/community-health"
mkdir -p "${rollback_root}/.github"
cp -R "${root}/.github/workflows" "${rollback_root}/.github/workflows"
jq '.repositories = [] | .required_partitions = {}' \
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
  GH_SHARED_RULESETS_PRESENT=true \
  GH_IMMUTABLE_STATE=${repository_immutable_state} \
  GH_SECURITY_SCENARIO=drifted \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${advisory_active_root}/bin/publish" --apply >/dev/null
assert_maintenance_payload \
  "${repository_log}" "repos/atrinik/content/rulesets" false
assert_default_branch_policy_payloads \
  "${repository_log}" "repos/atrinik/content/rulesets" false
assert_classic_advisory_bypass_payloads \
  "${repository_log}" "repos/atrinik/classic/rulesets" false
assert_classic_required_ci_payload \
  "${repository_log}" "repos/atrinik/classic/rulesets" false
jq -s -e '
  [
    .[] |
    select(
      .method == "DELETE" and
      (
        .endpoint == "repos/atrinik/classic/rulesets/904" or
        .endpoint == "repos/atrinik/classic/rulesets/905" or
        .endpoint == "repos/atrinik/classic/rulesets/906"
      )
    )
  ] | length == 3
' "${repository_log}" >/dev/null
while IFS=$'\t' read -r repository validation_context; do
  assert_replacement_required_ci_payload \
    "${repository_log}" "repos/atrinik/${repository}/rulesets" false \
    "${repository}" "${validation_context}"
done <<'EOF'
client	Client validation
content-toolkit	Content toolkit validation
protocol	Protocol validation
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

advisory_rollback_root=${temporary}/advisory-window-rollback
mkdir -p "${advisory_rollback_root}/bin"
cp "${root}/bin/publish" "${root}/bin/validate" "${root}/bin/security-readiness" \
  "${advisory_rollback_root}/bin/"
cp -R "${root}/lib" "${advisory_rollback_root}/lib"
cp -R "${root}/config" "${advisory_rollback_root}/config"
cp -R "${root}/community-health" \
  "${advisory_rollback_root}/community-health"
mkdir -p "${advisory_rollback_root}/.github"
cp -R "${root}/.github/workflows" \
  "${advisory_rollback_root}/.github/workflows"
jq '.repositories = []' \
  "${root}/config/advisory-merge-windows.json" \
  >"${advisory_rollback_root}/config/advisory-merge-windows.json"

advisory_organization_log=${temporary}/advisory-organization-rollback.jsonl
advisory_organization_state=${temporary}/advisory-organization-state.json
printf '%s\n' \
  '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' \
  >"${advisory_organization_state}"
GH_ADVISORY_RULESETS_PRESENT=true \
  GH_API_LOG=${advisory_organization_log} \
  GH_IMMUTABLE_STATE=${advisory_organization_state} \
  GH_SECURITY_SCENARIO=converged \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${advisory_rollback_root}/bin/publish" --apply >/dev/null
assert_advisory_window_closed \
  "${advisory_organization_log}" "orgs/atrinik/rulesets" \
  "orgs/atrinik/rulesets" true

advisory_repository_log=${temporary}/advisory-repository-rollback.jsonl
advisory_repository_state=${temporary}/advisory-repository-state.json
printf '%s\n' \
  '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' \
  >"${advisory_repository_state}"
GH_ADVISORY_RULESETS_PRESENT=true \
  GH_API_LOG=${advisory_repository_log} \
  GH_IMMUTABLE_STATE=${advisory_repository_state} \
  GH_SECURITY_SCENARIO=converged \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=repository \
  "${advisory_rollback_root}/bin/publish" --apply >/dev/null
assert_advisory_window_closed \
  "${advisory_repository_log}" "repos/atrinik/classic/rulesets" \
  "repos/atrinik/classic/rulesets" false

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
  GH_ORGANIZATION_SCENARIO=drifted \
  GH_SECURITY_SCENARIO=drifted \
  PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization \
  "${root}/bin/publish" >"${plan_output}"
grep -F \
  'DRIFT /orgs/atrinik description live="" desired="A cooperative, open-source fantasy world founded by Zoey Seraphina Rose (https://zoeysr.com). Playable in Classic and rebuilding for the future."' \
  "${plan_output}" >/dev/null
grep -F \
  'PLAN PATCH /orgs/atrinik <= config/organization.json' \
  "${plan_output}" >/dev/null
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
grep -F \
  'MANUAL cloudflare-workers-and-pages installation 152311798 selected repositories: atrinik/website, atrinik/metaserver-worker; publisher does not apply' \
  "${plan_output}" >/dev/null
jq -e '. == {enforced_repositories: "none"}' \
  "${plan_immutable_state}" >/dev/null
jq -s -e '
  all(
    .[];
    .method == "GET"
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

# A newly selected producer must qualify its exact workflow and environment
# before the publisher's first mutation. This fixture deliberately provides no
# source release, registry, or attestation endpoint: setup qualification is
# about reviewed protected-main configuration only.
crate_state=${temporary}/crate-immutable-state.json
crate_log=${temporary}/crate-immutable-log.jsonl
printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
GH_API_LOG=${crate_log} GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_SECURITY_SCENARIO=converged \
  GH_CRATE_FIXTURE_ROOT=${source_root} PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
  "${source_root}/bin/publish" --apply >"${temporary}/crate-immutable-apply.out"
jq -e '. == {enforced_repositories:"selected",selected_repository_ids:[1324297032,1327106950,1327107043,1327289971]}' "${crate_state}" >/dev/null
jq -s -e '
  . as $calls |
  ([ $calls | to_entries[] |
     select(.value.method != "GET") | .key ] | first) as $first_mutation |
  all(
    ["protocol", "content-toolkit"][] as $repository |
    ([ $calls | to_entries[] |
       select(.value.endpoint == ("repos/atrinik/" + $repository + "/git/ref/heads/main")) |
       .key ] | last) < $first_mutation
  ) and
  all(.[]; (.endpoint | test("/(releases|attestations|actions/runs)(/|$)") | not))
' "${crate_log}" >/dev/null
for repository in classic protocol content-toolkit; do
  jq -se --arg endpoint "repos/atrinik/${repository}/immutable-releases" \
    'any(.[]; .method == "GET" and .endpoint == $endpoint)' "${crate_log}" >/dev/null
done

crate_setup_root() {
  local destination=$1

  mkdir -p "${destination}/bin" "${destination}/lib" "${destination}/tests"
  cp "${source_root}/bin/publish" "${source_root}/bin/validate" \
    "${source_root}/bin/verify-manual-settings" "${source_root}/bin/security-readiness" "${destination}/bin/"
  cp "${source_root}/lib/verify_crate_workflow.py" "${source_root}/lib/security_readiness.py" \
    "${destination}/lib/"
  cp -R "${source_root}/config" "${source_root}/community-health" \
    "${source_root}/.github" "${destination}/"
  cp -R "${source_root}/tests/fixtures" "${destination}/tests/"
}

assert_setup_failed_before_mutation() {
  local log=$1

  jq -s -e 'all(.[]; .method == "GET")' "${log}" >/dev/null
}

# Metaserver draft-first and exact-main check failures stop before any write.
for scenario in partial-producer failed-source-check late-main-drift; do
  scenario_log=${temporary}/metaserver-${scenario}.jsonl
  printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
  if GH_API_LOG=${scenario_log} GH_IMMUTABLE_STATE=${crate_state} \
    GH_CRATE_IMMUTABLE_INVENTORY=true GH_METASERVER_SOURCE_SCENARIO=${scenario} \
    GH_CRATE_FIXTURE_ROOT=${source_root} PATH="${temporary}/bin:${PATH}" \
    ATRINIK_POLICY_SCOPE=organization "${source_root}/bin/publish" --apply \
    >"${temporary}/metaserver-${scenario}.out" 2>&1; then
    echo "error: unqualified metaserver producer did not block initial selection" >&2
    exit 1
  fi
  assert_setup_failed_before_mutation "${scenario_log}"
done

# A pending or absent manual record blocks a newly selected producer before
# immutable policy or any unrelated governance setting can mutate.
pending_setup_root=${temporary}/crate-pending-setup
crate_setup_root "${pending_setup_root}"
jq '(.crates_io_trusted_publishing[] | select(.repository == "atrinik/protocol") |
  .source_state) = "pending-reviewed-workflow" |
  (.crates_io_trusted_publishing[] | select(.repository == "atrinik/protocol") |
    .environment_state) = "pending"' \
  "${pending_setup_root}/config/manual-settings.json" >"${temporary}/pending-manual.json"
mv "${temporary}/pending-manual.json" "${pending_setup_root}/config/manual-settings.json"
pending_setup_log=${temporary}/crate-pending-setup.jsonl
printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
if GH_API_LOG=${pending_setup_log} GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_FIXTURE_ROOT=${source_root} \
  PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
  "${pending_setup_root}/bin/publish" --apply >"${temporary}/crate-pending-setup.out" 2>&1; then
  echo "error: pending crate setup did not block immutable selection" >&2
  exit 1
fi
grep -F 'initial immutable selection requires observed qualified source/environment for atrinik/protocol' \
  "${temporary}/crate-pending-setup.out" >/dev/null
assert_setup_failed_before_mutation "${pending_setup_log}"

missing_setup_root=${temporary}/crate-missing-setup
crate_setup_root "${missing_setup_root}"
jq 'del(.crates_io_trusted_publishing[] | select(.repository == "atrinik/protocol"))' \
  "${missing_setup_root}/config/manual-settings.json" >"${temporary}/missing-manual.json"
mv "${temporary}/missing-manual.json" "${missing_setup_root}/config/manual-settings.json"
missing_setup_log=${temporary}/crate-missing-setup.jsonl
printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
if GH_API_LOG=${missing_setup_log} GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_FIXTURE_ROOT=${source_root} \
  PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
  "${missing_setup_root}/bin/publish" --apply >"${temporary}/crate-missing-setup.out" 2>&1; then
  echo "error: missing crate setup record did not block immutable selection" >&2
  exit 1
fi
assert_setup_failed_before_mutation "${missing_setup_log}"

# The scoped verifier must reject malformed protected-main workflow bytes and
# environment drift before any mutation.
for scenario in malformed-workflow environment-drift; do
  scenario_log=${temporary}/crate-${scenario}.jsonl
  printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
  if GH_API_LOG=${scenario_log} GH_IMMUTABLE_STATE=${crate_state} \
    GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_SETUP_SCENARIO=${scenario} \
    GH_CRATE_FIXTURE_ROOT=${source_root} PATH="${temporary}/bin:${PATH}" \
    ATRINIK_POLICY_SCOPE=organization "${source_root}/bin/publish" --apply \
    >"${temporary}/crate-${scenario}.out" 2>&1; then
    echo "error: ${scenario} did not block immutable selection" >&2
    exit 1
  fi
  assert_setup_failed_before_mutation "${scenario_log}"
done

# The immutable snapshot is a fence: a changed live policy after successful
# qualification prevents the first convergence mutation.
snapshot_drift_log=${temporary}/crate-snapshot-drift.jsonl
printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1327289971]}' >"${crate_state}"
if GH_API_LOG=${snapshot_drift_log} GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_SNAPSHOT_DRIFT=true \
  GH_CRATE_FIXTURE_ROOT=${source_root} PATH="${temporary}/bin:${PATH}" \
  ATRINIK_POLICY_SCOPE=organization "${source_root}/bin/publish" --apply \
  >"${temporary}/crate-snapshot-drift.out" 2>&1; then
  echo "error: immutable snapshot drift did not block convergence" >&2
  exit 1
fi
grep -F 'immutable-release policy changed during initial qualification' \
  "${temporary}/crate-snapshot-drift.out" >/dev/null
assert_setup_failed_before_mutation "${snapshot_drift_log}"

# Existing selections do not requalify their pending records, and an all-mode
# snapshot does not cause avoidable source/environment verification.
for mode in selected all; do
  mode_log=${temporary}/crate-${mode}-already-selected.jsonl
  if [[ ${mode} == selected ]]; then
    printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[1324297032,1327106950,1327107043,1327289971]}' >"${crate_state}"
  else
    printf '%s\n' '{"enforced_repositories":"all"}' >"${crate_state}"
  fi
  GH_API_LOG=${mode_log} GH_IMMUTABLE_STATE=${crate_state} \
    GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_FIXTURE_ROOT=${source_root} \
    PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
    "${pending_setup_root}/bin/publish" --apply >"${temporary}/crate-${mode}-already-selected.out"
  jq -s -e 'all(.[];
    (.endpoint | test("/contents/\\.github/workflows/(publish-crate|release)\\.yml") | not) and
    (.endpoint | contains("/environments/crates-io-release") | not))' "${mode_log}" >/dev/null
done

crate_failure_log=${temporary}/crate-immutable-failure.jsonl
printf '%s\n' '{"enforced_repositories":"selected","selected_repository_ids":[101,1327289971]}' >"${crate_state}"
if GH_API_LOG=${crate_failure_log} GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_CRATE_IMMUTABLE_VERIFY_FAILURE=true \
  GH_SECURITY_SCENARIO=converged PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
  "${source_root}/bin/publish" --apply >"${temporary}/crate-immutable-failure.out" 2>&1; then
  echo "error: crate-family immutable readback drift did not fail" >&2
  exit 1
fi
jq -e '. == {enforced_repositories:"selected",selected_repository_ids:[101,1327289971]}' "${crate_state}" >/dev/null
if GH_API_LOG=${temporary}/crate-identity-drift.jsonl GH_IMMUTABLE_STATE=${crate_state} \
  GH_CRATE_IMMUTABLE_INVENTORY=true GH_PROTOCOL_REPOSITORY_ID=999 \
  GH_SECURITY_SCENARIO=converged PATH="${temporary}/bin:${PATH}" ATRINIK_POLICY_SCOPE=organization \
  "${source_root}/bin/publish" --apply >"${temporary}/crate-identity-drift.out" 2>&1; then
  echo "error: crate-family repository identity drift did not fail" >&2
  exit 1
fi
jq -se 'all(.[]; .method == "GET")' "${temporary}/crate-identity-drift.jsonl" >/dev/null

echo "Publisher policy-scope tests passed."
