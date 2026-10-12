#!/usr/bin/env python3
"""Deterministic, read-only security readiness contract tests."""

import base64
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, quote, urlparse


ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("security_readiness", ROOT / "lib/security_readiness.py")
readiness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(readiness)
HEAD, BASE, MERGE = "a" * 40, "b" * 40, "c" * 40
OLD, NEW = "d" * 40, "e" * 40
WORKFLOW = ("name: Dependency review\n\non:\n  pull_request:\n    branches: [main]\n"
            "    types: [opened, synchronize, reopened, edited]\n"
            "  merge_group:\n    types: [checks_requested]\n"
            "permissions:\n  contents: read\njobs:\n  dependency-review:\n"
            "    name: Dependency review\n    runs-on: ubuntu-24.04\n    steps:\n"
            f"      - uses: actions/dependency-review-action@{OLD} # v5.0.0\n"
            "        with:\n          fail-on-severity: high\n          warn-only: false\n").encode()
# Snapshot of the actual content-toolkit producer, including its types-first
# mapping, block branch filter, named step, and complete enforcement settings.
# Immutable action versions remain producer-owned and are normalized by policy.
COMPONENT_WORKFLOW = b"""name: Dependency review

on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
    branches:
      - main
  merge_group:
    types: [checks_requested]

permissions:
  contents: read

jobs:
  dependency-review:
    name: Dependency review
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - name: Review dependency changes
        uses: actions/dependency-review-action@a1d282b36b6f3519aa1f3fc636f609c47dddb294 # v5.0.0
        with:
          fail-on-severity: high
          fail-on-scopes: runtime,development,unknown
          warn-only: false
          comment-summary-in-pr: never
          show-openssf-scorecard: false
          retry-on-snapshot-warnings: true
          retry-on-snapshot-warnings-timeout: 120
"""
SELECTED = {"github_owned_allowed": True, "verified_allowed": False,
            "patterns_allowed": ["rust-lang/crates-io-auth-action@*", "docker/setup-buildx-action@*"]}
# Executable Classic workflow snapshot; action pins remain producer-owned.
CODEQL_WORKFLOW = b"""name: CodeQL

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
  merge_group:
  workflow_dispatch:
  schedule:
    - cron: "17 4 * * 2"

permissions:
  actions: read
  contents: read
  security-events: write

concurrency:
  group: classic-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  classify:
    name: CodeQL classification
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    outputs:
      matrix: ${{ steps.classify.outputs.codeql_matrix }}
      run: ${{ steps.classify.outputs.codeql_run }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - id: classify
        name: Select analysis languages and paths
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          EVENT_NAME: ${{ github.event_name }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          python3 tools/ci/classify_changes.py \\
            --event "${EVENT_NAME}" \\
            --base "${BASE_SHA}" \\
            --head "${HEAD_SHA}" \\
            --github-output "${GITHUB_OUTPUT}" \\
            --codeql-config build/codeql-config.yml

  analyze:
    name: CodeQL analysis (${{ matrix.display }})
    needs: classify
    if: needs.classify.outputs.run == 'true'
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.classify.outputs.matrix) }}
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - id: classify
        name: Recreate the trusted path configuration
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          EVENT_NAME: ${{ github.event_name }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          python3 tools/ci/classify_changes.py \\
            --event "${EVENT_NAME}" \\
            --base "${BASE_SHA}" \\
            --head "${HEAD_SHA}" \\
            --github-output "${GITHUB_OUTPUT}" \\
            --codeql-config build/codeql-config.yml \\
            --codeql-scope "${{ matrix.scope }}"
      - name: Initialize CodeQL
        if: matrix.run == true
        uses: github/codeql-action/init@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4.38.2
        with:
          build-mode: none
          config-file: ${{ steps.classify.outputs.codeql_config }}
          languages: ${{ matrix.language }}
      - name: Analyze
        if: matrix.run == true
        uses: github/codeql-action/analyze@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4.38.2
        with:
          category: ${{ matrix.category }}

  codeql-validation:
    name: CodeQL validation
    if: always()
    needs:
      - classify
      - analyze
    runs-on: ubuntu-24.04
    timeout-minutes: 2
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Require every selected analysis
        run: |
          python3 tools/ci/require_checks.py optional \\
            --label CodeQL \\
            --classifier-result '${{ needs.classify.result }}' \\
            --required '${{ needs.classify.outputs.run }}' \\
            --result '${{ needs.analyze.result }}'
"""
PARTITIONS = [
    {"display": "C/C++ client", "scope": "client", "language": "c-cpp",
     "category": "/partition:client/language:c-cpp", "run": True},
    {"display": "C/C++ server", "scope": "server", "language": "c-cpp",
     "category": "/partition:server/language:c-cpp", "run": True},
    {"display": "C/C++ core", "scope": "core-cpp", "language": "c-cpp",
     "category": "/partition:core/language:c-cpp", "run": True},
    {"display": "Python", "scope": "python", "language": "python",
     "category": "/partition:core/language:python", "run": True},
    {"display": "GitHub Actions", "scope": "actions", "language": "actions",
     "category": "/partition:core/language:actions", "run": True},
]


def classifier_source(partitions):
    source = """FULL_EVENTS = {'push', 'schedule', 'workflow_dispatch', 'merge_group'}
def main():
    if arguments.event in FULL_EVENTS:
        full = True
        paths = []
def write_outputs(path, result, config):
    entries = []
"""
    for item in partitions:
        source += f"    if result[{item['scope']!r}]:\n        entries.append({item!r})\n"
    source += "    matrix = {'include': entries or [{'run': False, 'scope': 'union'}]}\n"
    return source.encode()


CLASSIFIER = classifier_source(PARTITIONS)


def content(data):
    return {"type": "file", "encoding": "base64", "content": base64.b64encode(data).decode()}


def check(name, ref=HEAD, identifier=1, conclusion="success", status="completed"):
    return {"name": name, "head_sha": ref, "id": identifier, "status": status,
            "conclusion": conclusion, "started_at": "2026-10-11T12:00:00Z",
            "app": {"id": 15368, "slug": "github-actions"}, "check_suite": {"id": 99}}


class Fixture:
    def __init__(self):
        self.calls = []
        self.metadata = {"id": 42, "full_name": "atrinik/example", "default_branch": "main", "archived": False}
        self.pr = {"number": 12, "state": "open", "draft": False, "merged": False,
                   "changed_files": 1, "merge_commit_sha": MERGE,
                   "base": {"ref": "main", "sha": BASE, "repo": {"full_name": "atrinik/example"}},
                   "head": {"sha": HEAD, "repo": {"full_name": "atrinik/example"}}}
        self.run = {"id": 9, "run_attempt": 2, "event": "pull_request", "status": "completed",
                    "conclusion": "success", "head_sha": HEAD, "check_suite_id": 99,
                    "path": ".github/workflows/dependency-review.yml",
                    "head_repository": {"full_name": "atrinik/example"},
                    "pull_requests": [{"number": 12, "head": {"sha": HEAD},
                                       "base": {"sha": BASE, "ref": "main"}}]}
        self.suite_runs = {}
        self.associated_pulls = [{"number": 12}]
        self.suite = {"id": 99, "head_sha": MERGE, "status": "completed", "conclusion": "success",
                      "app": {"id": 15368}, "pull_requests": copy.deepcopy(self.run["pull_requests"])}
        self.jobs = [{"name": "Dependency review", "status": "completed", "conclusion": "success"}]
        self.files = [{"filename": ".github/workflows/check.yml", "status": "modified"}]
        self.before = f"name: Check\nsteps:\n  - uses: rust-lang/crates-io-auth-action@{OLD} # v1\n".encode()
        self.after = f"name: Check\nsteps:\n  - uses: rust-lang/crates-io-auth-action@{NEW} # v2\n".encode()
        self.checks = {HEAD: [check("Required checks"), check("Conventional PR title", identifier=2)], MERGE: []}
        self.live = copy.deepcopy(SELECTED)
        self.actions_policy = {"enabled_repositories": "all", "allowed_actions": "selected"}
        self.repository_actions = {"enabled": True, "allowed_actions": "all"}
        self.enabled_repositories = [{"id": 42, "full_name": "atrinik/example"}]
        self.effective_rules = []
        self.legacy_checks = None
        self.default_workflow = WORKFLOW
        self.run_workflow = WORKFLOW
        self.executed_workflow = WORKFLOW
        self.parents = [BASE, HEAD]
        self.branch_head = HEAD
        self.setup = {"state": "configured", "languages": ["rust"]}
        self.codeql_sources = {".github/workflows/codeql.yml": CODEQL_WORKFLOW,
                               "tools/ci/classify_changes.py": CLASSIFIER,
                               "tools/ci/require_checks.py": b"# Trusted aggregate\n"}
        self.codeql_head_sources = copy.deepcopy(self.codeql_sources)
        self.codeql_run = {"id": 29, "run_attempt": 1, "head_sha": HEAD, "head_branch": "main",
                           "event": "push", "path": ".github/workflows/codeql.yml", "check_suite_id": 777,
                           "status": "completed", "conclusion": "success"}
        self.codeql_check = check("CodeQL validation", identifier=999)
        self.codeql_check["check_suite"]["id"] = 777
        self.codeql_jobs = []
        self.analysis_reads = 0
        self.fresh_analyses = None
        self.analyses = [{"id": 1, "created_at": "2026-10-11T12:00:00Z", "tool": {"name": "CodeQL"},
                          "ref": "refs/heads/main", "commit_sha": HEAD, "category": "/language:rust",
                          "environment": '{"language":"rust"}', "error": "", "rules_count": 42}]

    def __call__(self, endpoint):
        self.calls.append(endpoint)
        if endpoint == "repos/atrinik/example":
            return copy.deepcopy(self.metadata)
        if endpoint == "repos/atrinik/example/pulls/12":
            return copy.deepcopy(self.pr)
        if "/contents/.github/workflows/dependency-review.yml" in endpoint:
            return content(self.default_workflow if "ref=main" in endpoint else
                           self.executed_workflow if "ref=" + MERGE in endpoint else self.run_workflow)
        if "/contents/.github/workflows/check.yml" in endpoint:
            return content(self.before if "ref=" + self.pr["base"]["sha"] in endpoint else self.after)
        if "/contents/" in endpoint:
            path = endpoint.split("/contents/")[1].split("?")[0]
            ref = parse_qs(urlparse(endpoint).query).get("ref", [None])[0]
            sources = self.codeql_sources if ref == self.metadata["default_branch"] else self.codeql_head_sources
            return content(sources[path])
        if "/actions/workflows/codeql.yml/runs" in endpoint:
            return {"workflow_runs": [copy.deepcopy(self.codeql_run)]}
        if "/actions/runs/29/attempts/1/jobs" in endpoint:
            return {"total_count": len(self.codeql_jobs), "jobs": copy.deepcopy(self.codeql_jobs)}
        if endpoint.endswith("/check-runs/999"):
            return copy.deepcopy(self.codeql_check)
        if "/check-runs/" in endpoint:
            identifier = int(endpoint.rsplit("/", 1)[1])
            for checks in self.checks.values():
                for current in checks:
                    if current["id"] == identifier:
                        return copy.deepcopy(current)
            raise AssertionError("Unexpected check identity: " + endpoint)
        if "/actions/workflows/dependency-review.yml/runs" in endpoint:
            return {"workflow_runs": [copy.deepcopy(self.run)]}
        if "/attempts/2/jobs" in endpoint:
            return {"total_count": len(self.jobs), "jobs": copy.deepcopy(self.jobs)}
        if endpoint == "orgs/atrinik/actions/permissions":
            return copy.deepcopy(self.actions_policy)
        if endpoint == "repos/atrinik/example/actions/permissions":
            return copy.deepcopy(self.repository_actions)
        if "/actions/permissions/repositories?" in endpoint:
            return {"total_count": len(self.enabled_repositories),
                    "repositories": copy.deepcopy(self.enabled_repositories)}
        if "/rules/branches/" in endpoint:
            return copy.deepcopy(self.effective_rules)
        if endpoint.endswith("/protection"):
            return {"required_status_checks": copy.deepcopy(self.legacy_checks)}
        if "/actions/permissions/selected-actions" in endpoint:
            return copy.deepcopy(self.live)
        if "/pulls/12/files" in endpoint:
            return copy.deepcopy(self.files)
        if f"/commits/{HEAD}/pulls?" in endpoint:
            return copy.deepcopy(self.associated_pulls)
        if endpoint == "repos/atrinik/example/commits/" + MERGE:
            return {"parents": [{"sha": value} for value in self.parents]}
        if "/check-runs?" in endpoint:
            values = copy.deepcopy(self.checks[endpoint.split("/commits/")[1].split("/")[0]])
            return {"total_count": len(values), "check_runs": values}
        if "/actions/runs?check_suite_id=" in endpoint:
            suite_id = int(parse_qs(urlparse(endpoint).query)["check_suite_id"][0])
            return {"workflow_runs": [copy.deepcopy(self.suite_runs.get(suite_id, self.run))]}
        if "/actions/runs?event=pull_request&head_sha=" in endpoint:
            return {"total_count": 1, "workflow_runs": [copy.deepcopy(self.run)]}
        if "/check-suites/" in endpoint:
            value = copy.deepcopy(self.suite)
            value["id"] = int(endpoint.rsplit("/", 1)[1])
            return value
        if endpoint == "repos/atrinik/example/branches/" + quote(self.metadata["default_branch"], safe=""):
            return {"commit": {"sha": self.branch_head}}
        if "/code-scanning/analyses?" in endpoint:
            page = int(parse_qs(urlparse(endpoint).query)["page"][0])
            if page == 1:
                self.analysis_reads += 1
            analyses = (self.fresh_analyses if self.analysis_reads > 1 and self.fresh_analyses is not None
                        else self.analyses)
            return copy.deepcopy(analyses[(page - 1) * 100:page * 100])
        if endpoint.endswith("/code-scanning/default-setup"):
            return copy.deepcopy(self.setup)
        raise AssertionError("Unexpected read-only API endpoint: " + endpoint)


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / ".github/workflows/dependency-review.yml").write_bytes(WORKFLOW)
        (self.root / "config").mkdir()
        (self.root / "config/actions-selected.json").write_text(json.dumps(SELECTED))
        (self.root / "config/repositories.json").write_text(json.dumps({
            "required_ci": {"example": ["Required checks", "Conventional PR title"]}}))
        (self.root / "config/security-merge-protection.json").write_text(json.dumps({
            "codeql_required_languages": {"example": ["rust"]}, "dependency_review": []}))
        (self.root / "config/codeql-advanced-setup.json").write_text('{"repositories": [], "required_partitions": {}}')
        self.fixture = Fixture()
        self.root_patch = patch.object(readiness, "ROOT", self.root)
        self.api_patch = patch.object(readiness, "api", self.fixture)
        self.root_patch.start()
        self.api_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.api_patch.stop)

    def invoke(self, mode):
        stream = io.StringIO()
        with patch("sys.stdout", stream):
            result = readiness.main([mode, "atrinik/example/12" if mode == "sha" else "atrinik/example"])
        return result, stream.getvalue()

    def assert_deferred(self, mode, fragment):
        code, text = self.invoke(mode)
        self.assertEqual(code, 1, text)
        self.assertIn(fragment, text)

    def test_dependency_ready_latest_attempt_exact_workflow(self):
        self.assertEqual(self.invoke("dependency")[0], 0)
        self.assertTrue(any("/attempts/2/jobs" in call for call in self.fixture.calls))

    def merged_empty_fixture(self, run_empty=True, suite_empty=True):
        fixture = Fixture()
        fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        if run_empty:
            fixture.run["pull_requests"] = []
        if suite_empty:
            fixture.suite["pull_requests"] = []
        return fixture

    def test_merged_empty_associations_ready_for_dependency_and_stored_sha_canary(self):
        for mode in ("dependency", "sha"):
            for run_empty, suite_empty in ((True, False), (False, True), (True, True)):
                for direct_head in (False, True):
                    with self.subTest(mode=mode, run_empty=run_empty, suite_empty=suite_empty,
                                      direct_head=direct_head):
                        fixture = self.merged_empty_fixture(run_empty, suite_empty)
                        if direct_head:
                            fixture.suite["head_sha"] = HEAD
                        elif mode == "sha":
                            fixture.checks[MERGE] = [check("Required checks", MERGE),
                                                     check("Conventional PR title", MERGE, 2)]
                            fixture.checks[HEAD] = []
                        with patch.object(readiness, "api", fixture):
                            result, output = self.invoke(mode)
                        self.assertEqual(result, 0, output)
                        self.assertGreaterEqual(sum(f"/commits/{HEAD}/pulls?" in endpoint
                                                    for endpoint in fixture.calls), 2)

    def test_merged_empty_association_newer_failed_or_queued_canary_still_blocks(self):
        for status, conclusion in (("completed", "failure"), ("queued", None)):
            with self.subTest(status=status):
                fixture = self.merged_empty_fixture()
                newer = check("Required checks", identifier=50, status=status, conclusion=conclusion)
                newer["started_at"] = None
                newer["check_suite"]["id"] = 100
                fixture.checks[HEAD].append(newer)
                run = copy.deepcopy(fixture.run)
                run.update(id=20, check_suite_id=100, status=status, conclusion=conclusion)
                fixture.suite_runs[100] = run
                with patch.object(readiness, "api", fixture):
                    self.assert_deferred("sha", "workflow run not successful")

    def test_merged_empty_associations_reject_ambiguous_or_missing_commit_pulls(self):
        for mode in ("dependency", "sha"):
            for entries in ([], [{"number": 12}, {"number": 13}]):
                with self.subTest(mode=mode, entries=entries):
                    fixture = self.merged_empty_fixture()
                    fixture.associated_pulls = entries
                    with patch.object(readiness, "api", fixture):
                        self.assert_deferred(mode, "association missing or ambiguous")

    def test_merged_empty_associations_reject_open_pr(self):
        for mode in ("dependency", "sha"):
            with self.subTest(mode=mode):
                fixture = self.merged_empty_fixture()
                fixture.pr.update(state="open", merged=False)
                fixture.pr["merge_commit_sha"] = MERGE
                with patch.object(readiness, "api", fixture):
                    self.assert_deferred(mode, "association identity")

    def test_merged_empty_associations_reject_identity_mismatch(self):
        for mode in ("dependency", "sha"):
            for field in ("head", "head_repository", "base", "base_repository", "number"):
                with self.subTest(mode=mode, field=field):
                    fixture = self.merged_empty_fixture()
                    # Change only the independently fetched association PR; retain
                    # the caller's initial canary so its own guards cannot mask this test.
                    count = 0
                    def mismatch(endpoint):
                        nonlocal count
                        value = fixture(endpoint)
                        if endpoint.endswith("/pulls/12"):
                            count += 1
                            if mode == "dependency" or count > 1:
                                if field == "head":
                                    value["head"]["sha"] = OLD
                                elif field == "head_repository":
                                    value["head"]["repo"]["full_name"] = "other/example"
                                elif field == "base":
                                    value["base"]["ref"] = "other"
                                elif field == "base_repository":
                                    value["base"]["repo"]["full_name"] = "other/example"
                                else:
                                    value["number"] = 13
                        return value
                    with patch.object(readiness, "api", mismatch):
                        self.assert_deferred(mode, "association identity")

    def test_merged_empty_associations_never_override_nonempty_conflict(self):
        for mode in ("dependency", "sha"):
            for conflicting in ("run", "suite"):
                with self.subTest(mode=mode, conflicting=conflicting):
                    fixture = self.merged_empty_fixture(conflicting != "run", conflicting != "suite")
                    source = fixture.run if conflicting == "run" else fixture.suite
                    source["pull_requests"][0]["base"]["sha"] = OLD
                    with patch.object(readiness, "api", fixture):
                        self.assert_deferred(mode, "nonempty PR association conflicts")

    def test_merged_empty_associations_reject_non_pr_event_or_workflow_path(self):
        for mode in ("dependency", "sha"):
            for field, value in (("event", "push"), ("event", "workflow_dispatch"),
                                 ("path", "untrusted.yml")):
                with self.subTest(mode=mode, field=field, value=value):
                    fixture = self.merged_empty_fixture()
                    fixture.run[field] = value
                    with patch.object(readiness, "api", fixture):
                        result, output = self.invoke(mode)
                    self.assertEqual(result, 1, output)

    def test_merged_empty_associations_unreadable_is_error(self):
        for mode in ("dependency", "sha"):
            with self.subTest(mode=mode):
                fixture = self.merged_empty_fixture()
                def unreadable(endpoint):
                    if f"/commits/{HEAD}/pulls?" in endpoint:
                        raise readiness.APIError(endpoint, 403)
                    return fixture(endpoint)
                with patch.object(readiness, "api", unreadable):
                    code, output = self.invoke(mode)
                self.assertEqual(code, 2, output)
                self.assertIn("HTTP 403", output)

    def test_merged_empty_association_collection_is_refenced(self):
        for mode in ("dependency", "sha"):
            with self.subTest(mode=mode):
                fixture = self.merged_empty_fixture()
                verify = readiness.verify_recovered_associations
                def change_at_fence(coordinate, recovered):
                    fixture.associated_pulls.append({"number": 13})
                    return verify(coordinate, recovered)
                with patch.object(readiness, "api", fixture), patch.object(
                        readiness, "verify_recovered_associations", change_at_fence):
                    self.assert_deferred(mode, "association missing or ambiguous")

    def test_merged_empty_association_pr_identity_is_refenced(self):
        for mode in ("dependency", "sha"):
            with self.subTest(mode=mode):
                fixture = self.merged_empty_fixture()
                verify = readiness.verify_recovered_associations
                def change_at_fence(coordinate, recovered):
                    fixture.pr["base"]["sha"] = OLD
                    return verify(coordinate, recovered)
                with patch.object(readiness, "api", fixture), patch.object(
                        readiness, "verify_recovered_associations", change_at_fence):
                    self.assert_deferred(mode, "association changed during preflight")

    def test_merged_empty_association_preserves_workflow_and_merge_parent_proof(self):
        for mode in ("dependency", "sha"):
            with self.subTest(mode=mode):
                fixture = self.merged_empty_fixture()
                fixture.parents = [OLD, HEAD]
                with patch.object(readiness, "api", fixture):
                    self.assert_deferred(mode, "merge")
        fixture = self.merged_empty_fixture()
        fixture.executed_workflow += b"# changed execution bytes\n"
        with patch.object(readiness, "api", fixture):
            self.assert_deferred("dependency", "different workflow bytes")

    def test_dependency_base_retarget_requires_edited_trigger(self):
        # An otherwise green producer that ran before retargeting coverage was
        # added cannot establish the complete default-branch PR contract.
        old = WORKFLOW.replace(b"opened, synchronize, reopened, edited",
                               b"opened, synchronize, reopened")
        self.fixture.default_workflow = old
        self.fixture.run_workflow = old
        self.fixture.executed_workflow = old
        self.assert_deferred("dependency", "not landed")

    def test_dependency_base_retarget_activity_block_ready(self):
        edited = WORKFLOW.replace(
            b"    types: [opened, synchronize, reopened, edited]",
            b"    types:\n      - edited\n      - opened\n      - reopened\n      - synchronize")
        self.fixture.default_workflow = edited
        self.fixture.run_workflow = edited
        self.fixture.executed_workflow = edited
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_extra_activity_type_deferred(self):
        self.fixture.default_workflow = WORKFLOW.replace(b"reopened, edited]",
                                                        b"reopened, edited, closed]")
        self.assert_deferred("dependency", "not landed")

    def test_dependency_merge_queue_trigger_required(self):
        self.fixture.default_workflow = WORKFLOW.replace(
            b"  merge_group:\n    types: [checks_requested]\n", b"")
        self.assert_deferred("dependency", "not landed")

    def test_dependency_merge_queue_activity_block_ready(self):
        queue = WORKFLOW.replace(b"    types: [checks_requested]",
                                 b"    types:\n      - checks_requested")
        self.fixture.default_workflow = queue
        self.fixture.run_workflow = queue
        self.fixture.executed_workflow = queue
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_merge_queue_wrong_activity_deferred(self):
        self.fixture.default_workflow = WORKFLOW.replace(b"[checks_requested]", b"[destroyed]")
        self.assert_deferred("dependency", "not landed")

    def test_dependency_merge_queue_run_does_not_replace_pr_evidence(self):
        self.fixture.run["event"] = "merge_group"
        self.assert_deferred("dependency", "latest dependency-review PR run not successful")

    def test_actual_component_workflow_key_order_matches_central_contract(self):
        central = (ROOT / ".github/workflows/dependency-review.yml").read_bytes()
        self.assertEqual(readiness.dependency_contract(COMPONENT_WORKFLOW),
                         readiness.dependency_contract(central))

    def test_actual_component_key_order_preserves_branch_restriction(self):
        central = (ROOT / ".github/workflows/dependency-review.yml").read_bytes()
        changed = COMPONENT_WORKFLOW.replace(b"      - main", b"      - other")
        self.assertNotEqual(readiness.dependency_contract(changed),
                            readiness.dependency_contract(central))

    def test_actual_component_key_order_preserves_activity_restriction(self):
        central = (ROOT / ".github/workflows/dependency-review.yml").read_bytes()
        changed = COMPONENT_WORKFLOW.replace(b", edited]", b"]")
        self.assertNotEqual(readiness.dependency_contract(changed),
                            readiness.dependency_contract(central))

    def test_dependency_not_landed(self):
        self.fixture.default_workflow = WORKFLOW.replace(b"fail-on-severity: high", b"fail-on-severity: low")
        self.assert_deferred("dependency", "not landed")

    def test_dependency_producer_fresh_sha_passes_without_central_update(self):
        fresh = WORKFLOW.replace(OLD.encode(), NEW.encode()).replace(b"v5.0.0", b"v5.1.0")
        self.fixture.default_workflow = fresh
        self.fixture.run_workflow = fresh
        self.fixture.executed_workflow = fresh
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_mutable_action_ref_deferred(self):
        self.fixture.default_workflow = WORKFLOW.replace(OLD.encode(), b"v5")
        self.assert_deferred("dependency", "full-SHA")

    def test_dependency_classic_block_branch_filter_ready(self):
        fresh = WORKFLOW.replace(b"    branches: [main]", b"    branches:\n      - main")
        self.fixture.default_workflow = fresh
        self.fixture.run_workflow = fresh
        self.fixture.executed_workflow = fresh
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_extra_branch_filter_deferred(self):
        self.fixture.default_workflow = WORKFLOW.replace(b"    branches: [main]",
                                                         b"    branches:\n      - main\n      - extra")
        self.assert_deferred("dependency", "not landed")

    def test_dependency_named_official_action_step_ready(self):
        fresh = WORKFLOW.replace(b"      - uses:",
                                 b"      - name: Review dependency changes\n        uses:")
        self.fixture.default_workflow = fresh
        self.fixture.run_workflow = fresh
        self.fixture.executed_workflow = fresh
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_labels_do_not_lock_producer_workflow(self):
        fresh = WORKFLOW.replace(b"name: Dependency review\n", b"name: Dependency safety\n", 1)
        fresh = fresh.replace(b"      - uses:", b"      - name: Validate dependencies\n        uses:")
        self.fixture.default_workflow = fresh
        self.fixture.run_workflow = fresh
        self.fixture.executed_workflow = fresh
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_named_step_arbitrary_run_deferred(self):
        fresh = WORKFLOW.replace(b"      - uses:",
                                 b"      - name: Review dependency changes\n        run: arbitrary\n        uses:")
        self.fixture.default_workflow = fresh
        self.assert_deferred("dependency", "not landed")

    def test_dependency_blank_comment_trailing_whitespace_ready(self):
        fresh = WORKFLOW.replace(b"permissions:\n", b"# Explanation\n\npermissions:  \n")
        self.fixture.default_workflow = fresh
        self.fixture.run_workflow = fresh
        self.fixture.executed_workflow = fresh
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_failed_latest_does_not_search_older_success(self):
        self.fixture.run["conclusion"] = "failure"
        self.assert_deferred("dependency", "latest")
        self.assertEqual(len([call for call in self.fixture.calls if "/runs?event=" in call]), 1)

    def test_dependency_successful_run_failed_job(self):
        self.fixture.jobs[0]["conclusion"] = "failure"
        self.assert_deferred("dependency", "job not successful")

    def test_dependency_run_different_bytes(self):
        self.fixture.executed_workflow += b"# different\n"
        self.assert_deferred("dependency", "different workflow bytes")

    def test_dependency_matching_head_but_executed_merge_workflow_differs(self):
        self.assertEqual(self.fixture.default_workflow, self.fixture.run_workflow)
        self.fixture.executed_workflow = WORKFLOW.replace(b"warn-only: false", b"warn-only: true")
        self.assert_deferred("dependency", "different workflow bytes")

    def test_dependency_direct_head_execution_bound_to_pr(self):
        self.fixture.suite["head_sha"] = HEAD
        self.assertEqual(self.invoke("dependency")[0], 0)

    def test_dependency_direct_head_missing_execution_pr_association(self):
        self.fixture.suite.update(head_sha=HEAD, pull_requests=[])
        self.assert_deferred("dependency", "merged PR association")

    def test_dependency_executed_merge_wrong_parents_deferred(self):
        self.fixture.parents = [BASE, OLD]
        self.assert_deferred("dependency", "current PR head/base")

    def test_dependency_stale_execution_base_association_deferred(self):
        self.fixture.suite["pull_requests"][0]["base"]["sha"] = OLD
        self.assert_deferred("dependency", "execution PR association")

    def test_dependency_check_suite_drift_deferred(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if endpoint.endswith("/check-suites/99"):
                calls += 1
                if calls > 1:
                    value["head_sha"] = OLD
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("dependency", "check suite changed")

    def test_dependency_run_association_drift_deferred(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if "/actions/workflows/dependency-review.yml/runs" in endpoint:
                calls += 1
                if calls > 1:
                    value["workflow_runs"][0]["pull_requests"] = []
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("dependency", "run changed")

    def test_dependency_pr_drift_deferred(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if endpoint.endswith("/pulls/12"):
                calls += 1
                if calls > 1:
                    value["base"]["sha"] = OLD
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("dependency", "PR changed")

    def test_dependency_wrong_base(self):
        self.fixture.pr["base"]["ref"] = "maintenance"
        self.assert_deferred("dependency", "default branch")

    def test_dependency_stale_head(self):
        self.fixture.pr["head"]["sha"] = NEW
        self.assert_deferred("dependency", "head changed")

    def test_dependency_api_404_missing_is_deferred(self):
        def missing(endpoint):
            if "/contents/" in endpoint:
                raise readiness.APIError(endpoint, 404)
            return self.fixture(endpoint)
        with patch.object(readiness, "api", missing):
            self.assert_deferred("dependency", "missing")

    def test_api_denied_is_error_not_deferred(self):
        with patch.object(readiness, "api", side_effect=readiness.APIError("repos/atrinik/example", 403)):
            self.assertEqual(self.invoke("dependency")[0], 2)

    def test_sha_wildcard_accepts_fresh_rust_pin(self):
        self.assertEqual(self.invoke("sha")[0], 0)

    def require_dependency_for_canary(self):
        path = self.root / "config/security-merge-protection.json"
        policy = json.loads(path.read_text())
        policy["dependency_review"] = ["example"]
        path.write_text(json.dumps(policy))

    def effective_check(self, context, app=15368):
        return {"type": "required_status_checks", "parameters": {
            "required_status_checks": [{"context": context, "integration_id": app}]}}

    def test_sha_targeted_dependency_review_missing_failed_or_queued_rejected(self):
        self.require_dependency_for_canary()
        self.assert_deferred("sha", "Dependency review")
        self.fixture.checks[HEAD].append(check("Dependency review", identifier=30, conclusion="failure"))
        self.assert_deferred("sha", "Dependency review")
        self.fixture.checks[HEAD][-1].update(status="queued", conclusion=None, started_at=None)
        self.assert_deferred("sha", "Dependency review")
        self.fixture.checks[HEAD][-1].update(status="completed", conclusion="success")
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_effective_extra_rule_context_required_with_trusted_actions(self):
        self.fixture.effective_rules = [self.effective_check("Extra validation")]
        self.assert_deferred("sha", "Extra validation")
        self.fixture.checks[HEAD].append(check("Extra validation", identifier=30))
        self.fixture.checks[HEAD][-1]["app"]["id"] = 999
        self.assert_deferred("sha", "Extra validation")
        self.fixture.checks[HEAD][-1]["app"]["id"] = 15368
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_effective_dependency_review_required_outside_target_inventory(self):
        self.fixture.effective_rules = [self.effective_check("Dependency review")]
        self.assert_deferred("sha", "Dependency review")

    def test_sha_legacy_protection_context_required(self):
        self.fixture.legacy_checks = {"contexts": ["Legacy check"], "checks": []}
        self.assert_deferred("sha", "Legacy check")
        self.fixture.checks[HEAD].append(check("Legacy check", identifier=30))
        self.assertEqual(self.invoke("sha")[0], 0)

    def legacy_error(self, message, status="404"):
        def response(endpoint):
            if endpoint.endswith("/protection"):
                raise readiness.APIError(endpoint, 404, {"message": message, "status": status})
            return self.fixture(endpoint)
        return patch.object(readiness, "api", response)

    def disabled_legacy_response(self):
        return {"data": {"repository": {"databaseId": 42, "nameWithOwner": "atrinik/example",
                "isArchived": False, "ref": {"name": "main", "branchProtectionRule": None}}}}

    def test_sha_only_exact_unprotected_error_proves_absence(self):
        for message, status, expected in (("Branch not protected", "404", 0),
                ("Resource not found", "404", 2), ("Not Found", "404", 2),
                ("Resource not accessible by integration", "404", 2),
                ("Branch not protected", None, 2), ("Branch not protected", 404, 2)):
            with self.subTest(message=message, status=status), self.legacy_error(message, status):
                self.assertEqual(self.invoke("sha")[0], expected)

    def test_sha_missing_or_malformed_full_protection_not_absence(self):
        for value in ({}, [], None, {"required_status_checks": False},
                {"required_status_checks": {}},
                {"required_status_checks": {"checks": None, "contexts": []}},
                {"required_status_checks": {"checks": [], "contexts": None}}):
            def response(endpoint):
                return value if endpoint.endswith("/protection") else self.fixture(endpoint)
            with self.subTest(value=value), patch.object(readiness, "api", response):
                self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_disabled_legacy_requires_exact_readonly_identity_proof(self):
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.disabled_legacy_response()), stderr="")
        with self.legacy_error("Branch protection has been disabled on this repository."), \
                patch.object(readiness.subprocess, "run", return_value=result) as mocked:
            self.assertEqual(self.invoke("sha")[0], 0)
        self.assertEqual(mocked.call_count, 2)
        args = mocked.call_args.args[0]
        self.assertEqual(args[args.index("--method") + 1], "POST")
        self.assertIn("graphql", args)
        self.assertIn("owner=atrinik", args)
        self.assertIn("name=example", args)
        self.assertIn("qualifiedName=refs/heads/main", args)
        query = next(arg for arg in args if arg.startswith("query="))
        self.assertTrue(query.startswith("query=query LegacyBranchProtection("))
        self.assertNotIn("mutation", query)

    def test_sha_disabled_legacy_ambiguous_identity_or_presence_rejected(self):
        mutations = [lambda r: r.update(errors=[]),
            lambda r: r["data"].update(repository=None),
            lambda r: r["data"]["repository"].update(databaseId=43),
            lambda r: r["data"]["repository"].update(databaseId=True),
            lambda r: r["data"]["repository"].update(nameWithOwner="foreign/example"),
            lambda r: r["data"]["repository"].update(isArchived=True),
            lambda r: r["data"]["repository"].update(ref=None),
            lambda r: r["data"]["repository"]["ref"].update(name="other"),
            lambda r: r["data"]["repository"]["ref"].pop("branchProtectionRule"),
            lambda r: r["data"]["repository"]["ref"].update(branchProtectionRule={"id": "rule"})]
        for index, mutate in enumerate(mutations):
            response = self.disabled_legacy_response()
            mutate(response)
            result = subprocess.CompletedProcess([], 0, stdout=json.dumps(response), stderr="")
            with self.subTest(index=index), self.legacy_error("Branch protection has been disabled on this repository."), \
                    patch.object(readiness.subprocess, "run", return_value=result):
                self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_disabled_legacy_unreadable_or_invalid_graphql_rejected(self):
        for result in (subprocess.CompletedProcess([], 1, stdout="", stderr="denied"),
                       subprocess.CompletedProcess([], 0, stdout="not json", stderr="")):
            with self.subTest(result=result), self.legacy_error("Branch protection has been disabled on this repository."), \
                    patch.object(readiness.subprocess, "run", return_value=result):
                self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_disabled_legacy_fresh_rest_identity_required(self):
        for field, value in (("id", 43), ("full_name", "foreign/example"),
                             ("default_branch", "other"), ("archived", True)):
            count = 0
            def response(endpoint):
                nonlocal count
                if endpoint.endswith("/protection"):
                    raise readiness.APIError(endpoint, 404, {
                        "message": "Branch protection has been disabled on this repository.", "status": "404"})
                current = self.fixture(endpoint)
                if endpoint == "repos/atrinik/example":
                    count += 1
                    if count > 1:
                        current[field] = value
                return current
            with self.subTest(field=field), patch.object(readiness, "api", response), \
                    patch.object(readiness.subprocess, "run") as mocked:
                self.assertNotEqual(self.invoke("sha")[0], 0)
                mocked.assert_not_called()

    def test_sha_disabled_legacy_proof_rechecked_before_acceptance(self):
        initial = self.disabled_legacy_response()
        changed = copy.deepcopy(initial)
        changed["data"]["repository"]["ref"]["branchProtectionRule"] = {"id": "new-rule"}
        results = [subprocess.CompletedProcess([], 0, stdout=json.dumps(value), stderr="")
                   for value in (initial, changed)]
        with self.legacy_error("Branch protection has been disabled on this repository."), \
                patch.object(readiness.subprocess, "run", side_effect=results):
            self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_full_legacy_checks_array_requires_all_bound_contexts(self):
        self.fixture.legacy_checks = {"contexts": [], "checks": [
            {"context": "Legacy check", "app_id": 15368},
            {"context": "Second legacy check", "app_id": None}]}
        self.assert_deferred("sha", "Legacy check")
        self.fixture.checks[HEAD].append(check("Legacy check", identifier=30))
        self.assert_deferred("sha", "Second legacy check")
        self.fixture.checks[HEAD].append(check("Second legacy check", identifier=31))
        self.assertEqual(self.invoke("sha")[0], 0)
        self.fixture.checks[HEAD][-1]["conclusion"] = "failure"
        self.assert_deferred("sha", "Second legacy check")

    def test_sha_legacy_absence_must_remain_readable_at_final_fence(self):
        count = 0
        def response(endpoint):
            nonlocal count
            if endpoint.endswith("/protection"):
                count += 1
                if count > 1:
                    raise readiness.APIError(endpoint, 404, {"message": "Not Found", "status": "404"})
            return self.fixture(endpoint)
        with patch.object(readiness, "api", response):
            self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_non_actions_app_binding_never_satisfied_by_same_named_actions_check(self):
        self.fixture.effective_rules = [self.effective_check("Required checks", 999)]
        self.assert_deferred("sha", "non-Actions app")
        self.fixture.effective_rules = []
        self.fixture.legacy_checks = {"contexts": ["Required checks"],
                                    "checks": [{"context": "Required checks", "app_id": 999}]}
        self.assert_deferred("sha", "non-Actions app")

    def test_sha_unbound_effective_context_still_requires_trusted_actions(self):
        self.fixture.effective_rules = [self.effective_check("Required checks", None)]
        self.assertEqual(self.invoke("sha")[0], 0)
        self.fixture.checks[HEAD][0]["app"]["slug"] = "untrusted"
        self.assert_deferred("sha", "Required checks")

    def test_sha_effective_rule_or_legacy_changes_during_preflight_rejected(self):
        for endpoint_part in ("/rules/branches/", "/protection"):
            with self.subTest(endpoint=endpoint_part):
                count = 0
                def drift(endpoint):
                    nonlocal count
                    if endpoint_part in endpoint:
                        count += 1
                        if count > 1:
                            if "rules/branches" in endpoint:
                                return [self.effective_check("New gate")]
                            return {"required_status_checks": {"contexts": ["New gate"], "checks": []}}
                    return self.fixture(endpoint)
                with patch.object(readiness, "api", drift):
                    self.assert_deferred("sha", "effective required checks changed")

    def test_sha_effective_rules_and_legacy_unreadable_fail_closed(self):
        for endpoint_part in ("/rules/branches/", "/protection"):
            with self.subTest(endpoint=endpoint_part):
                def unreadable(endpoint):
                    if endpoint_part in endpoint:
                        raise readiness.APIError(endpoint, 403)
                    return self.fixture(endpoint)
                with patch.object(readiness, "api", unreadable):
                    code, output = self.invoke("sha")
                self.assertEqual(code, 2, output)

    def test_sha_malformed_effective_checks_rejected(self):
        self.fixture.effective_rules = [self.effective_check("Required checks", "15368")]
        self.assertEqual(self.invoke("sha")[0], 2)
        self.fixture.effective_rules = []
        self.fixture.legacy_checks = {"contexts": "Required checks", "checks": []}
        self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_dormant_selected_patterns_with_all_mode_rejected(self):
        self.fixture.actions_policy["allowed_actions"] = "all"
        self.assert_deferred("sha", "selected policy is not active")
        self.assertFalse(any("/check-runs?" in endpoint for endpoint in self.fixture.calls))

    def test_sha_selected_repository_enablement_and_identity_required(self):
        self.fixture.actions_policy["enabled_repositories"] = "selected"
        self.assertEqual(self.invoke("sha")[0], 0)
        self.fixture.enabled_repositories[0]["id"] = 999
        self.assert_deferred("sha", "not enabled")
        self.fixture.enabled_repositories[0].update(id=42, full_name="foreign/example")
        self.assert_deferred("sha", "not enabled")

    def test_sha_disabled_organization_or_repository_actions_rejected(self):
        self.fixture.actions_policy["enabled_repositories"] = "none"
        self.assert_deferred("sha", "disabled")
        self.fixture.actions_policy["enabled_repositories"] = "all"
        self.fixture.repository_actions["enabled"] = False
        self.assert_deferred("sha", "does not allow external")
        self.fixture.repository_actions.update(enabled=True, allowed_actions="local_only")
        self.assert_deferred("sha", "does not allow external")

    def test_sha_repository_all_or_selected_cannot_relax_organization_ceiling(self):
        for mode in ("all", "selected"):
            self.fixture.repository_actions["allowed_actions"] = mode
            self.assertEqual(self.invoke("sha")[0], 0)
        self.fixture.actions_policy["allowed_actions"] = "all"
        self.assert_deferred("sha", "selected policy is not active")

    def test_sha_actions_mode_or_repository_changes_during_proof_rejected(self):
        for owner in ("orgs/atrinik", "repos/atrinik/example"):
            with self.subTest(owner=owner):
                count = 0
                def drift(endpoint):
                    nonlocal count
                    value = self.fixture(endpoint)
                    if endpoint == owner + "/actions/permissions":
                        count += 1
                        if count > 1:
                            value["allowed_actions"] = "all" if owner.startswith("orgs") else "local_only"
                    return value
                with patch.object(readiness, "api", drift):
                    self.assertEqual(self.invoke("sha")[0], 1)

    def test_sha_actions_policy_unreadable_and_malformed_fail_closed(self):
        for endpoint_part in ("orgs/atrinik/actions/permissions", "repos/atrinik/example/actions/permissions"):
            with self.subTest(endpoint=endpoint_part):
                def unreadable(endpoint):
                    if endpoint == endpoint_part:
                        raise readiness.APIError(endpoint, 403)
                    return self.fixture(endpoint)
                with patch.object(readiness, "api", unreadable):
                    self.assertEqual(self.invoke("sha")[0], 2)
        self.fixture.repository_actions["enabled"] = "true"
        self.assertEqual(self.invoke("sha")[0], 2)
        self.fixture.repository_actions["enabled"] = True
        self.fixture.actions_policy["enabled_repositories"] = "unexpected"
        self.assertEqual(self.invoke("sha")[0], 2)

    def test_sha_selected_membership_change_refenced(self):
        self.fixture.actions_policy["enabled_repositories"] = "selected"
        count = 0
        def drift(endpoint):
            nonlocal count
            value = self.fixture(endpoint)
            if "/actions/permissions/repositories?" in endpoint:
                count += 1
                if count > 1:
                    value = {"total_count": 0, "repositories": []}
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("sha", "not enabled")

    def test_codeql_languages_schema_rejects_mapping_null_and_nonstrings(self):
        for value in ({"rust": False}, None, "rust", [False], [""]):
            with self.subTest(value=value):
                self.fixture.setup["languages"] = value
                code, output = self.invoke("codeql")
                self.assertEqual(code, 2, output)

    def test_codeql_fresh_languages_schema_rejected(self):
        count = 0
        def drift(endpoint):
            nonlocal count
            value = self.fixture(endpoint)
            if endpoint.endswith("/code-scanning/default-setup"):
                count += 1
                if count > 1:
                    value["languages"] = {"rust": False}
            return value
        with patch.object(readiness, "api", drift):
            self.assertEqual(self.invoke("codeql")[0], 2)

    def test_sha_general_github_owned_pin_update(self):
        self.fixture.before = f"steps:\n  - uses: actions/checkout@{OLD} # v5\n".encode()
        self.fixture.after = f"steps:\n  - uses: actions/checkout@{NEW} # v6\n".encode()
        self.assertEqual(self.invoke("sha")[0], 0)

    def allow_canary_action_family(self, pattern):
        self.fixture.live["patterns_allowed"].append(pattern)
        (self.root / "config/actions-selected.json").write_text(json.dumps(self.fixture.live))

    def test_sha_reusable_workflow_update_is_not_action_enforcement_evidence(self):
        self.allow_canary_action_family("atrinik/shared/*")
        for suffix in ("yml", "yaml"):
            with self.subTest(suffix=suffix):
                workflow = ("name: Check\non: pull_request\njobs:\n  validation:\n"
                            f"    uses: atrinik/shared/.github/workflows/check.{suffix}@{{pin}}\n")
                self.fixture.before = workflow.format(pin=OLD).encode()
                self.fixture.after = workflow.format(pin=NEW).encode()
                self.assert_deferred("sha", "reusable workflow reference")
        # GitHub-owned allowances do not turn a reusable workflow into an action.
        self.fixture.before = self.fixture.before.replace(b"atrinik/shared", b"github/shared")
        self.fixture.after = self.fixture.after.replace(b"atrinik/shared", b"github/shared")
        self.assert_deferred("sha", "reusable workflow reference")

    def test_sha_mixed_reusable_and_action_updates_rejected(self):
        self.allow_canary_action_family("atrinik/shared/*")
        workflow = ("name: Check\non: pull_request\njobs:\n  validation:\n"
                    "    uses: atrinik/shared/.github/workflows/check.yml@{workflow_pin}\n"
                    "  local:\n    runs-on: ubuntu-24.04\n    steps:\n"
                    "      - uses: actions/checkout@{action_pin}\n")
        self.fixture.before = workflow.format(workflow_pin=OLD, action_pin=OLD).encode()
        self.fixture.after = workflow.format(workflow_pin=NEW, action_pin=NEW).encode()
        self.assert_deferred("sha", "reusable workflow reference")
        # An unchanged reusable reference is ordinary context, not changed proof.
        self.fixture.after = workflow.format(workflow_pin=OLD, action_pin=NEW).encode()
        result, message = self.invoke("sha")
        self.assertEqual(result, 0, message)

    def test_sha_real_action_subpath_update_remains_eligible(self):
        self.allow_canary_action_family("atrinik/shared/*")
        for action in ("atrinik/shared/actions/check", "atrinik/shared/.github/actions/check",
                       "github/codeql-action/init"):
            with self.subTest(action=action):
                workflow = ("name: Check\non: pull_request\njobs:\n  validation:\n"
                            "    runs-on: ubuntu-24.04\n    steps:\n"
                            f"      - uses: {action}@{{pin}}\n")
                self.fixture.before = workflow.format(pin=OLD).encode()
                self.fixture.after = workflow.format(pin=NEW).encode()
                result, message = self.invoke("sha")
                self.assertEqual(result, 0, message)

    def test_sha_live_old_exact_pin_deferred(self):
        self.fixture.live["patterns_allowed"][-1] = "rust-lang/crates-io-auth-action@" + OLD
        self.assert_deferred("sha", "live selected-actions")

    def test_sha_allowlist_file_update_rejected(self):
        self.fixture.files = [{"filename": "config/actions-selected.json", "status": "modified"}]
        self.assert_deferred("sha", "outside existing workflows")

    def test_sha_arbitrary_code_update_rejected_even_if_patch_hides_it(self):
        self.fixture.files[0]["patch"] = "@@ fake pin-only partial diff"
        self.fixture.after += b"  - run: arbitrary-command\n"
        self.assert_deferred("sha", "more than action pins")

    def test_sha_changed_action_identity_rejected(self):
        self.fixture.after = self.fixture.after.replace(b"rust-lang/crates-io-auth-action", b"docker/setup-buildx-action")
        self.assert_deferred("sha", "action structure")

    def test_sha_version_ref_rejected(self):
        self.fixture.after = self.fixture.after.replace(NEW.encode(), b"v2")
        self.assert_deferred("sha", "more than action pins")

    def test_sha_disallowed_action_update_rejected(self):
        self.fixture.before = self.fixture.before.replace(b"rust-lang", b"untrusted")
        self.fixture.after = self.fixture.after.replace(b"rust-lang", b"untrusted")
        self.assert_deferred("sha", "outside desired")

    def test_sha_latest_failure_masks_old_success(self):
        self.fixture.checks[HEAD].append(check("Required checks", identifier=10, conclusion="failure"))
        self.assert_deferred("sha", "not successful")

    def test_sha_missing_context(self):
        self.fixture.checks[HEAD].pop()
        self.assert_deferred("sha", "missing")

    def test_sha_wrong_head_check_rejected(self):
        self.fixture.checks[HEAD][0]["head_sha"] = OLD
        self.assert_deferred("sha", "missing")

    def test_sha_direct_head_push_checks_rejected(self):
        self.fixture.run["event"] = "push"
        self.assert_deferred("sha", "missing")

    def test_sha_direct_head_workflow_dispatch_checks_rejected(self):
        self.fixture.run["event"] = "workflow_dispatch"
        self.assert_deferred("sha", "missing")

    def test_sha_direct_head_unrelated_pr_checks_rejected(self):
        self.fixture.run["pull_requests"][0]["number"] = 100
        self.assert_deferred("sha", "missing")

    def test_sha_direct_head_wrong_suite_checks_rejected(self):
        self.fixture.run["check_suite_id"] = 100
        self.assert_deferred("sha", "missing")

    def test_sha_direct_head_stale_run_checks_rejected(self):
        self.fixture.run["head_sha"] = OLD
        self.assert_deferred("sha", "missing")

    def advance_canary_base(self):
        self.fixture.pr["base"]["sha"] = OLD
        self.fixture.parents = [OLD, HEAD]

    def test_sha_open_canary_base_advance_rejects_old_direct_head_success(self):
        self.advance_canary_base()
        self.assert_deferred("sha", "required check missing")

    def test_sha_open_canary_base_advance_requires_both_run_and_suite_current(self):
        for stale in ("run", "suite"):
            with self.subTest(stale=stale):
                self.advance_canary_base()
                self.fixture.run["pull_requests"][0]["base"]["sha"] = BASE if stale == "run" else OLD
                self.fixture.suite["pull_requests"][0]["base"]["sha"] = BASE if stale == "suite" else OLD
                self.assert_deferred("sha", "required check missing")

    def test_sha_open_canary_fresh_base_associations_pass_direct_and_merge_checks(self):
        self.advance_canary_base()
        for source in (self.fixture.run, self.fixture.suite):
            source["pull_requests"][0]["base"]["sha"] = OLD
        self.assertEqual(self.invoke("sha")[0], 0)
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_open_canary_old_base_associations_reject_even_with_current_merge_parents(self):
        self.advance_canary_base()
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assert_deferred("sha", "required check missing")

    def test_sha_merged_canary_keeps_recorded_historical_base_proof(self):
        self.fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        self.fixture.pr["base"]["sha"] = OLD
        # The historical merge and association retain their recorded BASE.
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_current_base_failure_or_queued_check_cannot_hide_behind_stale_green(self):
        for status, conclusion in (("completed", "failure"), ("queued", None)):
            with self.subTest(status=status):
                self.advance_canary_base()
                self.fixture.checks[HEAD] = [check("Required checks"), check("Conventional PR title", identifier=2)]
                self.fixture.suite_runs.clear()
                self.add_newer_pr_check(check_status=status, check_conclusion=conclusion,
                                       run_status=status, run_conclusion=conclusion)
                self.fixture.checks[HEAD][-1]["started_at"] = None
                self.fixture.suite_runs[100]["pull_requests"][0]["base"]["sha"] = OLD
                def current_suite(endpoint):
                    value = self.fixture(endpoint)
                    if endpoint.endswith("/check-suites/100"):
                        value["pull_requests"][0]["base"]["sha"] = OLD
                    return value
                with patch.object(readiness, "api", current_suite):
                    self.assert_deferred("sha", "workflow run not successful")

    def test_sha_merged_canary_rejects_conflicting_recorded_run_and_suite_bases(self):
        self.fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        self.fixture.suite["pull_requests"][0]["base"]["sha"] = OLD
        self.assert_deferred("sha", "required check missing")
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assert_deferred("sha", "required check missing")

    def test_sha_merged_canary_common_base_must_match_selected_merge_parents(self):
        self.fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        # A run lists two historical associations, but the suite corroborates
        # only the base absent from this merge commit's parents.
        alternate = copy.deepcopy(self.fixture.run["pull_requests"][0])
        alternate["base"]["sha"] = OLD
        self.fixture.run["pull_requests"].append(alternate)
        self.fixture.suite["pull_requests"] = [alternate]
        self.assert_deferred("sha", "required check missing")

    def test_sha_direct_head_failed_workflow_run_rejected(self):
        self.fixture.run["conclusion"] = "failure"
        self.assert_deferred("sha", "workflow run not successful")

    def add_newer_pr_check(self, check_status="completed", check_conclusion="success",
                           run_status="completed", run_conclusion="success"):
        newer = check("Required checks", identifier=50, status=check_status, conclusion=check_conclusion)
        newer["started_at"] = "2026-10-11T12:01:00Z"
        newer["check_suite"]["id"] = 100
        self.fixture.checks[HEAD].append(newer)
        run = copy.deepcopy(self.fixture.run)
        run.update(id=20, check_suite_id=100, status=run_status, conclusion=run_conclusion)
        self.fixture.suite_runs[100] = run

    def test_sha_newer_failing_pr_suite_does_not_hide_behind_older_green_suite(self):
        self.add_newer_pr_check(check_conclusion="failure", run_conclusion="failure")
        self.assert_deferred("sha", "workflow run not successful")

    def test_sha_newer_pending_pr_suite_does_not_hide_behind_older_green_suite(self):
        self.add_newer_pr_check(check_status="queued", check_conclusion=None,
                               run_status="queued", run_conclusion=None)
        self.assert_deferred("sha", "workflow run not successful")

    def test_sha_newer_queued_null_start_pr_suite_blocks_older_green_suite(self):
        self.add_newer_pr_check(check_status="queued", check_conclusion=None,
                               run_status="queued", run_conclusion=None)
        self.fixture.checks[HEAD][-1]["started_at"] = None
        self.assert_deferred("sha", "workflow run not successful")

    def test_sha_newer_queued_null_start_check_blocks_older_green_in_same_suite(self):
        newer = check("Required checks", identifier=50, status="queued", conclusion=None)
        newer["started_at"] = None
        self.fixture.checks[HEAD].append(newer)
        self.assert_deferred("sha", "required check not successful")

    def test_sha_older_check_starting_later_does_not_hide_newer_failure(self):
        self.add_newer_pr_check(check_conclusion="failure", run_conclusion="failure")
        self.fixture.checks[HEAD][0]["started_at"] = "2026-10-11T12:02:00Z"
        self.assert_deferred("sha", "workflow run not successful")

    def test_sha_newer_green_check_in_failed_pr_run_does_not_hide_behind_older_green_suite(self):
        self.add_newer_pr_check(run_conclusion="failure")
        self.assert_deferred("sha", "workflow run not successful")

    def test_sha_direct_head_run_drift_at_completion_deferred(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if "/actions/runs?check_suite_id=99" in endpoint:
                calls += 1
                if calls > 1:
                    value["workflow_runs"][0]["run_attempt"] += 1
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("sha", "workflow-run evidence changed")

    def test_sha_direct_head_check_drift_at_completion_deferred(self):
        def drift(endpoint):
            value = self.fixture(endpoint)
            if endpoint.endswith("/check-runs/1"):
                value["conclusion"] = "failure"
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("sha", "required check evidence changed")

    def test_sha_new_required_check_at_completion_deferred(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if f"/commits/{HEAD}/check-runs?" in endpoint:
                calls += 1
                if calls > 1:
                    value["check_runs"].append(check("Required checks", identifier=50, conclusion="failure"))
                    value["total_count"] += 1
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("sha", "required check collection changed")

    def test_sha_wrong_app_check_rejected(self):
        self.fixture.checks[HEAD][0]["app"]["id"] = 1
        self.assert_deferred("sha", "missing")

    def test_sha_realistic_merge_sha_checks(self):
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_merged_canary_current_head_direct_checks(self):
        self.fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_merged_canary_historical_merge_checks(self):
        self.fixture.pr.update(state="closed", merged=True, merge_commit_sha=NEW)
        self.fixture.checks[MERGE] = [check("Required checks", MERGE), check("Conventional PR title", MERGE, 2)]
        self.fixture.checks[HEAD] = []
        self.assertEqual(self.invoke("sha")[0], 0)

    def test_sha_closed_unmerged_canary_deferred(self):
        self.fixture.pr.update(state="closed", merged=False)
        self.assert_deferred("sha", "merged or open")

    def test_sha_stale_merge_run_head(self):
        self.fixture.checks[MERGE] = [check("Required checks", MERGE)]
        self.fixture.checks[HEAD] = []
        self.fixture.run["head_sha"] = OLD
        self.assert_deferred("sha", "missing")

    def test_sha_stale_merge_commit(self):
        self.fixture.parents = [BASE, OLD]
        self.assert_deferred("sha", "stale")

    def test_sha_fresh_pr_head_required_at_completion(self):
        calls = 0
        def drift(endpoint):
            nonlocal calls
            value = self.fixture(endpoint)
            if endpoint.endswith("/pulls/12"):
                calls += 1
                if calls > 1:
                    value["head"]["sha"] = NEW
            return value
        with patch.object(readiness, "api", drift):
            self.assert_deferred("sha", "changed during")

    def test_codeql_success_current_head_rust(self):
        self.assertEqual(self.invoke("codeql")[0], 0)

    def test_codeql_large_history_stops_after_current_coverage(self):
        old = copy.deepcopy(self.fixture.analyses[0])
        old.update(commit_sha=OLD, category="/partition:retired/language:rust")
        self.fixture.analyses.extend([old] * 1200)
        self.assertEqual(self.invoke("codeql")[0], 0)
        self.assertEqual(len([call for call in self.fixture.calls if "/analyses?" in call]), 2)

    def test_codeql_retired_category_failure_does_not_gate(self):
        old = copy.deepcopy(self.fixture.analyses[0])
        old.update(commit_sha=OLD, category="/partition:retired/language:rust", error="old failure")
        self.fixture.analyses.insert(0, old)
        self.assertEqual(self.invoke("codeql")[0], 0)

    def test_codeql_all_live_configured_languages_required(self):
        self.fixture.setup["languages"].append("python")
        self.assert_deferred("codeql", "configured CodeQL language")

    def test_codeql_javascript_typescript_alias_normalized(self):
        self.fixture.setup["languages"] = ["rust", "javascript/typescript"]
        second = copy.deepcopy(self.fixture.analyses[0])
        second.update(category="/language:javascript-typescript", environment='{"language":"javascript-typescript"}')
        self.fixture.analyses.append(second)
        self.assertEqual(self.invoke("codeql")[0], 0)

    def enable_advanced(self, partitions=None):
        if partitions is None:
            partitions = PARTITIONS
        # The policy minimum remains independent of the producer declarations.
        (self.root / "config/codeql-advanced-setup.json").write_text(json.dumps({
            "repositories": ["example"], "required_partitions": {"example": [
                {"scope": item["scope"], "language": item["language"]} for item in PARTITIONS]}}))
        self.set_classifier_source(classifier_source(partitions))
        (self.root / "config/security-merge-protection.json").write_text('{"codeql_required_languages": {}}')
        self.fixture.analyses = []
        self.fixture.codeql_jobs = []
        for index, item in enumerate(partitions):
            display, category, language = item["display"], item["category"], item["language"]
            job = {"id": index + 1, "name": f"CodeQL analysis ({display})", "head_sha": HEAD,
                   "status": "completed", "conclusion": "success",
                   "started_at": "2026-10-11T11:59:00Z", "completed_at": "2026-10-11T12:01:00Z"}
            self.fixture.codeql_jobs.append(job)
            self.fixture.analyses.append({"id": index + 1, "tool": {"name": "CodeQL"},
                "analysis_key": ".github/workflows/codeql.yml:analyze", "category": category,
                "environment": json.dumps({"display": display, "category": category, "language": language,
                                            "scope": item["scope"], "run": ""}),
                "commit_sha": HEAD, "ref": "refs/heads/main", "error": "", "rules_count": 58,
                "created_at": "2026-10-11T12:00:00Z"})
        for name in ("CodeQL classification", "CodeQL validation"):
            job = copy.deepcopy(self.fixture.codeql_jobs[0])
            job.update(id=999, name=name, check_run_url="https://api.github.com/repos/atrinik/example/check-runs/999")
            self.fixture.codeql_jobs.append(job)

    def set_classifier_source(self, source):
        self.fixture.codeql_sources["tools/ci/classify_changes.py"] = source
        self.fixture.codeql_head_sources["tools/ci/classify_changes.py"] = source

    def set_codeql_workflow(self, source):
        self.fixture.codeql_sources[".github/workflows/codeql.yml"] = source
        self.fixture.codeql_head_sources[".github/workflows/codeql.yml"] = source

    def codeql_document(self):
        import yaml
        # Preserve Actions' on key when constructing modified fixtures.
        return yaml.safe_load(CODEQL_WORKFLOW.replace(b"\non:", b"\n'on':"))

    def set_codeql_document(self, document):
        import yaml
        self.set_codeql_workflow(yaml.safe_dump(document, sort_keys=False).encode())

    def test_codeql_yaml_dependency_missing_fails_closed_without_affecting_other_modes(self):
        self.enable_advanced()
        with patch.dict(sys.modules, {"yaml": None}):
            result, message = self.invoke("codeql")
            self.assertEqual(result, 2, message)
            self.assertIn("install requirements-validation.txt", message)
            self.assertEqual(self.invoke("dependency")[0], 0)

    def test_codeql_advanced_full_run_cannot_replace_pull_request_trigger(self):
        for event in ('push', 'schedule', 'workflow_dispatch'):
            for triggers in (None, 'push', ['push', 'workflow_dispatch'],
                             {'push': {'branches': ['main']}, 'schedule': [{'cron': '0 0 * * *'}],
                              'workflow_dispatch': None}, {'pull_request_target': None}):
                with self.subTest(event=event, triggers=triggers):
                    self.enable_advanced()
                    self.fixture.codeql_run['event'] = event
                    document = self.codeql_document()
                    if triggers is None:
                        del document['on']
                    else:
                        document['on'] = triggers
                    self.set_codeql_document(document)
                    self.assert_deferred('codeql', 'pull_request trigger missing')

    def test_codeql_advanced_pull_request_filters_cannot_skip_required_producer(self):
        rejected = [False, [], 'main', {'branches': ['develop']},
                    {'branches': []}, {'branches': 'main'}, {'branches': None},
                    {'branches': ['main', '!main']}, {'branches': ['**']},
                    {'branches': ['main', 3]}, {'branches-ignore': ['main']},
                    {'branches-ignore': ['unrelated']}, {'paths': ['client/**']},
                    {'paths': ['**']}, {'paths-ignore': ['docs/**']},
                    {'branches': ['main'], 'paths-ignore': []},
                    {'tags': ['v*']}, {'types': None}, {'types': 'opened'},
                    {'types': []}, {'types': ['opened', 'reopened']},
                    {'types': ['synchronize', 'reopened']}, {'types': ['opened', 'synchronize']},
                    {'types': ['opened', 'synchronize', 'reopened', False]},
                    {'types': ['opened', 'synchronize', 'reopened', 'invented']},
                    {'types': ['opened', 'synchronize', 'reopened', 'opened']}]
        for trigger in rejected:
            with self.subTest(trigger=trigger):
                self.enable_advanced()
                document = self.codeql_document()
                document['on']['pull_request'] = trigger
                self.set_codeql_document(document)
                self.assert_deferred('codeql', 'pull_request')

    def test_codeql_advanced_pull_request_event_forms_and_additional_types_ready(self):
        for triggers in ('pull_request', ['push', 'pull_request', 'workflow_dispatch'],
                         {'pull_request': None}, {'pull_request': {}},
                         {'pull_request': {'branches': ['main', 'maintenance']}},
                         {'pull_request': {'types': ['opened', 'synchronize', 'reopened']}},
                         {'pull_request': {'branches': ['main'], 'types': [
                             'ready_for_review', 'edited', 'reopened', 'opened', 'synchronize']}}):
            with self.subTest(triggers=triggers):
                self.enable_advanced()
                document = self.codeql_document()
                document['on'] = triggers
                self.set_codeql_document(document)
                result, message = self.invoke('codeql')
                self.assertEqual(result, 0, message)

    def test_codeql_advanced_pull_request_uses_fresh_default_branch(self):
        self.enable_advanced()
        branch = 'release/current'
        self.fixture.metadata['default_branch'] = branch
        self.fixture.codeql_run['head_branch'] = branch
        for analysis in self.fixture.analyses:
            analysis['ref'] = 'refs/heads/' + branch
        self.assert_deferred('codeql', 'pull_request does not cover the default branch')
        document = self.codeql_document()
        document['on']['pull_request']['branches'] = [branch]
        document['on']['push']['branches'] = [branch]
        self.set_codeql_document(document)
        result, message = self.invoke('codeql')
        self.assertEqual(result, 0, message)
        self.assertIn('repos/atrinik/example/branches/release%2Fcurrent', self.fixture.calls)

    def test_codeql_advanced_default_branch_change_during_preflight_deferred(self):
        self.enable_advanced()
        reads = 0

        def drift(endpoint):
            nonlocal reads
            result = self.fixture(endpoint)
            if endpoint == 'repos/atrinik/example':
                reads += 1
                if reads > 1:
                    result = dict(result, default_branch='release/current')
            return result

        with patch.object(readiness, 'api', drift):
            self.assert_deferred('codeql', 'repository default branch changed')

    def test_codeql_advanced_comments_cannot_prove_executable_wiring(self):
        self.enable_advanced()
        source = b"name: CodeQL\njobs:\n  fake:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n"
        source += b"\n".join(b"# " + line for line in CODEQL_WORKFLOW.splitlines())
        self.set_codeql_workflow(source)
        self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_disconnected_wiring_rejected_despite_green_uploads(self):
        changes = [
            (("classify", "outputs", "matrix"), '${{ steps.other.outputs.codeql_matrix }}'),
            (("classify", "outputs", "run"), 'true'),
            (("classify", "steps", 1, "id"), 'other'),
            (("classify", "steps", 1, "env", "EVENT_NAME"), 'push'),
            (("classify", "steps", 1, "env", "HEAD_SHA"), '${{ github.event.pull_request.base.sha }}'),
            (("analyze", "needs"), 'other'),
            (("analyze", "if"), 'false'),
            (("analyze", "name"), 'CodeQL analysis (C/C++ client)'),
            (("analyze", "strategy", "matrix"), {"include": PARTITIONS}),
            (("analyze", "strategy", "matrix"), '${{ fromJSON(needs.other.outputs.matrix) }}'),
            (("analyze", "steps", 2, "with", "config-file"), 'unrelated-codeql.yml'),
            (("analyze", "steps", 2, "with", "config-file"), '${{ steps.other.outputs.codeql_config }}'),
            (("analyze", "steps", 2, "with", "languages"), 'c-cpp'),
            (("analyze", "steps", 2, "with", "build-mode"), 'autobuild'),
            (("analyze", "steps", 3, "with", "category"), '/partition:client/language:c-cpp'),
            (("codeql-validation", "if"), 'success()'),
            (("codeql-validation", "needs"), ['classify']),
            (("codeql-validation", "strategy"), {"matrix": {"fake": [1]}}),
        ]
        for path, value in changes:
            with self.subTest(path=path, value=value):
                self.enable_advanced()
                document = self.codeql_document()
                target = document["jobs"]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                self.set_codeql_document(document)
                self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_classifier_and_aggregate_arguments_are_executable(self):
        mutations = [
            ('classify', '--event "${EVENT_NAME}"', '--event push'),
            ('classify', '--event "${EVENT_NAME}"', "--event '${EVENT_NAME}'"),
            ('classify', '--event "${EVENT_NAME}"', '--event "\\${EVENT_NAME}"'),
            ('classify', '--github-output "${GITHUB_OUTPUT}"', '--github-output /dev/null'),
            ('analyze', '--codeql-scope "${{ matrix.scope }}"', '--codeql-scope client'),
            ('analyze', 'build/codeql-config.yml', 'build/disconnected-config.yml'),
            ('codeql-validation', "'${{ needs.classify.result }}'", 'success'),
            ('codeql-validation', "'${{ needs.classify.outputs.run }}'", 'true'),
            ('codeql-validation', "'${{ needs.analyze.result }}'", 'success'),
        ]
        for name, before, after in mutations:
            with self.subTest(name=name, before=before):
                self.enable_advanced()
                document = self.codeql_document()
                step = document['jobs'][name]['steps'][1]
                self.assertIn(before, step['run'])
                step['run'] = step['run'].replace(before, after)
                self.set_codeql_document(document)
                self.assert_deferred("codeql", "executable workflow contract")
        for name in ('classify', 'analyze', 'codeql-validation'):
            for mutation in ('comment-only', 'trailing-command', 'leading-command', 'substitution', 'duplicate-option'):
                with self.subTest(name=name, mutation=mutation):
                    self.enable_advanced()
                    document = self.codeql_document()
                    step = document['jobs'][name]['steps'][1]
                    run = step['run']
                    if mutation == 'comment-only':
                        step['run'] = '\n'.join('# ' + line for line in run.splitlines()) + '\ntrue\n'
                    elif mutation == 'trailing-command':
                        step['run'] = run.rstrip() + '; true\n'
                    elif mutation == 'leading-command':
                        step['run'] = 'true\n' + run
                    elif mutation == 'substitution':
                        step['run'] = run.replace('python3', '$(echo python3)', 1)
                    else:
                        step['run'] = run.rstrip() + ' --event push\n'
                    self.set_codeql_document(document)
                    self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_disabled_or_overridden_execution_rejected(self):
        targets = [('classify', None), ('analyze', None), ('codeql-validation', None),
                   ('classify', 1), ('analyze', 1), ('analyze', 2), ('analyze', 3),
                   ('codeql-validation', 1)]
        for name, index in targets:
            for key, value in [('continue-on-error', True), ('if', 'false'),
                               ('env', {'PYTHONPATH': 'untrusted'}),
                               ('defaults', {'run': {'working-directory': 'elsewhere'}}),
                               ('shell', 'bash {0}'), ('working-directory', 'elsewhere')]:
                with self.subTest(name=name, index=index, override=key):
                    self.enable_advanced()
                    document = self.codeql_document()
                    target = document['jobs'][name]
                    if index is not None:
                        target = target['steps'][index]
                    target[key] = value
                    self.set_codeql_document(document)
                    self.assert_deferred("codeql", "executable workflow contract")
        for key, value in [('env', {'GITHUB_OUTPUT': '/dev/null'}),
                           ('defaults', {'run': {'shell': 'true {0}'}})]:
            with self.subTest(workflow_override=key):
                self.enable_advanced()
                document = self.codeql_document()
                document[key] = value
                self.set_codeql_document(document)
                self.assert_deferred("codeql", "executable workflow contract")
        self.enable_advanced()
        document = self.codeql_document()
        document['jobs']['analyze'] = {'uses': 'foreign/repo/.github/workflows/codeql.yml@' + NEW}
        self.set_codeql_document(document)
        self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_current_complete_checkout_required(self):
        for name in ('classify', 'analyze', 'codeql-validation'):
            for key, value in [('ref', 'main'), ('ref', OLD), ('repository', 'foreign/repo'),
                               ('path', 'elsewhere'), ('sparse-checkout', 'only-one-file')]:
                with self.subTest(name=name, key=key, value=value):
                    self.enable_advanced()
                    document = self.codeql_document()
                    document['jobs'][name]['steps'][0].setdefault('with', {})[key] = value
                    self.set_codeql_document(document)
                    self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_step_order_actions_and_duplicate_ids_rejected(self):
        for mutation in ('order', 'extra', 'duplicate-id', 'mutable-init', 'foreign-analyze'):
            with self.subTest(mutation=mutation):
                self.enable_advanced()
                document = self.codeql_document()
                steps = document['jobs']['analyze']['steps']
                if mutation == 'order':
                    steps[2], steps[3] = steps[3], steps[2]
                elif mutation == 'extra':
                    steps.insert(2, {'run': 'echo overwrite generated config'})
                elif mutation == 'duplicate-id':
                    steps[0]['id'] = 'classify'
                elif mutation == 'mutable-init':
                    steps[2]['uses'] = 'github/codeql-action/init@v4'
                else:
                    steps[3]['uses'] = 'foreign/codeql-action/analyze@' + NEW
                self.set_codeql_document(document)
                self.assert_deferred("codeql", "executable workflow contract")

    def test_codeql_advanced_duplicate_yaml_is_unreadable(self):
        for source in (CODEQL_WORKFLOW + b'\njobs: {}\n',
                       CODEQL_WORKFLOW.replace(b'      - id: classify', b'      - id: classify\n        id: other', 1),
                       CODEQL_WORKFLOW.replace(b'    if: always()', b'    if: false\n    if: always()'),
                       b'jobs: [unclosed'):
            with self.subTest(source=source[-50:]):
                self.enable_advanced()
                self.set_codeql_workflow(source)
                result, message = self.invoke('codeql')
                self.assertEqual(result, 2, message)
                self.assertIn('YAML malformed or ambiguous', message)

    def test_codeql_advanced_formatting_and_owner_action_updates_ready(self):
        self.enable_advanced()
        document = self.codeql_document()
        for job in document['jobs'].values():
            for step in job['steps']:
                if 'uses' in step:
                    step['uses'] = step['uses'].split('@')[0] + '@' + NEW
            job['steps'][0].setdefault('with', {}).update(
                ref='${{github.sha}}', repository='${{ github.repository }}')
        for name in ('classify', 'analyze'):
            step = document['jobs'][name]['steps'][1]
            step['run'] = ('# executable invocation follows\npython3 tools/ci/classify_changes.py '
                           '--codeql-config build/new-config.yml --github-output "$GITHUB_OUTPUT" '
                           '--head "$HEAD_SHA" --base "$BASE_SHA" --event "$EVENT_NAME"')
            if name == 'analyze':
                step['run'] += ' --codeql-scope "${{matrix.scope}}"'
        document['jobs']['analyze']['if'] = "${{needs.classify.outputs.run=='true'}}"
        document['jobs']['analyze']['strategy']['matrix'] = '${{ fromJSON ( needs.classify.outputs.matrix ) }}'
        document['jobs']['analyze']['steps'][2]['with']['languages'] = '${{matrix.language}}'
        document['jobs']['analyze']['steps'][3]['with']['category'] = '${{ matrix.category}}'
        document['jobs']['codeql-validation']['if'] = '${{ always ( ) }}'
        self.set_codeql_document(document)
        result, message = self.invoke('codeql')
        self.assertEqual(result, 0, message)

    def test_codeql_advanced_reduced_source_and_jobs_below_policy_deferred(self):
        self.enable_advanced(PARTITIONS[:1])
        self.assert_deferred("codeql", "omits required partition coverage")

    def test_codeql_advanced_reduced_jobs_with_full_source_deferred(self):
        self.enable_advanced()
        self.fixture.codeql_jobs = self.fixture.codeql_jobs[:1] + self.fixture.codeql_jobs[-2:]
        self.fixture.analyses = self.fixture.analyses[:1]
        self.assert_deferred("codeql", "every declared partition")

    def test_codeql_advanced_additional_declared_partition_ready(self):
        extra = {"display": "Extra C/C++", "scope": "extra", "language": "c-cpp",
                 "category": "/partition:extra/language:c-cpp", "run": True}
        self.enable_advanced(PARTITIONS + [extra])
        self.assertEqual(self.invoke("codeql")[0], 0)

    def test_codeql_advanced_additional_declaration_requires_job(self):
        extra = {"display": "Extra C/C++", "scope": "extra", "language": "c-cpp",
                 "category": "/partition:extra/language:c-cpp", "run": True}
        self.enable_advanced(PARTITIONS + [extra])
        del self.fixture.codeql_jobs[5]
        self.assert_deferred("codeql", "every declared partition")

    def test_codeql_advanced_category_rename_preserves_semantic_minimum(self):
        partitions = copy.deepcopy(PARTITIONS)
        partitions[0]["category"] = "/partition:client-renamed/language:c-cpp"
        self.enable_advanced(partitions)
        self.assertEqual(self.invoke("codeql")[0], 0)

    def test_codeql_advanced_upload_matches_declared_scope_category_and_language(self):
        for field, value in (("scope", "server"), ("category", "/other/language:c-cpp"),
                             ("language", "python")):
            with self.subTest(field=field):
                self.enable_advanced()
                analysis = self.fixture.analyses[0]
                environment = json.loads(analysis["environment"])
                environment[field] = value
                analysis["environment"] = json.dumps(environment)
                if field == "category":
                    analysis["category"] = value
                self.assert_deferred("codeql", "selected full-run job")

    def test_codeql_advanced_duplicate_declarations_rejected(self):
        for field in ("display", "category", "scope"):
            with self.subTest(field=field):
                partitions = copy.deepcopy(PARTITIONS)
                partitions[1][field] = partitions[0][field]
                self.enable_advanced(partitions)
                self.assert_deferred("codeql", "declarations duplicated")

    def test_codeql_advanced_nonliteral_declaration_deferred(self):
        self.enable_advanced()
        self.set_classifier_source(CLASSIFIER.replace(b"entries.append({", b"entries.append(dict(", 1))
        self.assertEqual(self.invoke("codeql")[0], 2)  # Invalid Python is unreadable evidence.
        self.set_classifier_source(CLASSIFIER + b"\n")
        source = CLASSIFIER.replace(b"    matrix =", b"    entries.append(dynamic_partition)\n    matrix =")
        self.set_classifier_source(source)
        self.assert_deferred("codeql", "not literal")

    def test_codeql_advanced_unsupported_matrix_mutation_deferred(self):
        self.enable_advanced()
        source = CLASSIFIER.replace(b"    matrix =", b"    entries.extend(extra)\n    matrix =")
        self.set_classifier_source(source)
        self.assert_deferred("codeql", "shape unsupported")

    def test_codeql_advanced_missing_or_malformed_minima_unreadable(self):
        for minima in (None, [], {}, [{"scope": "client"}],
                       [{"scope": "client", "language": "c-cpp"}] * 2):
            with self.subTest(minima=minima):
                self.enable_advanced()
                policy = {"repositories": ["example"], "required_partitions": {"example": minima}}
                (self.root / "config/codeql-advanced-setup.json").write_text(json.dumps(policy))
                self.assertEqual(self.invoke("codeql")[0], 2)
        (self.root / "config/codeql-advanced-setup.json").write_text('{"repositories": ["example"]}')
        self.assertEqual(self.invoke("codeql")[0], 2)

    def test_codeql_advanced_current_full_producer_all_partitions_ready(self):
        self.enable_advanced()
        self.assertEqual(self.invoke("codeql")[0], 0)

    def test_codeql_advanced_large_retired_history_ready(self):
        self.enable_advanced()
        retired = copy.deepcopy(self.fixture.analyses[0])
        retired.update(commit_sha=OLD, category="/retired/language:c-cpp", environment='{"display":"Retired"}')
        self.fixture.analyses.insert(0, retired)
        self.fixture.analyses.extend([retired] * 1200)
        self.assertEqual(self.invoke("codeql")[0], 0)
        self.assertEqual(len([call for call in self.fixture.calls if "/analyses?" in call]), 2)

    def test_codeql_advanced_partial_uploads_deferred(self):
        self.enable_advanced()
        self.fixture.analyses.pop()
        self.assert_deferred("codeql", "partition upload missing")

    def test_codeql_advanced_latest_failed_category_masks_success(self):
        self.enable_advanced()
        failed = copy.deepcopy(self.fixture.analyses[0]); failed["error"] = "failed"
        self.fixture.analyses.insert(0, failed)
        self.assert_deferred("codeql", "failed")

    def test_codeql_advanced_wrong_producer_deferred(self):
        self.enable_advanced()
        self.fixture.analyses[0]["analysis_key"] = ".github/workflows/other.yml:analyze"
        self.assert_deferred("codeql", "partition upload missing")

    def test_codeql_advanced_partial_pr_event_deferred(self):
        self.enable_advanced()
        self.fixture.codeql_run["event"] = "pull_request"
        self.assert_deferred("codeql", "full-event")

    def test_codeql_advanced_wrong_app_deferred(self):
        self.enable_advanced()
        self.fixture.codeql_check["app"]["id"] = 1
        self.assert_deferred("codeql", "trusted current-head producer")

    def test_codeql_advanced_stale_source_deferred(self):
        self.enable_advanced()
        self.fixture.codeql_head_sources["tools/ci/classify_changes.py"] += b"# different\n"
        self.assert_deferred("codeql", "source is stale")

    def test_codeql_advanced_upload_outside_job_window_deferred(self):
        self.enable_advanced()
        self.fixture.analyses[0]["created_at"] = "2026-10-11T13:00:00Z"
        self.assert_deferred("codeql", "selected full-run job")

    def prepare_analysis_recheck(self, advanced):
        if advanced:
            self.enable_advanced()
        self.fixture.analysis_reads = 0
        self.fixture.fresh_analyses = copy.deepcopy(self.fixture.analyses)

    def test_codeql_newer_failure_during_preflight_deferred(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                failed = copy.deepcopy(self.fixture.analyses[0])
                failed.update(id=1000, error="new analysis failed")
                self.fixture.fresh_analyses.insert(0, failed)
                self.assert_deferred("codeql", "failed")
                self.assertEqual(self.fixture.analysis_reads, 2)

    def test_codeql_newer_zero_rules_during_preflight_deferred(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                empty = copy.deepcopy(self.fixture.analyses[0])
                empty.update(id=1000, rules_count=0)
                self.fixture.fresh_analyses.insert(0, empty)
                self.assert_deferred("codeql", "no executed rules")

    def test_codeql_deleted_selected_analysis_during_preflight_deferred(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                del self.fixture.fresh_analyses[0]
                self.assert_deferred("codeql", "missing within bounded evidence")

    def test_codeql_replaced_successful_coverage_during_preflight_deferred(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                replacement = copy.deepcopy(self.fixture.analyses[0])
                replacement["id"] = 1000
                self.fixture.fresh_analyses.insert(0, replacement)
                self.assert_deferred("codeql", "analysis coverage changed during preflight")

    def test_codeql_selected_analysis_mutation_during_preflight_deferred(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                self.fixture.fresh_analyses[0]["rules_count"] += 1
                self.assert_deferred("codeql", "analysis coverage changed during preflight")

    def test_codeql_new_retired_analysis_during_preflight_preserves_readiness(self):
        for advanced in (False, True):
            with self.subTest(advanced=advanced):
                self.prepare_analysis_recheck(advanced)
                retired = copy.deepcopy(self.fixture.analyses[0])
                retired.update(id=1000, commit_sha=OLD, category="/retired/language:c-cpp",
                               environment='{"display":"Retired"}')
                self.fixture.fresh_analyses.insert(0, retired)
                self.assertEqual(self.invoke("codeql")[0], 0)
                self.assertEqual(self.fixture.analysis_reads, 2)

    def test_codeql_default_new_failure_with_changed_language_does_not_fallback(self):
        self.prepare_analysis_recheck(False)
        failed = copy.deepcopy(self.fixture.analyses[0])
        failed.update(id=1000, error="new analysis failed", environment='{"language":"python"}')
        self.fixture.fresh_analyses.insert(0, failed)
        self.assert_deferred("codeql", "failed")

    def test_codeql_advanced_new_failure_without_display_does_not_fallback(self):
        for environment in ('{}', '{"display":"Renamed"}'):
            with self.subTest(environment=environment):
                self.prepare_analysis_recheck(True)
                failed = copy.deepcopy(self.fixture.analyses[0])
                failed.update(id=1000, error="new analysis failed", environment=environment)
                self.fixture.fresh_analyses.insert(0, failed)
                self.assert_deferred("codeql", "partition upload missing")

    def test_codeql_latest_error_masks_older_success(self):
        failed = copy.deepcopy(self.fixture.analyses[0])
        failed.update(id=2, error="analysis failed")
        self.fixture.analyses.insert(0, failed)
        self.assert_deferred("codeql", "failed")

    def test_codeql_success_old_head_deferred(self):
        self.fixture.analyses[0]["commit_sha"] = OLD
        self.assert_deferred("codeql", "current default head")

    def test_codeql_missing_rust_analysis_deferred(self):
        self.fixture.analyses[0]["environment"] = '{"language":"python"}'
        self.fixture.analyses[0]["category"] = "/language:python"
        self.assert_deferred("codeql", "language")

    def test_codeql_no_executed_rules_deferred(self):
        self.fixture.analyses[0]["rules_count"] = 0
        self.assert_deferred("codeql", "no executed rules")

    def test_archived_repository_deferred(self):
        self.fixture.metadata["archived"] = True
        self.assert_deferred("dependency", "archived")

    def test_malformed_api_evidence_error(self):
        self.fixture.metadata.pop("default_branch")
        self.assertEqual(self.invoke("dependency")[0], 2)

    def test_api_subprocess_uses_only_get_and_version(self):
        self.api_patch.stop()
        result = subprocess.CompletedProcess([], 0, stdout='{}', stderr='')
        with patch.object(readiness.subprocess, "run", return_value=result) as mocked:
            readiness.api("repos/atrinik/example")
        args = mocked.call_args.args[0]
        self.assertEqual(args[args.index("--method") + 1], "GET")
        self.assertIn("X-GitHub-Api-Version: 2026-03-10", args)

    def test_api_error_retains_structured_response_without_printing_body(self):
        self.api_patch.stop()
        for body in ('{"message":"Branch not protected","status":"404"}', "not json", "null"):
            result = subprocess.CompletedProcess([], 1, stdout=body, stderr="gh: error (HTTP 404)")
            with self.subTest(body=body), patch.object(readiness.subprocess, "run", return_value=result):
                with self.assertRaises(readiness.APIError) as raised:
                    readiness.api("repos/atrinik/example/branches/main/protection")
                self.assertEqual(raised.exception.status, 404)
                self.assertEqual(raised.exception.response, json.loads(body) if body != "not json" else None)
                self.assertNotIn(body, str(raised.exception))

    def test_executable_wrapper_is_bash_and_delegates_python(self):
        wrapper = ROOT / "bin/security-readiness"
        self.assertEqual(wrapper.read_text().splitlines()[0], "#!/usr/bin/env bash")
        self.assertIn('exec python3 "${root}/lib/security_readiness.py" "$@"', wrapper.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
