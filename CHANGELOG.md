# Paneflow Agent

## Unreleased

Paneflow Agent starts from fx 0.0.12 ([vercel-labs/fx](https://github.com/vercel-labs/fx) commit `1b1f9af1`). For changes before that point, see the [fx changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md).

### Breaking Changes

- **New name:** The command is `pf`. Profile state moves from `~/.fx` to `~/.pf`, project defaults from `.fx.json` to `.pf.json`, workspace skills from `.fx/skills` to `.pf/skills`, and environment variables from `FX_*` to `PF_*`. Existing fx settings, sessions, and credentials are not read.
- **SDK:** The JavaScript package is `libpf`, with `createPfAgent()` and `createPfTerminal()`, and its error codes use the `LIBPF_` prefix.
- **ACP session workspace:** `session/new` rejects a `cwd` that is relative, empty, or names a directory that does not exist with JSON-RPC error -32602 instead of creating a session.

### New Features

- **Sessions v2 (experimental):** `pf ask --sessions-v2` or `PF_SESSIONS_V2=1` saves the session in an append-only store under `~/.pf/sessions/v2/`, so a killed `pf ask` keeps its prompt and finished tool calls. Windows refuses it with an error.
- **Sessions v2 everywhere:** With `--sessions-v2` or `PF_SESSIONS_V2=1`, the interactive shell, `pf sessions`, `pf session`, and `pf doctor` use the sessions v2 store, and `pf acp` uses it with `PF_SESSIONS_V2=1`. Windows refuses it with an error.
- **ACP embedding:** ACP clients can steer a running turn with `_meta.pf.steer`, supply a session system prompt, keep their MCP tools loaded on every turn, serve MCP servers over the ACP connection, and choose each session's workspace with `cwd`.

### Improvements

- **Upgrades:** `pf upgrade` reports that no release channel is available, and automatic upgrades are off until Paneflow Agent publishes its own releases.
- **MCP authorization messages:** When you decline an MCP server's authorization in the browser, pf says so and tells you to run the connection command again, instead of printing an error name.
- **Grok models:** Models of your Grok subscription that xAI's public catalog omits, or that it cannot describe while it is unavailable, are listed without image input instead of being hidden.

### Bug Fixes

- **Steering after a cancel:** Steering typed right after a tool result survives a canceled turn and appears exactly once when the session resumes.
