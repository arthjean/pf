@AGENTS.md

## Paneflow Agent fork

This repository is Paneflow Agent, a fork of `vercel-labs/fx` (Apache-2.0) that ships as the `pf` binary. Where the rules below conflict with the imported `AGENTS.md`, these rules win.

### Upstream sync

- `origin` is `arthjean/paneflow-agent`, the product repository. `upstream` is `vercel-labs/fx` and is fetch-only (its push URL is `no_push`). Take upstream changes with `git fetch upstream && git merge upstream/main`; do not rebase `main` onto upstream.
- Keep `AGENTS.md` and `sdk/AGENTS.md` identical to upstream so merges stay clean, and put fork guidance in this file. `git diff upstream/main -- AGENTS.md sdk/AGENTS.md` must stay empty.
- Rename only what users see: the binary name, CLI and TUI copy, the agent's self-identification in system prompts, config paths, environment variables, domains, and docs. Keep internal Zig identifiers, file names, and module paths as upstream names them, because each renamed line becomes a future merge conflict.
- Keep `LICENSE`, `THIRD_PARTY_NOTICES.md`, and Vercel's copyright notice. Record fork modifications in a `NOTICE` file; never delete upstream attribution.

### Rename in progress

The move from `fx` to `pf` is incomplete. Until `build.zig` produces `zig-out/bin/pf`, the upstream rule about `./zig-out/bin/fx` still applies; after that, read every `fx` binary reference in `AGENTS.md` as `pf`. Upstream mentions of `~/.fx`, `FX_*`, and `.fx.json` describe the code until their rename lands. When a rename slice lands, update this section in the same commit.

Public copy, including `CHANGELOG.md`, names the product Paneflow Agent and the command `pf`, replacing the upstream rule that spells it `fx`.

### Stop for Arthur

Stop and present the options with their tradeoffs, without choosing, before changing:

- authentication and provider access: the Vercel OAuth login, Vercel AI Gateway, the ChatGPT `client_id` embedded in `src/core/auth/chatgpt_oauth.zig`, and the Grok route, because each relies on credentials or agreements Paneflow does not own;
- distribution: `fx.sh`, `releases.fx.sh`, Vercel Blob uploads, the install script, and `fx upgrade`;
- `.github/workflows/`: GitHub Actions is disabled on `arthjean/paneflow-agent`, and several workflows publish releases or npm packages with Vercel secrets.

### Upstream process that does not apply

- Full CI, the ship gate, draft pull requests, and `type:` labels are unavailable while Actions is disabled. Do not push branches or open pull requests unless Arthur asks. Work is ready after `zig build`, the focused tests for the changed path, `zig fmt --check src/`, and a real run of the built binary; state that Full CI did not run.
- The Releasing section and the benchmark upload to Vercel Blob describe Vercel's pipeline; do not run or imitate them.
- The Repository and License rule requiring `vercel-labs/fx` URLs applies only to upstream attribution. Product links point to `arthjean/paneflow-agent`.
- Do not use em dashes in prose; this replaces the upstream Code Style line that allows them sparingly.
