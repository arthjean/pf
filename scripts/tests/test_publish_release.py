from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "publish-release.sh"
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
VERSION = "v0.1.0"
ARCHIVES = (
    "pf-linux-x86_64.tar.gz",
    "pf-linux-aarch64.tar.gz",
    "pf-macos-x86_64.tar.gz",
    "pf-macos-aarch64.tar.gz",
    "pf-windows-x86_64.zip",
)
FILES = tuple(
    name + suffix for name in ARCHIVES for suffix in ("", ".sha256", ".minisig")
)
IMMUTABLE = "Cache-Control: public, max-age=31536000, immutable"
R2_ENV = {
    "R2_ACCESS_KEY_ID": "r2-access-key",
    "R2_SECRET_ACCESS_KEY": "r2-secret-material",
    "R2_ENDPOINT": "https://" + "0123456789abcdef" * 2 + ".r2.cloudflarestorage.com",
    "R2_BUCKET": "pf-releases",
}

# Each fake appends one tab-separated line per call: the tool, then its
# arguments. rclone also records the uploaded content of latest.txt.
# PF_PUBLISH_TEST_FAIL_<TOOL> makes a call fail when an argument ends with
# that file name, or every call when it is "all".
FAKE_TOOL = r'''#!/usr/bin/env python3
import os
import pathlib
import sys

name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
line = "\t".join([name] + args)
if name == "rclone":
    if os.environ.get("RCLONE_CONFIG_R2_NO_CHECK_BUCKET") != "true":
        raise SystemExit("rclone remote is missing no_check_bucket")
    if args[2].endswith("/latest.txt"):
        line += "\tcontent=" + pathlib.Path(args[1]).read_text()
with open(os.environ["PF_PUBLISH_TEST_LOG"], "a") as log:
    log.write(line + "\n")
fail = os.environ.get("PF_PUBLISH_TEST_FAIL_" + name.upper(), "")
if fail == "all" or (fail and any(arg.endswith("/" + fail) for arg in args)):
    raise SystemExit(1)
'''


class PublishReleaseScriptTests(unittest.TestCase):
    def run_script(
        self,
        root: pathlib.Path,
        *,
        dry_run: bool = False,
        env_overrides: dict[str, str | None] | None = None,
        missing_file: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], pathlib.Path]:
        tools = root / "tools"
        tools.mkdir()
        for name in ("rclone", "gh"):
            tool = tools / name
            tool.write_text(FAKE_TOOL, encoding="utf-8")
            tool.chmod(0o755)
        artifacts = root / "release"
        artifacts.mkdir()
        for name in FILES:
            if name != missing_file:
                (artifacts / name).write_text(f"{name} bytes\n", encoding="utf-8")
        notes = root / "notes.md"
        notes.write_text("### New Features\n\n- **First release:** pf\n")
        log = root / "calls.log"
        summary = root / "summary.md"
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("R2_", "RCLONE_"))
        }
        env.update(R2_ENV)
        env.update(
            {
                "PF_PUBLISH_RCLONE_BIN": str(tools / "rclone"),
                "PF_PUBLISH_GH_BIN": str(tools / "gh"),
                "PF_PUBLISH_TEST_LOG": str(log),
                "GITHUB_STEP_SUMMARY": str(summary),
                "RUNNER_TEMP": str(root),
            }
        )
        for key, value in (env_overrides or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        command = [str(SCRIPT_PATH)]
        if dry_run:
            command += ["--dry-run", VERSION, str(artifacts)]
        else:
            command += [VERSION, str(artifacts), str(notes)]
        result = subprocess.run(
            command, cwd=root, env=env, capture_output=True, text=True, check=False
        )
        calls = (
            [line.split("\t") for line in log.read_text().splitlines()]
            if log.exists()
            else []
        )
        return result, calls, summary

    def test_publishes_github_release_then_every_file_then_latest_last(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
            result, calls, _ = self.run_script(pathlib.Path(tmp))

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(1 + len(FILES) + 1, len(calls))
            gh = calls[0]
            self.assertEqual(
                ["gh", "release", "create", VERSION, "--verify-tag", "--title", VERSION],
                gh[:7],
            )
            self.assertEqual(
                sorted(FILES), sorted(pathlib.Path(arg).name for arg in gh[9:])
            )
            uploads = calls[1:-1]
            for call, name in zip(uploads, FILES):
                content_type = (
                    "application/gzip" if name.endswith(".tar.gz")
                    else "application/zip" if name.endswith(".zip")
                    else "text/plain"
                )
                self.assertEqual(
                    [
                        "rclone", "copyto", call[2],
                        f"r2:pf-releases/agent/{VERSION}/{name}",
                        "--header-upload", IMMUTABLE,
                        "--header-upload", f"Content-Type: {content_type}",
                    ],
                    call,
                )
                self.assertEqual(name, pathlib.Path(call[2]).name)
            latest = calls[-1]
            self.assertEqual("r2:pf-releases/agent/latest.txt", latest[3])
            self.assertEqual(
                ["--header-upload", "Cache-Control: no-cache",
                 "--header-upload", "Content-Type: text/plain"],
                latest[4:8],
            )
            self.assertEqual(f"content={VERSION}", latest[8])
            self.assertNotIn("r2-secret-material", result.stdout + result.stderr)
            self.assertEqual(
                [], list(pathlib.Path(tmp).glob("pf-publish.*")),
                "latest.txt staging directory was not removed",
            )

    def test_failed_upload_leaves_latest_untouched_and_names_the_file(self) -> None:
        failing = "pf-macos-x86_64.tar.gz.minisig"
        with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
            result, calls, summary = self.run_script(
                pathlib.Path(tmp),
                env_overrides={"PF_PUBLISH_TEST_FAIL_RCLONE": failing},
            )

            self.assertNotEqual(0, result.returncode)
            message = f"Upload failed: {failing}; latest.txt unchanged."
            self.assertIn(message, result.stderr)
            self.assertIn(message, summary.read_text())
            targets = [call[3] for call in calls if call[0] == "rclone"]
            self.assertTrue(targets[-1].endswith("/" + failing))
            self.assertFalse(any(t.endswith("/latest.txt") for t in targets))

    def test_missing_r2_credentials_fail_before_any_upload(self) -> None:
        for name in R2_ENV:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
                    result, calls, _ = self.run_script(
                        pathlib.Path(tmp), env_overrides={name: None}
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(
                        f"Missing required environment variable: {name}",
                        result.stderr,
                    )
                    self.assertEqual([], calls)

    def test_endpoint_with_a_bucket_path_fails_before_any_upload(self) -> None:
        endpoint = R2_ENV["R2_ENDPOINT"]
        for value in (
            endpoint + "/pf-releases",
            endpoint + "/pf-releases/",
            "http://" + endpoint.removeprefix("https://"),
            "https://example.com",
        ):
            with self.subTest(endpoint=value):
                with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
                    result, calls, _ = self.run_script(
                        pathlib.Path(tmp), env_overrides={"R2_ENDPOINT": value}
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("R2_ENDPOINT must be https://", result.stderr)
                    self.assertEqual([], calls)

    def test_missing_release_file_fails_before_any_upload(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
            result, calls, _ = self.run_script(
                pathlib.Path(tmp), missing_file="pf-windows-x86_64.zip.minisig"
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "Missing release file: pf-windows-x86_64.zip.minisig", result.stderr
            )
            self.assertEqual([], calls)

    def test_failed_github_release_uploads_nothing_to_r2(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
            result, calls, _ = self.run_script(
                pathlib.Path(tmp),
                env_overrides={"PF_PUBLISH_TEST_FAIL_GH": "all"},
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn("nothing was uploaded to R2", result.stderr)
            self.assertEqual(["gh"], [call[0] for call in calls])

    def test_dry_run_logs_every_destination_and_writes_nothing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-") as tmp:
            result, calls, _ = self.run_script(
                pathlib.Path(tmp),
                dry_run=True,
                env_overrides={name: None for name in R2_ENV},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual([], calls)
            lines = result.stdout.splitlines()
            self.assertTrue(all(line.startswith("dry run: ") for line in lines))
            self.assertIn(
                f"dry run: GitHub Release {VERSION} with {len(FILES)} assets", lines
            )
            for name in FILES:
                self.assertTrue(
                    any(
                        f"{name} -> r2:<R2_BUCKET>/agent/{VERSION}/{name}" in line
                        and IMMUTABLE in line
                        for line in lines
                    ),
                    name,
                )
            self.assertIn(
                "dry run: latest.txt -> r2:<R2_BUCKET>/agent/latest.txt "
                "(Content-Type: text/plain; Cache-Control: no-cache)",
                lines,
            )
            self.assertTrue(lines[-2].startswith("dry run: latest.txt"))

    def test_rejects_versions_that_are_not_release_tags(self) -> None:
        for version in ("0.1.0", "v0.1", "v0.1.0-rc1", "v01.0.0", "../v0.1.0"):
            with self.subTest(version=version):
                result = subprocess.run(
                    [str(SCRIPT_PATH), "--dry-run", version, "release"],
                    cwd=REPO_ROOT, capture_output=True, text=True, check=False,
                )
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Release version must look like vX.Y.Z", result.stderr)


def job(workflow: str, name: str) -> str:
    """Return one top-level job block of a workflow."""
    block = workflow.split(f"\n  {name}:\n", 1)[1]
    end = next(
        (
            index
            for index, line in enumerate(block.splitlines(keepends=True))
            if line.startswith("  ") and not line.startswith("   ") and line.strip()
        ),
        None,
    )
    lines = block.splitlines(keepends=True)
    return "".join(lines if end is None else lines[:end])


class ReleaseWorkflowTests(unittest.TestCase):
    workflow = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_runs_only_on_dispatch_and_validates_by_default(self) -> None:
        triggers = self.workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(
            ["workflow_dispatch:"],
            [line.strip() for line in triggers.splitlines()
             if line.startswith("  ") and not line.startswith("   ")
             and not line.strip().startswith("#")],
        )
        validate = triggers.split("validate_only:\n", 1)[1]
        self.assertIn("type: boolean", validate)
        self.assertIn("default: true", validate)

    def test_publication_waits_for_release_approval_outside_validation(self) -> None:
        release = job(self.workflow, "release")
        self.assertIn("environment: release", release)
        self.assertIn("needs: [check-version, sign-release]", release)
        self.assertIn(
            "if: needs.check-version.outputs.publish == 'true' && "
            "!(github.event_name == 'workflow_dispatch' && inputs.validate_only)",
            release,
        )
        self.assertIn(
            'scripts/publish-release.sh "$VERSION" release /tmp/release-notes.md',
            release,
        )
        self.assertLess(release.index("Create git tag"), release.index("publish-release.sh"))

    def test_signing_job_signs_attests_and_dry_runs_before_upload(self) -> None:
        sign = job(self.workflow, "sign-release")
        self.assertIn("environment: release", sign)
        self.assertIn(
            "needs: [check-version, build-linux, build-macos-x86_64, "
            "sign-macos-arm64, build-windows]",
            sign,
        )
        self.assertIn("${{ secrets.PF_MINISIGN_SECRET_KEY }}", sign)
        self.assertIn("id-token: write", sign)
        self.assertIn("attestations: write", sign)
        order = [
            "scripts/sign-release-archives.sh",
            "actions/attest-build-provenance@",
            "scripts/publish-release.sh --dry-run",
            "name: release-signed",
        ]
        positions = [sign.index(marker) for marker in order]
        self.assertEqual(sorted(positions), positions)
        dry_run = sign.split("- name: Dry-run the publication\n", 1)[1].split(
            "\n      - name:", 1
        )[0]
        self.assertIn(
            "if: github.event_name == 'workflow_dispatch' && inputs.validate_only",
            dry_run,
        )

    def test_secrets_stay_in_their_environment_jobs(self) -> None:
        for secret, owner in (
            ("PF_MINISIGN_SECRET_KEY", "sign-release"),
            ("R2_ACCESS_KEY_ID", "release"),
            ("R2_SECRET_ACCESS_KEY", "release"),
            ("R2_ENDPOINT", "release"),
            ("R2_BUCKET", "release"),
            ("AZURE_CLIENT_SECRET", "build-windows"),
        ):
            with self.subTest(secret=secret):
                reference = f"${{{{ secrets.{secret} }}}}"
                self.assertEqual(1, self.workflow.count(reference))
                self.assertIn(reference, job(self.workflow, owner))
        self.assertIn("id-token: write", job(self.workflow, "sign-release"))
        for other in ("check-version", "build-linux", "build-windows", "release"):
            self.assertNotIn("id-token", job(self.workflow, other))
            self.assertNotIn("attestations:", job(self.workflow, other))

    def test_windows_archive_is_built_signed_and_packaged(self) -> None:
        windows = job(self.workflow, "build-windows")
        self.assertIn("runs-on: windows-2025", windows)
        self.assertIn("environment: windows-signing", windows)
        self.assertIn(
            "zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu "
            "-Dupdate-channel=stable",
            windows,
        )
        order = [
            "./scripts/sign-windows.ps1 -InputFile zig-out/bin/pf.exe",
            "pf-windows-x86_64.zip",
            "name: pf-windows-x86_64",
        ]
        positions = [windows.index(marker) for marker in order]
        self.assertEqual(sorted(positions), positions)
        self.assertIn('"$hash  pf-windows-x86_64.zip`n"', windows)

    def test_no_vercel_blob_reference_remains(self) -> None:
        for reference in ("blob.vercel-storage.com", "BLOB_READ_WRITE_TOKEN"):
            self.assertNotIn(reference, self.workflow)

    def test_failed_signing_or_attestation_is_named_in_the_summary(self) -> None:
        sign = job(self.workflow, "sign-release")
        step = sign.split("- name: Name the failed step\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        for minisign, attest, expected in (
            ("failure", "skipped", "Sign and verify archives with minisign"),
            ("success", "failure", "Attest build provenance"),
        ):
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory(prefix="pf-release-summary-") as tmp:
                    summary = pathlib.Path(tmp) / "summary.md"
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script],
                        env=dict(
                            os.environ,
                            GITHUB_STEP_SUMMARY=str(summary),
                            MINISIGN_OUTCOME=minisign,
                            ATTEST_OUTCOME=attest,
                        ),
                        capture_output=True, text=True,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn(f"Failed step: {expected}", summary.read_text())


if __name__ == "__main__":
    unittest.main()
