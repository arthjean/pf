// `libpf/wasm` (pf-sdk.js): the WebAssembly SDK with no packaged asset paths,
// so every factory takes its `wasm` explicitly.
import type { PfEngine, PfEngineOptions, PfTerminal, PfTerminalOptions, PfWasmSource } from "./libpf.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  PfFencedError,
  PfJournalVersionError,
  pfSdkApiVersion,
  listModels,
  supportsJspi,
  xtermAdapter,
} from "./libpf.cjs";

export type {
  PfApiKeyCredentials,
  PfBytes,
  PfCheckpointMeta,
  PfCodexProvider,
  PfCustomProvider,
  PfCustomProviderDefinition,
  PfCustomProviderModel,
  PfEffort,
  PfEngine,
  PfEngineEvent,
  PfEngineOptions,
  PfEnginePromptOptions,
  PfEngineStorage,
  PfEngineTurn,
  PfEngineTurnResult,
  PfErrorSummary,
  PfFetch,
  PfFollowUp,
  PfGatewayProvider,
  PfGrokProvider,
  PfHostTool,
  PfImageBlock,
  PfJsonSchema,
  PfKeyedTool,
  PfKeyEventLike,
  PfListModelsOptions,
  PfModelCatalogEntry,
  PfModelChoice,
  PfModelOptions,
  PfOnAmbiguous,
  PfPromptBlock,
  PfPromptInput,
  PfProviderCredentials,
  PfProviderTool,
  PfResizedImage,
  PfResourceBlock,
  PfResumeOptions,
  PfSharedOptions,
  PfSteer,
  PfSteeringInput,
  PfStopReason,
  PfTerminal,
  PfTerminalAdapter,
  PfTerminalEvent,
  PfTerminalOptions,
  PfTextBlock,
  PfTool,
  PfToolContext,
  PfToolImage,
  PfToolResult,
  PfTools,
  PfTurnEvent,
  PfUsage,
  PfWasmModule,
  PfWasmSource,
  PfWorkspace,
  PfWorkspaceExecResult,
  PfXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libpf.cjs";

/** Options for `createPfEngine()` from `libpf/wasm`. */
export type PfWasmEngineOptions = PfEngineOptions & {
  /** The `pf-core.wasm` asset. */
  wasm: PfWasmSource;
};

/** Options for `createPfTerminal()` from `libpf/wasm`. */
export type PfWasmTerminalOptions = PfTerminalOptions & {
  /** The `pf-term.wasm` asset. */
  wasm: PfWasmSource;
};

/** One session on one pf core, with no durability of its own. Requires JSPI. */
export declare function createPfEngine(options: PfWasmEngineOptions): Promise<PfEngine>;

/** The interactive terminal harness on WebAssembly. Requires JSPI. */
export declare function createPfTerminal(options: PfWasmTerminalOptions): Promise<PfTerminal>;
