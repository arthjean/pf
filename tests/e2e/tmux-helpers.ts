/**
 * tmux helper for interactive TUI testing.
 *
 * Creates isolated tmux sessions, sends keystrokes, captures pane
 * output, and provides waitForText polling for assertions.
 *
 * Requires: tmux installed and available in PATH.
 */
import { execFileSync, execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PF_BIN, REPO_ROOT, providerVersionTestEnv } from "../evals/eval-helpers";
import {
  AUTH_ENV_KEYS,
  DEFAULT_UNSET_ENV_KEYS,
  hasEmptyComposer,
  MIRRORED_ENV_KEYS,
} from "./e2e-helpers";

export * from "./e2e-helpers";

let sessionCounter = 0;

const TMUX_CAPTURE_MAX_BUFFER = 32 * 1024 * 1024;
const TMUX_HEX_CHUNK_BYTES = 256;

export function terminalFixtureShell(): string {
  for (const path of ["/bin/zsh", "/bin/bash"]) {
    if (existsSync(path)) return path;
  }
  throw new Error("terminal fixtures require Bash or zsh");
}

const TMUX_RAW_PASTE_FLAGS = (() => {
  try {
    const version = execFileSync("tmux", ["-V"], { encoding: "utf8" })
      .trim()
      .match(/^tmux (\d+)\.(\d+)/);
    if (!version) return [] as const;
    const major = Number(version[1]);
    const minor = Number(version[2]);
    return major > 3 || (major === 3 && minor >= 7) ? (["-S"] as const) : [];
  } catch {
    return [] as const;
  }
})();

export function tmuxRawPasteFlags(): readonly string[] {
  return TMUX_RAW_PASTE_FLAGS;
}

export function paneExitMatches(
  pane: { dead: boolean; status: number | null },
  expectedStatus: number,
): boolean {
  return pane.dead && pane.status === expectedStatus;
}

export function parseSingleChildPid(output: string, parentPid: number): number {
  const lines = output.trim().length === 0 ? [] : output.trim().split(/\s+/);
  if (lines.length !== 1) {
    throw new Error(
      `tmux pane process ${parentPid} has ${lines.length} direct children`,
    );
  }
  const pid = Number.parseInt(lines[0]!, 10);
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    throw new Error(`invalid child PID for tmux pane process ${parentPid}`);
  }
  return pid;
}

export function buildObservedCommand(
  command: string,
  stderrPath: string | undefined,
  exitStatusPath: string,
): string {
  const childCommand = stderrPath
    ? `/bin/sh -c ${shellQuote(`exec ${command} 2>${shellQuote(stderrPath)}`)}`
    : command;
  const observer = `/bin/sh -c ${shellQuote([
    childCommand,
    "status=$?",
    `printf '%s\\n' \"$status\" > ${shellQuote(exitStatusPath)}`,
    'exit "$status"',
  ].join("; "))}`;
  return stderrPath ? `${observer} 2>/dev/null` : observer;
}


// Serves a fake update channel whose "new" artifact is a wrapper script that
// logs its argv to argvLogPath and execs the real PF_BIN, so upgrade relaunch
// tests can drive the handoff without shipping a second binary.
export function startUpgradeServer(
  root: string,
  argvLogPath: string,
  options: {
    revision?: string;
  } = {},
): { baseUrl: string; stop: () => void } {
  const artifactDir = join(root, "release-artifact");
  const wrapperPath = join(artifactDir, "pf");
  const archivePath = join(root, "pf.tar.gz");
  mkdirSync(artifactDir);
  const script = `#!/bin/sh
{
  printf '%s' "$0"
  for arg in "$@"; do
    printf '\\t%s' "$arg"
  done
  printf '\\n'
} >> ${shellQuote(argvLogPath)}
exec ${shellQuote(PF_BIN)} "$@"
`;
  writeFileSync(wrapperPath, script);
  chmodSync(wrapperPath, 0o755);
  const tar = Bun.spawnSync(["tar", "-czf", archivePath, "-C", artifactDir, "pf"]);
  if (tar.exitCode !== 0) throw new Error(tar.stderr.toString());

  const archive = readFileSync(archivePath);
  const checksum = createHash("sha256").update(archive).digest("hex");
  const platform = `${process.platform === "darwin" ? "macos" : "linux"}-${process.arch === "arm64" ? "aarch64" : "x86_64"}`;
  const revision = options.revision ?? "abcdef0123456789abcdef0123456789abcdef01";
  const stableArchiveRoute = `/v9.9.9/pf-${platform}.tar.gz`;
  const devArchiveRoute = `/dev/${revision}/pf-${platform}.tar.gz`;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/latest.txt") return new Response("v9.9.9\n");
      if (path === "/dev.json") {
        return Response.json({ version: "9.9.9", commit: revision });
      }
      if (path === stableArchiveRoute || path === devArchiveRoute) {
        return new Response(archive);
      }
      if (path === `${stableArchiveRoute}.sha256` || path === `${devArchiveRoute}.sha256`) {
        return new Response(`${checksum}\n`);
      }
      return new Response("not found", { status: 404 });
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    stop: () => server.stop(true),
  };
}

export class TmuxSession {
  readonly name: string;
  private readonly socketName?: string;
  private readonly exitStatusPath: string;
  private killed = false;

  private constructor(name: string, exitStatusPath: string, socketName?: string) {
    this.name = name;
    this.exitStatusPath = exitStatusPath;
    this.socketName = socketName;
  }

  static async create(opts?: {
    cmd?: string;
    cwd?: string;
    env?: Record<string, string | undefined>;
    width?: number;
    height?: number;
    stderrPath?: string;
    remainOnExit?: boolean;
    minimumHistoryLines?: number;
    startupWaitMs?: number;
    isolated?: boolean;
    socketName?: string;
  }): Promise<TmuxSession> {
    const {
      cmd = PF_BIN,
      cwd = REPO_ROOT,
      env: requestedEnv = {},
      width = 120,
      height = 40,
      stderrPath,
      remainOnExit = false,
      minimumHistoryLines,
      startupWaitMs = 1000,
      isolated = false,
      socketName,
    } = opts ?? {};
    const env = providerVersionTestEnv(requestedEnv);

    if (
      minimumHistoryLines !== undefined &&
      (!Number.isInteger(minimumHistoryLines) || minimumHistoryLines < 0)
    ) {
      throw new Error(
        `minimumHistoryLines must be a non-negative integer, got ${minimumHistoryLines}`,
      );
    }

    const sequence = ++sessionCounter;
    const name = `pf-test-${process.pid}-${sequence}`;
    const resolvedSocketName = socketName ?? (isolated
      ? `pf-e2e-${process.pid}-${sequence}-${Date.now()}`
      : undefined);
    const startGate = `${name}-start`;
    const exitStatusPath = join(tmpdir(), `${name}.exit-status`);
    rmSync(exitStatusPath, { force: true });

    const authEnvKeys = new Set<string>(AUTH_ENV_KEYS);
    const unsetArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined ? ["-u", shellQuote(key)] : []
    );
    const defaultUnsetArgs = DEFAULT_UNSET_ENV_KEYS.flatMap((key) =>
      Object.prototype.hasOwnProperty.call(env, key) ? [] : ["-u", shellQuote(key)]
    );
    const assignmentArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined || authEnvKeys.has(key) ? [] : [shellQuote(`${key}=${value}`)]
    );
    const sessionEnvArgs = Object.entries(env).flatMap(([key, value]) =>
      value === undefined || !authEnvKeys.has(key) ? [] : ["-e", `${key}=${value}`]
    );
    const mirroredEnv = MIRRORED_ENV_KEYS.flatMap((key) =>
      Object.prototype.hasOwnProperty.call(env, key)
        ? []
        : [[key, process.env[key]] as const]
    );
    const mirroredUnsetArgs = mirroredEnv.flatMap(([key, value]) =>
      value === undefined ? ["-u", shellQuote(key)] : []
    );
    const mirroredAssignmentArgs = mirroredEnv.flatMap(([key, value]) =>
      value === undefined ? [] : [shellQuote(`${key}=${value}`)]
    );
    const defaultArgs = [
      ["PF_DISABLE_KEYCHAIN", "1"],
      ["PF_SKIP_ONBOARDING", "1"],
      ["PF_SOUND", "0"],
    ].flatMap(([key, value]) =>
      Object.prototype.hasOwnProperty.call(env, key) ? [] : [shellQuote(`${key}=${value}`)]
    );
    const envArgs = [
      ...unsetArgs,
      ...mirroredUnsetArgs,
      ...defaultUnsetArgs,
      ...defaultArgs,
      ...mirroredAssignmentArgs,
      ...assignmentArgs,
    ];
    const envStr = envArgs.length > 0 ? `/usr/bin/env ${envArgs.join(" ")}` : "";
    const command = envStr ? `${envStr} ${cmd}` : cmd;
    const observedCmd = buildObservedCommand(
      command,
      stderrPath,
      exitStatusPath,
    );
    const processEnv = {
      ...process.env,
      PF_DISABLE_KEYCHAIN: "1",
      PF_SKIP_ONBOARDING: "1",
      PF_SOUND: process.env.PF_SOUND ?? "0",
    };
    for (const key of DEFAULT_UNSET_ENV_KEYS) delete processEnv[key];

    const gatedLaunch = remainOnExit || minimumHistoryLines !== undefined;
    const tmuxCommand = gatedLaunch
      ? `tmux wait-for ${shellQuote(startGate)} && exec ${observedCmd}`
      : observedCmd;
    const tmuxPrefix = resolvedSocketName ? ["-L", resolvedSocketName] : [];
    const setupSessionName = `${name}-setup`;
    const killSetupSession = () => {
      try {
        execFileSync(
          "tmux",
          [...tmuxPrefix, "kill-session", "-t", setupSessionName],
          { stdio: "pipe", env: processEnv },
        );
      } catch {}
    };
    let serverHistoryLines: number | undefined;
    if (minimumHistoryLines !== undefined) {
      execFileSync(
        "tmux",
        [
          ...tmuxPrefix,
          "new-session",
          "-d",
          "-s",
          setupSessionName,
          "sleep 60",
        ],
        { env: processEnv, stdio: "pipe" },
      );
      try {
        const value = execFileSync(
          "tmux",
          [
            ...tmuxPrefix,
            "show-options",
            "-gv",
            "history-limit",
          ],
          { encoding: "utf8", env: processEnv, stdio: ["ignore", "pipe", "pipe"] },
        ).trim();
        const parsed = Number.parseInt(value, 10);
        if (!Number.isSafeInteger(parsed) || parsed < 0) {
          throw new Error(`invalid tmux history limit: ${JSON.stringify(value)}`);
        }
        serverHistoryLines = parsed;
      } catch (err) {
        killSetupSession();
        throw err;
      }
    }
    const launchPrefix = minimumHistoryLines === undefined
      ? tmuxPrefix
      : [
        ...tmuxPrefix,
        "set-option",
        "-g",
        "history-limit",
        String(Math.max(serverHistoryLines!, minimumHistoryLines)),
        ";",
      ];
    const launchSuffix = minimumHistoryLines === undefined
      ? []
      : [
        ";",
        "set-option",
        "-w",
        "-t",
        `${name}:0`,
        "history-limit",
        String(Math.max(serverHistoryLines!, minimumHistoryLines)),
        ";",
        "set-option",
        "-g",
        "history-limit",
        String(serverHistoryLines!),
        ";",
        "kill-session",
        "-t",
        setupSessionName,
      ];
    try {
      execFileSync(
        "tmux",
        [
          ...launchPrefix,
          "new-session",
          "-d",
          "-s",
          name,
          "-x",
          String(width),
          "-y",
          String(height),
          ...sessionEnvArgs,
          tmuxCommand,
          ...launchSuffix,
        ],
        { cwd, stdio: "pipe", env: processEnv },
      );
    } catch (err) {
      if (minimumHistoryLines !== undefined) {
        try {
          execFileSync(
            "tmux",
            [
              ...tmuxPrefix,
              "set-option",
              "-g",
              "history-limit",
              String(serverHistoryLines!),
            ],
            { stdio: "pipe", env: processEnv },
          );
        } catch {}
        try {
          execFileSync("tmux", [...tmuxPrefix, "kill-session", "-t", name], {
            stdio: "pipe",
            env: processEnv,
          });
        } catch {}
        killSetupSession();
        if (String(err).includes("value is")) {
          throw new Error(
            `tmux history limit ${serverHistoryLines} is below required minimum ${minimumHistoryLines}`,
            { cause: err },
          );
        }
      }
      rmSync(exitStatusPath, { force: true });
      throw err;
    }
    const session = new TmuxSession(name, exitStatusPath, resolvedSocketName);
    try {
      for (const key of AUTH_ENV_KEYS) {
        try {
          execFileSync(
            "tmux",
            [...tmuxPrefix, "set-environment", "-u", "-t", name, key],
            { env: processEnv, stdio: "pipe" },
          );
        } catch (err) {
          if (session.isAlive()) throw err;
        }
      }
      if (remainOnExit) {
        execFileSync(
          "tmux",
          [...tmuxPrefix, "set-option", "-w", "-t", `${name}:0`, "remain-on-exit", "on"],
          { stdio: "pipe" },
        );
        const value = execFileSync(
          "tmux",
          [...tmuxPrefix, "show-options", "-w", "-v", "-t", `${name}:0`, "remain-on-exit"],
          { stdio: "pipe", encoding: "utf-8" },
        ).trim();
        if (value !== "on") {
          throw new Error(
            `tmux remain-on-exit verification failed for ${name}: ${JSON.stringify(value)}`,
          );
        }
      }

      if (minimumHistoryLines !== undefined) {
        const inherited = session.historyLimit();
        if (inherited < minimumHistoryLines) {
          throw new Error(
            `tmux history limit ${inherited} is below required minimum ${minimumHistoryLines}`,
          );
        }
      }

      if (gatedLaunch) {
        execFileSync("tmux", [...tmuxPrefix, "wait-for", "-S", startGate], {
          stdio: "pipe",
        });
      }
      await sleep(startupWaitMs);
      return session;
    } catch (err) {
      await session.kill();
      throw err;
    }
  }

  async sendKeys(keys: string): Promise<void> {
    execSync(`${this.tmuxCommand()} send-keys -t ${this.name} ${keys}`, {
      stdio: "pipe",
    });
    await sleep(100);
  }

  // Interrupt active work: the first Escape arms the interrupt gesture, and a
  // confirming press within the one-second window cancels. The confirm press
  // is retried once when a runner stall let the arm expire between presses
  // (the hint reappearing means the second press re-armed instead of firing).
  async sendInterruptEscapePair(hintTimeoutMs = 15_000): Promise<void> {
    await this.sendKeys("Escape");
    await this.waitForText("esc again to interrupt", hintTimeoutMs);
    await sleep(150);
    await this.sendKeys("Escape");
    await sleep(250);
    const pane = await this.capturePane();
    if (
      pane.includes("esc again to interrupt") ||
      pane.includes("esc esc interrupt") ||
      pane.includes("esc esc to interrupt")
    ) {
      await this.sendKeys("Escape");
    }
  }

  sendKeysImmediate(keys: readonly string[]): void {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, ...keys]),
      { stdio: "pipe" },
    );
  }

  sendRepeatedKeyThenImmediate(key: string, count: number, nextKey: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs([
        "send-keys",
        "-N",
        String(count),
        "-t",
        this.name,
        key,
        ";",
        "send-keys",
        "-t",
        this.name,
        nextKey,
      ]),
      { stdio: "pipe" },
    );
  }

  sendLiteralImmediate(text: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, "-l", "--", text]),
      { stdio: "pipe" },
    );
  }

  async sendLiteral(text: string): Promise<void> {
    await this.sendLiteralText(text);
  }

  async sendText(text: string): Promise<void> {
    await this.sendLiteralText(text);
    await this.sendKeys("Enter");
  }

  async pasteText(text: string): Promise<void> {
    const buffer = `${this.name}-paste`;
    execFileSync("tmux", this.tmuxArgs(["load-buffer", "-b", buffer, "-"]), {
      input: text,
      stdio: ["pipe", "pipe", "pipe"],
    });
    execFileSync(
      "tmux",
      this.tmuxArgs(["paste-buffer", "-d", "-p", "-b", buffer, "-t", this.name]),
      { stdio: "pipe" },
    );
    await sleep(250);
  }

  async sendLiteralText(text: string): Promise<void> {
    execFileSync(
      "tmux",
      this.tmuxArgs(["send-keys", "-t", this.name, "-l", "--", text]),
      { stdio: "pipe" },
    );
    await sleep(50);
  }

  async sendHexBytes(hexBytes: readonly string[]): Promise<void> {
    for (let offset = 0; offset < hexBytes.length; offset += TMUX_HEX_CHUNK_BYTES) {
      execFileSync(
        "tmux",
        this.tmuxArgs([
          "send-keys",
          "-t",
          this.name,
          "-H",
          ...hexBytes.slice(offset, offset + TMUX_HEX_CHUNK_BYTES),
        ]),
        { stdio: "pipe" },
      );
    }
    await sleep(150);
  }

  async sendFragmentedHexBytes(
    hexBytes: readonly string[],
    delayMs: number,
    injectionLogPath: string,
  ): Promise<void> {
    if (!Number.isInteger(delayMs) || delayMs < 0) {
      throw new Error(`delayMs must be a non-negative integer, got ${delayMs}`);
    }
    writeFileSync(
      injectionLogPath,
      hexBytes.map((byte, index) =>
        `write=${index + 1}/${hexBytes.length} byte=${byte} delay_before_ms=${index === 0 ? 0 : delayMs}`
      ).join("\n") + "\n",
    );
    for (const [index, byte] of hexBytes.entries()) {
      execFileSync("tmux", this.tmuxArgs(["send-keys", "-t", this.name, "-H", byte]), {
        stdio: "pipe",
      });
      if (index + 1 < hexBytes.length) await sleep(delayMs);
    }
    await sleep(150);
  }

  async capturePane(): Promise<string> {
    try {
      return execSync(`${this.tmuxCommand()} capture-pane -t ${this.name} -p`, {
        stdio: "pipe",
        encoding: "utf-8",
        maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
      });
    } catch {
      return "";
    }
  }

  async captureFullScrollback(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["capture-pane", "-t", this.name, "-p", "-S", "-"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
          maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
        },
      );
    } catch {
      return "";
    }
  }

  /**
   * Complete pane history including the ANSI sequences emitted by pf.
   * Keep this separate from the viewport capture so transcript-order tests
   * inspect all committed output rather than only the visible rows.
   */
  async captureFullScrollbackEscapes(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["capture-pane", "-t", this.name, "-e", "-p", "-S", "-"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
          maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
        },
      );
    } catch {
      return "";
    }
  }

  /**
   * Current pane title, which is what a terminal renders as the tab label.
   * pf sets it through OSC 2, so this reads back what the user would see.
   */
  async paneTitle(): Promise<string> {
    try {
      return execFileSync(
        "tmux",
        this.tmuxArgs(["display-message", "-p", "-t", this.name, "#{pane_title}"]),
        {
          stdio: "pipe",
          encoding: "utf-8",
        },
      ).trimEnd();
    } catch {
      return "";
    }
  }

  /**
   * Resize the tmux window. Delivers a real SIGWINCH to pf, exercising the
   * resize pipeline end-to-end. Default post-resize sleep covers the 100 ms
   * debounce in src/main.zig.
   */
  async resizeWindow(cols: number, rows: number, settleMs = 250): Promise<void> {
    execSync(`${this.tmuxCommand()} resize-window -t ${this.name} -x ${cols} -y ${rows}`, {
      stdio: "pipe",
    });
    await sleep(settleMs);
  }

  /**
   * Capture pane output including raw ANSI escape sequences. Use when you
   * need to assert on color/style or confirm specific escapes were emitted.
   */
  async capturePaneEscapes(): Promise<string> {
    try {
      return execSync(`${this.tmuxCommand()} capture-pane -t ${this.name} -e -p -J`, {
        stdio: "pipe",
        encoding: "utf-8",
        maxBuffer: TMUX_CAPTURE_MAX_BUFFER,
      });
    } catch {
      return "";
    }
  }

  /**
   * Copy subsequent raw pane output to a file. Unlike capture-pane, this
   * preserves control bytes such as BEL before tmux applies them to its grid.
   */
  startPaneOutputCapture(path: string): void {
    execFileSync(
      "tmux",
      this.tmuxArgs([
        "pipe-pane",
        "-O",
        "-t",
        this.name,
        `cat >> ${shellQuote(path)}`,
      ]),
      { stdio: "pipe" },
    );
  }

  /**
   * Grid snapshot of the pane as an array of row strings (ANSI stripped).
   * Rows are right-padded to the pane width so positional assertions are
   * stable.
   */
  async capturePaneGrid(): Promise<string[]> {
    const raw = await this.capturePane();
    if (raw.length === 0) return [];
    return raw.replace(/\n$/, "").split("\n");
  }

  /**
   * Full snapshot for golden-style assertions.
   */
  async snapshot(): Promise<{ grid: string[]; escapes: string; alive: boolean }> {
    return {
      grid: await this.capturePaneGrid(),
      escapes: await this.capturePaneEscapes(),
      alive: this.isAlive(),
    };
  }

  /**
   * Current pane dimensions as tmux sees them. Handy for sanity checks after
   * resizeWindow().
   */
  paneSize(): { cols: number; rows: number } {
    const raw = execSync(
      `${this.tmuxCommand()} display-message -t ${this.name} -p "#{pane_width}x#{pane_height}"`,
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const [cols, rows] = raw.split("x").map((s) => parseInt(s, 10));
    return { cols, rows };
  }

  panePid(): number {
    const raw = execFileSync(
      "tmux",
      this.tmuxArgs([
        "display-message",
        "-t",
        `${this.name}:0.0`,
        "-p",
        "#{pane_pid}",
      ]),
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const value = Number.parseInt(raw, 10);
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw new Error(`Invalid tmux pane PID: ${JSON.stringify(raw)}`);
    }
    return value;
  }

  processPid(): number {
    const panePid = this.panePid();
    let children = "";
    try {
      children = execFileSync("pgrep", ["-P", String(panePid)], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch {}
    return parseSingleChildPid(children, panePid);
  }

  historyLimit(): number {
    const raw = execFileSync(
      "tmux",
      this.tmuxArgs([
        "display-message",
        "-t",
        this.name,
        "-p",
        "#{history_limit}",
      ]),
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const value = Number.parseInt(raw, 10);
    if (!Number.isInteger(value) || value < 0) {
      throw new Error(`Invalid tmux history limit: ${JSON.stringify(raw)}`);
    }
    return value;
  }

  paneStatus(): { dead: boolean; status: number | null } {
    try {
      const raw = execSync(
        `${this.tmuxCommand()} display-message -t ${this.name}:0.0 -p "#{pane_dead}:#{pane_dead_status}"`,
        { stdio: "pipe", encoding: "utf-8" },
      ).trim();
      const [dead, status] = raw.split(":");
      const parsed = status && status.length > 0 ? parseInt(status, 10) : null;
      const parsedStatus = parsed !== null &&
          Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= 255
        ? parsed
        : null;
      return {
        dead: dead === "1",
        status: dead === "1" && parsedStatus === null
          ? this.recordedExitStatus()
          : parsedStatus,
      };
    } catch {
      return { dead: true, status: this.recordedExitStatus() };
    }
  }

  isPaneAlive(): boolean {
    return !this.paneStatus().dead;
  }

  cursorPosition(): { row: number; col: number } {
    const raw = execSync(
      `${this.tmuxCommand()} display-message -t ${this.name} -p "#{cursor_y} #{cursor_x}"`,
      { stdio: "pipe", encoding: "utf-8" },
    ).trim();
    const values = raw.split(/\s+/).map((value) => Number.parseInt(value, 10));
    if (
      values.length !== 2 ||
      !Number.isInteger(values[0]) ||
      !Number.isInteger(values[1]) ||
      values[0] < 0 ||
      values[1] < 0
    ) {
      throw new Error(`Invalid tmux cursor position: ${JSON.stringify(raw)}`);
    }
    const [row, col] = values;
    return { row, col };
  }

  async waitForCursor(
    predicate: (position: { row: number; col: number }) => boolean,
    timeoutMs = 3_000,
  ): Promise<{ row: number; col: number }> {
    const start = Date.now();
    let lastMatch = "";
    let lastObserved: { row: number; col: number } | null = null;
    let stableMatches = 0;
    while (Date.now() - start < timeoutMs) {
      const position = this.cursorPosition();
      lastObserved = position;
      const key = `${position.row}:${position.col}`;
      if (predicate(position)) {
        stableMatches = key === lastMatch ? stableMatches + 1 : 1;
        lastMatch = key;
        if (stableMatches >= 2) return position;
      } else {
        lastMatch = "";
        stableMatches = 0;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for cursor predicate in ${this.name}; last=${JSON.stringify(lastObserved)}`,
    );
  }

  async waitForPane(
    predicate: (pane: string) => boolean,
    timeoutMs = 3_000,
  ): Promise<string> {
    const start = Date.now();
    let lastPane = "";
    while (Date.now() - start < timeoutMs) {
      const pane = await this.capturePane();
      lastPane = pane;
      if (predicate(pane)) return pane;
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for pane predicate in ${this.name}.\nLast pane:\n${lastPane}`,
    );
  }

  async waitForStableGrid(
    expected: string[],
    normalize: (grid: string[]) => string[] = (grid) => grid,
    timeoutMs = 3_000,
  ): Promise<string[]> {
    const normalizedExpected = normalize(expected);
    const deadline = Date.now() + timeoutMs;
    let latest: string[] = [];
    while (Date.now() < deadline) {
      latest = await this.capturePaneGrid();
      const normalizedLatest = normalize(latest);
      if (normalizedLatest.length === normalizedExpected.length &&
          normalizedLatest.every((line, index) => line === normalizedExpected[index])) {
        return latest;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable terminal grid.\nExpected:\n${expected.join("\n")}\nActual:\n${latest.join("\n")}`,
    );
  }

  async waitForText(
    pattern: string | RegExp,
    timeoutMs = 15_000,
  ): Promise<string> {
    return this.waitForPane(
      (pane) => typeof pattern === "string"
        ? pane.includes(pattern)
        : pattern.test(pane),
      timeoutMs,
    );
  }

  async waitForComposer(timeoutMs = 15_000): Promise<string> {
    return this.waitForPane(hasEmptyComposer, timeoutMs);
  }

  async waitForStableComposer(
    timeoutMs = 15_000,
    stableMs = 100,
  ): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    let stableSince: number | null = null;
    let previousPane = "";
    let lastPane = "";
    while (Date.now() < deadline) {
      const pane = await this.capturePane();
      lastPane = pane;
      if (hasEmptyComposer(pane)) {
        if (pane !== previousPane) {
          previousPane = pane;
          stableSince = Date.now();
        } else if (stableSince !== null && Date.now() - stableSince >= stableMs) {
          return pane;
        }
      } else {
        previousPane = "";
        stableSince = null;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable composer in ${this.name}.\nLast pane:\n${lastPane}`,
    );
  }

  async waitForStableScrollback(
    predicate: (scrollback: string) => boolean,
    timeoutMs = 15_000,
    stableMs = 100,
  ): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    let stableSince: number | null = null;
    let previousScrollback = "";
    let lastScrollback = "";
    while (Date.now() < deadline) {
      const scrollback = await this.captureFullScrollback();
      lastScrollback = scrollback;
      if (predicate(scrollback)) {
        if (scrollback !== previousScrollback) {
          previousScrollback = scrollback;
          stableSince = Date.now();
        } else if (stableSince !== null && Date.now() - stableSince >= stableMs) {
          return scrollback;
        }
      } else {
        previousScrollback = "";
        stableSince = null;
      }
      await sleep(25);
    }
    throw new Error(
      `Timed out waiting for stable scrollback in ${this.name}.\nLast scrollback:\n${lastScrollback}`,
    );
  }

  async waitForSessionEnd(timeoutMs = 10_000): Promise<boolean> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (!this.isAlive()) return true;
      await sleep(500);
    }
    const pane = await this.capturePane();
    throw new Error(
      `Timed out waiting for tmux session ${this.name} to exit after ${timeoutMs}ms.\nLast pane:\n${pane}`,
    );
  }

  isAlive(): boolean {
    try {
      execSync(`${this.tmuxCommand()} has-session -t ${this.name}`, { stdio: "pipe" });
      return true;
    } catch {
      return false;
    }
  }

  async kill(): Promise<void> {
    if (this.killed) return;
    this.killed = true;
    try {
      execSync(`${this.tmuxCommand()} kill-session -t ${this.name}`, { stdio: "pipe" });
    } catch {}

    const deadline = Date.now() + 1_000;
    let missingServerChecks = 0;
    while (Date.now() < deadline) {
      try {
        execFileSync(
          "tmux",
          this.tmuxArgs(["list-sessions", "-F", "#{session_name}"]),
          { stdio: "pipe" },
        );
        break;
      } catch {
        missingServerChecks += 1;
        if (missingServerChecks === 2) break;
        await sleep(25);
      }
    }
    rmSync(this.exitStatusPath, { force: true });
  }

  private recordedExitStatus(): number | null {
    try {
      const value = Number.parseInt(readFileSync(this.exitStatusPath, "utf8").trim(), 10);
      return Number.isSafeInteger(value) && value >= 0 && value <= 255 ? value : null;
    } catch {
      return null;
    }
  }

  private tmuxArgs(args: string[]): string[] {
    return this.socketName ? ["-L", this.socketName, ...args] : args;
  }

  private tmuxCommand(): string {
    return this.socketName
      ? `tmux -L ${shellQuote(this.socketName)}`
      : "tmux";
  }
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function tmuxAvailable(): boolean {
  try {
    execSync("tmux -V", { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}
