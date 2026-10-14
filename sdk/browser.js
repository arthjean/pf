import { createDurableAgentFactory, memory } from "./durable.js";
import { pfHarness } from "./pf-harness.js";
import {
  createPfEngine as createWasmAgent,
  createPfTerminal as createWasmTerminal,
  createMemoryPersistence,
  PfFencedError,
  PfJournalVersionError,
  encodeXtermKeyEvent,
  pfSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./pf-sdk.js";

export { createMemoryPersistence, encodeXtermKeyEvent, PfFencedError, PfJournalVersionError, pfSdkApiVersion, listModels, memory, supportsJspi, xtermAdapter };
export const libpfApiVersion = 3;

const defaultCoreWasm = new URL("./pf-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./pf-term.wasm", import.meta.url).href;

/** One pf session on WebAssembly, with no durability of its own. */
export function createPfEngine(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

/** An agent whose sessions live in this page unless `durability` says otherwise. */
export const createPfAgent = createDurableAgentFactory({
  name: "createPfAgent",
  label: "pf agent",
  defaultDurability: async () => memory(),
  harness: pfHarness({ createEngine: createPfEngine }),
});

export function createPfTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
