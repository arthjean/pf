// `libpf` and `libpf/node` on Node.js, for `require` (node.cjs). The ESM entry,
// node.d.ts, re-exports this file: node.cjs is built from node.js.
import type {
  PfAgent,
  PfAgentOptions,
  PfBackendInfo,
  PfBackendInfoOptions,
  PfEngine,
  PfEngineOptions,
  PfNodeBackendOptions,
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
  wakeHandler,
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
  PfBackendAttempt,
  PfBackendChoice,
  PfBackendInfo,
  PfBackendInfoOptions,
  PfBackendReason,
  PfBackendReasonCode,
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
  PfNodeBackendOptions,
  PfNodeWasmSource,
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

/** Options for `createPfAgent()` on Node.js. */
export type PfNodeAgentOptions = PfAgentOptions & PfNodeBackendOptions;

/** Options for `createPfEngine()` on Node.js. */
export type PfNodeEngineOptions = PfEngineOptions & PfNodeBackendOptions;

/** Options for `createPfTerminal()` on Node.js. */
export type PfNodeTerminalOptions = PfTerminalOptions & PfNodeBackendOptions;

/**
 * An agent whose sessions survive crashes, timeouts, and redeployments. It
 * returns at once and does no I/O until a session runs a turn. Without
 * `durability`, sessions live in Vercel's World on Vercel and in local files
 * elsewhere.
 */
export declare function createPfAgent(options?: PfNodeAgentOptions): PfAgent;

/**
 * The kernel under `createPfAgent()`: one conversation, held in the memory of
 * the process that runs it. `apiKey` is required, and it resolves once its
 * backend has loaded.
 */
export declare function createPfEngine(options: PfNodeEngineOptions): Promise<PfEngine>;

/** The interactive terminal harness. */
export declare function createPfTerminal(options: PfNodeTerminalOptions): Promise<PfTerminal>;

/** Inspects backend availability without creating an agent or terminal. */
export declare function getBackendInfo(options?: PfBackendInfoOptions): Promise<PfBackendInfo>;

/** The version of the libpf agent API. */
export declare const libpfApiVersion: 3;
