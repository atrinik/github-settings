#!/usr/bin/env python3
"""Read-only check of one GitHub organization against its baseline file.

Usage: check_settings.py BASELINE.json [--validate | --ruleset NAME]. It runs only `gh api -X GET` as whoever
is logged in and writes nothing. Exit: 0 match, 1 differences, 2 only "could not verify", 3 could not run.
README.md has the output, the baseline format and the limits.
"""

import argparse
import concurrent.futures
import copy
import functools
import json
import re
import shlex
import subprocess
import sys
import traceback
import urllib.parse

MAX_PROFILES = 3
MAX_EXCEPTIONS = 10
TOP_KEYS = {"organization", "organization_settings", "actions", "rulesets", "required_check_ruleset", "reminders",
            "check_integration_id", "security_configurations", "profiles", "repositories", "recorded", "notes"}
ACTIONS_PATHS = {"permissions": "", "selected_actions": "/selected-actions", "workflow": "/workflow"}


def mapping(of=lambda v: True):
    """A shape test: an object whose values all pass `of`."""
    return lambda v: isinstance(v, dict) and all(of(x) for x in v.values())


def names_list(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


SHAPES = {"repository": ("an object of fields", mapping()),  # profile keys, as the check reads them
          "branch_rules": ("rule type to parameters", mapping(mapping())),
          "tag_rules": ('a "ref" and a list of rule types in "rules"',
                        lambda v: isinstance(v, dict) and isinstance(v.get("ref"), str) and names_list(v.get("rules"))),
          "security_configuration": ("a name", lambda v: isinstance(v, str))}
RECORDED = {"teams": mapping(mapping(lambda v: isinstance(v, str))), "apps": mapping(lambda v: isinstance(v, str)),
            "environments": mapping(names_list), "webhooks": mapping(names_list), "organization_webhooks": names_list}
RULESET = lambda v: (isinstance(v, dict) and {"target", "enforcement"} <= set(v) and isinstance(  # noqa: E731
    v.get("rules"), list) and all(isinstance(r, dict) and isinstance(r.get("type"), str)
                                  and isinstance(r.get("parameters", {}), dict) for r in v["rules"]))
SECTIONS = {"organization": ("the organization's login", lambda v: isinstance(v, str) and v != ""),
            "organization_settings": ("an object of fields", mapping()),  # top-level sections the check reads
            "rulesets": ("name to target, enforcement and rules with a type and object parameters", mapping(RULESET)),
            "required_check_ruleset": ("a rulesets entry with {repository} in its name",
                                       lambda v: RULESET(v) and "{repository}" in str(v.get("name"))),
            "reminders": ('a list of objects with an "item" and a "note"', lambda v: isinstance(v, list) and all(
                isinstance(i, dict) and isinstance(i.get("item"), str) and isinstance(i.get("note"), str) for i in v)),
            "actions": ("permissions, selected_actions or workflow, each an object of fields",
                        lambda v: mapping(mapping())(v) and set(v) <= set(ACTIONS_PATHS)),
            "security_configurations": ("configuration name to an object of fields", mapping(mapping())),
            "repositories": ("repository name to an object with a profile", mapping(lambda v: isinstance(v, dict))),
            "recorded": (f"{', '.join(RECORDED)}, each in its shape (README.md)",
                         lambda v: isinstance(v, dict) and all(k in RECORDED and RECORDED[k](x) for k, x in v.items()))}
# Organization settings the REST API cannot change: the fix is this settings page.
WEB_ONLY = dict.fromkeys(["members_can_delete_repositories", "members_can_change_repo_visibility",
                          "members_can_delete_issues", "members_can_invite_outside_collaborators",
                          "members_can_create_teams", "readers_can_create_discussions"], "member_privileges")
WEB_ONLY.update(two_factor_requirement_enabled="security", default_repository_branch="repository_defaults")
show = functools.partial(json.dumps, sort_keys=True)
# Effective rules are GitHub's computed view of a branch or tag, so their lines name the ruleset and carry no command.
SEE_RULESETS = ("an organization ruleset that is missing, unrecorded or different from the baseline has its own "
                "line with the command; otherwise correct the ruleset by hand, or the baseline")


class Unverifiable(Exception):
    """A read that failed: missing scope or missing access."""


class CannotRun(Exception):
    """gh is not logged in, or the repository list could not be read."""


def parse_output(text):
    """gh prints one JSON value per page; join pages of a list into one list."""
    decoder, text, pos, values = json.JSONDecoder(), text.strip(), 0, []
    while pos < len(text):
        value, pos = decoder.raw_decode(text, pos)
        values.append(value)
        pos = len(text) - len(text[pos:].lstrip())
    if len(values) < 2:
        return values[0] if values else None
    return [item for value in values for item in value]


def gh_fetch(path, paginate):
    command = ["gh", "api", "-X", "GET", path] + (["--paginate"] if paginate else [])
    proc = subprocess.run(command, capture_output=True, text=True, check=False)
    if proc.returncode == 0:
        return parse_output(proc.stdout)
    message = (proc.stderr.strip().splitlines() or ["gh api failed"])[0].removeprefix("gh: ")[:160]
    scope = re.search(r'needs the "([^"]+)" scope', proc.stderr)
    if not scope and re.search(r"gh auth login|HTTP 401|Bad credentials", proc.stderr, re.IGNORECASE):
        raise CannotRun(message)  # no read can succeed; a timeout on one read is only "could not verify"
    if scope:
        message += f" (the login lacks the {scope.group(1)} scope)"
    elif path.startswith("orgs/") and re.search(r"HTTP 40[34]", message):
        message += " (the login may lack admin:org)"
    raise Unverifiable(message)


class GitHub:
    """Cached GET reads. `get` returns parsed JSON, or the Unverifiable a failed `fetch` raised."""

    def __init__(self, fetch=gh_fetch):
        self.fetch, self.cache = fetch, {}

    def get(self, path, paginate=False):
        if path not in self.cache:
            try:  # an empty response (204, such as no configuration attached) reads as {}
                value = self.fetch(path, paginate)
                self.cache[path] = {} if value is None else value
            except Unverifiable as error:
                self.cache[path] = error
        return self.cache[path]

    def prefetch(self, reads):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda read: self.get(*read), reads))


def gh_command(method, path, body=None):
    command = f"gh api --method {method} {shlex.quote(path)}"
    if body is None:
        return command
    if all(isinstance(v, (str, bool, int)) or v is None for v in body.values()):
        return " ".join([command] + [("-f " if isinstance(v, str) else "-F ") + shlex.quote(
            f"{k}={v if isinstance(v, str) else json.dumps(v)}") for k, v in body.items()])
    return f"echo {shlex.quote(json.dumps(body, separators=(',', ':')))} | {command} --input -"


def matches(want, have):
    """True when `have` holds everything in `want`. Lists match in any order."""
    if isinstance(want, dict):
        return isinstance(have, dict) and all(k in have and matches(v, have[k]) for k, v in want.items())
    if isinstance(want, list):
        if not isinstance(have, list) or len(want) != len(have):
            return False
        left = list(have)
        for item in want:
            found = next((i for i, other in enumerate(left) if matches(item, other)), None)
            if found is None:
                return False
            left.pop(found)
        return True
    return type(want) is type(have) and want == have


def expected_rulesets(base):
    rulesets = {name: dict(body, name=name) for name, body in base.get("rulesets", {}).items()}
    template = base.get("required_check_ruleset")
    if template:
        for repo, entry in sorted(base.get("repositories", {}).items()):
            if not entry.get("checks"):
                continue
            body = json.loads(json.dumps(template).replace("{repository}", repo))
            app = {"integration_id": base["check_integration_id"]} if base.get("check_integration_id") else {}
            for rule in (r for r in body["rules"] if r["type"] == "required_status_checks"):
                rule.setdefault("parameters", {})["required_status_checks"] = [dict(app, context=c)
                                                                               for c in entry["checks"]]
            rulesets[body["name"]] = body
    return rulesets


def profile_for(base, entry):
    profile = copy.deepcopy(base["profiles"][entry["profile"]])
    profile.update(copy.deepcopy(entry.get("overrides", {})))
    return profile


def shape_errors(where, value, shapes):
    """The shapes the checker reads, so a malformed baseline fails --validate instead of the live run."""
    if not isinstance(value, dict):
        return [f"{where}: must be an object"]
    return [f"{where}: unknown key {k!r}" for k in sorted(set(value) - set(shapes))] + [
        f"{where}: {k} must be {shapes[k][0]}" for k in sorted(set(value) & set(shapes)) if not shapes[k][1](value[k])]


def validate(base):
    if not isinstance(base, dict):
        return ["the baseline must be a JSON object"]
    errors = [f"unknown top-level key {k!r}" for k in sorted(set(base) - TOP_KEYS)]
    errors += shape_errors("baseline", {k: v for k, v in dict({"organization": None}, **base).items() if k in SECTIONS},
                           SECTIONS)
    profiles = base.get("profiles")
    if not isinstance(profiles, dict) or not 1 <= len(profiles) <= MAX_PROFILES:
        errors.append(f'"profiles" must hold 1 to {MAX_PROFILES} profiles')
        profiles = {}
    bad_profiles = set()
    for name, profile in profiles.items():
        bad = shape_errors(f"profile {name}", profile, SHAPES)
        errors, bad_profiles = errors + bad, bad_profiles | ({name} if bad else set())
    configs, exceptions = base.get("security_configurations", {}), 0
    repos = base.get("repositories")  # a section of the wrong shape is reported above
    for repo, entry in sorted(repos.items() if isinstance(repos, dict) else []):
        if not isinstance(entry, dict) or entry.get("profile") not in list(profiles):  # list: value may be unhashable
            errors.append(f"repository {repo}: needs a known profile")
            continue
        if not names_list(entry.get("checks", [])):
            errors.append(f"repository {repo}: checks must be a list of check names")
        overrides = entry.get("overrides", {})
        bad = shape_errors(f"repository {repo} override", overrides, SHAPES)
        errors, exceptions = errors + bad, exceptions + (len(overrides) if isinstance(overrides, dict) else 0)
        if bad or entry["profile"] in bad_profiles:
            continue
        if overrides and not entry.get("why"):
            errors.append(f'repository {repo}: an override needs a "why"')
        wanted = profile_for(base, entry).get("security_configuration")
        if wanted and isinstance(configs, dict) and wanted not in configs:  # a bad section is reported above
            errors.append(f"repository {repo}: security configuration {wanted!r} is not in the baseline")
    if exceptions > MAX_EXCEPTIONS:
        errors.append(f"{exceptions} per-repository exceptions; the limit is {MAX_EXCEPTIONS}")
    return errors


class Checker:
    def __init__(self, base, github, script="check_settings.py", baseline="BASELINE"):
        self.base, self.gh, self.org = base, github, base["organization"]
        self.diffs, self.unverified = [], []
        self.ruleset_cmd = f"python3 {shlex.quote(script)} {shlex.quote(baseline)} --ruleset"
        self.wanted_rulesets = expected_rulesets(base)
        self.live_ruleset_ids, self.config_ids, self.recorded = None, {}, base.get("recorded", {})

    def diff(self, where, text, fix):
        self.diffs.append(f"{where}: {text} | fix: {fix}")

    def changed(self, where, text, undo):
        self.diffs.append(f"{where}: {text} (changed since last recorded) | fix: record it in the baseline, "
                          f"or undo: {undo}")

    def cannot(self, where, reason):
        self.unverified.append(f"could not verify: {where}: {reason}")

    def read(self, where, path, paginate=False):
        value = self.gh.get(path, paginate)
        if isinstance(value, Unverifiable):
            return self.cannot(where, str(value))
        return value

    def names(self, where, label, have, recorded, undo_new, undo_gone):
        for name in sorted(set(have) - set(recorded)):
            self.changed(where, f"{label} {name!r} is new", undo_new(name))
        for name in sorted(set(recorded) - set(have)):
            self.changed(where, f"{label} {name!r} is gone", undo_gone(name))

    def ruleset_fix(self, name):
        """POST when the live list lacks it, PUT when known; ID stands in when the list could not be read."""
        known = self.live_ruleset_ids is None or name in self.live_ruleset_ids
        path = f"orgs/{self.org}/rulesets" + (f"/{(self.live_ruleset_ids or {}).get(name, 'ID')}" if known else "")
        return f"{self.ruleset_cmd} {shlex.quote(name)} | gh api --method {'PUT' if known else 'POST'} {path} --input -"

    def compare_fields(self, where, want, have, fix_for, needs=None):
        """A field the response lacks is unverifiable when the login `needs` more access, else a baseline error."""
        hidden = ", ".join(sorted(set(want) - set(have)))
        if hidden and not needs:
            self.diff(where, f"{hidden} is not in the API response", "correct the field name in the baseline")
        elif hidden:
            self.cannot(where, f"{hidden} not visible to this login (needs {needs}, or a field name is misspelled)")
        for key, value in want.items():
            if key in have and not matches(value, have[key]):
                self.diff(where, f"{key} is {show(have[key])}, baseline {show(value)}", fix_for(key, value))

    def run(self):
        org = self.org  # organization reads run one by one; the per-repository ones run eight at a time
        self.check_organization()
        self.check_actions()
        self.check_rulesets()
        self.check_security_configurations()
        repos = self.gh.get(f"orgs/{org}/repos?per_page=100&type=all", True)
        if isinstance(repos, Unverifiable):
            raise CannotRun(f"cannot list the repositories, so none was checked: {repos}")
        self.check_repositories({r["name"]: r for r in repos})
        self.check_apps()

    def check_organization(self):
        live, page = self.read(f"orgs/{self.org}", f"orgs/{self.org}"), f"https://github.com/organizations/{self.org}"
        if live is not None:
            fix = lambda k, v: (f"change it at {page}/settings/{WEB_ONLY[k]}" if k in WEB_ONLY  # noqa: E731
                                else gh_command("PATCH", f"orgs/{self.org}", {k: v}))
            # Owners with admin:org see the member privileges; without them, hidden fields are unverifiable.
            self.compare_fields(f"orgs/{self.org}", self.base.get("organization_settings", {}), live, fix,
                                None if "members_can_create_repositories" in live else "admin:org")

    def check_actions(self):
        for section, want in self.base.get("actions", {}).items():
            live = self.read(path := f"orgs/{self.org}/actions/permissions{ACTIONS_PATHS[section]}", path)
            if live is not None:
                self.compare_fields(path, want, live, lambda key, value, p=path, w=want: gh_command("PUT", p, w))

    def check_rulesets(self):
        listing = self.read("organization rulesets", f"orgs/{self.org}/rulesets?per_page=100", True)
        if listing is None:
            return
        self.live_ruleset_ids = {r["name"]: r["id"] for r in listing}
        self.gh.prefetch([(f"orgs/{self.org}/rulesets/{r['id']}", False) for r in listing])
        for name, want in sorted(self.wanted_rulesets.items()):
            if name not in self.live_ruleset_ids:
                self.diff(f"orgs/{self.org}/rulesets", f"ruleset {name!r} is missing", self.ruleset_fix(name))
                continue
            live = self.read(path := f"orgs/{self.org}/rulesets/{self.live_ruleset_ids[name]}", path)
            if live is not None and not matches(want, live):
                keys = ", ".join(k for k in sorted(want) if not matches(want[k], live.get(k)))
                self.diff(path, f"ruleset {name!r} differs in {keys}", self.ruleset_fix(name))
        for name, rid in sorted(self.live_ruleset_ids.items()):
            if name not in self.wanted_rulesets:
                self.diff(f"orgs/{self.org}/rulesets/{rid}", f"ruleset {name!r} is not in the baseline",
                                 f"record it, or {gh_command('DELETE', f'orgs/{self.org}/rulesets/{rid}')}")

    def check_security_configurations(self):
        path = f"orgs/{self.org}/code-security/configurations"
        live = self.read("security configurations", f"{path}?per_page=100", True)
        defaults = self.read("security configuration defaults", f"{path}/defaults")
        if live is None:
            return
        live = {c["name"]: c for c in live if c.get("target_type") != "global"}
        self.config_ids = {name: c["id"] for name, c in live.items()}
        default_of = {d["configuration"]["id"]: d["default_for_new_repos"] for d in defaults or []}
        for name, want in sorted(self.base.get("security_configurations", {}).items()):
            want = dict({"default_for_new_repos": "none"}, **want)  # not a default unless the baseline says so
            if name not in live:
                body = {k: v for k, v in want.items() if k != "default_for_new_repos"}
                self.diff(path, f"security configuration {name!r} is missing", gh_command("POST", path, body))
                continue
            target, have = f"{path}/{live[name]['id']}", dict(live[name], default_for_new_repos=default_of.get(
                live[name]["id"], "none"))
            if defaults is None:  # already a could-not-verify line
                del want["default_for_new_repos"]
            self.compare_fields(f"{target} ({name})", want, have, lambda k, v, t=target: gh_command(
                "PUT", f"{t}/defaults", {k: v}) if k == "default_for_new_repos" else gh_command("PATCH", t, {k: v}))
        for name in sorted(set(live) - set(self.base.get("security_configurations", {}))):
            target = f"{path}/{live[name]['id']}"
            self.diff(target, f"security configuration {name!r} is not in the baseline",
                      f"record it, or {gh_command('DELETE', target)}")

    def check_repositories(self, live_repos):
        org, wanted = self.org, self.base.get("repositories", {})
        for name in sorted(set(live_repos) - set(wanted)):
            self.diff(f"{org}/{name}", "repository is not classified", 'add it under "repositories" with a profile')
        for name in sorted(set(wanted) - set(live_repos)):
            self.diff(f"{org}/{name}", "repository is in the baseline only", "remove it from the baseline")
        names = sorted(set(live_repos) & set(wanted))
        reads = []
        for name in names:
            branch = urllib.parse.quote(live_repos[name]["default_branch"], safe="")
            base = f"repos/{org}/{name}"
            reads += [(base + p, False) for p in ("", "/code-security-configuration", "/environments?per_page=100")]
            reads += [(base + p, True) for p in (f"/rules/branches/{branch}?per_page=100", "/hooks?per_page=100",
                                                 "/rulesets?includes_parents=true&per_page=100", "/teams?per_page=100")]
        self.gh.prefetch(reads)
        grants, unread = {}, set()
        for name in names:
            profile, entry = profile_for(self.base, wanted[name]), wanted[name]
            repo = self.read(f"{org}/{name}", f"repos/{org}/{name}")
            if repo is None:
                continue
            self.compare_fields(f"{org}/{name}", profile.get("repository", {}), repo,
                                lambda key, value, n=name: gh_command("PATCH", f"repos/{org}/{n}", {key: value}),
                                None if (repo.get("permissions") or {}).get("admin") else "admin on the repository")
            if "branch_rules" in profile:
                self.check_branch_rules(name, repo, profile["branch_rules"], entry.get("checks", []))
            if "tag_rules" in profile:
                self.check_tag_rules(name, profile["tag_rules"])
            if "security_configuration" in profile:
                self.check_attachment(name, repo, profile["security_configuration"])
            teams = self.read(f"{org}/{name} teams", f"repos/{org}/{name}/teams?per_page=100", True)
            unread |= {name} if teams is None else set()
            for team in teams or []:
                grants.setdefault(team["slug"], {})[name] = team["permission"]
            self.check_environments(name)
            self.check_webhooks(f"{org}/{name}", f"repos/{org}/{name}/hooks", f"https://github.com/{org}/{name}",
                                self.recorded.get("webhooks", {}).get(name, []))
        self.check_teams(grants, set(names) - unread)
        self.check_webhooks(f"orgs/{org}", f"orgs/{org}/hooks", f"https://github.com/organizations/{org}",
                            self.recorded.get("organization_webhooks", []))

    def rule_source(self, name, rule):
        """Where an effective rule comes from, and its fix: a command only for a repository ruleset."""
        rid = rule.get("ruleset_id")
        if rule.get("ruleset_source_type") == "Organization":
            return f"organization ruleset {rid}", SEE_RULESETS
        path = f"repos/{self.org}/{name}/rulesets/{rid}"
        return f"repository ruleset {rid}", (f"change the rule in {path} (read it, edit, PUT it back with --input -), "
                                             f"or {gh_command('DELETE', path)}")

    def check_branch_rules(self, name, repo, want_rules, checks):
        where = f"{self.org}/{name} {repo['default_branch']}"
        branch = urllib.parse.quote(repo["default_branch"], safe="")
        live = self.read(where, f"repos/{self.org}/{name}/rules/branches/{branch}?per_page=100", True)
        if live is None:
            return
        for rule_type in sorted(set(want_rules) - {r["type"] for r in live}):
            self.diff(where, f"no {rule_type} rule", SEE_RULESETS)
        required = [r for r in live if r["type"] == "required_status_checks"]
        for rule in (r for r in live if r["type"] != "required_status_checks"):  # each must match, from any ruleset
            source, fix = self.rule_source(name, rule)
            if rule["type"] not in want_rules:
                self.diff(where, f"unexpected {rule['type']} rule from {source}", fix)
            elif not matches(want_rules[rule["type"]], rule.get("parameters", {})):
                self.diff(where, f"{rule['type']} rule from {source} is not {show(want_rules[rule['type']])}", fix)
        app = self.base.get("check_integration_id")
        have = sorted({(c["context"], c.get("integration_id") if app else None) for r in required
                       for c in r["parameters"]["required_status_checks"]}, key=str)
        want = sorted({(c, app) for c in checks}, key=str)
        if have != want:
            sources = ", ".join(sorted({self.rule_source(name, r)[0] for r in required})) or "no ruleset"
            self.diff(where, f"required checks are {show([c for c, _ in have])}"
                             f"{' (or from another app)' if [c for c, _ in have] == [c for c, _ in want] else ''} "
                             f"from {sources}, baseline {show(checks)}", SEE_RULESETS)

    def check_tag_rules(self, name, want):
        where, base = f"{self.org}/{name} tags {want['ref']}", f"repos/{self.org}/{name}/rulesets"
        listing = self.read(where, f"{base}?includes_parents=true&per_page=100", True)
        if listing is None:
            return
        found, excluded = set(), []
        for item in (i for i in listing if i.get("target") == "tag" and i.get("enforcement") == "active"):
            body = self.read(where, f"{base}/{item['id']}?includes_parents=true")
            if body is None:  # an unreadable body is "could not verify", not missing rules
                return
            ref_name = (body.get("conditions") or {}).get("ref_name", {})
            if {want["ref"], "~ALL"} & set(ref_name.get("include", [])):  # a ruleset with ref excludes does not count
                excluded += [str(item["id"])] if ref_name.get("exclude") else []
                found |= set() if ref_name.get("exclude") else {r["type"] for r in body["rules"]}
        note = f" (ruleset {', '.join(excluded)} has ref excludes, so it does not count)" if excluded else ""
        for rule_type in want["rules"]:
            if rule_type not in found:
                self.diff(where, f"no {rule_type} rule{note}", SEE_RULESETS)

    def check_attachment(self, name, repo, want):
        where = f"{self.org}/{name}"
        live = self.read(f"{where} security configuration", f"repos/{self.org}/{name}/code-security-configuration")
        if live is None:
            return
        have, status = (live.get("configuration") or {}).get("name"), live.get("status")
        if have != want or status not in ("attached", "enforced"):
            cid = self.config_ids.get(want, "ID")
            self.diff(where, f"security configuration is {have!r} ({status}), baseline {want!r}",
                             gh_command("POST", f"orgs/{self.org}/code-security/configurations/{cid}/attach",
                                        {"scope": "selected", "selected_repository_ids[]": repo["id"]}))

    def check_environments(self, name):
        path = f"repos/{self.org}/{name}/environments"
        live = self.read(f"{self.org}/{name} environments", f"{path}?per_page=100")
        undo = lambda method: lambda env: gh_command(method, f"{path}/{urllib.parse.quote(env, safe='')}")  # noqa
        if live is not None:
            self.names(f"{self.org}/{name}", "environment", {e["name"] for e in live.get("environments", [])},
                       self.recorded.get("environments", {}).get(name, []), undo("DELETE"), undo("PUT"))

    def check_webhooks(self, where, hook_path, page, recorded):
        live = self.read(f"{where} webhooks", f"{hook_path}?per_page=100", True)
        if live is None:
            return
        hosts = {}
        for hook in live:
            url = (hook.get("config") or {}).get("url") or ""
            hosts.setdefault(urllib.parse.urlsplit(url).hostname or hook.get("name", "?"), []).append(hook["id"])
        delete = lambda host: " && ".join(gh_command("DELETE", f"{hook_path}/{hid}") for hid in hosts[host])  # noqa
        self.names(where, "webhook to", hosts, recorded, delete, lambda host: f"recreate it at {page}/settings/hooks")

    def check_teams(self, grants, checked):
        """Team names (organization read) and their grants on the repositories read in `checked`."""
        org, recorded = self.org, self.recorded.get("teams", {})
        teams = self.read("teams", f"orgs/{org}/teams?per_page=100", True)
        live = set(recorded) if teams is None else {t["slug"] for t in teams}
        self.names(f"orgs/{org}", "team", live, recorded, lambda team: gh_command("DELETE", f"orgs/{org}/teams/{team}"),
                   lambda team: gh_command("POST", f"orgs/{org}/teams", {"name": team}))
        for team in sorted((set(grants) | set(recorded)) - (live ^ set(recorded))):  # new or gone teams: reported above
            have, want = grants.get(team, {}), recorded.get(team, {})
            for repo in sorted((set(have) | set(want)) & checked):
                if have.get(repo) != want.get(repo):
                    path = f"orgs/{org}/teams/{team}/repos/{org}/{repo}"
                    undo = gh_command(*("PUT", path, {"permission": want[repo]}) if repo in want else ("DELETE", path))
                    self.changed(f"{org}/{repo}", f"team {team!r} has {have.get(repo, 'no access')}, "
                                        f"recorded {want.get(repo, 'no access')}", undo)

    def check_apps(self):
        live = self.read("installed apps", f"orgs/{self.org}/installations?per_page=100")
        if live is None:
            return
        have = {i["app_slug"]: i["repository_selection"] for i in live.get("installations", [])}
        recorded, page = self.recorded.get("apps", {}), f"https://github.com/organizations/{self.org}/settings"
        for app in sorted(set(have) | set(recorded)):
            if have.get(app) != recorded.get(app):
                self.changed(f"orgs/{self.org}", f"app {app!r} reaches {have.get(app, 'nothing')} repositories, "
                             f"recorded {recorded.get(app, 'not installed')}", f"change it at {page}/installations")


def run(argv, github):
    parser = argparse.ArgumentParser(description="Read-only check of a GitHub organization against a baseline file.")
    parser.error = lambda message: parser.exit(3, f"{parser.format_usage()}check_settings.py: {message}\n")  # not 2
    parser.add_argument("baseline", help="the organization's baseline JSON file")
    parser.add_argument("--validate", action="store_true", help="only check the baseline file, offline")
    parser.add_argument("--ruleset", metavar="NAME", help="print the baseline body of one organization ruleset")
    args = parser.parse_args(argv)
    try:
        with open(args.baseline, encoding="utf-8") as stream:
            base = json.load(stream)
    except (OSError, ValueError) as error:
        print(f"{args.baseline}: cannot read the baseline: {error}", file=sys.stderr)
        return 3
    errors = validate(base)
    for error in errors:
        print(f"{args.baseline}: {error}", file=sys.stderr)
    if errors or args.validate:
        return 3 if errors else 0
    if args.ruleset:
        body = expected_rulesets(base).get(args.ruleset)
        print(json.dumps(body, indent=2, sort_keys=True) if body else f"no ruleset {args.ruleset!r} in {args.baseline}",
              file=sys.stdout if body else sys.stderr)
        return 0 if body else 3
    checker = Checker(base, github or GitHub(), sys.argv[0] if argv is None else "check_settings.py", args.baseline)
    try:
        checker.run()
    except (CannotRun, FileNotFoundError) as error:
        reason = "gh is not installed or not on PATH" if isinstance(error, FileNotFoundError) else error
        print(f"could not run: {reason}", file=sys.stderr)
        return 3
    lines = checker.diffs + ([""] if checker.diffs and checker.unverified else []) + checker.unverified
    if lines:
        print("\n".join(lines))
    return 1 if checker.diffs else 2 if checker.unverified else 0


def main(argv=None, github=None):
    """Exit 1 means "differences", so nothing else may end in it: any unexpected error is exit 3."""
    try:
        return run(argv, github)
    except Exception:  # a baseline shape --validate does not know, an unexpected API response, or a bug
        traceback.print_exc()
        print("could not run: unexpected error (traceback above); nothing was compared", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
