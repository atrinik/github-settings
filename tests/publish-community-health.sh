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
[[ $(grep -c '^PLAN PUT /repos/atrinik/.github/contents/' <<<"${output}") == 9 ]]

echo "Community-health publisher plans the repository and every default file."
