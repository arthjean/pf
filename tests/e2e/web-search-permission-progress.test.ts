import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runPf } from "../evals/eval-helpers";

const TIMEOUT = 15_000;
const NO_GATEWAY_AUTH = {
  AI_GATEWAY_API_KEY: undefined,
  VERCEL_OIDC_TOKEN: undefined,
  PF_DISABLE_KEYCHAIN: "1",
};

async function runWithoutGatewayAuth(args: string[]) {
  const root = mkdtempSync(join(tmpdir(), "pf-web-search-no-auth-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  try {
    return await runPf(args, {
      cwd: workspace,
      env: { ...NO_GATEWAY_AUTH, HOME: home },
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function expectNoSearchProgress(stderr: string) {
  expect(stderr).not.toContain("Searching ");
  expect(stderr).not.toContain("Found ");
}

describe("web_search permission progress", () => {
  test(
    "default ask emits no native search progress before authentication",
    async () => {
      const result = await runWithoutGatewayAuth([
        "ask",
        "--auto",
        "search the web for current news",
      ]);

      expect(result.code).toBe(1);
      expect(result.stderr).toContain("pf needs access to Vercel AI Gateway. Run pf login to sign in, pf setup to use an API key, or set AI_GATEWAY_API_KEY.");
      expectNoSearchProgress(result.stderr);
    },
    TIMEOUT,
  );

  test(
    "help does not print the ordinary tool inventory",
    async () => {
      const result = await runPf(["--help"]);

      expect(result.code).toBe(0);
      expect(result.stdout).not.toContain("web_search");
    },
    TIMEOUT,
  );
});
