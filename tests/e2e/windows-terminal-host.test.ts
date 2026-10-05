/**
 * Hosted terminal sessions on Windows. `pf ask` drives the shell tool with
 * `tty: true` through a fake gateway, so each session runs in the detached
 * terminal host behind ConPTY, in the shell that `shell_selection` picks.
 * The suite runs only on Windows.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runPf } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  type FakeGatewayResponse,
} from "./e2e-helpers";

const isWindows = process.platform === "win32";
const TIMEOUT = 90_000;
const GIT_BASH = "C:\\Program Files\\Git\\bin\\bash.exe";
const BASH_ENV = { PF_WINDOWS_SHELL: "bash", PF_GIT_BASH_PATH: GIT_BASH };

let cleanup: (() => void)[] = [];

afterEach(() => {
  for (const step of cleanup.reverse()) step();
  cleanup = [];
});

function createProfile() {
  // A short root: every session's control socket lives under the profile and
  // must fit an AF_UNIX path of 108 bytes.
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pf-wt-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".pf"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".pf", "settings.json"),
    JSON.stringify({ permission_mode: "yolo", yolo_acknowledged: true, permission: {} }) + "\n",
  );
  cleanup.push(() => {
    stopHost(home);
    rmSync(root, { recursive: true, force: true });
  });
  return { root, home, workspace: realpathSync(workspace) };
}

function hostIdentity(home: string): { pid: string } | null {
  const path = join(home, ".pf", "terminal-host-v7", "host.json");
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as { pid: string };
  } catch {
    return null;
  }
}

function processRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function stopHost(home: string) {
  const identity = hostIdentity(home);
  if (identity) {
    try {
      process.kill(Number(identity.pid), "SIGKILL");
    } catch {}
  }
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await Bun.sleep(50);
  }
  return predicate();
}

function toolResultText(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as { prompt?: Array<{ content?: Array<Record<string, unknown>> }> };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  if (!result) throw new Error(`no tool result for ${toolCallId}`);
  const output = result.output as { value?: unknown };
  return typeof output.value === "string" ? output.value : JSON.stringify(output.value);
}

function sessionIdIn(text: string): string {
  const match = text.match(/"session_id"\s*:\s*"([^"]+)"/);
  if (!match) throw new Error(`no session_id in ${text}`);
  return match[1]!;
}

async function ask(
  profile: ReturnType<typeof createProfile>,
  responses: FakeGatewayResponse[],
  args: string[] = [],
  extraEnv: Record<string, string> = {},
) {
  const gateway = startFakeGateway(responses);
  cleanup.push(() => gateway.stop());
  const result = await runPf(["ask", "--json", ...args, "Drive the hosted terminal."], {
    cwd: profile.workspace,
    env: {
      HOME: profile.home,
      USERPROFILE: profile.home,
      AI_GATEWAY_API_KEY: "fake-windows-terminal-key",
      VERCEL_OIDC_TOKEN: undefined,
      PF_GATEWAY_BASE_URL: gateway.baseUrl,
      PF_GATEWAY_CHAT_URL: gateway.chatUrl,
      PF_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
      PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      PF_E2E_GATEWAY_CREDITS_URL: undefined,
      PF_MODEL: FAKE_GATEWAY_MODEL,
      PF_AUTO_UPGRADE: "0",
      PF_TERMINAL_HOST_IDLE_MS: "60000",
      ...extraEnv,
    },
    timeoutMs: TIMEOUT,
  });
  if (result.code !== 0) throw new Error(`pf exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  return { gateway, result };
}

function ttyRun(id: string, command: string, yieldMs = 5_000) {
  return fakeGatewayToolCall(id, "shell", {
    request: { action: "run", command, tty: true, yield_time_ms: yieldMs },
  });
}

function interact(id: string, sessionId: () => string, chars: string, yieldMs = 5_000) {
  return () =>
    fakeGatewayToolCall(id, "shell", {
      request: { action: "interact", session_id: sessionId(), chars, yield_time_ms: yieldMs },
    });
}

function pythonAvailable(): boolean {
  try {
    execFileSync("python", ["-c", "print(1)"], { stdio: "pipe", timeout: 15_000 });
    return true;
  } catch {
    return false;
  }
}

describe.skipIf(!isWindows)("hosted terminal sessions on Windows", () => {
  test.skipIf(!pythonAvailable())("drives a Python REPL through ConPTY", async () => {
    const profile = createProfile();
    let sessionId = "";
    const { gateway } = await ask(profile, [
      ttyRun("repl_start", "python -q -i", 3_000),
      (body) => {
        sessionId = sessionIdIn(toolResultText(body, "repl_start"));
        return interact("repl_answer", () => sessionId, "print(6 * 7 + 1000)\r", 3_000)();
      },
      interact("repl_exit", () => sessionId, "exit(3)\r", 10_000),
      fakeGatewayFinalText("REPL_DONE"),
    ]);
    expect(toolResultText(gateway.requests[2]!.body, "repl_answer")).toContain("1042");
    expect(toolResultText(gateway.requests[3]!.body, "repl_exit")).toMatch(/"exit_code"\s*:\s*3/);
  }, TIMEOUT);

  test.skipIf(!existsSync(GIT_BASH))("reports the exit code of a Git Bash session", async () => {
    const profile = createProfile();
    const { gateway } = await ask(
      profile,
      [ttyRun("exit_run", "echo HOSTED_EXIT_MARK; exit 7", 20_000), fakeGatewayFinalText("EXIT_DONE")],
      [],
      BASH_ENV,
    );
    const output = toolResultText(gateway.requests[1]!.body, "exit_run");
    expect(output).toContain("HOSTED_EXIT_MARK");
    expect(output).toMatch(/"exit_code"\s*:\s*7/);
  }, TIMEOUT);

  test("reports the exit code of a PowerShell session", async () => {
    const profile = createProfile();
    const { gateway } = await ask(
      profile,
      [ttyRun("exit_run", "Write-Output ('PS_' + 'EXIT_MARK'); exit 9", 20_000), fakeGatewayFinalText("EXIT_DONE")],
      [],
      { PF_WINDOWS_SHELL: "powershell" },
    );
    const output = toolResultText(gateway.requests[1]!.body, "exit_run");
    expect(output).toContain("PS_EXIT_MARK");
    expect(output).toMatch(/"exit_code"\s*:\s*9/);
  }, TIMEOUT);

  test.skipIf(!existsSync(GIT_BASH))("keeps a session across pf restarts and loses it with its host", async () => {
    const profile = createProfile();
    let sessionId = "";
    const first = await ask(
      profile,
      [
        ttyRun(
          "long_run",
          'sleep 600 & echo "PIDS=$(cat /proc/$$/winpid):$(cat /proc/$!/winpid)"; echo LONG_READY; ' +
            'while read line; do echo "GOT_$line"; done',
          3_000,
        ),
        (body) => {
          sessionId = sessionIdIn(toolResultText(body, "long_run"));
          return fakeGatewayFinalText("PHASE_ONE");
        },
      ],
      [],
      BASH_ENV,
    );
    const started = toolResultText(first.gateway.requests[1]!.body, "long_run");
    expect(started).toContain("LONG_READY");
    const pids = started.match(/PIDS=(\d+):(\d+)/);
    expect(pids).not.toBeNull();
    const sessionPids = [Number(pids![1]), Number(pids![2])];
    expect(sessionPids.every(processRunning)).toBe(true);
    const identity = hostIdentity(profile.home);
    expect(identity).not.toBeNull();
    const hostPid = Number(identity!.pid);
    expect(processRunning(hostPid)).toBe(true);

    // pf exited; the detached host kept the session for the next run.
    const second = await ask(
      profile,
      [interact("long_observe", () => sessionId, "AFTER_RESTART\r", 3_000), fakeGatewayFinalText("PHASE_TWO")],
      ["--resume", "last"],
      BASH_ENV,
    );
    expect(toolResultText(second.gateway.requests[1]!.body, "long_observe")).toContain("GOT_AFTER_RESTART");
    expect(hostIdentity(profile.home)?.pid).toBe(identity!.pid);

    // A crashed host takes every process of its sessions with it.
    process.kill(hostPid, "SIGKILL");
    expect(await waitFor(() => !processRunning(hostPid), 10_000)).toBe(true);
    expect(await waitFor(() => !sessionPids.some(processRunning), 10_000)).toBe(true);

    const third = await ask(
      profile,
      [interact("long_lost", () => sessionId, "", 1_000), fakeGatewayFinalText("PHASE_THREE")],
      ["--resume", "last"],
      BASH_ENV,
    );
    expect(toolResultText(third.gateway.requests[1]!.body, "long_lost")).toMatch(/lost/);
  }, TIMEOUT * 2);
});
