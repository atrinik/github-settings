# Atrinik GitHub settings

This repository is the home of Atrinik's GitHub organization settings record.
Today it holds very little:

- [`config/planning.json`](config/planning.json): the **Atrinik work** Project
  and its status names. Agent skills read the status names from here.
- A small CI check ([`.github/scripts/check_repository.py`](.github/scripts/check_repository.py))
  that keeps the files in this repository valid.

A read-only settings check and Atrinik's settings baseline will be added here
by a later pull request.

## The old automation is retired

On 2026-11-14 the owner retired the automation that used to live here: the
settings publisher, the Project synchronizer, the drift audit, the Project
health check, the community-health generator and semantic release. They were
removed because:

- They needed a standing organization-owner credential stored in GitHub. That
  credential is gone and will not be replaced.
- The rules they managed now live in organization rulesets that target all
  repositories, so a new repository is covered without being registered
  anywhere.
- The replacement is a read-only check and a short baseline file, both coming
  to this repository.

## How settings change now

- The owner, or an agent session she authorizes, changes settings by hand
  under her own login, in GitHub's web pages or with `gh`.
- The change is recorded here in the same task, through a pull request. Until
  the baseline file lands, it is recorded in the description of the pull
  request or task that made it.
- The **Atrinik work** Project board is no longer filled automatically. Add
  issues and pull requests to it by hand when they belong there.
- [`atrinik/.github`](https://github.com/atrinik/.github) (issue forms,
  pull-request template, contribution guidance, public profile) is no longer
  generated from here. Edit it by hand through pull requests in that
  repository.

## Rollouts that were never switched on

The old configuration declared three rollouts that were never switched on.
They are now settled:

- Required full-SHA pinning of actions is on for the organization.
- CodeQL as a merge requirement is dropped. CodeQL alerts stay advisory.
- The merge queue pilot on `playtester` is dropped.

## History

The retired tooling, its configuration and its documentation are in the Git
history. The last release that contains them is
[`v2.26.0`](https://github.com/atrinik/github-settings/releases/tag/v2.26.0).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md).
