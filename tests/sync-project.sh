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
  *)
    shift
    ;;
  esac
done

[[ -n ${input} ]]
query=$(jq -r '.query' "${input}")
variables=$(jq -c '.variables' "${input}")
printf '%s\n' "${query}" >>"${FAKE_GH_LOG}"

case ${FAKE_GH_SCENARIO} in
api-failure)
  echo "gh: authentication failed" >&2
  exit 1
  ;;
graphql-error)
  jq -n '{errors: [{message: "Resource not accessible by personal access token"}]}'
  exit 0
  ;;
happy | idempotent) ;;
*) exit 1 ;;
esac

if [[ ${query} == *'addProjectV2ItemById'* ]]; then
  jq -n --arg id "ITEM-$(jq -r '.input.contentId' <<<"${variables}")" \
    '{data: {addProjectV2ItemById: {item: {id: $id}}}}'
elif [[ ${query} == *'updateProjectV2ItemFieldValue'* ]]; then
  jq -n --arg id "$(jq -r '.input.itemId' <<<"${variables}")" \
    '{data: {updateProjectV2ItemFieldValue: {projectV2Item: {id: $id}}}}'
elif [[ ${query} == *'updateIssue(input:'* ]]; then
  jq -n --arg id "$(jq -r '.input.id' <<<"${variables}")" \
    '{data: {updateIssue: {issue: {id: $id}}}}'
elif [[ ${query} == *'organization(login:'* ]]; then
  jq -n '{
    data: {
      organization: {
        issueTypes: {
          nodes: [
            {id: "TASK", name: "Task", isEnabled: true},
            {id: "BUG", name: "Bug", isEnabled: true},
            {id: "FEATURE", name: "Feature", isEnabled: true},
            {id: "INITIATIVE", name: "Initiative", isEnabled: true}
          ]
        },
        projectsV2: {
          nodes: [{
            id: "PROJECT",
            number: 1,
            title: "Atrinik work",
            fields: {
              nodes: [{
                id: "STATUS",
                name: "Status",
                options: [
                  {id: "INBOX", name: "Inbox"},
                  {id: "BACKLOG", name: "Backlog"},
                  {id: "REVIEW", name: "Review"},
                  {id: "DONE", name: "Done"}
                ]
              }]
            }
          }]
        }
      }
    }
  }'
elif [[ ${query} == *'search(query:'* ]]; then
  query_string=$(jq -r '.queryString' <<<"${variables}")
  if [[ ${query_string} == *'is:issue'* ]]; then
    issue_type=null
    if [[ ${FAKE_GH_SCENARIO} == idempotent ]]; then
      issue_type='{"name":"Initiative"}'
    fi
    jq -n --argjson issue_type "${issue_type}" '{
      data: {search: {
        nodes: [{
          __typename: "Issue",
          id: "ISSUE",
          url: "https://github.com/atrinik/server/issues/1",
          createdAt: "2020-01-01T00:00:00Z",
          state: "OPEN",
          issueType: $issue_type,
          repository: {name: "server", isArchived: false},
          labels: {nodes: []},
          subIssues: {totalCount: 1}
        }],
        pageInfo: {hasNextPage: false, endCursor: null}
      }}
    }'
  else
    jq -n '{
      data: {search: {
        nodes: [{
          __typename: "PullRequest",
          id: "PR",
          url: "https://github.com/atrinik/server/pull/2",
          createdAt: "2020-01-01T00:00:00Z",
          state: "OPEN",
          isDraft: false,
          repository: {name: "server", isArchived: false}
        }],
        pageInfo: {hasNextPage: false, endCursor: null}
      }}
    }'
  fi
elif [[ ${query} == *'... on ProjectV2{items('* ]]; then
  if [[ ${FAKE_GH_SCENARIO} == idempotent ]]; then
    jq -n '{
      data: {node: {items: {
        nodes: [
          {
            id: "ITEM-ISSUE",
            fieldValueByName: {name: "Inbox", optionId: "INBOX"},
            content: {
              __typename: "Issue", id: "ISSUE",
              url: "https://github.com/atrinik/server/issues/1",
              createdAt: "2020-01-01T00:00:00Z", state: "OPEN",
              issueType: {name: "Initiative"},
              repository: {name: "server", isArchived: false},
              labels: {nodes: []}, subIssues: {totalCount: 1}
            }
          },
          {
            id: "ITEM-PR",
            fieldValueByName: {name: "Review", optionId: "REVIEW"},
            content: {
              __typename: "PullRequest", id: "PR",
              url: "https://github.com/atrinik/server/pull/2",
              createdAt: "2020-01-01T00:00:00Z", state: "OPEN",
              isDraft: false,
              repository: {name: "server", isArchived: false}
            }
          }
        ],
        pageInfo: {hasNextPage: false, endCursor: null}
      }}}
    }'
  else
    jq -n '{
      data: {node: {items: {
        nodes: [],
        pageInfo: {hasNextPage: false, endCursor: null}
      }}}
    }'
  fi
else
  exit 1
fi
EOF
chmod +x "${temporary}/bin/gh"

run_sync() {
  local scenario=$1
  shift

  PATH="${temporary}/bin:${PATH}" \
    FAKE_GH_LOG="${temporary}/gh.log" \
    FAKE_GH_SCENARIO="${scenario}" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=test-token \
    ATRINIK_PROJECT_SYNC_PAUSE_SECONDS=0 \
    "${root}/bin/sync-project" "$@"
}

: >"${temporary}/gh.log"
output=$(run_sync happy --apply)
grep -Fq 'APPLY project 1 (Atrinik work)' <<<"${output}"
grep -Fq 'Items to add: 2' <<<"${output}"
grep -Fq 'Open-item status changes: 2' <<<"${output}"
grep -Fq 'Issue types to set: 1 (Initiative 1, Feature 0, Bug 0, Task 0)' \
  <<<"${output}"
grep -Fq 'Total mutations: 5' <<<"${output}"
[[ $(grep -c 'addProjectV2ItemById' "${temporary}/gh.log") == 2 ]]
[[ $(grep -c 'updateProjectV2ItemFieldValue' "${temporary}/gh.log") == 2 ]]
[[ $(grep -c 'updateIssue(input:' "${temporary}/gh.log") == 1 ]]

: >"${temporary}/gh.log"
output=$(run_sync idempotent)
grep -Fq 'PLAN project 1 (Atrinik work)' <<<"${output}"
grep -Fq 'Items to add: 0' <<<"${output}"
grep -Fq 'Open-item status changes: 0' <<<"${output}"
grep -Fq 'Issue types to set: 0' <<<"${output}"
grep -Fq 'Total mutations: 0' <<<"${output}"
if grep -Eq 'addProjectV2ItemById|updateProjectV2ItemFieldValue|updateIssue\(input:' \
  "${temporary}/gh.log"; then
  echo "error: idempotent plan attempted a mutation" >&2
  exit 1
fi

: >"${temporary}/gh.log"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=happy \
  GITHUB_ACTIONS=true GH_TOKEN='' "${root}/bin/sync-project" \
  >"${temporary}/empty.out" 2>"${temporary}/empty.err"; then
  echo "error: synchronization accepted an empty workflow credential" >&2
  exit 1
fi
grep -Fq 'ATRINIK_SETTINGS_TOKEN is unavailable' "${temporary}/empty.err"
[[ ! -s ${temporary}/gh.log ]]

for scenario in api-failure graphql-error; do
  : >"${temporary}/gh.log"
  if run_sync "${scenario}" --apply \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: synchronization accepted ${scenario}" >&2
    exit 1
  fi
  grep -Fq 'read organization planning metadata' \
    "${temporary}/${scenario}.err"
  if grep -Fq 'project Status option is missing' \
    "${temporary}/${scenario}.err"; then
    echo "error: ${scenario} fell through to a schema error" >&2
    exit 1
  fi
  if grep -Fq 'APPLY project' "${temporary}/${scenario}.out"; then
    echo "error: ${scenario} printed a success summary" >&2
    exit 1
  fi
  if grep -Eq 'addProjectV2ItemById|updateProjectV2ItemFieldValue|updateIssue\(input:' \
    "${temporary}/gh.log"; then
    echo "error: ${scenario} attempted a mutation" >&2
    exit 1
  fi
done
grep -Fq 'gh: authentication failed' "${temporary}/api-failure.err"
grep -Fq 'Resource not accessible by personal access token' \
  "${temporary}/graphql-error.err"

echo "Project synchronization validates authentication, API failures, mutations, and idempotence."
