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
jq_filter=
scenario=${GH_TEST_SCENARIO:-pass}
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

case ${endpoint} in
orgs/atrinik/properties/schema)
  printf '[]\n'
  ;;
orgs/atrinik/repos?*)
  case ${jq_filter} in
  '.[].name')
    if [[ ${scenario} == extra-active ]]; then
      jq -r '.repositories | keys[], "unmanaged"' "${PROPERTIES_CONFIG:?}"
    elif [[ ${scenario} == missing-archived ]]; then
      jq -r '.repositories | keys[] | select(. != "legacy-client")' \
        "${PROPERTIES_CONFIG:?}"
    else
      jq -r '.repositories | keys[]' "${PROPERTIES_CONFIG:?}"
    fi
    ;;
  *'@tsv'*)
    if [[ ${scenario} == extra-active ]]; then
      jq -r '.repositories | to_entries[] |
        [.key, (.value.lifecycle == "archived" | tostring),
          "false", "public", "false", "false", "true", "true", "true"] |
        @tsv' \
        "${PROPERTIES_CONFIG:?}"
      printf 'unmanaged\tfalse\tfalse\tpublic\tfalse\tfalse\ttrue\ttrue\ttrue\n'
    elif [[ ${scenario} == missing-archived ]]; then
      jq -r '.repositories | to_entries[] |
        select(.key != "legacy-client") |
        [.key, (.value.lifecycle == "archived" | tostring),
          "false", "public", "false", "false", "true", "true", "true"] |
        @tsv' \
        "${PROPERTIES_CONFIG:?}"
    elif [[ ${scenario} == temporary ]]; then
      jq -r '.repositories | to_entries[] |
        [.key, (.value.lifecycle == "archived" | tostring),
          "false", "public", "false", "false", "true", "true", "true"] |
        @tsv' \
        "${PROPERTIES_CONFIG:?}"
      printf 'classic-ghsa-8533-3vg8-r287\tfalse\ttrue\tprivate\tfalse\tfalse\tfalse\tfalse\tfalse\n'
    else
      jq -r '.repositories | to_entries[] |
        [.key, (.value.lifecycle == "archived" | tostring),
          "false", "public", "false", "false", "true", "true", "true"] |
        @tsv' \
        "${PROPERTIES_CONFIG:?}"
    fi
    ;;
  *)
    exit 1
    ;;
  esac
  ;;
repos/atrinik/*/properties/values)
  printf '[]\n'
  ;;
*)
  echo "unexpected endpoint: ${endpoint}" >&2
  exit 1
  ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

output=$(
  PATH="${temporary}/bin:${PATH}" \
    PROPERTIES_CONFIG="${root}/config/repository-properties.json" \
    "${root}/bin/publish-repository-properties"
)

[[ $(grep -c '^PLAN PUT /orgs/atrinik/properties/schema/' <<<"${output}") == 4 ]]
expected_repositories=$(jq '.repositories | length' \
  "${root}/config/repository-properties.json")
[[ $(grep -c '^PLAN PATCH /orgs/atrinik/properties/values ' <<<"${output}") == "${expected_repositories}" ]]

temporary_output=$(
  GH_TEST_SCENARIO=temporary \
    PATH="${temporary}/bin:${PATH}" \
    PROPERTIES_CONFIG="${root}/config/repository-properties.json" \
    "${root}/bin/publish-repository-properties"
)
[[ $(grep -c '^PLAN PATCH /orgs/atrinik/properties/values ' <<<"${temporary_output}") == "${expected_repositories}" ]]

if GH_TEST_SCENARIO=extra-active \
  PATH="${temporary}/bin:${PATH}" \
  PROPERTIES_CONFIG="${root}/config/repository-properties.json" \
  "${root}/bin/publish-repository-properties" \
  >"${temporary}/extra.out" 2>"${temporary}/extra.err"; then
  echo "expected extra active repository to fail closed" >&2
  exit 1
fi
grep -Fq \
  'live active repository is not in the property inventory: atrinik/unmanaged' \
  "${temporary}/extra.err"

missing_output=$(
  GH_TEST_SCENARIO=missing-archived \
    PATH="${temporary}/bin:${PATH}" \
    PROPERTIES_CONFIG="${root}/config/repository-properties.json" \
    "${root}/bin/publish-repository-properties"
)
grep -Fq 'SKIP atrinik/legacy-client is an absent archived repository' \
  <<<"${missing_output}"
[[ $(grep -c '^PLAN PATCH /orgs/atrinik/properties/values ' <<<"${missing_output}") == $((expected_repositories - 1)) ]]

echo "Repository-property publisher plans every definition and repository value."
