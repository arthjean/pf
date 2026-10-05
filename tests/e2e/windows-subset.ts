/**
 * Runs the end-to-end files that pass on native Windows, one Bun process per
 * file, against `zig-out\bin\pf.exe`. The other files need tmux, POSIX
 * shells, or POSIX fixtures.
 *
 * Usage, from tests/e2e after `zig build` and `zig build conpty-driver`:
 *   bun windows-subset.ts
 *
 * Every file runs with HOME and USERPROFILE pointing at a fresh profile, so
 * a test that does not set its own home never touches the real one.
 *
 * pf discovers workspace skills in every ancestor of a workspace, and test
 * workspaces live under the temporary directory. When an ancestor of TEMP
 * holds a skill root, such as `%USERPROFILE%\.claude\skills`, the subset
 * stops before running: set TEMP and TMP to a directory outside it.
 *
 * pf canonicalizes workspace paths to their long form, so the subset expands
 * an 8.3 short TEMP, such as the RUNNER~1 profile on GitHub runners, and
 * passes the long form to every file.
 */
import { appendFileSync, existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { PF_BIN } from "./e2e-helpers";

export const WINDOWS_E2E_FILES: readonly string[] = [
  // CLI
  "cli.test.ts",
  "auth-refresh.test.ts",
  // ACP
  "acp.test.ts",
  // MCP
  "mcp-http.test.ts",
  "mcp-legacy-remote.test.ts",
  "windows-mcp-oauth.test.ts",
  // Headless agent runs
  "file-tool-permissions.test.ts",
  "session-title.test.ts",
  "web-fetch-permission-progress.test.ts",
  "web-search-permission-progress.test.ts",
  // Interactive terminal through ConPTY
  "windows-tui-smoke.test.ts",
  // Verified self-update and the Windows ctrl+g relaunch through ConPTY
  "upgrade-verification.test.ts",
];

// The workspace skill roots in src/builtins/skills.zig.
const WORKSPACE_SKILL_ROOTS = [
  ".pf/skills",
  "skills",
  ".opencode/skills",
  ".codex/skills",
  ".claude/skills",
  ".agents/skills",
  ".claw/skills",
];

function ancestorSkillRoot(start: string): string | null {
  for (let dir = start; ; dir = dirname(dir)) {
    for (const root of WORKSPACE_SKILL_ROOTS) {
      if (existsSync(join(dir, root))) return join(dir, root);
    }
    if (dirname(dir) === dir) return null;
  }
}

if (import.meta.main) {
  if (!existsSync(PF_BIN)) {
    console.error(`pf binary not found at ${PF_BIN}. Run 'zig build' first.`);
    process.exit(1);
  }
  const temp = realpathSync.native(tmpdir());
  const skillRoot = ancestorSkillRoot(temp);
  if (skillRoot !== null) {
    console.error(
      `pf would load the skill root ${skillRoot}, above the temporary directory ${temp}, in every test workspace. Set TEMP and TMP to a directory outside it.`,
    );
    process.exit(1);
  }
  const failed: string[] = [];
  for (const file of WINDOWS_E2E_FILES) {
    const profile = mkdtempSync(join(temp, "pf-windows-e2e-profile-"));
    try {
      console.log(`\n=== ${file}`);
      const result = Bun.spawnSync(["bun", "test", "--max-concurrency", "1", `./${file}`], {
        cwd: import.meta.dir,
        env: { ...process.env, HOME: profile, USERPROFILE: profile, TEMP: temp, TMP: temp },
        stdout: "inherit",
        stderr: "inherit",
      });
      if (result.exitCode !== 0) failed.push(file);
    } finally {
      rmSync(profile, { recursive: true, force: true });
    }
  }
  if (failed.length > 0) {
    console.error(`\nWindows e2e subset failed: ${failed.join(", ")}`);
    const summary = process.env.GITHUB_STEP_SUMMARY;
    if (summary) {
      appendFileSync(summary, `### Failed step: Run Windows E2E subset\n${failed.map((file) => `- ${file}`).join("\n")}\n`);
    }
    process.exit(1);
  }
  console.log(`\nWindows e2e subset passed: ${WINDOWS_E2E_FILES.length} files`);
}
