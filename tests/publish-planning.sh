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
input=
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  --input)
    input=$2
    shift 2
    ;;
  graphql)
    shift
    ;;
  *)
    echo "unexpected gh argument: $1" >&2
    exit 1
    ;;
  esac
done
[[ -n ${input} ]] || exit 1

jq -n --slurpfile config "${PLANNING_CONFIG:?}" '
  $config[0] as $config |
  {
    data: {
      organization: {
        id: "ORG",
        issueTypes: {
          nodes: [
            $config.issue_types[] |
            select(.name != "Initiative") |
            {
              id: ("TYPE-" + .name),
              name,
              description,
              color,
              isEnabled: .enabled
            }
          ]
        },
        issueFields: {
          nodes: [
            $config.issue_fields[] |
            {
              id: ("FIELD-" + .name),
              name,
              description,
              dataType: .data_type,
              visibility: "ORG_ONLY"
            } +
            if has("options") then
              {options: [.options[] | . + {id: ("OPTION-" + .name)}]}
            else
              {}
            end
          ]
        },
        projectsV2: {nodes: []}
      }
    }
  }
'
EOF
chmod +x "${temporary}/bin/gh"

output=$(
  PATH="${temporary}/bin:${PATH}" \
    PLANNING_CONFIG="${root}/config/planning.json" \
    "${root}/bin/publish-planning"
)

grep -Fq 'PLAN create organization issue type Initiative' <<<"${output}"
grep -Fq 'PLAN update organization issue field Priority' <<<"${output}"
grep -Fq 'PLAN create organization project Atrinik work' <<<"${output}"
[[ $(grep -c '^PLAN create shared project view ' <<<"${output}") == 6 ]]

echo "Planning publisher emits the expected initial plan."
