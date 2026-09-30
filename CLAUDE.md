@AGENTS.md

## Paneflow Agent

This repository is Paneflow Agent, shipped as the `pf` binary. It started from `vercel-labs/fx` (Apache-2.0) at commit `1b1f9af1` and shares no git history with it. Arthur ports fx changes himself. Where the rules below conflict with `AGENTS.md`, these rules win.

### Porting fx changes

- `UPSTREAM.md` records the fx base commit and the last fx commit ported into pf. Track fx in a separate clone at `../fx-upstream`, never as a remote of this repository.
- Port a range with `python3 scripts/rebrand.py port <last-ported> <target>`. It renames each changed fx file with the same rules as this repository and 3-way merges it into the worktree, leaving conflict markers where pf diverged. Resolve them, run the checks below, and update `UPSTREAM.md` in the same commit.
- Every rename rule lives in `scripts/rebrand.py`. When fx introduces a spelling the rules miss, fix the rule instead of hand-editing the port. `python3 scripts/rebrand.py check` must pass.

### Kept as fx on purpose

`scripts/rebrand.py` protects what pf does not own yet: the Grok `referrer` and `x-grok-client-identifier`, the Slack bridge on fx.sh, Vercel's macOS signing identity, and `vercel-labs/fx` links used for attribution or as test fixtures. Binary format magics such as `FXCP` and `FXTP` also stay.

### Stop for Arthur

Stop and present the options with their tradeoffs, without choosing, before changing:

- authentication and provider access: the Vercel OAuth login and its client id, Vercel AI Gateway, the ChatGPT `client_id` (Codex CLI's public OAuth client) and `originator` (`pf`), the Grok identifiers above, and the Slack bridge, because each relies on credentials or agreements Paneflow does not own;
- distribution: install scripts, release channels, signing, and `pf upgrade`, which stays disabled until pf has its own release channel;
- `.github/workflows/`: the workflows still assume Vercel secrets (Blob, AI Gateway, Apple signing, npm). Decide what to keep before this repository is pushed to GitHub with Actions enabled.

### Process from AGENTS.md that does not apply

- Full CI, the ship gate, draft pull requests, and `type:` labels do not exist for pf yet. Do not push branches or open pull requests unless Arthur asks. Work is ready after `zig build`, the focused tests for the changed path, `zig fmt --check src/`, and a real run of `./zig-out/bin/pf`; state that Full CI did not run.
- The Releasing section and the benchmark upload to Vercel Blob describe Vercel's pipeline; do not run or imitate them.
- Public copy names the product Paneflow Agent and the command `pf`. Product links point to https://paneflow.dev/agent.
- Keep `LICENSE`, `THIRD_PARTY_NOTICES.md`, Vercel's copyright notice, and `NOTICE`. Record notable modifications of fx in `NOTICE`.
- Do not use em dashes in prose; this replaces the AGENTS.md Code Style line that allows them sparingly.
