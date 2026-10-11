#!/usr/bin/env python3
"""Read-only preflight for security controls; 0 ready, 1 deferred, 2 unreadable."""

import argparse
import ast
import base64
import binascii
import difflib
import fnmatch
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
from urllib.parse import quote, urlencode


ROOT = Path(__file__).resolve().parent.parent
VERSION = "2026-03-10"
ACTION_APP = 15368
SHA = re.compile(r"[0-9a-fA-F]{40}\Z")
COORDINATE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SIMPLE_NAME = r"(?:[A-Za-z][A-Za-z0-9 ._/-]*|'[A-Za-z][A-Za-z0-9 ._/-]*'|\"[A-Za-z][A-Za-z0-9 ._/-]*\")"
USES = re.compile(
    r"(?P<prefix>[ \t]*(?:-[ \t]+)?uses:[ \t]+)"
    r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@"
    r"(?P<sha>[0-9a-fA-F]{40})(?P<space>[ \t]*)"
    r"(?P<comment>#[ \t]*v?[0-9]+(?:\.[0-9A-Za-z_-]+)*(?:[ \t]*)?)?"
    r"(?P<newline>\r?\n)?\Z"
)


class Deferred(Exception):
    pass


class EvidenceError(Exception):
    pass


class APIError(EvidenceError):
    def __init__(self, endpoint, status=None):
        self.status = status
        super().__init__(f"API unreadable: {endpoint.split('?')[0]}"
                         + (f" (HTTP {status})" if status else ""))


def api(endpoint):
    """Use GET explicitly: query parameters must never select gh's POST default."""
    try:
        result = subprocess.run(
            ["gh", "api", "--method", "GET", "-H", f"X-GitHub-Api-Version: {VERSION}",
             "-H", "Accept: application/vnd.github+json", endpoint],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise APIError(endpoint) from exc
    if result.returncode:
        status = re.search(r"HTTP (\d{3})", result.stderr)
        raise APIError(endpoint, int(status[1]) if status else None)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise EvidenceError("API returned invalid JSON") from exc


def config(name):
    return json.loads((ROOT / "config" / name).read_text())


def require(condition, reason):
    if not condition:
        raise Deferred(reason)


def repository(coordinate):
    metadata = api(f"repos/{coordinate}")
    if metadata["full_name"].lower() != coordinate.lower():
        raise EvidenceError("repository identity changed")
    require(metadata["archived"] is False, "repository archived")
    if not isinstance(metadata["default_branch"], str) or not metadata["default_branch"]:
        raise EvidenceError("default branch missing")
    return metadata


def contents(coordinate, path, ref):
    endpoint = f"repos/{coordinate}/contents/{path}?{urlencode({'ref': ref})}"
    try:
        value = api(endpoint)
    except APIError as exc:
        if exc.status == 404:
            raise Deferred(f"{path} missing at required revision") from exc
        raise
    if value.get("type") != "file" or value.get("encoding") != "base64":
        raise EvidenceError("workflow content is not an encoded file")
    try:
        # GitHub wraps content with newlines; reject other non-base64 bytes.
        return base64.b64decode(value["content"].replace("\n", ""), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise EvidenceError("workflow content encoding invalid") from exc


def pages(endpoint, key=None):
    """Bound enumeration; missing or oversized evidence cannot imply readiness."""
    results = []
    for page in range(1, 11):
        value = api(endpoint + ("&" if "?" in endpoint else "?")
                    + urlencode({"per_page": 100, "page": page}))
        entries = value[key] if key else value
        if not isinstance(entries, list):
            raise EvidenceError("API collection malformed")
        results.extend(entries)
        if len(entries) < 100:
            if key and "total_count" in value and len(results) != value["total_count"]:
                raise EvidenceError("API collection changed during enumeration")
            return results
    raise Deferred("evidence exceeds bounded enumeration")


def latest_dependency_run(coordinate):
    try:
        value = api(f"repos/{coordinate}/actions/workflows/dependency-review.yml/runs"
                    "?event=pull_request&per_page=1")
    except APIError as exc:
        if exc.status == 404:
            raise Deferred("dependency-review workflow not landed") from exc
        raise
    require(bool(value["workflow_runs"]), "dependency-review PR run missing")
    return value["workflow_runs"][0]


def dependency_contract(data):
    """Allow producer-owned immutable pin bumps without weakening the contract.

    Keep indentation and every policy value intact. Ignore blank lines, standalone
    comments and trailing whitespace; normalize only this official action's SHA
    and its optional same-line version annotation.
    """
    lines = []
    pins = 0
    for line in data.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = USES.fullmatch(line)
        if match and match["action"] == "actions/dependency-review-action":
            pins += 1
            line = match["prefix"] + "actions/dependency-review-action@<immutable-sha>"
        if re.fullmatch("name: " + SIMPLE_NAME, line.rstrip()):
            line = "name: Dependency review"
        lines.append(line.rstrip())
    require(pins == 1, "dependency-review workflow requires one official full-SHA action")
    normalized = []
    index = 0
    while index < len(lines):
        line = lines[index]
        step_name = re.fullmatch(r"( *)- name: " + SIMPLE_NAME, line)
        if step_name and index + 1 < len(lines):
            following = lines[index + 1]
            if following == step_name[1] + "  uses: actions/dependency-review-action@<immutable-sha>":
                line = step_name[1] + "- uses: actions/dependency-review-action@<immutable-sha>"
                index += 1
        # Producers may spell the same one-element branch filter as a block
        # list or a flow list. Preserve key indentation and reject extra items.
        flow = re.fullmatch(r"( *)branches: *\[ *(?:main|'main'|\"main\") *\]", line)
        block = re.fullmatch(r"( *)branches:", line)
        if flow:
            line = flow[1] + "branches: [main]"
        elif block and index + 1 < len(lines):
            item = re.fullmatch(r"( *)- +(?:main|'main'|\"main\")", lines[index + 1])
            if item and len(item[1]) > len(block[1]):
                line = block[1] + "branches: [main]"
                index += 1
        # Activity order and flow/block spelling do not change which PR or
        # merge-group events trigger review. Keep duplicates and unknown events visible to the
        # contract comparison rather than silently broadening the trigger.
        activity_flow = re.fullmatch(r"( *)types: *\[(.*)\]", line)
        activity_block = re.fullmatch(r"( *)types:", line)
        activities = None
        if activity_flow:
            activities = [item.strip() for item in activity_flow[2].split(",")]
            indentation = activity_flow[1]
        elif activity_block:
            activities = []
            indentation = activity_block[1]
            while index + 1 < len(lines):
                item = re.fullmatch(r"( *)- +(.+)", lines[index + 1])
                if not item or len(item[1]) <= len(indentation):
                    break
                activities.append(item[2])
                index += 1
        if activities is not None:
            values = []
            for activity in activities:
                value = re.fullmatch(r"(?:([a-z_]+)|'([a-z_]+)'|\"([a-z_]+)\")", activity)
                require(value is not None, "dependency-review activity types unsupported")
                values.append(next(part for part in value.groups() if part is not None))
            line = indentation + "types: [" + ", ".join(sorted(values)) + "]"
        normalized.append(line)
        index += 1
    # YAML mapping key order does not change the PR trigger. Reorder only the
    # two recognized, already-normalized keys; retain every value and any
    # additional or duplicated key for the exact contract comparison below.
    for index in range(len(normalized) - 2):
        if (normalized[index] == "  pull_request:"
                and normalized[index + 1].startswith("    types: [")
                and normalized[index + 2] == "    branches: [main]"):
            normalized[index + 1:index + 3] = [normalized[index + 2], normalized[index + 1]]
    return normalized


def pull_identity(pr):
    return {"number": pr["number"], "state": pr["state"], "merged": pr["merged"], "draft": pr["draft"],
            "head": (pr["head"]["sha"], pr["head"]["repo"]["full_name"]),
            "base": (pr["base"]["sha"], pr["base"]["ref"], pr["base"]["repo"]["full_name"])}


def merged_run_pull(coordinate, run, default_branch):
    """Recover only an unambiguous, fully fetched merged PR after refs disappear."""
    require(run["event"] == "pull_request"
            and re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", run["path"]) is not None,
            "merged PR association requires a PR workflow")
    require(bool(SHA.fullmatch(run["head_sha"])), "merged PR association head missing")
    associated = pages(f"repos/{coordinate}/commits/{run['head_sha']}/pulls")
    require(len(associated) == 1, "merged PR association missing or ambiguous")
    pr = api(f"repos/{coordinate}/pulls/{associated[0]['number']}")
    require(pr["number"] == associated[0]["number"] and pr["merged"] is True
            and pr["state"] == "closed" and pr["head"]["sha"] == run["head_sha"]
            and pr["head"]["repo"]["full_name"].lower() == run["head_repository"]["full_name"].lower()
            and pr["base"]["repo"]["full_name"].lower() == coordinate.lower()
            and pr["base"]["ref"] == default_branch,
            "merged PR association identity does not match run/default branch")
    return pr


def association_references(coordinate, run, suite, default_branch, recovered):
    if run["pull_requests"] and suite["pull_requests"]:
        return run["pull_requests"], suite["pull_requests"]
    pr = merged_run_pull(coordinate, run, default_branch)
    for references in (run["pull_requests"], suite["pull_requests"]):
        require(all(item["number"] == pr["number"]
                    and item["head"]["sha"] == pr["head"]["sha"]
                    and item["base"]["sha"] == pr["base"]["sha"]
                    and item["base"]["ref"] == pr["base"]["ref"] for item in references),
                "nonempty PR association conflicts with merged PR")
    recovered.append((run, default_branch, pull_identity(pr)))
    return [pr], [pr]


def verify_recovered_associations(coordinate, recovered):
    for run, default_branch, identity in recovered:
        require(pull_identity(merged_run_pull(coordinate, run, default_branch)) == identity,
                "merged PR association changed during preflight")


def dependency(coordinate):
    metadata = repository(coordinate)
    path = ".github/workflows/dependency-review.yml"
    desired = dependency_contract((ROOT / path).read_bytes())
    landed = contents(coordinate, path, metadata["default_branch"])
    require(dependency_contract(landed) == desired,
            "dependency-review workflow not landed with desired enforcement contract")
    run = latest_dependency_run(coordinate)
    require(run["event"] == "pull_request" and run["status"] == "completed"
            and run["conclusion"] == "success", "latest dependency-review PR run not successful")
    require(run["path"] == path, "dependency-review run workflow path changed")
    suite_endpoint = f"repos/{coordinate}/check-suites/{run['check_suite_id']}"
    suite = api(suite_endpoint)
    require(suite["id"] == run["check_suite_id"] and suite["app"]["id"] == ACTION_APP
            and suite["status"] == "completed" and suite["conclusion"] == "success",
            "dependency-review execution check suite not successful")
    executed = suite["head_sha"]
    require(bool(SHA.fullmatch(executed)), "dependency-review executed SHA missing")
    merge_parents = None
    if executed != run["head_sha"]:
        merge_commit = api(f"repos/{coordinate}/commits/{executed}")
        merge_parents = [parent["sha"] for parent in merge_commit["parents"]]
    recovered, pulls = [], []
    references, suite_references = association_references(
        coordinate, run, suite, metadata["default_branch"], recovered)
    for reference in references:
        pr = api(f"repos/{coordinate}/pulls/{reference['number']}")
        require(pr["base"]["repo"]["full_name"].lower() == coordinate.lower()
                and pr["base"]["ref"] == metadata["default_branch"],
                "dependency-review PR does not target default branch")
        require(pr["head"]["sha"] == run["head_sha"], "dependency-review PR head changed")
        require(reference["head"]["sha"] == pr["head"]["sha"]
                and reference["base"]["sha"] == pr["base"]["sha"]
                and reference["base"]["ref"] == pr["base"]["ref"],
                "dependency-review run PR association is stale")
        require(any(item["number"] == pr["number"]
                    and item["head"]["sha"] == pr["head"]["sha"]
                    and item["base"]["sha"] == pr["base"]["sha"]
                    and item["base"]["ref"] == pr["base"]["ref"]
                    for item in suite_references),
                "dependency-review execution PR association missing or stale")
        if merge_parents is not None:
            require(len(merge_parents) == 2 and set(merge_parents)
                    == {pr["head"]["sha"], pr["base"]["sha"]},
                    "dependency-review executed merge does not match current PR head/base")
        pulls.append(pr)
    require(contents(coordinate, path, executed) == landed,
            "dependency-review run used different workflow bytes")
    jobs = pages(f"repos/{coordinate}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
    matches = [job for job in jobs if job["name"] == "Dependency review"]
    require(len(matches) == 1 and matches[0]["status"] == "completed"
            and matches[0]["conclusion"] == "success", "Dependency review job not successful")
    fresh = latest_dependency_run(coordinate)
    run_keys = ("id", "run_attempt", "status", "conclusion", "event", "head_sha",
                "check_suite_id", "pull_requests", "path", "head_repository")
    require(all(fresh[key] == run[key] for key in run_keys),
            "dependency-review run changed during preflight")
    fresh_suite = api(suite_endpoint)
    suite_keys = ("id", "head_sha", "app", "status", "conclusion", "pull_requests")
    require(all(fresh_suite[key] == suite[key] for key in suite_keys),
            "dependency-review execution check suite changed during preflight")
    for pr in pulls:
        fresh_pr = api(f"repos/{coordinate}/pulls/{pr['number']}")
        require(fresh_pr["head"]["sha"] == pr["head"]["sha"]
                and fresh_pr["base"]["sha"] == pr["base"]["sha"]
                and fresh_pr["base"]["ref"] == pr["base"]["ref"]
                and fresh_pr["base"]["repo"]["full_name"] == pr["base"]["repo"]["full_name"]
                and all(fresh_pr[key] == pr[key] for key in ("state", "draft", "merged")),
                "dependency-review PR changed during preflight")
    verify_recovered_associations(coordinate, recovered)
    require(contents(coordinate, path, metadata["default_branch"]) == landed,
            "default-branch dependency-review workflow changed during preflight")
    require(repository(coordinate)["default_branch"] == metadata["default_branch"],
            "repository default branch changed during preflight")
    return "workflow enforcement contract landed; latest PR job successful with same workflow bytes"


def pin_changes(before, after, selected):
    """Compare complete files, so API's potentially truncated patches grant nothing."""
    old = before.decode("utf-8").splitlines(keepends=True)
    new = after.decode("utf-8").splitlines(keepends=True)
    changed = 0
    for tag, old_start, old_end, new_start, new_end in difflib.SequenceMatcher(
            None, old, new, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        require(tag == "replace" and old_end - old_start == new_end - new_start,
                "canary changes more than action pins")
        for left, right in zip(old[old_start:old_end], new[new_start:new_end]):
            left_match, right_match = USES.fullmatch(left), USES.fullmatch(right)
            require(bool(left_match and right_match), "canary changes more than action pins")
            for key in ("prefix", "action", "space", "newline"):
                require(left_match[key] == right_match[key], "canary changes action structure")
            require(left_match["sha"] != right_match["sha"], "canary contains unrelated comment changes")
            action = right_match["action"]
            # GitHub's action SHA requirement excludes reusable workflow refs.
            # The canary admits only action-pin changes, including in mixed PRs.
            require(re.fullmatch(r"[^/]+/[^/]+/\.github/workflows/[^/]+\.ya?ml", action,
                                 flags=re.IGNORECASE) is None,
                    "canary changes a reusable workflow reference, not only action pins")
            identity = f"{action}@{right_match['sha']}"
            require((selected["github_owned_allowed"] and action.split("/")[0].lower()
                     in {"actions", "github"})
                    or any(fnmatch.fnmatchcase(identity, pattern)
                           for pattern in selected["patterns_allowed"]),
                    "new action pin is outside desired selected-actions patterns")
            changed += 1
    require(changed > 0, "canary has no full-SHA action update")
    return changed


def merge_check_run(coordinate, check, pr, merges, proofs, recovered):
    """Establish PR association before selecting the latest check, even if failing."""
    if check["head_sha"] != pr["head"]["sha"] and check["head_sha"] not in merges:
        return False
    suite_id = check["check_suite"]["id"]
    if suite_id not in proofs:
        endpoint = f"repos/{coordinate}/actions/runs?check_suite_id={suite_id}&per_page=1"
        value = api(endpoint)
        runs = value["workflow_runs"]
        valid = bool(len(runs) == 1 and runs[0]["event"] == "pull_request"
                     and runs[0]["head_sha"] == pr["head"]["sha"]
                     and runs[0]["check_suite_id"] == suite_id)
        suite, bases = None, set()
        if valid:
            suite = api(f"repos/{coordinate}/check-suites/{suite_id}")
            references, suite_references = association_references(
                coordinate, runs[0], suite, pr["base"]["ref"], recovered)
            association_bases = [
                {item["base"]["sha"] for item in refs if item["number"] == pr["number"]
                 and item["head"]["sha"] == pr["head"]["sha"]
                 and item["base"]["ref"] == pr["base"]["ref"]}
                for refs in (references, suite_references)]
            bases = association_bases[0] & association_bases[1]
            # Open PRs require the current base. Merged PRs retain the common
            # recorded base from their run and suite, even after main advances.
            if not pr["merged"]:
                bases &= {pr["base"]["sha"]}
            valid = suite["id"] == suite_id and suite["app"]["id"] == ACTION_APP and bool(bases)
        proofs[suite_id] = {"endpoint": endpoint, "run": runs[0] if valid else None,
                            "suite": suite, "bases": bases, "parents": {}}
    proof = proofs[suite_id]
    if proof["run"] is None:
        return False
    if check["head_sha"] != pr["head"]["sha"]:
        if check["head_sha"] not in proof["parents"]:
            commit = api(f"repos/{coordinate}/commits/{check['head_sha']}")
            proof["parents"][check["head_sha"]] = [item["sha"] for item in commit["parents"]]
        parents = proof["parents"][check["head_sha"]]
        return len(parents) == 2 and any(set(parents) == {base, pr["head"]["sha"]}
                                         for base in proof["bases"])
    return True


def canary_actions_policy(coordinate, metadata):
    organization = coordinate.split('/')[0]
    if type(metadata["id"]) is not int or metadata["id"] < 1:
        raise EvidenceError("canary repository identity malformed")
    current = api(f"orgs/{organization}/actions/permissions")
    if (current["allowed_actions"] not in {"all", "local_only", "selected"}
            or current["enabled_repositories"] not in {"all", "none", "selected"}):
        raise EvidenceError("organization Actions permissions malformed")
    require(current["allowed_actions"] == "selected", "organization Actions selected policy is not active")
    require(current["enabled_repositories"] != "none", "organization Actions are disabled")
    membership = []
    if current["enabled_repositories"] == "selected":
        membership = pages(f"orgs/{organization}/actions/permissions/repositories", "repositories")
        require(any(item["id"] == metadata["id"] and item["full_name"].lower() == coordinate.lower()
                    for item in membership), "canary repository is not enabled for organization Actions")
    repository_policy = api(f"repos/{coordinate}/actions/permissions")
    if (not isinstance(repository_policy["enabled"], bool)
            or repository_policy["allowed_actions"] not in {"all", "local_only", "selected"}):
        raise EvidenceError("repository Actions permissions malformed")
    require(repository_policy["enabled"] and repository_policy["allowed_actions"] != "local_only",
            "canary repository does not allow external Actions")
    # Repository 'all' cannot relax the organization's selected-actions ceiling.
    selected = api(f"orgs/{organization}/actions/permissions/selected-actions")
    desired = config("actions-selected.json")
    require(desired["github_owned_allowed"] is True and desired["verified_allowed"] is False,
            "desired selected-actions policy is not conservative")
    for value in (selected, desired):
        if (not isinstance(value["github_owned_allowed"], bool)
                or not isinstance(value["verified_allowed"], bool)
                or not isinstance(value["patterns_allowed"], list)
                or not all(isinstance(item, str) for item in value["patterns_allowed"])):
            raise EvidenceError("selected-actions policy malformed")
    require(selected["github_owned_allowed"] is True and selected["verified_allowed"] is False
            and sorted(selected["patterns_allowed"]) == sorted(desired["patterns_allowed"]),
            "live selected-actions policy differs from desired policy")
    return {"mode": current["allowed_actions"], "enabled": current["enabled_repositories"],
            "membership": sorted((item["id"], item["full_name"]) for item in membership),
            "repository": repository_policy, "selected": selected}


def canary_required_checks(coordinate, branch):
    rules = pages(f"repos/{coordinate}/rules/branches/{quote(branch, safe='')}")
    entries = []
    for rule in rules:
        if rule["type"] == "required_status_checks":
            entries.extend((item["context"], item["integration_id"])
                           for item in rule["parameters"]["required_status_checks"])
    try:
        legacy = api(f"repos/{coordinate}/branches/{quote(branch, safe='')}/protection/required_status_checks")
    except APIError as exc:
        if exc.status != 404:
            raise
        legacy = None
    if legacy is not None:
        if (not isinstance(legacy["checks"], list) or not isinstance(legacy["contexts"], list)
                or not all(isinstance(value, str) and value for value in legacy["contexts"])):
            raise EvidenceError("legacy required status checks malformed")
        entries.extend((item["context"], item["app_id"]) for item in legacy["checks"])
        entries.extend((context, None) for context in legacy["contexts"])
    for context, app in entries:
        if not isinstance(context, str) or not context or (app is not None and type(app) is not int):
            raise EvidenceError("effective required status check malformed")
        require(app in (None, -1, ACTION_APP),
                f"effective required check is bound to a non-Actions app: {context}")
    repository_name = coordinate.split('/')[1]
    configured = config("repositories.json")["required_ci"].get(repository_name)
    require(bool(configured), "canary has no configured required contexts")
    if not isinstance(configured, list) or not all(isinstance(value, str) and value for value in configured):
        raise EvidenceError("configured required checks malformed")
    required = set(configured) | {context for context, _ in entries}
    if repository_name in config("security-merge-protection.json")["dependency_review"]:
        required.add("Dependency review")
    return (list(dict.fromkeys(configured)) + sorted(required - set(configured)),
            sorted(json.dumps(item) for item in entries))


def sha(coordinate, number):
    metadata = repository(coordinate)
    pr = api(f"repos/{coordinate}/pulls/{number}")
    require(pr["merged"] is True or (pr["state"] == "open" and not pr["draft"]),
            "action-update canary must be merged or open and review-ready")
    require(pr["base"]["repo"]["full_name"].lower() == coordinate.lower()
            and pr["base"]["ref"] == metadata["default_branch"],
            "canary does not target default branch")
    require(bool(SHA.fullmatch(pr["head"]["sha"])), "canary head SHA missing")
    actions_policy = canary_actions_policy(coordinate, metadata)
    selected = config("actions-selected.json")
    required, required_evidence = canary_required_checks(coordinate, metadata["default_branch"])
    files = pages(f"repos/{coordinate}/pulls/{number}/files")
    require(bool(files) and len(files) == pr["changed_files"], "canary file evidence incomplete")
    updates = 0
    for item in files:
        path = item["filename"]
        require(item["status"] == "modified" and
                re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", path) is not None,
                "canary contains changes outside existing workflows")
        updates += pin_changes(contents(coordinate, path, pr["base"]["sha"]),
                               contents(pr["head"]["repo"]["full_name"], path, pr["head"]["sha"]), selected)
    merge = pr.get("merge_commit_sha") if not pr["merged"] else None
    merges, recovered = set(), []
    if merge:
        require(bool(SHA.fullmatch(merge)), "canary merge SHA malformed")
        commit = api(f"repos/{coordinate}/commits/{merge}")
        require({parent["sha"] for parent in commit["parents"]}
                == {pr["base"]["sha"], pr["head"]["sha"]}, "canary merge SHA is stale")
        merges.add(merge)
    if pr["merged"]:
        # After squash/rebase merge, merge_commit_sha identifies publication,
        # not the temporary merge commit that PR Actions checks evaluated.
        runs = pages(f"repos/{coordinate}/actions/runs?event=pull_request&head_sha={pr['head']['sha']}",
                     "workflow_runs")
        for run in runs:
            if run["event"] != "pull_request" or run["head_sha"] != pr["head"]["sha"]:
                continue
            suite = api(f"repos/{coordinate}/check-suites/{run['check_suite_id']}")
            references, _ = association_references(
                coordinate, run, suite, metadata["default_branch"], recovered)
            references = [item for item in references if item["number"] == number]
            if not references:
                continue
            candidate = suite["head_sha"]
            if candidate == pr["head"]["sha"]:
                continue
            require(bool(SHA.fullmatch(candidate)), "historical canary merge SHA malformed")
            commit = api(f"repos/{coordinate}/commits/{candidate}")
            require(any(item["head"]["sha"] == pr["head"]["sha"]
                        and item["base"]["ref"] == metadata["default_branch"]
                        and {parent["sha"] for parent in commit["parents"]}
                        == {item["base"]["sha"], pr["head"]["sha"]} for item in references),
                    "historical canary merge does not match PR head/base")
            merges.add(candidate)
    checks = []
    for ref in [pr["head"]["sha"], *sorted(merges)]:
        checks.extend(pages(f"repos/{coordinate}/commits/{ref}/check-runs?filter=all&app_id={ACTION_APP}",
                            "check_runs"))
    proofs, selected_checks = {}, []
    for context in required:
        candidates = [check for check in checks if check["name"] == context
                      and check["app"]["id"] == ACTION_APP
                      and check["app"]["slug"] == "github-actions"
                      and merge_check_run(coordinate, check, pr, merges, proofs, recovered)]
        require(bool(candidates), f"required check missing for canary head: {context}")
        # Check IDs order creation, including queued checks with no started_at.
        # Scheduling/start time must not let an older green check hide a newer
        # PR-associated check or suite that has not completed successfully.
        latest = max(candidates, key=lambda check: check["id"])
        run = proofs[latest["check_suite"]["id"]]["run"]
        require(run["status"] == "completed" and run["conclusion"] == "success",
                f"required PR workflow run not successful for canary head: {context}")
        require(latest["status"] == "completed" and latest["conclusion"] == "success",
                f"required check not successful for canary head: {context}")
        selected_checks.append(latest)
    run_keys = ("id", "run_attempt", "event", "head_sha", "check_suite_id", "status", "conclusion",
                "pull_requests", "path", "head_repository")
    check_keys = ("id", "name", "head_sha", "status", "conclusion", "app", "check_suite", "started_at")
    fresh_checks = []
    for ref in [pr["head"]["sha"], *sorted(merges)]:
        fresh_checks.extend(pages(f"repos/{coordinate}/commits/{ref}/check-runs?filter=all&app_id={ACTION_APP}",
                                  "check_runs"))
    def check_snapshot(values):
        return sorted(json.dumps({key: check[key] for key in check_keys}, sort_keys=True)
                      for check in values if check["name"] in required)
    require(check_snapshot(fresh_checks) == check_snapshot(checks),
            "canary required check collection changed during preflight")
    for suite_id in {check["check_suite"]["id"] for check in selected_checks}:
        proof = proofs[suite_id]
        fresh_runs = api(proof["endpoint"])["workflow_runs"]
        require(len(fresh_runs) == 1 and all(fresh_runs[0][key] == proof["run"][key] for key in run_keys),
                "canary PR workflow-run evidence changed during preflight")
        fresh_suite = api(f"repos/{coordinate}/check-suites/{suite_id}")
        suite_keys = ("id", "head_sha", "app", "status", "conclusion", "pull_requests")
        require(all(fresh_suite[key] == proof["suite"][key] for key in suite_keys),
                "canary check-suite evidence changed during preflight")
    verify_recovered_associations(coordinate, recovered)
    for check in selected_checks:
        fresh_check = api(f"repos/{coordinate}/check-runs/{check['id']}")
        require(all(fresh_check[key] == check[key] for key in check_keys),
                "canary required check evidence changed during preflight")
    fresh = api(f"repos/{coordinate}/pulls/{number}")
    require(fresh["head"]["sha"] == pr["head"]["sha"]
            and fresh["base"]["sha"] == pr["base"]["sha"]
            and fresh.get("merge_commit_sha") == pr.get("merge_commit_sha")
            and fresh["state"] == pr["state"] and fresh["merged"] == pr["merged"]
            and (fresh["merged"] or not fresh["draft"]), "canary changed during preflight")
    require(canary_actions_policy(coordinate, metadata) == actions_policy,
            "live Actions permissions changed during preflight")
    require(canary_required_checks(coordinate, metadata["default_branch"])
            == (required, required_evidence), "effective required checks changed during preflight")
    fresh_metadata = repository(coordinate)
    require(fresh_metadata["default_branch"] == metadata["default_branch"]
            and fresh_metadata["id"] == metadata["id"], "repository identity/default branch changed during preflight")
    return f"ordinary action-update PR #{number}: {updates} allowed full-SHA updates; required checks passed"


def canonical_language(value):
    return {"javascript/typescript": "javascript-typescript", "javascript": "javascript-typescript",
            "typescript": "javascript-typescript"}.get(value, value)


def analysis_language(analysis):
    environment = json.loads(analysis.get("environment") or "{}")
    language = environment.get("language")
    if not language:
        match = re.search(r"(?:^|/)language:([a-z0-9+-]+)(?:/|$)", analysis["category"])
        language = match[1] if match else None
    return canonical_language(language), environment


def successful_analysis(analysis, head):
    require(analysis["commit_sha"] == head, "latest CodeQL analysis does not cover current default head")
    require(analysis["error"] in ("", None) and analysis["rules_count"] > 0,
            "latest CodeQL analysis failed or contains no executed rules")


def newest_analysis_pages(coordinate, branch):
    endpoint = f"repos/{coordinate}/code-scanning/analyses?" + urlencode(
        {"ref": f"refs/heads/{branch}", "tool_name": "CodeQL"})
    for page in range(1, 11):
        entries = api(endpoint + f"&per_page=100&page={page}")
        if not isinstance(entries, list):
            raise EvidenceError("CodeQL analysis collection malformed")
        yield entries
        if len(entries) < 100:
            return


def configured_codeql_languages(setup):
    values = setup["languages"]
    if not isinstance(values, list) or not all(isinstance(item, str) and item for item in values):
        raise EvidenceError("CodeQL default-setup languages malformed")
    return {canonical_language(value) for value in values}


def default_codeql_coverage(coordinate, branch, head, languages):
    """Select only the newest canonical analyses within the bounded history."""
    found = {}
    for entries in newest_analysis_pages(coordinate, branch):
        for analysis in entries:
            if analysis["tool"]["name"] != "CodeQL" or analysis["ref"] != f"refs/heads/{branch}":
                continue
            language, _ = analysis_language(analysis)
            # Default setup owns one canonical category per configured language.
            # Retired advanced partitions, even in that language, are historical.
            category_language = canonical_language(analysis["category"].removeprefix("/language:"))
            if (not analysis["category"].startswith("/language:")
                    or category_language not in languages or category_language in found):
                continue
            successful_analysis(analysis, head)
            require(language == category_language, "default CodeQL analysis language does not match its category")
            found[language] = analysis
        if set(found) == languages:
            return found
    raise Deferred("required configured CodeQL language analysis missing within bounded evidence")


def default_codeql(coordinate, branch, head, minima):
    endpoint = f"repos/{coordinate}/code-scanning/default-setup"
    setup = api(endpoint)
    require(setup["state"] == "configured", "CodeQL default setup not configured")
    languages = configured_codeql_languages(setup)
    require(bool(languages), "CodeQL default setup has no configured languages")
    require(set(minima) <= languages, "required CodeQL languages not configured")
    coverage = default_codeql_coverage(coordinate, branch, head, languages)
    fresh = api(endpoint)
    require(fresh["state"] == setup["state"]
            and configured_codeql_languages(fresh) == languages,
            "CodeQL default setup changed during preflight")
    require(default_codeql_coverage(coordinate, branch, head, languages) == coverage,
            "CodeQL default-setup analysis coverage changed during preflight")
    return "latest canonical default-setup analyses cover every configured language on current head"


def classifier_full_events(source):
    """Read the owner's full-event contract without executing fetched Python."""
    tree = ast.parse(source)
    assignments = [node for node in tree.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "FULL_EVENTS" for target in node.targets)]
    require(len(assignments) == 1, "advanced CodeQL classifier full-event contract missing")
    events = ast.literal_eval(assignments[0].value)
    mains = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main"]
    require(len(mains) == 1, "advanced CodeQL classifier main contract missing")
    full = False
    for node in ast.walk(mains[0]):
        if (isinstance(node, ast.If) and isinstance(node.test, ast.Compare)
                and ast.unparse(node.test) == "arguments.event in FULL_EVENTS"):
            full = any(isinstance(item, ast.Assign) and isinstance(item.value, ast.Constant)
                       and item.value.value is True and any(isinstance(target, ast.Name)
                           and target.id == "full" for target in item.targets) for item in node.body)
    require(full and {"push", "schedule", "workflow_dispatch"} <= set(events),
            "advanced CodeQL classifier does not select full analysis for full events")
    return set(events) & {"push", "schedule", "workflow_dispatch"}


def advanced_partition_minima(policy, repository_name):
    """Validate source-owned coverage even when preflight is called directly."""
    inventories = policy.get("required_partitions")
    if (not isinstance(inventories, dict) or set(inventories) != set(policy["repositories"])
            or not isinstance(inventories.get(repository_name), list)
            or not inventories[repository_name]):
        raise EvidenceError("advanced CodeQL required partition inventory malformed/missing")
    minima = set()
    for item in inventories[repository_name]:
        if (not isinstance(item, dict) or set(item) != {"scope", "language"}
                or any(not isinstance(item[key], str)
                       or not re.fullmatch(r"[a-z][a-z0-9+-]*", item[key]) for key in item)):
            raise EvidenceError("advanced CodeQL required partition identity malformed")
        identity = (item["scope"], canonical_language(item["language"]))
        if identity in minima:
            raise EvidenceError("advanced CodeQL required partition identity duplicated")
        minima.add(identity)
    return minima


def classifier_partitions(source, minima):
    """Inspect literal matrix declarations; never execute repository Python."""
    tree = ast.parse(source)
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                 and node.name == "write_outputs"]
    require(len(functions) == 1, "advanced CodeQL partition declarations missing")
    function = functions[0]
    assignments = [node for node in ast.walk(function) if isinstance(node, ast.Name)
                   and node.id == "entries" and isinstance(node.ctx, ast.Store)]
    initializers = [node for node in function.body if isinstance(node, ast.Assign)
                    and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                    and node.targets[0].id == "entries" and isinstance(node.value, ast.List)
                    and not node.value.elts]
    require(len(assignments) == len(initializers) == 1,
            "advanced CodeQL partition declaration shape unsupported")
    declarations, identities, categories = {}, set(), set()
    for node in ast.walk(function):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "entries"):
            continue
        require(node.func.attr == "append" and len(node.args) == 1 and not node.keywords,
                "advanced CodeQL partition declaration shape unsupported")
        try:
            item = ast.literal_eval(node.args[0])
        except (ValueError, TypeError):
            raise Deferred("advanced CodeQL partition declaration is not literal") from None
        require(isinstance(item, dict) and set(item) == {"display", "category", "scope", "language", "run"}
                and item["run"] is True and all(isinstance(item[key], str) and item[key]
                    for key in ("display", "category", "scope", "language")),
                "advanced CodeQL partition declaration malformed")
        identity = (item["scope"], canonical_language(item["language"]))
        require(item["display"] not in declarations and item["category"] not in categories
                and identity not in identities, "advanced CodeQL partition declarations duplicated")
        declarations[item["display"]] = item
        categories.add(item["category"])
        identities.add(identity)
    require(bool(declarations) and minima <= identities,
            "advanced CodeQL producer omits required partition coverage")
    return declarations


def latest_full_codeql_run(coordinate, branch, head, events):
    value = api(f"repos/{coordinate}/actions/workflows/codeql.yml/runs?head_sha={head}&per_page=100")
    candidates = [run for run in value["workflow_runs"] if run["event"] in events
                  and run["head_sha"] == head and run["head_branch"] == branch]
    require(bool(candidates), "current-head full-event CodeQL workflow run missing")
    run = candidates[0]
    require(run["path"] == ".github/workflows/codeql.yml" and run["status"] == "completed"
            and run["conclusion"] == "success", "latest full-event CodeQL workflow run not successful")
    return run


def advanced_codeql_coverage(coordinate, branch, head, minima, selected, declarations):
    """Select current producer uploads, ignoring retired categories and history."""
    found, categories, languages = {}, set(), set()
    for entries in newest_analysis_pages(coordinate, branch):
        for analysis in entries:
            if (analysis["tool"]["name"] != "CodeQL" or analysis["ref"] != f"refs/heads/{branch}"
                    or analysis.get("analysis_key") != ".github/workflows/codeql.yml:analyze"):
                continue
            category = analysis["category"]
            if category in categories:
                continue
            categories.add(category)
            language, environment = analysis_language(analysis)
            display = environment.get("display")
            if display not in selected:
                continue
            job = selected[display]
            declaration = declarations[display]
            if analysis["created_at"] < job["started_at"]:
                continue
            require(display not in found, "advanced CodeQL selected display has ambiguous upload categories")
            successful_analysis(analysis, head)
            category_language = re.search(r"(?:^|/)language:([a-z0-9+-]+)$", category)
            require(environment.get("category") == category == declaration["category"]
                    and environment.get("scope") == declaration["scope"]
                    and language == canonical_language(declaration["language"])
                    and category_language is not None
                    and canonical_language(category_language[1]) == language
                    and job["started_at"] <= analysis["created_at"] <= job["completed_at"],
                    "advanced CodeQL analysis upload does not belong to selected full-run job")
            found[display] = analysis
            languages.add(language)
            if set(found) == set(selected):
                break
        if set(found) == set(selected):
            require({canonical_language(value) for value in minima} <= languages,
                    "required CodeQL language analysis missing")
            return found
    raise Deferred("required advanced CodeQL partition upload missing within bounded evidence")


def advanced_workflow_wiring(source):
    """Check executable dataflow, not the honesty of repository-owned Python.

    The supported ordinary-job shape is deliberately bounded. Producer-owned
    action SHAs and classifier path/category declarations are not central pins.
    """
    try:
        import yaml
    except ImportError as exc:
        raise EvidenceError("install requirements-validation.txt for CodeQL workflow verification") from exc

    class UniqueLoader(yaml.SafeLoader):
        # Actions uses `on` as a mapping key. Preserve scalar booleans as text,
        # as in the existing publication verifier, and validate them explicitly.
        yaml_implicit_resolvers = {
            key: [(tag, regex) for tag, regex in values if tag != "tag:yaml.org,2002:bool"]
            for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
        }

    def unique_mapping(loader, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in result:
                raise ValueError(f"duplicate YAML key: {key}")
            result[key] = loader.construct_object(value_node, deep=deep)
        return result

    UniqueLoader.add_constructor("tag:yaml.org,2002:map", unique_mapping)
    try:
        workflow = yaml.load(source, Loader=UniqueLoader)
    except (yaml.YAMLError, ValueError, TypeError) as exc:
        raise EvidenceError("advanced CodeQL workflow YAML malformed or ambiguous") from exc

    def check(condition, detail):
        require(condition, "advanced CodeQL executable workflow contract: " + detail)

    def expression(value, expected, wrapped=True):
        if not isinstance(value, str):
            return False
        value = value.strip()
        if value.startswith("${{") and value.endswith("}}"):
            value = value[3:-2].strip()
        elif wrapped:
            return False
        # Ignore token spacing, preserving string contents (including spaces).
        def tokens(text):
            return re.findall(r"'(?:[^']|'')*'|[A-Za-z_][A-Za-z_0-9]*|==|\S", text)
        return tokens(value) == tokens(expected)

    def execution_settings(value, context):
        check(isinstance(value, dict), context + " must be a mapping")
        check(not value.get("env") and not value.get("defaults"), context + " execution overrides")
        check(value.get("continue-on-error", "false") == "false", context + " suppresses failure")
        check(not any(key in value for key in ("shell", "working-directory", "container", "services")),
              context + " changes execution context")

    def step(value, context, condition=None):
        execution_settings(value, context)
        check(set(value) <= {"name", "id", "uses", "with", "run", "env", "if", "continue-on-error"},
              context + " unsupported step execution")
        check(("if" not in value) if condition is None else expression(value.get("if"), condition, False),
              context + " condition disconnected")

    def action(value, name):
        check(isinstance(value.get("uses"), str)
              and re.fullmatch(re.escape(name) + r"@[0-9a-fA-F]{40}", value["uses"]) is not None
              and "run" not in value, "expected official full-SHA " + name)

    def checkout(value):
        step(value, "checkout")
        action(value, "actions/checkout")
        inputs = value.get("with", {})
        check(isinstance(inputs, dict)
              and set(inputs) <= {"fetch-depth", "ref", "repository", "persist-credentials"},
              "checkout must use the current complete workspace")
        check("ref" not in inputs or expression(inputs["ref"], "github.sha"),
              "checkout revision differs from run")
        check("repository" not in inputs or expression(inputs["repository"], "github.repository"),
              "checkout repository differs from run")

    def command(value, prefix):
        check(isinstance(value.get("run"), str) and "uses" not in value and "with" not in value,
              "helper must execute a run step")
        try:
            # Retain shell quoting as well as argument values: single-quoted or
            # escaped $EVENT_NAME is a literal, not the bound event environment.
            source = value["run"].replace("\\\r\n", "").replace("\\\n", "")
            raw = shlex.split(source, comments=True, posix=False)
            decoded = [shlex.split(token) for token in raw]
            check(all(len(item) == 1 for item in decoded), "helper shell arguments unsupported")
            tokens = [item[0] for item in decoded]
        except ValueError:
            raw, tokens = [], []
        check(tokens[:len(prefix)] == prefix, "helper invocation disconnected")
        arguments, raw_arguments = tokens[len(prefix):], raw[len(prefix):]
        check(len(arguments) % 2 == 0, "helper arguments malformed")
        options, quoted_options = {}, {}
        for index in range(0, len(arguments), 2):
            key, argument = arguments[index:index + 2]
            check(key.startswith("--") and key not in options, "helper arguments ambiguous")
            options[key] = argument
            quoted_options[key] = raw_arguments[index + 1]
        return options, quoted_options

    def classifier(value, scoped=False):
        expected_env = {"BASE_SHA": "github.event.pull_request.base.sha",
                        "EVENT_NAME": "github.event_name", "HEAD_SHA": "github.event.pull_request.head.sha"}
        environment = value.get("env")
        check(isinstance(environment, dict) and set(environment) == set(expected_env)
              and all(expression(environment[key], expected) for key, expected in expected_env.items()),
              "classifier event/revision environment disconnected")
        # Environment is validated above; every other execution override is rejected.
        step({key: item for key, item in value.items() if key != "env"}, "classifier")
        check(value.get("id") == "classify", "classifier step identity disconnected")
        options, quoted = command(value, ["python3", "tools/ci/classify_changes.py"])
        expected = {"--event": "EVENT_NAME", "--base": "BASE_SHA", "--head": "HEAD_SHA",
                    "--github-output": "GITHUB_OUTPUT"}
        check(set(options) == set(expected) | {"--codeql-config"} | ({"--codeql-scope"} if scoped else set()),
              "classifier arguments disconnected")
        check(all(quoted[key] in ("$" + variable, "${" + variable + "}",
                                  '"$' + variable + '"', '"${' + variable + '}"')
                  for key, variable in expected.items()), "classifier event/output arguments disconnected")
        path = options["--codeql-config"]
        check(re.fullmatch(r"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.ya?ml", path) is not None
              and ".." not in path.split("/"), "classifier config destination unsupported")
        if scoped:
            check(expression(options["--codeql-scope"], "matrix.scope"), "classifier scope disconnected")
        return path

    execution_settings(workflow, "workflow")
    jobs = workflow.get("jobs")
    check(isinstance(jobs, dict) and set(jobs) == {"classify", "analyze", "codeql-validation"},
          "requires ordinary classification, analysis and validation jobs")
    for name, job in jobs.items():
        execution_settings(job, name)
        check(set(job) <= {"name", "runs-on", "timeout-minutes", "outputs", "steps", "if", "needs",
                          "strategy", "continue-on-error"}, name + " unsupported job execution")
        runner = job.get("runs-on")
        check((isinstance(runner, str) and bool(runner)) or
              (isinstance(runner, list) and bool(runner) and
               all(isinstance(item, str) and item for item in runner)), name + " runner missing")
        steps = job.get("steps")
        check(isinstance(steps, list) and all(isinstance(item, dict) for item in steps),
              name + " executable steps missing")
        identifiers = [item["id"] for item in steps if "id" in item]
        check(all(isinstance(item, str) for item in identifiers)
              and len(identifiers) == len(set(identifiers)), name + " duplicate step identities")
    classify, analyze, validation = (jobs[name] for name in ("classify", "analyze", "codeql-validation"))
    check(classify.get("name") == "CodeQL classification"
          and not any(key in classify for key in ("if", "needs", "strategy"))
          and len(classify["steps"]) == 2, "classification job execution disconnected")
    outputs = classify.get("outputs", {})
    check(isinstance(outputs, dict) and set(outputs) == {"matrix", "run"}
          and expression(outputs["matrix"], "steps.classify.outputs.codeql_matrix")
          and expression(outputs["run"], "steps.classify.outputs.codeql_run"), "classifier outputs disconnected")
    checkout(classify["steps"][0])
    config_path = classifier(classify["steps"][1])

    check(analyze.get("needs") in ("classify", ["classify"])
          and expression(analyze.get("if"), "needs.classify.outputs.run == 'true'", False),
          "analysis dependency/condition disconnected")
    name = analyze.get("name", "")
    match = re.fullmatch(r"CodeQL analysis \((\$\{\{.*\}\})\)", name) if isinstance(name, str) else None
    check(match is not None and expression(match[1], "matrix.display"), "analysis display disconnected")
    strategy = analyze.get("strategy", {})
    check(isinstance(strategy, dict) and set(strategy) == {"fail-fast", "matrix"}
          and strategy["fail-fast"] == "false"
          and expression(strategy["matrix"], "fromJSON(needs.classify.outputs.matrix)"),
          "analysis matrix disconnected")
    check("outputs" not in analyze and len(analyze["steps"]) == 4, "analysis step order unsupported")
    checkout(analyze["steps"][0])
    check(classifier(analyze["steps"][1], scoped=True) == config_path, "analysis config destination disconnected")
    initialize, analyze_step = analyze["steps"][2:]
    step(initialize, "CodeQL init", "matrix.run == true")
    action(initialize, "github/codeql-action/init")
    inputs = initialize.get("with", {})
    check(isinstance(inputs, dict) and set(inputs) == {"build-mode", "config-file", "languages"}
          and inputs["build-mode"] == "none"
          and expression(inputs["config-file"], "steps.classify.outputs.codeql_config")
          and expression(inputs["languages"], "matrix.language"), "CodeQL init/config/language disconnected")
    step(analyze_step, "CodeQL analysis", "matrix.run == true")
    action(analyze_step, "github/codeql-action/analyze")
    inputs = analyze_step.get("with", {})
    check(isinstance(inputs, dict) and set(inputs) == {"category"}
          and expression(inputs["category"], "matrix.category"), "CodeQL analysis category disconnected")

    check(validation.get("name") == "CodeQL validation"
          and expression(validation.get("if"), "always()", False)
          and isinstance(validation.get("needs"), list) and sorted(validation["needs"]) == ["analyze", "classify"]
          and not any(key in validation for key in ("strategy", "outputs"))
          and len(validation["steps"]) == 2, "validation dependency/condition disconnected")
    checkout(validation["steps"][0])
    aggregate = validation["steps"][1]
    step(aggregate, "validation aggregate")
    options, _ = command(aggregate, ["python3", "tools/ci/require_checks.py", "optional"])
    check(set(options) == {"--label", "--classifier-result", "--required", "--result"}
          and options["--label"] == "CodeQL"
          and expression(options["--classifier-result"], "needs.classify.result")
          and expression(options["--required"], "needs.classify.outputs.run")
          and expression(options["--result"], "needs.analyze.result"), "validation result arguments disconnected")


def advanced_codeql(coordinate, branch, head, minima, partition_minima):
    sources = {}
    for path in (".github/workflows/codeql.yml", "tools/ci/classify_changes.py", "tools/ci/require_checks.py"):
        sources[path] = contents(coordinate, path, branch)
        require(contents(coordinate, path, head) == sources[path], "advanced CodeQL producer source is stale")
    advanced_workflow_wiring(sources[".github/workflows/codeql.yml"])
    declarations = classifier_partitions(sources["tools/ci/classify_changes.py"], partition_minima)
    events = classifier_full_events(sources["tools/ci/classify_changes.py"])
    run = latest_full_codeql_run(coordinate, branch, head, events)
    jobs_endpoint = f"repos/{coordinate}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"
    jobs = pages(jobs_endpoint, "jobs")
    require(bool(jobs) and all(job["head_sha"] == head and job["status"] == "completed"
                             and job["conclusion"] == "success" for job in jobs),
            "advanced CodeQL full-run jobs not all successful on current head")
    require(len([job for job in jobs if job["name"] == "CodeQL classification"]) == 1,
            "advanced CodeQL classification job missing")
    validation = [job for job in jobs if job["name"] == "CodeQL validation"]
    require(len(validation) == 1, "advanced CodeQL validation job missing")
    expected_url = f"https://api.github.com/repos/{coordinate}/check-runs/"
    check_url = validation[0]["check_run_url"]
    require(check_url.startswith(expected_url) and check_url[len(expected_url):].isdigit(),
            "advanced CodeQL validation check identity missing")
    check_endpoint = f"repos/{coordinate}/check-runs/{check_url[len(expected_url):]}"
    check = api(check_endpoint)
    require(check["name"] == "CodeQL validation" and check["head_sha"] == head
            and check["app"]["id"] == ACTION_APP and check["app"]["slug"] == "github-actions"
            and check["check_suite"]["id"] == run["check_suite_id"]
            and check["status"] == "completed" and check["conclusion"] == "success",
            "advanced CodeQL validation check is not the trusted current-head producer")
    selected = {}
    for job in jobs:
        match = re.fullmatch(r"CodeQL analysis \((.+)\)", job["name"])
        if match:
            require(match[1] not in selected, "advanced CodeQL analysis jobs duplicated")
            selected[match[1]] = job
    require(set(selected) == set(declarations),
            "advanced CodeQL full run does not cover every declared partition")
    coverage = advanced_codeql_coverage(coordinate, branch, head, minima, selected, declarations)
    fresh = latest_full_codeql_run(coordinate, branch, head, events)
    require(all(fresh[key] == run[key] for key in
                ("id", "run_attempt", "head_sha", "head_branch", "event", "path", "check_suite_id")),
            "advanced CodeQL full run changed during preflight")
    require(api(check_endpoint) == check, "advanced CodeQL validation check changed during preflight")
    require(pages(jobs_endpoint, "jobs") == jobs, "advanced CodeQL full-run jobs changed during preflight")
    for path, source in sources.items():
        require(contents(coordinate, path, branch) == source,
                "advanced CodeQL producer source changed during preflight")
    require(advanced_codeql_coverage(coordinate, branch, head, minima, selected, declarations) == coverage,
            "advanced CodeQL analysis coverage changed during preflight")
    return "current full-event CodeQL producer covers policy minima and every declared partition upload"


def codeql(coordinate):
    metadata = repository(coordinate)
    branch = metadata["default_branch"]
    branch_endpoint = f"repos/{coordinate}/branches/{quote(branch, safe='')}"
    head = api(branch_endpoint)["commit"]["sha"]
    require(bool(SHA.fullmatch(head)), "default-branch head missing")
    required = config("security-merge-protection.json")["codeql_required_languages"].get(
        coordinate.split('/')[1], [])
    advanced = config("codeql-advanced-setup.json")
    if coordinate.split('/')[1] in advanced["repositories"]:
        partition_minima = advanced_partition_minima(advanced, coordinate.split('/')[1])
        reason = advanced_codeql(coordinate, branch, head, required, partition_minima)
    else:
        reason = default_codeql(coordinate, branch, head, [canonical_language(value) for value in required])
    require(api(branch_endpoint)["commit"]["sha"] == head, "default branch changed during CodeQL preflight")
    require(repository(coordinate)["default_branch"] == branch,
            "repository default branch changed during preflight")
    return reason


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("dependency", "sha", "codeql"))
    parser.add_argument("target", help="OWNER/REPO, or OWNER/REPO/PR for sha")
    args = parser.parse_args(argv)
    try:
        parts = args.target.split("/")
        coordinate = "/".join(parts[:2])
        if not COORDINATE.fullmatch(coordinate) or len(parts) != (3 if args.mode == "sha" else 2):
            raise EvidenceError("invalid repository or PR coordinate")
        if args.mode == "sha":
            if not parts[2].isdigit() or int(parts[2]) < 1:
                raise EvidenceError("invalid PR number")
            reason = sha(coordinate, int(parts[2]))
        else:
            reason = {"dependency": dependency, "codeql": codeql}[args.mode](coordinate)
        print(f"ready: {reason}")
        return 0
    except Deferred as exc:
        print(f"deferred: {exc}")
        return 1
    except (EvidenceError, OSError, ValueError, KeyError, TypeError, AttributeError, SyntaxError) as exc:
        reason = str(exc) if isinstance(exc, EvidenceError) else "local or API evidence malformed/unreadable"
        print(f"error: {reason}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
