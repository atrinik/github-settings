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
input=
while (($#)); do
  case $1 in
  --include)
    shift
    ;;
  -H)
    shift 2
    ;;
  --input)
    input=$2
    shift 2
    ;;
  user)
    endpoint=user
    shift
    ;;
  *)
    shift
    ;;
  esac
done

if [[ ${endpoint} == user ]]; then
  printf '%s\n' 'REST user' >>"${FAKE_GH_LOG}"
  if [[ ${FAKE_GH_SCENARIO} == scope-api-failure ]]; then
    echo "gh: scope metadata request failed" >&2
    exit 44
  fi
  scopes='admin:org, project, repo'
  [[ ${FAKE_GH_SCENARIO} == insufficient-scopes ]] && scopes=repo
  printf 'HTTP/2.0 200 OK\r\nx-oauth-scopes: %s\r\n\r\n{"login":"test"}\n' \
    "${scopes}"
  exit 0
fi

[[ -n ${input} ]]
query=$(jq -r '.query' "${input}")
variables=$(jq -c '.variables' "${input}")
cursor=$(jq -r '.endCursor // empty' <<<"${variables}")
printf '%s\n' "${query}" >>"${FAKE_GH_LOG}"

case ${FAKE_GH_SCENARIO} in
api-failure)
  echo "gh: authentication failed" >&2
  exit 42
  ;;
graphql-error)
  jq -n '{errors: [{message: "Resource not accessible by personal access token"}]}'
  exit 0
  ;;
invalid-response)
  jq -n '{}'
  exit 0
  ;;
page2-api-failure)
  if [[ ${cursor} == CURSOR ]]; then
    echo "gh: pagination transport failed" >&2
    exit 43
  fi
  ;;
page2-graphql-error)
  if [[ ${cursor} == CURSOR ]]; then
    jq -n '{errors: [{message: "Pagination authorization denied"}]}'
    exit 0
  fi
  ;;
happy | idempotent | paginated | page2-shape-error | repeated-cursor | \
  mutation-empty-add | mutation-empty-status | mutation-empty-type | \
  project-read-only | repository-read-only | search-overflow) ;;
*) exit 1 ;;
esac

if [[ ${FAKE_GH_SCENARIO} == mutation-empty-add && \
  ${query} == *'addProjectV2ItemById'* ]]; then
  jq -n '{data: {addProjectV2ItemById: {item: null}}}'
  exit 0
elif [[ ${FAKE_GH_SCENARIO} == mutation-empty-status && \
  ${query} == *'updateProjectV2ItemFieldValue'* ]]; then
  jq -n '{data: {updateProjectV2ItemFieldValue: {projectV2Item: null}}}'
  exit 0
elif [[ ${FAKE_GH_SCENARIO} == mutation-empty-type && \
  ${query} == *'updateIssue(input:'* ]]; then
  jq -n '{data: {updateIssue: {issue: null}}}'
  exit 0
fi

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
  can_update=true
  [[ ${FAKE_GH_SCENARIO} == project-read-only ]] && can_update=false
  jq -n --argjson can_update "${can_update}" '{
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
            viewerCanUpdate: $can_update,
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
  issue_count=1
  [[ ${FAKE_GH_SCENARIO} == search-overflow ]] && issue_count=1001
  if [[ ${cursor} == CURSOR ]]; then
    case ${FAKE_GH_SCENARIO} in
    page2-shape-error)
      jq -n '{data: {search: null}}'
      ;;
    repeated-cursor)
      jq -n --argjson issue_count "${issue_count}" '{data: {search: {
        issueCount: $issue_count,
        nodes: [],
        pageInfo: {hasNextPage: true, endCursor: "CURSOR"}
      }}}'
      ;;
    *)
      jq -n --argjson issue_count "${issue_count}" '{data: {search: {
        issueCount: $issue_count,
        nodes: [],
        pageInfo: {hasNextPage: false, endCursor: null}
      }}}'
      ;;
    esac
    exit 0
  fi
  page_info='{"hasNextPage":false,"endCursor":null}'
  case ${FAKE_GH_SCENARIO} in
  paginated | page2-api-failure | page2-graphql-error | page2-shape-error | \
    repeated-cursor)
    page_info='{"hasNextPage":true,"endCursor":"CURSOR"}'
    ;;
  esac
  query_string=$(jq -r '.queryString' <<<"${variables}")
  if [[ ${query_string} == *'is:issue'* ]]; then
    issue_type=null
    if [[ ${FAKE_GH_SCENARIO} == idempotent ]]; then
      issue_type='{"name":"Initiative"}'
    fi
    viewer_permission=WRITE
    [[ ${FAKE_GH_SCENARIO} == repository-read-only ]] && \
      viewer_permission=READ
    jq -n --argjson issue_count "${issue_count}" \
      --argjson issue_type "${issue_type}" \
      --arg viewer_permission "${viewer_permission}" \
      --argjson page_info "${page_info}" '{
      data: {search: {
        issueCount: $issue_count,
        nodes: [{
          __typename: "Issue",
          id: "ISSUE",
          url: "https://github.com/atrinik/server/issues/1",
          createdAt: "2020-01-01T00:00:00Z",
          state: "OPEN",
          issueType: $issue_type,
          repository: {
            name: "server", isArchived: false,
            viewerPermission: $viewer_permission
          },
          labels: {nodes: []},
          subIssues: {totalCount: 1}
        }],
        pageInfo: $page_info
      }}
    }'
  else
    jq -n --argjson issue_count "${issue_count}" \
      --argjson page_info "${page_info}" '{
      data: {search: {
        issueCount: $issue_count,
        nodes: [{
          __typename: "PullRequest",
          id: "PR",
          url: "https://github.com/atrinik/server/pull/2",
          createdAt: "2020-01-01T00:00:00Z",
          state: "OPEN",
          isDraft: false,
          repository: {
            name: "server", isArchived: false, viewerPermission: "WRITE"
          }
        }],
        pageInfo: $page_info
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
  elif [[ ${FAKE_GH_SCENARIO} == paginated && -z ${cursor} ]]; then
    jq -n '{
      data: {node: {items: {
        nodes: [],
        pageInfo: {hasNextPage: true, endCursor: "CURSOR"}
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
output=$(run_sync paginated --apply)
grep -Fq 'APPLY project 1 (Atrinik work)' <<<"${output}"
grep -Fq 'Total mutations: 5' <<<"${output}"
[[ $(grep -c 'search(query:' "${temporary}/gh.log") == 4 ]]
[[ $(grep -c '... on ProjectV2{items(' "${temporary}/gh.log") == 2 ]]

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

assert_preflight_failure() {
  local expected_status=$1
  local scenario=$2
  local status

  : >"${temporary}/gh.log"
  set +e
  run_sync "${scenario}" --apply \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
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
}

assert_preflight_failure 42 api-failure
grep -Fq 'read organization planning metadata' \
  "${temporary}/api-failure.err"
assert_preflight_failure 44 scope-api-failure
grep -Fq 'gh: scope metadata request failed' \
  "${temporary}/scope-api-failure.err"
grep -Fq 'verify settings credential scopes' \
  "${temporary}/scope-api-failure.err"
assert_preflight_failure 1 insufficient-scopes
grep -Fq 'missing required classic PAT scope: admin:org' \
  "${temporary}/insufficient-scopes.err"
[[ $(wc -l <"${temporary}/gh.log") == 1 ]]
assert_preflight_failure 1 graphql-error
grep -Fq 'read organization planning metadata' \
  "${temporary}/graphql-error.err"
assert_preflight_failure 1 invalid-response
grep -Fq 'invalid response: read organization planning metadata' \
  "${temporary}/invalid-response.err"
assert_preflight_failure 43 page2-api-failure
grep -Fq 'search open is:issue work (page 2)' \
  "${temporary}/page2-api-failure.err"
assert_preflight_failure 1 page2-graphql-error
grep -Fq 'Pagination authorization denied' \
  "${temporary}/page2-graphql-error.err"
assert_preflight_failure 1 page2-shape-error
grep -Fq 'missing the expected connection: search open is:issue work' \
  "${temporary}/page2-shape-error.err"
assert_preflight_failure 1 repeated-cursor
grep -Fq 'repeated the next cursor: search open is:issue work' \
  "${temporary}/repeated-cursor.err"
assert_preflight_failure 1 project-read-only
grep -Fq 'cannot update organization project: Atrinik work' \
  "${temporary}/project-read-only.err"
assert_preflight_failure 1 repository-read-only
grep -Fq 'cannot set issue types in repositories: server' \
  "${temporary}/repository-read-only.err"
assert_preflight_failure 1 search-overflow
grep -Fq 'search exceeds the 1000-result API window' \
  "${temporary}/search-overflow.err"

grep -Fq 'gh: authentication failed' "${temporary}/api-failure.err"
grep -Fq 'Resource not accessible by personal access token' \
  "${temporary}/graphql-error.err"

for scenario in mutation-empty-add mutation-empty-status mutation-empty-type; do
  : >"${temporary}/gh.log"
  if run_sync "${scenario}" --apply \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: synchronization accepted ${scenario}" >&2
    exit 1
  fi
  grep -Fq 'GitHub GraphQL operation returned an invalid' \
    "${temporary}/${scenario}.err"
  if grep -Fq 'APPLY project' "${temporary}/${scenario}.out"; then
    echo "error: ${scenario} printed a success summary" >&2
    exit 1
  fi
done
grep -Fq 'add ISSUE to project' "${temporary}/mutation-empty-add.err"
grep -Fq 'set project item ITEM-ISSUE status to Backlog' \
  "${temporary}/mutation-empty-status.err"
grep -Fq 'set issue ISSUE type to Initiative' \
  "${temporary}/mutation-empty-type.err"

echo "Project synchronization validates authentication, API failures, mutations, and idempotence."
