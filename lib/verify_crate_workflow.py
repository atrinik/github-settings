#!/usr/bin/env python3
"""Verify the executable OIDC publication contract on exact-main workflow bytes."""

import argparse
import re
import shlex
import sys

try:
    import yaml
except ImportError:
    sys.exit("error: install requirements-validation.txt to verify observed crate workflows")


class UniqueLoader(yaml.SafeLoader):
    """Reject ambiguous duplicate keys and preserve Actions' `on` YAML key."""

    yaml_implicit_resolvers = {
        key: [(tag, regex) for tag, regex in values if tag != "tag:yaml.org,2002:bool"]
        for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor("tag:yaml.org,2002:map", unique_mapping)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def expression(value):
    require(isinstance(value, str), "missing executable job condition")
    value = value.strip()
    if value.startswith("${{") and value.endswith("}}"):
        value = value[3:-2].strip()
    return value


def run_configuration(value, context):
    defaults = value.get("defaults", {})
    require(isinstance(defaults, dict), f"invalid {context} run defaults")
    run_defaults = defaults.get("run", {})
    require(isinstance(run_defaults, dict) and not run_defaults,
            f"{context} run defaults must not override executable helper semantics")


def critical_step(step, context):
    require("shell" not in step and "working-directory" not in step,
            f"{context} must use the standard runner shell and workspace")
    require(step.get("continue-on-error", "false") == "false",
            f"{context} must fail on execution errors")


def helper_run(step, operation):
    if "if" in step or not isinstance(step.get("run"), str):
        return False
    try:
        tokens = shlex.split(step["run"], comments=False)
    except ValueError:
        return False
    expected = ["python3", "tools/crate_release.py", operation, "--release-id",
                "SOURCE_RELEASE_ID", "--revision", "SOURCE_REVISION", "--manifest-sha256", "MANIFEST_SHA256"]
    if len(tokens) != len(expected):
        return False
    return all(token in ("$" + expected[index], "${" + expected[index] + "}")
               if index in (4, 6, 8) else token == expected[index]
               for index, token in enumerate(tokens))


def verify(source, repository, repository_id):
    workflow = yaml.load(source, Loader=UniqueLoader)
    require(isinstance(workflow, dict), "workflow must be a YAML mapping")
    run_configuration(workflow, "workflow")
    triggers = workflow.get("on")
    require(isinstance(triggers, dict) and "workflow_dispatch" in triggers
            and set(triggers) <= {"workflow_dispatch", "schedule"},
            "publication must offer workflow_dispatch with only optional reconciliation schedule")
    operation = triggers["workflow_dispatch"]["inputs"]["operation"]
    require(isinstance(operation, dict) and operation.get("type") == "choice"
            and isinstance(operation.get("options"), list) and "automatic" in operation["options"],
            "dispatch must offer the automatic operation")
    require(workflow.get("permissions") == {"contents": "read"},
            "workflow default permission must be contents read only")
    require("CARGO_REGISTRY_TOKEN" not in workflow.get("env", {}),
            "registry token must not be workflow scoped")
    jobs = workflow.get("jobs")
    require(isinstance(jobs, dict), "missing executable publication jobs")
    guard = {
        f"github.repository == '{repository}'",
        f"github.repository_id == '{repository_id}'",
        "github.ref == 'refs/heads/main'",
        "github.event_name == 'workflow_dispatch'",
        "inputs.operation == 'automatic'",
    }
    matching = {name: job for name, job in jobs.items() if isinstance(job, dict)
                and isinstance(job.get("if"), str)
                and {term.strip() for term in expression(job["if"]).split("&&")} == guard}
    publish_names = [name for name, job in matching.items()
                     if isinstance(job.get("permissions"), dict)
                     and job["permissions"].get("id-token") == "write"]
    require(len(matching) == 2 and len(publish_names) == 1,
            "automatic operation needs one credential-free verify job and one OIDC publish job")
    publish_name = publish_names[0]
    verify_name = next(name for name in matching if name != publish_name)
    for name in (verify_name, publish_name):
        job = jobs.get(name)
        require(isinstance(job, dict), f"missing job {name}")
        run_configuration(job, name)
        require(job.get("continue-on-error", "false") == "false",
                f"{name} must fail on execution errors")
        terms = expression(job.get("if")).split("&&")
        require(len(terms) == len(guard) and {term.strip() for term in terms} == guard,
                f"{name} must enforce exactly the repository/id/main/dispatch/automatic guard")
        require(isinstance(job.get("runs-on"), (str, list)) and bool(job["runs-on"]),
                f"{name} has no runner")
        require("CARGO_REGISTRY_TOKEN" not in job.get("env", {}),
                f"{name} must not scope the registry token to the job")
        for key, value in {
            "SOURCE_RELEASE_ID": "${{ inputs.source_release_id }}",
            "SOURCE_REVISION": "${{ inputs.source_revision }}",
            "MANIFEST_SHA256": "${{ inputs.manifest_sha256 }}",
        }.items():
            require(job.get("env", {}).get(key) == value,
                    f"{name} must bind {key} to the reviewed dispatch input")
        steps = job.get("steps")
        require(isinstance(steps, list) and steps, f"{name} has no executable steps")
        checkouts = [step for step in steps if isinstance(step, dict)
                     and str(step.get("uses", "")).startswith("actions/checkout@")]
        require(len(checkouts) == 1, f"{name} must check out the exact main revision")
        checkout = checkouts[0]
        critical_step(checkout, f"{name} checkout")
        require(re.fullmatch(r"actions/checkout@[0-9a-f]{40}", checkout["uses"]) is not None
                and checkout.get("with", {}).get("ref") == "${{ github.sha }}"
                and str(checkout.get("with", {}).get("persist-credentials")).lower() == "false"
                and "if" not in checkout, f"{name} checkout identity/credential drift")
        for step in steps:
            require(isinstance(step, dict), f"invalid {name} step")
            if "uses" in step:
                require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}",
                                     str(step["uses"])) is not None,
                        f"{name} action reference must be a full immutable SHA")
    for name in (verify_name, publish_name):
        for step in jobs[name]["steps"]:
            if helper_run(step, "verify"):
                critical_step(step, f"{name} verification")
    verify_job = jobs[verify_name]
    require(verify_job.get("permissions", workflow["permissions"]) == {"contents": "read"},
            "automatic verification must not request OIDC")
    require(any(helper_run(step, "verify") for step in verify_job["steps"]),
            "automatic verification helper must run unconditionally")
    publish = jobs[publish_name]
    require(publish.get("needs") in (verify_name, [verify_name]),
            "automatic publication must depend on credential-free verification")
    require(publish.get("environment") == "crates-io-release", "wrong publication environment")
    require(publish.get("permissions") == {"contents": "read", "id-token": "write"},
            "automatic upload needs exactly contents read and OIDC write")
    auth_steps = [(index, step) for index, step in enumerate(publish["steps"])
                  if str(step.get("uses", "")).startswith("rust-lang/crates-io-auth-action@")]
    require(len(auth_steps) == 1, "automatic upload needs one official authentication action")
    auth_index, auth = auth_steps[0]
    critical_step(auth, "official authentication step")
    require(auth.get("id") == "auth" and "if" not in auth,
            "official authentication step must be executable and have id auth")
    require(any(helper_run(step, "verify") for step in publish["steps"][:auth_index]),
            "upload must reverify bytes before requesting OIDC")
    uploads = [(index, step) for index, step in enumerate(publish["steps"])
               if "CARGO_REGISTRY_TOKEN" in step.get("env", {})]
    require(len(uploads) == 1, "only one upload step may receive the registry token")
    upload_index, upload = uploads[0]
    critical_step(upload, "registry upload step")
    require(upload_index > auth_index and upload.get("id") in (None, "upload") and "if" not in upload
            and upload["env"]["CARGO_REGISTRY_TOKEN"] == "${{ steps.auth.outputs.token }}"
            and helper_run(upload, "upload"),
            "upload must execute after auth with only the returned temporary token")
    for name, job in jobs.items():
        if name == publish_name:
            continue
        if repository == "atrinik/protocol" and name == "publish":
            # Protocol 0.2 retains its separately reviewed manual upload path.
            manual_guard = (guard - {"inputs.operation == 'automatic'"}) | {
                "inputs.operation == 'publish'", "needs.verify.outputs.ready == 'true'"}
            terms = expression(job.get("if")).split("&&")
            require(job.get("environment") == "crates-io-release"
                    and len(terms) == len(manual_guard)
                    and {term.strip() for term in terms} == manual_guard
                    and job.get("needs") in ("verify", ["verify"])
                    and job.get("permissions") == {"contents": "read", "id-token": "write"},
                    "protocol manual upload path identity/permission drift")
            for step in job.get("steps", []):
                if "uses" in step:
                    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}",
                                         str(step["uses"])) is not None,
                            "protocol manual path action reference must be immutable")
            continue
        permissions = job.get("permissions", workflow["permissions"])
        require(isinstance(permissions, dict) and permissions.get("id-token", "none") == "none",
                f"unexpected OIDC permission on {name}")
    return auth["uses"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--repository-id", required=True)
    args = parser.parse_args()
    try:
        action = verify(sys.stdin.read(), args.repository, args.repository_id)
    except (ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        sys.exit(f"error: crate publication executable workflow drift: {error}")
    print(f"Executable automatic publication contract verified; immutable auth action {action}")


if __name__ == "__main__":
    main()
