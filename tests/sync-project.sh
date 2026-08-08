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
arguments=" $* "
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

if [[ -n ${input} ]]; then
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
elif [[ ${arguments} == *'queryString=org:atrinik is:open is:issue archived:false'* ]]; then
  jq -nc '{
    __typename: "Issue",
    id: "ISSUE",
    url: "https://github.com/atrinik/server/issues/1",
    createdAt: "2020-01-01T00:00:00Z",
    state: "OPEN",
    issueType: null,
    repository: {name: "server", isArchived: false},
    labels: {nodes: []},
    subIssues: {totalCount: 1}
  }'
elif [[ ${arguments} == *'queryString=org:atrinik is:open is:pr archived:false'* ]]; then
  jq -nc '{
    __typename: "PullRequest",
    id: "PR",
    url: "https://github.com/atrinik/server/pull/2",
    createdAt: "2020-01-01T00:00:00Z",
    state: "OPEN",
    isDraft: false,
    repository: {name: "server", isArchived: false}
  }'
else
  exit 0
fi
EOF
chmod +x "${temporary}/bin/gh"

output=$(PATH="${temporary}/bin:${PATH}" "${root}/bin/sync-project")

grep -Fq 'Items to add: 2' <<<"${output}"
grep -Fq 'Open-item status changes: 2' <<<"${output}"
grep -Fq 'Issue types to set: 1 (Initiative 1, Feature 0, Bug 0, Task 0)' \
  <<<"${output}"
grep -Fq 'Total mutations: 5' <<<"${output}"

echo "Project synchronization plans membership, intake status, and type inference."
