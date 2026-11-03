"""Policy checks for the GitHub Actions workflows."""

import shutil
import subprocess
import unittest
from collections import Counter
from pathlib import Path

import yaml


WORKFLOW_DIR = Path(__file__).resolve().parents[1] / ".github" / "workflows"
JOB_NAMES = {
    "ci.yaml": "check",
    "update-flake-lock.yaml": "lockfile",
}
TOKEN_PRESENCE_EXPRESSION = "${{ secrets.FLAKE_LOCK_TOKEN != '' }}"
TOKEN_INPUT_EXPRESSION = "${{ secrets.FLAKE_LOCK_TOKEN }}"
APPROVED_ACTION_REFS = {
    "actions/checkout": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
    "cachix/install-nix-action": "cachix/install-nix-action@75c75c31ebece974e48ebc36b4ad125bd97bd97b",
    "DeterminateSystems/update-flake-lock": (
        "DeterminateSystems/update-flake-lock@da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3"
    ),
}


def run_github_bash(script, token_presence):
    bash = shutil.which("bash")
    if bash is None:
        raise AssertionError("bash must be available for the CI policy check")

    # Pass only the non-secret boolean that the workflow expression produces.
    environment = {}
    if token_presence is not None:
        environment["FLAKE_LOCK_TOKEN_PRESENT"] = token_presence

    return subprocess.run(
        [bash, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
        check=False,
        capture_output=True,
        env=environment,
        text=True,
    )


class WorkflowPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = {
            filename: yaml.load(
                (WORKFLOW_DIR / filename).read_text(encoding="utf-8"),
                Loader=yaml.BaseLoader,
            )
            for filename in JOB_NAMES
        }

    def test_workflow_and_every_job_have_only_read_permissions(self):
        for filename, expected_job in JOB_NAMES.items():
            with self.subTest(workflow=filename):
                workflow = self.workflows[filename]
                self.assertEqual({}, workflow.get("permissions"))
                self.assertIn(expected_job, workflow["jobs"])
                for job_name, job in workflow["jobs"].items():
                    with self.subTest(workflow=filename, job=job_name):
                        self.assertEqual(
                            {"contents": "read"},
                            job.get("permissions"),
                        )

    def test_checkout_does_not_persist_credentials(self):
        for filename, workflow in self.workflows.items():
            with self.subTest(workflow=filename):
                checkout_steps = [
                    step
                    for job in workflow["jobs"].values()
                    for step in job["steps"]
                    if step.get("uses", "").startswith("actions/checkout@")
                ]
                self.assertTrue(
                    checkout_steps,
                    "workflow must check out the repository",
                )
                for step in checkout_steps:
                    self.assertEqual(
                        "false",
                        step.get("with", {}).get("persist-credentials"),
                    )

    def test_every_action_uses_an_approved_immutable_commit(self):
        refs = [
            step["uses"]
            for workflow in self.workflows.values()
            for job in workflow["jobs"].values()
            for step in job["steps"]
            if "uses" in step
        ]
        expected_counts = Counter(
            {
                APPROVED_ACTION_REFS["actions/checkout"]: 2,
                APPROVED_ACTION_REFS["cachix/install-nix-action"]: 2,
                APPROVED_ACTION_REFS["DeterminateSystems/update-flake-lock"]: 1,
            }
        )
        self.assertEqual(expected_counts, Counter(refs))

        for reference in refs:
            action, separator, revision = reference.rpartition("@")
            with self.subTest(reference=reference):
                self.assertTrue(separator)
                self.assertEqual(APPROVED_ACTION_REFS[action], reference)
                self.assertRegex(revision, r"\A[0-9a-f]{40}\Z")

    def test_updater_disables_otlp_for_the_update_action_only(self):
        occurrences = []
        for filename, workflow in self.workflows.items():
            if "OTEL_SDK_DISABLED" in workflow.get("env", {}):
                occurrences.append(
                    (filename, "workflow", None, workflow["env"]["OTEL_SDK_DISABLED"])
                )
            for job_name, job in workflow["jobs"].items():
                if "OTEL_SDK_DISABLED" in job.get("env", {}):
                    occurrences.append(
                        (filename, job_name, None, job["env"]["OTEL_SDK_DISABLED"])
                    )
                for step in job["steps"]:
                    if "OTEL_SDK_DISABLED" in step.get("env", {}):
                        occurrences.append(
                            (
                                filename,
                                job_name,
                                step.get("uses"),
                                step["env"]["OTEL_SDK_DISABLED"],
                            )
                        )

        self.assertEqual(
            [
                (
                    "update-flake-lock.yaml",
                    JOB_NAMES["update-flake-lock.yaml"],
                    APPROVED_ACTION_REFS["DeterminateSystems/update-flake-lock"],
                    "true",
                )
            ],
            occurrences,
        )

    def test_updater_uses_dedicated_token_only_after_preflight(self):
        updater = self.workflows["update-flake-lock.yaml"]
        expected_job = JOB_NAMES["update-flake-lock.yaml"]
        preflights = [
            (job_name, index, step)
            for job_name, job in updater["jobs"].items()
            for index, step in enumerate(job["steps"])
            if "FLAKE_LOCK_TOKEN_PRESENT" in step.get("env", {})
        ]
        self.assertEqual(1, len(preflights))
        preflight_job, preflight_index, preflight = preflights[0]
        self.assertEqual(expected_job, preflight_job)
        self.assertEqual(
            TOKEN_PRESENCE_EXPRESSION,
            preflight["env"]["FLAKE_LOCK_TOKEN_PRESENT"],
        )
        self.assertNotIn("secrets.FLAKE_LOCK_TOKEN", preflight.get("run", ""))

        consumers = [
            (job_name, index, step)
            for job_name, job in updater["jobs"].items()
            for index, step in enumerate(job["steps"])
            if step.get("with", {}).get("token") == TOKEN_INPUT_EXPRESSION
        ]
        self.assertEqual(1, len(consumers))
        consumer_job, consumer_index, _ = consumers[0]
        self.assertEqual(expected_job, consumer_job)
        self.assertLess(preflight_index, consumer_index)

        self.assertEqual(2, repr(updater).count("secrets.FLAKE_LOCK_TOKEN"))
        self.assertNotIn("github.token", repr(updater).lower())
        for scope in (updater, updater["jobs"][expected_job]):
            env = scope.get("env", {})
            self.assertNotIn("FLAKE_LOCK_TOKEN", env)
            self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn(
            "FLAKE_LOCK_TOKEN",
            repr(self.workflows["ci.yaml"]),
        )

    def test_updater_preflight_rejects_false_and_missing_presence(self):
        updater = self.workflows["update-flake-lock.yaml"]
        job_name = JOB_NAMES["update-flake-lock.yaml"]
        preflights = [
            step
            for step in updater["jobs"][job_name]["steps"]
            if "FLAKE_LOCK_TOKEN_PRESENT" in step.get("env", {})
        ]
        self.assertEqual(1, len(preflights))
        script = preflights[0].get("run", "")

        for presence in ("false", None):
            with self.subTest(presence=presence):
                result = run_github_bash(script, presence)
                output = result.stdout + result.stderr
                self.assertNotEqual(0, result.returncode)
                self.assertIn("::error::", output)
                self.assertIn("FLAKE_LOCK_TOKEN", output)

        result = run_github_bash(script, "true")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
