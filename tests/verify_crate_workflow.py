"""Exercise the credential and executable provenance qualification boundaries."""

import copy
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("crate_workflow", ROOT / "lib/verify_crate_workflow.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class WorkflowBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.publish = workflow.yaml.load((ROOT / "tests/fixtures/crate-publication.yml").read_text(),
                                         Loader=workflow.UniqueLoader)
        self.source = workflow.yaml.load((ROOT / "tests/fixtures/crate-source-release.yml").read_text(),
                                        Loader=workflow.UniqueLoader)

    def publication(self, candidate):
        return workflow.verify(workflow.yaml.dump(candidate), "atrinik/protocol", "1327106950")

    def signing(self, candidate):
        return workflow.verify_source_release(workflow.yaml.dump(candidate), "atrinik/protocol")

    def reject(self, original, checker, mutate):
        candidate = copy.deepcopy(original)
        mutate(candidate)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            checker(candidate)

    def test_reviewed_boundary(self):
        self.publication(self.publish)
        self.signing(self.source)

    def test_safe_full_checkout_and_confirmation_variants(self):
        job = self.publish["jobs"]["automatic-publish"]
        job["steps"][0]["with"]["fetch-depth"] = 0
        confirm = {"if": "${{ !cancelled() }}", "run": job["steps"][-1]["run"].replace(" upload ", " confirm ")}
        job["steps"].append(confirm)
        self.publication(self.publish)

    def test_publisher_least_privilege_and_inert_execution(self):
        mutations = [
            lambda w: w["jobs"]["automatic-verify"]["permissions"].update({"contents": "write"}),
            lambda w: w["jobs"]["automatic-verify"]["permissions"].pop("attestations"),
            lambda w: w["jobs"]["automatic-publish"]["permissions"].update({"checks": "write"}),
            lambda w: w["jobs"]["automatic-publish"]["permissions"].update({"contents": "read"}),
            lambda w: w["jobs"]["automatic-publish"]["env"].update({"GH_INTENT_TOKEN": "${{ github.token }}"}),
            lambda w: w["jobs"]["automatic-publish"]["env"].update({"BASH_ENV": "untrusted.sh"}),
            lambda w: w["jobs"]["automatic-publish"].update({"container": "untrusted"}),
            lambda w: w["jobs"]["automatic-publish"]["steps"][-1]["env"].pop("GH_INTENT_TOKEN"),
            lambda w: w["jobs"]["automatic-publish"]["steps"].append({"run": "cargo build"}),
            lambda w: w["jobs"]["automatic-publish"]["steps"].append({"uses": "owner/build@" + "1" * 40}),
            lambda w: w["jobs"]["automatic-publish"]["steps"][1].update({"env": {"PYTHONPATH": "untrusted"}}),
            lambda w: w["jobs"]["automatic-publish"]["steps"][0]["with"].update({"path": "alternate"}),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.reject(self.publish, self.publication, mutation)

    def test_signer_isolation_and_dependency(self):
        mutations = [
            lambda w: w["jobs"]["package"].update({"permissions": {"contents": "read", "id-token": "write"}}),
            lambda w: w["jobs"]["release"]["permissions"].update({"id-token": "write"}),
            lambda w: w["jobs"]["release"].update({"needs": ["package"]}),
            lambda w: w["jobs"].pop("attest"),
            lambda w: w["jobs"]["attest"].update({"if": "false"}),
            lambda w: w["jobs"]["attest"].update({"continue-on-error": "true"}),
            lambda w: w["jobs"]["attest"].update({"env": {"PYTHONPATH": "untrusted"}}),
            lambda w: w["jobs"]["attest"].update({"container": "untrusted"}),
            lambda w: w["jobs"]["attest"]["steps"].append({"run": "npm install"}),
            lambda w: w["jobs"]["attest"]["steps"][2].update({"run": "cargo build"}),
            lambda w: w["jobs"]["attest"]["steps"][2].update({"shell": "echo {0}"}),
            lambda w: w["jobs"]["attest"]["steps"][2].update({"continue-on-error": "true"}),
            lambda w: w["jobs"]["attest"]["steps"][2].update({"if": "false"}),
            lambda w: w["jobs"]["attest"]["steps"][0]["with"].update({"ref": "main"}),
            lambda w: w["jobs"]["attest"]["steps"][1]["with"].update({"run-id": "123"}),
            lambda w: w["jobs"]["attest"]["steps"][3].update({"uses": "actions/attest-build-provenance@v4"}),
            lambda w: w["jobs"]["attest"]["steps"][3]["with"].update({"subject-path": "build/release/*.crate"}),
            lambda w: w["jobs"]["attest"]["steps"][3]["with"].update({"push-to-registry": "true"}),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.reject(self.source, self.signing, mutation)

    def test_immutable_official_signer_can_receive_dependabot_updates(self):
        self.source["jobs"]["attest"]["steps"][-1]["uses"] = "actions/attest-build-provenance@" + "2" * 40
        self.signing(self.source)


if __name__ == "__main__":
    unittest.main()
