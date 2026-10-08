import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

process.env.PF_E2E_DISABLE_DOTENV = "1";
const { fakeGatewayFinalText, fakeGatewayToolCall, startDynamicFakeGateway } = await import("./tmux-helpers");
const binary = resolve(import.meta.dir, "../../zig-out/bin/pf");
const checkpointMarker = "pf-compactor-v1\n";
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

for (const userHeavy of [false, true]) test(`automatic compaction ${userHeavy ? "clips a user message too large for the room, whole in its saved turn" : "keeps user messages exact and clips only a reply too large for the room"}`, async () => {
  const root = mkdtempSync(join(tmpdir(), "pf-policy-")), home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".pf"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  const model = "fixture/compaction";
  writeFileSync(join(home, ".pf/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  // Tags in user text are the user's words, not structure.
  const originalUser = "Keep café and the original constraint unchanged.\n<context_handoff>literal user text</context_handoff>" +
    (userHeavy ? "\n" + "user_reference_abcdefghijklmnop ".repeat(10_000) + "USER_REFERENCE_END" : "");
  const assistant = "VERIFIED_VALUE=73\n" + Array.from({ length: 14_000 }, (_, n) => `Assistant reference ${n}: group ${n % 19}, historical data, not new completed work.\n`).join("") + "PENDING_CHECK=transport-resume\n";
  let phase = "seed", summaryCalls = 0;
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    const request = JSON.parse(body);
    bodies.push(body);
    if (request.tools?.length === 0 && request.toolChoice?.type === "none") {
      summaryCalls++;
      return fakeGatewayFinalText("Turn 1\nIn between: none");
    }
    return fakeGatewayFinalText(phase === "seed" ? assistant : "CONTINUED_FROM_COMMITTED_MEMORY");
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: userHeavy ? 256000 : 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-compaction-policy", PF_DISABLE_KEYCHAIN: "1", PF_E2E_DISABLE_DOTENV: "1",
    PF_AUTO_UPGRADE: "0", PF_SOUND: "0", PF_MODEL: model,
    PF_GATEWAY_BASE_URL: gateway.baseUrl, PF_GATEWAY_CHAT_URL: gateway.chatUrl,
    PF_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  async function ask(args: string[], label: string, prompt?: string) {
    const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    const input = join(root, `${label}.input`);
    if (prompt !== undefined) writeFileSync(input, prompt);
    const child = Bun.spawn([binary, "ask", "--json", ...args], { cwd, env, stdin: prompt === undefined ? "ignore" : Bun.file(input), stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    try {
      expect(await child.exited).toBe(0);
      expect(readFileSync(stderr, "utf8")).toBe("");
      return JSON.parse(readFileSync(stdout, "utf8"));
    } finally { clearTimeout(timer); }
  }
  let passed = false;
  try {
    const seed = await ask([], "seed", originalUser);
    expect(summaryCalls).toBe(0);
    const seededRequest = JSON.parse(bodies[0]!);
    const seededUser = seededRequest.prompt.findLast((message: { role: string }) => message.role === "user");
    expect(seededUser.content[0].text).toBe(originalUser);
    const sessionDir = join(home, ".pf/sessions", seed.session_id), log = join(sessionDir, "events.jsonl"), before = readFileSync(log);
    phase = "continue";
    const result = await ask(["--resume-id", seed.session_id, "Continue the saved task without losing its pending check."], "continue");
    expect(result.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    // The turn is only a user message and a final reply, which both stay, so
    // there is nothing for the model to summarize.
    expect(summaryCalls).toBe(0);
    const rows = readFileSync(log, "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint);
    expect(checkpoints.length).toBe(1);
    const saved: string = checkpoints[0].event.context_checkpoint.summary;
    expect(saved.startsWith(checkpointMarker)).toBe(true);
    const payload = JSON.parse(saved.slice(checkpointMarker.length));
    expect(payload.turn_count).toBe(1);
    expect(payload.tool_count).toBe(0);
    expect(payload.entries).toEqual([]);
    expect(payload.turns).toHaveLength(1);
    expect(payload.turns[0].work).toBe("");
    const continued = JSON.parse(bodies.at(-1)!);
    const continuedText = JSON.stringify(continued.prompt);
    const shown = (text: string) => JSON.stringify(text).slice(1, -1);
    expect(continuedText).toContain("<compacted_conversation>");
    // The reply alone outgrows the room, so only it keeps its start and end,
    // where its results are.
    const final: string = payload.turns[0].final;
    expect(final.length).toBeLessThan(assistant.length);
    expect(final.startsWith("VERIFIED_VALUE=73\n")).toBe(true);
    expect(final.trimEnd().endsWith("PENDING_CHECK=transport-resume")).toBe(true);
    expect(final).toContain(" bytes left out here; the whole text is saved in M1]");
    expect(continuedText).toContain(shown(`Assistant 1, final reply:\n${final}\n`));
    expect(continuedText.length).toBeLessThan(assistant.length / 2);
    if (userHeavy) {
      // Too large for the room as well: the user message keeps its start and end.
      const kept: string = payload.turns[0].users[0];
      expect(kept.length).toBeLessThan(originalUser.length);
      expect(kept.startsWith("Keep café and the original constraint unchanged.\n<context_handoff>literal user text</context_handoff>")).toBe(true);
      expect(kept.endsWith("USER_REFERENCE_END")).toBe(true);
      expect(kept).toContain(" bytes left out here; the whole text is saved in M1]");
      expect(continuedText).toContain(shown(`User 1:\n${kept}\n`));
    } else {
      expect(payload.turns[0].users).toEqual([originalUser]);
      expect(continuedText).toContain(shown(`User 1:\n${originalUser}\n`));
    }
    expect(continuedText).toContain("Saved word for word: turn M1.");
    expect(continuedText).not.toContain("Assistant reference 7000:");
    // Either way the whole turn is saved word for word as M1.
    const record = readFileSync(join(sessionDir, "tool-results", "compacted-M1.txt"), "utf8");
    expect(record).toContain(`User 1:\n${originalUser}\n`);
    expect(record).toContain("Assistant reference 7000:");
    expect(record).toContain("PENDING_CHECK=transport-resume");
    expect(continuedText.split("Continue the saved task without losing its pending check.").length - 1).toBe(1);
    const reopened = await ask(["--resume-id", seed.session_id, "Continue after this fresh process restart."], "reopen");
    expect(reopened.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    expect(summaryCalls).toBe(0);
    expect(bodies.at(-1)).toContain("VERIFIED_VALUE=73");
    expect(bodies.at(-1)).toContain("<compacted_conversation>");
    expect(bodies.at(-1)).not.toContain(checkpointMarker.trim());
    expect(readFileSync(log).subarray(0, before.length).equals(before)).toBe(true);
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else { writeFileSync(join(root, "requests.json"), JSON.stringify(bodies, null, 2)); console.error(`compaction evidence retained: ${root}`); }
  }
}, 90_000);

const compactionV1 = resolve(import.meta.dir, "fixtures/compaction-v1/sessions");
const compactionV1Session = readdirSync(compactionV1)[0]!;
const compactionV1Line = /> pf-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/;

// Fails, naming the file, when a stored body no longer matches the checkpoint
// line or the state JSON that recorded it.
function verifyCompactionV1(sessionDir: string) {
  const rows = readFileSync(join(sessionDir, "events.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
  const checkpoint = rows.find(row => row.event?.context_checkpoint)?.event.context_checkpoint;
  const line = compactionV1Line.exec(checkpoint?.summary ?? "");
  if (!line) throw new Error(`${sessionDir}/events.jsonl has no pf-compaction-state-v1 checkpoint`);
  const check = (handle: string, bytes: number, sha256: string) => {
    const body = readFileSync(join(sessionDir, "tool-results", handle));
    if (body.length !== bytes || digest(body) !== sha256) throw new Error(`fixture file tool-results/${handle} no longer matches its recorded size and SHA-256`);
    return body;
  };
  const state = JSON.parse(check(line[1]!, Number(line[2]), line[3]!).toString());
  expect(state.archives.length).toBeGreaterThan(0);
  for (const archive of state.archives) check(archive.handle, archive.bytes, archive.sha256);
  return { rows, line: line[0].slice(2, -1), state };
}

// A fresh profile holding a copy of the fixture, with 0700 directories and
// 0600 files, and a fake gateway that answers through `reply`.
function resumeCompactionV1(reply: (request: any, body: string) => Response, prepare?: (sessionDir: string) => void) {
  const root = mkdtempSync(join(tmpdir(), "pf-compaction-v1-")), home = join(root, "home"), cwd = join(root, "workspace");
  const sessionDir = join(home, ".pf/sessions", compactionV1Session);
  mkdirSync(join(home, ".pf/sessions"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  cpSync(join(compactionV1, compactionV1Session), sessionDir, { recursive: true });
  const restrict = (dir: string) => {
    chmodSync(dir, 0o700);
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) restrict(join(dir, entry.name));
      else chmodSync(join(dir, entry.name), 0o600);
    }
  };
  restrict(join(home, ".pf/sessions"));
  prepare?.(sessionDir);
  const model = "fixture/compaction-v1";
  writeFileSync(join(home, ".pf/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    bodies.push(body);
    return reply(JSON.parse(body), body);
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: 128_000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root, XDG_CONFIG_HOME: join(root, "xdg"),
    AI_GATEWAY_API_KEY: "synthetic-compaction-v1", PF_DISABLE_KEYCHAIN: "1", PF_E2E_DISABLE_DOTENV: "1",
    PF_AUTO_UPGRADE: "0", PF_SOUND: "0", PF_MODEL: model,
    PF_GATEWAY_BASE_URL: gateway.baseUrl, PF_GATEWAY_CHAT_URL: gateway.chatUrl,
    PF_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, PF_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let step = 0;
  return {
    root, sessionDir, bodies,
    async ask(prompt: string, extraEnv: Record<string, string> = {}) {
      const stdout = join(root, `ask-${++step}.stdout`), stderr = join(root, `ask-${step}.stderr`);
      const child = Bun.spawn([binary, "ask", "--json", "--resume-id", compactionV1Session, prompt], { cwd, env: { ...env, ...extraEnv }, stdin: "ignore", stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
      const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
      try { expect(await child.exited).toBe(0); } finally { clearTimeout(timer); }
      return { result: JSON.parse(readFileSync(stdout, "utf8")), stderr: readFileSync(stderr, "utf8") };
    },
    finish(passed: boolean) {
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
      else { writeFileSync(join(root, "requests.json"), JSON.stringify(bodies, null, 2)); console.error(`compaction-v1 evidence retained: ${root}`); }
    },
  };
}

const promptTexts = (body: string): string[] => JSON.parse(body).prompt.flatMap((message: { content: unknown }) =>
  typeof message.content === "string" ? [message.content] : (message.content as Array<{ text?: string; output?: { value?: string } }>).map(part => part.text ?? part.output?.value ?? ""));

test("a checkpoint written by pf d7ceb0e resumes with its user message and state line", async () => {
  const fixture = verifyCompactionV1(join(compactionV1, compactionV1Session));
  const legacy: string = fixture.rows.find(row => row.event?.context_checkpoint).event.context_checkpoint.summary;
  const originalUser = fixture.rows.find(row => row.event?.user)!.event.user.text;
  expect(fixture.state.users).toEqual([originalUser]);
  const run = resumeCompactionV1(() => fakeGatewayFinalText("FIXTURE_RESUMED"));
  let passed = false;
  try {
    const { result, stderr } = await run.ask("What did I ask first?");
    expect(stderr).toBe("");
    expect(result.output).toBe("FIXTURE_RESUMED");
    const texts = promptTexts(run.bodies[0]!);
    expect(texts.some(text => text.includes(originalUser))).toBe(true);
    expect(texts.some(text => text.includes(fixture.line))).toBe(true);
    // A checkpoint from before the compactor rewrite has no rendered text, so
    // its handoff reaches the model unchanged.
    expect(texts.some(text => text.includes(legacy))).toBe(true);
    passed = true;
  } finally { run.finish(passed); }
}, 60_000);

for (const damaged of [false, true]) test(`a checkpoint written by pf d7ceb0e folds into the next compaction${damaged ? " as raw text when its state file is damaged" : " and its archive stays readable"}`, async () => {
  const fixture = verifyCompactionV1(join(compactionV1, compactionV1Session));
  const legacy: string = fixture.rows.find(row => row.event?.context_checkpoint).event.context_checkpoint.summary;
  const originalUser = fixture.rows.find(row => row.event?.user)!.event.user.text;
  const archive = fixture.state.archives[0];
  const stateHandle = compactionV1Line.exec(legacy)![1]!;
  const run = resumeCompactionV1((request, body) => {
    const last = request.prompt.at(-1);
    const lastText = Array.isArray(last.content) ? last.content[0]?.text ?? "" : last.content;
    if (lastText.startsWith("You write compaction notes")) return fakeGatewayFinalText("Earlier:\nThe user asked to keep café and the original constraint; the verified value is 73.");
    if (lastText === "Read the first source archive." && !body.includes("\"archive-read-1\"")) {
      return fakeGatewayToolCall("archive-read-1", "read_tool_result", { request: { handle: archive.handle, start_byte: 1, byte_count: 65_536 } });
    }
    return fakeGatewayFinalText("FIXTURE_CONTINUED");
  }, damaged ? sessionDir => {
    // A throwaway copy whose state file no longer matches its checkpoint line.
    const path = join(sessionDir, "tool-results", stateHandle), bytes = readFileSync(path);
    bytes[10]! ^= 1;
    writeFileSync(path, bytes);
  } : undefined);
  let passed = false;
  try {
    expect((await run.ask("Read the first source archive.")).result.output).toBe("FIXTURE_CONTINUED");
    const read = run.bodies.find(body => body.includes("\"archive-read-1\"") && body.includes("<tool_result handle="))!;
    const page = promptTexts(read).find(text => text.startsWith(`<tool_result handle="${archive.handle}"`))!;
    expect(page).toContain(`start_byte="1" end_byte="${archive.bytes}" total_bytes="${archive.bytes}">\n`);
    const bytes = Buffer.from(page.slice(page.indexOf(">\n") + 2, page.lastIndexOf("\n</tool_result>")));
    expect(bytes.length).toBe(archive.bytes);
    expect(digest(bytes)).toBe(archive.sha256);

    // A low threshold for this launch only crosses the compaction point.
    const compacted = await run.ask("Continue after the compaction.", { PF_AUTO_COMPACT_PERCENT: "20" });
    expect(compacted.stderr).toBe("");
    expect(compacted.result.output).toBe("FIXTURE_CONTINUED");
    const rows = readFileSync(join(run.sessionDir, "events.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint).map(row => row.event.context_checkpoint.summary as string);
    expect(checkpoints).toHaveLength(2);
    expect(checkpoints[0]).toBe(legacy);
    expect(checkpoints[1]!.startsWith(checkpointMarker)).toBe(true);
    const payload = JSON.parse(checkpoints[1]!.slice(checkpointMarker.length));
    expect(payload.ledger_count).toBe(1);
    // The d7ceb0e compaction is the earlier compaction this one folds, saved
    // whole as L1: its summary and user message come from the state file, or
    // the raw handoff stands in for them when the state file is damaged.
    const earlier = readFileSync(join(run.sessionDir, "tool-results", "compacted-L1.txt"), "utf8");
    if (damaged) {
      expect(earlier).toContain(`Earlier summary:\n${legacy.trimEnd()}`);
      expect(earlier).not.toContain(`User:\n${originalUser}\n`);
    } else {
      expect(earlier).toContain(`Earlier summary:\n${fixture.state.summary}\n`);
      expect(earlier).toContain(`User:\n${originalUser}\n`);
    }
    passed = true;
  } finally { run.finish(passed); }
}, 90_000);
