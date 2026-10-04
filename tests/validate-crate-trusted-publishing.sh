#!/usr/bin/env bash

set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir -p "${temporary}/bin"
cp "${root}/bin/validate" "${temporary}/bin/validate"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${temporary}/"

reset_policy() {
  cp "${root}/config/manual-settings.json" "${temporary}/config/manual-settings.json"
  cp "${root}/config/actions-selected.json" "${temporary}/config/actions-selected.json"
}

assert_rejected() {
  local filter=$1
  jq "${filter}" "${root}/config/manual-settings.json" >"${temporary}/config/manual-settings.json"
  if "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: accepted invalid crate publishing policy: ${filter}" >&2
    exit 1
  fi
  reset_policy
}

"${temporary}/bin/validate" >/dev/null
for filter in \
  '.crates_io_trusted_publishing[0].activation_state = "active"' \
  '.crates_io_trusted_publishing[0].crate = "other-crate"' \
  '.crates_io_trusted_publishing[0].provider = "other-provider"' \
  '.crates_io_trusted_publishing[0].repository = "atrinik/classic"' \
  '.crates_io_trusted_publishing[0].repository_id = 1' \
  '.crates_io_trusted_publishing[0].workflow_filename = "../publish-crate.yml"' \
  '.crates_io_trusted_publishing[0].workflow_ref = "refs/tags/v1.0.0"' \
  '.crates_io_trusted_publishing[0].workflow_trigger = "push"' \
  '.crates_io_trusted_publishing[0].authentication_action = "rust-lang/crates-io-auth-action@v1"' \
  '.crates_io_trusted_publishing[0].environment.name = "crates-io-bootstrap"' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers = []' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers = null' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers[0].id = 1' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers[0].login = "unknown"' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers[0].type = "Team"' \
  '.crates_io_trusted_publishing[0].environment.prevent_self_review = true' \
  '.crates_io_trusted_publishing[0].environment.can_admins_bypass = true' \
  '.crates_io_trusted_publishing[0].environment.deployment_branch_policy.patterns[0].name = "*"' \
  '.crates_io_trusted_publishing[0].environment.deployment_branch_policy.patterns[0].type = "tag"' \
  '.crates_io_trusted_publishing[0].environment.deployment_branch_policy.patterns += [{name:"v*",type:"tag"}]' \
  '.crates_io_trusted_publishing[0].environment.secret_names = ["CARGO_REGISTRY_TOKEN"]' \
  '.crates_io_trusted_publishing[0].environment.variable_names = ["UNREVIEWED"]' \
  '.crates_io_trusted_publishing[0].token = "forbidden-value"' \
  '.crates_io_trusted_publishing[0].release_sha = "invented"' \
  '.crates_io_trusted_publishing[0].crate_sha256 = "invented"' \
  '.crates_io_trusted_publishing += [.crates_io_trusted_publishing[0]]'; do
  assert_rejected "${filter}"
done

jq '.patterns_allowed |= map(select(startswith("rust-lang/crates-io-auth-action@") | not))' \
  "${root}/config/actions-selected.json" >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted planned publisher without exact action allowance" >&2
  exit 1
fi
reset_policy
jq '.patterns_allowed |= map(if startswith("rust-lang/crates-io-auth-action@") then "rust-lang/*" else . end)' \
  "${root}/config/actions-selected.json" >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted wildcard action allowance instead of exact pin" >&2
  exit 1
fi
reset_policy
jq '.patterns_allowed += ["rust-lang/*"]' "${root}/config/actions-selected.json" \
  >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted broader Rust action access beside the exact pin" >&2
  exit 1
fi
reset_policy
# Removing unactivated manual intent is a valid reviewed rollback.
jq '.crates_io_trusted_publishing = []' "${root}/config/manual-settings.json" \
  >"${temporary}/config/manual-settings.json"
"${temporary}/bin/validate" >/dev/null

echo "Planned crates.io Trusted Publishing validation tests passed."
