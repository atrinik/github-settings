# Contributing

Use a Conventional Commits pull-request title, for example
`docs: describe the settings baseline`. Pull requests are squash-merged.

Before you push, run:

```sh
python3 .github/scripts/check_repository.py
python3 -m unittest discover -s tests
python3 check_settings.py --validate baselines/atrinik.json
git diff --check
```

The first command confirms that every JSON file parses, that every relative
link in the Markdown files points at a file that exists, and that every action
in the workflows is pinned to a full commit SHA. The tests run the settings
check offline against invented fixtures in `tests/fixtures/`. Run
[actionlint](https://github.com/rhysd/actionlint) as well when you change a
workflow.

A pull request that changes `baselines/atrinik.json` follows a settings change
that was already made. Quote the output of
`python3 check_settings.py baselines/atrinik.json` in its description: empty
when everything matches, otherwise each remaining line and why it remains.

Keep `config/planning.json` unchanged unless the **Atrinik work** Project
itself changes: agent skills read its Status names.

Never commit tokens, secrets or API responses that contain credentials.
