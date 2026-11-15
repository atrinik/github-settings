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
POINTER = check_settings.SEE_RULESETS


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
        self.assertLine(lines, f"{ORG}/docs tags refs/tags/v[0-9]*: no update rule", POINTER)
        self.assertLine(lines, f"{ORG}/docs: security configuration is None", "configurations/501/attach",
                        "-f scope=selected -F 'selected_repository_ids[]=9002'")
        self.assertLine(lines, "unexpected merge_queue rule from repository ruleset 999",
                        f"gh api --method DELETE repos/{ORG}/docs/rulesets/999")
        self.assertFalse(any(line.startswith("could not verify") for line in lines))

    def test_required_checks_compare_names_and_app(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        next(r for r in rules if r["type"] == "required_status_checks")["parameters"]["required_status_checks"][0][
            "integration_id"] = 1
        self.base["repositories"]["docs"]["checks"] = ["Docs build"]
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: required checks", "(or from another app) from organization "
                        "ruleset 104", POINTER)
        self.assertLine(lines, f"{ORG}/docs main: required checks are [] from no ruleset, baseline [\"Docs build\"]",
                        POINTER)
        self.assertLine(lines, "ruleset 'Required CI - docs' is missing", "--ruleset 'Required CI - docs'",
                        f"gh api --method POST orgs/{ORG}/rulesets --input -")

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
        self.assertLine(lines, f"{ORG}/engine main: no deletion rule", POINTER)
        self.assertLine(lines, "could not verify: teams")

    def test_rules_from_an_organization_ruleset_are_always_reported_and_carry_no_command(self):
        """Its own line has the command when it differs; the per-repository lines never guess one."""
        extra = {"type": "merge_queue", "ruleset_id": 102, "ruleset_source_type": "Organization", "parameters": {}}
        self.api[f"orgs/{ORG}/rulesets/102"]["rules"].append({"type": "merge_queue", "parameters": {}})
        for repo in ("docs", "engine"):
            self.api[f"repos/{ORG}/{repo}/rules/branches/main?per_page=100"].append(dict(extra))
        states = {"read": None, "unreadable": {f"orgs/{ORG}/rulesets/102"}, "no admin:org": {
            path for path in self.api if path.startswith(f"orgs/{ORG}") and "/repos?" not in path}}
        for state, failing in states.items():
            for path in failing or ():
                self.api[path] = {"__error__": "Forbidden (HTTP 403)"}
            with self.subTest(state=state):
                code, lines = self.run_check()
                self.assertEqual(code, 1)
                for repo in ("docs", "engine"):
                    self.assertLine(lines, f"{ORG}/{repo} main: unexpected merge_queue rule from organization "
                                    "ruleset 102", f"fix: {POINTER}")
                own = [line for line in lines if line.startswith(f"orgs/{ORG}/rulesets/102: ")]
                self.assertEqual(len(own), 1 if state == "read" else 0, lines)
                if own:
                    self.assertIn(f"gh api --method PUT orgs/{ORG}/rulesets/102 --input -", own[0])
                else:
                    self.assertLine(lines, "could not verify: ", "HTTP 403")
                self.assertFalse(any("DELETE" in line for line in lines), lines)

    def test_repository_pull_request_rule_is_compared_in_full(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        other = copy.deepcopy(next(r for r in rules if r["type"] == "pull_request"))
        other.update(ruleset_id=999, ruleset_source_type="Repository")
        other["parameters"].update(require_code_owner_review=True, required_reviewers=[{"reviewer": {"id": 1}}])
        rules.append(other)
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from repository ruleset 999 is not",
                        f"repos/{ORG}/engine/rulesets/999", f"gh api --method DELETE repos/{ORG}/engine/rulesets/999")
        # The organization ruleset already matches, so its PUT would not fix this.
        self.assertFalse(any("orgs/example-org/rulesets" in line for line in lines), lines)

    def test_required_status_checks_parameters_a_profile_names_are_compared(self):
        self.base["profiles"]["standard"]["branch_rules"]["required_status_checks"] = {
            "strict_required_status_checks_policy": True}
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        rules.append({"type": "required_status_checks", "ruleset_id": 999, "ruleset_source_type": "Repository",
                      "parameters": {"strict_required_status_checks_policy": False, "required_status_checks": [
                          {"context": "Engine tests", "integration_id": 15368}]}})
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: required_status_checks rule from repository ruleset 999 is not",
                        f"repos/{ORG}/engine/rulesets/999")

    def test_a_rule_of_unknown_origin_gets_no_command(self):
        self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"].append({"type": "merge_queue"})
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: unexpected merge_queue rule from unknown ruleset None", POINTER)
        self.assertFalse(any("gh api" in line for line in lines), lines)

    def test_differing_rule_from_an_unrecorded_organization_ruleset(self):
        rules = self.api[f"repos/{ORG}/engine/rules/branches/main?per_page=100"]
        other = copy.deepcopy(next(r for r in rules if r["type"] == "pull_request"))
        other.update(ruleset_id=555, ruleset_source_type="Organization")
        other["parameters"]["require_code_owner_review"] = True
        rules.append(other)
        self.api[f"orgs/{ORG}/rulesets?per_page=100"].append({"id": 555, "name": "Extra review", "target": "branch"})
        self.api[f"orgs/{ORG}/rulesets/555"] = {"id": 555, "name": "Extra review", "target": "branch"}
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from organization ruleset 555 is not",
                        f"fix: {POINTER}")
        self.assertLine(lines, "ruleset 'Extra review' is not in the baseline", f"DELETE orgs/{ORG}/rulesets/555")
        # The matching baseline ruleset 102 would be a no-op PUT, so it is never the fix.
        self.assertFalse(any("rulesets/102" in line for line in lines), lines)

    def test_recorded_organization_ruleset_that_disagrees_with_the_profile(self):
        recorded = self.base["rulesets"]["Changes through pull requests"]["rules"]
        recorded[0]["parameters"]["require_code_owner_review"] = True
        recorded.append({"type": "merge_queue", "parameters": {}})
        self.api[f"orgs/{ORG}/rulesets/102"]["rules"] = copy.deepcopy(recorded)  # live matches its baseline body
        for repo in ("docs", "engine"):
            rules = self.api[f"repos/{ORG}/{repo}/rules/branches/main?per_page=100"]
            next(r for r in rules if r["type"] == "pull_request")["parameters"]["require_code_owner_review"] = True
            rules.append({"type": "merge_queue", "ruleset_id": 102, "ruleset_source_type": "Organization"})
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from organization ruleset 102 is not", POINTER)
        self.assertLine(lines, f"{ORG}/engine main: unexpected merge_queue rule from organization ruleset 102", POINTER)
        # No ruleset line and no command: a PUT would send the body that is already live.
        self.assertFalse(any("gh api" in line for line in lines), lines)

    def test_unreadable_tag_ruleset_is_only_unverifiable(self):
        self.api[f"repos/{ORG}/docs/rulesets/103?includes_parents=true"] = {"__error__": "Forbidden (HTTP 403)"}
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(lines, [f"could not verify: {ORG}/docs tags refs/tags/v[0-9]*: Forbidden (HTTP 403)"])

    def test_repository_ruleset_bypass_is_compared_with_the_profile(self):
        owner = {"actor_id": None, "actor_type": "OrganizationAdmin"}
        self.base["profiles"]["standard"]["ruleset_bypass"] = [{"actor_type": "OrganizationAdmin",
                                                               "bypass_mode": "pull_request"}]
        listing = f"repos/{ORG}/engine/rulesets?includes_parents=true&per_page=100"
        self.api[listing].append({"id": 900, "name": "Required CI checks", "target": "branch",
                                  "enforcement": "active", "source_type": "Repository"})
        where = f"{ORG}/engine ruleset 900"
        cases = [([dict(owner, bypass_mode="pull_request")], 0, None), ([], 0, None),
                 ([dict(owner, bypass_mode="always")], 1, f'{where}: [{{"actor_id": null, "actor_type": '
                  '"OrganizationAdmin", "bypass_mode": "always"}] may bypass it'),
                 ([dict(owner, bypass_mode="pull_request"), {"actor_id": 5, "actor_type": "Team",
                                                             "bypass_mode": "always"}], 1, '"actor_type": "Team"'),
                 (None, 2, f"could not verify: {where}: its bypass list is not visible"),
                 ("error", 2, f"could not verify: {where}: Forbidden (HTTP 403)")]
        for actors, expected, text in cases:
            body = {"id": 900, "name": "Required CI checks", "source_type": "Repository"}
            if actors == "error":
                body = {"__error__": "Forbidden (HTTP 403)"}
            elif actors is not None:
                body["bypass_actors"] = actors
            self.api[f"repos/{ORG}/engine/rulesets/900"] = body
            with self.subTest(actors=actors):
                code, lines = self.run_check()
                self.assertEqual((code, len(lines)), (expected, 1 if text else 0), lines)
                if text:
                    self.assertLine(lines, text)
                if expected == 1:
                    self.assertLine(lines, f"change bypass_actors in repos/{ORG}/engine/rulesets/900")

    def test_an_unreadable_repository_is_only_unverifiable(self):
        """Its team grants were not read either, so they are not reported as gone."""
        self.api[f"repos/{ORG}/docs"] = {"__error__": "net/http: TLS handshake timeout"}
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(lines, [f"could not verify: {ORG}/docs: net/http: TLS handshake timeout"])

    def test_an_object_override_changes_only_the_fields_it_names(self):
        self.base["repositories"]["engine"].update(overrides={"repository": {"delete_branch_on_merge": False}},
                                                   why="test")
        self.api[f"repos/{ORG}/engine"].update(delete_branch_on_merge=False, allow_merge_commit=True)
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertEqual(len(lines), 1, lines)
        self.assertLine(lines, f"{ORG}/engine: allow_merge_commit is true, baseline false")

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
        self.assertLine(lines, f"{ORG}/engine main: pull_request rule from repository ruleset 777 is not",
                        f"repos/{ORG}/engine/rulesets/777")

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
        self.assertIn("KeyError: 'parameters'", err.getvalue())
        self.assertIn("could not run: unexpected error", err.getvalue())

    def test_a_crash_exits_3_and_never_1(self):
        """Exit 1 means "differences", so a baseline shape --validate does not know must not end in it."""
        self.base["check_integration_id"] = {"not": "an id"}  # passes --validate, breaks the comparison
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(self.run_check(), (3, []))
        self.assertIn("TypeError", err.getvalue())
        self.assertIn("could not run: unexpected error", err.getvalue())

    def test_hidden_organization_fields_are_unverifiable(self):
        for key in ("members_can_create_repositories", "members_can_create_teams", "two_factor_requirement_enabled"):
            del self.api[f"orgs/{ORG}"][key]  # what a member without admin:org sees
        code, lines = self.run_check()
        self.assertEqual(code, 2)
        self.assertEqual(lines, [f"could not verify: orgs/{ORG}: members_can_create_repositories, "
                                 "members_can_create_teams, two_factor_requirement_enabled not visible to this login "
                                 "(needs admin:org, or a field name is misspelled)"])

    def test_misspelled_fields_are_baseline_errors_when_the_login_sees_everything(self):
        self.base["organization_settings"]["members_can_create_team"] = False
        self.base["profiles"]["standard"]["repository"]["allow_squash_merges"] = True
        self.api[f"repos/{ORG}/engine"]["permissions"] = {"admin": True}
        self.base["security_configurations"]["Example baseline"]["dependabot_alert"] = "enabled"
        code, lines = self.run_check()
        self.assertEqual(code, 1)
        self.assertLine(lines, f"orgs/{ORG}: members_can_create_team is not in the API response",
                        "correct the field name in the baseline")
        self.assertLine(lines, f"{ORG}/engine: allow_squash_merges is not in the API response")
        self.assertLine(lines, "(Example baseline): dependabot_alert is not in the API response")
        # Without admin on the repository the field may be hidden, so it is unverifiable, never blamed on admin:org.
        self.assertLine(lines, f"could not verify: {ORG}/docs: allow_squash_merges not visible to this login "
                        "(needs admin on the repository, or a field name is misspelled)")


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
                                (lambda b: next(iter(b["rulesets"].values()))["rules"].append({}),
                                 "rules with a type"),
                                (lambda b: b["required_check_ruleset"]["rules"][0].update(parameters=3),
                                 "required_check_ruleset must"),
                                (lambda b: b["required_check_ruleset"]["rules"][0].update(parameters=[]),
                                 "required_check_ruleset must"),
                                (lambda b: next(iter(b["rulesets"].values()))["rules"][0].update(parameters="x"),
                                 "rulesets must be"),
                                (lambda b: b["actions"].update({"selected-actions": {}}), "actions must be"),
                                (lambda b: b["actions"].update(workflow=[]), "actions must be"),
                                (lambda b: b["recorded"].update(teams=["x"]), "recorded must be"),
                                (lambda b: b["recorded"].update(team={}), "recorded must be"),
                                (lambda b: b["security_configurations"].update(x=1), "security_configurations must be"),
                                (lambda b: b.update(security_configurations=3), "security_configurations must be"),
                                (lambda b: b.update(security_configurations=None), "security_configurations must be"),
                                (lambda b: b.update(security_configurations=True), "security_configurations must be"),
                                (lambda b: b.update(organization_settings=[]), "organization_settings must be"),
                                (lambda b: b["reminders"].append({"item": "x"}), "reminders must be"),
                                (lambda b: b["required_check_ruleset"].update(name="CI"), "required_check_ruleset must"),
                                (lambda b: b.pop("organization"), "organization must be"),
                                (lambda b: b.update(repositories=[]), "repositories must be"),
                                (lambda b: b["repositories"]["docs"].update(profile=["x"]), "docs: needs a known"),
                                (lambda b: b["repositories"]["docs"].update(overrides=3, why="x"),
                                 "docs override: must be an object")]:
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
        self.assertLessEqual(lines, 575, "the check is meant to stay small; simplify before growing it")


if __name__ == "__main__":
    unittest.main()
