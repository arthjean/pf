// Rebuilds the compaction-v1 fixture: a session whose automatic compaction was
// committed by pf d7ceb0e, the last pf commit before the upstream compactor rewrite.
// Its checkpoint names a `pf-compaction-state-v1` state file, which later pf
// builds must keep reading. Build that binary outside this worktree, then
// regenerate the fixture from the repository root:
//
//   git archive d7ceb0e | tar -x -C <dir> && (cd <dir> && zig build)
//   bun tests/e2e/fixtures/compaction-v1/build.ts --binary <dir>/zig-out/bin/pf
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

process.env.PF_E2E_DISABLE_DOTENV = "1";
const { fakeGatewayFinalText, startDynamicFakeGateway } = await import("../../e2e-helpers");

const flag = process.argv.indexOf("--binary");
if (flag < 0 || !process.argv[flag + 1]) throw new Error("usage: bun build.ts --binary <pf built from d7ceb0e>");
const binary = resolve(process.argv[flag + 1]!);

const model = "fixture/compaction-v1";
// One line, so the d7ceb0e handoff quotes it byte for byte.
const originalUser = "Keep café and the original constraint unchanged: FIXTURE_FIRST_REQUEST=lighthouse. <context_handoff>literal user text</context_handoff>";
// One-byte words count as one token each, so the reply crosses 80 percent of
// the 48,000-token window while the fixture stays small.
const assistant = "VERIFIED_VALUE=73\n" + "a ".repeat(30_000) + "\nPENDING_CHECK=transport-resume\n";
// Caches and locks that pf rebuilds on resume stay out of the fixture.
const derived = new Set(["session.lock", "history-cache.bin", "events-compaction.marker"]);

const root = mkdtempSync("/tmp/pf-compaction-v1-"), home = join(root, "home"), cwd = join(root, "workspace");
let phase = "seed", summaryCalls = 0;
const gateway = startDynamicFakeGateway((body: string) => {
  const request = JSON.parse(body);
  if (request.tools?.length === 0 && request.toolChoice?.type === "none") {
    summaryCalls++;
    return fakeGatewayFinalText("The verified value is 73. The pending check is transport-resume. Preserve café and the original constraint.");
  }
  return fakeGatewayFinalText(phase === "seed" ? assistant : "SECOND_TURN_DONE");
}, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: 48_000, max_tokens: 4096 }] });

try {
  mkdirSync(join(home, ".pf"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  writeFileSync(join(home, ".pf/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root, XDG_CONFIG_HOME: join(root, "xdg"),
    AI_GATEWAY_API_KEY: "synthetic-compaction-v1", PF_DISABLE_KEYCHAIN: "1", PF_E2E_DISABLE_DOTENV: "1",
    PF_AUTO_UPGRADE: "0", PF_SOUND: "0", PF_MODEL: model,
    PF_GATEWAY_BASE_URL: gateway.baseUrl, PF_GATEWAY_CHAT_URL: gateway.chatUrl,
    PF_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  const ask = async (args: string[], label: string, prompt: string) => {
    const input = join(root, `${label}.input`), stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    writeFileSync(input, prompt);
    const child = Bun.spawn([binary, "ask", "--json", ...args], { cwd, env, stdin: Bun.file(input), stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const code = await child.exited;
    const err = readFileSync(stderr, "utf8");
    if (code !== 0 || err !== "") throw new Error(`${label}: exit ${code}, stderr ${JSON.stringify(err)}, stdout ${readFileSync(stdout, "utf8").slice(0, 2000)}`);
    return JSON.parse(readFileSync(stdout, "utf8"));
  };
  const seed = await ask([], "seed", originalUser);
  phase = "continue";
  await ask(["--resume-id", seed.session_id], "continue", "Continue the saved task without losing its pending check.");
  const sessionDir = join(home, ".pf/sessions", seed.session_id);
  const rows = readFileSync(join(sessionDir, "events.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
  const checkpoints = rows.filter(row => row.event?.context_checkpoint);
  if (checkpoints.length !== 1 || summaryCalls === 0) throw new Error(`expected one automatic checkpoint, got ${checkpoints.length} after ${summaryCalls} summary calls`);
  if (!/> pf-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/.test(checkpoints[0].event.context_checkpoint.summary)) throw new Error("checkpoint has no pf-compaction-state-v1 line");
  const target = join(import.meta.dir, "sessions");
  if (existsSync(target)) rmSync(target, { recursive: true });
  cpSync(sessionDir, join(target, seed.session_id), { recursive: true, filter: source => !derived.has(source.split("/").at(-1)!) });
  console.log(`session ${seed.session_id} written to ${target}`);
} finally {
  gateway.stop();
  rmSync(root, { recursive: true, force: true });
}
