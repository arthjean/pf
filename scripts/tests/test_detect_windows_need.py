from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "detect-windows-need.sh"
SUBSET = "tests/e2e/windows-subset.ts"


class DetectWindowsNeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": self.temp.name,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }
        self.git("init", "-q")
        self.write(SUBSET, 'export const WINDOWS_E2E_FILES = [\n  "listed.test.ts",\n];\n')
        self.write("src/plain.zig", "pub fn plain() void {}\n")
        self.write("src/win.zig", "if (builtin.os.tag == .windows) {}\n")
        self.write("README.md", "pf\n")
        self.base = self.commit("base")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, check=True,
            capture_output=True, text=True,
        )
        return result.stdout.strip()

    def write(self, path: str, content: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def detect(
        self, base: str | None = None, head: str = "HEAD", **env: str,
    ) -> tuple[int, dict[str, str], str]:
        output_path = self.root.parent / f"{self.root.name}-output"
        output_path.write_text("", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), base or self.base, head],
            cwd=self.root,
            env={**self.env, "GITHUB_OUTPUT": str(output_path), **env},
            capture_output=True,
            text=True,
        )
        outputs = dict(
            line.split("=", 1)
            for line in output_path.read_text(encoding="utf-8").splitlines()
        )
        output_path.unlink()
        return result.returncode, outputs, result.stdout + result.stderr

    def assert_needed(self, **env: str) -> str:
        code, outputs, text = self.detect(**env)
        self.assertEqual(0, code, text)
        self.assertEqual({"needed": "true"}, outputs, text)
        return text

    def assert_not_needed(self) -> None:
        code, outputs, text = self.detect()
        self.assertEqual(0, code, text)
        self.assertEqual({"needed": "false"}, outputs, text)

    def test_change_without_platform_behavior_skips_windows(self) -> None:
        self.write("README.md", "pf docs\n")
        self.write("src/plain.zig", "pub fn plain() u8 { return 1; }\n")
        self.write("src/linux_target.zig", "const name = .linux_x64;\n")
        self.write("tests/e2e/unlisted.test.ts", "test\n")
        self.commit("head")

        self.assert_not_needed()

    def test_zig_file_with_windows_code_needs_windows(self) -> None:
        self.write("src/win.zig", "if (builtin.os.tag == .windows) { run(); }\n")
        self.commit("head")

        self.assertIn("src/win.zig", self.assert_needed())

    def test_any_os_branch_needs_windows_because_windows_may_take_the_else_path(self) -> None:
        self.write("src/self_exe.zig", "if (comptime builtin.os.tag == .linux) {} else {}\n")
        self.write("src/native.zig", "const posix = native_os != .windows;\n")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/self_exe.zig", text)
        self.assertIn("src/native.zig", text)

    def test_win32_and_conpty_code_needs_windows(self) -> None:
        self.write("src/console.zig", "const handle = win32.GetStdHandle();\n")
        self.write("src/pty.zig", "// Runs the shell in a ConPTY pseudo console.\n")
        self.commit("head")

        text = self.assert_needed()
        self.assertIn("src/console.zig", text)
        self.assertIn("src/pty.zig", text)

    def test_removing_windows_code_needs_windows(self) -> None:
        self.write("src/win.zig", "pub fn now_plain() void {}\n")
        self.commit("head")

        self.assertIn("src/win.zig", self.assert_needed())

    def test_build_and_signing_changes_need_windows(self) -> None:
        for path in ("build.zig", "build.zig.zon", "scripts/sign-windows.ps1"):
            with self.subTest(path=path):
                self.write(path, f"{path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

    def test_windows_check_inputs_need_windows(self) -> None:
        for path in (".github/workflows/windows.yml", "scripts/detect-windows-need.sh"):
            with self.subTest(path=path):
                self.write(path, f"# {path}\n")
                self.commit(path)
                self.assertIn(path, self.assert_needed())
                self.base = self.git("rev-parse", "HEAD")

        self.write(SUBSET, 'export const WINDOWS_E2E_FILES = [\n  "listed.test.ts",\n  "other.test.ts",\n];\n')
        self.commit("subset")
        self.assertIn(SUBSET, self.assert_needed())

    def test_subset_test_needs_windows_and_nested_paths_do_not(self) -> None:
        self.write("tests/e2e/listed.test.ts", "test\n")
        self.commit("listed")
        self.assertIn("listed.test.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/fixtures/listed.test.ts", "fixture\n")
        self.commit("nested")
        self.assert_not_needed()

    def test_shared_e2e_helper_with_platform_branch_needs_windows(self) -> None:
        self.write("tests/e2e/helper.ts", 'const win = process.platform === "win32";\n')
        self.commit("helper")
        self.assertIn("tests/e2e/helper.ts", self.assert_needed())
        self.base = self.git("rev-parse", "HEAD")

        self.write("tests/e2e/plain.ts", "export const value = 1;\n")
        self.commit("plain helper")
        self.assert_not_needed()

    def test_request_forces_the_checks(self) -> None:
        self.assertIn("ci:windows label", self.assert_needed(WINDOWS_REQUESTED="ci:windows label"))

    def test_unreadable_revision_fails_instead_of_skipping(self) -> None:
        code, outputs, text = self.detect(base="does-not-exist")

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("cannot read revision", text)

    def test_missing_subset_fails_instead_of_skipping(self) -> None:
        (self.root / SUBSET).unlink()

        code, outputs, text = self.detect()

        self.assertNotEqual(0, code, text)
        self.assertEqual({}, outputs)
        self.assertIn("is missing", text)


if __name__ == "__main__":
    unittest.main()
