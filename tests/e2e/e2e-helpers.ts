/**
 * End-to-end helpers that do not need tmux: the pf binary path, the test
 * environment keys, composer text matching, and the fake AI Gateway.
 * `tmux-helpers.ts` re-exports everything here, so files that drive the TUI
 * through tmux keep one import.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { PF_BIN, REPO_ROOT } from "../evals/eval-helpers";

export { PF_BIN, REPO_ROOT };

const DPAPI_HEADER = "pf-dpapi-v1\n";

/**
 * Reads a credential file as text. On Windows pf encrypts credentials with
 * DPAPI to the current account, so an encrypted file is decrypted the same
 * way, with pf's entropy, by the same account that runs the test.
 */
export function readCredentialFile(path: string): string {
  const stored = readFileSync(path);
  if (stored.subarray(0, DPAPI_HEADER.length).toString("latin1") !== DPAPI_HEADER) {
    return stored.toString("utf8");
  }
  const script =
    "Add-Type -AssemblyName System.Security; " +
    "$blob = [Convert]::FromBase64String($env:PF_TEST_DPAPI_BLOB); " +
    "$entropy = [Text.Encoding]::ASCII.GetBytes('pf.credentials.v1'); " +
    "$plain = [Security.Cryptography.ProtectedData]::Unprotect($blob, $entropy, 'CurrentUser'); " +
    "[Console]::Out.Write([Convert]::ToBase64String($plain))";
  const plain = execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
    env: { ...process.env, PF_TEST_DPAPI_BLOB: stored.subarray(DPAPI_HEADER.length).toString("base64") },
    encoding: "utf8",
    timeout: 30_000,
  });
  return Buffer.from(plain.trim(), "base64").toString("utf8");
}

/** Fails with a build instruction when the pf binary is missing. */
export function requirePfBinary(): string {
  if (!existsSync(PF_BIN)) {
    throw new Error(`pf binary not found at ${PF_BIN}. Run 'zig build' first.`);
  }
  return PF_BIN;
}

export const FAKE_GATEWAY_MODEL = "openai/gpt-5";

const COMPOSER_LINE = /^[ \t]*(?:┃|❯|>)(?:[ \t]|$)/;
export const AUTH_ENV_KEYS = [
  "AI_GATEWAY_API_KEY",
  "VERCEL_OIDC_TOKEN",
] as const;
export const DEFAULT_UNSET_ENV_KEYS = [
  ...AUTH_ENV_KEYS,
  "PF_E2E_GATEWAY_CHAT_URL",
  "PF_E2E_GATEWAY_MODELS_URL",
  "PF_E2E_GATEWAY_CREDITS_URL",
  "PF_E2E_UPGRADE_BASE_URL",
  "PF_E2E_UPGRADE_PUBLIC_KEY",
  "PF_PERMISSION_MODE",
] as const;
export const MIRRORED_ENV_KEYS = [
  "PF_GATEWAY_BASE_URL",
  "PF_GATEWAY_CHAT_URL",
  "PF_MAX_AGENT_STEPS",
  "PF_MODEL",
  "PF_SESSIONS_V2",
] as const;

export function canonicalSubagentIdForStore(childId: string): string {
  const match = /^(\d+)-(\d{6})-([0-9a-f]{16})$/.exec(childId);
  return match ? `${match[1]}-${match[1]}${match[2]}-${match[3]}` : childId;
}

export function isVolatileTokenStatusRow(line: string): boolean {
  return /^\s*(?:(?:\d+s|\d+m \d+s|\d+h \d{2}m) )?\(↑\d+(?:\.\d+)?k? ↓\d+(?:\.\d+)?k?\)$/.test(
    line,
  );
}

export function isComposerLine(line: string): boolean {
  return COMPOSER_LINE.test(line);
}

export function isEmptyComposerLine(line: string): boolean {
  return isComposerLine(line) && line.trim().length === 1;
}

export function composerContains(pane: string, text: string): boolean {
  return pane.split("\n").some((line) => isComposerLine(line) && line.includes(text));
}

export function hasEmptyComposer(pane: string): boolean {
  return pane.split("\n").some(isEmptyComposerLine);
}

export function fakeGatewaySse(events: object[]) {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

export function fakeGatewayToolCall(
  id: string,
  name: string,
  input: object,
) {
  return fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: id,
      toolName: name,
      input,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

export function fakeShellRun(
  id: string,
  command: string,
  options: Record<string, unknown> = {},
) {
  return fakeGatewayToolCall(id, "shell", {
    request: {
      yield_time_ms: 30_000,
      ...options,
      action: "run",
      command,
    },
  });
}

export function fakeGatewayPermissionDecision(
  decision: "clear" | "caution" = "clear",
  toolCallId = "permission_decision_1",
  rationale = "test fixture",
) {
  return fakeGatewayToolCall(toolCallId, "permission_decision", {
    risk: decision === "clear" ? "low" : "high",
    decision,
    rationale,
  });
}

export function fakeGatewaySerializedToolCall(
  id: string,
  name: string,
  input: string,
  assistantText?: string,
) {
  return fakeGatewaySse([
    ...(assistantText
      ? [{ type: "text-delta", id: "answer_1", delta: assistantText }]
      : []),
    {
      type: "tool-call",
      toolCallId: id,
      toolName: name,
      input,
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

export function fakeGatewayFinalText(text: string) {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 3 },
        outputTokens: { total: 5 },
      },
    },
  ]);
}

export function heldFakeGatewayFinalText() {
  const encoder = new TextEncoder();
  let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  let closed = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let response: Response | undefined;
  let pendingText: string | undefined;

  const stopTimer = () => {
    if (timer) clearInterval(timer);
    timer = undefined;
  };
  const close = () => {
    if (closed) return;
    closed = true;
    stopTimer();
    controller?.close();
  };
  const finish = (text: string) => {
    if (closed) return;
    if (!controller) {
      pendingText = text;
      return;
    }
    stopTimer();
    controller.enqueue(encoder.encode(
      `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n` +
        `data: ${JSON.stringify({
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
          usage: {
            inputTokens: { total: 3 },
            outputTokens: { total: 5 },
          },
        })}\n\ndata: [DONE]\n\n`,
    ));
    close();
  };
  const createResponse = () => new Response(
    new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        if (closed) {
          value.close();
          return;
        }
        const keepAlive = () => {
          if (!closed) value.enqueue(encoder.encode(": hold-response\n\n"));
        };
        keepAlive();
        timer = setInterval(keepAlive, 50);
        if (pendingText !== undefined) finish(pendingText);
      },
      cancel() {
        closed = true;
        stopTimer();
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
  return {
    get response() {
      response ??= createResponse();
      return response;
    },
    release: finish,
    dispose: close,
  };
}

export type FakeGatewayResponse =
  | Response
  | ((body: string) => Response | Promise<Response>);

export type FakeGatewayModel = {
  id: string;
  type?: string;
  owned_by?: string;
  released?: number;
  tags?: string[];
  context_window?: number;
  max_tokens?: number;
  pricing?: Record<string, unknown>;
  reasoning_options?: Array<{
    type: string;
    values?: string[];
    [key: string]: unknown;
  }>;
  fast_options?: Array<{
    type: string;
    [key: string]: unknown;
  }>;
};

export type FakeGatewayModelRequest = {
  headers: Headers;
  url: string;
};

export type FakeGatewayOptions = {
  models?:
    | FakeGatewayModel[]
    | ((request: Request) =>
      | FakeGatewayModel[]
      | Response
      | Promise<FakeGatewayModel[] | Response>);
  classifierDecision?: "clear" | "caution";
  classifierResponses?: FakeGatewayResponse[];
  titleResponses?: FakeGatewayResponse[];
  generationResponse?: (
    generationId: string,
    request: Request,
  ) => Response | Promise<Response>;
  // Response for the /v4/ai/evaluation-model endpoint (TypeSafe Jev through
  // the gateway). Defaults to a clear Jev decision.
  evaluationResponse?: FakeGatewayResponse;
};

// Session title generation calls carry this instruction regardless of the
// provider protocol. Fake servers route them to their own channel so they
// never consume queued completion responses; the default is a finish-only
// stream so the call completes without text deltas (which would pollute
// SSE trace assertions) and without a usable title, leaving the locally
// derived title in place for tests that do not opt in.
export const TITLE_GENERATION_MARKER = "Generate a short title";

export function fakeGatewayTitleDefault() {
  return fakeGatewaySse([{
    type: "finish",
    finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 2 }, outputTokens: { total: 0 } },
  }]);
}

// Finish-only Responses-protocol stream for title generation side calls at
// Codex/Grok fake servers: completes without text deltas and without usable
// title content, leaving the locally derived session title in place.
export function fakeResponsesTitleDefault() {
  return new Response(
    'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":2,"output_tokens":0}}}\n\n',
    { headers: { "content-type": "text/event-stream" } },
  );
}

function serveFakeGateway(
  nextCompletion: (body: string) => Response | Promise<Response>,
  options: FakeGatewayOptions,
) {
  const requests: Array<{ body: string; headers: Headers }> = [];
  const classifierRequests: Array<{ body: string; headers: Headers }> = [];
  const evaluationRequests: Array<{ body: string; headers: Headers }> = [];
  const classifierResponses = [...(options.classifierResponses ?? [])];
  const titleRequests: Array<{ body: string; headers: Headers }> = [];
  const titleResponses = [...(options.titleResponses ?? [])];
  const modelRequests: FakeGatewayModelRequest[] = [];
  const generationRequests: string[] = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      if (new URL(req.url).pathname === "/coding-agent/v1/models") {
        modelRequests.push({ headers: new Headers(req.headers), url: req.url });
        const models = typeof options.models === "function"
          ? await options.models(req)
          : options.models;
        if (models instanceof Response) return models;
        return Response.json({
          data: models ?? [{
            id: FAKE_GATEWAY_MODEL,
            type: "language",
            tags: ["tool-use"],
          }],
        });
      }
      if (req.method === "GET" && new URL(req.url).pathname === "/v1/generation") {
        const generationId = new URL(req.url).searchParams.get("id") ?? "";
        generationRequests.push(generationId);
        if (options.generationResponse) {
          return options.generationResponse(generationId, req);
        }
        return new Response("not found", { status: 404 });
      }
      if (
        req.method === "POST" &&
        new URL(req.url).pathname === "/v4/ai/evaluation-model"
      ) {
        evaluationRequests.push({
          body: await req.text(),
          headers: new Headers(req.headers),
        });
        // Mirrors the real AI Gateway evaluation-model envelope: camelCase
        // usage and confidence under providerMetadata.typesafe.
        const evaluationResponse = options.evaluationResponse ??
          Response.json({
            answers: {
              decision: {
                type: "choice",
                choice: "clear",
                probabilities: { clear: 0.99, caution: 0.01 },
              },
            },
            rounding: { probabilityDecimals: 2, scoreDecimals: 2 },
            usage: { inputTokens: 100, outputTokens: 10 },
            warnings: [],
            providerMetadata: {
              typesafe: { confidence: { decision: 0.97 } },
            },
          });
        return typeof evaluationResponse === "function"
          ? await evaluationResponse(evaluationRequests[evaluationRequests.length - 1].body)
          : evaluationResponse;
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      const headers = new Headers(req.headers);
      if (body.includes("\"permission_decision\"")) {
        classifierRequests.push({ body, headers });
        const next = classifierResponses.shift();
        if (next) return typeof next === "function" ? await next(body) : next;
        return fakeGatewayPermissionDecision(options.classifierDecision ?? "clear");
      }
      if (body.includes(TITLE_GENERATION_MARKER)) {
        titleRequests.push({ body, headers });
        const next = titleResponses.shift();
        if (next) return typeof next === "function" ? await next(body) : next;
        return fakeGatewayTitleDefault();
      }
      requests.push({ body, headers });
      return nextCompletion(body);
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    requests,
    classifierRequests,
    evaluationRequests,
    titleRequests,
    generationRequests,
    modelRequests,
    requestCount() {
      return requests.length;
    },
    stop() {
      server.stop(true);
    },
  };
}

export function startFakeGateway(
  responses: FakeGatewayResponse[],
  options: FakeGatewayOptions = {},
) {
  return serveFakeGateway(async (body) => {
    const next = responses.shift();
    if (!next) {
      return new Response("unexpected request", { status: 500 });
    }
    return typeof next === "function" ? await next(body) : next;
  }, options);
}

// Same server and classifier handling as startFakeGateway, but every
// completion request is answered by the supplied callback instead of a
// finite queue. For suites that replay one response indefinitely or switch
// on their own state.
export function startDynamicFakeGateway(
  response: (body: string) => Response | Promise<Response>,
  options: FakeGatewayOptions = {},
) {
  return serveFakeGateway(response, options);
}
