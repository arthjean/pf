// The browser entry and `libpf/wasm`: agents on this page, the terminal
// harness with xterm.js, and the WebAssembly SDK with explicit assets.
import {
  createPfAgent,
  createPfEngine,
  createPfTerminal,
  encodeXtermKeyEvent,
  libpfApiVersion,
  memory,
  supportsJspi,
  xtermAdapter,
  type PfTerminal,
  type PfWorkspace,
  type PfXtermLike,
} from "libpf/browser";
// @ts-expect-error getBackendInfo() is Node.js only
import { getBackendInfo } from "libpf/browser";
import * as wasm from "libpf/wasm";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const term: PfXtermLike & { focus(): void };

// README "Interactive terminal".
export async function terminal(): Promise<PfTerminal> {
  const runtime = await createPfTerminal({
    terminal: xtermAdapter(term),
    env: { AI_GATEWAY_API_KEY: "<short-lived credential>" },
  });
  await runtime.interactive;
  const code = await runtime.exited;
  assertType<Equal<typeof code, number>>();
  runtime.write("hello\r");
  runtime.resize();
  runtime.abort();

  const workspace = {
    info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
    permission: "allow-sandboxed",
    exec({ command, cwd, signal, timeoutMs, outputLimitBytes }) {
      return { exitCode: signal.aborted ? 130 : 0, stdout: `${command} ${cwd} ${timeoutMs} ${outputLimitBytes}`, stderr: "" };
    },
    async readFile({ path, signal }) {
      return signal.aborted || !path.endsWith("/AGENTS.md") ? null : new TextEncoder().encode("# Rules");
    },
  } satisfies PfWorkspace;

  await createPfTerminal({
    terminal: xtermAdapter(term),
    args: ["--fast"],
    workspace,
    clipboard: { writeText: (text) => navigator.clipboard.writeText(text) },
    openUrl: (url) => window.open(url) !== null,
    onEvent: (event) => console.log(event.type, event.timestamp),
    wasm: "/pf-term.wasm",
  });

  // @ts-expect-error a terminal needs its terminal adapter
  await createPfTerminal({ env: {} });
  // @ts-expect-error workspace version 1 is non-git
  await createPfTerminal({ terminal: xtermAdapter(term), workspace: { ...workspace, info: { ...workspace.info, gitAvailable: true } } });

  return runtime;
}

export function keys(event: KeyboardEvent): string | null {
  return encodeXtermKeyEvent(event);
}

export async function agents(): Promise<void> {
  assertType<Equal<typeof libpfApiVersion, 2>>();
  if (!supportsJspi()) return;
  const agent = createPfAgent({ apiKey: "<short-lived credential>", durability: memory() });
  const turn = agent.session().prompt("Hello");
  for await (const event of turn) if (event.type === "text_delta") console.log(event.delta);
  await agent.close();

  createPfAgent({ wasm: fetch("/pf-core.wasm") });
  const engine = await createPfEngine({ apiKey: "<short-lived credential>", wasm: await WebAssembly.compileStreaming(fetch("/pf-core.wasm")) });
  await engine.close();

  // @ts-expect-error backend selection is Node.js only
  createPfAgent({ backend: "native" });
  // @ts-expect-error nativeAddon is Node.js only
  createPfAgent({ nativeAddon: false });
}

export async function wasmEntry(): Promise<void> {
  const engine = await wasm.createPfEngine({ apiKey: "<short-lived credential>", wasm: "https://cdn.example.com/pf-core.wasm" });
  const result = await engine.prompt("Hello").result;
  console.log(result.stopReason, result.usage.outputTokens);
  await wasm.createPfTerminal({ terminal: wasm.xtermAdapter(term), wasm: new ArrayBuffer(8) });
  const persistence = wasm.createMemoryPersistence();
  await wasm.createPfEngine({ apiKey: "k", wasm: "/pf-core.wasm", persistence });
  console.log(wasm.pfSdkApiVersion, wasm.supportsJspi(), await wasm.listModels({ apiKey: "k" }));

  // @ts-expect-error libpf/wasm needs an explicit wasm asset
  await wasm.createPfEngine({ apiKey: "k" });
  // @ts-expect-error libpf/wasm has no durable agent
  wasm.createPfAgent();
  // @ts-expect-error libpf/wasm has no memory() durability
  wasm.memory();
}

void getBackendInfo;
