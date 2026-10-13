// Declarations shared by every libpf entry point. This file is not an entry
// point: import from "libpf" or one of its subpaths. Each entry's own file
// re-exports the part of it that entry has at runtime.

export {};

// ---------------------------------------------------------------------------
// Basics

/** A value that survives `JSON.stringify()` and `JSON.parse()`. */
export type JsonValue = string | number | boolean | null | readonly JsonValue[] | JsonObject;

/** A JSON object. A key whose value is `undefined` is dropped when serialized. */
export type JsonObject = { readonly [key: string]: JsonValue | undefined };

/** A JSON Schema object, such as a tool's input schema. */
export type PfJsonSchema = { readonly [key: string]: any };

/** Bytes: an `ArrayBuffer`, a typed array such as `Uint8Array` or `Buffer`, or a `DataView`. */
export type PfBytes = ArrayBuffer | ArrayBufferView;

/** `WebAssembly.Module` where the host's TypeScript lib declares it, and `never` where it does not. */
export type PfWasmModule = typeof globalThis extends { WebAssembly: { Module: abstract new (...args: any[]) => infer Module } } ? Module : never;

/** The `fetch` libpf calls: always with a URL string and an init object. The global `fetch` fits. */
export type PfFetch = (input: string, init: RequestInit) => Promise<Response>;

/** An error as libpf reports it in results and events. */
export interface PfErrorSummary {
  name: string;
  message: string;
  code?: string | number;
}

// ---------------------------------------------------------------------------
// Models

/** A reasoning effort: `"default"` leaves the choice to the model; a named level requests that level. */
export type PfEffort = "default" | "low" | "medium" | "high" | "xhigh" | (string & {});

/** Model configuration: the model ID and model-specific options. */
export interface PfModelOptions {
  /** The model ID, such as `"anthropic/claude-haiku-4.5"`. */
  id: string;
  /** The reasoning effort, for models that advertise effort levels. A named level is validated at creation. */
  effort?: PfEffort;
  /** Enables the fast lane for models that advertise one. */
  fast?: boolean;
  /** Requests Ultra mode, the higher-cost service tier, for models whose metadata advertises it. Disables Fast. */
  ultrafast?: boolean;
}

/** A model option: a model object, or a model ID string with the deprecated top-level options. Top-level options cannot be mixed with a model object. */
export type PfModelChoice =
  | {
    /** The model ID and its options. */
    model: PfModelOptions;
    effort?: never;
    fast?: never;
    ultrafast?: never;
  }
  | {
    /** The model ID. Defaults to pf's built-in model. */
    model?: string | undefined;
    /** @deprecated Use `model: { id, effort }`. */
    effort?: PfEffort;
    /** @deprecated Use `model: { id, fast }`. */
    fast?: boolean;
    /** @deprecated Use `model: { id, ultrafast }`. */
    ultrafast?: boolean;
  };

/** An entry from `https://ai-gateway.vercel.sh/coding-agent/v1/models`. */
export interface PfModelCatalogEntry {
  id: string;
  [key: string]: unknown;
}

/** Options for `listModels()`. */
export interface PfListModelsOptions {
  /** The AI Gateway credential. */
  apiKey: string;
  /** Replaces the global `fetch` for the catalog request. */
  fetch?: PfFetch;
}

// ---------------------------------------------------------------------------
// Prompt input

/** A text block. */
export interface PfTextBlock {
  type: "text";
  text: string;
}

/** A resource block: a URI with optional text, given directly or under `resource`. */
export type PfResourceBlock =
  | { type: "resource"; resource: { uri: string; text?: string } }
  | { type: "resource"; uri: string; text?: string };

/**
 * An image block: a `Blob` or `File` with a non-empty `type`, raw bytes or
 * canonical base64 with an explicit `mimeType`, or only a `sourceRef` that
 * names a host-owned original. The payload must be PNG, JPEG, GIF, or WebP.
 */
export type PfImageBlock =
  | { type: "image"; data: Blob; mimeType?: string; sourceRef?: string }
  | { type: "image"; data: string | PfBytes; mimeType: string; sourceRef?: string }
  | { type: "image"; data?: undefined; mimeType: string; sourceRef: string };

/** One prompt block. */
export type PfPromptBlock = PfTextBlock | PfImageBlock | PfResourceBlock;

/** Prompt input: a string, or text, image, and resource blocks. */
export type PfPromptInput = string | readonly PfPromptBlock[];

/** An image block in a durable session's prompt: base64 data, or only a `sourceRef`. */
export type PfSessionImageBlock =
  | { type: "image"; data: string; mimeType: string; sourceRef?: string }
  | { type: "image"; data?: undefined; mimeType: string; sourceRef: string };

/** A durable session's prompt input. Image data must be a base64 string, because the prompt is stored as JSON before it runs. */
export type PfSessionPromptInput = string | readonly (PfTextBlock | PfSessionImageBlock | PfResourceBlock)[];

/** Steering or follow-up input: a string or text blocks. */
export type PfSteeringInput = string | readonly PfTextBlock[];

/** What `resizeImage` returns: any bytes and their MIME type. */
export interface PfResizedImage {
  bytes: PfBytes;
  mimeType: string;
}

// ---------------------------------------------------------------------------
// Tools

/** What a tool's `execute()` receives beside its input. */
export interface PfToolContext {
  /** Aborts when the turn is cancelled. */
  signal: AbortSignal;
  /** The model's id for the call. It stays the same when the call runs again after a crash. */
  executionId: string;
  /** The session the call belongs to. */
  sessionId: string;
  /** The JSON passed as `context` to the `session()` call whose prompt or steer started the turn. */
  context?: JsonValue;
}

/** An image in a typed tool result: base64 `data`, or a `sourceRef` with no `data`. */
export type PfToolImage =
  | { type: "image"; mimeType: string; data: string; sourceRef?: string }
  | { type: "image"; mimeType: string; data?: undefined; sourceRef: string };

/** A typed tool result that returns rich image content. Ordinary values returned by tools are JSON text. */
export interface PfToolResult {
  type: "libpf.tool-result";
  text: string;
  /** Up to 8 images. */
  images: readonly PfToolImage[];
  /** Reports the result as a tool error. */
  isError?: boolean;
}

/** A tool the JavaScript host runs. */
export interface PfHostTool<Input = any> {
  /** 1 to 64 letters, digits, `_`, or `-`. */
  name: string;
  description: string;
  /** A JSON Schema object for the tool's input. */
  inputSchema: PfJsonSchema;
  /** Runs one call. A string is sent as is, an `PfToolResult` as rich content, and any other value as JSON text. */
  execute: (input: Input, context: PfToolContext) => unknown;
  /** Running a call twice is safe, so a call cut off by a crash runs again. */
  idempotent?: boolean;
  /** Calls must not overlap others: one starts after every earlier call in the response finishes. */
  writes?: boolean;
  providerExecuted?: false;
}

/** A tool the provider runs, such as Gateway web search. `web_search` is currently the supported name. */
export interface PfProviderTool {
  name: "web_search";
  providerExecuted: true;
  execute?: never;
}

/** A tool descriptor. */
export type PfTool = PfHostTool | PfProviderTool;

/** A tool descriptor in an object keyed by tool name. A descriptor that includes `name` must match its key. */
export type PfKeyedTool =
  | (Omit<PfHostTool, "name"> & { name?: string })
  | (Omit<PfProviderTool, "name"> & { name?: "web_search" });

/** At most 64 tools: an array of descriptors, or an object keyed by tool name. */
export type PfTools = readonly PfTool[] | { readonly [name: string]: PfKeyedTool };

// ---------------------------------------------------------------------------
// Turn events and results

/** A model or tool event of a turn. */
export type PfTurnEvent =
  | { type: "text_delta"; delta: string }
  | { type: "reasoning_delta"; delta: string }
  /** Accepted mid-turn steering entering the turn. */
  | { type: "user_message"; text: string }
  | { type: "tool_start"; id: string; name: string; input?: JsonValue; inputTruncated?: undefined; inputPreview?: undefined }
  /** A tool input over 64 KiB of JSON arrives as a prefix. The tool still receives complete arguments. */
  | { type: "tool_start"; id: string; name: string; input?: undefined; inputTruncated: true; inputPreview: string }
  | { type: "tool_end"; id: string; name: string; content?: string; isError: boolean };

/** Token usage. Each count is present when the provider reported it. */
export interface PfUsage {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  reasoningTokens?: number;
}

/** Why an engine turn ended. */
export type PfStopReason = "end_turn" | "max_output_tokens" | "max_model_turns" | "refused" | "cancelled";

// ---------------------------------------------------------------------------
// Diagnostics

interface PfEventBase {
  /** `performance.now()` when the event was emitted. */
  timestamp: number;
}

/** The libpf version, tool set, and model a checkpoint records. */
export interface PfCheckpointMeta {
  libpfVersion: string;
  toolSchemaHash: string;
  model: string;
}

/** A runtime diagnostic an engine passes to `onEvent`, separate from model output. */
export type PfEngineEvent = PfEventBase & (
  | { type: "runtime.start" }
  | { type: "runtime.ready" }
  | { type: "runtime.exit"; code: number }
  | { type: "acp.send"; message: unknown }
  | { type: "acp.receive"; message: unknown }
  | { type: "transport.start"; attempt: number; method: string; endpoint: string; model: string | undefined }
  | {
    type: "transport.response";
    attempt: number;
    status: number;
    elapsedMs: number;
    requestId: string | null;
    generationId: string | null;
    model: string | undefined;
    provider: string | null;
  }
  | { type: "transport.error"; attempt: number; elapsedMs: number; error: string }
  | { type: "transport.retry"; attempt: number; nextAttempt: number; elapsedMs: number; error: string }
  /** Liveness while a response body streams, at most once per 250 ms. */
  | { type: "transport.activity"; attempt: number; chunkBytes: number; totalBytes: number }
  | { type: "permission.request"; request: unknown }
  | { type: "permission.resolve"; optionId: unknown }
  | { type: "journal.open"; events: number; checkpoint: boolean; turns: unknown; resumable: boolean }
  | { type: "journal.append"; events: number }
  | { type: "journal.error"; error: string }
  | { type: "checkpoint.save"; through: string; bytes: number }
  | { type: "checkpoint.error"; error: string; message: string }
  /** A checkpoint saved under a different libpf version, tool set, or model still loaded. */
  | { type: "checkpoint.mismatch"; sessionId: string; changed: Array<keyof PfCheckpointMeta>; saved: unknown; current: PfCheckpointMeta }
  | { type: "output.backpressure"; bufferedBytes: number; bufferedEvents: number }
  | { type: "output.discarded"; reason: "cancelled"; bytes: number }
);

/** A durable session's diagnostic: a failed write or engine, a takeover, or a function deadline. */
export type PfSessionEvent = PfEventBase & (
  | { type: "session.error"; sessionId: string; error: PfErrorSummary }
  | { type: "session.fenced"; sessionId: string; epoch: number }
  /** `cutoffs`: the times in a row the deadline cut off the same step, this one included. */
  | { type: "session.deadline"; sessionId: string; epoch: number; cutoffs: number }
  | { type: "ui.error"; sessionId: string; error: string }
);

/** What an agent passes to `onEvent`: its engines' diagnostics and its sessions'. */
export type PfAgentEvent = PfEngineEvent | PfSessionEvent;

// ---------------------------------------------------------------------------
// Options shared by agents and engines

/** Options `createPfAgent()` and `createPfEngine()` share. */
export interface PfSharedOptions<Event> {
  /** The complete host-owned system context, up to 64 KiB of UTF-8. An array is joined with blank lines. */
  instructions?: string | readonly string[];
  tools?: PfTools;
  /** Replaces the global `fetch` for model and catalog requests. */
  fetch?: PfFetch;
  /** The Gateway model catalog, as the response's `{ data }` or the entries alone, so the agent makes no catalog request. */
  modelCatalog?: readonly PfModelCatalogEntry[] | { readonly data: readonly PfModelCatalogEntry[] };
  /** Downscales or converts prompt images before they are sent. */
  resizeImage?: (image: { bytes: Uint8Array; mimeType: string }) => PfResizedImage | Promise<PfResizedImage>;
  /** Trusted host configuration: the canonical Gateway or an explicit loopback HTTP URL. */
  gatewayChatUrl?: string;
  /** Receives runtime diagnostics separately from model output. */
  onEvent?: (event: Event) => void;
}

/** Where a Node.js factory's backend comes from. */
export type PfBackendChoice = "auto" | "native" | "wasm";

/** A Wasm asset in browsers and on `libpf/wasm`: a URL string, a `Response`, bytes, a compiled module, or a promise of one of the last three. */
export type PfWasmSource = string | Response | PfBytes | PfWasmModule | Promise<Response | PfBytes | PfWasmModule>;

/** A Wasm asset on Node.js: a path, a URL, a `Response`, bytes, a compiled module, or a promise of an HTTP(S) URL string, a `Response`, bytes, or a module. */
export type PfNodeWasmSource = string | URL | Response | PfBytes | PfWasmModule | Promise<string | Response | PfBytes | PfWasmModule>;

/** Backend selection on Node.js. */
export interface PfNodeBackendOptions {
  /** `"auto"` tries the native addon, then Wasm; `"native"` requires N-API; `"wasm"` requires Wasm and JSPI. */
  backend?: PfBackendChoice;
  /** Trusted host configuration: the native addon module, its path or URL, or `false` to disable native loading. */
  nativeAddon?: string | URL | false | object;
  /** The Wasm asset to use instead of the packaged one. */
  wasm?: PfNodeWasmSource;
}

/** Wasm asset selection in browsers. */
export interface PfBrowserBackendOptions {
  /** The Wasm asset to use instead of the packaged one. */
  wasm?: PfWasmSource;
}

// ---------------------------------------------------------------------------
// Persistence

/** One stored record of a session's journal. */
export interface JournalRecord {
  cursor: string;
  data: Uint8Array;
}

/** What `Persistence.load()` resolves to: the latest checkpoint, if any, and the records stored after it, oldest first. */
export interface PersistenceLoadResult {
  checkpoint?: { data: PfBytes; through: string };
  journal?: Iterable<{ cursor: string; data: PfBytes }> | AsyncIterable<{ cursor: string; data: PfBytes }>;
}

/** A store for one session's records and checkpoints. libpf writes opaque bytes; the store never parses them. */
export interface Persistence {
  /** Called once by `createPfEngine()`. Resolve to `{}` for a session with nothing stored. */
  load(): Promise<PersistenceLoadResult>;
  /** Stores one record and resolves to its cursor. Reject with an `PfFencedError` when `expected` is not the last stored record's cursor. */
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array }): Promise<{ cursor: string }>;
  /** Stores a checkpoint covering the records through `through`. */
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>;
}

/** The persistence store `createMemoryPersistence()` returns. */
export interface MemoryPersistence extends Persistence {
  /** The stored records, oldest first. */
  readonly records: Array<JournalRecord & { idempotencyKey: string }>;
  /** The latest checkpoint, or null. */
  readonly checkpoint: { through: string; data: Uint8Array } | null;
  load(): Promise<{ checkpoint?: { data: Uint8Array; through: string }; journal: JournalRecord[] }>;
  saveCheckpoint(input: { through: string; data: Uint8Array }): Promise<void>;
}

/** Another writer took over the session after this agent loaded it. Its `code` is `PF_FENCED`. */
export declare class PfFencedError extends Error {
  constructor(message?: string);
  name: "PfFencedError";
  code: "PF_FENCED";
}

/** The journal was written by a newer libpf than this one. Its `code` is `PF_JOURNAL_VERSION`. */
export declare class PfJournalVersionError extends Error {
  constructor(message?: string);
  name: "PfJournalVersionError";
  code: "PF_JOURNAL_VERSION";
}

/** A persistence store that keeps the records and the latest checkpoint in memory, for tests and hosts that copy them to their own storage. */
export declare function createMemoryPersistence(): MemoryPersistence;

// ---------------------------------------------------------------------------
// A single engine

/** Called once for each call a resumed turn left running. Return `"rerun"` to run it again under the same `executionId`. */
export type PfOnAmbiguous = (call: { executionId: string; name: string; input: unknown }) => "rerun" | undefined | void;

/** Options for an engine's `prompt()`. */
export interface PfEnginePromptOptions {
  /** Cancels the turn when it aborts. */
  signal?: AbortSignal;
  /** The turn's id, so a retried prompt continues or answers the same turn. 1 to 128 letters, digits, `.`, `_`, or `-`. */
  turnId?: string;
  onAmbiguous?: PfOnAmbiguous;
}

/** Options for an engine's `resume()`. */
export interface PfResumeOptions {
  signal?: AbortSignal;
  onAmbiguous?: PfOnAmbiguous;
}

/** How an engine turn ended. */
export interface PfEngineTurnResult {
  stopReason: PfStopReason;
  usage: PfUsage;
}

/** A steer: resolves to `{ id }` once accepted, and carries the same `id` at once. */
export type PfSteer = Promise<{ id: string; withdrawn?: true }> & { readonly id: string };

/** One engine turn: an async iterable of its events with one consumer. Breaking out of the iterator cancels the turn. */
export interface PfEngineTurn {
  /** The turn's id. */
  readonly id: string | null;
  readonly result: Promise<PfEngineTurnResult>;
  /** Stops the turn. `{ reason: "handoff" }` stores nothing more, so the next agent continues it; it needs persistence. */
  cancel(options?: { reason?: "handoff" }): void;
  /** Appends guidance at the next safe model boundary. */
  steer(input: PfSteeringInput, id?: string): PfSteer;
  /** Takes a steer back before the model sees it. */
  withdraw(id: string): Promise<"withdrawn" | "already_placed">;
  [Symbol.asyncIterator](): AsyncIterator<PfTurnEvent>;
}

/** A follow-up: a promise for its turn that carries its `id` and `accepted`, which resolves `{ id }` once it is stored. */
export type PfFollowUp = Promise<PfEngineTurn> & { readonly id: string; readonly accepted: Promise<{ id: string }> };

/** One conversation held in the memory of the process that runs it, with no queue and no session store. */
export interface PfEngine {
  /** The id the engine uses for AI Gateway session affinity and prompt caching. */
  readonly sessionId: string;
  /** Starts a turn. Only one top-level prompt may run at a time. */
  prompt(input: PfPromptInput, options?: PfEnginePromptOptions): PfEngineTurn;
  /** Continues the turn the last process left open, or the next held follow-up; null when there is none. */
  resume(options?: PfResumeOptions): PfEngineTurn | null;
  /** Queues text to run as its own turn once the current turn ends, or at once when none is running. */
  followUp(input: PfSteeringInput): PfFollowUp;
  /** The conversation as opaque, bounded, versioned bytes, when no prompt is running. */
  checkpoint(): Promise<Uint8Array>;
  close(): Promise<void>;
}

/** Where an engine keeps its conversation: a persistence store, or a checkpoint to start from. The two cannot be combined. */
export type PfEngineStorage =
  | {
    /** Records the session as it runs, so a new engine can continue it. */
    persistence: Persistence;
    /** Record bytes since the last checkpoint after which a checkpoint is saved. Default 1 MiB. */
    checkpointAfterBytes?: number;
    checkpoint?: undefined;
  }
  | {
    persistence?: undefined;
    checkpointAfterBytes?: undefined;
    /** Checkpoint bytes to restore. */
    checkpoint?: PfBytes;
  };

/** Options for `createPfEngine()`. */
export type PfEngineOptions = PfSharedOptions<PfEngineEvent> & PfModelChoice & PfEngineStorage & {
  /** The AI Gateway credential. Required. */
  apiKey: string;
  /** The id for AI Gateway session affinity: 1 to 255 letters, digits, `.`, `_`, or `-`. Give a restored session the id it had before. */
  sessionId?: string | null;
};

// ---------------------------------------------------------------------------
// Durability

declare const durabilityBrand: unique symbol;

/** Where an agent's sessions live: `memory()`, or `local()`, `vercel()`, or `world()`. */
export interface Durability {
  readonly [durabilityBrand]: true;
}

/** Options for `memory()`. */
export interface MemoryOptions {
  /** Each delivery runs as if its function stopped after this long. No limit by default. */
  maxDurationMs?: number;
  /** How long before the deadline each delivery stops. Default 30000. */
  reserveMs?: number;
}

/** The durability that keeps sessions in this process only. Nothing survives the process. */
export declare function memory(options?: MemoryOptions): Durability;

// ---------------------------------------------------------------------------
// Durable agents

/** Options for `createPfAgent()`. */
export type PfAgentOptions = PfSharedOptions<PfAgentEvent> & PfModelChoice & {
  /** The AI Gateway credential. Without it, libpf uses `AI_GATEWAY_API_KEY`, then on Vercel the deployment's OIDC token. */
  apiKey?: string | undefined;
  /** Where sessions live. Without it, libpf picks one from the environment. */
  durability?: Durability | undefined;
  /** Checkpoint bytes the agent's new sessions start from. */
  checkpoint?: PfBytes;
};

/** Options for `agent.session()`. Each applies to the turns this session object starts. */
export interface PfSessionOptions {
  /** JSON every tool call of those turns receives as `context`. */
  context?: JsonValue;
  /** The model for those turns instead of the agent's whole model choice: a model ID, or a model object. */
  model?: string | PfModelOptions;
  /** The system context for those turns instead of the agent's. An array is joined with blank lines. */
  instructions?: string | readonly string[];
}

/** Options for a durable session's `prompt()`. */
export interface PfPromptOptions {
  /** The turn's id, so a retried request reaches the same turn. Follows the session id rule. */
  messageId?: string;
  /** Cancels this prompt's turn when it aborts, whether it runs or still waits, and never a later turn. */
  signal?: AbortSignal;
}

/** What `turn.accepted` resolves to once the prompt is stored. */
export interface PfAccepted {
  messageId: string;
  sessionId: string;
}

/** How a durable turn ended. */
export interface PfTurnResult {
  messageId: string;
  /** `error` when the turn failed, with the reason in `error`; `unknown` when the process that ran it stopped before writing how it ended. */
  stopReason: PfStopReason | "error" | "unknown";
  /** Absent when the result is a failure read from the session's log rather than from the turn's end. */
  usage?: PfUsage;
  error?: PfErrorSummary;
  /** The lease epoch of the worker that wrote the turn's end. */
  epoch?: number;
  /** Set when a `prompt()` with an already accepted `messageId` reports that turn's outcome. */
  repeated?: true;
}

/** What `session.resume()` resolves to when no turn was left open. */
export interface PfIdleResult {
  stopReason: "idle";
  usage: PfUsage;
}

/** A turn event as a durable session delivers it, with the lease epoch of the worker that wrote it. */
export type PfSessionTurnEvent = PfTurnEvent & { epoch?: number };

/** A view of one durable turn. Dropping it cancels nothing; call `session.cancel()` to stop the turn. */
export interface PfTurnView<Result> {
  /** Resolves once the prompt is stored, or at once for a prompt whose signal had already aborted. */
  readonly accepted: Promise<PfAccepted>;
  /** Resolves when the turn ends. */
  readonly result: Promise<Result>;
  /** The same turn as an NDJSON stream a route can return as its response body. Each line is an `PfStreamLine`. */
  readonly readable: ReadableStream<Uint8Array>;
  [Symbol.asyncIterator](): AsyncIterator<PfSessionTurnEvent>;
}

/** A view of a prompted turn. */
export interface PfTurn extends PfTurnView<PfTurnResult> {
  /** The turn's id, which libpf chooses unless the prompt passed one. */
  readonly messageId: string;
}

/** A view of the turn `session.resume()` continues. `accepted` carries the resume request's id. */
export interface PfResumeTurn extends PfTurnView<PfTurnResult | PfIdleResult> {
  /** The continued turn's id, once known. */
  readonly messageId: string | null;
}

/** One line of `session.stream()` or `turn.readable`, parsed from NDJSON. */
export type PfStreamLine = (
  | (PfTurnEvent & { messageId: string })
  | { type: "turn_start"; messageId: string; sessionId: string; input?: string }
  | { type: "turn_resume"; messageId: string; sessionId: string }
  | { type: "turn_yield"; messageId: string }
  | {
    type: "turn_end";
    messageId: string;
    stopReason: PfStopReason | "error" | "unknown";
    usage?: PfUsage;
    error?: PfErrorSummary;
    repeated?: true;
  }
  | { type: "idle"; requestId: string }
) & {
  /** The lease epoch of the line's writer. Readers hide a line whose epoch is lower than one before it. */
  epoch?: number;
  /** The position `stream()` resumes after. Present on every line of `stream()`; a turn view's `readable` omits it from the `turn_end` of a turn that had already ended. */
  cursor?: number;
};

/** One durable conversation. Opening a session reads nothing; its first prompt does. */
export interface PfSession {
  /** The session's id; for a new session, null until its first prompt is accepted. */
  readonly id: string | null;
  /** Queues `input` as the session's next turn and returns a view of that turn. */
  prompt(input: PfSessionPromptInput, options?: PfPromptOptions): PfTurn;
  /** Continues a turn a stopped process left open; its result has the stop reason `idle` when there was none. */
  resume(): PfResumeTurn;
  /** Every event the session has produced from `cursor` on, as NDJSON, staying open for the events after them. */
  stream(cursor?: number): ReadableStream<Uint8Array>;
  /** Adds guidance to the running turn at its next model request, or to the next turn when none is running. */
  steer(text: string): Promise<void>;
  /** Cancels the running turn. */
  cancel(): Promise<void>;
  /** The session's history as opaque bytes, read without changing the session. */
  checkpoint(): Promise<Uint8Array>;
}

/** An agent: the configuration its sessions run under. Create one per server and open a session per conversation. */
export interface PfAgent {
  /** Opens the session `id`, or starts a new one without it. Any other value, `null` included, throws. */
  session(id?: string, options?: PfSessionOptions): PfSession;
  /** An id for a new session, before its first prompt. */
  newSessionId(): Promise<string>;
  /** The id of the session `agent.prompt()` uses, once known. */
  readonly sessionId: string | null;
  /** Prompts a session the agent opens for itself, for code that holds one conversation. */
  prompt(input: PfSessionPromptInput, options?: PfPromptOptions): PfTurn;
  /** The history of the session `agent.prompt()` uses, as opaque bytes. */
  checkpoint(): Promise<Uint8Array>;
  /** The request handler a deployment mounts for queue deliveries. */
  wakeHandler(): (request: Request) => Promise<Response>;
  /** Waits for the turns this process is running, then lets their sessions go. */
  close(): Promise<void>;
}

// ---------------------------------------------------------------------------
// Backend diagnostics (Node.js)

/** A stable backend diagnostic code. */
export type PfBackendReasonCode =
  | "LIBPF_UNSUPPORTED_PLATFORM"
  | "LIBPF_NATIVE_ARTIFACT_MISSING"
  | "LIBPF_NATIVE_LOAD_FAILED"
  | "LIBPF_NATIVE_API_MISMATCH"
  | "LIBPF_NATIVE_SURFACE_MISSING"
  | "LIBPF_NATIVE_DISABLED"
  | "LIBPF_JSPI_UNAVAILABLE"
  | "LIBPF_WASM_LOAD_FAILED";

/** Why a backend was unavailable. `causeCode` retains a Node error code such as `ENOENT` when one exists. */
export interface PfBackendReason {
  code: PfBackendReasonCode;
  message: string;
  causeCode?: string | number;
}

/** One backend `getBackendInfo()` tried. */
export type PfBackendAttempt =
  | { backend: "native" | "wasm-jspi"; available: true; reason: null }
  | { backend: "native" | "wasm-jspi"; available: false; reason: PfBackendReason };

/** Options for `getBackendInfo()`. */
export interface PfBackendInfoOptions {
  /** `"agent"` by default. */
  surface?: "agent" | "terminal";
  backend?: PfBackendChoice;
  nativeAddon?: string | URL | false | object;
  wasm?: PfNodeWasmSource;
}

/** What `getBackendInfo()` resolves to. */
export interface PfBackendInfo {
  surface: "agent" | "terminal";
  backend: "native" | "wasm-jspi" | "unavailable";
  attempts: PfBackendAttempt[];
}

// ---------------------------------------------------------------------------
// Interactive terminal

/** The terminal a terminal runtime draws on. `xtermAdapter()` builds one from xterm.js. */
export interface PfTerminalAdapter {
  write(bytes: Uint8Array): void;
  /** Subscribes to user input; returns the unsubscribe function. */
  onData(callback: (data: string | Uint8Array) => void): (() => void) | void;
  onKeyData?(callback: (data: string | Uint8Array) => void): (() => void) | void;
  onResize(callback: () => void): (() => void) | void;
  readonly cols: number;
  readonly rows: number;
  /** Resolves once written output has drained. */
  drain?(): unknown;
}

/** The result of one workspace command. */
export interface PfWorkspaceExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/** A browser workspace: completion-only `shell.run` and optional AGENTS.md reads. */
export interface PfWorkspace {
  info: { version: 1; root: string; cwd: string; home: string; gitAvailable: false; ephemeral: true };
  permission: "allow-sandboxed" | "prompt";
  exec(request: { command: string; cwd: string; signal: AbortSignal; timeoutMs: number; outputLimitBytes: number }): PfWorkspaceExecResult | Promise<PfWorkspaceExecResult>;
  /** Returns a string, UTF-8 bytes, or null when the file does not exist. */
  readFile?(request: { path: string; signal: AbortSignal }): string | PfBytes | null | undefined | Promise<string | PfBytes | null | undefined>;
}

/** A diagnostic a terminal runtime passes to `onEvent`. */
export interface PfTerminalEvent {
  type: string;
  timestamp: number;
  [key: string]: unknown;
}

/** Options for `createPfTerminal()`. */
export interface PfTerminalOptions {
  terminal: PfTerminalAdapter;
  env?: Readonly<Record<string, string>>;
  args?: readonly string[];
  /** Input that aborts host effects. Default Ctrl+C (`"\x03"`). */
  interruptKey?: string;
  fetch?: PfFetch;
  onEvent?: (event: PfTerminalEvent) => void;
  workspace?: PfWorkspace;
  /** Defaults to `navigator.clipboard`. */
  clipboard?: { writeText(text: string): unknown } | null;
  /** Opens a URL; return `false` when it was not opened. */
  openUrl?: (url: string) => unknown;
  sessionStore?: unknown;
  configStore?: unknown;
  oauthSessionStore?: unknown;
  promptHistoryStore?: unknown;
}

/** A running terminal harness. */
export interface PfTerminal {
  /** Resolves once the terminal is interactive. */
  readonly interactive: Promise<void>;
  /** Resolves with the exit code. */
  readonly exited: Promise<number>;
  write(data: string | Uint8Array): void;
  resize(): void;
  abort(): void;
}

/** The parts of a keyboard event `encodeXtermKeyEvent()` reads. */
export interface PfKeyEventLike {
  readonly type: string;
  readonly key: string;
  readonly altKey: boolean;
  readonly ctrlKey: boolean;
  readonly shiftKey: boolean;
  readonly metaKey: boolean;
}

/** The parts of an xterm.js `Terminal` `xtermAdapter()` uses. */
export interface PfXtermLike {
  readonly cols: number;
  readonly rows: number;
  write(data: string): void;
  onData(callback: (data: string) => void): { dispose(): void };
  onResize(callback: (size: { cols: number; rows: number }) => void): { dispose(): void };
  attachCustomKeyEventHandler?(handler: (event: PfKeyEventLike) => boolean): void;
  hasSelection?(): boolean;
  readonly element?: unknown;
  readonly modes?: { readonly mouseTrackingMode?: string };
}

/** Connects an xterm.js terminal to `createPfTerminal()`. */
export declare function xtermAdapter(term: PfXtermLike): PfTerminalAdapter;

/** The terminal input for a browser keyboard shortcut the composer handles, or null. */
export declare function encodeXtermKeyEvent(event: PfKeyEventLike): string | null;

// ---------------------------------------------------------------------------
// Shared values

/** Whether this JavaScript runtime provides JavaScript Promise Integration (JSPI). */
export declare function supportsJspi(): boolean;

/** Sorted, unique language-model IDs from one bounded Gateway request. */
export declare function listModels(options: PfListModelsOptions): Promise<string[]>;

/** The version of the WebAssembly SDK API. */
export declare const pfSdkApiVersion: 2;
