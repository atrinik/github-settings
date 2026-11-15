# Atrinik GitHub settings repository guide

- This repository holds Atrinik's settings baseline
  (`baselines/atrinik.json`) and the read-only check that compares it with
  the live organization (`check_settings.py`). Read `README.md` first.
- Run the check before and after any Atrinik settings change, and report any
  difference you did not cause first:
  `python3 check_settings.py baselines/atrinik.json`. Exit 0 is a match, 1
  differences, 2 only "could not verify", 3 could not run. The organization
  webhooks line is expected: the everyday login lacks `admin:org_hook`.
- How a change is made: change the setting in GitHub under the owner's login,
  only when the current task authorizes that change; run the check; update
  the baseline for that change until the check shows no difference the task
  caused; open a pull request here that quotes the output and explains each
  remaining line. A difference you did not cause goes into the baseline only
  with the owner's explicit approval. Live state wins and the record catches
  up in the same task. Never record a change first and apply it later.
- The check only reads. Never run its fix commands unless the current task
  authorizes that exact change. Never add code to it that writes, stores a
  token or runs on a schedule.
- Keep within its limits: nothing that writes, no dates that fail it, at
  most three repository profiles, about ten per-repository exceptions, about
  500 lines, standard library only. If a change would cross one, simplify
  instead.
- Another organization's baseline is checked by path
  (`python3 check_settings.py /path/to/its/baseline.json`), and its baseline
  pull request goes to the repository that holds that baseline, not here.
  Keep a private organization's baseline, its check output and its names out
  of this public repository, its pull requests and its CI logs. Test fixtures
  are invented.
- The settings automation that used to live here (publisher, Project
  synchronizer, drift audit, Project health check, community-health
  generator, semantic release) was retired on 2026-11-14 by owner decision.
  Do not restore, run or imitate it, including from an old checkout or
  release. It is in the Git history and in release `v2.26.0` for reference
  only.
- The **Atrinik work** Project is no longer filled automatically. Keep
  `config/planning.json` and its Status names as they are: agent skills read
  them.
- `atrinik/.github` is edited by hand, through pull requests in that
  repository. Nothing here generates it.
- Keep the two required check names exactly: the `Policy validation` job in
  `.github/workflows/check.yml` and `Conventional PR title` in
  `.github/workflows/pr-title.yml`. The ruleset `03 - Required CI -
  github-settings` requires both.
- Pin every action to a full commit SHA with a version comment. The
  organization requires it.
- Before you push, run:

  ```sh
  python3 .github/scripts/check_repository.py
  python3 -m unittest discover -s tests
  python3 check_settings.py --validate baselines/atrinik.json
  git diff --check
  ```

  Run actionlint when workflows change, if you have it.
- Commits and pull-request titles use Conventional Commits.
- Never print or commit tokens, secrets or API responses that contain
  credentials. The baseline records names only.
