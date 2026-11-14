# Atrinik GitHub settings

This repository is the home of Atrinik's GitHub organization settings record:

- [`check_settings.py`](check_settings.py): a read-only check that compares
  an organization's live settings with a baseline file.
- [`baselines/atrinik.json`](baselines/atrinik.json): Atrinik's baseline,
  written from the live organization on 2026-11-14.
- [`config/planning.json`](config/planning.json): the **Atrinik work** Project
  and its status names. Agent skills read the status names from here.
- [`tests/`](tests): offline tests with invented fixtures, and a small check
  of this repository's own files
  ([`.github/scripts/check_repository.py`](.github/scripts/check_repository.py)).

GitHub holds the rules. Organization rulesets aim at all repositories instead
of lists of names, so a new repository is covered without being registered
anywhere. The check and the baseline only say whether the live organization
still looks the way it was last recorded.

## Run the check

You need Python 3.10 or newer and `gh`, logged in as someone who can read the
organization's settings (for Atrinik, the owner).

```sh
python3 check_settings.py baselines/atrinik.json
```

It prints nothing and exits 0 when everything matches. Otherwise it prints one
line per difference, each ending with `| fix:` and what would make the live
organization match the baseline, usually a command, then a blank line and the
things it could not verify:

```text
atrinik/pathfinder: allow_merge_commit is true, baseline false | fix: gh api --method PATCH repos/atrinik/pathfinder -F allow_merge_commit=false
could not verify: orgs/atrinik webhooks: Not Found (HTTP 404) (the login lacks the admin:org_hook scope)
```

| Exit | Meaning |
| --- | --- |
| 0 | Everything matches. |
| 1 | At least one difference. |
| 2 | No difference, but something could not be verified. |
| 3 | The check could not run: bad arguments, an invalid baseline, no `gh`, `gh` not logged in or its token rejected, an unreadable repository list, or any unexpected error, such as an API response or a baseline shape it does not know (the traceback goes to standard error). Exit 1 always means differences, never a crash. The run stopped and printed nothing on standard output, so any difference it had found is not shown: fix the cause and rerun it. A single read that fails or times out (for example one network blip) is a "could not verify" line instead, and the run goes on. |

The check never runs a fix itself. A fix command is a suggestion: when the
difference comes from a change the task authorized or the owner approved,
update the baseline instead.

Other uses:

```sh
python3 check_settings.py --validate baselines/atrinik.json   # the file only (keys, shapes, limits), offline
python3 check_settings.py baselines/atrinik.json --ruleset '02 - Changes through pull requests'
```

`--validate` catches the usual mistakes in a baseline file. A shape it does
not know still ends in exit 3 at the live run. `--ruleset` prints a ruleset's
body from the baseline. The fix commands for rulesets pipe it into
`gh api --method PUT|POST ... --input -`.

### Another organization

The script holds no organization's data. Pass any organization's baseline by
path, for example one kept in a private repository:

```sh
python3 check_settings.py /path/to/private/baseline.json
```

Keep a private organization's baseline and its check output out of this
public repository, its pull requests and its CI logs.

### Without `admin:org`

If the login lacks `admin:org`, the per-repository checks still run: merge
settings, effective rules on each default branch and the tag rules, security
configuration attachment, team grants, environments and repository webhooks.
Organization-level reads (Actions policy, organization rulesets, security
configurations, teams, installed Apps) and settings GitHub hides from that
login become "could not verify" lines. When the login does see the whole
response (an owner with `admin:org` for the organization, admin on the
repository for merge settings, and always for Actions policy and security
configurations), a baseline field the response lacks is a difference
("is not in the API response"): usually a misspelled field name. Organization webhooks need
`admin:org_hook`, which the everyday login does not have, so that line is
expected.

## What it checks

**Policy**, compared field by field:

- organization settings (`organization_settings`);
- Actions policy, allowed actions and default workflow permissions
  (`actions`);
- organization rulesets (`rulesets`, plus one required-check ruleset per
  repository generated from `required_check_ruleset`); a ruleset missing
  from either side is a difference;
- each repository's effective rules on its default branch, its required
  checks, and the rules on its release tags (`branch_rules`, `checks`,
  `tag_rules`). Branch rules come from GitHub's own view of what applies to
  the default branch, so they also catch a repository-level ruleset or an
  organization ruleset that stopped targeting the repository. Every rule of
  a type must match the profile's parameters, and a rule type the profile
  does not name is a difference. So list every parameter of a rule in the
  profile, as `baselines/atrinik.json` does for `pull_request`, or a
  repository ruleset could tighten or loosen the unlisted ones unseen.
  These lines name the ruleset a rule comes from and always print, even
  when that ruleset has a line of its own. They carry a command only for a
  repository ruleset (`repos/O/R/rulesets/ID`). For an organization ruleset
  the command is on that ruleset's own line, which exists when the ruleset
  is missing, unrecorded or different from the baseline (a "could not
  verify" line if it could not be read). When there is neither, the
  baseline's rulesets and the profile disagree, and the fix is in the
  baseline. Tag rules are checked for presence only, and a tag
  ruleset with ref excludes does not count; if a tag ruleset's body cannot
  be read, the tag check is one "could not verify" line;
- security configurations, which one is the default for new repositories,
  and which one each repository has attached (`security_configurations`,
  `security_configuration`);
- each repository's merge settings (`repository`).

**Changed since last recorded**, names only (`recorded`): teams and their
repository grants, installed Apps and their repository selection mode
(`all` or `selected`), environment names, and webhook hosts. A line here
means something changed since the baseline was written, not that it is
wrong.

**Repositories it cannot classify fail it.** Every repository in the
organization must be listed under `repositories` with a profile, and every
listed one must exist.

## The baseline file

One JSON file per organization:

| Key | What it holds |
| --- | --- |
| `organization` | The organization's login. |
| `notes` | Free text for people. Not checked. |
| `organization_settings`, `actions` | Values compared with the live ones. |
| `rulesets` | Organization rulesets by name; each is the body a `PUT` would send. |
| `required_check_ruleset`, `check_integration_id` | The template for the one-per-repository required-check ruleset (`{repository}` is replaced) and the App that must report the checks (15368 is GitHub Actions). |
| `security_configurations` | Configurations by name, with `default_for_new_repos`. |
| `profiles` | At most three repository profiles: `repository` (merge settings), `branch_rules`, `tag_rules`, `security_configuration`. |
| `repositories` | Every repository: its `profile`, its required `checks`, and rarely `overrides` of profile keys with a `why`. An override of an object key, such as `repository`, changes only the entries it names. |
| `recorded` | Names only: `teams`, `apps`, `environments`, `webhooks`, `organization_webhooks`. |
| `reminders` | Plain notes about credentials and Apps, such as rotation dates. Never checked. |

Values are compared as subsets: a field GitHub adds later does not make a
difference, and lists match in any order.

## How a change is made

Live state wins and the record catches up in the same task:

1. Run the check. Report any difference you did not cause first, before you
   change anything.
2. Make the change in GitHub, under the owner's login, only when the current
   task authorizes it.
3. Run the check again. It shows exactly what you changed.
4. Update the baseline for the change the task authorized, until the check
   shows no difference the task caused, and open a pull request here that
   quotes the output and explains each remaining line. A difference you did
   not cause goes into the baseline only with the owner's explicit approval.

Changes made by hand in GitHub's web pages show up at the next run. GitHub
keeps its own history too: the organization audit log and each ruleset's
history.

## Limits

These keep the check small enough to read in one sitting. Simplify instead of
growing past them.

- Nothing that writes. The script only runs `gh api -X GET`; the tests check
  that.
- No dates that fail it. Rotation and review dates are reminders only.
- At most three repository profiles and about ten per-repository
  exceptions (`overrides`). `--validate` enforces three and ten.
- About 500 lines for the script. A test stops it at 550.
- Standard library only, and no stored token: it runs as whoever runs it,
  by hand. Nothing runs it on a schedule.

## The old automation is retired

On 2026-11-14 the owner retired the automation that used to live here: the
settings publisher, the Project synchronizer, the drift audit, the Project
health check, the community-health generator and semantic release. It needed
a standing organization-owner credential stored in GitHub; that credential is
gone and will not be replaced. The tooling is in the Git history and in
release
[`v2.26.0`](https://github.com/atrinik/github-settings/releases/tag/v2.26.0)
for reference only.

- The **Atrinik work** Project board is no longer filled automatically. Add
  issues and pull requests to it by hand when they belong there.
- [`atrinik/.github`](https://github.com/atrinik/.github) is edited by hand
  through pull requests in that repository.
- Required full-SHA action pinning is on. CodeQL is not a merge requirement;
  its alerts stay advisory. The `playtester` merge queue pilot is dropped.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md).
