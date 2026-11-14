#!/usr/bin/env python3
"""Check that this repository's own files are valid.

- every tracked JSON file parses;
- every relative link in a tracked Markdown file points at a tracked path;
- every `uses:` in a workflow is a local path, a Docker image digest or an
  action pinned to a full 40-character commit SHA.

Prints one line per problem and exits 1 if there is any. Standard library
only; it reads files and never touches the network.
"""

import json
import pathlib
import re
import subprocess
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Inline links and images: [text](target) or ![alt](target "title").
INLINE_LINK = re.compile(r"!?\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+[\"'][^)]*[\"'])?\s*\)")
# Reference definitions: [label]: target
REFERENCE_LINK = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HTML_LINK = re.compile(r"""<(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
FENCE = re.compile(r"^\s{0,3}(```|~~~)")
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*['\"]?([^\s'\"#]+)")
PINNED = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[^@\s]+)?@[0-9a-f]{40}$")
DOCKER_DIGEST = re.compile(r"^docker://\S+@sha256:[0-9a-f]{64}$")


def tracked_files():
    output = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    ).stdout
    return sorted(pathlib.PurePosixPath(name) for name in output.decode().split("\0") if name)


def check_json(path, problems):
    try:
        with open(ROOT / path, encoding="utf-8") as stream:
            json.load(stream)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        problems.append(f"{path}: invalid JSON: {error}")


def link_targets(text):
    in_fence = None
    for number, line in enumerate(text.splitlines(), start=1):
        fence = FENCE.match(line)
        if fence:
            marker = fence.group(1)
            if in_fence is None:
                in_fence = marker
            elif marker == in_fence:
                in_fence = None
            continue
        if in_fence is not None:
            continue
        line = INLINE_CODE.sub("", line)
        for pattern in (INLINE_LINK, HTML_LINK):
            for match in pattern.finditer(line):
                yield number, match.group(1)
        reference = REFERENCE_LINK.match(line)
        if reference:
            yield number, reference.group(1)


def check_markdown(path, known, problems):
    text = (ROOT / path).read_text(encoding="utf-8")
    known_dirs = {parent for item in known for parent in item.parents}
    for number, target in link_targets(text):
        parsed = urllib.parse.urlsplit(target)
        if parsed.scheme or parsed.netloc or target.startswith("#"):
            continue
        relative = urllib.parse.unquote(parsed.path)
        if relative.startswith("/"):
            resolved = pathlib.PurePosixPath(relative.lstrip("/"))
        else:
            resolved = pathlib.PurePosixPath(*_normalize(path.parent / relative))
        if resolved not in known and resolved not in known_dirs:
            problems.append(f"{path}:{number}: broken relative link: {target}")


def _normalize(path):
    parts = []
    for part in path.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            else:
                parts.append("..")
            continue
        parts.append(part)
    return parts


def check_workflow(path, problems):
    text = (ROOT / path).read_text(encoding="utf-8")
    for number, line in enumerate(text.splitlines(), start=1):
        match = USES.match(line)
        if not match:
            continue
        reference = match.group(1)
        if reference.startswith("./") or PINNED.match(reference) or DOCKER_DIGEST.match(reference):
            continue
        problems.append(f"{path}:{number}: action is not pinned to a full commit SHA: {reference}")


def main():
    files = tracked_files()
    known = set(files)
    problems = []
    for path in files:
        if path.suffix == ".json":
            check_json(path, problems)
        elif path.suffix == ".md":
            check_markdown(path, known, problems)
        if path.parent == pathlib.PurePosixPath(".github/workflows") and path.suffix in (".yml", ".yaml"):
            check_workflow(path, problems)
    for problem in problems:
        print(problem)
    if problems:
        return 1
    print(f"Checked {len(files)} tracked files: no problems.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
