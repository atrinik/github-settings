#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
cp -R "${root}/." "${temporary}/repository"

"${temporary}/repository/bin/validate" >/dev/null

jq '.project.views += [.project.views[0]]' \
  "${root}/config/planning.json" \
  >"${temporary}/repository/config/planning.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: duplicate project view was accepted" >&2
  exit 1
fi

cp "${root}/config/planning.json" \
  "${temporary}/repository/config/planning.json"
jq '.repositories.server.lifecycle = "unknown"' \
  "${root}/config/repository-properties.json" \
  >"${temporary}/repository/config/repository-properties.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: invalid repository lifecycle was accepted" >&2
  exit 1
fi

echo "Planning validation rejects invalid desired state."
