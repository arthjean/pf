/**
 * `pf upgrade` installs only a release whose SHA-256 sidecar and minisign
 * signature verify, and leaves the installed binary byte-identical whenever
 * it refuses one. Each case runs a copy of the built binary against a signed
 * loopback release channel from upgrade-fixture.ts.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  REPO_ROOT,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./e2e-helpers";
import { installPfCopy, startUpgradeServer, type UpgradeFixtureOptions } from "./upgrade-fixture";

const TIMEOUT_MS = 60_000;

let cleanup: (() => void)[] = [];

afterEach(() => {
  for (const fn of cleanup.reverse()) fn();
  cleanup = [];
});

type Installed = { root: string; home: string; pf: string; original: Buffer };

function install(): Installed {
  const root = realpathSync.native(mkdtempSync(join(tmpdir(), "pf-upgrade-verification-")));
  cleanup.push(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const bin = join(root, "bin");
  mkdirSync(home);
  mkdirSync(bin);
  const pf = installPfCopy(bin);
  return { root, home, pf, original: readFileSync(pf) };
}

function serve(installed: Installed, options: UpgradeFixtureOptions = {}) {
  const fixture = startUpgradeServer(installed.root, join(installed.root, "argv.log"), options);
  cleanup.push(fixture.stop);
  return fixture;
}

async function upgradeJson(
  installed: Installed,
  env: Record<string, string | undefined>,
  args: string[] = [],
): Promise<{ code: number; report: Record<string, unknown>; stderr: string }> {
  const proc = Bun.spawn([installed.pf, "upgrade", ...args, "--json"], {
    env: {
      ...process.env,
      HOME: installed.home,
      USERPROFILE: installed.home,
      PF_AUTO_UPGRADE: "0",
      PF_E2E_UPGRADE_BASE_URL: undefined,
      PF_E2E_UPGRADE_PUBLIC_KEY: undefined,
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  return { code, report: JSON.parse(stdout.trim()), stderr };
}

function expectUnchanged(installed: Installed) {
  expect(readFileSync(installed.pf).equals(installed.original)).toBe(true);
  expect(existsSync(`${installed.pf}.old`)).toBe(false);
}

describe("pf upgrade verification", () => {
  test("installs a signed release and runs it", async () => {
    const installed = install();
    const fixture = serve(installed);

    const { code, report, stderr } = await upgradeJson(installed, fixture.env);
    expect(report, stderr).toMatchObject({ kind: "upgrade", latest: "9.9.9", status: "upgraded" });
    expect(code).toBe(0);
    expect(readFileSync(installed.pf).equals(fixture.artifact)).toBe(true);

    if (process.platform === "win32") {
      // The running pf.exe was renamed aside; the next start removes it.
      expect(readFileSync(`${installed.pf}.old`).equals(installed.original)).toBe(true);
    }
    const version = Bun.spawnSync([installed.pf, "--version"], {
      env: { ...process.env, HOME: installed.home, USERPROFILE: installed.home },
    });
    expect(version.exitCode, version.stderr.toString()).toBe(0);
    expect(existsSync(`${installed.pf}.old`)).toBe(false);
  }, TIMEOUT_MS);

  const refusals: { name: string; options: UpgradeFixtureOptions; trustKey?: boolean; error: string }[] = [
    {
      name: "a tampered archive",
      options: { signature: "bad" },
      error: "Refused to install pf 9.9.9: its signature is invalid.",
    },
    {
      name: "an unsigned archive",
      options: { signature: "missing" },
      error: "Refused to install pf 9.9.9: it has no signature, so it cannot be verified.",
    },
    {
      name: "a signature for another version",
      options: { signedVersion: "v9.9.8" },
      error: "Refused to install pf 9.9.9: the signature belongs to a different release.",
    },
    {
      name: "a signature from an untrusted key",
      options: {},
      trustKey: false,
      error: "Refused to install pf 9.9.9: it is signed by an unknown key. Download pf from its release page.",
    },
    {
      name: "an archive redirected to another host",
      options: { redirectArchive: true },
      error: "The pf release host redirected to an unexpected location; update refused.",
    },
    {
      name: "a channel with no published release",
      options: { latest: null },
      error: "No pf release is published yet; rebuild from source to update.",
    },
  ];
  for (const refusal of refusals) {
    test(`refuses ${refusal.name} and keeps the binary`, async () => {
      const installed = install();
      const fixture = serve(installed, refusal.options);
      const env = refusal.trustKey === false
        ? { PF_E2E_UPGRADE_BASE_URL: fixture.baseUrl }
        : fixture.env;

      const { code, report, stderr } = await upgradeJson(installed, env);
      expect(report, stderr).toEqual({ kind: "upgrade", status: "failed", error: refusal.error });
      expect(code).toBe(1);
      expectUnchanged(installed);
    }, TIMEOUT_MS);
  }

  test("installs a signed dev build", async () => {
    const installed = install();
    const fixture = serve(installed);

    const { code, report, stderr } = await upgradeJson(installed, fixture.env, ["--channel", "dev"]);
    expect(report, stderr).toMatchObject({ kind: "upgrade", status: "upgraded" });
    expect(code).toBe(0);
    expect(readFileSync(installed.pf).equals(fixture.artifact)).toBe(true);
  }, TIMEOUT_MS);

  test("refuses a dev build signed for another commit and keeps the binary", async () => {
    const installed = install();
    const fixture = serve(installed, { signedRevision: "0123456789abcdef0123456789abcdef01234567" });

    const { code, report, stderr } = await upgradeJson(installed, fixture.env, ["--channel", "dev"]);
    expect(report, stderr).toMatchObject({ kind: "upgrade", status: "failed" });
    expect(String(report.error)).toEndWith("the signature belongs to a different release.");
    expect(code).toBe(1);
    expectUnchanged(installed);
  }, TIMEOUT_MS);

  test("reports an older stable release as up to date without downloading it", async () => {
    const installed = install();
    const fixture = serve(installed, { latest: "v0.0.1", signature: "missing" });

    const { code, report, stderr } = await upgradeJson(installed, fixture.env);
    expect(report, stderr).toMatchObject({ kind: "upgrade", latest: "0.0.1", status: "up_to_date" });
    expect(code).toBe(0);
    expectUnchanged(installed);
  }, TIMEOUT_MS);
});

const DRIVER = join(REPO_ROOT, "zig-out", "bin", "conpty-driver.exe");

describe.skipIf(process.platform !== "win32")("windows upgrade relaunch", () => {
  test(
    "ctrl+g relaunches the background-installed pf.exe and resumes the session",
    async () => {
      if (!existsSync(DRIVER)) {
        throw new Error(`ConPTY driver not found at ${DRIVER}. Run 'zig build conpty-driver' first.`);
      }
      const installed = install();
      const fixture = serve(installed);
      const gateway = startFakeGateway([fakeGatewayFinalText("UPGRADE_WINDOWS_INITIAL_DONE")]);
      cleanup.push(() => gateway.stop());
      const workspace = join(installed.root, "workspace");
      mkdirSync(workspace);

      const script = join(installed.root, "relaunch.script");
      const output = join(installed.root, "output.bin");
      const events = join(installed.root, "events.log");
      writeFileSync(script, [
        `wait ${JSON.stringify("┃")} 15000`,
        `send ${JSON.stringify("save a turn before the upgrade")}`,
        "sleep 200",
        `send ${JSON.stringify("\r")}`,
        `wait ${JSON.stringify("UPGRADE_WINDOWS_INITIAL_DONE")} 15000`,
        `wait ${JSON.stringify("update ready: ctrl+g to reload")} 40000`,
        `send ${JSON.stringify("\u0007")}`,
        `wait ${JSON.stringify("pf has been updated to")} 15000`,
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
        installed.pf,
      ], {
        cwd: workspace,
        env: {
          ...process.env,
          HOME: installed.home,
          USERPROFILE: installed.home,
          AI_GATEWAY_API_KEY: "fake-windows-upgrade-key",
          VERCEL_OIDC_TOKEN: undefined,
          PF_GATEWAY_BASE_URL: gateway.baseUrl,
          PF_GATEWAY_CHAT_URL: gateway.chatUrl,
          PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          PF_MODEL: FAKE_GATEWAY_MODEL,
          PF_AUTO_UPGRADE: "1",
          ...fixture.env,
          PF_DISABLE_KEYCHAIN: "1",
          PF_SKIP_ONBOARDING: "1",
          PF_SOUND: "0",
          PF_PERMISSION_MODE: undefined,
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      const code = await proc.exited;
      const eventLog = existsSync(events) ? readFileSync(events, "utf8") : "";
      const screen = existsSync(output) ? readFileSync(output, "latin1") : "";
      const context = `driver exit ${code}\nevents:\n${eventLog}\noutput tail:\n${JSON.stringify(screen.slice(-3000))}`;

      expect(code, context).toBe(0);
      expect(eventLog, context).not.toContain("wait_timeout");
      expect(screen, context).not.toContain("relaunch failed");
      // pf prints the update notice only when relaunched with
      // `resume <session-id> --upgrade-relaunch`; resuming kept the one
      // session instead of starting another.
      const sessions = readdirSync(join(installed.home, ".pf", "sessions")).filter((name) => name !== "latest");
      expect(sessions, context).toHaveLength(1);
      expect(readFileSync(installed.pf).equals(fixture.artifact)).toBe(true);
      expect(readFileSync(`${installed.pf}.old`).equals(installed.original)).toBe(true);
    },
    120_000,
  );
});
