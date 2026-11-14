#!/usr/bin/env python3
"""Read-only check of one GitHub organization against its baseline file.

Usage: check_settings.py BASELINE.json [--validate | --ruleset NAME]. It runs only
`gh api -X GET` as whoever is logged in to gh and writes nothing. It prints nothing
when everything matches; otherwise one line per difference with a command that would
fix it, then what it could not verify. Exit: 0 match, 1 differences, 2 only "could not
verify", 3 could not run. Standard library only; README.md has the format and limits.
"""

import argparse
import concurrent.futures
import copy
import json
import re
import shlex
import subprocess
import sys
import urllib.parse

MAX_PROFILES = 3
MAX_EXCEPTIONS = 10
TOP_KEYS = {"organization", "organization_settings", "actions", "rulesets", "required_check_ruleset",
            "check_integration_id", "security_configurations", "profiles", "repositories", "recorded",
            "reminders", "notes"}
PROFILE_KEYS = {"repository", "branch_rules", "tag_rules", "security_configuration"}
RECORDED_KEYS = {"teams", "apps", "environments", "webhooks", "organization_webhooks"}
ACTIONS_PATHS = {"permissions": "", "selected_actions": "/selected-actions", "workflow": "/workflow"}
# Organization settings the REST API cannot change: the fix is this settings page.
WEB_ONLY = dict.fromkeys(["members_can_delete_repositories", "members_can_change_repo_visibility",
                          "members_can_delete_issues", "members_can_invite_outside_collaborators",
                          "members_can_create_teams", "readers_can_create_discussions"], "member_privileges")
WEB_ONLY.update(two_factor_requirement_enabled="security", default_repository_branch="repository_defaults")
ATTACHED = {"attached", "enforced"}


class Unverifiable(Exception):
    """A read that failed: missing scope or missing access."""


class CannotRun(Exception):
    """gh is not logged in, the network failed, or the repository list could not be read."""



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
    if not scope and re.search(r"gh auth login|HTTP 401|Bad credentials|error connecting|could not resolve|dial tcp|"
                               r"timed? ?out|connection (refused|reset)", proc.stderr, re.IGNORECASE):
        raise CannotRun(message)
    if scope:
        message += f" (the login lacks the {scope.group(1)} scope)"
    elif path.startswith("orgs/") and re.search(r"HTTP 40[34]", message):
        message += " (the login may lack admin:org)"
    raise Unverifiable(message)


class GitHub:
    """Cached GET reads. `fetch(path, paginate)` returns parsed JSON or raises Unverifiable."""

    def __init__(self, fetch=gh_fetch):
        self.fetch, self.cache = fetch, {}

    def get(self, path, paginate=False):
        if path not in self.cache:
            try:
                self.cache[path] = self.fetch(path, paginate)
            except Unverifiable as error:
                self.cache[path] = error
        if isinstance(self.cache[path], Unverifiable):
            raise self.cache[path]
        return self.cache[path]

    def prefetch(self, reads):
        def load(read):
            try:
                self.get(*read)
            except Unverifiable:
                pass
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(load, reads))


def show(value):
    return json.dumps(value, sort_keys=True)


def gh_command(method, path, body=None):
    command = f"gh api --method {method} {shlex.quote(path)}"
    if body is None:
        return command
    if all(isinstance(v, (str, bool, int)) or v is None for v in body.values()):
        fields = []
        for key, value in body.items():
            flag = "-f" if isinstance(value, str) else "-F"
            text = value if isinstance(value, str) else json.dumps(value)
            fields.append(f"{flag} {shlex.quote(f'{key}={text}')}")
        return " ".join([command] + fields)
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
            for rule in body["rules"]:
                if rule["type"] == "required_status_checks":
                    rule.setdefault("parameters", {})["required_status_checks"] = [
                        dict({"context": c}, **({"integration_id": base["check_integration_id"]}
                                                if base.get("check_integration_id") else {}))
                        for c in entry["checks"]]
            rulesets[body["name"]] = body
    return rulesets


def profile_for(base, entry):
    profile = copy.deepcopy(base["profiles"][entry["profile"]])
    profile.update(copy.deepcopy(entry.get("overrides", {})))
    return profile


def validate(base):
    errors = []
    if not isinstance(base, dict):
        return ["the baseline must be a JSON object"]
    errors += [f"unknown top-level key {k!r}" for k in sorted(set(base) - TOP_KEYS)]
    if not isinstance(base.get("organization"), str) or not base.get("organization"):
        errors.append('"organization" must name the organization')
    profiles = base.get("profiles")
    if not isinstance(profiles, dict) or not 1 <= len(profiles) <= MAX_PROFILES:
        errors.append(f'"profiles" must hold 1 to {MAX_PROFILES} profiles')
        profiles = {}
    for name, profile in profiles.items():
        errors += [f"profile {name}: unknown key {k!r}" for k in sorted(set(profile) - PROFILE_KEYS)]
    configs = base.get("security_configurations", {})
    exceptions = 0
    for repo, entry in sorted(base.get("repositories", {}).items()):
        if not isinstance(entry, dict) or entry.get("profile") not in profiles:
            errors.append(f"repository {repo}: needs a known profile")
            continue
        if not isinstance(entry.get("checks", []), list) or not all(isinstance(c, str) for c in entry.get("checks", [])):
            errors.append(f"repository {repo}: checks must be a list of check names")
        overrides = entry.get("overrides", {})
        exceptions += len(overrides)
        errors += [f"repository {repo}: unknown override {k!r}" for k in sorted(set(overrides) - PROFILE_KEYS)]
        if overrides and not entry.get("why"):
            errors.append(f'repository {repo}: an override needs a "why"')
        wanted = profile_for(base, entry).get("security_configuration")
        if wanted and wanted not in configs:
            errors.append(f"repository {repo}: security configuration {wanted!r} is not in the baseline")
    if exceptions > MAX_EXCEPTIONS:
        errors.append(f"{exceptions} per-repository exceptions; the limit is {MAX_EXCEPTIONS}")
    for name, body in base.get("rulesets", {}).items():
        if not isinstance(body, dict) or not {"target", "enforcement", "rules"} <= set(body):
            errors.append(f"ruleset {name}: needs target, enforcement and rules")
    template = base.get("required_check_ruleset")
    if template is not None and "{repository}" not in str(template.get("name", "")):
        errors.append('"required_check_ruleset" name must contain {repository}')
    errors += [f"recorded: unknown key {k!r}" for k in sorted(set(base.get("recorded", {})) - RECORDED_KEYS)]
    for item in base.get("reminders", []):
        if not (isinstance(item, dict) and isinstance(item.get("item"), str) and isinstance(item.get("note"), str)):
            errors.append('each reminder needs an "item" and a "note"')
    return errors


class Checker:
    def __init__(self, base, github, script="check_settings.py", baseline="BASELINE"):
        self.base, self.gh, self.org = base, github, base["organization"]
        self.diffs, self.unverified = [], []
        self.ruleset_cmd = f"python3 {shlex.quote(script)} {shlex.quote(baseline)} --ruleset"
        self.wanted_rulesets = expected_rulesets(base)
        self.live_ruleset_ids = None
        self.config_ids = {}

    def diff(self, where, text, fix):
        self.diffs.append(f"{where}: {text} | fix: {fix}")

    def changed(self, where, text, undo):
        self.diffs.append(f"{where}: {text} (changed since last recorded) | fix: record it in the baseline, "
                          f"or undo: {undo}")

    def cannot(self, where, reason):
        self.unverified.append(f"could not verify: {where}: {reason}")

    def read(self, where, path, paginate=False):
        try:
            return self.gh.get(path, paginate)
        except Unverifiable as error:
            self.cannot(where, str(error))
            return None

    def names(self, where, label, have, recorded, undo_new, undo_gone):
        for name in sorted(set(have) - set(recorded)):
            self.changed(where, f"{label} {name!r} is new", undo_new(name))
        for name in sorted(set(recorded) - set(have)):
            self.changed(where, f"{label} {name!r} is gone", undo_gone(name))

    def ruleset_fix(self, name):
        """POST when the live list lacks it, PUT when known; ID stands in when the list could not be read."""
        ids = self.live_ruleset_ids
        method, rid = ("POST", "") if ids is not None and name not in ids else ("PUT", f"/{(ids or {}).get(name, 'ID')}")
        return f"{self.ruleset_cmd} {shlex.quote(name)} | gh api --method {method} orgs/{self.org}/rulesets{rid} --input -"

    def compare_fields(self, where, want, have, fix_for):
        hidden = sorted(set(want) - set(have))
        if hidden:
            self.cannot(where, f"{', '.join(hidden)} not visible to this login (needs admin:org?)")
        for key, value in want.items():
            if key in have and not matches(value, have[key]):
                self.diff(where, f"{key} is {show(have[key])}, baseline {show(value)}", fix_for(key, value))

    def run(self):
        org = self.org
        self.gh.prefetch([(f"orgs/{org}", False), (f"orgs/{org}/rulesets?per_page=100", True),
                          (f"orgs/{org}/code-security/configurations?per_page=100", True),
                          (f"orgs/{org}/code-security/configurations/defaults", False),
                          (f"orgs/{org}/teams?per_page=100", True), (f"orgs/{org}/installations?per_page=100", False),
                          (f"orgs/{org}/hooks?per_page=100", True), (f"orgs/{org}/repos?per_page=100&type=all", True)]
                         + [(f"orgs/{org}/actions/permissions{p}", False) for p in ACTIONS_PATHS.values()])
        self.check_organization()
        self.check_actions()
        self.check_rulesets()
        self.check_security_configurations()
        try:
            repos = self.gh.get(f"orgs/{org}/repos?per_page=100&type=all", True)
        except Unverifiable as error:
            raise CannotRun(f"cannot list the repositories, so none was checked: {error}") from error
        self.check_repositories({r["name"]: r for r in repos})
        self.check_apps()

    def check_organization(self):
        live, page = self.read(f"orgs/{self.org}", f"orgs/{self.org}"), f"https://github.com/organizations/{self.org}"
        if live is not None:
            self.compare_fields(f"orgs/{self.org}", self.base.get("organization_settings", {}), live, lambda k, v:
                                f"change it at {page}/settings/{WEB_ONLY[k]}" if k in WEB_ONLY
                                else gh_command("PATCH", f"orgs/{self.org}", {k: v}))

    def check_actions(self):
        for section, want in self.base.get("actions", {}).items():
            path = f"orgs/{self.org}/actions/permissions{ACTIONS_PATHS[section]}"
            live = self.read(path, path)
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
            path = f"orgs/{self.org}/rulesets/{self.live_ruleset_ids[name]}"
            live = self.read(path, path)
            if live is not None and not matches(want, live):
                keys = ", ".join(k for k in sorted(want) if not matches(want[k], live.get(k)))
                self.diff(path, f"ruleset {name!r} differs in {keys}", self.ruleset_fix(name))
        for name, rid in sorted(self.live_ruleset_ids.items()):
            if name not in self.wanted_rulesets:
                self.diff(f"orgs/{self.org}/rulesets/{rid}", f"ruleset {name!r} is not in the baseline",
                                 f"record it, or {gh_command('DELETE', f'orgs/{self.org}/rulesets/{rid}')}")

    def check_security_configurations(self):
        want_all = self.base.get("security_configurations", {})
        path = f"orgs/{self.org}/code-security/configurations"
        live = self.read("security configurations", f"{path}?per_page=100", True)
        defaults = self.read("security configuration defaults", f"{path}/defaults")
        if live is None:
            return
        live = {c["name"]: c for c in live if c.get("target_type") != "global"}
        self.config_ids = {name: c["id"] for name, c in live.items()}
        default_of = {d["configuration"]["id"]: d["default_for_new_repos"] for d in defaults or []}
        for name, want in sorted(want_all.items()):
            settings = {k: v for k, v in want.items() if k != "default_for_new_repos"}
            if name not in live:
                self.diff(path, f"security configuration {name!r} is missing",
                                 gh_command("POST", path, dict(settings, name=name)))
                continue
            cid = live[name]["id"]
            wrong = {k: v for k, v in settings.items() if not matches(v, live[name].get(k))}
            if wrong:
                self.diff(f"{path}/{cid}", f"{name!r} differs in {', '.join(sorted(wrong))}",
                                 gh_command("PATCH", f"{path}/{cid}", wrong))
            want_default, have_default = want.get("default_for_new_repos", "none"), default_of.get(cid, "none")
            if defaults is not None and want_default != have_default:
                self.diff(f"{path}/{cid}", f"{name!r} is the default for {have_default!r} repositories, "
                                 f"baseline {want_default!r}", gh_command("PUT", f"{path}/{cid}/defaults",
                                                                          {"default_for_new_repos": want_default}))
        for name in sorted(set(live) - set(want_all)):
            target = f"{path}/{live[name]['id']}"
            self.diff(target, f"security configuration {name!r} is not in the baseline",
                             f"record it, or {gh_command('DELETE', target)}")

    def check_repositories(self, live_repos):
        org, wanted = self.org, self.base.get("repositories", {})
        for name in sorted(set(live_repos) - set(wanted)):
            self.diff(f"{org}/{name}", "repository is not classified",
                             'add it under "repositories" in the baseline with a profile')
        for name in sorted(set(wanted) - set(live_repos)):
            self.diff(f"{org}/{name}", "repository is in the baseline but not in the organization",
                             "remove it from the baseline")
        names = sorted(set(live_repos) & set(wanted))
        reads = []
        for name in names:
            branch = urllib.parse.quote(live_repos[name]["default_branch"], safe="")
            base = f"repos/{org}/{name}"
            reads += [(base, False), (f"{base}/rules/branches/{branch}?per_page=100", True),
                      (f"{base}/rulesets?includes_parents=true&per_page=100", True),
                      (f"{base}/code-security-configuration", False), (f"{base}/environments?per_page=100", False),
                      (f"{base}/hooks?per_page=100", True), (f"{base}/teams?per_page=100", True)]
        self.gh.prefetch(reads)
        grants, unread = {}, set()
        for name in names:
            profile, entry = profile_for(self.base, wanted[name]), wanted[name]
            repo = self.read(f"{org}/{name}", f"repos/{org}/{name}")
            if repo is None:
                continue
            self.compare_fields(f"{org}/{name}", profile.get("repository", {}), repo,
                                lambda key, value, n=name: gh_command("PATCH", f"repos/{org}/{n}", {key: value}))
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
            self.check_webhooks(f"{org}/{name}", f"repos/{org}/{name}/hooks?per_page=100",
                                self.base.get("recorded", {}).get("webhooks", {}).get(name, []),
                                f"https://github.com/{org}/{name}/settings/hooks", f"repos/{org}/{name}/hooks")
        self.check_teams(grants, set(names) - unread)
        self.check_webhooks(f"orgs/{org}", f"orgs/{org}/hooks?per_page=100",
                            self.base.get("recorded", {}).get("organization_webhooks", []),
                            f"https://github.com/organizations/{org}/settings/hooks", f"orgs/{org}/hooks")

    def provider_fix(self, target, rule_type):
        for name, body in sorted(self.base.get("rulesets", {}).items()):
            if body.get("target") == target and any(r["type"] == rule_type for r in body["rules"]):
                return self.ruleset_fix(name)
        return f"add a {rule_type} rule to an organization ruleset in the baseline"

    def check_branch_rules(self, name, repo, want_rules, checks):
        where = f"{self.org}/{name} {repo['default_branch']}"
        branch = urllib.parse.quote(repo["default_branch"], safe="")
        live = self.read(where, f"repos/{self.org}/{name}/rules/branches/{branch}?per_page=100", True)
        if live is None:
            return
        for rule_type, params in sorted(want_rules.items()):
            found = [r for r in live if r["type"] == rule_type]  # every one must match, repository rulesets too
            bad = sorted({str(r.get("ruleset_id")) for r in found if not matches(params, r.get("parameters", {}))})
            if bad or not found:
                self.diff(where, f"{rule_type} rule from ruleset {', '.join(bad)} is not {show(params)}" if bad
                          else f"no {rule_type} rule", self.provider_fix("branch", rule_type))
        template = (self.base.get("required_check_ruleset") or {}).get("name", "").replace("{repository}", name)
        check_fix = self.ruleset_fix(template) if template else "change the ruleset that requires checks"
        app = self.base.get("check_integration_id")
        have = sorted({(c["context"], c.get("integration_id") if app else None) for r in live
                       if r["type"] == "required_status_checks"
                       for c in r["parameters"]["required_status_checks"]}, key=str)
        want = sorted({(c, app) for c in checks}, key=str)
        if have != want:
            self.diff(where, f"required checks are {show([c for c, _ in have])}"
                             f"{' (or from another app)' if [c for c, _ in have] == [c for c, _ in want] else ''}, "
                             f"baseline {show(checks)}", check_fix)
        known = self.live_ruleset_ids or {}
        for rule in (r for r in live if r["type"] not in want_rules and r["type"] != "required_status_checks"):
            rid, kind = rule.get("ruleset_id"), rule["type"]
            if rule.get("ruleset_source_type") != "Organization":
                self.diff(where, f"unexpected {kind} rule from ruleset {rid}", "remove it from that ruleset, or "
                          + gh_command("DELETE", f"repos/{self.org}/{name}/rulesets/{rid}"))
            elif rid not in known.values():  # a listed organization ruleset is reported by check_rulesets
                rname = next((n for n, i in known.items() if i == rid), "NAME")
                self.diff(where, f"unexpected {kind} rule from organization ruleset {rid}", f"{self.ruleset_cmd} "
                          f"{shlex.quote(rname)} | gh api --method PUT orgs/{self.org}/rulesets/{rid} --input -")

    def check_tag_rules(self, name, want):
        where, base = f"{self.org}/{name} tags {want['ref']}", f"repos/{self.org}/{name}/rulesets"
        listing = self.read(where, f"{base}?includes_parents=true&per_page=100", True)
        if listing is None:
            return
        found, excluded = set(), []
        for item in (i for i in listing if i.get("target") == "tag" and i.get("enforcement") == "active"):
            body = self.read(where, f"{base}/{item['id']}?includes_parents=true") or {}
            ref_name = (body.get("conditions") or {}).get("ref_name", {})
            if {want["ref"], "~ALL"} & set(ref_name.get("include", [])):  # a ruleset with ref excludes does not count
                excluded += [str(item["id"])] if ref_name.get("exclude") else []
                found |= set() if ref_name.get("exclude") else {r["type"] for r in body["rules"]}
        note = f" (ruleset {', '.join(excluded)} has ref excludes, so it does not count)" if excluded else ""
        for rule_type in want["rules"]:
            if rule_type not in found:
                self.diff(where, f"no {rule_type} rule{note}", self.provider_fix("tag", rule_type))

    def check_attachment(self, name, repo, want):
        where = f"{self.org}/{name}"
        try:
            live = self.gh.get(f"repos/{self.org}/{name}/code-security-configuration") or {}
        except Unverifiable as error:
            return self.cannot(f"{where} security configuration", str(error))
        have, status = (live.get("configuration") or {}).get("name"), live.get("status")
        if have != want or status not in ATTACHED:
            cid = self.config_ids.get(want, "ID")
            self.diff(where, f"security configuration is {have!r} ({status}), baseline {want!r}",
                             gh_command("POST", f"orgs/{self.org}/code-security/configurations/{cid}/attach",
                                        {"scope": "selected", "selected_repository_ids[]": repo["id"]}))

    def check_environments(self, name):
        live = self.read(f"{self.org}/{name} environments", f"repos/{self.org}/{name}/environments?per_page=100")
        if live is not None:
            path = f"repos/{self.org}/{name}/environments/"
            self.names(f"{self.org}/{name}", "environment", {e["name"] for e in live.get("environments", [])},
                       self.base.get("recorded", {}).get("environments", {}).get(name, []),
                       lambda env: gh_command("DELETE", path + urllib.parse.quote(env, safe="")),
                       lambda env: gh_command("PUT", path + urllib.parse.quote(env, safe="")))

    def check_webhooks(self, where, path, recorded, page, hook_path):
        live = self.read(f"{where} webhooks", path, True)
        if live is None:
            return
        hosts = {}
        for hook in live:
            url = (hook.get("config") or {}).get("url") or ""
            hosts.setdefault(urllib.parse.urlsplit(url).hostname or hook.get("name", "?"), []).append(hook["id"])
        self.names(where, "webhook to", hosts, recorded, lambda host: " && ".join(
            gh_command("DELETE", f"{hook_path}/{hid}") for hid in hosts[host]), lambda host: f"recreate it at {page}")

    def check_teams(self, grants, checked):
        """Team names (organization read) and their grants on the repositories read in `checked`."""
        org, recorded = self.org, self.base.get("recorded", {}).get("teams", {})
        teams = self.read("teams", f"orgs/{org}/teams?per_page=100", True)
        skip = set()
        if teams is not None:
            live_names = {t["slug"] for t in teams}
            self.names(f"orgs/{org}", "team", live_names, recorded,
                       lambda team: gh_command("DELETE", f"orgs/{org}/teams/{team}"),
                       lambda team: gh_command("POST", f"orgs/{org}/teams", {"name": team}))
            skip = live_names ^ set(recorded)
        for team in sorted((set(grants) | set(recorded)) - skip):
            have, want = grants.get(team, {}), recorded.get(team, {})
            for repo in sorted((set(have) | set(want)) & checked):
                if have.get(repo) != want.get(repo):
                    path = f"orgs/{org}/teams/{team}/repos/{org}/{repo}"
                    undo = gh_command("PUT", path, {"permission": want[repo]}) if repo in want else \
                        gh_command("DELETE", path)
                    self.changed(f"{org}/{repo}", f"team {team!r} has {have.get(repo, 'no access')}, "
                                        f"recorded {want.get(repo, 'no access')}", undo)

    def check_apps(self):
        live = self.read("installed apps", f"orgs/{self.org}/installations?per_page=100")
        if live is None:
            return
        have = {i["app_slug"]: i["repository_selection"] for i in live.get("installations", [])}
        recorded = self.base.get("recorded", {}).get("apps", {})
        page = f"https://github.com/organizations/{self.org}/settings/installations"
        for app in sorted(set(have) | set(recorded)):
            if have.get(app) != recorded.get(app):
                self.changed(f"orgs/{self.org}", f"app {app!r} reaches {have.get(app, 'nothing')} "
                                    f"repositories, recorded {recorded.get(app, 'not installed')}", f"change it at {page}")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(3, f"{self.format_usage()}check_settings.py: {message}\n")


def main(argv=None, github=None):
    parser = Parser(description="Read-only check of a GitHub organization against a baseline file.")
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
        if body is None:
            print(f"no ruleset {args.ruleset!r} in {args.baseline}", file=sys.stderr)
            return 3
        print(json.dumps(body, indent=2, sort_keys=True))
        return 0
    checker = Checker(base, github or GitHub(), sys.argv[0] if argv is None else "check_settings.py", args.baseline)
    try:
        checker.run()
    except FileNotFoundError:
        print("gh is not installed or not on PATH", file=sys.stderr)
        return 3
    except (CannotRun, KeyError, TypeError, AttributeError, IndexError) as error:
        print(f"could not run: {error if isinstance(error, CannotRun) else f'unexpected API response ({error!r})'}",
              file=sys.stderr)
        return 3
    lines = checker.diffs + ([""] if checker.diffs and checker.unverified else []) + checker.unverified
    if lines:
        print("\n".join(lines))
    return 1 if checker.diffs else 2 if checker.unverified else 0


if __name__ == "__main__":
    sys.exit(main())
