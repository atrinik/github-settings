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
        self.metadata = {"full_name": "atrinik/example", "default_branch": "main", "archived": False}
        self.pr = {"number": 12, "state": "open", "draft": False, "merged": False,
                   "changed_files": 1, "merge_commit_sha": MERGE,
                   "base": {"ref": "main", "sha": BASE, "repo": {"full_name": "atrinik/example"}},
                   "head": {"sha": HEAD, "repo": {"full_name": "atrinik/example"}}}
        self.run = {"id": 9, "run_attempt": 2, "event": "pull_request", "status": "completed",
                    "conclusion": "success", "head_sha": HEAD, "check_suite_id": 99,
                    "pull_requests": [{"number": 12, "head": {"sha": HEAD},
                                       "base": {"sha": BASE, "ref": "main"}}]}
        self.suite = {"id": 99, "head_sha": MERGE, "status": "completed", "conclusion": "success",
                      "app": {"id": 15368}, "pull_requests": copy.deepcopy(self.run["pull_requests"])}
        self.jobs = [{"name": "Dependency review", "status": "completed", "conclusion": "success"}]
        self.files = [{"filename": ".github/workflows/check.yml", "status": "modified"}]
        self.before = f"name: Check\nsteps:\n  - uses: rust-lang/crates-io-auth-action@{OLD} # v1\n".encode()
        self.after = f"name: Check\nsteps:\n  - uses: rust-lang/crates-io-auth-action@{NEW} # v2\n".encode()
        self.checks = {HEAD: [check("Required checks"), check("Conventional PR title", identifier=2)], MERGE: []}
        self.live = copy.deepcopy(SELECTED)
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
            return content(self.before if "ref=" + BASE in endpoint else self.after)
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
        if "/actions/workflows/dependency-review.yml/runs" in endpoint:
            return {"workflow_runs": [copy.deepcopy(self.run)]}
        if "/attempts/2/jobs" in endpoint:
            return {"total_count": len(self.jobs), "jobs": copy.deepcopy(self.jobs)}
        if "/actions/permissions/selected-actions" in endpoint:
            return copy.deepcopy(self.live)
        if "/pulls/12/files" in endpoint:
            return copy.deepcopy(self.files)
        if endpoint == "repos/atrinik/example/commits/" + MERGE:
            return {"parents": [{"sha": value} for value in self.parents]}
        if "/check-runs?" in endpoint:
            values = copy.deepcopy(self.checks[endpoint.split("/commits/")[1].split("/")[0]])
            return {"total_count": len(values), "check_runs": values}
        if "/actions/runs?check_suite_id=99" in endpoint:
            return {"workflow_runs": [copy.deepcopy(self.run)]}
        if "/actions/runs?event=pull_request&head_sha=" in endpoint:
            return {"total_count": 1, "workflow_runs": [copy.deepcopy(self.run)]}
        if "/check-suites/99" in endpoint:
            return copy.deepcopy(self.suite)
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
            "codeql_required_languages": {"example": ["rust"]}}))
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
        self.assert_deferred("dependency", "execution PR association")

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
