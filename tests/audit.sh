#!/usr/bin/env bash

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT
mkdir -p "${temporary}/mock" "${temporary}/full/bin"
cp -R "${root}/config" "${temporary}/full/config"
cp "${root}/bin/audit" "${temporary}/full/bin/audit"
# Schema validation has its own policy tests; these isolate live API evidence.
printf '#!/usr/bin/env bash\nexit 0\n' >"${temporary}/full/bin/validate"
cat >"${temporary}/full/bin/security-readiness" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${AUDIT_READINESS_LOG}"
case ${GH_TEST_SCENARIO:-pass} in
  pending|pending-codeql|pending-wrong-dependency-scope|enforced-missing-dependency|enforced-missing-codeql) exit 1 ;;
  readiness-unreadable|dependency-readiness-unreadable|codeql-readiness-unreadable|enforced-unreadable-dependency|enforced-unreadable-codeql) exit 2 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${temporary}/full/bin/validate" "${temporary}/full/bin/security-readiness"
cp "${root}/tests/audit-fixtures.py" "${temporary}/mock/gh"
chmod +x "${temporary}/mock/gh"
# Exercise both reviewed rollout phases using test-owned desired state.
printf '%s\n' '{"phase":"pending","canary":null}' \
  >"${temporary}/full/config/actions-sha-pinning.json"
jq '.sha_pinning_required = true' "${temporary}/full/config/actions-permissions.json" \
  >"${temporary}/actions.json"
mv "${temporary}/actions.json" "${temporary}/full/config/actions-permissions.json"
jq '.pull_request_gate |= ((. + [".github"]) | unique)' "${temporary}/full/config/repositories.json" \
  >"${temporary}/repositories.json"
mv "${temporary}/repositories.json" "${temporary}/full/config/repositories.json"
for repository in .github classic observatory content-toolkit playtester service-updater web-platform; do
  fixture="${temporary}/fixture-${repository}"
  cp -R "${temporary}/full" "${fixture}"
  jq --arg repository "${repository}" \
    '.repositories |= with_entries(select(.key == $repository))' \
    "${temporary}/full/config/repository-properties.json" >"${fixture}/config/repository-properties.json"
done

cp -R "${temporary}/fixture-observatory" "${temporary}/fixture-legacy-branches"
jq '.maintenance_branches = [
  {repository: "observatory", branch: "release/2.x", required_ci: []},
  {repository: "observatory", branch: "release/next#candidate", required_ci: []},
  {repository: "classic", branch: "foreign/maintenance", required_ci: []}
]' "${temporary}/full/config/repositories.json" \
  >"${temporary}/fixture-legacy-branches/config/repositories.json"

cp -R "${temporary}/fixture-observatory" "${temporary}/fixture-retired-observatory"
jq 'del(.required_ci.observatory)' "${temporary}/full/config/repositories.json" \
  >"${temporary}/fixture-retired-observatory/config/repositories.json"

cp -R "${temporary}/fixture-legacy-branches" "${temporary}/fixture-effective-branches"
jq '(.maintenance_branches[] | select(.branch == "release/next#candidate") | .required_ci) = ["Conventional PR title"]' \
  "${temporary}/fixture-legacy-branches/config/repositories.json" \
  >"${temporary}/fixture-effective-branches/config/repositories.json"

run_audit() {
  local scenario=$1 fixture=${2:-focused} repository=observatory
  if [[ ${fixture} == focused ]]; then
    case ${scenario} in
      closure-*) repository=effective-branches ;;
      retained-*) repository=.github ;;
      retired-*) repository=retired-observatory ;;
      legacy-maintenance-*|legacy-multiple) repository=legacy-branches ;;
      wrong-pr-scope|unexpected-codeql|tag-extra-nonrelease|tag-all-nonrelease|tag-repository-nonrelease|inherited-tag-unaffected|foreign-tag) repository=.github ;;
      advanced-config|advanced-setup|advanced-null-languages) repository=classic ;;
      missing-rust) repository=content-toolkit ;;
      missing-tag-scope|tag-ref-drift|tag-all-scope|tag-extra-repo|tag-extra-exclude) repository=service-updater ;;
      unexpected-pr) repository=web-platform ;;
      queue-retained) repository=observatory ;;
      queue-*) repository=playtester ;;
    esac
    fixture="fixture-${repository}"
  fi
  case ${scenario} in
    sha-enforced-off|sha-enforced-on)
      printf '%s\n' '{"phase":"enforced","canary":"atrinik/observatory/1"}' \
        >"${temporary}/${fixture}/config/actions-sha-pinning.json"
      ;;
    phase-unreadable)
      printf '%s\n' '{}' >"${temporary}/${fixture}/config/actions-sha-pinning.json"
      ;;
    *)
      printf '%s\n' '{"phase":"pending","canary":null}' \
        >"${temporary}/${fixture}/config/actions-sha-pinning.json"
      ;;
  esac
  # Preserve required-gate audit scenarios independently of advisory production.
  if [[ ${scenario} == production-advisory ]]; then
    cp "${root}/config/security-merge-protection.json" "${temporary}/${fixture}/config/security-merge-protection.json"
  else
  # Dependency review never reports on merge groups, so queued repositories
  # cannot carry its required gate.
  jq --slurpfile repositories "${root}/config/repositories.json" '
    $repositories[0].merge_queue as $queued |
    .dependency_review = (.code_scanning - $queued) |
    .activation.dependency_review = (.activation.code_scanning |
      with_entries(select(.key as $repository | $queued | index($repository) | not)))
  ' "${root}/config/security-merge-protection.json" >"${temporary}/${fixture}/config/security-merge-protection.json"
  fi
  case ${scenario} in
    retired-*)
      jq '.dependency_review -= ["observatory"] | .code_scanning -= ["observatory"] |
        del(.activation.dependency_review.observatory, .activation.code_scanning.observatory)' \
        "${temporary}/${fixture}/config/security-merge-protection.json" >"${temporary}/activation.json"
      mv "${temporary}/activation.json" "${temporary}/${fixture}/config/security-merge-protection.json"
      ;;
    enforced-missing-dependency|enforced-unreadable-dependency)
      jq '.activation.dependency_review.observatory = "enforced"' \
        "${temporary}/${fixture}/config/security-merge-protection.json" >"${temporary}/activation.json"
      mv "${temporary}/activation.json" "${temporary}/${fixture}/config/security-merge-protection.json"
      ;;
    enforced-missing-codeql|enforced-unreadable-codeql)
      jq '.activation.code_scanning.observatory = "enforced"' \
        "${temporary}/${fixture}/config/security-merge-protection.json" >"${temporary}/activation.json"
      mv "${temporary}/activation.json" "${temporary}/${fixture}/config/security-merge-protection.json"
      ;;
  esac
  : >"${temporary}/${scenario}.readiness-log"
  GH_TEST_SCENARIO=${scenario} \
    AUDIT_READINESS_LOG="${temporary}/${scenario}.readiness-log" \
    PATH="${temporary}/mock:${PATH}" \
    AUDIT_CONFIG_ROOT="${temporary}/${fixture}" \
    AUDIT_API_LOG="${temporary}/api.log" \
    "${temporary}/${fixture}/bin/audit"
}

output=$(run_audit production-advisory full)
grep -Fxq 'Governance audit passed: 22 active repositories checked.' <<<"${output}"
if grep -Fq 'Dependency review merge protection' <<<"${output}"; then
  echo 'advisory production must not require dependency merge protection' >&2
  exit 1
fi
output=$(run_audit pass full)
grep -Fxq 'Governance audit passed: 22 active repositories checked.' <<<"${output}"
output=$(run_audit temporary full)
grep -Fxq 'Governance audit passed: 22 active repositories checked.' <<<"${output}"
output=$(run_audit legacy-security)
grep -Fq 'Governance audit passed:' <<<"${output}"
output=$(run_audit repository-rulesets)
grep -Fq 'Governance audit passed:' <<<"${output}"
for scenario in api-defaults-omitted api-default-order scope-order inherited-tag-unaffected foreign-tag sha-enforced-on languages-readable languages-empty advanced-null-languages; do
  output=$(run_audit "${scenario}")
  grep -Fq 'Governance audit passed:' <<<"${output}"
done
output=$(run_audit pending)
grep -Fq 'PENDING Actions SHA pinning deferred pending canary proof' <<<"${output}"
grep -Fq 'PENDING Dependency review merge protection awaits landed successful producer' <<<"${output}"
grep -Fq 'Governance audit baseline passed with' <<<"${output}"
if grep -Fq 'Governance audit passed:' <<<"${output}"; then
  echo 'pending policy must not report full governance enforcement' >&2
  exit 1
fi

assert_drift() {
  local scenario=$1 message=$2
  if run_audit "${scenario}" >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "expected ${scenario} audit to fail" >&2
    exit 1
  fi
  if ! grep -Fq "${message}" "${temporary}/${scenario}.out" "${temporary}/${scenario}.err"; then
    cat "${temporary}/${scenario}.out" "${temporary}/${scenario}.err" >&2
    echo "missing expected ${scenario} diagnostic: ${message}" >&2
    exit 1
  fi
}

# Only the precise GitHub absence response is accepted; legacy policies are
# manual drift even when their contexts match the declared ruleset contract.
for scenario in extra-context wrong-app approval force-push matching empty success-error; do
  assert_drift "legacy-${scenario}" 'unexpected legacy branch protection requires manual review: atrinik/observatory/main'
done
for scenario in forbidden not-found wrong-status mismatched-http transport-error wrong-exit non-json success-non-json null array; do
  assert_drift "legacy-${scenario}" 'legacy branch protection could not be read: atrinik/observatory/main'
done
for scenario in extra-context approval; do
  assert_drift "legacy-maintenance-${scenario}" 'unexpected legacy branch protection requires manual review: atrinik/observatory/release/next#candidate'
done
assert_drift legacy-maintenance-forbidden 'legacy branch protection could not be read: atrinik/observatory/release/next#candidate'
: >"${temporary}/api.log"
output=$(run_audit legacy-multiple)
grep -Fq 'Governance audit passed:' <<<"${output}"
for branch in main release%2F2.x release%2Fnext%23candidate; do
  [[ $(grep -Fxc "repos/atrinik/observatory/branches/${branch}/protection" "${temporary}/api.log") == 1 ]]
done
if grep -Fq 'foreign' "${temporary}/api.log"; then
  echo 'maintenance protection must remain scoped to its repository' >&2
  exit 1
fi

# GitHub's disabled-protection response requires independent exact-ref proof;
# historical rules on another branch must neither create drift nor prove absence.
for scenario in legacy-disabled-absent legacy-maintenance-disabled-absent; do
  output=$(run_audit "${scenario}")
  grep -Fq 'Governance audit passed:' <<<"${output}"
done
assert_drift legacy-disabled-present 'unexpected legacy branch protection requires manual review: atrinik/observatory/main'
assert_drift legacy-maintenance-disabled-present 'unexpected legacy branch protection requires manual review: atrinik/observatory/release/next#candidate'
for scenario in wrong-id wrong-owner wrong-name archived missing-field null-ref null-repository missing-data malformed-rule errors unreadable non-json inventory-id metadata-name; do
  assert_drift "legacy-disabled-${scenario}" 'legacy branch protection could not be read: atrinik/observatory/main'
done
assert_drift legacy-maintenance-disabled-wrong-name 'legacy branch protection could not be read: atrinik/observatory/release/next#candidate'

# Retained named rules remain drift after target removal, regardless of whether
# their current rules apply to main. Unrelated names remain outside ownership.
for scope in retained retired; do
  for kind in codeql dependency; do
    case ${kind} in
      codeql) name='06 - CodeQL security' ;;
      dependency) name='07 - Dependency review' ;;
    esac
    for variant in disabled moved modified duplicate foreign-owner; do
      assert_drift "${scope}-${kind}-${variant}" "unexpected retained security ruleset '${name}' requires manual review"
    done
    output=$(run_audit "${scope}-${kind}-foreign-name")
    grep -Fq 'Governance audit passed:' <<<"${output}"
  done
  output=$(run_audit "${scope}-absent")
  grep -Fq 'Governance audit passed:' <<<"${output}"
done
for variant in unreadable non-json object missing-name null-item partial-page; do
  assert_drift "retained-list-${variant}" 'inherited rulesets could not be read'
done

# Check the entire effective policy on main and exact maintenance refs. Desired
# CI, Dependency review and CodeQL coexist; API provenance is metadata only.
for branch in default maintenance; do
  for variant in baseline metadata-organization metadata-repository; do
    output=$(run_audit "closure-${branch}-${variant}")
    grep -Fq 'Governance audit passed:' <<<"${output}"
  done
  for variant in signatures deployments update unknown integrity-parameter status-parameter top-field malformed-parameters signatures-inherited; do
    assert_drift "closure-${branch}-${variant}" 'effective branch policy drift requires manual review'
  done
  for variant in missing-type null-item null-page unreadable non-json; do
    assert_drift "closure-${branch}-${variant}" "effective ${branch}-branch rules could not be read"
  done
done

assert_drift unmanaged 'active repository is not in the desired-state inventory'
assert_drift merge-drift 'repository merge policy drift'
assert_drift properties-drift 'repository custom-property drift'
assert_drift schema-drift 'organization custom-property schema drift'
assert_drift inventory-unreadable 'organization repository inventory could not be read'
assert_drift wrong-pr-scope 'effective pull-request policy drift: atrinik/.github'
assert_drift missing-tag-scope "ruleset scope or policy drift '04 - Immutable release tags': atrinik/service-updater"
assert_drift tag-ref-drift "ruleset scope or policy drift '04 - Immutable release tags'"
for scenario in tag-all-scope tag-extra-repo tag-extra-exclude tag-all-nonrelease tag-extra-nonrelease; do
  assert_drift "${scenario}" "ruleset scope or policy drift '04 - Immutable release tags'"
done
assert_drift tag-repository-nonrelease 'unexpected managed release-tag protection: atrinik/.github'
for scenario in api-required-reviewers api-extra-approval api-restricted-merges api-duplicate-merges \
  api-malformed-reviewers api-malformed-approval api-malformed-merges api-unknown-pr-field; do
  assert_drift "${scenario}" "ruleset scope or policy drift '02 - Changes through pull requests'"
done
for scenario in api-create-exemption api-malformed-create-exemption; do
  assert_drift "${scenario}" "ruleset scope or policy drift '03 - Required CI - observatory'"
done
assert_drift pr-all-scope "ruleset scope or policy drift '02 - Changes through pull requests'"
assert_drift default-extra-exclude "ruleset scope or policy drift '01 - Default branch integrity'"
assert_drift repository-scope-extra "ruleset scope or policy drift '07 - Dependency review'"
assert_drift organization-codeql-owner "managed security ruleset must be repository-owned '06 - CodeQL security'"
assert_drift organization-dependency-owner "managed security ruleset must be repository-owned '07 - Dependency review'"
assert_drift integrity-bypass "ruleset scope or policy drift '01 - Default branch integrity'"
assert_drift pr-bypass "ruleset scope or policy drift '02 - Changes through pull requests'"
assert_drift owner-id-drift "ruleset scope or policy drift '02 - Changes through pull requests'"
assert_drift pending-wrong-dependency-scope "ruleset scope or policy drift '07 - Dependency review'"
for scenario in wrong-app wrong-context strict-ci; do
  assert_drift "${scenario}" 'effective required CI contexts or app drift'
done
for scenario in approval-count thread-resolution; do
  assert_drift "${scenario}" 'effective pull-request policy drift'
done

# A queued repository needs its repository-owned queue, the exact queue
# parameters, and required CI that no longer demands a current branch.
output=$(run_audit queue-pass)
grep -Fq 'Governance audit passed:' <<<"${output}"
assert_drift queue-missing "missing or duplicate inherited ruleset '08 - Merge queue': atrinik/playtester"
assert_drift queue-missing 'effective merge queue drift: atrinik/playtester'
assert_drift queue-parameter "ruleset scope or policy drift '08 - Merge queue': atrinik/playtester"
assert_drift queue-parameter 'effective merge queue drift: atrinik/playtester'
assert_drift queue-organization-owner 'managed merge-queue ruleset must be repository-owned: atrinik/playtester'
assert_drift queue-strict 'effective required CI contexts or app drift: atrinik/playtester'
assert_drift queue-strict "ruleset scope or policy drift '03 - Required CI - playtester'"
assert_drift queue-retained 'unexpected retained merge-queue ruleset requires manual review: atrinik/observatory'
assert_drift queue-retained 'effective branch policy drift requires manual review: atrinik/observatory/main'
assert_drift effective-integrity 'effective default-branch integrity drift'
assert_drift unexpected-pr 'effective pull-request policy drift: atrinik/web-platform'
assert_drift unexpected-codeql 'unexpected effective CodeQL merge protection: atrinik/.github'
for scenario in codeql-threshold codeql-tool codeql-quality; do
  assert_drift "${scenario}" 'effective CodeQL merge protection drift'
done
for scenario in actions-write-token actions-approval; do
  assert_drift "${scenario}" 'organization Actions workflow drift'
done
for scenario in repository-write-token repository-approval; do
  assert_drift "${scenario}" 'repository Actions workflow permissions drift'
done
assert_drift repository-actions-unreadable 'repository Actions workflow permissions could not be read'
assert_drift actions-allowlist 'organization Actions selected-actions drift'
assert_drift actions-unreadable 'organization Actions permissions could not be read'
assert_drift sha-unreadable 'Actions SHA pinning state could not be read'
assert_drift sha-invalid-type 'Actions SHA pinning state could not be read'
assert_drift sha-enforced-off 'Actions SHA pinning enforcement drift'
assert_drift phase-unreadable 'Actions SHA pinning rollout phase could not be read'
assert_drift missing-rust 'CodeQL setup or required language drift: atrinik/content-toolkit'
for scenario in languages-missing languages-null languages-scalar languages-object languages-number languages-mixed; do
  assert_drift "${scenario}" 'CodeQL setup or required language drift: atrinik/observatory'
done
for scenario in advanced-setup default-setup; do
  assert_drift "${scenario}" 'CodeQL setup or required language drift'
done
for scenario in configuration-detached dependency-graph advanced-config; do
  assert_drift "${scenario}" 'security configuration attachment or baseline drift'
done
assert_drift configuration-unreadable 'security configuration could not be read'
assert_drift setup-unreadable 'CodeQL setup could not be read'
assert_drift dependabot-alerts 'Dependabot alerts disabled or unreadable'
assert_drift private-reporting 'private vulnerability reporting disabled or unreadable'
assert_drift secret-baseline 'exposed security baseline drift'
assert_drift effective-unreadable 'effective default-branch rules could not be read'
assert_drift ruleset-unreadable 'ruleset contents could not be read'
for scenario in enforced-missing-dependency enforced-unreadable-dependency; do
  assert_drift "${scenario}" 'effective required CI contexts or app drift'
  [[ ! -s ${temporary}/${scenario}.readiness-log ]]
  if grep -Fq 'PENDING Dependency review' "${temporary}/${scenario}.out"; then
    echo 'enforced dependency protection must never fall back to pending' >&2
    exit 1
  fi
done
for scenario in enforced-missing-codeql enforced-unreadable-codeql; do
  assert_drift "${scenario}" 'effective CodeQL merge protection drift'
  [[ ! -s ${temporary}/${scenario}.readiness-log ]]
  if grep -Fq 'PENDING CodeQL' "${temporary}/${scenario}.out"; then
    echo 'enforced CodeQL protection must never fall back to pending' >&2
    exit 1
  fi
done
for scenario in ready-missing ready-missing-codeql; do
  output=$(run_audit "${scenario}")
  grep -Fq 'merge protection awaits reviewed activation intent' <<<"${output}"
  grep -Fq 'Governance audit baseline passed with' <<<"${output}"
done
assert_drift dependency-readiness-unreadable 'Dependency review readiness could not be read'
assert_drift codeql-readiness-unreadable 'CodeQL readiness could not be read'
output=$(run_audit pending-codeql)
grep -Fq 'PENDING CodeQL merge protection awaits successful analysis' <<<"${output}"
grep -Fq 'Governance audit baseline passed with' <<<"${output}"
# An existing dependency gate survives a temporarily unreadable producer readiness
# API; read readiness is required only when first installing the context.
output=$(run_audit readiness-unreadable)
grep -Fq 'Governance audit passed:' <<<"${output}"

if grep -Eq '^repos/atrinik/(legacy-|nawerhals)' "${temporary}/api.log"; then
  echo 'audit must not inspect archived repositories' >&2
  exit 1
fi
echo 'Governance effective-policy audit tests passed.'
