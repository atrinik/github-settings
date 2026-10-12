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
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  repos/atrinik/.github)
    exit 1
    ;;
  *)
    echo "unexpected gh argument: $1" >&2
    exit 1
    ;;
  esac
done
EOF
chmod +x "${temporary}/bin/gh"

output=$(PATH="${temporary}/bin:${PATH}" \
  "${root}/bin/publish-community-health")

[[ $(grep -c '^PLAN POST /orgs/atrinik/repos ' <<<"${output}") == 1 ]]
expected_files=$(jq '.files | length' "${root}/config/community-health.json")
[[ $(grep -c '^PLAN PUT /repos/atrinik/.github/contents/' <<<"${output}") == "${expected_files}" ]]
grep -Fq \
  'PLAN PUT /repos/atrinik/.github/contents/profile/README.md' \
  <<<"${output}"

grep -Fq \
  'PLAN PUT /repos/atrinik/.github/contents/.github/workflows/dependency-review.yml' \
  <<<"${output}"

# A matching generated workflow must be kept, just like every other mapped file.
cat >"${temporary}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

[[ ${1:-} == api ]] || exit 1
shift
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  repos/atrinik/.github)
    jq '.repository' "${COMMUNITY_TEST_ROOT}/config/community-health.json"
    exit
    ;;
  repos/atrinik/.github/contents/*\?ref=main)
    target=${1#repos/atrinik/.github/contents/}
    target=${target%\?ref=main}
    source=$(jq -er --arg target "${target}" \
      '.files[] | select(.target == $target) | .source' \
      "${COMMUNITY_TEST_ROOT}/config/community-health.json")
    content=$(base64 -w 0 "${COMMUNITY_TEST_ROOT}/community-health/${source}")
    jq -n --arg content "${content}" '{sha: "fixture-sha", content: $content}'
    exit
    ;;
  *)
    echo "unexpected gh argument: $1" >&2
    exit 1
    ;;
  esac
done
EOF

output=$(PATH="${temporary}/bin:${PATH}" COMMUNITY_TEST_ROOT="${root}" \
  "${root}/bin/publish-community-health")
[[ $(grep -c '^KEEP /repos/atrinik/.github/contents/' <<<"${output}") == "${expected_files}" ]]
if grep -q '^PLAN ' <<<"${output}"; then
  echo "error: publisher planned mutations for matching generated files" >&2
  exit 1
fi
grep -Fxq \
  'KEEP /repos/atrinik/.github/contents/.github/workflows/dependency-review.yml' \
  <<<"${output}"

echo "Community-health publisher plans every default file and keeps matching content."
