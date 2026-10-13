// A real xterm `Terminal` fits `xtermAdapter()`. Checked only when the
// headless terminal suite's dependencies are installed (`npm ci --prefix sdk/node`).
import { Terminal } from "@xterm/headless";
import { createPfTerminal, xtermAdapter } from "libpf/browser";

export async function run(): Promise<void> {
  const term = new Terminal({ cols: 100, rows: 30, allowProposedApi: true });
  const runtime = await createPfTerminal({ terminal: xtermAdapter(term), wasm: "/pf-term.wasm" });
  await runtime.interactive;
  runtime.abort();
}
