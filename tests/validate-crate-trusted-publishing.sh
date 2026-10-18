#!/usr/bin/env bash

set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
export ATRINIK_VALIDATION_TODAY=2026-10-18
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
  '.crates_io_trusted_publishing[0].source_state = "active"' \
  '.crates_io_trusted_publishing[0].crates = ["other-crate"]' \
  '.crates_io_trusted_publishing[0].provider = "other-provider"' \
  '.crates_io_trusted_publishing[0].repository = "atrinik/classic"' \
  '.crates_io_trusted_publishing[0].repository_id = 1' \
  '.crates_io_trusted_publishing[0].workflow_filename = "../publish-crate.yml"' \
  '.crates_io_trusted_publishing[0].source_workflow_filename = "../release.yml"' \
  '.crates_io_trusted_publishing[0].source_evidence_policy = "release-asset-digest-only"' \
  '.crates_io_trusted_publishing[0].upload_intent_policy = "retry-on-registry-404"' \
  '.crates_io_trusted_publishing[0].workflow_ref = "refs/tags/v1.0.0"' \
  '.crates_io_trusted_publishing[0].workflow_trigger = "push"' \
  '.crates_io_trusted_publishing[0].environment_state = "active"' \
  '.crates_io_trusted_publishing[0].publisher_registration.state = "active"' \
  '.crates_io_trusted_publishing[1].publisher_registration = {state:"pending-owner-registration", observed_on:null, evidence_location:"invented"}' \
  '.crates_io_trusted_publishing[1].bootstrap_crates += ["atrinik-render"]' \
  '.crates_io_trusted_publishing[2].bootstrap_crates += ["atrinik-content"]' \
  '.crates_io_trusted_publishing[0].bootstrap_crates = ["atrinik-protocol"]' \
  '.crates_io_trusted_publishing[0].bootstrap_policy = "api-token-every-release"' \
  '.crates_io_trusted_publishing[0].release_approval = "per-release-approval"' \
  '.crates_io_trusted_publishing[0].authentication_action = "rust-lang/crates-io-auth-action@v1"' \
  '.crates_io_trusted_publishing[0].environment.name = "crates-io-bootstrap"' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers = [{type: "User", id: 3865595}]' \
  '.crates_io_trusted_publishing[0].environment.wait_timer_minutes = 30' \
  '.crates_io_trusted_publishing[0].environment.required_reviewers = null' \
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
  echo "error: accepted planned publisher without official action allowance" >&2
  exit 1
fi
reset_policy
jq '.patterns_allowed |= map(if startswith("rust-lang/crates-io-auth-action@") then "rust-lang/*" else . end)' \
  "${root}/config/actions-selected.json" >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted an unrelated broader Rust action allowance" >&2
  exit 1
fi
reset_policy
jq '.patterns_allowed += ["rust-lang/*"]' "${root}/config/actions-selected.json" \
  >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted broader Rust action access beside the exact action" >&2
  exit 1
fi
reset_policy
# GitHub-owned official signing actions remain permitted without central SHA locks.
jq '.github_owned_allowed = false' "${root}/config/actions-selected.json" \
  >"${temporary}/config/actions-selected.json"
if "${temporary}/bin/validate" >/dev/null 2>&1; then
  echo "error: accepted source provenance signing without GitHub-owned Actions access" >&2
  exit 1
fi
reset_policy
# Dependabot can change the immutable workflow pin without a central version lock.
jq '.crates_io_trusted_publishing[0].authentication_action = "rust-lang/crates-io-auth-action@2222222222222222222222222222222222222222"' \
  "${root}/config/manual-settings.json" >"${temporary}/config/manual-settings.json"
"${temporary}/bin/validate" >/dev/null
reset_policy
# Observed onboarding requires coherent source/environment/external proof.
jq '.crates_io_trusted_publishing[0] |= (
  .source_state = "observed-reviewed-workflow" | .environment_state = "observed" |
  .publisher_registration = {state:"owner-observed-registration", observed_on:"2026-10-11",
    evidence_location:"atrinik/github-settings#owner-setup"})' "${root}/config/manual-settings.json" \
  >"${temporary}/config/manual-settings.json"
"${temporary}/bin/validate" >/dev/null
reset_policy
for filter in \
  '.crates_io_trusted_publishing[0] |= (.source_state="pending-reviewed-workflow" | .environment_state="observed")' \
  '.crates_io_trusted_publishing[0].publisher_registration = {state:"owner-observed-registration", observed_on:"2026-02-31", evidence_location:"atrinik/github-settings#owner-setup"}' \
  '.crates_io_trusted_publishing[0] |= (.source_state="observed-reviewed-workflow" | .environment_state="observed" | .publisher_registration={state:"owner-observed-registration",observed_on:"2099-01-01",evidence_location:"atrinik/github-settings#owner-setup"})'; do
  assert_rejected "${filter}"
done
jq '.crate_dependency_update_app |= (.status="owner-observed" | .app_id=85500002 |
  .installation_id=154000002 | .repository_scope_verification="organization_owner_ui" |
  .observed_on="2026-08-31" | .evidence_location="atrinik/github-settings#owner-app" |
  .repository_scope_reverification.last_readback_on="2026-08-31" |
  .workflow_activation={state:"pending-reviewed-workflows", observed_on:null, evidence_location:null})' \
  "${root}/config/manual-settings.json" >"${temporary}/config/manual-settings.json"
"${temporary}/bin/validate" >/dev/null
reset_policy
for filter in \
  '.crate_dependency_update_app.permissions.administration = "write"' \
  '.crate_dependency_update_app.consumers += ["atrinik/classic/.github/workflows/update-content.yml"]' \
  '.crate_dependency_update_app.key_created_on = "2099-01-01"' \
  '.crate_dependency_update_app.last_verified_on = null' \
  '.crate_dependency_update_app.rotate_by = "2026-10-10"' \
  '.crate_dependency_update_app.rotate_by = "2027-01-10"' \
  '.crate_dependency_update_app.rotation_cadence_days = 365' \
  '.crate_dependency_update_app.rotation_owner = "unknown"' \
  '.crate_dependency_update_app.events = ["push"]' \
  '.crate_dependency_update_app.webhook_active = true' \
  '.crate_dependency_update_app.homepage_url = "https://example.test"' \
  '.crate_dependency_update_app.repository_selection = "all"' \
  '.crate_dependency_update_app.repositories += [{repository:"atrinik/classic", repository_id:1327289971}]' \
  '.crate_dependency_update_app.repositories[0].repository_id = 1' \
  '.crate_dependency_update_app.secret_scope = "organization"' \
  '.crate_dependency_update_app.secret_name = "CARGO_REGISTRY_TOKEN"' \
  '.crate_dependency_update_app.private_key = "forbidden"' \
  '.crate_dependency_update_app.pull_request_policy = "auto-merge"' \
  '.crate_dependency_update_app.status = "active"' \
  '.crate_dependency_update_app.workflow_activation.state = "active"' \
  '.crate_dependency_update_app.workflow_activation = {state:"observed-successful-owned-pr", observed_on:null, evidence_location:null}' \
  '.crate_dependency_update_app.workflow_activation = {state:"pending-reviewed-workflows", observed_on:null, evidence_location:"invented"}' \
  '.crate_dependency_update_app.app_id = null' \
  '.crate_dependency_update_app.observed_on = null'; do
  assert_rejected "${filter}"
done

assert_accepted() {
  local filter=$1
  jq "${filter}" "${root}/config/manual-settings.json" >"${temporary}/config/manual-settings.json"
  if ! "${temporary}/bin/validate" >/dev/null 2>&1; then
    echo "error: rejected valid dependency App record: ${filter}" >&2
    exit 1
  fi
  reset_policy
}

# The exposure acceptance pins the editor transfer and stays while the key
# that was current at the transfer is in use. Rotation retires it.
assert_accepted '.crate_dependency_update_app |= (.key_created_on = "2026-10-18" |
  .last_verified_on = "2026-10-18" | .rotate_by = "2027-01-16" | .accepted_key_exposures = [])'
exposure='.crate_dependency_update_app.accepted_key_exposures'
for filter in \
  "${exposure} = null" \
  "${exposure} = []" \
  "${exposure}[0] |= (.former_repository = \"atrinik/classic\" | .repository = \"elsewhere/classic\" | .repository_id = 1327289971)" \
  "${exposure}[0].repository = \"seraphinastudios/other-editor\"" \
  "${exposure}[0].exposure_started_on = \"2026-10-18\"" \
  "${exposure} = {}" \
  "${exposure} += [${exposure}[0]]" \
  "${exposure}[0].private_key = \"forbidden\"" \
  "del(${exposure}[0].accepted_on)" \
  "${exposure}[0].exposure = \"accepted\"" \
  "${exposure}[0].exposed_names = [\"CRATE_DEPENDENCY_UPDATE_APP_ID\"]" \
  "${exposure}[0].exposed_names += [\"CARGO_REGISTRY_TOKEN\"]" \
  "${exposure}[0].exposed_names |= reverse" \
  "${exposure}[0].former_repository = \"atrinik/client\"" \
  "${exposure}[0].former_repository = \"seraphinastudios/tilewright-editor\"" \
  "${exposure}[0].repository = \"atrinik/editor\"" \
  "${exposure}[0].repository = \"Atrinik/editor\"" \
  "${exposure}[0].repository_id = 1327106844" \
  "${exposure}[0].repository_id = 0" \
  "${exposure}[0].exposure_started_on = \"2026-10-10\"" \
  "${exposure}[0].exposure_started_on = \"2026-02-30\"" \
  "${exposure}[0].removal_observed_on = null" \
  "${exposure}[0].removal_observed_on = \"2026-10-16\"" \
  "${exposure}[0].accepted_on = null" \
  "${exposure}[0].accepted_on = \"2026-10-17\"" \
  "${exposure}[0].accepted_on = \"2099-01-01\"" \
  "${exposure}[0].accepted_by = \"unknown\"" \
  "${exposure}[0].evidence_location = \"https://example.test/evidence?id=1\"" \
  '.crate_dependency_update_app |= (.key_created_on = "2026-10-18" |
    .last_verified_on = "2026-10-18" | .rotate_by = "2027-01-16")'; do
  assert_rejected "${filter}"
done

# A readback on or before the transfer stays pending; only a later readback
# in observed_on may clear the record, and then it must be cleared.
assert_accepted '.crate_dependency_update_app |= (.repository_scope_verification = "organization_owner_ui" |
  .observed_on = "2026-10-18" | .repository_scope_reverification = null)'
reverification='.crate_dependency_update_app.repository_scope_reverification'
for filter in \
  "${reverification} = null" \
  "${reverification} = \"pending\"" \
  '.crate_dependency_update_app |= (.observed_on = "2026-10-17" | .repository_scope_reverification = null)' \
  '.crate_dependency_update_app.observed_on = "2026-10-18"' \
  '.crate_dependency_update_app |= (.observed_on = "2026-10-17" | .repository_scope_reverification.last_readback_on = "2026-10-17")' \
  "${reverification}.removed_repositories = [{repository:\"atrinik/classic\", repository_id:1327289971}]" \
  "${reverification}.selection_changed_on = \"2026-10-16\"" \
  "${reverification} = {}" \
  "${reverification}.observed_on = \"2026-10-18\"" \
  "${reverification}.state = \"reverified\"" \
  "${reverification}.reason = \"unknown\"" \
  "${reverification}.last_readback_on = \"2026-10-10\"" \
  "${reverification}.last_readback_on = null" \
  "${reverification}.selection_changed_on = \"2026-10-11\"" \
  "${reverification}.selection_changed_on = \"2099-01-01\"" \
  "${reverification}.selection_changed_on = null" \
  "${reverification}.removed_repositories = []" \
  "${reverification}.removed_repositories = null" \
  "${reverification}.removed_repositories += [${reverification}.removed_repositories[0]]" \
  "${reverification}.removed_repositories[0] = {repository:\"atrinik/client\", repository_id:1327106844}" \
  "${reverification}.removed_repositories[0].repository_id = 1327106844" \
  "${reverification}.removed_repositories[0].repository = \"seraphinastudios/tilewright-editor\"" \
  "${reverification}.removed_repositories[0].visibility = \"public\"" \
  "${reverification}.evidence_location = null" \
  '.crate_dependency_update_app.observed_on = "2026-10-12"'; do
  assert_rejected "${filter}"
done

# A planned App has no observed readback or key to qualify.
planned='.crate_dependency_update_app |= (.status="planned" | .app_id=null | .installation_id=null |
  .key_created_on=null | .last_verified_on=null | .rotate_by=null |
  .repository_scope_verification="pending-owner-ui" | .observed_on=null | .evidence_location=null |
  .credential_state="pending-name-metadata")'
assert_accepted "${planned} | .crate_dependency_update_app |= (.accepted_key_exposures=[] | .repository_scope_reverification=null)"
assert_rejected "${planned} | .crate_dependency_update_app.accepted_key_exposures=[]"
assert_rejected "${planned} | .crate_dependency_update_app.repository_scope_reverification=null"
# Removing unactivated manual intent is a valid reviewed rollback.
jq '.crates_io_trusted_publishing = []' "${root}/config/manual-settings.json" \
  >"${temporary}/config/manual-settings.json"
"${temporary}/bin/validate" >/dev/null

echo "Automatic crates.io Trusted Publishing and dependency App validation tests passed."
