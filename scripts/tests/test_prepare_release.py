from __future__ import annotations

import base64
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PREPARE_PATH = REPO_ROOT / ".github" / "workflows" / "prepare-release.yml"
RELEASE_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
PLACEHOLDER = "<!-- release:placeholder -->"
PREVIOUS_CHANGELOG = (
    "# pf\n\n## 0.0.12\n\n<!-- release:start -->\n### Bug Fixes\n\n"
    "- **Resize:** Keep the composer visible\n<!-- release:end -->\n"
)


def steps(workflow: str) -> list[str]:
    """Return every step block of a workflow, in order, across its jobs."""
    return ["      - " + block for block in workflow.split("\n      - ")[1:]]


def step(workflow: str, name: str) -> str:
    matches = [block for block in steps(workflow) if f"name: {name}\n" in block]
    if len(matches) != 1:
        raise AssertionError(f"expected one step named {name!r}, found {len(matches)}")
    return matches[0]


def script(block: str, substitutions: dict[str, str]) -> str:
    """Return the run script of a step with its expressions and /tmp/ replaced."""
    text = textwrap.dedent(block.split("        run: |\n", 1)[1])
    for old, new in substitutions.items():
        text = text.replace(old, new)
    if "${{" in text:
        raise AssertionError("unsubstituted expression in step script")
    return text


def run_bash(text: str, cwd: pathlib.Path, env: dict[str, str] | None = None):
    return subprocess.run(
        ["bash", "-e", "-c", text],
        cwd=cwd,
        env=dict(os.environ, **(env or {})),
        capture_output=True,
        text=True,
        check=False,
    )


class PrepareReleaseWorkflowTests(unittest.TestCase):
    workflow = PREPARE_PATH.read_text(encoding="utf-8")

    def test_changelog_input_defaults_to_manual_and_offers_ai(self) -> None:
        inputs = self.workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        changelog = inputs.split("      changelog:\n", 1)[1]
        self.assertIn("type: choice", changelog)
        self.assertIn("default: manual", changelog)
        options = changelog.split("options:\n", 1)[1].split()
        self.assertEqual(["-", "manual", "-", "ai"], options)

    def test_ai_gateway_is_reached_only_by_ai_steps(self) -> None:
        for block in steps(self.workflow):
            if "secrets.AI_GATEWAY_API_KEY" in block or "ai-gateway" in block:
                self.assertIn("if: inputs.changelog == 'ai'", block)
        self.assertIn("if: inputs.changelog == 'ai'", step(self.workflow, "Collect changes since last tag"))
        lint = step(self.workflow, "Generate changelog with AI")
        self.assertIn("https://ai-gateway.vercel.sh/v4/ai/language-model", lint)
        self.assertIn("Public changelog policy violation", lint)
        self.assertIn("> /tmp/changelog-body.md", lint)

    def test_missing_ai_key_fails_before_checkout_and_names_the_secret(self) -> None:
        names = [block.split("\n", 1)[0] for block in steps(self.workflow)]
        self.assertEqual("      - name: Require the AI Gateway key", names[0])
        self.assertTrue(any("uses: actions/checkout" in name for name in names[1:2]))
        self.assertEqual("      - name: Create pull request", names[-1])
        guard = step(self.workflow, "Require the AI Gateway key")
        self.assertIn("if: inputs.changelog == 'ai'", guard)
        with tempfile.TemporaryDirectory(prefix="pf-prepare-") as tmp:
            text = script(guard, {})
            missing = run_bash(text, pathlib.Path(tmp), {"AI_GATEWAY_API_KEY": ""})
            self.assertNotEqual(0, missing.returncode)
            self.assertIn("AI_GATEWAY_API_KEY secret is not set", missing.stdout)
            present = run_bash(text, pathlib.Path(tmp), {"AI_GATEWAY_API_KEY": "key"})
            self.assertEqual(0, present.returncode, present.stdout)

    # The workflow runs on ubuntu-latest, and its sed -i calls are GNU syntax.
    @unittest.skipUnless(sys.platform.startswith("linux"), "needs GNU sed")
    def test_manual_changelog_bumps_the_version_and_blocks_publication(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-prepare-") as tmp:
            root = pathlib.Path(tmp)
            work = root / "tmp"
            work.mkdir()
            (root / "src").mkdir()
            (root / "src" / "main.zig").write_text('pub const version = "0.0.12";\n')
            (root / "README.md").write_text("Build pf from source.\n")
            (root / "CHANGELOG.md").write_text(PREVIOUS_CHANGELOG)
            paths = {"/tmp/": f"{work}/"}

            version = script(
                step(self.workflow, "Compute new version"),
                {"${{ inputs.bump }}": "minor"},
            )
            output = root / "output"
            result = run_bash(version, root, {"GITHUB_OUTPUT": str(output)})
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("new=0.1.0", output.read_text())

            for name in ("Write placeholder changelog", "Update version and changelog"):
                block = step(self.workflow, name)
                if name == "Write placeholder changelog":
                    self.assertIn("if: inputs.changelog == 'manual'", block)
                result = run_bash(
                    script(
                        block,
                        {
                            **paths,
                            "${{ steps.version.outputs.new }}": "0.1.0",
                            "${{ steps.version.outputs.current }}": "0.0.12",
                        },
                    ),
                    root,
                )
                self.assertEqual(0, result.returncode, result.stderr)

            self.assertEqual(
                'pub const version = "0.1.0";\n',
                (root / "src" / "main.zig").read_text(),
            )
            changelog = (root / "CHANGELOG.md").read_text()
            self.assertTrue(
                changelog.startswith(
                    "# pf\n\n## 0.1.0\n\n<!-- release:start -->\n"
                    f"{PLACEHOLDER}\n"
                    "Replace this placeholder with the public release notes "
                    "before publishing.\n<!-- release:end -->\n\n## 0.0.12\n"
                ),
                changelog,
            )
            self.assertEqual(1, changelog.count("<!-- release:start -->"))

            extract = step(RELEASE_PATH.read_text(encoding="utf-8"), "Extract changelog entry")
            refused = run_bash(script(extract, paths), root)
            self.assertNotEqual(0, refused.returncode)
            self.assertIn(PLACEHOLDER, refused.stdout)
            self.assertIn("replace it with the release notes", refused.stdout)

            (root / "CHANGELOG.md").write_text(
                changelog.replace(
                    f"{PLACEHOLDER}\nReplace this placeholder with the public "
                    "release notes before publishing.\n",
                    "### New Features\n\n- **Upgrade:** Verify signed releases\n",
                )
            )
            accepted = run_bash(script(extract, paths), root)
            self.assertEqual(0, accepted.returncode, accepted.stdout)
            self.assertIn(
                "- **Upgrade:** Verify signed releases",
                (work / "release-notes.md").read_text(),
            )

    @unittest.skipUnless(sys.platform.startswith("linux"), "needs GNU base64")
    def test_release_commit_payload_carries_the_full_source_files(self) -> None:
        create = script(
            step(self.workflow, "Create pull request"),
            {"${{ inputs.changelog }}": "manual",
             "${{ steps.version.outputs.new }}": "0.1.0"},
        )
        start = create.index("base64 -w 0 src/main.zig")
        end = create.index("> /tmp/create-release-commit.json") + len(
            "> /tmp/create-release-commit.json"
        )
        with tempfile.TemporaryDirectory(prefix="pf-prepare-") as tmp:
            root = pathlib.Path(tmp)
            (root / "src").mkdir()
            for name in ("src/main.zig", "README.md", "CHANGELOG.md"):
                (root / name).write_bytes((REPO_ROOT / name).read_bytes())
            payload = create[start:end].replace("/tmp/", f"{root}/")
            result = run_bash(
                payload,
                root,
                {"GITHUB_REPOSITORY": "o/pf", "BRANCH": "prepare-v0.1.0",
                 "GITHUB_SHA": "0" * 40, "NEW": "0.1.0"},
            )
            self.assertEqual(0, result.returncode, result.stderr)
            request = json.loads((root / "create-release-commit.json").read_text())
            additions = request["variables"]["input"]["fileChanges"]["additions"]
            self.assertEqual(
                (REPO_ROOT / "src" / "main.zig").read_bytes(),
                base64.b64decode(additions[0]["contents"]),
            )

    def test_pull_request_states_that_merging_publishes_nothing(self) -> None:
        create = step(self.workflow, "Create pull request")
        self.assertIn("Merging publishes nothing", create)
        self.assertNotIn("publish the GitHub release automatically", create)


class ReleasePlaceholderTests(unittest.TestCase):
    def test_release_job_checks_the_placeholder_before_tagging(self) -> None:
        workflow = RELEASE_PATH.read_text(encoding="utf-8")
        release = workflow.split("\n  release:\n", 1)[1]
        self.assertLess(
            release.index("- name: Extract changelog entry"),
            release.index("- name: Create git tag"),
        )
        self.assertIn(PLACEHOLDER, release.split("- name: Create git tag", 1)[0])


if __name__ == "__main__":
    unittest.main()
