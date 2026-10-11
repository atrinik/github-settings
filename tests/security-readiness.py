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
from urllib.parse import parse_qs, urlparse


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
CODEQL_WORKFLOW = b"""name: CodeQL
jobs:
  analyze:
    name: CodeQL analysis (${{ matrix.display }})
    run: python3 tools/ci/classify_changes.py
    languages: ${{ matrix.language }}
    category: ${{ matrix.category }}
  validation:
    name: CodeQL validation
    run: python3 tools/ci/require_checks.py optional '${{ needs.classify.outputs.run }}' '${{ needs.analyze.result }}'
"""
CLASSIFIER = b"""FULL_EVENTS = {'push', 'schedule', 'workflow_dispatch', 'merge_group'}
def main():
    if arguments.event in FULL_EVENTS:
        full = True
        paths = []
"""


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
            sources = self.codeql_sources if "ref=main" in endpoint else self.codeql_head_sources
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
        if endpoint.endswith("/protection/required_status_checks"):
            if self.legacy_checks is None:
                raise readiness.APIError(endpoint, 404)
            return copy.deepcopy(self.legacy_checks)
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
        if "/branches/main" in endpoint:
            return {"commit": {"sha": self.branch_head}}
        if "/code-scanning/analyses?" in endpoint:
            page = int(parse_qs(urlparse(endpoint).query)["page"][0])
            return copy.deepcopy(self.analyses[(page - 1) * 100:page * 100])
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
        (self.root / "config/codeql-advanced-setup.json").write_text('{"repositories": []}')
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
        for endpoint_part in ("/rules/branches/", "/protection/required_status_checks"):
            with self.subTest(endpoint=endpoint_part):
                count = 0
                def drift(endpoint):
                    nonlocal count
                    if endpoint_part in endpoint:
                        count += 1
                        if count > 1:
                            if "rules/branches" in endpoint:
                                return [self.effective_check("New gate")]
                            return {"contexts": ["New gate"], "checks": []}
                    return self.fixture(endpoint)
                with patch.object(readiness, "api", drift):
                    self.assert_deferred("sha", "effective required checks changed")

    def test_sha_effective_rules_and_legacy_unreadable_fail_closed(self):
        for endpoint_part in ("/rules/branches/", "/protection/required_status_checks"):
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
        self.assertEqual(len([call for call in self.fixture.calls if "/analyses?" in call]), 1)

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

    def enable_advanced(self):
        (self.root / "config/codeql-advanced-setup.json").write_text('{"repositories": ["example"]}')
        (self.root / "config/security-merge-protection.json").write_text('{"codeql_required_languages": {}}')
        displays = [("C/C++ client", "client", "c-cpp"), ("C/C++ server", "server", "c-cpp"),
                    ("C/C++ core", "core", "c-cpp"), ("Python", "core", "python"),
                    ("GitHub Actions", "core", "actions")]
        self.fixture.analyses = []
        self.fixture.codeql_jobs = []
        for index, (display, partition, language) in enumerate(displays):
            category = f"/partition:{partition}/language:{language}"
            job = {"id": index + 1, "name": f"CodeQL analysis ({display})", "head_sha": HEAD,
                   "status": "completed", "conclusion": "success",
                   "started_at": "2026-10-11T11:59:00Z", "completed_at": "2026-10-11T12:01:00Z"}
            self.fixture.codeql_jobs.append(job)
            self.fixture.analyses.append({"id": index + 1, "tool": {"name": "CodeQL"},
                "analysis_key": ".github/workflows/codeql.yml:analyze", "category": category,
                "environment": json.dumps({"display": display, "category": category, "language": language,
                                            "scope": partition, "run": ""}),
                "commit_sha": HEAD, "ref": "refs/heads/main", "error": "", "rules_count": 58,
                "created_at": "2026-10-11T12:00:00Z"})
        for name in ("CodeQL classification", "CodeQL validation"):
            job = copy.deepcopy(self.fixture.codeql_jobs[0])
            job.update(id=999, name=name, check_run_url="https://api.github.com/repos/atrinik/example/check-runs/999")
            self.fixture.codeql_jobs.append(job)

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
        self.assertEqual(len([call for call in self.fixture.calls if "/analyses?" in call]), 1)

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

    def test_executable_wrapper_is_bash_and_delegates_python(self):
        wrapper = ROOT / "bin/security-readiness"
        self.assertEqual(wrapper.read_text().splitlines()[0], "#!/usr/bin/env bash")
        self.assertIn('exec python3 "${root}/lib/security_readiness.py" "$@"', wrapper.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
