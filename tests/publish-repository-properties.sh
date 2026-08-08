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
  [[ ${jq_filter} == '.[].name' ]] || exit 1
  jq -r '.repositories | keys[]' "${PROPERTIES_CONFIG:?}"
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
[[ $(grep -c '^PLAN PATCH /orgs/atrinik/properties/values ' <<<"${output}") == 23 ]]

echo "Repository-property publisher plans every definition and repository value."
