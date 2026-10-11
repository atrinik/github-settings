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
case ${GH_TEST_SCENARIO:-pass} in
  pending|pending-codeql|pending-wrong-dependency-scope) exit 1 ;;
  readiness-unreadable|dependency-readiness-unreadable|codeql-readiness-unreadable) exit 2 ;;
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
for repository in .github classic observatory content-toolkit service-updater web-platform; do
  fixture="${temporary}/fixture-${repository}"
  cp -R "${temporary}/full" "${fixture}"
  jq --arg repository "${repository}" \
    '.repositories |= with_entries(select(.key == $repository))' \
    "${temporary}/full/config/repository-properties.json" >"${fixture}/config/repository-properties.json"
done

run_audit() {
  local scenario=$1 fixture=${2:-focused} repository=observatory
  if [[ ${fixture} == focused ]]; then
    case ${scenario} in
      wrong-pr-scope|unexpected-codeql|tag-extra-nonrelease|tag-all-nonrelease|tag-repository-nonrelease|inherited-tag-unaffected|foreign-tag) repository=.github ;;
      advanced-config|advanced-setup) repository=classic ;;
      missing-rust) repository=content-toolkit ;;
      missing-tag-scope|tag-ref-drift|tag-all-scope|tag-extra-repo|tag-extra-exclude) repository=service-updater ;;
      unexpected-pr) repository=web-platform ;;
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
  GH_TEST_SCENARIO=${scenario} \
    PATH="${temporary}/mock:${PATH}" \
    AUDIT_CONFIG_ROOT="${temporary}/${fixture}" \
    AUDIT_API_LOG="${temporary}/api.log" \
    "${temporary}/${fixture}/bin/audit"
}

output=$(run_audit pass full)
grep -Fxq 'Governance audit passed: 23 active repositories checked.' <<<"${output}"
output=$(run_audit temporary full)
grep -Fxq 'Governance audit passed: 23 active repositories checked.' <<<"${output}"
output=$(run_audit legacy-security)
grep -Fq 'Governance audit passed:' <<<"${output}"
output=$(run_audit repository-rulesets)
grep -Fq 'Governance audit passed:' <<<"${output}"
for scenario in scope-order inherited-tag-unaffected foreign-tag sha-enforced-on; do
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
assert_drift ready-missing 'effective required CI contexts or app drift'
assert_drift ready-missing-codeql 'effective CodeQL merge protection drift'
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
