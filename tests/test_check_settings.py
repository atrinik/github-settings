"""Offline tests for check_settings.py. Fixtures are invented; no network."""

import contextlib
import copy
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import check_settings  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures"
ORG = "example-org"


def load(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class Recorded:
    """A fake `gh api` reading recorded responses; `{"__error__": text}` fails the read."""

    def __init__(self, api):
        self.api, self.calls = api, []

    def __call__(self, path, paginate):
        self.calls.append(path)
        if path not in self.api:
            raise check_settings.Unverifiable(f"no fixture for {path} (HTTP 404)")
        value = self.api[path]
        if isinstance(value, dict) and "__error__" in value:
            raise check_settings.Unverifiable(value["__error__"])
        return copy.deepcopy(value)


class CheckTest(unittest.TestCase):
    def setUp(self):
        self.api, self.base = load("example-org-api.json"), load("example-org-baseline.json")

    def run_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "baseline.json"
            path.write_text(json.dumps(self.base), encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = check_settings.main([str(path)], github=check_settings.GitHub(Recorded(self.api)))
        return code, out.getvalue().splitlines()

    def assertLine(self, lines, *parts):
        if not any(all(part in line for part in parts) for line in lines):
            self.fail(f"no line with {parts!r} in:\n" + "\n".join(lines))

    def test_clean_organization_prints_nothing(self):
        self.assertEqual(self.run_check(), (0, []))

    def test_policy_differences_print_fix_commands(self):
        self.api[f"repos/{ORG}/engine"]["allow_merge_commit"] = True
        self.api[f"orgs/{ORG}/actions/permissions"]["sha_pinning_required"] = False
        self.api[f"orgs/{ORG}"]["members_can_create_teams"] = True
        self.api[f"orgs/{ORG}"]["default_repository_permission"] = "read"
        self.api[f"orgs/{ORG}/rulesets/103"]["rules"].pop()
        self.api[f"repos/{ORG}/docs/rulesets/103?includes_parents=true"]["rules"].pop()
        self.api[f"repos/{ORG}/docs/code-security-configuration"] = None
        self.api[f"repos/{ORG}/docs/rules/branches/main?per_page=100"].append(
            {"type": "merge_queue", "ruleset_id": 999, "ruleset_source_type": "Repository", "parameters": {}})
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine: allow_merge_commit is true, baseline false",
                        f"fix: gh api --method PATCH repos/{ORG}/engine -F allow_merge_commit=false")
        self.assertLine(lines, "sha_pinning_required is false", f"gh api --method PUT orgs/{ORG}/actions/permissions "
                        "-f enabled_repositories=all -f allowed_actions=selected -F sha_pinning_required=true")
        self.assertLine(lines, "members_can_create_teams", "settings/member_privileges")
        self.assertLine(lines, f"gh api --method PATCH orgs/{ORG} -f default_repository_permission=none")
        self.assertLine(lines, "'Release tags' differs in rules", "--ruleset 'Release tags'",
                        f"gh api --method PUT orgs/{ORG}/rulesets/103 --input -")
        self.assertLine(lines, f"{ORG}/docs tags refs/tags/v[0-9]*: no update rule", "rulesets/103")
        self.assertLine(lines, f"{ORG}/docs: security configuration is None", "configurations/501/attach",
                        "-f scope=selected -F 'selected_repository_ids[]=9002'")
        self.assertLine(lines, "unexpected merge_queue rule from ruleset 999",
                        f"gh api --method DELETE repos/{ORG}/docs/rulesets/999")
        self.assertFalse(any(line.startswith("could not verify") for line in lines))

    def test_required_checks_compare_names_and_app(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        next(r for r in rules if r["type"] == "required_status_checks")["parameters"]["required_status_checks"][0][
            "integration_id"] = 1
        self.base["repositories"]["docs"]["checks"] = ["Docs build"]
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: required checks", "(or from another app)", "rulesets/104")
        self.assertLine(lines, f"{ORG}/docs main: required checks are [], baseline [\"Docs build\"]",
                        "--ruleset 'Required CI - docs'", f"gh api --method POST orgs/{ORG}/rulesets --input -")
        self.assertLine(lines, "ruleset 'Required CI - docs' is missing")

    def test_unclassified_and_unknown_objects_fail(self):
        repos = self.api[f"orgs/{ORG}/repos?per_page=100&type=all"]
        repos.append(dict(repos[0], name="sandbox", id=9004))
        self.api[f"orgs/{ORG}/rulesets?per_page=100"].append({"id": 105, "name": "Hand-made", "target": "branch"})
        self.api[f"orgs/{ORG}/rulesets/105"] = {"id": 105, "name": "Hand-made", "target": "branch"}
        del self.base["repositories"]["legacy"]
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/sandbox: repository is not classified")
        self.assertLine(lines, f"{ORG}/legacy: repository is not classified")
        self.assertLine(lines, "ruleset 'Hand-made' is not in the baseline", f"DELETE orgs/{ORG}/rulesets/105")

    def test_recorded_names_report_changes(self):
        self.api[f"repos/{ORG}/engine/environments?per_page=100"]["environments"].append({"name": "staging"})
        self.api[f"repos/{ORG}/docs/hooks?per_page=100"].append({"id": 5, "config": {"url": "https://x.example.org/h"}})
        self.api[f"repos/{ORG}/docs/teams?per_page=100"][0]["permission"] = "admin"
        self.api[f"orgs/{ORG}/installations?per_page=100"]["installations"][0]["repository_selection"] = "all"
        self.api[f"orgs/{ORG}/teams?per_page=100"].append({"slug": "visitors"})
        self.base["recorded"]["environments"]["docs"] = ["preview"]
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, "environment 'staging' is new", "changed since last recorded",
                        f"DELETE repos/{ORG}/engine/environments/staging")
        self.assertLine(lines, "environment 'preview' is gone", f"PUT repos/{ORG}/docs/environments/preview")
        self.assertLine(lines, "webhook to 'x.example.org' is new", f"DELETE repos/{ORG}/docs/hooks/5")
        self.assertLine(lines, "team 'maintainers' has admin, recorded maintain",
                        f"PUT orgs/{ORG}/teams/maintainers/repos/{ORG}/docs -f permission=maintain")
        self.assertLine(lines, "app 'example-ci' reaches all repositories, recorded selected", "settings/installations")
        self.assertLine(lines, "team 'visitors' is new")

    def test_without_admin_org_only_unverifiable(self):
        for path in list(self.api):
            if path.startswith(f"orgs/{ORG}") and path != f"orgs/{ORG}/repos?per_page=100&type=all":
                self.api[path] = {"__error__": "Forbidden (HTTP 403)"}
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertTrue(lines and all(line.startswith("could not verify: ") for line in lines), lines)
        self.assertLine(lines, "organization rulesets", "HTTP 403")
        self.assertLine(lines, "orgs/example-org/actions/permissions")

    def test_without_admin_org_repository_checks_still_run(self):
        for path in list(self.api):
            if path.startswith(f"orgs/{ORG}") and path != f"orgs/{ORG}/repos?per_page=100&type=all":
                self.api[path] = {"__error__": "Forbidden (HTTP 403)"}
        self.api[f"repos/{ORG}/engine"]["delete_branch_on_merge"] = False
        self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"] = []
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, "delete_branch_on_merge is false")
        self.assertLine(lines, f"{ORG}/engine main: no deletion rule", f"rulesets/ID --input -")
        self.assertLine(lines, "could not verify: teams")

    def test_organization_rule_changes_never_suggest_deleting_the_ruleset(self):
        extra = {"type": "merge_queue", "ruleset_id": 102, "ruleset_source_type": "Organization", "parameters": {}}
        self.api[f"orgs/{ORG}/rulesets/102"]["rules"].append({"type": "merge_queue", "parameters": {}})
        for repo in ("docs", "engine"):
            self.api[f"repos/{ORG}/{repo}/rules/branches/main?per_page=100"].append(dict(extra))
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, "'Changes through pull requests' differs in rules")
        self.assertFalse(any("DELETE" in line or "unexpected" in line for line in lines), lines)
        for path in list(self.api):
            if path.startswith(f"orgs/{ORG}") and path != f"orgs/{ORG}/repos?per_page=100&type=all":
                self.api[path] = {"__error__": "Forbidden (HTTP 403)"}
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        # The name comes from the repository's ruleset listing, which needs no admin:org.
        self.assertLine(lines, f"{ORG}/docs main: unexpected merge_queue rule from organization ruleset 102",
                        "--ruleset 'Changes through pull requests'", f"gh api --method PUT orgs/{ORG}/rulesets/102 --input -")
        self.assertFalse(any("DELETE" in line or "NAME" in line for line in lines), lines)
        for repo in ("docs", "engine"):
            self.api[f"repos/{ORG}/{repo}/rules/branches/main?per_page=100"][-1]["ruleset_id"] = 106
            self.api[f"repos/{ORG}/{repo}/rulesets?includes_parents=true&per_page=100"].append(
                {"id": 106, "name": "Hand-made", "target": "branch", "enforcement": "active"})
        code, lines = self.run_check()
        self.assertLine(lines, f"{ORG}/docs main: unexpected merge_queue rule from organization ruleset 106",
                        "fix: record ruleset Hand-made in the baseline")
        self.assertFalse(any("PUT" in line for line in lines if "106" in line), lines)

    def test_repository_pull_request_rule_is_compared_in_full(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        other = copy.deepcopy(next(r for r in rules if r["type"] == "pull_request"))
        other.update(ruleset_id=999, ruleset_source_type="Repository")
        other["parameters"].update(require_code_owner_review=True, required_reviewers=[{"reviewer": {"id": 1}}])
        rules.append(other)
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from ruleset 999 is not")

    def test_unreadable_tag_ruleset_is_only_unverifiable(self):
        self.api[f"repos/{ORG}/docs/rulesets/103?includes_parents=true"] = {"__error__": "Forbidden (HTTP 403)"}
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(lines, [f"could not verify: {ORG}/docs tags refs/tags/v[0-9]*: Forbidden (HTTP 403)"])

    def test_one_timeout_keeps_the_other_differences(self):
        self.api[f"orgs/{ORG}"]["members_can_create_teams"] = True
        self.api[f"repos/{ORG}/engine/hooks?per_page=100"] = {"__error__": "Get ...: dial tcp: i/o timeout"}
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, "members_can_create_teams is true")
        self.assertLine(lines, f"could not verify: {ORG}/engine webhooks: Get ...: dial tcp: i/o timeout")

    def test_tag_excludes_and_other_repository_rules_are_differences(self):
        self.api[f"repos/{ORG}/docs/rulesets/103?includes_parents=true"]["conditions"]["ref_name"]["exclude"] = [
            "refs/tags/v1*"]
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        other = copy.deepcopy(next(r for r in rules if r["type"] == "pull_request"))
        other.update(ruleset_id=777, ruleset_source_type="Repository")
        other["parameters"]["allowed_merge_methods"] = ["merge", "squash"]
        rules.append(other)
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/docs tags refs/tags/v[0-9]*: no deletion rule", "ruleset 103 has ref excludes")
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from ruleset 777 is not")

    def test_nothing_verified_exits_3(self):
        def logged_out(path, paginate):
            raise check_settings.CannotRun("To get started with GitHub CLI, please run:  gh auth login")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_settings.main([str(FIXTURES / "example-org-baseline.json")], github=check_settings.GitHub(logged_out))
        self.assertEqual((code, out.getvalue()), (3, ""))
        self.assertIn("could not run: ", err.getvalue())
        self.api[f"orgs/{ORG}/repos?per_page=100&type=all"] = {"__error__": "Forbidden (HTTP 403)"}
        with contextlib.redirect_stderr(err):
            self.assertEqual(self.run_check()[0], 3)
        self.assertIn("cannot list the repositories", err.getvalue())

    def test_unexpected_response_exits_3(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        del next(r for r in rules if r["type"] == "required_status_checks")["parameters"]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(self.run_check()[0], 3)
        self.assertIn("could not run: unexpected API response (KeyError('parameters'))", err.getvalue())

    def test_hidden_organization_fields_are_unverifiable(self):
        del self.api[f"orgs/{ORG}"]["members_can_create_teams"]
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(lines, [f"could not verify: orgs/{ORG}: members_can_create_teams not visible to this login "
                                 "(needs admin:org?)"])


class BaselineTest(unittest.TestCase):
    def setUp(self):
        self.base = load("example-org-baseline.json")

    def test_real_baselines_are_valid(self):
        for path in sorted((ROOT / "baselines").glob("*.json")):
            with self.subTest(path=path.name):
                self.assertEqual(check_settings.validate(json.loads(path.read_text(encoding="utf-8"))), [])

    def test_at_most_three_profiles(self):
        for name in ("a", "b"):
            self.base["profiles"][name] = {}
        self.assertIn("1 to 3 profiles", " ".join(check_settings.validate(self.base)))

    def test_at_most_ten_exceptions(self):
        for number in range(11):
            self.base["repositories"][f"r{number}"] = {"profile": "standard", "why": "test",
                                                       "overrides": {"tag_rules": {"ref": "x", "rules": []}}}
        self.assertIn("11 per-repository exceptions", " ".join(check_settings.validate(self.base)))

    def test_rejects_unknown_profile_key_and_unexplained_override(self):
        self.base["repositories"]["docs"]["profile"] = "missing"
        self.base["repositories"]["engine"]["overrides"] = {"security_configuration": "Example baseline"}
        self.base["profiles"]["archived"]["expires"] = "2026-01-01"
        errors = " ".join(check_settings.validate(self.base))
        self.assertIn("docs: needs a known profile", errors)
        self.assertIn('engine: an override needs a "why"', errors)
        self.assertIn("unknown key 'expires'", errors)

    def test_rejects_shapes_the_check_cannot_read(self):
        for change, message in [(lambda b: b["profiles"]["standard"]["tag_rules"].pop("ref"), "standard: tag_rules must be"),
                                (lambda b: b["profiles"]["standard"].update(branch_rules=[]), "branch_rules must be"),
                                (lambda b: b["repositories"]["engine"].update(overrides={"repository": 1}, why="x"),
                                 "engine override: repository must be"),
                                (lambda b: next(iter(b["rulesets"].values()))["rules"].append({}), "rules that each have a type")]:
            base = copy.deepcopy(self.base)
            change(base)
            with self.subTest(message=message):
                self.assertIn(message, " ".join(check_settings.validate(base)))

    def test_ruleset_option_expands_the_template(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_settings.main([str(FIXTURES / "example-org-baseline.json"), "--ruleset", "Required CI - engine"])
        body = json.loads(out.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(body["conditions"]["repository_name"]["include"], ["engine"])
        self.assertEqual(body["rules"][0]["parameters"]["required_status_checks"],
                         [{"context": "Engine tests", "integration_id": 15368}, {"context": "PR title", "integration_id": 15368}])

    def test_bad_input_exits_3(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(check_settings.main([str(FIXTURES / "missing.json")]), 3)
            for argv in ([], ["x.json", "--no-such-flag"]):
                with self.assertRaises(SystemExit) as raised:
                    check_settings.main(argv)
                self.assertEqual(raised.exception.code, 3)


class ReadOnlyTest(unittest.TestCase):
    def test_gh_is_only_called_with_get(self):
        result = subprocess.CompletedProcess([], 0, stdout='[{"a": 1}]\n', stderr="")
        with mock.patch.object(check_settings.subprocess, "run", return_value=result) as run:
            self.assertEqual(check_settings.gh_fetch("orgs/x/repos?per_page=100", True), [{"a": 1}])
        self.assertEqual(run.call_args.args[0], ["gh", "api", "-X", "GET", "orgs/x/repos?per_page=100", "--paginate"])
        source = (ROOT / "check_settings.py").read_text(encoding="utf-8")
        self.assertEqual(source.count("subprocess.run("), 1)

    def test_failed_read_names_the_missing_scope(self):
        stderr = 'gh: Not Found (HTTP 404)\nThis API operation needs the "admin:org_hook" scope.\n'
        result = subprocess.CompletedProcess([], 1, stdout="", stderr=stderr)
        with mock.patch.object(check_settings.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(check_settings.Unverifiable, "lacks the admin:org_hook scope"):
                check_settings.gh_fetch("orgs/x/hooks", True)

    def test_logged_out_or_offline_cannot_run(self):
        for stderr in ("To get started with GitHub CLI, please run:  gh auth login\n", "gh: Bad credentials (HTTP 401)\n"):
            result = subprocess.CompletedProcess([], 1, stdout="", stderr=stderr)
            with self.subTest(stderr=stderr), mock.patch.object(check_settings.subprocess, "run", return_value=result):
                with self.assertRaises(check_settings.CannotRun):
                    check_settings.gh_fetch("orgs/x", False)
        result = subprocess.CompletedProcess([], 1, stdout="", stderr="Get \"https://api.github.com\": dial tcp: i/o timeout\n")
        with mock.patch.object(check_settings.subprocess, "run", return_value=result):
            with self.assertRaises(check_settings.Unverifiable):  # one slow read must not stop the run
                check_settings.gh_fetch("repos/x/y/hooks", True)

    def test_pages_are_joined(self):
        self.assertEqual(check_settings.parse_output('[1, 2]\n[3]\n'), [1, 2, 3])
        self.assertEqual(check_settings.parse_output('{"a": 1}'), {"a": 1})
        self.assertIsNone(check_settings.parse_output(""))

    def test_fix_commands_quote_values(self):
        self.assertEqual(check_settings.gh_command("PATCH", "repos/o/r", {"a": True, "b": "x y"}),
                         "gh api --method PATCH repos/o/r -F a=true -f 'b=x y'")
        self.assertEqual(check_settings.gh_command("PUT", "p", {"list": ["it's"]}),
                         "echo '{\"list\":[\"it'\"'\"'s\"]}' | gh api --method PUT p --input -")

    def test_matching_ignores_order_and_extra_fields(self):
        self.assertTrue(check_settings.matches({"a": [1, 2]}, {"a": [2, 1], "b": 3}))
        self.assertFalse(check_settings.matches({"a": [1]}, {"a": [1, 1]}))
        self.assertFalse(check_settings.matches(False, 0))

    def test_script_stays_small(self):
        lines = (ROOT / "check_settings.py").read_text(encoding="utf-8").count("\n")
        self.assertLessEqual(lines, 550, "the check is meant to stay about 500 lines; simplify before growing it")


if __name__ == "__main__":
    unittest.main()
