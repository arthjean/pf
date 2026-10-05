/**
 * Interactive MCP OAuth on Windows. A fixture authorization server guards a
 * fixture MCP server; `pf mcp auth` prints the authorization URL because
 * PF_NO_OPEN_BROWSER is set, and the test plays the browser by following it
 * to pf's loopback callback. The suite runs only on Windows, where the other
 * MCP auth suites need POSIX shell openers.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PF_BIN, runPf } from "../evals/eval-helpers";
import { startModernMcpHttpFixture } from "./fixtures/mcp-modern-http";

const ACCESS_TOKEN = "windows-mcp-access-secret";
const isWindows = process.platform === "win32";

let cleanup: (() => void)[] = [];

afterEach(() => {
  for (const step of cleanup.reverse()) step();
  cleanup = [];
});

function startAuthorizationServer(upstreamUrl: string) {
  let challenge = "";
  let tokenExchanges = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const origin = `http://127.0.0.1:${server.port}`;
      const body = request.method === "GET" ? "" : await request.text();
      if (url.pathname === "/mcp") {
        if (request.headers.get("authorization") !== `Bearer ${ACCESS_TOKEN}`) {
          return new Response("", {
            status: 401,
            headers: {
              "www-authenticate":
                `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp", scope="tools.read"`,
            },
          });
        }
        const headers = new Headers(request.headers);
        headers.set("connection", "close");
        return fetch(upstreamUrl, { method: request.method, headers, ...(body === "" ? {} : { body }) });
      }
      if (url.pathname === "/.well-known/oauth-protected-resource/mcp") {
        return Response.json({ resource: `${origin}/mcp`, authorization_servers: [origin], scopes_supported: ["tools.read"] });
      }
      if (url.pathname === "/.well-known/oauth-authorization-server") {
        return Response.json({
          issuer: origin,
          authorization_endpoint: `${origin}/authorize`,
          token_endpoint: `${origin}/token`,
          grant_types_supported: ["authorization_code"],
          token_endpoint_auth_methods_supported: ["none"],
          code_challenge_methods_supported: ["S256"],
          authorization_response_iss_parameter_supported: true,
        });
      }
      if (url.pathname === "/authorize") {
        challenge = url.searchParams.get("code_challenge") ?? "";
        const redirect = new URL(url.searchParams.get("redirect_uri")!);
        redirect.searchParams.set("code", "fixture-code");
        redirect.searchParams.set("state", url.searchParams.get("state")!);
        redirect.searchParams.set("iss", origin);
        return Response.redirect(redirect, 302);
      }
      if (url.pathname === "/token") {
        const form = new URLSearchParams(body);
        const verifier = form.get("code_verifier") ?? "";
        if (form.get("code") !== "fixture-code" || createHash("sha256").update(verifier).digest("base64url") !== challenge) {
          return Response.json({ error: "invalid_grant" }, { status: 400 });
        }
        tokenExchanges += 1;
        return Response.json({ access_token: ACCESS_TOKEN, token_type: "Bearer", scope: "tools.read", expires_in: 3600 });
      }
      return new Response("not found", { status: 404 });
    },
  });
  cleanup.push(() => server.stop(true));
  return {
    url: `http://127.0.0.1:${server.port}/mcp`,
    get tokenExchanges() {
      return tokenExchanges;
    },
  };
}

function createProfile(serverUrl: string, callbackPort?: number) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pf-windows-mcp-oauth-")));
  cleanup.push(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".pf"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".pf", "settings.json"), "{}");
  writeFileSync(join(home, ".pf", "mcp.json"), JSON.stringify({
    mcp: {
      fixture: {
        type: "http",
        url: serverUrl,
        environment: { PF_MCP_PROTOCOL_VERSION: "2026-07-28" },
        oauth: {
          client_id: "pf-windows-mcp-oauth-test",
          scopes: ["tools.read"],
          ...(callbackPort === undefined ? {} : { callback_port: callbackPort }),
        },
        startup_timeout_ms: 5_000,
        operation_timeout_ms: 5_000,
      },
    },
  }));
  const env = {
    HOME: home,
    USERPROFILE: home,
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    PF_AUTO_UPGRADE: "0",
    PF_NO_OPEN_BROWSER: "1",
    PF_MCP_PROTOCOL_VERSION: "2026-07-28",
    NO_COLOR: "1",
  };
  return { home, workspace, env };
}

describe.skipIf(!isWindows)("interactive MCP OAuth on Windows", () => {
  test("authorizes through the loopback callback and lists the server's tools", async () => {
    const upstream = startModernMcpHttpFixture("json");
    cleanup.push(() => upstream.stop());
    const authorization = startAuthorizationServer(upstream.url);
    const profile = createProfile(authorization.url);

    const childEnv: Record<string, string> = {};
    for (const [key, value] of Object.entries({ ...process.env, ...profile.env })) {
      if (value !== undefined) childEnv[key] = value;
    }
    const child = Bun.spawn([PF_BIN, "mcp", "auth", "fixture"], {
      cwd: profile.workspace,
      env: childEnv,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    let stdout = "";
    let callbackStatus: number | null = null;
    let callbackBody = "";
    const readStdout = (async () => {
      const decoder = new TextDecoder();
      let followed = false;
      for await (const chunk of child.stdout) {
        stdout += decoder.decode(chunk, { stream: true });
        const match = stdout.match(/^(https?:\/\/[^\r\n]+)\r?\n/m);
        if (!followed && match) {
          followed = true;
          // The browser: follow the authorization redirect to pf's callback.
          const response = await fetch(match[1]);
          callbackStatus = response.status;
          callbackBody = await response.text();
        }
      }
    })();
    const timer = setTimeout(() => child.kill(), 20_000);
    let code: number;
    let stderr: string;
    try {
      [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text(), readStdout]);
    } finally {
      clearTimeout(timer);
    }

    expect({ code, stderr }).toEqual({ code: 0, stderr: "" });
    expect(stdout).toContain("Authenticated MCP server 'fixture'");
    expect(callbackStatus).toBe(200);
    expect(callbackBody).toContain("Authorization complete");
    expect(authorization.tokenExchanges).toBe(1);

    const credentials = join(profile.home, ".pf", "mcp-credentials", "credentials.json");
    expect(existsSync(credentials)).toBe(true);
    const stored = readFileSync(credentials);
    expect(stored.subarray(0, 12).toString()).toBe("pf-dpapi-v1\n");
    expect(stored.includes(Buffer.from(ACCESS_TOKEN))).toBe(false);

    const listed = await runPf(["mcp", "list", "--connect"], {
      cwd: profile.workspace,
      env: profile.env,
      timeoutMs: 20_000,
    });
    expect(listed.stderr).toBe("");
    expect(listed.code).toBe(0);
    expect(listed.stdout).toMatch(/fixture[\s\S]{0,240}state=ready/);
    expect(listed.stdout).toContain("tools=1");
  }, 45_000);

  test("reports a pinned callback port held by another program within 5 seconds", async () => {
    const upstream = startModernMcpHttpFixture("json");
    cleanup.push(() => upstream.stop());
    const authorization = startAuthorizationServer(upstream.url);
    const holder = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("held") });
    cleanup.push(() => holder.stop(true));
    const profile = createProfile(authorization.url, holder.port);

    const started = Date.now();
    const result = await runPf(["mcp", "auth", "fixture"], {
      cwd: profile.workspace,
      env: profile.env,
      timeoutMs: 15_000,
    });
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(result.code).not.toBe(0);
    expect(result.stderr).toContain(`Port ${holder.port} is in use. Close the program using it and retry`);
    expect(existsSync(join(profile.home, ".pf", "mcp-credentials", "credentials.json"))).toBe(false);
  }, 20_000);
});
