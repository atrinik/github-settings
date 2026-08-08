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

query=$(jq -r '.query' "${input}")
if [[ ${PLANNING_SCENARIO:-initial} == partial ]] && \
  [[ ${query} == query\(\$id:ID\!\)* ]]; then
  jq -n --slurpfile config "${PLANNING_CONFIG:?}" '
    $config[0] as $config |
    {
      data: {
        node: {
          fields: {
            nodes: (
              [
                "Title",
                "Repository",
                "Milestone",
                "Assignees",
                "Reviewers",
                "Linked pull requests"
              ] |
              map({id: ("PROJECT-FIELD-" + .), name: .})
            ) + [{
              id: "PROJECT-FIELD-Status",
              name: "Status",
              dataType: "SINGLE_SELECT",
              options: [
                $config.project.statuses[] |
                {
                  id: ("STATUS-" + .name),
                  name,
                  color,
                  description
                }
              ]
            }] +
            if env.PLANNING_COLLISION == "true" then
              [{
                id: "PROJECT-FIELD-Issue-Type",
                name: "Issue Type",
                dataType: "TEXT"
              }]
            else
              []
            end
          },
          views: {
            nodes: [{
              id: "DEFAULT-VIEW",
              name: "View 1",
              layout: "TABLE_LAYOUT",
              filter: null,
              fields: {nodes: []}
            }]
          }
        }
      }
    }
  '
  exit
fi

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
        projectsV2: {
          nodes:
            if env.PLANNING_SCENARIO == "partial" then
              [{
                id: "PROJECT",
                number: 1,
                title: $config.project.title,
                shortDescription: $config.project.short_description,
                readme: $config.project.readme,
                public: $config.project.public,
                closed: false
              }]
            else
              []
            end
        }
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

partial_output=$(
  PATH="${temporary}/bin:${PATH}" \
    PLANNING_CONFIG="${root}/config/planning.json" \
    PLANNING_SCENARIO=partial \
    "${root}/bin/publish-planning"
)

for field in Priority Effort 'Start date' 'Target date'; do
  grep -Fq "PLAN link organization issue field ${field} to Atrinik work" \
    <<<"${partial_output}"
done
grep -Fq 'PLAN add built-in project field Issue Type to Atrinik work' \
  <<<"${partial_output}"
grep -Fq 'PLAN update shared project view Triage' <<<"${partial_output}"
[[ $(grep -c '^PLAN create shared project view ' <<<"${partial_output}") == 5 ]]
grep -Fq 'Project planning configuration is converged (project 1).' \
  <<<"${partial_output}"

if collision_output=$(
  PATH="${temporary}/bin:${PATH}" \
    PLANNING_CONFIG="${root}/config/planning.json" \
    PLANNING_SCENARIO=partial \
    PLANNING_COLLISION=true \
    "${root}/bin/publish-planning" 2>&1
); then
  echo "error: incompatible project field was accepted" >&2
  exit 1
fi
grep -Fq \
  'error: Atrinik work field Issue Type has an incompatible data type' \
  <<<"${collision_output}"

echo "Planning publisher emits the expected initial and partial-project plans."
