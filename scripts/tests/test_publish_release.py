from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "publish-release.sh"
BACKFILL_PATH = REPO_ROOT / "scripts" / "backfill-release.sh"
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
BACKFILL_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "cdn-backfill.yml"
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
COMMIT = "c0ffee" + "0" * 34
DEV_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "dev-release.yml"
R2_ENV = {
    "R2_ACCESS_KEY_ID": "r2-access-key",
    "R2_SECRET_ACCESS_KEY": "r2-secret-material",
    "R2_ENDPOINT": "https://" + "0123456789abcdef" * 2 + ".r2.cloudflarestorage.com",
    "R2_BUCKET": "pf-releases",
}

# Each fake appends one tab-separated line per call: the tool, then its
# arguments. rclone also records the uploaded content of latest.txt and
# dev.json, prints PF_PUBLISH_TEST_DEV_LISTING for lsf, and prints
# PF_PUBLISH_TEST_DEV_JSON for cat, failing when it is unset; git prints
# PF_PUBLISH_TEST_MAIN_SHA as the head of main.
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
    if args[0] == "copyto" and args[2].endswith(("/latest.txt", "/dev.json")):
        line += "\tcontent=" + pathlib.Path(args[1]).read_text().replace("\n", "\\n")
with open(os.environ["PF_PUBLISH_TEST_LOG"], "a") as log:
    log.write(line + "\n")
fail = os.environ.get("PF_PUBLISH_TEST_FAIL_" + name.upper(), "")
if fail == "all" or (fail and any(arg.endswith("/" + fail) for arg in args)):
    raise SystemExit(1)
if name == "rclone" and args[0] == "lsf":
    sys.stdout.write(os.environ.get("PF_PUBLISH_TEST_DEV_LISTING", ""))
elif name == "rclone" and args[0] == "cat":
    if "PF_PUBLISH_TEST_DEV_JSON" not in os.environ:
        raise SystemExit("object not found")
    print(os.environ["PF_PUBLISH_TEST_DEV_JSON"])
elif name == "git":
    print(os.environ["PF_PUBLISH_TEST_MAIN_SHA"] + "\trefs/heads/main")
'''


class PublishReleaseScriptTests(unittest.TestCase):
    def run_script(
        self,
        root: pathlib.Path,
        *,
        dry_run: bool = False,
        dev: bool = False,
        env_overrides: dict[str, str | None] | None = None,
        missing_file: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], pathlib.Path]:
        tools = root / "tools"
        tools.mkdir()
        for name in ("rclone", "gh", "git"):
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
                "PF_PUBLISH_GIT_BIN": str(tools / "git"),
                "PF_PUBLISH_TEST_LOG": str(log),
                "PF_PUBLISH_TEST_MAIN_SHA": COMMIT,
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
        if dev:
            command += ["--dev"] + (["--dry-run"] if dry_run else [])
            command += [VERSION, COMMIT, str(artifacts)]
        elif dry_run:
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


def dev_listing(builds: list[str]) -> str:
    """An `rclone lsf --format tp` listing of agent/dev/, oldest build first,
    with two files per build and entries that are not dev builds."""
    lines = ["2026-09-01 00:00:00;README.txt", "2026-09-01 00:00:00;scratch/probe.txt"]
    for index, build in enumerate(builds):
        minute = f"{index // 60:02d}:{index % 60:02d}"
        lines.append(f"2026-10-01 10:{minute};{build}/pf-linux-x86_64.tar.gz")
        lines.append(f"2026-10-01 11:{minute};{build}/pf-windows-x86_64.zip.minisig")
    return "\n".join(lines) + "\n"


class DevPublishTests(unittest.TestCase):
    run_script = PublishReleaseScriptTests.run_script
    older = [f"{index:040x}" for index in range(1, 32)]

    def publish(
        self, tmp: str, env: dict[str, str | None] | None = None
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], pathlib.Path]:
        overrides: dict[str, str | None] = {
            "PF_PUBLISH_TEST_DEV_LISTING": dev_listing(self.older + [COMMIT]),
        }
        overrides.update(env or {})
        return self.run_script(pathlib.Path(tmp), dev=True, env_overrides=overrides)

    def test_uploads_the_build_then_dev_json_then_removes_builds_beyond_30(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
            result, calls, _ = self.publish(tmp)

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertNotIn("gh", [call[0] for call in calls])
            copies = [call for call in calls if call[:2] == ["rclone", "copyto"]]
            self.assertEqual(
                [f"r2:pf-releases/agent/dev/{COMMIT}/{name}" for name in FILES]
                + ["r2:pf-releases/agent/dev.json"],
                [call[3] for call in copies],
            )
            for call in copies[:-1]:
                self.assertEqual(["--header-upload", IMMUTABLE], call[4:6])
            manifest = copies[-1]
            self.assertEqual(
                ["--header-upload", "Cache-Control: no-cache",
                 "--header-upload", "Content-Type: application/json"],
                manifest[4:8],
            )
            self.assertEqual(
                'content={"version":"0.1.0","commit":"' + COMMIT + '"}\\n', manifest[8]
            )
            kinds = [call[0] if call[0] == "git" else call[1] for call in calls]
            self.assertEqual(
                ["copyto"] * len(FILES) + ["git", "copyto", "lsf", "purge", "purge"], kinds
            )
            self.assertEqual(["ls-remote", "origin", "refs/heads/main"], calls[len(FILES)][1:])
            self.assertEqual(
                sorted(f"r2:pf-releases/agent/dev/{build}" for build in self.older[:2]),
                sorted(call[2] for call in calls if call[1:2] == ["purge"]),
            )
            self.assertIn(f"Published dev build {COMMIT}", result.stdout)
            self.assertEqual([], list(pathlib.Path(tmp).glob("pf-publish.*")))

    def test_main_advanced_keeps_dev_json_and_the_build_it_names(self) -> None:
        named = self.older[0]
        with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
            result, calls, summary = self.publish(tmp, {
                "PF_PUBLISH_TEST_MAIN_SHA": "f" * 40,
                "PF_PUBLISH_TEST_DEV_JSON": '{"version":"0.1.0","commit":"' + named + '"}',
            })

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            targets = [call[3] for call in calls if call[1:2] == ["copyto"]]
            self.assertFalse(any(t.endswith("/dev.json") for t in targets))
            self.assertIn("main advanced to " + "f" * 40 + "; dev.json unchanged.",
                          summary.read_text())
            self.assertEqual(
                [f"r2:pf-releases/agent/dev/{self.older[1]}"],
                [call[2] for call in calls if call[1:2] == ["purge"]],
            )

    def test_unreadable_dev_json_removes_no_build(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
            result, calls, summary = self.publish(
                tmp, {"PF_PUBLISH_TEST_MAIN_SHA": "f" * 40}
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("Retention skipped", summary.read_text())
            self.assertFalse(any(call[1:2] in (["purge"], ["lsf"]) for call in calls))

    def test_failed_upload_leaves_dev_json_and_old_builds_untouched(self) -> None:
        failing = "pf-linux-aarch64.tar.gz.sha256"
        with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
            result, calls, summary = self.publish(
                tmp, {"PF_PUBLISH_TEST_FAIL_RCLONE": failing}
            )

            self.assertNotEqual(0, result.returncode)
            message = f"Upload failed: {failing}; dev.json unchanged."
            self.assertIn(message, summary.read_text())
            self.assertTrue(calls[-1][3].endswith("/" + failing))
            self.assertNotIn("git", [call[0] for call in calls])

    def test_unreadable_main_or_failed_removal_fails(self) -> None:
        for env, message in (
            ({"PF_PUBLISH_TEST_FAIL_GIT": "all"}, "Cannot read main from origin; dev.json unchanged."),
            ({"PF_PUBLISH_TEST_FAIL_RCLONE": self.older[0]},
             f"Retention failed: could not remove dev build {self.older[0]}."),
        ):
            with self.subTest(message=message):
                with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
                    result, _, _ = self.publish(tmp, env)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(message, result.stderr)

    def test_dry_run_logs_dev_destinations_and_writes_nothing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-publish-dev-") as tmp:
            result, calls, _ = self.run_script(
                pathlib.Path(tmp), dev=True, dry_run=True,
                env_overrides={name: None for name in R2_ENV},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual([], calls)
            lines = result.stdout.splitlines()
            self.assertTrue(all(line.startswith("dry run: ") for line in lines))
            for name in FILES:
                self.assertTrue(any(
                    f"{name} -> r2:<R2_BUCKET>/agent/dev/{COMMIT}/{name} (" in line
                    and IMMUTABLE in line for line in lines
                ), name)
            self.assertIn(
                "dry run: dev.json -> r2:<R2_BUCKET>/agent/dev.json (Content-Type: "
                f"application/json; Cache-Control: no-cache) if main still points at {COMMIT}",
                lines,
            )
            self.assertTrue(lines[-2].startswith("dry run: retention keeps the newest 30"))

    def test_rejects_short_or_missing_commits(self) -> None:
        for args in (
            ["--dev", "--dry-run", VERSION, COMMIT[:12], "release"],
            ["--dev", "--dry-run", VERSION, "release"],
        ):
            with self.subTest(args=args):
                result = subprocess.run(
                    [str(SCRIPT_PATH), *args],
                    cwd=REPO_ROOT, capture_output=True, text=True, check=False,
                )
                self.assertNotEqual(0, result.returncode)
                self.assertTrue(
                    "full commit SHA" in result.stderr or "usage:" in result.stderr,
                    result.stderr,
                )


class DevReleaseWorkflowTests(unittest.TestCase):
    workflow = DEV_WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_dispatch_only_and_dry_run_by_default(self) -> None:
        triggers = self.workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(
            ["workflow_dispatch:"],
            [line.strip() for line in triggers.splitlines()
             if line.startswith("  ") and not line.startswith("   ")
             and not line.strip().startswith("#")],
        )
        self.assertIn("returns only through the go-live checklist", " ".join(
            line.strip(" #") for line in triggers.splitlines() if line.strip().startswith("#")
        ))
        dry_run = triggers.split("      dry_run:\n", 1)[1]
        self.assertIn("type: boolean", dry_run)
        self.assertIn("default: true", dry_run)

    def test_builds_all_five_platforms_on_the_dev_channel(self) -> None:
        build = job(self.workflow, "build")
        for target in ("x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos"):
            self.assertIn(f"target: {target}", build)
        self.assertIn("-Dupdate-channel=dev", build)
        self.assertIn(
            "-Dtarget=x86_64-windows-gnu -Dupdate-channel=dev",
            job(self.workflow, "build-windows"),
        )

    def test_signs_with_the_commit_and_dry_runs_before_any_upload(self) -> None:
        sign = job(self.workflow, "sign")
        self.assertIn("environment: release", sign)
        self.assertIn("needs: [metadata, build, build-windows]", sign)
        self.assertIn(
            'scripts/sign-release-archives.sh --commit "$SHA" "$VERSION" dev '
            "release/pf-*.tar.gz release/pf-*.zip",
            sign,
        )
        self.assertIn(
            'scripts/publish-release.sh --dev --dry-run "$VERSION" "$SHA" release', sign
        )
        self.assertIn("if: needs.metadata.outputs.dry_run == 'true'", sign)
        publish = job(self.workflow, "publish")
        self.assertIn("if: needs.metadata.outputs.dry_run != 'true'", publish)
        self.assertIn("environment: release", publish)
        self.assertIn('scripts/publish-release.sh --dev "$VERSION" "$SHA" release', publish)
        self.assertIn(
            "DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}",
            job(self.workflow, "metadata"),
        )

    def test_secrets_stay_in_their_environment_jobs(self) -> None:
        for secret, owner in (
            ("PF_MINISIGN_SECRET_KEY", "sign"),
            ("R2_ACCESS_KEY_ID", "publish"),
            ("R2_SECRET_ACCESS_KEY", "publish"),
            ("R2_ENDPOINT", "publish"),
            ("R2_BUCKET", "publish"),
        ):
            with self.subTest(secret=secret):
                reference = f"${{{{ secrets.{secret} }}}}"
                self.assertEqual(1, self.workflow.count(reference))
                self.assertIn(reference, job(self.workflow, owner))
        self.assertEqual(5, self.workflow.count("secrets."))

    def test_dev_builds_are_neither_apple_nor_azure_signed_and_ship_no_web_package(self) -> None:
        for reference in (
            "sign-and-notarize-macos", "sign-windows.ps1", "apple-signing",
            "windows-signing", "AZURE_", "APPLE_", "PF_WEB_DEPLOY_HOOK_URL",
            "wasm-surface", "pf-sdk.js", "blob.vercel-storage.com",
            "BLOB_READ_WRITE_TOKEN",
        ):
            with self.subTest(reference=reference):
                self.assertNotIn(reference, self.workflow)


ACTIVE_KEY = "RW" + "A" * 54
NEXT_KEY = "RW" + "B" * 54

# A fake gh for the backfill: it lists the tags in PF_BACKFILL_TEST_RELEASES
# and downloads a release by copying <PF_BACKFILL_TEST_ASSETS>/<tag>/.
FAKE_BACKFILL_GH = r"""#!/usr/bin/env python3
import os
import pathlib
import shutil
import sys

args = sys.argv[1:]
with open(os.environ["PF_PUBLISH_TEST_LOG"], "a") as log:
    log.write("\t".join(["gh"] + args) + "\n")
if os.environ.get("PF_BACKFILL_TEST_FAIL_LIST") and args[:2] == ["release", "list"]:
    raise SystemExit(1)
if args[:2] == ["release", "list"]:
    for tag in os.environ["PF_BACKFILL_TEST_RELEASES"].split():
        print(tag)
elif args[:2] == ["release", "download"]:
    source = pathlib.Path(os.environ["PF_BACKFILL_TEST_ASSETS"]) / args[2]
    target = pathlib.Path(args[args.index("--dir") + 1])
    if not source.is_dir():
        raise SystemExit("release not found")
    for item in source.iterdir():
        shutil.copy(item, target / item.name)
else:
    raise SystemExit("unexpected gh call")
"""

# A fake minisign that accepts a signature only for the key named in its
# untrusted comment, and prints its trusted comment like minisign -V.
FAKE_BACKFILL_MINISIGN = r"""#!/usr/bin/env python3
import os
import pathlib
import sys

args = sys.argv[1:]
with open(os.environ["PF_PUBLISH_TEST_LOG"], "a") as log:
    log.write("\t".join(["minisign"] + args) + "\n")
def value(flag):
    return args[args.index(flag) + 1]
lines = pathlib.Path(value("-x")).read_text().splitlines()
if args[0] != "-V" or lines[0] != "untrusted comment: key " + value("-P"):
    raise SystemExit("Signature verification failed")
print("Signature and comment signature verified")
print("Trusted comment: " + lines[2].removeprefix("trusted comment: "))
"""


class BackfillScriptTests(unittest.TestCase):
    def run_backfill(
        self,
        root: pathlib.Path,
        releases: tuple[str, ...],
        *args: str,
        keys: tuple[str, str] = (ACTIVE_KEY, ""),
        signer: dict[tuple[str, str], str] | None = None,
        comment: dict[tuple[str, str], str] | None = None,
        env_overrides: dict[str, str | None] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], pathlib.Path]:
        tools = root / "tools"
        tools.mkdir()
        for name, source in (
            ("gh", FAKE_BACKFILL_GH),
            ("minisign", FAKE_BACKFILL_MINISIGN),
            ("rclone", FAKE_TOOL),
        ):
            (tools / name).write_text(source, encoding="utf-8")
            (tools / name).chmod(0o755)
        assets = root / "assets"
        for version in releases:
            release = assets / version
            release.mkdir(parents=True)
            for name in ARCHIVES:
                (release / name).write_text(f"{version} {name}\n")
                (release / f"{name}.sha256").write_text(f"hash  {name}\n")
                key = (signer or {}).get((version, name), ACTIVE_KEY)
                trusted = (comment or {}).get(
                    (version, name), f"file:{name} version:{version} channel:stable"
                )
                (release / f"{name}.minisig").write_text(
                    f"untrusted comment: key {key}\nsignature\n"
                    f"trusted comment: {trusted}\nglobal\n"
                )
        keys_file = root / "release_keys.zig"
        keys_file.write_text(
            f'pub const active = "{keys[0]}";\npub const next = "{keys[1]}";\n'
        )
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
                "PF_MINISIGN_BIN": str(tools / "minisign"),
                "PF_RELEASE_KEYS_FILE": str(keys_file),
                "PF_PUBLISH_TEST_LOG": str(log),
                "PF_BACKFILL_TEST_RELEASES": " ".join(releases),
                "PF_BACKFILL_TEST_ASSETS": str(assets),
                "GITHUB_STEP_SUMMARY": str(summary),
                "RUNNER_TEMP": str(root),
            }
        )
        for key, value in (env_overrides or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        result = subprocess.run(
            [str(BACKFILL_PATH), *args], cwd=root, env=env,
            capture_output=True, text=True, check=False,
        )
        calls = (
            [line.split("\t") for line in log.read_text().splitlines()]
            if log.exists()
            else []
        )
        return result, calls, summary

    @staticmethod
    def uploads(calls: list[list[str]]) -> list[str]:
        return [call[3] for call in calls if call[0] == "rclone"]

    def test_verifies_each_signature_then_uploads_like_a_release(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.2.0", "v0.1.0"), "all"
            )

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(
                ["list", "download", "download"],
                [call[2] for call in calls if call[0] == "gh"],
            )
            for version in ("v0.1.0", "v0.2.0"):
                expected = [f"r2:pf-releases/agent/{version}/{name}" for name in FILES]
                self.assertEqual(
                    expected,
                    [t for t in self.uploads(calls) if f"/{version}/" in t],
                )
            self.assertFalse(any(t.endswith("latest.txt") for t in self.uploads(calls)))
            for call in calls:
                if call[0] == "rclone":
                    name = pathlib.Path(call[3]).name
                    content_type = (
                        "application/gzip" if name.endswith(".tar.gz")
                        else "application/zip" if name.endswith(".zip")
                        else "text/plain"
                    )
                    self.assertEqual(
                        ["--header-upload", IMMUTABLE,
                         "--header-upload", f"Content-Type: {content_type}"],
                        call[4:],
                    )
            # Every archive of a release is verified before its first upload,
            # and older releases go first.
            kinds = [
                (call[0], call[3] if call[0] == "rclone" else call[-1])
                for call in calls if call[0] in ("minisign", "rclone")
            ]
            first_upload = kinds.index(next(k for k in kinds if k[0] == "rclone"))
            self.assertEqual(
                [f"v0.1.0/{name}.minisig" for name in ARCHIVES],
                ["/".join(pathlib.Path(k[1]).parts[-2:]) for k in kinds[:first_upload]],
            )
            self.assertIn("/v0.1.0/", kinds[first_upload][1])
            self.assertIn("Backfilled 2 release(s).", result.stdout)

    def test_latest_moves_only_to_the_newest_verified_release(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0", "v0.2.0"), "--update-latest", "all"
            )
            self.assertEqual(0, result.returncode, result.stderr)
            latest = [c for c in calls if c[0] == "rclone"][-1]
            self.assertEqual("r2:pf-releases/agent/latest.txt", latest[3])
            self.assertEqual("content=v0.2.0", latest[-1])
            self.assertEqual(1, sum(t.endswith("latest.txt") for t in self.uploads(calls)))

        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, summary = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0", "v0.2.0"), "--update-latest", "v0.1.0"
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(len(FILES), len(self.uploads(calls)))
            self.assertFalse(any(t.endswith("latest.txt") for t in self.uploads(calls)))
            self.assertIn(
                "latest.txt unchanged: v0.2.0 is the newest release and was not backfilled.",
                summary.read_text(),
            )

        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0", "v0.2.0"), "--update-latest", "all",
                signer={("v0.2.0", "pf-linux-aarch64.tar.gz"): NEXT_KEY},
            )
            self.assertNotEqual(0, result.returncode)
            self.assertFalse(any(t.endswith("latest.txt") for t in self.uploads(calls)))
            self.assertFalse(any("/v0.2.0/" in t for t in self.uploads(calls)))

    def test_refused_signature_skips_the_release_and_fails_at_the_end(self) -> None:
        for override, problem in (
            ({"signer": {("v0.1.0", "pf-macos-x86_64.tar.gz"): NEXT_KEY}},
             "pf-macos-x86_64.tar.gz.minisig does not verify against release_keys.zig"),
            ({"comment": {("v0.1.0", "pf-windows-x86_64.zip"):
                          "file:pf-windows-x86_64.zip version:v0.2.0 channel:stable"}},
             "pf-windows-x86_64.zip.minisig belongs to a different release"),
            ({"comment": {("v0.1.0", "pf-linux-x86_64.tar.gz"):
                          "file:pf-linux-x86_64.tar.gz version:v0.1.0 channel:stable2"}},
             "pf-linux-x86_64.tar.gz.minisig belongs to a different release"),
        ):
            with self.subTest(problem=problem):
                with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
                    result, calls, summary = self.run_backfill(
                        pathlib.Path(tmp), ("v0.1.0", "v0.2.0"), "all", **override
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(f"Skipped v0.1.0: {problem}.", summary.read_text())
                    self.assertIn("Backfill failed for v0.1.0", result.stderr)
                    self.assertFalse(any("/v0.1.0/" in t for t in self.uploads(calls)))
                    self.assertEqual(
                        len(FILES),
                        sum("/v0.2.0/" in t for t in self.uploads(calls)),
                    )

    def test_next_key_slot_verifies_after_a_rotation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0",), "all", keys=(NEXT_KEY, ACTIVE_KEY)
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(len(FILES), len(self.uploads(calls)))

    def test_failed_upload_skips_the_release_and_leaves_latest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, summary = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0",), "--update-latest", "all",
                env_overrides={"PF_PUBLISH_TEST_FAIL_RCLONE": "pf-linux-x86_64.tar.gz"},
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Skipped v0.1.0: its upload failed.", summary.read_text())
            self.assertFalse(any(t.endswith("latest.txt") for t in self.uploads(calls)))

    def test_dry_run_verifies_and_lists_uploads_without_writing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0",), "--dry-run", "--update-latest", "all",
                env_overrides={name: None for name in R2_ENV},
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual([], self.uploads(calls))
            self.assertEqual(len(ARCHIVES), sum(c[0] == "minisign" for c in calls))
            self.assertNotIn("release create", " ".join(" ".join(c) for c in calls))
            for name in FILES:
                self.assertIn(
                    f"dry run: {name} -> r2:<R2_BUCKET>/agent/v0.1.0/{name}",
                    result.stdout,
                )
            self.assertIn("dry run: latest.txt -> r2:<R2_BUCKET>/agent/latest.txt", result.stdout)
            self.assertNotIn("GitHub Release", result.stdout)

    def test_no_release_means_nothing_to_backfill(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, summary = self.run_backfill(pathlib.Path(tmp), (), "all")

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("No GitHub Release exists; nothing to backfill.", summary.read_text())
            self.assertEqual([["gh", "release", "list"]], [c[:3] for c in calls])

    def test_listing_failure_and_unknown_version_fail_without_writing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(
                pathlib.Path(tmp), ("v0.1.0",), "all",
                env_overrides={"PF_BACKFILL_TEST_FAIL_LIST": "1"},
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("Could not list GitHub Releases.", result.stderr)
            self.assertEqual([], self.uploads(calls))
        with tempfile.TemporaryDirectory(prefix="pf-backfill-") as tmp:
            result, calls, _ = self.run_backfill(pathlib.Path(tmp), ("v0.1.0",), "v0.3.0")
            self.assertNotEqual(0, result.returncode)
            self.assertIn("No GitHub Release v0.3.0 exists", result.stderr)
            self.assertEqual([], self.uploads(calls))
        for version in ("0.1.0", "v0.1", "latest"):
            with self.subTest(version=version):
                result = subprocess.run(
                    [str(BACKFILL_PATH), "--dry-run", version],
                    cwd=REPO_ROOT, capture_output=True, text=True, check=False,
                )
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Version must be vX.Y.Z or all", result.stderr)


class CdnBackfillWorkflowTests(unittest.TestCase):
    workflow = BACKFILL_WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_dispatch_only_and_dry_run_by_default(self) -> None:
        triggers = self.workflow.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(
            ["workflow_dispatch:"],
            [line.strip() for line in triggers.splitlines()
             if line.startswith("  ") and not line.startswith("   ")],
        )
        dry_run = triggers.split("      dry-run:\n", 1)[1]
        self.assertIn("type: boolean", dry_run)
        self.assertIn("default: true", dry_run)
        update_latest = triggers.split("      update-latest:\n", 1)[1]
        self.assertIn("default: false", update_latest.split("      dry-run:", 1)[0])

    def test_runs_the_backfill_script_in_the_release_environment(self) -> None:
        self.assertIn("environment: release", self.workflow)
        self.assertIn('scripts/backfill-release.sh "${args[@]}" "$VERSION"', self.workflow)
        self.assertIn('if [[ "$DRY_RUN" == true ]]; then args+=(--dry-run); fi', self.workflow)
        self.assertIn(
            'if [[ "$UPDATE_LATEST" == true ]]; then args+=(--update-latest); fi',
            self.workflow,
        )
        self.assertIn("apt-get install -y minisign rclone", self.workflow)

    def test_no_vercel_blob_reference_remains(self) -> None:
        for reference in ("blob.vercel-storage.com", "BLOB_READ_WRITE_TOKEN", "CDN_BASE"):
            self.assertNotIn(reference, self.workflow)


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
