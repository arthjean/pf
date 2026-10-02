/**
 * Windows TUI smoke test. tmux does not exist on Windows, so the US-009
 * ConPTY driver (`zig build conpty-driver`) runs pf.exe behind a pseudo
 * console from a timed script: it starts pf, sends a prompt, waits for the
 * fake gateway reply, resizes, and exits with Ctrl+C.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  REPO_ROOT,
  fakeGatewayFinalText,
  requirePfBinary,
  startFakeGateway,
} from "./e2e-helpers";

const DRIVER = join(REPO_ROOT, "zig-out", "bin", "conpty-driver.exe");
const REPLY = "windows smoke reply";
const TIMEOUT_MS = 60_000;

let cleanup: (() => void)[] = [];

afterEach(() => {
  for (const fn of cleanup.reverse()) fn();
  cleanup = [];
});

describe.skipIf(process.platform !== "win32")("windows tui smoke", () => {
  test(
    "pf.exe answers a prompt through ConPTY, resizes, and exits on Ctrl+C with the console restored",
    async () => {
      const pf = requirePfBinary();
      if (!existsSync(DRIVER)) {
        throw new Error(`ConPTY driver not found at ${DRIVER}. Run 'zig build conpty-driver' first.`);
      }

      const gateway = startFakeGateway([fakeGatewayFinalText(REPLY)]);
      cleanup.push(() => gateway.stop());
      const root = mkdtempSync(join(tmpdir(), "pf-windows-tui-smoke-"));
      cleanup.push(() => rmSync(root, { recursive: true, force: true }));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);

      const script = join(root, "smoke.script");
      const output = join(root, "output.bin");
      const events = join(root, "events.log");
      const trace = join(root, "trace.log");
      writeFileSync(script, [
        `wait ${JSON.stringify("┃")} 15000`,
        `send ${JSON.stringify("say hello")}`,
        "sleep 200",
        `send ${JSON.stringify("\r")}`,
        `wait ${JSON.stringify(REPLY)} 15000`,
        "resize 80 24",
        "sleep 500",
        `send ${JSON.stringify("\u0003")}`,
        "sleep 300",
        `send ${JSON.stringify("\u0003")}`,
        "",
      ].join("\n"));

      const proc = Bun.spawn([
        DRIVER,
        "--cols", "120",
        "--rows", "30",
        "--script", script,
        "--output", output,
        "--events", events,
        "--exit-timeout-ms", "10000",
        "--",
        pf,
      ], {
        cwd: workspace,
        env: {
          ...process.env,
          HOME: home,
          USERPROFILE: home,
          AI_GATEWAY_API_KEY: "fake-windows-smoke-key",
          VERCEL_OIDC_TOKEN: undefined,
          PF_GATEWAY_BASE_URL: gateway.baseUrl,
          PF_GATEWAY_CHAT_URL: gateway.chatUrl,
          PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          PF_MODEL: FAKE_GATEWAY_MODEL,
          PF_AUTO_UPGRADE: "0",
          PF_DISABLE_KEYCHAIN: "1",
          PF_SKIP_ONBOARDING: "1",
          PF_SOUND: "0",
          PF_PERMISSION_MODE: undefined,
          PF_TRACE_LOG: trace,
          PF_TRACE_SCOPES: "resize",
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const code = await proc.exited;
      const eventLog = existsSync(events) ? readFileSync(events, "utf8") : "";
      const screen = existsSync(output) ? readFileSync(output, "latin1") : "";
      const context = `driver exit ${code}\nevents:\n${eventLog}\noutput tail:\n${JSON.stringify(screen.slice(-2000))}`;

      // The driver exits with pf's exit code, or 124 when a wait times out.
      expect(code, context).toBe(0);
      expect(eventLog, context).not.toContain("wait_timeout");
      expect(gateway.requestCount(), context).toBe(1);
      expect(gateway.requests[0]!.body, context).toContain("say hello");

      // The resize reached pf, which laid out its next frame at 80x24.
      const traceLog = existsSync(trace) ? readFileSync(trace, "utf8") : "";
      expect(traceLog, `${context}
trace:
${traceLog}`).toContain("layout=80x24");

      // On exit pf turns off bracketed paste and shows the cursor again,
      // after the last time it enabled them.
      expect(screen.lastIndexOf("\x1b[?2004l"), context).toBeGreaterThan(screen.lastIndexOf("\x1b[?2004h"));
      expect(screen.lastIndexOf("\x1b[?25h"), context).toBeGreaterThan(screen.lastIndexOf("\x1b[?25l"));
    },
    TIMEOUT_MS,
  );
});
