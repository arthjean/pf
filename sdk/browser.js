import {
  createPfAgent as createWasmAgent,
  createPfTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  pfSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./pf-sdk.js";

export { encodeXtermKeyEvent, pfSdkApiVersion, listModels, supportsJspi, xtermAdapter };
export const libpfApiVersion = 2;

const defaultCoreWasm = new URL("./pf-core.wasm", import.meta.url).href;
const defaultTermWasm = new URL("./pf-term.wasm", import.meta.url).href;

export function createPfAgent(options = {}) {
  return createWasmAgent({ ...options, wasm: options.wasm ?? defaultCoreWasm });
}

export function createPfTerminal(options = {}) {
  return createWasmTerminal({ ...options, wasm: options.wasm ?? defaultTermWasm });
}
