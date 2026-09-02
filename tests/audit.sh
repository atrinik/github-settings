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
jq_filter=
endpoint=
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  --paginate)
    shift
    ;;
  --jq)
    jq_filter=$2
    shift 2
    ;;
  *)
    endpoint=$1
    shift
    ;;
  esac
done

emit() {
  local payload=$1
  if [[ -n ${jq_filter} ]]; then
    jq -r "${jq_filter}" <<<"${payload}"
  else
    printf '%s\n' "${payload}"
  fi
}

config_root=${AUDIT_CONFIG_ROOT:?}
scenario=${GH_TEST_SCENARIO:-pass}

case ${endpoint} in
orgs/atrinik/properties/schema)
  if [[ ${scenario} == schema-drift ]]; then
    jq -n --slurpfile config \
      "${config_root}/config/repository-properties.json" \
      '$config[0].definitions | map(. + {description: "drift"})'
  else
    jq -n --slurpfile config \
      "${config_root}/config/repository-properties.json" \
      '$config[0].definitions'
  fi
  ;;
orgs/atrinik/repos\?*)
  payload=$(jq -n --slurpfile config "${config_root}/config/repository-properties.json" '
    [
      $config[0].repositories |
      to_entries[] |
      {
        name: .key,
        archived: (.value.lifecycle == "archived"),
        private: false,
        visibility: "public",
        disabled: false,
        fork: false,
        has_issues: true,
        has_projects: true,
        has_wiki: true
      }
    ] |
    if $ENV.GH_TEST_SCENARIO == "unmanaged" then
      . + [{
        name: "unmanaged",
        archived: false,
        private: false,
        visibility: "public",
        disabled: false,
        fork: false,
        has_issues: true,
        has_projects: true,
        has_wiki: true
      }]
    elif $ENV.GH_TEST_SCENARIO == "temporary" then
      . + [{
        name: "classic-ghsa-8533-3vg8-r287",
        archived: false,
        private: true,
        visibility: "private",
        disabled: false,
        fork: false,
        has_issues: false,
        has_projects: false,
        has_wiki: false
      }]
    else
      .
    end
  ')
  emit "${payload}"
  ;;
repos/atrinik/*)
  path=${endpoint#repos/atrinik/}
  case ${path} in
  */properties/values)
    repository=${path%/properties/values}
    if [[ ${scenario} == properties-drift && ${repository} == observatory ]]; then
      jq -n '
        [
          {property_name: "component_role", value: ["unclassified"]},
          {property_name: "lifecycle", value: "seed"},
          {property_name: "provider_set", value: ["unclassified"]},
          {property_name: "release_policy", value: "none"}
        ]
      '
    else
      jq -n --slurpfile config "${config_root}/config/repository-properties.json" \
        --arg repository "${repository}" '
        $config[0].repositories[$repository] |
        to_entries |
        map({property_name: .key, value: .value})
      '
    fi
    ;;
  */rulesets\?includes_parents=true)
    repository=${path%/rulesets?includes_parents=true}
    jq -n --slurpfile repositories "${config_root}/config/repositories.json" \
      --arg repository "${repository}" '
      [
        "01 - Default branch integrity",
        "01 - Default branch linear history"
      ] +
      (if ($repositories[0].pull_request_gate | index($repository)) != null then
        ["02 - Changes through pull requests"]
       else [] end) +
      (if ($repositories[0].required_ci | has($repository)) then
        ["03 - Required CI - " + $repository]
       else [] end) +
      (if ($repositories[0].release_tags | index($repository)) != null then
        ["04 - Immutable release tags"]
       else [] end) |
      map({name: .})
    '
    ;;
  *)
    repository=${path}
    allow_merge_commit=false
    if [[ ${scenario} == merge-drift && ${repository} == observatory ]]; then
      allow_merge_commit=true
    fi
    jq -n --slurpfile defaults "${config_root}/config/repository-defaults.json" \
      --arg repository "${repository}" --argjson allow_merge_commit ${allow_merge_commit} '
      {
        id: 1,
        name: $repository,
        archived: false,
        default_branch: $defaults[0].default_branch,
        allow_merge_commit: $allow_merge_commit,
        allow_rebase_merge: $defaults[0].allow_rebase_merge,
        allow_squash_merge: $defaults[0].allow_squash_merge,
        delete_branch_on_merge: $defaults[0].delete_branch_on_merge,
        squash_merge_commit_title: $defaults[0].squash_merge_commit_title,
        squash_merge_commit_message: $defaults[0].squash_merge_commit_message,
        security_and_analysis: {
          secret_scanning: {status: "enabled"},
          secret_scanning_push_protection: {status: "enabled"},
          secret_scanning_validity_checks: {status: "enabled"},
          dependabot_security_updates: {status: "enabled"}
        }
      }
    '
    ;;
  esac
  ;;
*)
  echo "unexpected endpoint: ${endpoint}" >&2
  exit 1
  ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

run_audit() {
  local scenario=$1
  GH_TEST_SCENARIO=${scenario} \
    PATH="${temporary}/bin:${PATH}" \
    AUDIT_CONFIG_ROOT="${root}" \
    "${root}/bin/audit"
}

output=$(run_audit pass)
grep -Fxq 'Governance audit passed: 21 active repositories checked.' <<<"${output}"

temporary_output=$(run_audit temporary)
grep -Fxq 'Governance audit passed: 21 active repositories checked.' <<<"${temporary_output}"

if run_audit unmanaged >"${temporary}/unmanaged.out" 2>"${temporary}/unmanaged.err"; then
  echo "expected unmanaged repository audit to fail" >&2
  exit 1
fi
grep -Fq 'active repository is not in the desired-state inventory: atrinik/unmanaged' \
  "${temporary}/unmanaged.out"

if run_audit merge-drift >"${temporary}/merge.out" 2>"${temporary}/merge.err"; then
  echo "expected merge drift audit to fail" >&2
  exit 1
fi
grep -Fq 'repository merge policy drift: atrinik/observatory' \
  "${temporary}/merge.out"

if run_audit properties-drift >"${temporary}/properties.out" 2>"${temporary}/properties.err"; then
  echo "expected property drift audit to fail" >&2
  exit 1
fi
grep -Fq 'repository custom-property drift: atrinik/observatory' \
  "${temporary}/properties.out"

if run_audit schema-drift >"${temporary}/schema.out" 2>"${temporary}/schema.err"; then
  echo "expected property schema drift audit to fail" >&2
  exit 1
fi
grep -Fq 'organization custom-property schema drift: atrinik' \
  "${temporary}/schema.out"

echo "Governance drift audit tests passed."
