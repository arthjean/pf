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
- **Compaction threshold:** Set `auto_compact_percent` in `~/.pf/settings.json` to any value from 10 to 80, or `PF_AUTO_COMPACT_PERCENT` for a single launch, to choose how full the model's context gets before automatic compaction starts. The default stays 80.

### Improvements

- **Upgrades:** `pf upgrade` reports that no release channel is available, and automatic upgrades are off until Paneflow Agent publishes its own releases.
- **MCP authorization messages:** When you decline an MCP server's authorization in the browser, pf says so and tells you to run the connection command again, instead of printing an error name.
- **Grok models:** Models of your Grok subscription that xAI's public catalog omits, or that it cannot describe while it is unavailable, are listed without image input instead of being hidden.
- **Context compaction:** Compaction keeps your messages and the assistant's final replies word for word, and saves every compacted turn, tool call, and earlier compaction under an ID such as `M3`, `T12`, or `L2` that the agent can open or search with `read_tool_result`. Sessions compacted by an earlier pf build keep resuming, but a pf build from before this change cannot read checkpoints written after it.
- **Sessions v2 storage:** With `--sessions-v2`, tool results, tool images, command output, and web downloads are kept once each as read-only blobs named by their digest, prompt images stay inside their turn, and terminal state moves to `~/.pf/terminal/<id>`. Resume, `pf doctor`, and `pf session recover` report a lost blob as damage.

### Bug Fixes

- **Damaged compaction checkpoints:** A compaction checkpoint whose saved counts are out of range no longer stops pf; new records are numbered after the saved ones.
- **Steering after a cancel:** Steering typed right after a tool result survives a canceled turn and appears exactly once when the session resumes.
