# Paneflow Agent

## Unreleased

Paneflow Agent starts from fx 0.0.12 ([vercel-labs/fx](https://github.com/vercel-labs/fx) commit `1b1f9af1`). For changes before that point, see the [fx changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md).

### Breaking Changes

- **New name:** The command is `pf`. Profile state moves from `~/.fx` to `~/.pf`, project defaults from `.fx.json` to `.pf.json`, workspace skills from `.fx/skills` to `.pf/skills`, and environment variables from `FX_*` to `PF_*`. Existing fx settings, sessions, and credentials are not read.
- **SDK:** The JavaScript package is `libpf`, with `createPfAgent()` and `createPfTerminal()`, and its error codes use the `LIBPF_` prefix.
- **ACP session workspace:** `session/new` rejects a `cwd` that is relative, empty, or names a directory that does not exist with JSON-RPC error -32602 instead of creating a session.
- **Interactive terminals:** Terminals that the shell tool starts with `tty: true` now end when pf exits, on every platform, and a resumed session reports them as ended instead of reattaching them.
- **ACP permission modes:** ACP session modes are the CLI's permission modes, `auto`, `ask`, and `full-access`, with `auto` as the default; the `code` mode is gone. A session starts in the saved `permission_mode`, choosing a mode with `session/set_mode` or `session/set_config_option` saves it like `/permissions`, and any other mode returns error -32602.
- **Zig 0.17:** Building pf requires Zig 0.17.0.

### New Features

- **Sessions v2 (experimental):** `pf ask --sessions-v2` or `PF_SESSIONS_V2=1` saves the session in an append-only store under `~/.pf/sessions/v2/`, so a killed `pf ask` keeps its prompt and finished tool calls. Windows refuses it with an error.
- **Sessions v2 everywhere:** With `--sessions-v2` or `PF_SESSIONS_V2=1`, the interactive shell, `pf sessions`, `pf session`, and `pf doctor` use the sessions v2 store, and `pf acp` uses it with `PF_SESSIONS_V2=1`. Windows refuses it with an error.
- **ACP embedding:** ACP clients can steer a running turn with `_meta.pf.steer`, supply a session system prompt, keep their MCP tools loaded on every turn, serve MCP servers over the ACP connection, and choose each session's workspace with `cwd`.
- **Compaction threshold:** Set `auto_compact_percent` in `~/.pf/settings.json` to any value from 10 to 80, or `PF_AUTO_COMPACT_PERCENT` for a single launch, to choose how full the model's context gets before automatic compaction starts. The default stays 80.
- **Ultrafast mode:** With `--ultrafast`, `PF_ULTRAFAST=1`, `/ultrafast on`, or `"ultrafast_mode": true` in `~/.pf/settings.json`, pf requests OpenAI's higher-cost Ultrafast service tier on Vercel AI Gateway for a model that supports it. It is off by default, `/status` and `pf status --json` report the request, and pf tells you when Gateway does not confirm that it served the tier.
- **ACP Fast mode:** ACP sessions offer a `fast` config option for models with a Fast lane, next to `ultrafast`. Turning one on turns the other off, enabling a lane the model lacks or setting an unknown option id returns an error, and the choice is saved with the session.
- **MCP-v2 (experimental):** On Linux and macOS, `PF_MCP_ENGINE=v2` runs MCP servers on a new engine that starts each server when the model first needs it, with its own `pf mcp` and `/mcp` verbs (`list`, `show`, `add`, `remove`, `approve`, `reject`, `login`, `logout`); `/mcp` alone opens a menu of them. The default engine is unchanged, and Windows refuses `PF_MCP_ENGINE=v2` with an error.
- **MCP-v2 fixes:** With `PF_MCP_ENGINE=v2`, Ctrl+C leaves `/mcp`, typing filters its menu, the status line shows the servers' state and any sign-in in progress, servers start in the background once the first screen is up, `"type": "streamable-http"` reads as HTTP on both engines, project stdio servers start in the ACP session's directory, and a login made with the default engine carries over once.
- **Agent detection:** Every command pf runs, including terminals and PowerShell on Windows, receives `AI_AGENT=pf` in its environment, replacing any inherited value, so development tools can detect pf.
- **Program Status reports:** The interactive shell reports whether it is idle, working, waiting for your approval or answer, done, or stopped by an error through the Program Status Protocol (OSC 7501), and clears its reports when it exits or is suspended. Terminals without support ignore them. `pf ask` and `pf acp` do not send them.

### Improvements

- **Upgrades:** `pf upgrade` reports that no release channel is available, and automatic upgrades are off until Paneflow Agent publishes its own releases.
- **MCP authorization messages:** When you decline an MCP server's authorization in the browser, pf says so and tells you to run the connection command again, instead of printing an error name.
- **Grok models:** Models of your Grok subscription that xAI's public catalog omits, or that it cannot describe while it is unavailable, are listed without image input instead of being hidden.
- **Context compaction:** Compaction keeps your messages and the assistant's final replies word for word, and saves every compacted turn, tool call, and earlier compaction under an ID such as `M3`, `T12`, or `L2` that the agent can open or search with `read_tool_result`. Sessions compacted by an earlier pf build keep resuming, but a pf build from before this change cannot read checkpoints written after it.
- **Sessions v2 storage:** With `--sessions-v2`, tool results, tool images, command output, and web downloads are kept once each as read-only blobs named by their digest, prompt images stay inside their turn, and terminal state moves to `~/.pf/terminal/<id>`. Resume, `pf doctor`, and `pf session recover` report a lost blob as damage.
- **Images:** Originals up to 8000 pixels per side and 5 MiB encoded are sent unchanged. A larger image, or one whose dimensions cannot be verified, is withheld with its saved path and guidance to make a smaller copy, instead of being downscaled. `/image` followed by a pasted path attaches the image.
- **Faster launch:** The first screen appears before the credential inventory and skill discovery finish; skills finish loading afterward. On macOS, a Vercel login or AI Gateway key stored in the Keychain is read after the first screen too.
- **Faster exit:** Quitting no longer waits for stdio MCP servers to stop one at a time or for a large usage history to finish loading.
- **Shell commands:** On Linux and macOS, pf runs your zsh or bash startup files once per process and restores their result for each command. Run `/shell reload` after changing a file they source; reloading also resets remembered command approvals.
- **Model details:** `pf models --json` describes each Gateway model with its display `name`, the `efforts` it accepts besides `auto`, and whether it has `fast` and `ultrafast` lanes.
- **Status effort:** `pf status` and `pf status --json` report the reasoning `effort` a new session in the workspace starts with, after the model.
- **Status modes:** `pf status --json` reports the permission `mode` a new session in the workspace starts in and lists the `modes` with their `id`, `name`, and `description`.
- **Request size budget:** pf keeps each model request under 30 MiB and 100 images by leaving the oldest images out of that request, with a note telling the model to reopen them with `read_file` or `read_tool_result`; the saved conversation keeps every image. When AI Gateway reports that a provider rejected a request as too large, pf sends it again with fewer images, at most twice per turn, instead of compacting the conversation.
- **Full transcript tool rows:** In the full transcript (Ctrl+O), a tool row longer than the terminal wraps onto more lines instead of ending in an ellipsis, so long commands show in full.
- **Full transcript reading position:** When the full transcript (Ctrl+O) rebuilds a page while you read it, the entry at the top of the page stays at the top instead of moving.
- **`@` menu folders:** In the `@` menu, Enter on a folder mentions it and Tab opens it. An opened folder lists itself first, so it can be mentioned from inside, and its rows appear with the keystroke instead of after a loading frame.

### Bug Fixes

- **Process scans under gVisor:** On Linux sandboxes such as gVisor, pf no longer fails to scan a command's processes when one of them exits during the scan.
- **Gateway connections:** A request's timer no longer interrupts other open connections to the model provider.
- **Host statuses:** A libpf host that reports an HTTP status outside 100 to 599 now fails the request with a provider error instead of crashing pf.
- **Tall prompts:** A submitted prompt or steering message taller than the screen stays whole in the terminal scrollback instead of losing its first lines.
- **Prompts on a full screen:** A prompt submitted when the screen is full appears at once instead of after the next redraw.
- **Crash recovery on sessions v2:** Text the agent streamed before a tool call survives a crash or a killed process, and is sent once when the session resumes.
- **Damaged compaction checkpoints:** A compaction checkpoint whose saved counts are out of range no longer stops pf; new records are numbered after the saved ones.
- **Steering after a cancel:** Steering typed right after a tool result survives a canceled turn and appears exactly once when the session resumes.

### Security

- **Git-free file listing:** `@`-completion, `glob_files`, and `grep_files` list workspace files by reading git's index, ignore rules, and config as data, without starting git, so opening a repository cannot run the programs its config names, such as `core.fsmonitor`, hooks, or filters. Listings are saved under `~/.pf/file-index/` and reused only while current; listings saved by an earlier pf build are ignored and left in place.
- **Safe git:** The git that pf runs itself, for `pf pr`, `pf issue`, and the agent's direct `git status`, `git diff`, and `git log`, turns off every program the repository's config can name and refuses to run when git would use a different repository than the one pf read. In `auto` mode, a git command that pf cannot run this way is returned to the agent without running; `ask` mode still asks.
