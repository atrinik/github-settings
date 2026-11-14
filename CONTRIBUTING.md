# Contributing

Use a Conventional Commits pull-request title, for example
`docs: describe the settings baseline`. Pull requests are squash-merged.

Before you push, run:

```sh
python3 .github/scripts/check_repository.py
git diff --check
```

The check confirms that every JSON file parses, that every relative link in
the Markdown files points at a file that exists, and that every action in the
workflows is pinned to a full commit SHA. Run
[actionlint](https://github.com/rhysd/actionlint) as well when you change a
workflow.

Keep `config/planning.json` unchanged unless the **Atrinik work** Project
itself changes: agent skills read its Status names.

Never commit tokens, secrets or API responses that contain credentials.
