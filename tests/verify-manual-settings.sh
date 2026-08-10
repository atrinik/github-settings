#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir "${temporary}/bin"

cat >"${temporary}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

[[ ${1:-} == api ]] || exit 1
shift
endpoint=
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  -f | -F)
    shift 2
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
printf '%s\n' "${endpoint}" >>"${FAKE_GH_LOG}"

if [[ ${FAKE_GH_SCENARIO} == api-failure ]]; then
  echo "gh: repository administration denied" >&2
  exit 41
fi
case ${endpoint} in
graphql)
  if [[ ${FAKE_GH_SCENARIO} == malformed-pins ]]; then
    jq -n '{data: {organization: {login: "atrinik", pinnedItems: {nodes: []}}}}'
  elif [[ ${FAKE_GH_SCENARIO} == pin-drift ]]; then
    jq -n '{data: {organization: {
      login: "atrinik",
      pinnedItems: {
        totalCount: 2,
        nodes: [
          {name: "atrinik", databaseId: 15810595, nameWithOwner: "atrinik/atrinik", isArchived: false, visibility: "PUBLIC"},
          {name: "classic", databaseId: 1327289971, nameWithOwner: "atrinik/classic", isArchived: false, visibility: "PUBLIC"}
        ]
      }
    }}}'
  else
    jq -n '{data: {organization: {
      login: "atrinik",
      pinnedItems: {
        totalCount: 6,
        nodes: [
          {name: "classic", databaseId: 1327289971, nameWithOwner: "atrinik/classic", isArchived: false, visibility: "PUBLIC"},
          {name: "atrinik", databaseId: 15810595, nameWithOwner: "atrinik/atrinik", isArchived: false, visibility: "PUBLIC"},
          {name: "website", databaseId: 1327107093, nameWithOwner: "atrinik/website", isArchived: false, visibility: "PUBLIC"},
          {name: "content", databaseId: 1325219730, nameWithOwner: "atrinik/content", isArchived: false, visibility: "PUBLIC"},
          {name: "protocol", databaseId: 1327106950, nameWithOwner: "atrinik/protocol", isArchived: false, visibility: "PUBLIC"},
          {name: "playtester", databaseId: 1329284051, nameWithOwner: "atrinik/playtester", isArchived: false, visibility: "PUBLIC"}
        ]
      }
    }}}'
  fi
  ;;
repos/atrinik/github-settings)
  if [[ ${FAKE_GH_SCENARIO} == identity-drift ]]; then
    jq -n '{
      id: 1,
      full_name: "atrinik/github-settings",
      archived: false,
      default_branch: "main"
    }'
  else
    jq -n '{
      id: 1324382941,
      full_name: "atrinik/github-settings",
      archived: false,
      default_branch: "main"
    }'
  fi
  ;;
repos/atrinik/classic)
  if [[ ${FAKE_GH_SCENARIO} == environment-identity-drift ]]; then
    jq -n '{
      id: 1,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-repository-name-drift ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/renamed-classic",
      archived: false,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-archived ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: true,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-default-branch-drift ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "trunk"
    }'
  else
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "main"
    }'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing ]]; then
    jq -n '{total_count: 0, secrets: []}'
  elif [[ ${FAKE_GH_SCENARIO} == page2 || \
    ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    jq -n '{
      total_count: 101,
      secrets: [range(0; 100) | {
        name: ("UNRELATED_" + tostring),
        created_at: "2026-08-01T00:00:00Z",
        updated_at: "2026-08-01T00:00:00Z"
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == shared-repository ]]; then
    jq -n '{
      total_count: 2,
      secrets: [
        {
          name: "ATRINIK_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        },
        {
          name: "SECOND_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        }
      ]
    }'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "ATRINIK_SETTINGS_TOKEN",
        created_at: "2026-08-10T02:13:48Z",
        updated_at: "2026-08-10T02:13:48Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    echo "gh: second secret page failed" >&2
    exit 42
  fi
  [[ ${FAKE_GH_SCENARIO} == page2 ]]
  jq -n '{
    total_count: 101,
    secrets: [{
      name: "ATRINIK_SETTINGS_TOKEN",
      created_at: "2026-08-10T02:13:48Z",
      updated_at: "2026-08-10T02:13:48Z"
    }]
  }'
  ;;
repos/atrinik/classic/environments/discord-release)
  if [[ ${FAKE_GH_SCENARIO} == missing-environment ]]; then
    echo "gh: environment not found" >&2
    exit 43
  elif [[ ${FAKE_GH_SCENARIO} == environment-name-drift ]]; then
    jq -n '{
      name: "other-environment",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == branch-mode-drift ]]; then
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: true,
        custom_branch_policies: false
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == extra-reviewer ]]; then
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{
        type: "required_reviewers",
        reviewers: [{type: "User", reviewer: {id: 1, login: "reviewer"}}]
      }, {type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == wait-timer ||
    ${FAKE_GH_SCENARIO} == custom-protection-rule ]]; then
    rule_type=wait_timer
    if [[ ${FAKE_GH_SCENARIO} == custom-protection-rule ]]; then
      rule_type=custom_deployment_protection_rule
    fi
    jq -n --arg rule_type "${rule_type}" '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}, {type: $rule_type}]
    }'
  else
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  fi
  ;;
"repos/atrinik/classic/environments/discord-release/deployment-branch-policies?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == branch-policy-drift ]]; then
    jq -n '{
      total_count: 1,
      branch_policies: [{id: 1, name: "release", type: "branch"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-page2 ||
    ${FAKE_GH_SCENARIO} == environment-page2-failure ]]; then
    jq -n '{
      total_count: 101,
      branch_policies: [range(0; 100) | {
        id: ., name: ("branch-" + tostring), type: "branch"
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == malformed-branch-policy-response ]]; then
    jq -n '{total_count: 1, branch_policy: []}'
  else
    jq -n '{
      total_count: 2,
      branch_policies: [
        {id: 1, name: "main", type: "branch"},
        {id: 2, name: "v*", type: "tag"}
      ]
    }'
  fi
  ;;
"repos/atrinik/classic/environments/discord-release/deployment-branch-policies?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == environment-page2-failure ]]; then
    echo "gh: second environment branch-policy page failed" >&2
    exit 44
  fi
  [[ ${FAKE_GH_SCENARIO} == environment-page2 ]]
  jq -n '{
    total_count: 101,
    branch_policies: [{id: 101, name: "main", type: "branch"}]
  }'
  ;;
"repos/atrinik/classic/environments/discord-release/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing-environment-secret ]]; then
    jq -n '{total_count: 0, secrets: []}'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "DISCORD_APPLICATION_ID",
        created_at: "2026-08-10T00:00:00Z",
        updated_at: "2026-08-10T00:00:00Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/classic/environments/discord-release/variables?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == extra-environment-variable ]]; then
    jq -n '{
      total_count: 1,
      variables: [{name: "UNEXPECTED", created_at: "2026-08-10T00:00:00Z"}]
    }'
  else
    jq -n '{total_count: 0, variables: []}'
  fi
  ;;
*) exit 1 ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

run_verify() {
  local scenario=$1

  PATH="${temporary}/bin:${PATH}" \
    FAKE_GH_LOG="${temporary}/gh.log" \
    FAKE_GH_SCENARIO="${scenario}" \
    GITHUB_ACTIONS=true GH_TOKEN=test-token \
    ATRINIK_VALIDATION_TODAY=2026-08-10 \
    "${root}/bin/verify-manual-settings"
}

: >"${temporary}/gh.log"
output=$(run_verify present)
grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'KEEP atrinik/classic environment discord-release metadata' <<<"${output}"
grep -Fq 'KEEP atrinik organization pins match the exact governed order' <<<"${output}"
grep -Fq 'Manual settings live credential, environment, and organization pin metadata is present.' \
  <<<"${output}"

: >"${temporary}/gh.log"
output=$(run_verify page2)
grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'page=2' "${temporary}/gh.log"

environment_page_root=${temporary}/environment-page
mkdir -p "${environment_page_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" \
  "${environment_page_root}/bin/"
cp -R "${root}/config" "${environment_page_root}/config"
cp -R "${root}/community-health" "${environment_page_root}/community-health"
cp -R "${root}/.github" "${environment_page_root}/.github"
jq '
  .github_actions_environments[0].deployment_branch_policy.patterns =
    ([range(0; 100) | {
      name: ("branch-" + tostring),
      type: "branch"
    }] + [{name: "main", type: "branch"}])
' "${root}/config/manual-settings.json" \
  >"${environment_page_root}/config/manual-settings.json"
: >"${temporary}/gh.log"
output=$(PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" \
  FAKE_GH_SCENARIO=environment-page2 \
  GITHUB_ACTIONS=true GH_TOKEN=test-token \
  ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${environment_page_root}/bin/verify-manual-settings")
grep -Fq 'KEEP atrinik/classic environment discord-release metadata' <<<"${output}"
grep -Fq 'deployment-branch-policies?per_page=100&page=2' "${temporary}/gh.log"

shared_root=${temporary}/shared-repository
mkdir -p "${shared_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" \
  "${shared_root}/bin/"
cp -R "${root}/config" "${shared_root}/config"
cp -R "${root}/community-health" "${shared_root}/community-health"
cp -R "${root}/.github" "${shared_root}/.github"
jq '
  .github_actions_credentials += [
    .github_actions_credentials[0] |
    .secret_name = "SECOND_SETTINGS_TOKEN"
  ]
' "${root}/config/manual-settings.json" \
  >"${shared_root}/config/manual-settings.json"
: >"${temporary}/gh.log"
output=$(PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" \
  FAKE_GH_SCENARIO=shared-repository \
  GITHUB_ACTIONS=true GH_TOKEN=test-token \
  ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${shared_root}/bin/verify-manual-settings")
grep -Fq 'SECOND_SETTINGS_TOKEN' <<<"${output}"
[[ $(grep -Fc 'repos/atrinik/github-settings' "${temporary}/gh.log") == 2 ]]

for scenario in missing identity-drift api-failure page2-failure; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done

for scenario in pin-drift malformed-pins; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'organization pin order or identity drift' \
  "${temporary}/pin-drift.err"
grep -Fq 'invalid organization pin metadata' \
  "${temporary}/malformed-pins.err"
grep -Fq 'MISSING atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  "${temporary}/missing.err"
grep -Fq 'repository identity or active-state drift' \
  "${temporary}/identity-drift.err"
grep -Fq 'gh: repository administration denied' "${temporary}/api-failure.err"
grep -Fq 'read atrinik/github-settings identity' "${temporary}/api-failure.err"
grep -Fq 'gh: second secret page failed' "${temporary}/page2-failure.err"
grep -Fq 'page 2' "${temporary}/page2-failure.err"

environment_failures=(
  missing-environment
  environment-identity-drift
  environment-repository-name-drift
  environment-archived
  environment-default-branch-drift
  environment-name-drift
  branch-mode-drift
  branch-policy-drift
  extra-reviewer
  wait-timer
  custom-protection-rule
  missing-environment-secret
  extra-environment-variable
  malformed-branch-policy-response
  environment-page2-failure
)
for scenario in "${environment_failures[@]}"; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'environment not found' "${temporary}/missing-environment.err"
grep -Fq 'read atrinik/classic environment discord-release' \
  "${temporary}/missing-environment.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-identity-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-repository-name-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-archived.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-default-branch-drift.err"
grep -Fq 'environment metadata is invalid' \
  "${temporary}/environment-name-drift.err"
grep -Fq 'deployment branch mode drift' \
  "${temporary}/branch-mode-drift.err"
grep -Fq 'deployment branch policy drift' \
  "${temporary}/branch-policy-drift.err"
grep -Fq 'required reviewer drift' "${temporary}/extra-reviewer.err"
grep -Fq 'protection rule drift' "${temporary}/wait-timer.err"
grep -Fq 'protection rule drift' "${temporary}/custom-protection-rule.err"
grep -Fq 'environment secret-name drift' \
  "${temporary}/missing-environment-secret.err"
grep -Fq 'environment variable-name drift' \
  "${temporary}/extra-environment-variable.err"
grep -Fq 'returned invalid metadata' \
  "${temporary}/malformed-branch-policy-response.err"
grep -Fq 'second environment branch-policy page failed' \
  "${temporary}/environment-page2-failure.err"
grep -Fq 'page 2' "${temporary}/environment-page2-failure.err"

for failure in api-failure:41 page2-failure:42; do
  scenario=${failure%%:*}
  expected_status=${failure#*:}
  : >"${temporary}/gh.log"
  set +e
  run_verify "${scenario}" \
    >"${temporary}/${scenario}-status.out" \
    2>"${temporary}/${scenario}-status.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
done

: >"${temporary}/gh.log"
set +e
run_verify environment-page2-failure \
  >"${temporary}/environment-page2-failure-status.out" \
  2>"${temporary}/environment-page2-failure-status.err"
status=$?
set -e
if ((status != 44)); then
  echo "error: environment-page2-failure exited ${status}, expected 44" >&2
  exit 1
fi

: >"${temporary}/gh.log"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=present \
  GITHUB_ACTIONS=true GH_TOKEN='' ATRINIK_VALIDATION_TODAY=2026-08-10 \
  "${root}/bin/verify-manual-settings" \
  >"${temporary}/empty.out" 2>"${temporary}/empty.err"; then
  echo "error: manual-settings verifier accepted an empty workflow credential" >&2
  exit 1
fi
grep -Fq 'ATRINIK_SETTINGS_TOKEN is unavailable' "${temporary}/empty.err"
[[ ! -s ${temporary}/gh.log ]]

echo "Manual settings live credential and environment verification tests passed."
