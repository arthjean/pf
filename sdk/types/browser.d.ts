// `libpf` in browsers and other non-Node hosts, and `libpf/browser` (browser.js).
import type {
  PfAgent,
  PfAgentOptions,
  PfBrowserBackendOptions,
  PfEngine,
  PfEngineOptions,
  PfTerminal,
  PfTerminalOptions,
} from "./libpf.cjs";

export {
  createMemoryPersistence,
  encodeXtermKeyEvent,
  PfFencedError,
  PfJournalVersionError,
  pfSdkApiVersion,
  listModels,
  memory,
  supportsJspi,
  xtermAdapter,
} from "./libpf.cjs";

export type {
  Durability,
  PfAccepted,
  PfAgent,
  PfAgentEvent,
  PfAgentHostTool,
  PfAgentKeyedTool,
  PfAgentOptions,
  PfAgentTool,
  PfAgentTools,
  PfApiKeyCredentials,
  PfBrowserBackendOptions,
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
  PfIdleResult,
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
  PfPromptOptions,
  PfProviderCredentials,
  PfProviderTool,
  PfResizedImage,
  PfResourceBlock,
  PfResumeOptions,
  PfResumeTurn,
  PfSession,
  PfSessionEvent,
  PfSessionImageBlock,
  PfSessionOptions,
  PfSessionPromptInput,
  PfSessionTurnEvent,
  PfSharedOptions,
  PfSteer,
  PfSteeringInput,
  PfStopReason,
  PfStreamLine,
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
  PfTurn,
  PfTurnEvent,
  PfTurnResult,
  PfTurnView,
  PfUsage,
  PfWasmModule,
  PfWasmSource,
  PfWorkspace,
  PfWorkspaceExecResult,
  PfXtermLike,
  JournalRecord,
  JsonObject,
  JsonValue,
  MemoryOptions,
  MemoryPersistence,
  Persistence,
  PersistenceLoadResult,
} from "./libpf.cjs";

/** Options for `createPfAgent()` in browsers. */
export type PfBrowserAgentOptions = PfAgentOptions & PfBrowserBackendOptions;

/** Options for `createPfEngine()` in browsers. */
export type PfBrowserEngineOptions = PfEngineOptions & PfBrowserBackendOptions;

/** Options for `createPfTerminal()` in browsers. */
export type PfBrowserTerminalOptions = PfTerminalOptions & PfBrowserBackendOptions;

/**
 * An agent whose sessions live in this page unless `durability` says
 * otherwise. It returns at once and does no I/O until a session runs a turn.
 */
export declare function createPfAgent(options?: PfBrowserAgentOptions): PfAgent;

/** One pf session on WebAssembly, with no durability of its own. `apiKey` is required. */
export declare function createPfEngine(options: PfBrowserEngineOptions): Promise<PfEngine>;

/** The interactive terminal harness. Connect it to xterm.js with `xtermAdapter()`. */
export declare function createPfTerminal(options: PfBrowserTerminalOptions): Promise<PfTerminal>;

/** The version of the libpf agent API. */
export declare const libpfApiVersion: 3;
