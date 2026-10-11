#!/usr/bin/env python3
"""Read-only GitHub API double for the effective-governance audit tests."""
import copy
import fnmatch
import json
import os
import sys
from pathlib import Path

root = Path(os.environ['AUDIT_CONFIG_ROOT'])
scenario = os.environ.get('GH_TEST_SCENARIO', 'pass')


def config(name):
    return json.loads((root / 'config' / name).read_text())


def reject(message):
    print(message, file=sys.stderr)
    sys.exit(2)


args = sys.argv[1:]
if not args or args.pop(0) != 'api':
    reject('API only')
slurp = False
include = False
endpoint = None
method = None
fields = {}
while args:
    arg = args.pop(0)
    if arg == '--method':
        method = args.pop(0)
    elif arg == '-H':
        args.pop(0)
    elif arg == '--paginate':
        pass
    elif arg == '--slurp':
        slurp = True
    elif arg == '--include':
        include = True
    elif arg == '-f':
        key, separator, value = args.pop(0).partition('=')
        if not separator or key in fields:
            reject('invalid or duplicated GraphQL variable')
        fields[key] = value
    elif arg.startswith('-'):
        reject(f'unexpected or mutating API flag: {arg}')
    else:
        endpoint = arg
if endpoint is None:
    reject('endpoint missing')
query = 'query LegacyBranchProtection($owner: String!, $name: String!, $qualifiedName: String!) { repository(owner: $owner, name: $name) { databaseId nameWithOwner isArchived ref(qualifiedName: $qualifiedName) { name branchProtectionRule { id } } } }'
if endpoint == 'graphql':
    if (method != 'POST' or set(fields) != {'query', 'owner', 'name', 'qualifiedName'}
            or fields['query'] != query or fields['owner'] != 'atrinik'
            or fields['name'] != 'observatory'
            or fields['qualifiedName'] not in ('refs/heads/main', 'refs/heads/release/next#candidate')
            or not scenario.startswith(('legacy-disabled-', 'legacy-maintenance-disabled-'))):
        reject('unexpected or mutating GraphQL request')
elif method != 'GET' or fields:
    reject('audit attempted API mutation')
with open(os.environ['AUDIT_API_LOG'], 'a', encoding='utf-8') as log:
    log.write(endpoint + '\n')

properties = config('repository-properties.json')
repositories = config('repositories.json')
policy = config('security-merge-protection.json')
active = sorted(name for name, value in properties['repositories'].items()
                if value['lifecycle'] != 'archived')


def rulesets(repository):
    specs = [('default-branch-integrity', None), ('default-branch-linear-history', None)]
    if repository in repositories['pull_request_gate']:
        specs.append(('pull-request-gate', None))
    if repository in repositories['required_ci']:
        specs.append(('required-ci', '03 - Required CI - ' + repository))
    if repository in repositories['release_tags'] or scenario in (
            'inherited-tag-unaffected', 'tag-extra-nonrelease', 'tag-all-nonrelease', 'tag-repository-nonrelease'):
        specs.append(('immutable-release-tags', None))
    if repository in policy['code_scanning'] and scenario not in ('pending-codeql', 'ready-missing-codeql', 'codeql-readiness-unreadable', 'enforced-missing-codeql', 'enforced-unreadable-codeql'):
        specs.append(('code-scanning', None))
    if repository in policy['dependency_review'] and scenario not in ('pending', 'ready-missing', 'dependency-readiness-unreadable', 'enforced-missing-dependency', 'enforced-unreadable-dependency'):
        specs.append(('dependency-review', None))
    if scenario == 'foreign-tag':
        specs.append(('immutable-release-tags', 'Foreign tag retention'))
    retained_template = None
    if scenario.startswith(('retained-', 'retired-')):
        kind = scenario.split('-')[1]
        retained_template = {'codeql': 'code-scanning', 'dependency': 'dependency-review'}.get(kind)
        if retained_template:
            specs.append((retained_template, None))
            if scenario.endswith('-duplicate'):
                specs.append((retained_template, None))
    result = []
    for index, (template, name) in enumerate(specs, 1):
        item = config('rulesets/' + template + '.json')
        if name:
            item['name'] = name
        if template == 'required-ci':
            item['rules'][0]['parameters']['required_status_checks'] = [
                {'context': context, 'integration_id': 15368}
                for context in repositories['required_ci'][repository]]
        # Actual ruleset GET responses expand omitted request parameters.
        for rule in item['rules']:
            if rule['type'] == 'pull_request':
                rule['parameters'].update(required_reviewers=[],
                    require_extra_approval_for_unattributed_changes=True,
                    allowed_merge_methods=['merge', 'squash', 'rebase'])
                deviations = {
                    'api-required-reviewers': ('required_reviewers', [{'reviewer': {'id': 42, 'type': 'Team'}, 'minimum_approvals': 1}]),
                    'api-extra-approval': ('require_extra_approval_for_unattributed_changes', False),
                    'api-restricted-merges': ('allowed_merge_methods', ['squash']),
                    'api-duplicate-merges': ('allowed_merge_methods', ['merge', 'squash', 'rebase', 'merge']),
                    'api-malformed-reviewers': ('required_reviewers', None),
                    'api-malformed-approval': ('require_extra_approval_for_unattributed_changes', 'true'),
                    'api-malformed-merges': ('allowed_merge_methods', 'merge,squash,rebase'),
                    'api-unknown-pr-field': ('unknown_future_control', False),
                }
                if scenario in deviations:
                    key, value = deviations[scenario]
                    rule['parameters'][key] = value
                if scenario == 'api-default-order':
                    rule['parameters']['allowed_merge_methods'].reverse()
            if rule['type'] == 'required_status_checks':
                rule['parameters']['do_not_enforce_on_create'] = False
                if scenario == 'api-create-exemption':
                    rule['parameters']['do_not_enforce_on_create'] = True
                if scenario == 'api-malformed-create-exemption':
                    rule['parameters']['do_not_enforce_on_create'] = None
        if scenario == 'api-defaults-omitted':
            for rule in item['rules']:
                for key in ('required_reviewers', 'require_extra_approval_for_unattributed_changes',
                            'allowed_merge_methods', 'do_not_enforce_on_create'):
                    rule.get('parameters', {}).pop(key, None)
        item.update(id=active.index(repository) * 10 + index,
                    source_type='Repository' if scenario == 'repository-rulesets' or
                    template in ('code-scanning', 'dependency-review') else 'Organization')
        if ((scenario == 'organization-codeql-owner' and template == 'code-scanning') or
                (scenario == 'organization-dependency-owner' and template == 'dependency-review')):
            item['source_type'] = 'Organization'
        if scenario == 'tag-repository-nonrelease' and template == 'immutable-release-tags':
            item['source_type'] = 'Repository'
        # Match GitHub's actual owner representation, including repository rulesets.
        for actor in item['bypass_actors']:
            if actor['actor_type'] == 'OrganizationAdmin':
                actor['actor_id'] = None
        if scenario == 'owner-id-drift' and repository == 'observatory' and template == 'pull-request-gate':
            item['bypass_actors'][0]['actor_id'] = 2
        if item['source_type'] == 'Organization':
            if template in ('default-branch-integrity', 'default-branch-linear-history'):
                included = ['~ALL']
                excluded = config('advisory-merge-windows.json')['repositories']
            elif template == 'pull-request-gate':
                windows = config('advisory-merge-windows.json')['repositories']
                included = [name for name in repositories['pull_request_gate'] if name not in windows]
                excluded = []
            elif template == 'immutable-release-tags':
                included, excluded = repositories['release_tags'], []
            elif template == 'code-scanning':
                included, excluded = policy['code_scanning'], []
            elif template == 'dependency-review':
                included, excluded = policy['dependency_review'], []
            else:
                included, excluded = [repository], []
            item['conditions']['repository_name'] = {
                'include': list(included), 'exclude': list(excluded), 'protected': False}
        if scenario == 'scope-order' and 'repository_name' in item['conditions']:
            item['conditions']['repository_name']['include'].reverse()
            item['conditions']['repository_name']['exclude'].reverse()
        if scenario == 'repository-scope-extra' and template == 'dependency-review':
            item['conditions']['repository_name'] = {'include': ['~ALL'], 'exclude': [], 'protected': False}
        if scenario in ('tag-all-scope', 'tag-all-nonrelease') and template == 'immutable-release-tags':
            item['conditions']['repository_name']['include'] = ['~ALL']
        if scenario in ('tag-extra-repo', 'tag-extra-nonrelease') and template == 'immutable-release-tags':
            item['conditions']['repository_name']['include'].append('.github')
        if scenario == 'tag-extra-exclude' and template == 'immutable-release-tags':
            item['conditions']['repository_name']['exclude'] = ['foreign-repository']
        if scenario == 'pr-all-scope' and template == 'pull-request-gate':
            item['conditions']['repository_name']['include'] = ['~ALL']
        if scenario == 'default-extra-exclude' and template == 'default-branch-integrity':
            item['conditions']['repository_name']['exclude'].append('foreign-repository')
        # Keep inherited names while making actual targeting ineffective.
        if scenario == 'wrong-pr-scope' and repository == '.github' and template == 'pull-request-gate':
            item['conditions']['repository_name']['include'] = ['client']
        if scenario == 'pending-wrong-dependency-scope' and repository == 'observatory' and template == 'dependency-review':
            item['conditions']['repository_name'] = {'include': ['observatory'], 'exclude': ['observatory'], 'protected': False}
        if scenario == 'missing-tag-scope' and repository == 'service-updater' and template == 'immutable-release-tags':
            item['conditions']['repository_name']['exclude'] = ['service-updater']
        if scenario == 'tag-ref-drift' and repository == 'service-updater' and template == 'immutable-release-tags':
            item['conditions']['ref_name']['include'] = ['refs/tags/unrelated*']
        if scenario == 'integrity-bypass' and repository == 'observatory' and template == 'default-branch-integrity':
            item['bypass_actors'] = [{'actor_type': 'OrganizationAdmin', 'actor_id': 1, 'bypass_mode': 'always'}]
        if scenario == 'pr-bypass' and repository == 'observatory' and template == 'pull-request-gate':
            item['bypass_actors'][0]['bypass_mode'] = 'always'
        if scenario == 'codeql-threshold' and repository == 'observatory' and template == 'code-scanning':
            item['rules'][0]['parameters']['code_scanning_tools'][0]['security_alerts_threshold'] = 'critical'
        if scenario == 'codeql-tool' and repository == 'observatory' and template == 'code-scanning':
            item['rules'][0]['parameters']['code_scanning_tools'][0]['tool'] = 'other-scanner'
        if scenario == 'codeql-quality' and repository == 'observatory' and template == 'code-scanning':
            item['rules'][0]['parameters']['code_scanning_tools'][0]['alerts_threshold'] = 'errors'
        if template == retained_template:
            if scenario.endswith(('-disabled', '-foreign-name', '-duplicate')):
                item['enforcement'] = 'disabled'
            if scenario.endswith('-moved'):
                item['conditions']['ref_name']['include'] = ['refs/heads/other']
            if scenario.endswith('-modified'):
                item['rules'] = [{'type': 'creation'}]
                item['enforcement'] = 'disabled'
            if scenario.endswith('-foreign-owner'):
                item['source_type'] = 'Organization'
                item['enforcement'] = 'disabled'
            if scenario.endswith('-foreign-name'):
                item['name'] = 'Foreign security policy'
        result.append(item)
    return result


payload = None
if endpoint == 'graphql':
    variant = scenario.removeprefix('legacy-maintenance-').removeprefix('legacy-').removeprefix('disabled-')
    repository = {'databaseId': active.index('observatory') + 1, 'nameWithOwner': 'atrinik/observatory',
                  'isArchived': False, 'ref': {'name': fields['qualifiedName'].removeprefix('refs/heads/'),
                                             'branchProtectionRule': None}}
    payload = {'data': {'repository': repository}}
    if variant == 'present':
        repository['ref']['branchProtectionRule'] = {'id': 'BPR_fixture'}
    elif variant == 'wrong-id':
        repository['databaseId'] += 100
    elif variant == 'wrong-owner':
        repository['nameWithOwner'] = 'foreign/observatory'
    elif variant == 'wrong-name':
        repository['ref']['name'] = 'master'
    elif variant == 'archived':
        repository['isArchived'] = True
    elif variant == 'missing-field':
        del repository['ref']['branchProtectionRule']
    elif variant == 'null-ref':
        repository['ref'] = None
    elif variant == 'null-repository':
        payload['data']['repository'] = None
    elif variant == 'missing-data':
        del payload['data']
    elif variant == 'malformed-rule':
        repository['ref']['branchProtectionRule'] = False
    elif variant == 'errors':
        payload['errors'] = [{'message': 'read denied'}]
    elif variant == 'unreadable':
        reject('GraphQL request denied')
    elif variant == 'non-json':
        print('<html>unavailable</html>')
        sys.exit(0)
elif endpoint.startswith('orgs/atrinik/repos?'):
    if scenario == 'inventory-unreadable':
        reject('inventory read denied')
    payload = [dict(name=name, id=active.index(name) + 1 if name in active else 1000,
                    archived=value['lifecycle'] == 'archived', private=False,
                    visibility='public', disabled=False, fork=False, has_issues=True,
                    has_projects=True, has_wiki=True)
               for name, value in properties['repositories'].items()]
    if scenario == 'legacy-disabled-inventory-id':
        next(item for item in payload if item['name'] == 'observatory')['id'] += 100
    if scenario == 'unmanaged':
        payload.append(dict(name='unmanaged', archived=False, private=False, visibility='public',
                            disabled=False, fork=False, has_issues=True, has_projects=True, has_wiki=True))
    if scenario == 'temporary':
        payload.append(dict(name='classic-ghsa-8533-3vg8-r287', archived=False, private=True,
                            visibility='private', disabled=False, fork=False,
                            has_issues=False, has_projects=False, has_wiki=False))
elif endpoint == 'orgs/atrinik/properties/schema':
    payload = properties['definitions']
    if scenario == 'schema-drift':
        payload[0]['description'] = 'drift'
elif endpoint.startswith('orgs/atrinik/actions/permissions'):
    suffix = endpoint.removeprefix('orgs/atrinik/actions/permissions')
    filename = {'': 'actions-permissions.json', '/workflow': 'actions-workflow.json',
                '/selected-actions': 'actions-selected.json'}[suffix]
    if scenario == 'actions-unreadable':
        reject('Actions read denied')
    payload = config(filename)
    if filename == 'actions-permissions.json':
        payload['sha_pinning_required'] = scenario not in ('pending', 'sha-enforced-off', 'phase-unreadable')
        if scenario == 'sha-invalid-type':
            payload['sha_pinning_required'] = 'false'
        if scenario == 'sha-unreadable':
            del payload['sha_pinning_required']
    if filename == 'actions-workflow.json':
        if scenario == 'actions-write-token':
            payload['default_workflow_permissions'] = 'write'
        if scenario == 'actions-approval':
            payload['can_approve_pull_request_reviews'] = True
    if filename == 'actions-selected.json' and scenario == 'actions-allowlist':
        payload['patterns_allowed'].append('*')
elif endpoint.startswith('orgs/atrinik/rulesets/'):
    identifier = int(endpoint.rsplit('/', 1)[1])
    payload = next((item for repository in active for item in rulesets(repository)
                    if item['id'] == identifier), None)
    if payload is None or scenario == 'ruleset-unreadable':
        reject('ruleset read denied')
elif endpoint.startswith('repos/atrinik/'):
    repository, _, path = endpoint.removeprefix('repos/atrinik/').partition('/')
    if repository not in active:
        reject('audit attempted to inspect archived or foreign repository')
    target = repository == 'observatory'
    if path == 'actions/permissions/workflow':
        if scenario == 'repository-actions-unreadable' and target:
            reject('repository workflow permissions read denied')
        payload = config('actions-workflow.json')
        if scenario == 'repository-write-token' and target:
            payload['default_workflow_permissions'] = 'write'
        if scenario == 'repository-approval' and target:
            payload['can_approve_pull_request_reviews'] = True
    elif path.startswith('branches/') and path.endswith('/protection'):
        if not include:
            reject('legacy protection requires an observable HTTP status')
        branch = path.removeprefix('branches/').removesuffix('/protection')
        if branch not in ('main', 'release%2F2.x', 'release%2Fnext%23candidate'):
            reject('unexpected or unencoded branch: ' + branch)
        code, payload, result = 404, {'message': 'Branch not protected', 'status': '404'}, 1
        selected = target and branch == 'main'
        if scenario.startswith('legacy-maintenance-'):
            selected = target and branch == 'release%2Fnext%23candidate'
        if selected:
            variant = scenario.removeprefix('legacy-maintenance-').removeprefix('legacy-')
            policies = {
                'extra-context': {'required_status_checks': {'checks': [
                    {'context': 'Unconfigured check', 'app_id': 15368}]}},
                'wrong-app': {'required_status_checks': {'checks': [
                    {'context': 'Conventional PR title', 'app_id': 99}]}},
                'approval': {'required_pull_request_reviews': {'required_approving_review_count': 1}},
                'force-push': {'allow_force_pushes': {'enabled': True}},
                'matching': {'required_status_checks': {'checks': [
                    {'context': context, 'app_id': 15368}
                    for context in repositories['required_ci'].get(repository, [])]}},
                'empty': {},
            }
            if variant.startswith('disabled-'):
                payload['message'] = 'Branch protection has been disabled on this repository.'
            elif variant in policies:
                code, payload, result = 200, policies[variant], 0
            elif variant == 'forbidden':
                code, payload = 403, {'message': 'Resource not accessible by integration', 'status': '403'}
            elif variant == 'not-found':
                payload['message'] = 'Not Found'
            elif variant == 'wrong-status':
                payload['status'] = '403'
            elif variant == 'mismatched-http':
                code = 403
            elif variant == 'transport-error':
                reject('connection failed')
            elif variant == 'wrong-exit':
                result = 2
            elif variant == 'success-error':
                code, result = 200, 0
            elif variant == 'non-json':
                payload = '<html>service unavailable</html>'
            elif variant == 'success-non-json':
                code, payload, result = 200, '<html>service unavailable</html>', 0
            elif variant == 'null':
                payload = None
            elif variant == 'array':
                payload = [payload]
        print(f'HTTP/2.0 {code} Fixture\r\nContent-Type: application/json\r\n\r')
        print(payload if isinstance(payload, str) else json.dumps(payload))
        sys.exit(result)
    elif path == 'properties/values':
        payload = [{'property_name': key, 'value': value}
                   for key, value in properties['repositories'][repository].items()]
        if scenario == 'properties-drift' and target:
            payload[0]['value'] = 'drift'
    elif path.startswith('rulesets?'):
        if scenario == 'retained-list-unreadable':
            reject('ruleset list read denied')
        if scenario == 'retained-list-non-json':
            print('<html>unavailable</html>')
            sys.exit(0)
        payload = [{'name': item['name'], 'id': item['id'], 'source_type': item['source_type']}
                   for item in rulesets(repository)]
        if scenario == 'retained-list-object':
            payload = {'message': 'unreadable'}
        elif scenario == 'retained-list-missing-name':
            payload.append({'id': 999, 'source_type': 'Repository'})
        elif scenario == 'retained-list-null-item':
            payload.append(None)
        elif scenario == 'retained-list-partial-page':
            print(json.dumps([payload, None]))
            sys.exit(0)
    elif path.startswith('rulesets/'):
        identifier = int(path.rsplit('/', 1)[1])
        payload = next((item for item in rulesets(repository) if item['id'] == identifier), None)
        if payload is None:
            reject('repository ruleset missing')
    elif path.startswith('rules/branches/'):
        if scenario == 'effective-unreadable' and target:
            reject('effective branch read denied')
        payload = []
        for item in rulesets(repository):
            scope = item['conditions'].get('repository_name', {'include': [repository], 'exclude': []})
            included = any(pattern == '~ALL' or fnmatch.fnmatchcase(repository, pattern) for pattern in scope['include'])
            excluded = any(pattern == '~ALL' or fnmatch.fnmatchcase(repository, pattern) for pattern in scope['exclude'])
            refs = item['conditions']['ref_name']
            branch_included = any(pattern == '~DEFAULT_BRANCH' or
                                  fnmatch.fnmatchcase('refs/heads/main', pattern) for pattern in refs['include'])
            branch_excluded = any(pattern == '~DEFAULT_BRANCH' or
                                  fnmatch.fnmatchcase('refs/heads/main', pattern) for pattern in refs['exclude'])
            if (item['target'] == 'branch' and item['enforcement'] == 'active'
                    and included and not excluded and branch_included and not branch_excluded):
                payload.extend(copy.deepcopy(item['rules']))
        for rule in payload:
            if target and rule['type'] == 'required_status_checks':
                if scenario == 'wrong-app':
                    rule['parameters']['required_status_checks'][0]['integration_id'] = 9
                if scenario == 'wrong-context':
                    rule['parameters']['required_status_checks'][0]['context'] += ' drift'
                if scenario == 'strict-ci':
                    rule['parameters']['strict_required_status_checks_policy'] = False
            if target and rule['type'] == 'pull_request':
                if scenario == 'approval-count':
                    rule['parameters']['required_approving_review_count'] = 1
                if scenario == 'thread-resolution':
                    rule['parameters']['required_review_thread_resolution'] = False
        if scenario == 'effective-integrity' and target:
            payload = [item for item in payload if item['type'] != 'deletion']
        if scenario == 'unexpected-codeql' and repository == '.github':
            payload.extend(config('rulesets/code-scanning.json')['rules'])
        if scenario == 'unexpected-pr' and repository == 'web-platform':
            payload.append(config('rulesets/pull-request-gate.json')['rules'][0])
    elif path == 'code-security-configuration':
        advanced = repository in config('codeql-advanced-setup.json')['repositories']
        if scenario == 'configuration-unreadable' and target:
            reject('configuration read denied')
        payload = {'status': 'enforced', 'configuration': config(
            'code-security-advanced.json' if advanced else 'code-security.json')}
        if scenario == 'legacy-security':
            payload['configuration'].pop('code_security')
            payload['configuration'].pop('secret_protection')
            payload['configuration']['advanced_security'] = 'enabled'
        if scenario == 'configuration-detached' and target:
            payload['status'] = 'attached'
        if scenario == 'dependency-graph' and target:
            payload['configuration']['dependency_graph'] = 'disabled'
        if scenario == 'advanced-config' and repository == 'classic':
            payload['configuration'] = config('code-security.json')
    elif path == 'code-scanning/default-setup':
        advanced = repository in config('codeql-advanced-setup.json')['repositories']
        if scenario == 'setup-unreadable' and target:
            reject('setup read denied')
        payload = config('codeql-default-setup-advanced.json' if advanced else 'codeql-default-setup.json')
        payload['languages'] = policy['codeql_required_languages'].get(repository, [])
        if target:
            malformed_languages = {
                'languages-null': None,
                'languages-scalar': 'javascript-typescript',
                'languages-object': {'language': 'javascript-typescript'},
                'languages-number': [7],
                'languages-mixed': ['javascript-typescript', None],
            }
            if scenario in malformed_languages:
                payload['languages'] = malformed_languages[scenario]
            elif scenario == 'languages-missing':
                del payload['languages']
            elif scenario == 'languages-readable':
                payload['languages'] = ['javascript-typescript', 'future-language']
            elif scenario == 'languages-empty':
                payload['languages'] = []
        if scenario == 'advanced-null-languages' and repository == 'classic':
            payload['languages'] = None
        if scenario == 'missing-rust' and repository == 'content-toolkit':
            payload['languages'] = ['javascript-typescript']
        if scenario == 'advanced-setup' and repository == 'classic':
            payload['state'] = 'configured'
        if scenario == 'default-setup' and target:
            payload['state'] = 'not-configured'
    elif path == 'vulnerability-alerts':
        if scenario == 'dependabot-alerts' and target:
            reject('alerts disabled')
        sys.exit(0)  # GitHub's enabled response is HTTP 204, without JSON.
    elif path == 'private-vulnerability-reporting':
        payload = {'enabled': not (scenario == 'private-reporting' and target)}
    elif path == '':
        payload = dict(config('repository-defaults.json'), id=active.index(repository) + 1,
                       name=repository, full_name='atrinik/' + repository, archived=False, security_and_analysis={
                           name: {'status': 'enabled'} for name in (
                               'secret_scanning', 'secret_scanning_push_protection',
                               'secret_scanning_validity_checks', 'dependabot_security_updates')})
        if scenario == 'legacy-disabled-metadata-name' and target:
            payload['full_name'] = 'foreign/observatory'
        if scenario == 'merge-drift' and target:
            payload['allow_merge_commit'] = True
        if scenario == 'secret-baseline' and target:
            payload['security_and_analysis']['secret_scanning']['status'] = 'disabled'
    else:
        reject('unexpected repository endpoint: ' + endpoint)
else:
    reject('unexpected endpoint: ' + endpoint)
print(json.dumps([payload] if slurp else payload))
