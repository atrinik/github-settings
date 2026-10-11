#!/usr/bin/env python3
"""Verify the executable OIDC publication contract on exact-main workflow bytes."""

import argparse
import re
import shlex
import sys
from pathlib import Path

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


def job_execution_shape(job, context):
    require(not any(key in job for key in ("strategy", "uses", "with", "secrets")),
            f"{context} must be one ordinary job without matrix or reusable execution")


def confined_step_references(job, upload_index=None):
    """Whitelist the two reviewed step references, including expression casing/index variants."""
    def visit(value, path=()):
        if isinstance(value, dict):
            for key, item in value.items():
                visit(key, path + ("mapping-key",))
                visit(item, path + (key,))
        elif isinstance(value, list):
            for index, item in enumerate(value):
                visit(item, path + (index,))
        elif isinstance(value, str):
            if "${{" not in value or not re.search(r"\bsteps\b", value, flags=re.IGNORECASE):
                return
            token = (upload_index is not None and
                     path == ("steps", upload_index, "env", "CARGO_REGISTRY_TOKEN") and
                     value == "${{ steps.auth.outputs.token }}")
            confirmation = (len(path) == 3 and path[0] == "steps" and path[2] == "if" and
                            value == "${{ !cancelled() && (steps.upload.outcome == 'success' || steps.upload.outcome == 'failure') }}")
            require(token or confirmation, "step references must not expose the authentication token outside validated upload")
    visit(job)


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
    require(workflow.get("env", {}) in ({}, {"PYTHONDONTWRITEBYTECODE": "1"}),
            "publication workflow must not override helper execution through global environment")
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
        job_execution_shape(job, name)
        require("outputs" not in job, f"{name} must not export credentials through job outputs")
        run_configuration(job, name)
        require(job.get("continue-on-error", "false") == "false",
                f"{name} must fail on execution errors")
        terms = expression(job.get("if")).split("&&")
        require(len(terms) == len(guard) and {term.strip() for term in terms} == guard,
                f"{name} must enforce exactly the repository/id/main/dispatch/automatic guard")
        require(job.get("runs-on") == "ubuntu-24.04" and "container" not in job and "services" not in job,
                f"{name} must use the reviewed hosted runner without execution overrides")
        require("CARGO_REGISTRY_TOKEN" not in job.get("env", {}),
                f"{name} must not scope the registry token to the job")
        for key, value in {
            "GH_READ_TOKEN": "${{ github.token }}",
            "SOURCE_RELEASE_ID": "${{ inputs.source_release_id }}",
            "SOURCE_REVISION": "${{ inputs.source_revision }}",
            "MANIFEST_SHA256": "${{ inputs.manifest_sha256 }}",
        }.items():
            require(job.get("env", {}).get(key) == value,
                    f"{name} must bind {key} to the reviewed dispatch input")
        require(set(job.get("env", {})) == {"GH_READ_TOKEN", "SOURCE_RELEASE_ID", "SOURCE_REVISION", "MANIFEST_SHA256"},
                f"{name} must not override helper execution through extra environment")
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
                and set(checkout.get("with", {})) <= {"ref", "persist-credentials", "fetch-depth"}
                and str(checkout.get("with", {}).get("fetch-depth", "0")) == "0"
                and "env" not in checkout and "run" not in checkout
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
    read_permissions = {"contents": "read", "actions": "read", "checks": "read", "attestations": "read"}
    require(verify_job.get("permissions") == read_permissions,
            "automatic verification needs only source/provenance/run/check read permissions")
    require(any(helper_run(step, "verify") for step in verify_job["steps"]),
            "automatic verification helper must run unconditionally")
    publish = jobs[publish_name]
    require(publish.get("needs") in (verify_name, [verify_name]),
            "automatic publication must depend on credential-free verification")
    require(publish.get("environment") == "crates-io-release", "wrong publication environment")
    require(publish.get("permissions") == dict(read_permissions, contents="write", **{"id-token": "write"}),
            "automatic upload needs only provenance reads, upload-intent contents write and OIDC write")
    auth_steps = [(index, step) for index, step in enumerate(publish["steps"])
                  if str(step.get("uses", "")).startswith("rust-lang/crates-io-auth-action@")]
    require(len(auth_steps) == 1, "automatic upload needs one official authentication action")
    auth_index, auth = auth_steps[0]
    critical_step(auth, "official authentication step")
    require(auth.get("id") == "auth" and "if" not in auth
            and "with" not in auth and "env" not in auth and "run" not in auth,
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
            and upload["env"].get("GH_INTENT_TOKEN") == "${{ github.token }}"
            and helper_run(upload, "upload"),
            "upload must execute after auth with only the returned temporary token")
    for name in (verify_name, publish_name):
        confined_step_references(jobs[name], upload_index if name == publish_name else None)
        require(jobs[name].get("env", {}).get("GH_READ_TOKEN") == "${{ github.token }}"
                and "GH_INTENT_TOKEN" not in jobs[name].get("env", {})
                and "GH_INTENT_TOKEN" not in workflow.get("env", {}),
                "read authority must be explicit; upload-intent token must be step scoped")
        for step in jobs[name]["steps"]:
            if step is upload:
                require(set(step.get("env", {})) == {"CARGO_REGISTRY_TOKEN", "GH_INTENT_TOKEN"},
                        "upload step must receive only the temporary registry and intent tokens")
                continue
            require("GH_INTENT_TOKEN" not in step.get("env", {}),
                    "only upload may receive the intent token")
            if "uses" in step:
                require(str(step["uses"]).startswith("actions/checkout@") or step is auth,
                        "automatic jobs may run only immutable checkout and official authentication actions")
            else:
                critical_step(step, f"{name} inert helper")
                require("env" not in step, "verification/confirmation must not override helper environment")
                confirm = dict(step)
                confirm.pop("if", None)
                require(helper_run(step, "verify") or (name == publish_name
                        and helper_run(confirm, "confirm") and step.get("if") in (
                        "${{ !cancelled() }}",
                        "${{ !cancelled() && (steps.upload.outcome == 'success' || steps.upload.outcome == 'failure') }}")),
                        "automatic jobs may execute only the inert verify/upload/confirm helpers")
    for name, job in jobs.items():
        if name in (verify_name, publish_name):
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
        require(permissions.get("attestations", "none") == "none",
                f"unexpected attestation permission on {name}")
    return auth["uses"]


def verify_source_release(source, repository):
    """Qualify the signing boundary; runtime certificate/claim checks belong to the producer."""
    workflow = yaml.load(source, Loader=UniqueLoader)
    require(isinstance(workflow, dict), "source release must be a YAML mapping")
    run_configuration(workflow, "source workflow")
    require(workflow.get("permissions") == {"contents": "read"},
            "source workflow default must be contents read only")
    require(not workflow.get("env", {}), "source workflow must not supply signing environment overrides")
    triggers = workflow.get("on")
    require(isinstance(triggers, dict) and set(triggers) == {"push", "workflow_dispatch"}
            and triggers["push"].get("branches") == ["main", "[0-9]+.[0-9]+.x"],
            "source release must use the reviewed main/maintenance push and dispatch triggers")
    jobs = workflow.get("jobs")
    require(isinstance(jobs, dict) and jobs, "missing source release jobs")
    signers = []
    for name, job in jobs.items():
        require(isinstance(job, dict), "invalid source release job")
        job_execution_shape(job, f"source {name}")
        permissions = job.get("permissions", workflow["permissions"])
        require(isinstance(permissions, dict), "invalid source permissions")
        if permissions.get("id-token", "none") != "none" or permissions.get("attestations", "none") != "none":
            require(permissions == {"contents": "read", "id-token": "write", "attestations": "write"},
                    "only the isolated signer may request OIDC and attestation writes")
            signers.append(name)
    require(len(signers) == 1, "source release needs exactly one isolated signer")
    signer_name = signers[0]
    signer = jobs[signer_name]
    run_configuration(signer, "source signer")
    require(signer.get("continue-on-error", "false") == "false", "signer must fail on errors")
    require(not signer.get("env", {}), "signer must not override inert execution environment")
    require(signer.get("runs-on") == "ubuntu-24.04" and "container" not in signer and "services" not in signer,
            "signer must use the reviewed hosted runner without execution overrides")
    package_name = signer.get("needs")
    expected_package = "source-package" if repository == "atrinik/renderer" else "package"
    require(package_name == expected_package and package_name in jobs,
            "signer must depend on one credential-free package job")
    package = jobs[package_name]
    require(package.get("permissions", workflow["permissions"]) == {"contents": "read"},
            "source package preparation must be credential-free")
    require(package.get("continue-on-error", "false") == "false", "package preparation must fail on errors")
    guard = (f"needs.{package_name}.outputs.release == 'true'" if repository == "atrinik/renderer"
             else f"needs.{package_name}.outputs.version != ''")
    require(expression(signer.get("if")) == guard, "signer must use the package version readiness guard")
    release = jobs.get("release", {})
    require(set(release.get("needs", [])) == {package_name, signer_name}
            and expression(release.get("if")) == guard
            and release.get("continue-on-error", "false") == "false",
            "source publication must depend on successful package preparation and signing")
    steps = signer.get("steps")
    require(isinstance(steps, list) and len(steps) == 4,
            "signer must contain only checkout, payload download, inert finalization and official attestation")
    checkout, download, finalize, attest = steps
    for step in steps:
        require(isinstance(step, dict) and "if" not in step, "signing steps must be unconditional")
        critical_step(step, "source signing step")
    revision = "${{ needs." + package_name + ".outputs.revision }}"
    version = "${{ needs." + package_name + ".outputs.version }}"
    artifact = ("prepared-renderer-release-${{ github.sha }}" if repository == "atrinik/renderer"
                else "source-release-${{ github.sha }}")
    require(re.fullmatch(r"actions/checkout@[0-9a-f]{40}", str(checkout.get("uses"))) is not None
            and checkout.get("with") == {"ref": revision, "persist-credentials": "false"},
            "signer checkout must use the exact prepared revision without persisted credentials")
    require(re.fullmatch(r"actions/download-artifact@[0-9a-f]{40}", str(download.get("uses"))) is not None
            and download.get("with") == {"name": artifact, "path": "build/release/"},
            "signer must download only its same-run prepared payload")
    require(finalize.get("env") == {"ATRINIK_RELEASE_BRANCH": "${{ github.ref_name }}",
            "EXPECTED_SOURCE_REVISION": revision, "EXPECTED_SOURCE_VERSION": version}
            and shlex.split(finalize.get("run", "")) == ["python3", "tools/crate_release.py", "finalize",
            "--source-tag", "v${EXPECTED_SOURCE_VERSION}", "--archives", "build/release"],
            "signer may run only the inert payload finalizer with exact prepared inputs")
    require(re.fullmatch(r"actions/attest-build-provenance@[0-9a-f]{40}", str(attest.get("uses"))) is not None
            and attest.get("with") == {"subject-path": "build/release/crate-release.json", "push-to-registry": "false"},
            "signer must attest the exact manifest through the immutable official action")
    for step in (checkout, download, attest):
        require("run" not in step and "env" not in step,
                "source signing action must not execute extra commands or receive credential overrides")
    return attest["uses"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--repository-id", required=True)
    parser.add_argument("--source-workflow-file", required=True)
    args = parser.parse_args()
    try:
        action = verify(sys.stdin.read(), args.repository, args.repository_id)
        signer_action = verify_source_release(Path(args.source_workflow_file).read_text(), args.repository)
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError) as error:
        sys.exit(f"error: crate publication executable workflow drift: {error}")
    print(f"Executable automatic publication and inert source signing contracts verified; immutable actions {action}, {signer_action}")


if __name__ == "__main__":
    main()
