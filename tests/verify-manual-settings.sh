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
while (($#)); do
  case $1 in
  -H)
    shift 2
    ;;
  -f | -F)
    shift 2
    ;;
  *)
    if [[ -n ${endpoint} ]]; then
      echo "unexpected gh api argument: $1" >&2
      exit 1
    fi
    endpoint=$1
    shift
    ;;
  esac
done
printf '%s\n' "${endpoint}" >>"${FAKE_GH_LOG}"

if [[ ${FAKE_GH_SCENARIO} == api-failure ]]; then
  echo "gh: repository administration denied" >&2
  exit 41
fi
case ${endpoint} in
graphql)
  if [[ ${FAKE_GH_SCENARIO} == malformed-pins ]]; then
    jq -n '{data: {organization: {login: "atrinik", pinnedItems: {nodes: []}}}}'
  elif [[ ${FAKE_GH_SCENARIO} == pin-drift ]]; then
    jq -n '{data: {organization: {
      login: "atrinik",
      pinnedItems: {
        totalCount: 2,
        nodes: [
          {name: "atrinik", databaseId: 15810595, nameWithOwner: "atrinik/atrinik", isArchived: false, visibility: "PUBLIC"},
          {name: "classic", databaseId: 1327289971, nameWithOwner: "atrinik/classic", isArchived: false, visibility: "PUBLIC"}
        ]
      }
    }}}'
  else
    jq -n '{data: {organization: {
      login: "atrinik",
      pinnedItems: {
        totalCount: 6,
        nodes: [
          {name: "classic", databaseId: 1327289971, nameWithOwner: "atrinik/classic", isArchived: false, visibility: "PUBLIC"},
          {name: "atrinik", databaseId: 15810595, nameWithOwner: "atrinik/atrinik", isArchived: false, visibility: "PUBLIC"},
          {name: "website", databaseId: 1327107093, nameWithOwner: "atrinik/website", isArchived: false, visibility: "PUBLIC"},
          {name: "content", databaseId: 1325219730, nameWithOwner: "atrinik/content", isArchived: false, visibility: "PUBLIC"},
          {name: "protocol", databaseId: 1327106950, nameWithOwner: "atrinik/protocol", isArchived: false, visibility: "PUBLIC"},
          {name: "playtester", databaseId: 1329284051, nameWithOwner: "atrinik/playtester", isArchived: false, visibility: "PUBLIC"}
        ]
      }
    }}}'
  fi
  ;;
repos/atrinik/protocol)
  repository_id=1327106950
  if [[ ${FAKE_GH_SCENARIO} == crate-repository-drift ]]; then
    repository_id=1
  fi
  jq -n --argjson id "${repository_id}" \
    '{id: $id, full_name: "atrinik/protocol", archived: false, default_branch: "main"}'
  ;;
repos/atrinik/renderer | repos/atrinik/content-toolkit | repos/atrinik/client | repos/atrinik/editor)
  name=${endpoint##*/}
  case ${name} in
  renderer) id=1327106998 ;;
  content-toolkit) id=1327107043 ;;
  client) id=1327106844 ;;
  editor) id=1327106902 ;;
  esac
  jq -n --arg name "${name}" --argjson id "${id}" \
    '{id:$id, full_name:("atrinik/"+$name), archived:false, default_branch:"main"}'
  ;;
repos/atrinik/*/branches/main)
  protected=true
  [[ ${FAKE_GH_SCENARIO} != crate-unprotected ]] || protected=false
  jq -n --argjson protected "${protected}" \
    '{name:"main",protected:$protected,commit:{sha:"1111111111111111111111111111111111111111"}}'
  ;;
repos/atrinik/*/git/ref/heads/main)
  sha=1111111111111111111111111111111111111111
  [[ ${FAKE_GH_SCENARIO} != crate-ref-drift ]] || sha=2222222222222222222222222222222222222222
  jq -n --arg sha "${sha}" '{ref:"refs/heads/main",object:{type:"commit",sha:$sha}}'
  ;;
repos/atrinik/protocol/contents/.github/workflows/publish-crate.yml\?ref=*)
  source=$(cat <<'WORKFLOW'
on:
  workflow_dispatch:
    inputs:
      operation:
        type: choice
        options: [automatic]
permissions:
  contents: read
jobs:
  automatic-verify:
    if: github.repository == 'atrinik/protocol' && github.repository_id == '1327106950' && github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch' && inputs.operation == 'automatic'
    runs-on: ubuntu-24.04
    env:
      SOURCE_RELEASE_ID: ${{ inputs.source_release_id }}
      SOURCE_REVISION: ${{ inputs.source_revision }}
      MANIFEST_SHA256: ${{ inputs.manifest_sha256 }}
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
        with:
          ref: ${{ github.sha }}
          persist-credentials: false
      - run: python3 tools/crate_release.py verify --release-id "$SOURCE_RELEASE_ID" --revision "$SOURCE_REVISION" --manifest-sha256 "$MANIFEST_SHA256"
  automatic-publish:
    needs: automatic-verify
    if: github.repository == 'atrinik/protocol' && github.repository_id == '1327106950' && github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch' && inputs.operation == 'automatic'
    environment: crates-io-release
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write
    env:
      SOURCE_RELEASE_ID: ${{ inputs.source_release_id }}
      SOURCE_REVISION: ${{ inputs.source_revision }}
      MANIFEST_SHA256: ${{ inputs.manifest_sha256 }}
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
        with:
          ref: ${{ github.sha }}
          persist-credentials: false
      - run: python3 tools/crate_release.py verify --release-id "$SOURCE_RELEASE_ID" --revision "$SOURCE_REVISION" --manifest-sha256 "$MANIFEST_SHA256"
      - id: auth
        uses: rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18
      - id: upload
        env:
          CARGO_REGISTRY_TOKEN: ${{ steps.auth.outputs.token }}
        run: python3 tools/crate_release.py upload --release-id "$SOURCE_RELEASE_ID" --revision "$SOURCE_REVISION" --manifest-sha256 "$MANIFEST_SHA256"
WORKFLOW
)
  case ${FAKE_GH_SCENARIO} in
  crate-workflow-drift) source=${source//rust-lang\/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18/rust-lang\/crates-io-auth-action@v1} ;;
  crate-workflow-future-pin) source=${source//c6f97d42243bad5fab37ca0427f495c86d5b1a18/2222222222222222222222222222222222222222} ;;
  crate-workflow-plaintext) source='crates-io-release refs/heads/main automatic rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18' ;;
  crate-workflow-comments) source="# crates-io-release refs/heads/main automatic rust-lang/crates-io-auth-action@c6f97d42243bad5fab37ca0427f495c86d5b1a18" ;;
  crate-workflow-disabled) source=${source//inputs.operation == \'automatic\'/false} ;;
  crate-workflow-no-oidc) source=${source//id-token: write/id-token: none} ;;
  crate-workflow-shell) source=$(sed '/- run: python3 tools\/crate_release.py verify/a\        shell: echo {0}' <<<"${source}") ;;
  crate-workflow-ignored-step-failure) source=$(sed '/- run: python3 tools\/crate_release.py verify/a\        continue-on-error: true' <<<"${source}") ;;
  crate-workflow-ignored-job-failure) source=$(sed '/    runs-on: ubuntu-24.04/a\    continue-on-error: true' <<<"${source}") ;;
  crate-workflow-default-shell) source=$(printf 'defaults:\n  run:\n    shell: echo {0}\n%s\n' "${source}") ;;
  crate-workflow-job-default-shell) source=$(sed '/    runs-on: ubuntu-24.04/a\    defaults:\n      run:\n        shell: echo {0}' <<<"${source}") ;;
  crate-workflow-comment-run) source=${source//run: python3/run: \"# python3}; source=${source//\"\$DIGEST\"/\"\$DIGEST\"\"} ;;
  esac
  jq -n --arg content "$(printf '%s' "${source}" | base64)" \
    '{type:"file",encoding:"base64",content:$content}'
  ;;
repos/atrinik/protocol/environments/crates-io-release)
  rules='[{"type":"branch_policy"}]'
  bypass=false
  [[ ${FAKE_GH_SCENARIO} != crate-env-wait ]] || rules='[{"type":"branch_policy"},{"type":"wait_timer","wait_timer":1}]'
  [[ ${FAKE_GH_SCENARIO} != crate-env-reviewer ]] || rules='[{"type":"branch_policy"},{"type":"required_reviewers","reviewers":[{"type":"User","reviewer":{"id":3865595}}]}]'
  [[ ${FAKE_GH_SCENARIO} != crate-env-bypass ]] || bypass=true
  jq -n --argjson rules "${rules}" --argjson bypass "${bypass}" \
    '{name:"crates-io-release",can_admins_bypass:$bypass,protection_rules:$rules,
      deployment_branch_policy:{protected_branches:false,custom_branch_policies:true}}'
  ;;
"repos/atrinik/protocol/environments/crates-io-release/deployment-branch-policies?per_page=100&page=1")
  name=main
  [[ ${FAKE_GH_SCENARIO} != crate-env-branch ]] || name='*'
  jq -n --arg name "${name}" '{total_count:1,branch_policies:[{name:$name,type:"branch"}]}'
  ;;
"repos/atrinik/protocol/environments/crates-io-release/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == crate-env-secret ]]; then
    jq -n '{total_count:1,secrets:[{name:"CARGO_REGISTRY_TOKEN"}]}'
  else
    jq -n '{total_count:0,secrets:[]}'
  fi
  ;;
"repos/atrinik/protocol/environments/crates-io-release/variables?per_page=100&page=1")
  jq -n '{total_count:0,variables:[]}'
  ;;
"repos/atrinik/client/actions/secrets?per_page=100&page=1" | "repos/atrinik/editor/actions/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == updater-missing-secret ]]; then
    jq -n '{total_count:0,secrets:[]}'
  else
    jq -n '{total_count:1,secrets:[{name:"CRATE_DEPENDENCY_UPDATE_APP_PRIVATE_KEY",updated_at:"2026-08-31T00:00:00Z"}]}'
  fi
  ;;
"repos/atrinik/client/actions/variables?per_page=100&page=1" | "repos/atrinik/editor/actions/variables?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == updater-missing-variable ]]; then
    jq -n '{total_count:0,variables:[]}'
  else
    jq -n '{total_count:1,variables:[{name:"CRATE_DEPENDENCY_UPDATE_APP_ID",created_at:"2026-08-31T00:00:00Z",updated_at:"2026-08-31T00:00:00Z"}]}'
  fi
  ;;
repos/atrinik/github-settings)
  if [[ ${FAKE_GH_SCENARIO} == identity-drift ]]; then
    jq -n '{
      id: 1,
      full_name: "atrinik/github-settings",
      archived: false,
      default_branch: "main"
    }'
  else
    jq -n '{
      id: 1324382941,
      full_name: "atrinik/github-settings",
      archived: false,
      default_branch: "main"
    }'
  fi
  ;;
repos/atrinik/deploy-control)
  repository_id=1352850539
  repository_visibility=public
  repository_license=MIT
  if [[ ${FAKE_GH_SCENARIO} == planned-control-identity-drift ]]; then
    repository_id=1
  fi
  if [[ ${FAKE_GH_SCENARIO} == planned-control-license-drift ]]; then
    repository_license=GPL-2.0
  fi
  jq -n \
    --argjson repository_id "${repository_id}" \
    --arg repository_visibility "${repository_visibility}" \
    --arg repository_license "${repository_license}" '{
    id: $repository_id,
    full_name: "atrinik/deploy-control",
    archived: false,
    default_branch: "main",
    visibility: $repository_visibility,
    license: {spdx_id: $repository_license}
  }'
  ;;
repos/atrinik/website)
  repository_id=1327107093
  if [[ ${FAKE_GH_SCENARIO} == external-website-identity-drift ]]; then
    repository_id=1
  fi
  jq -n --argjson repository_id "${repository_id}" '{
    id: $repository_id,
    full_name: "atrinik/website",
    archived: false,
    default_branch: "main"
  }'
  ;;
repos/atrinik/metaserver-worker)
  repository_id=1324297032
  if [[ ${FAKE_GH_SCENARIO} == external-metaserver-identity-drift ]]; then
    repository_id=1
  fi
  jq -n --argjson repository_id "${repository_id}" '{
    id: $repository_id,
    full_name: "atrinik/metaserver-worker",
    archived: false,
    default_branch: "main"
  }'
  ;;
repos/atrinik/classic)
  if [[ ${FAKE_GH_SCENARIO} == environment-identity-drift ]]; then
    jq -n '{
      id: 1,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-repository-name-drift ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/renamed-classic",
      archived: false,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-archived ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: true,
      default_branch: "main"
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-default-branch-drift ]]; then
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "trunk"
    }'
  else
    jq -n '{
      id: 1327289971,
      full_name: "atrinik/classic",
      archived: false,
      default_branch: "main"
    }'
  fi
  ;;
repos/atrinik/classic/pages)
  build_type=legacy
  html_url=https://atrinik.github.io/classic/
  source='{"branch":"main","path":"/"}'
  if [[ ${FAKE_GH_SCENARIO} == pages-active ]]; then
    build_type=workflow
    source=null
  elif [[ ${FAKE_GH_SCENARIO} == pages-source-drift ]]; then
    source='{"branch":"development","path":"/"}'
  elif [[ ${FAKE_GH_SCENARIO} == pages-identity-drift ]]; then
    html_url=https://example.test/classic/
  fi
  jq -n \
    --arg build_type "${build_type}" \
    --arg html_url "${html_url}" \
    --argjson source "${source}" \
    '{html_url: $html_url, build_type: $build_type, source: $source,
      public: true, https_enforced: true, cname: null}'
  ;;
"repos/atrinik/classic/contents/.github/workflows/daily-client-performance.yml?ref=main")
  workflow='name: Daily Classic client performance'
  if [[ ${FAKE_GH_SCENARIO} == pages-active ||
    ${FAKE_GH_SCENARIO} == pages-activation-missing ]]; then
    workflow='uses: actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e'
  fi
  if [[ ${FAKE_GH_SCENARIO} == pages-workflow-metadata-drift ]]; then
    jq -n '{type: "dir", encoding: "none", content: null}'
  else
    content=$(printf '%s\n' "${workflow}" | base64 -w0)
    jq -n --arg content "${content}" \
      '{type: "file", encoding: "base64", content: $content}'
  fi
  ;;
"orgs/atrinik/installations?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == app-api-failure ]]; then
    echo "gh: organization installation administration denied" >&2
    exit 45
  elif [[ ${FAKE_GH_SCENARIO} == malformed-app-installations ]]; then
    jq -n '{total_count: 1, installation: []}'
  elif [[ ${FAKE_GH_SCENARIO} == app-installations-page2 || \
    ${FAKE_GH_SCENARIO} == app-installations-page2-failure ]]; then
    jq -n '{
      total_count: 103,
      installations: [range(0; 100) | {
        id: (1000 + .),
        app_id: (2000 + .),
        app_slug: ("unrelated-" + tostring),
        target_type: "Organization",
        account: {login: "atrinik", type: "Organization"},
        repository_selection: "selected",
        permissions: {metadata: "read"},
        events: [],
        suspended_at: null
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == missing-app ]]; then
    jq -n '{
      total_count: 1,
      installations: [{
        id: 152311798,
        app_id: 85455,
        app_slug: "cloudflare-workers-and-pages",
        target_type: "Organization",
        account: {login: "atrinik", type: "Organization"},
        repository_selection: "selected",
        permissions: {
          administration: "write",
          checks: "write",
          contents: "write",
          deployments: "write",
          metadata: "read",
          pull_requests: "write"
        },
        events: ["pull_request", "push"],
        suspended_at: null
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == missing-external-app ]]; then
    jq -n '{total_count: 0, installations: []}'
  else
    app_id=4564008
    installation_id=153045686
    app_slug=atrinik-classic-dependency-updater
    repository_selection=selected
    account_login=atrinik
    events='[]'
    permissions='{"contents":"write","metadata":"read","pull_requests":"write"}'
    suspended_at=null
    case ${FAKE_GH_SCENARIO} in
    app-id-drift) app_id=1 ;;
    app-installation-id-drift) installation_id=1 ;;
    app-slug-drift) app_slug=other-app ;;
    app-selection-drift) repository_selection=all ;;
    app-account-drift) account_login=other ;;
    app-events-drift) events='["push"]' ;;
    app-permission-drift) permissions='{"actions":"write","contents":"write","metadata":"read","pull_requests":"write"}' ;;
    app-suspended) suspended_at='"2026-08-11T00:00:00Z"' ;;
    esac
    external_app_id=85455
    external_installation_id=152311798
    external_app_slug=cloudflare-workers-and-pages
    external_repository_selection=selected
    external_events='["pull_request","push"]'
    external_permissions='{"administration":"write","checks":"write","contents":"write","deployments":"write","metadata":"read","pull_requests":"write"}'
    external_suspended_at=null
    case ${FAKE_GH_SCENARIO} in
    external-app-id-drift) external_app_id=1 ;;
    external-app-installation-id-drift) external_installation_id=1 ;;
    external-app-slug-drift) external_app_slug=other-app ;;
    external-app-selection-drift) external_repository_selection=all ;;
    external-app-events-drift) external_events='["push"]' ;;
    external-app-permission-drift) external_permissions='{"checks":"write","contents":"write","deployments":"write","metadata":"read","pull_requests":"write"}' ;;
    external-app-suspended) external_suspended_at='"2026-08-15T00:00:00Z"' ;;
    esac
    updater_installed=true
    [[ ${FAKE_GH_SCENARIO} != updater-missing ]] || updater_installed=false
    updater_permissions='{"contents":"write","metadata":"read","pull_requests":"write"}'
    [[ ${FAKE_GH_SCENARIO} != updater-permissions ]] || updater_permissions='{"contents":"write","metadata":"read","pull_requests":"write","administration":"write"}'
    updater_selection=selected
    [[ ${FAKE_GH_SCENARIO} != updater-selection ]] || updater_selection=all
    planned_control=false
    [[ ${FAKE_GH_SCENARIO} == planned-control-installed ]] && planned_control=true
    jq -n \
      --argjson app_id "${app_id}" \
      --argjson installation_id "${installation_id}" \
      --arg app_slug "${app_slug}" \
      --arg repository_selection "${repository_selection}" \
      --arg account_login "${account_login}" \
      --argjson events "${events}" \
      --argjson permissions "${permissions}" \
      --argjson suspended_at "${suspended_at}" \
      --argjson external_app_id "${external_app_id}" \
      --argjson external_installation_id "${external_installation_id}" \
      --arg external_app_slug "${external_app_slug}" \
      --arg external_repository_selection "${external_repository_selection}" \
      --argjson external_events "${external_events}" \
      --argjson external_permissions "${external_permissions}" \
      --argjson external_suspended_at "${external_suspended_at}" \
      --argjson updater_installed "${updater_installed}" \
      --argjson updater_permissions "${updater_permissions}" \
      --arg updater_selection "${updater_selection}" \
      --argjson planned_control "${planned_control}" '(
        [{
          id: $installation_id,
          app_id: $app_id,
          app_slug: $app_slug,
          target_type: "Organization",
          account: {login: $account_login, type: "Organization"},
          repository_selection: $repository_selection,
          permissions: $permissions,
          events: $events,
          suspended_at: $suspended_at
        }, {
          id: $external_installation_id,
          app_id: $external_app_id,
          app_slug: $external_app_slug,
          target_type: "Organization",
          account: {login: "atrinik", type: "Organization"},
          repository_selection: $external_repository_selection,
          permissions: $external_permissions,
          events: $external_events,
          suspended_at: $external_suspended_at
        }] + (if $planned_control then [{
          id: 154000001,
          app_id: 85500001,
          app_slug: "atrinik-deploy-control",
          target_type: "Organization",
          account: {login: "atrinik", type: "Organization"},
          repository_selection: "selected",
          permissions: {actions: "read", metadata: "read"},
          events: ["workflow_run"],
          suspended_at: null
        }] else [] end)
        + (if $updater_installed then [{
          id:170332148, app_id:5276152, app_slug:"atrinik-crate-dependency-update",
          target_type:"Organization",account:{login:"atrinik",type:"Organization"},
          repository_selection:$updater_selection,permissions:$updater_permissions,
          events:[],suspended_at:null
        }] else [] end)
      ) as $installations |
      {total_count: ($installations | length), installations: $installations}'
  fi
  ;;
"orgs/atrinik/installations?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == app-installations-page2-failure ]]; then
    echo "gh: second installation page failed" >&2
    exit 47
  fi
  [[ ${FAKE_GH_SCENARIO} == app-installations-page2 ]]
  jq -n '{
    total_count: 103,
    installations: [{
      id: 153045686,
      app_id: 4564008,
      app_slug: "atrinik-classic-dependency-updater",
      target_type: "Organization",
      account: {login: "atrinik", type: "Organization"},
      repository_selection: "selected",
      permissions: {
        contents: "write",
        metadata: "read",
        pull_requests: "write"
      },
      events: [],
      suspended_at: null
    }, {
      id: 152311798,
      app_id: 85455,
      app_slug: "cloudflare-workers-and-pages",
      target_type: "Organization",
      account: {login: "atrinik", type: "Organization"},
      repository_selection: "selected",
      permissions: {
        administration: "write",
        checks: "write",
        contents: "write",
        deployments: "write",
        metadata: "read",
        pull_requests: "write"
      },
      events: ["pull_request", "push"],
      suspended_at: null
    }, {
      id:170332148, app_id:5276152, app_slug:"atrinik-crate-dependency-update",
      target_type:"Organization",account:{login:"atrinik",type:"Organization"},
      repository_selection:"selected",
      permissions:{contents:"write",metadata:"read",pull_requests:"write"},
      events:[],suspended_at:null
    }]
  }'
  ;;
"repos/atrinik/classic/actions/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing-app-secret ]]; then
    jq -n '{total_count: 0, secrets: []}'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "DEPENDENCY_UPDATE_APP_PRIVATE_KEY",
        created_at: "2026-08-11T23:47:15Z",
        updated_at: "2026-08-11T23:47:15Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/classic/actions/variables?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == app-variable-api-failure ]]; then
    echo "gh: Actions variable administration denied" >&2
    exit 46
  elif [[ ${FAKE_GH_SCENARIO} == malformed-app-variables ]]; then
    jq -n '{total_count: 1, variable: []}'
  elif [[ ${FAKE_GH_SCENARIO} == missing-app-variable ]]; then
    jq -n '{total_count: 0, variables: []}'
  else
    jq -n '{
      total_count: 1,
      variables: [{
        name: "DEPENDENCY_UPDATE_APP_ID",
        value: "not-inspected-by-the-verifier",
        created_at: "2026-08-11T23:47:00Z",
        updated_at: "2026-08-11T23:47:00Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing ]]; then
    jq -n '{total_count: 0, secrets: []}'
  elif [[ ${FAKE_GH_SCENARIO} == page2 || \
    ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    jq -n '{
      total_count: 101,
      secrets: [range(0; 100) | {
        name: ("UNRELATED_" + tostring),
        created_at: "2026-08-01T00:00:00Z",
        updated_at: "2026-08-01T00:00:00Z"
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == shared-repository ]]; then
    jq -n '{
      total_count: 2,
      secrets: [
        {
          name: "ATRINIK_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        },
        {
          name: "SECOND_SETTINGS_TOKEN",
          created_at: "2026-08-10T02:13:48Z",
          updated_at: "2026-08-10T02:13:48Z"
        }
      ]
    }'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "ATRINIK_SETTINGS_TOKEN",
        created_at: "2026-08-10T02:13:48Z",
        updated_at: "2026-08-10T02:13:48Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/github-settings/actions/secrets?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == page2-failure ]]; then
    echo "gh: second secret page failed" >&2
    exit 42
  fi
  [[ ${FAKE_GH_SCENARIO} == page2 ]]
  jq -n '{
    total_count: 101,
    secrets: [{
      name: "ATRINIK_SETTINGS_TOKEN",
      created_at: "2026-08-10T02:13:48Z",
      updated_at: "2026-08-10T02:13:48Z"
    }]
  }'
  ;;
repos/atrinik/classic/environments/discord-release)
  if [[ ${FAKE_GH_SCENARIO} == missing-environment ]]; then
    echo "gh: environment not found" >&2
    exit 43
  elif [[ ${FAKE_GH_SCENARIO} == environment-name-drift ]]; then
    jq -n '{
      name: "other-environment",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == branch-mode-drift ]]; then
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: true,
        custom_branch_policies: false
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == extra-reviewer ]]; then
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{
        type: "required_reviewers",
        reviewers: [{type: "User", reviewer: {id: 1, login: "reviewer"}}]
      }, {type: "branch_policy"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == wait-timer ||
    ${FAKE_GH_SCENARIO} == custom-protection-rule ]]; then
    rule_type=wait_timer
    if [[ ${FAKE_GH_SCENARIO} == custom-protection-rule ]]; then
      rule_type=custom_deployment_protection_rule
    fi
    jq -n --arg rule_type "${rule_type}" '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}, {type: $rule_type}]
    }'
  else
    jq -n '{
      name: "discord-release",
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: true
      },
      protection_rules: [{type: "branch_policy"}]
    }'
  fi
  ;;
repos/atrinik/classic/environments/github-pages)
  jq -n '{
    name: "github-pages",
    deployment_branch_policy: {
      protected_branches: false,
      custom_branch_policies: true
    },
    protection_rules: [{type: "branch_policy"}]
  }'
  ;;
"repos/atrinik/classic/environments/discord-release/deployment-branch-policies?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == branch-policy-drift ]]; then
    jq -n '{
      total_count: 1,
      branch_policies: [{id: 1, name: "release", type: "branch"}]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == environment-page2 ||
    ${FAKE_GH_SCENARIO} == environment-page2-failure ]]; then
    jq -n '{
      total_count: 101,
      branch_policies: [range(0; 100) | {
        id: ., name: ("branch-" + tostring), type: "branch"
      }]
    }'
  elif [[ ${FAKE_GH_SCENARIO} == malformed-branch-policy-response ]]; then
    jq -n '{total_count: 1, branch_policy: []}'
  else
    jq -n '{
      total_count: 2,
      branch_policies: [
        {id: 1, name: "main", type: "branch"},
        {id: 2, name: "v*", type: "tag"}
      ]
    }'
  fi
  ;;
"repos/atrinik/classic/environments/discord-release/deployment-branch-policies?per_page=100&page=2")
  if [[ ${FAKE_GH_SCENARIO} == environment-page2-failure ]]; then
    echo "gh: second environment branch-policy page failed" >&2
    exit 44
  fi
  [[ ${FAKE_GH_SCENARIO} == environment-page2 ]]
  jq -n '{
    total_count: 101,
    branch_policies: [{id: 101, name: "main", type: "branch"}]
  }'
  ;;
"repos/atrinik/classic/environments/discord-release/secrets?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == missing-environment-secret ]]; then
    jq -n '{total_count: 0, secrets: []}'
  else
    jq -n '{
      total_count: 1,
      secrets: [{
        name: "DISCORD_APPLICATION_ID",
        created_at: "2026-08-10T00:00:00Z",
        updated_at: "2026-08-10T00:00:00Z"
      }]
    }'
  fi
  ;;
"repos/atrinik/classic/environments/discord-release/variables?per_page=100&page=1")
  if [[ ${FAKE_GH_SCENARIO} == extra-environment-variable ]]; then
    jq -n '{
      total_count: 1,
      variables: [{name: "UNEXPECTED", created_at: "2026-08-10T00:00:00Z"}]
    }'
  else
    jq -n '{total_count: 0, variables: []}'
  fi
  ;;
"repos/atrinik/classic/environments/github-pages/deployment-branch-policies?per_page=100&page=1")
  jq -n '{
    total_count: 1,
    branch_policies: [{id: 3, name: "main", type: "branch"}]
  }'
  ;;
"repos/atrinik/classic/environments/github-pages/secrets?per_page=100&page=1")
  jq -n '{total_count: 0, secrets: []}'
  ;;
"repos/atrinik/classic/environments/github-pages/variables?per_page=100&page=1")
  jq -n '{total_count: 0, variables: []}'
  ;;
*) exit 1 ;;
esac
EOF
chmod +x "${temporary}/bin/gh"

run_verify() {
  local scenario=$1
  local verification_root=${2:-${root}}

  PATH="${temporary}/bin:${PATH}" \
    FAKE_GH_LOG="${temporary}/gh.log" \
    FAKE_GH_SCENARIO="${scenario}" \
    GITHUB_ACTIONS=true GH_TOKEN=test-token \
    ATRINIK_VALIDATION_TODAY=2026-10-11 \
    "${verification_root}/bin/verify-manual-settings"
}

: >"${temporary}/gh.log"
output=$(run_verify present)
grep -Fq 'PENDING atrinik/protocol crates.io atrinik-protocol via publish-crate.yml / crates-io-release' <<<"${output}"
if grep -Eq 'protocol/environments|crates.io|/trusted-publishers' "${temporary}/gh.log"; then
  echo "error: planned crate contract inspected or mutated unprovisioned state" >&2
  exit 1
fi
for scenario in crate-repository-drift crate-unprotected crate-ref-drift; do
  if run_verify "${scenario}" >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: verifier accepted ${scenario}" >&2
    exit 1
  fi
done
observed_root=${temporary}/observed-crate
mkdir -p "${observed_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" "${observed_root}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${root}/lib" "${observed_root}/"
jq '.crates_io_trusted_publishing[0] |= (
  .source_state = "observed-reviewed-workflow" | .environment_state = "observed" |
  .publisher_registration = {state:"owner-observed-registration",observed_on:"2026-08-31",
    evidence_location:"atrinik/github-settings#owner-setup"})' "${root}/config/manual-settings.json" \
  >"${observed_root}/config/manual-settings.json"
observed_output=$(run_verify present "${observed_root}")
future_output=$(run_verify crate-workflow-future-pin "${observed_root}")
grep -Fq "immutable auth action rust-lang/crates-io-auth-action@2222222222222222222222222222222222222222" <<<"${future_output}"
grep -Fq 'KEEP atrinik/protocol environment crates-io-release metadata' <<<"${observed_output}"
grep -Fq 'GitHub metadata does not verify external registration' <<<"${observed_output}"
for scenario in crate-workflow-drift crate-env-wait crate-env-reviewer crate-env-bypass \
  crate-env-branch crate-env-secret crate-workflow-comments crate-workflow-plaintext \
  crate-workflow-disabled crate-workflow-no-oidc crate-workflow-shell \
  crate-workflow-ignored-step-failure crate-workflow-ignored-job-failure \
  crate-workflow-default-shell crate-workflow-job-default-shell; do
  if run_verify "${scenario}" "${observed_root}" >"${temporary}/${scenario}.out" \
    2>"${temporary}/${scenario}.err"; then
    echo "error: verifier accepted ${scenario}" >&2
    exit 1
  fi
done

planned_updater_root=${temporary}/planned-updater
mkdir -p "${planned_updater_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" "${planned_updater_root}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${planned_updater_root}/"
jq '.crate_dependency_update_app |= (.status="planned" | .app_id=null | .installation_id=null |
  .repository_scope_verification="pending-owner-ui" | .observed_on=null | .evidence_location=null |
  .credential_state="pending-name-metadata")' "${root}/config/manual-settings.json" \
  >"${planned_updater_root}/config/manual-settings.json"
if run_verify updater-present "${planned_updater_root}" >"${temporary}/updater-planned.out" 2>"${temporary}/updater-planned.err"; then
  echo "error: pending App accepted an unrecorded live installation" >&2
  exit 1
fi
updater_root=${temporary}/observed-updater
mkdir -p "${updater_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" "${updater_root}/bin/"
cp -R "${root}/config" "${root}/community-health" "${root}/.github" "${updater_root}/"
jq '.crate_dependency_update_app |= (.status="owner-observed" | .app_id=5276152 |
  .installation_id=170332148 | .repository_scope_verification="organization_owner_ui" |
  .observed_on="2026-08-31" | .evidence_location="atrinik/github-settings#owner-app")' \
  "${root}/config/manual-settings.json" >"${updater_root}/config/manual-settings.json"
updater_output=$(run_verify updater-present "${updater_root}")
grep -Fq 'KEEP atrinik/client crate dependency App credential name metadata' <<<"${updater_output}"
grep -Fq 'KEEP atrinik/editor crate dependency App credential name metadata' <<<"${updater_output}"
grep -Fq 'selected repositories require current owner UI or App-authenticated API proof: atrinik/client and atrinik/editor only' <<<"${updater_output}"
for scenario in updater-missing updater-permissions updater-selection updater-missing-secret updater-missing-variable; do
  if run_verify "${scenario}" "${updater_root}" >"${temporary}/updater-${scenario}.out" \
    2>"${temporary}/updater-${scenario}.err"; then
    echo "error: verifier accepted observed updater ${scenario}" >&2
    exit 1
  fi
done

grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'KEEP atrinik/classic environment discord-release metadata' <<<"${output}"
grep -Fq 'PENDING atrinik/classic Pages remains on the exact legacy main-root source' \
  <<<"${output}"
grep -Fq 'KEEP atrinik/classic environment github-pages metadata' <<<"${output}"
grep -Fq 'KEEP cloudflare-workers-and-pages installation metadata and exact permissions/events' \
  <<<"${output}"
grep -Fq 'MANUAL cloudflare-workers-and-pages selected repositories require owner UI proof: atrinik/website and atrinik/metaserver-worker only' \
  <<<"${output}"
grep -Fq 'PENDING atrinik-deploy-control GitHub App installation and credentials; owner UI proof is required for atrinik/deploy-control and selected repository atrinik/classic only' \
  <<<"${output}"
grep -Fq 'KEEP atrinik-classic-dependency-updater installation metadata and exact permissions' \
  <<<"${output}"
grep -Fq 'KEEP atrinik/classic repository Actions secret DEPENDENCY_UPDATE_APP_PRIVATE_KEY' \
  <<<"${output}"
grep -Fq 'KEEP atrinik/classic repository Actions variable DEPENDENCY_UPDATE_APP_ID' \
  <<<"${output}"
grep -Fq 'KEEP atrinik organization pins match the exact governed order' <<<"${output}"
grep -Fq 'Manual settings live credential, GitHub App, external provider App, Pages, environment, and organization pin metadata is present; planned integrations are recorded without live provisioning.' \
  <<<"${output}"

: >"${temporary}/gh.log"
output=$(run_verify pages-active)
grep -Fq 'KEEP atrinik/classic Pages uses the reviewed Actions workflow source' \
  <<<"${output}"

for scenario in pages-source-drift pages-identity-drift \
  pages-activation-missing pages-workflow-metadata-drift; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'pending Pages activation has unexpected live source' \
  "${temporary}/pages-source-drift.err"
grep -Fq 'Pages identity or HTTPS drift' \
  "${temporary}/pages-identity-drift.err"
grep -Fq 'Pages Actions source is not active' \
  "${temporary}/pages-activation-missing.err"
grep -Fq 'Pages workflow metadata is invalid' \
  "${temporary}/pages-workflow-metadata-drift.err"

: >"${temporary}/gh.log"
output=$(run_verify page2)
grep -Fq 'KEEP atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  <<<"${output}"
grep -Fq 'page=2' "${temporary}/gh.log"

environment_page_root=${temporary}/environment-page
mkdir -p "${environment_page_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" \
  "${environment_page_root}/bin/"
cp -R "${root}/config" "${environment_page_root}/config"
cp -R "${root}/community-health" "${environment_page_root}/community-health"
cp -R "${root}/.github" "${environment_page_root}/.github"
jq '
  .github_actions_environments[0].deployment_branch_policy.patterns =
    ([range(0; 100) | {
      name: ("branch-" + tostring),
      type: "branch"
    }] + [{name: "main", type: "branch"}])
' "${root}/config/manual-settings.json" \
  >"${environment_page_root}/config/manual-settings.json"
: >"${temporary}/gh.log"
output=$(PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" \
  FAKE_GH_SCENARIO=environment-page2 \
  GITHUB_ACTIONS=true GH_TOKEN=test-token \
  ATRINIK_VALIDATION_TODAY=2026-10-11 \
  "${environment_page_root}/bin/verify-manual-settings")
grep -Fq 'KEEP atrinik/classic environment discord-release metadata' <<<"${output}"
grep -Fq 'deployment-branch-policies?per_page=100&page=2' "${temporary}/gh.log"

shared_root=${temporary}/shared-repository
mkdir -p "${shared_root}/bin"
cp "${root}/bin/validate" "${root}/bin/verify-manual-settings" \
  "${shared_root}/bin/"
cp -R "${root}/config" "${shared_root}/config"
cp -R "${root}/community-health" "${shared_root}/community-health"
cp -R "${root}/.github" "${shared_root}/.github"
jq '
  .github_actions_credentials += [
    .github_actions_credentials[0] |
    .secret_name = "SECOND_SETTINGS_TOKEN"
  ]
' "${root}/config/manual-settings.json" \
  >"${shared_root}/config/manual-settings.json"
: >"${temporary}/gh.log"
output=$(PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" \
  FAKE_GH_SCENARIO=shared-repository \
  GITHUB_ACTIONS=true GH_TOKEN=test-token \
  ATRINIK_VALIDATION_TODAY=2026-10-11 \
  "${shared_root}/bin/verify-manual-settings")
grep -Fq 'SECOND_SETTINGS_TOKEN' <<<"${output}"
[[ $(grep -Fc 'repos/atrinik/github-settings' "${temporary}/gh.log") == 2 ]]

for scenario in missing identity-drift api-failure page2-failure; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done

for scenario in pin-drift malformed-pins; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done

app_failures=(
  missing-external-app
  missing-app
  app-id-drift
  app-installation-id-drift
  app-slug-drift
  app-selection-drift
  app-account-drift
  app-events-drift
  app-permission-drift
  app-suspended
  missing-app-secret
  missing-app-variable
  malformed-app-installations
  malformed-app-variables
  app-api-failure
  app-variable-api-failure
  app-installations-page2-failure
  external-app-id-drift
  external-app-installation-id-drift
  external-app-slug-drift
  external-app-selection-drift
  external-app-events-drift
  external-app-permission-drift
  external-app-suspended
  planned-control-installed
  planned-control-identity-drift
  planned-control-license-drift
  external-website-identity-drift
  external-metaserver-identity-drift
)
for scenario in "${app_failures[@]}"; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'GitHub App installation is missing or ambiguous' \
  "${temporary}/missing-app.err"
grep -Fq 'external provider App installation is missing or ambiguous' \
  "${temporary}/missing-external-app.err"
grep -Fq 'GitHub App installation metadata or permission drift' \
  "${temporary}/app-permission-drift.err"
grep -Fq 'external provider App installation metadata or permission drift' \
  "${temporary}/external-app-permission-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/website' \
  "${temporary}/external-website-identity-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/deploy-control' \
  "${temporary}/planned-control-identity-drift.err"
grep -Fq 'planned external provider App has a live installation for atrinik-deploy-control' \
  "${temporary}/planned-control-installed.err"
grep -Fq 'repository visibility or license drift for atrinik/deploy-control' \
  "${temporary}/planned-control-license-drift.err"
grep -Fq 'GitHub App Actions secret name is missing' \
  "${temporary}/missing-app-secret.err"
grep -Fq 'GitHub App Actions variable name is missing' \
  "${temporary}/missing-app-variable.err"
grep -Fq 'returned invalid metadata' \
  "${temporary}/malformed-app-installations.err"
grep -Fq 'Actions variable metadata response is invalid' \
  "${temporary}/malformed-app-variables.err"
grep -Fq 'organization installation administration denied' \
  "${temporary}/app-api-failure.err"
grep -Fq 'Actions variable administration denied' \
  "${temporary}/app-variable-api-failure.err"
grep -Fq 'second installation page failed' \
  "${temporary}/app-installations-page2-failure.err"

: >"${temporary}/gh.log"
output=$(run_verify app-installations-page2)
grep -Fq 'KEEP atrinik-classic-dependency-updater installation metadata and exact permissions' \
  <<<"${output}"
grep -Fq 'orgs/atrinik/installations?per_page=100&page=2' "${temporary}/gh.log"

for failure in \
  app-api-failure:45 \
  app-variable-api-failure:46 \
  app-installations-page2-failure:47; do
  scenario=${failure%%:*}
  expected_status=${failure#*:}
  : >"${temporary}/gh.log"
  set +e
  run_verify "${scenario}" \
    >"${temporary}/${scenario}-status.out" \
    2>"${temporary}/${scenario}-status.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
done
grep -Fq 'organization pin order or identity drift' \
  "${temporary}/pin-drift.err"
grep -Fq 'invalid organization pin metadata' \
  "${temporary}/malformed-pins.err"
grep -Fq 'MISSING atrinik/github-settings repository Actions secret ATRINIK_SETTINGS_TOKEN' \
  "${temporary}/missing.err"
grep -Fq 'repository identity or active-state drift' \
  "${temporary}/identity-drift.err"
grep -Fq 'gh: repository administration denied' "${temporary}/api-failure.err"
grep -Fq 'read atrinik/github-settings identity' "${temporary}/api-failure.err"
grep -Fq 'gh: second secret page failed' "${temporary}/page2-failure.err"
grep -Fq 'page 2' "${temporary}/page2-failure.err"

environment_failures=(
  missing-environment
  environment-identity-drift
  environment-repository-name-drift
  environment-archived
  environment-default-branch-drift
  environment-name-drift
  branch-mode-drift
  branch-policy-drift
  extra-reviewer
  wait-timer
  custom-protection-rule
  missing-environment-secret
  extra-environment-variable
  malformed-branch-policy-response
  environment-page2-failure
)
for scenario in "${environment_failures[@]}"; do
  : >"${temporary}/gh.log"
  if run_verify "${scenario}" \
    >"${temporary}/${scenario}.out" 2>"${temporary}/${scenario}.err"; then
    echo "error: manual-settings verifier accepted ${scenario}" >&2
    exit 1
  fi
done
grep -Fq 'environment not found' "${temporary}/missing-environment.err"
grep -Fq 'read atrinik/classic environment discord-release' \
  "${temporary}/missing-environment.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-identity-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-repository-name-drift.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-archived.err"
grep -Fq 'repository identity or active-state drift for atrinik/classic' \
  "${temporary}/environment-default-branch-drift.err"
grep -Fq 'environment metadata is invalid' \
  "${temporary}/environment-name-drift.err"
grep -Fq 'deployment branch mode drift' \
  "${temporary}/branch-mode-drift.err"
grep -Fq 'deployment branch policy drift' \
  "${temporary}/branch-policy-drift.err"
grep -Fq 'required reviewer drift' "${temporary}/extra-reviewer.err"
grep -Fq 'protection rule drift' "${temporary}/wait-timer.err"
grep -Fq 'protection rule drift' "${temporary}/custom-protection-rule.err"
grep -Fq 'environment secret-name drift' \
  "${temporary}/missing-environment-secret.err"
grep -Fq 'environment variable-name drift' \
  "${temporary}/extra-environment-variable.err"
grep -Fq 'returned invalid metadata' \
  "${temporary}/malformed-branch-policy-response.err"
grep -Fq 'second environment branch-policy page failed' \
  "${temporary}/environment-page2-failure.err"
grep -Fq 'page 2' "${temporary}/environment-page2-failure.err"

for failure in api-failure:41 page2-failure:42; do
  scenario=${failure%%:*}
  expected_status=${failure#*:}
  : >"${temporary}/gh.log"
  set +e
  run_verify "${scenario}" \
    >"${temporary}/${scenario}-status.out" \
    2>"${temporary}/${scenario}-status.err"
  status=$?
  set -e
  if ((status != expected_status)); then
    echo "error: ${scenario} exited ${status}, expected ${expected_status}" >&2
    exit 1
  fi
done

: >"${temporary}/gh.log"
set +e
run_verify environment-page2-failure \
  >"${temporary}/environment-page2-failure-status.out" \
  2>"${temporary}/environment-page2-failure-status.err"
status=$?
set -e
if ((status != 44)); then
  echo "error: environment-page2-failure exited ${status}, expected 44" >&2
  exit 1
fi

: >"${temporary}/gh.log"
if PATH="${temporary}/bin:${PATH}" \
  FAKE_GH_LOG="${temporary}/gh.log" FAKE_GH_SCENARIO=present \
  GITHUB_ACTIONS=true GH_TOKEN='' ATRINIK_VALIDATION_TODAY=2026-10-11 \
  "${root}/bin/verify-manual-settings" \
  >"${temporary}/empty.out" 2>"${temporary}/empty.err"; then
  echo "error: manual-settings verifier accepted an empty workflow credential" >&2
  exit 1
fi
grep -Fq 'ATRINIK_SETTINGS_TOKEN is unavailable' "${temporary}/empty.err"
[[ ! -s ${temporary}/gh.log ]]

echo "Manual settings live credential, GitHub App, external provider App, planned integration, Pages, and environment verification tests passed."
