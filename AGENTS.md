# Atrinik GitHub settings repository guide

- This repository is the home of Atrinik's GitHub organization settings
  record. Read `README.md` first. Today it holds `config/planning.json` and a
  small CI check; a read-only settings check and Atrinik's baseline file are
  coming in a later pull request.
- The settings automation that used to live here (publisher, Project
  synchronizer, drift audit, Project health check, community-health generator,
  semantic release) was retired on 2026-11-14 by owner decision: there is no
  standing organization-owner credential any more, and the rules now live in
  organization rulesets that target all repositories. Do not restore, run or
  imitate those tools, including from an old checkout or release. They are in
  the Git history and in release `v2.26.0` for reference only.
- Settings are changed by hand under the owner's login, only when the current
  task authorizes that change. Record each change in this repository in the
  same task, through a pull request.
- The **Atrinik work** Project is no longer filled automatically. Keep
  `config/planning.json` and its Status names as they are: agent skills read
  them.
- `atrinik/.github` is edited by hand, through pull requests in that
  repository. Nothing here generates it.
- Settled rollouts: required full-SHA action pinning is on; CodeQL as a merge
  requirement and the `playtester` merge queue are dropped.
- Keep the two required check names exactly: the `Policy validation` job in
  `.github/workflows/check.yml` and `Conventional PR title` in
  `.github/workflows/pr-title.yml`. The ruleset `03 - Required CI -
  github-settings` requires both.
- Pin every action to a full commit SHA with a version comment. The
  organization requires it.
- Before you push, run `python3 .github/scripts/check_repository.py` and
  `git diff --check`. Run actionlint when workflows change, if you have it.
- Commits and pull-request titles use Conventional Commits.
- Never print or commit tokens, secrets or API responses that contain
  credentials.
