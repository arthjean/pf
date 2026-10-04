from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "sign-release-archives.sh"
RELEASE_KEYS_PATH = REPO_ROOT / "src" / "core" / "upgrade" / "release_keys.zig"
VERSION = "v0.1.0"
ARCHIVES = ("pf-linux-x86_64.tar.gz", "pf-windows-x86_64.zip")
FAKE_PUBLIC_KEY = "RW" + "A" * 54
FAKE_SECRET_KEY = "untrusted comment: minisign secret key\nfake-secret-material"

# A fake minisign that records where the secret key lives, writes signatures
# whose algorithm is PF_SIGN_TEST_ALGORITHM, and fails on request.
FAKE_MINISIGN = r'''#!/usr/bin/env python3
import base64
import os
import pathlib
import sys

args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1]
with open(os.environ["PF_SIGN_TEST_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if args[0] == "-S":
    key = pathlib.Path(value("-s"))
    pathlib.Path(os.environ["PF_SIGN_TEST_KEY_PATH"]).write_text(str(key))
    if key.read_text() != os.environ["PF_SIGN_TEST_EXPECTED_KEY"] + "\n":
        raise SystemExit("unexpected secret key content")
    if os.environ.get("PF_SIGN_TEST_FAIL") == "sign":
        raise SystemExit(1)
    algorithm = os.environ.get("PF_SIGN_TEST_ALGORITHM", "ED").encode()
    comment = os.environ.get("PF_SIGN_TEST_COMMENT", value("-t"))
    pathlib.Path(value("-x")).write_text(
        "untrusted comment: signature\n"
        + base64.b64encode(algorithm + bytes(72)).decode() + "\n"
        + "trusted comment: " + comment + "\n"
        + base64.b64encode(bytes(64)).decode() + "\n"
    )
elif args[0] == "-V":
    if value("-P") != os.environ["PF_SIGN_TEST_PUBLIC_KEY"]:
        raise SystemExit("wrong public key")
    if os.environ.get("PF_SIGN_TEST_FAIL") == "verify":
        raise SystemExit(1)
    trusted = pathlib.Path(value("-x")).read_text().splitlines()[2]
    print("Signature and comment signature verified")
    print("Trusted comment: " + trusted.removeprefix("trusted comment: "))
'''


class SignReleaseArchivesTests(unittest.TestCase):
    def run_script(
        self,
        root: pathlib.Path,
        *,
        public_key: str = FAKE_PUBLIC_KEY,
        secret_key: str | None = FAKE_SECRET_KEY,
        minisign: pathlib.Path | None = None,
        extra_env: dict[str, str] | None = None,
        args: list[str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path]:
        release = root / "release"
        release.mkdir()
        for name in ARCHIVES:
            (release / name).write_bytes(f"{name} payload".encode())
        keys = root / "release_keys.zig"
        keys.write_text(
            f'pub const active = "{public_key}";\npub const next = "";\n'
        )
        runner_temp = root / "runner-temp"
        runner_temp.mkdir()
        if minisign is None:
            minisign = root / "minisign"
            minisign.write_text(FAKE_MINISIGN, encoding="utf-8")
            minisign.chmod(0o755)
        env = dict(
            os.environ,
            PF_MINISIGN_BIN=str(minisign),
            PF_RELEASE_KEYS_FILE=str(keys),
            RUNNER_TEMP=str(runner_temp),
            PF_SIGN_TEST_LOG=str(root / "calls.log"),
            PF_SIGN_TEST_KEY_PATH=str(root / "key-path"),
            PF_SIGN_TEST_EXPECTED_KEY=secret_key or "",
            PF_SIGN_TEST_PUBLIC_KEY=public_key,
        )
        env.pop("PF_MINISIGN_SECRET_KEY", None)
        if secret_key is not None:
            env["PF_MINISIGN_SECRET_KEY"] = secret_key
        env.update(extra_env or {})
        result = subprocess.run(
            [str(SCRIPT_PATH)]
            + (args if args is not None
               else [VERSION, "stable"] + [str(release / n) for n in ARCHIVES]),
            cwd=root, env=env, capture_output=True, text=True, check=False,
        )
        return result, release, runner_temp

    def test_signs_each_archive_with_its_trusted_comment_and_removes_the_key(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-minisign-") as tmp:
            root = pathlib.Path(tmp)
            result, release, runner_temp = self.run_script(root)

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            for name in ARCHIVES:
                comment = f"file:{name} version:{VERSION} channel:stable"
                self.assertIn(
                    f"trusted comment: {comment}",
                    (release / f"{name}.minisig").read_text(),
                )
                self.assertIn(f"Signed and verified {name} ({comment})", output)
            self.assertNotIn("fake-secret-material", output)
            key_path = pathlib.Path((root / "key-path").read_text())
            self.assertTrue(key_path.is_relative_to(runner_temp))
            self.assertFalse(key_path.exists())
            self.assertEqual([], list(runner_temp.iterdir()))
            calls = (root / "calls.log").read_text().splitlines()
            self.assertEqual(["-S", "-V", "-S", "-V"], [c.split()[0] for c in calls])

    def test_dev_builds_name_their_commit_in_the_trusted_comment(self) -> None:
        commit = "0123456789abcdef" * 2 + "01234567"
        with tempfile.TemporaryDirectory(prefix="pf-minisign-") as tmp:
            root = pathlib.Path(tmp)
            release = root / "release"
            result, _, _ = self.run_script(
                root,
                args=["--commit", commit, VERSION, "dev"]
                + [str(release / n) for n in ARCHIVES],
            )

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            for name in ARCHIVES:
                comment = f"file:{name} version:{VERSION} channel:dev commit:{commit}"
                self.assertIn(
                    f"trusted comment: {comment}",
                    (release / f"{name}.minisig").read_text(),
                )
                self.assertIn(f"Signed and verified {name} ({comment})", result.stdout)

    def test_failures_remove_the_secret_key(self) -> None:
        for extra_env, message in (
            ({"PF_SIGN_TEST_FAIL": "sign"}, "minisign failed to sign"),
            ({"PF_SIGN_TEST_FAIL": "verify"}, "minisign verification failed"),
            ({"PF_SIGN_TEST_ALGORITHM": "Ed"}, "prehashed ED algorithm"),
            (
                {"PF_SIGN_TEST_COMMENT": "file:other version:v9.9.9 channel:stable"},
                "unexpected trusted comment",
            ),
        ):
            with self.subTest(message=message):
                with tempfile.TemporaryDirectory(prefix="pf-minisign-") as tmp:
                    root = pathlib.Path(tmp)
                    result, _, runner_temp = self.run_script(
                        root, extra_env=extra_env
                    )

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(message, result.stderr)
                    self.assertEqual([], list(runner_temp.iterdir()))

    def test_refuses_to_start_without_a_key_or_valid_inputs(self) -> None:
        cases = (
            ({"secret_key": None}, "Missing required environment variable: PF_MINISIGN_SECRET_KEY"),
            ({"public_key": ""}, "has no active minisign public key"),
            ({"args": ["0.1.0", "stable", "x"]}, "Release version must look like vX.Y.Z"),
            ({"args": [VERSION, "beta", "x"]}, "Unsupported release channel: beta"),
            ({"args": [VERSION, "stable", "missing.zip"]}, "Archive not found: missing.zip"),
            ({"args": [VERSION, "dev", "x"]}, "Dev builds need --commit with a full commit SHA"),
            ({"args": ["--commit", "0123456", VERSION, "dev", "x"]},
             "Dev builds need --commit with a full commit SHA: 0123456"),
            ({"args": ["--commit", "a" * 40, VERSION, "stable", "x"]},
             "Stable releases take no --commit"),
        )
        for kwargs, message in cases:
            with self.subTest(message=message):
                with tempfile.TemporaryDirectory(prefix="pf-minisign-") as tmp:
                    root = pathlib.Path(tmp)
                    result, release, runner_temp = self.run_script(root, **kwargs)

                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(message, result.stderr)
                    self.assertFalse((root / "calls.log").exists())
                    self.assertEqual([], list(release.glob("*.minisig")))
                    self.assertEqual([], list(runner_temp.iterdir()))

    @unittest.skipUnless(shutil.which("minisign"), "minisign is not installed")
    def test_real_minisign_produces_verifiable_prehashed_signatures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-minisign-real-") as tmp:
            root = pathlib.Path(tmp)
            subprocess.run(
                ["minisign", "-G", "-W", "-p", str(root / "k.pub"),
                 "-s", str(root / "k.key")],
                check=True, capture_output=True,
            )
            public_key = (root / "k.pub").read_text().splitlines()[1]
            result, release, runner_temp = self.run_script(
                root,
                public_key=public_key,
                secret_key=(root / "k.key").read_text().rstrip("\n"),
                minisign=pathlib.Path(shutil.which("minisign")),
            )

            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            for name in ARCHIVES:
                verified = subprocess.run(
                    ["minisign", "-V", "-p", str(root / "k.pub"),
                     "-m", str(release / name)],
                    capture_output=True, text=True,
                )
                self.assertEqual(0, verified.returncode, verified.stderr)
                self.assertIn(
                    f"Trusted comment: file:{name} version:{VERSION} channel:stable",
                    verified.stdout,
                )
            self.assertEqual([], list(runner_temp.iterdir()))


class ReleaseKeysTests(unittest.TestCase):
    def test_release_keys_declare_an_active_and_a_next_slot(self) -> None:
        lines = RELEASE_KEYS_PATH.read_text(encoding="utf-8").splitlines()
        slots = [line.split(" = ")[0] for line in lines if line.startswith("pub const")]
        self.assertEqual(["pub const active", "pub const next"], slots)


if __name__ == "__main__":
    unittest.main()
