#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
cp -R "${root}/." "${temporary}/repository"

"${temporary}/repository/bin/validate" >/dev/null

jq '.release_tags += ["observatory"]' \
  "${root}/config/repositories.json" \
  >"${temporary}/repository/config/repositories.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: a no-release repository in release_tags was accepted" >&2
  exit 1
fi

cp "${root}/config/repositories.json" \
  "${temporary}/repository/config/repositories.json"
jq '.repositories.observatory.release_policy = "semantic-release"' \
  "${root}/config/repository-properties.json" \
  >"${temporary}/repository/config/repository-properties.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: a release-policy repository omitted from release_tags was accepted" >&2
  exit 1
fi

cp "${root}/config/repository-properties.json" \
  "${temporary}/repository/config/repository-properties.json"

jq '.project.views += [.project.views[0]]' \
  "${root}/config/planning.json" \
  >"${temporary}/repository/config/planning.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: duplicate project view was accepted" >&2
  exit 1
fi

jq '.project.builtin_fields[0].name = .issue_fields[0].name' \
  "${root}/config/planning.json" \
  >"${temporary}/repository/config/planning.json"
if "${temporary}/repository/bin/validate" >/dev/null 2>&1; then
  echo "error: ambiguous project field name was accepted" >&2
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
