# Contributing

## Scope

`pf` is a CLI-first coding agent written in Zig.

Contributions should preserve that direction:

* CLI-first over terminal-IDE behavior

* explicit contracts over ad hoc strings and branches

* permission-first security model

* small, reviewable changes

* honest docs and status reporting

## Setup

Requirements:

* Zig `0.16.0+`

* interactive terminal for manual shell testing

* a model connection for model-backed flows. [Custom model connections](README.md#custom-model-connections) support local and remote endpoints. Vercel OAuth via `pf login`, macOS Keychain API keys via `pf setup`, `AI_GATEWAY_API_KEY`, and `VERCEL_OIDC_TOKEN` are also supported

Common commands:

```bash
zig fmt src/
zig build
zig build test
zig build run
```

### Windows

pf builds and runs natively on Windows x86_64, and the interactive terminal UI runs in a console with virtual terminal support, such as Windows Terminal or the VS Code terminal. The README's Windows section lists what is not ported yet. To work on it:

* install Zig `0.16.0` for Windows x86_64 and put `zig.exe` on `PATH`

* build natively from PowerShell or Git Bash with `zig build`; the target is `x86_64-windows-gnu`, and Linux and macOS still build from the same checkout with `zig build -Dtarget=x86_64-linux-gnu` and `zig build -Dtarget=aarch64-macos`

* run the unit tests natively with `zig build test`; a test that cannot run on Windows starts with `if (comptime builtin.os.tag == .windows) return error.SkipZigTest;` and a comment that states why

* run the Windows end-to-end subset from `tests/e2e` with `bun windows-subset.ts` after `zig build` and `zig build conpty-driver`; it runs the files listed in `WINDOWS_E2E_FILES` with a throwaway profile, and the rest of `tests/e2e` needs tmux or POSIX fixtures. pf loads skills from every ancestor of a workspace, so the runner stops when a directory above `%TEMP%` holds one, such as `%USERPROFILE%\.claude\skills`; set `TEMP` and `TMP` to a directory outside your profile, for example `C:\pf-e2e-tmp`

* drive `./zig-out/bin/pf.exe` through a pseudo console with `zig build conpty-driver`, which installs `zig-out/bin/conpty-driver.exe`; its options and script commands are documented at the top of `tests/e2e/fixtures/windows-conpty-driver.zig`, and `tests/e2e/windows-tui-smoke.test.ts` shows it in a test

* pf reads its profile from `USERPROFILE` before `HOME` on Windows, so a test that isolates its home must set both

* run the Linux unit tests inside WSL on a copy of the checkout in the WSL filesystem with a Linux Zig `0.16.0`: `zig build test`

* run `bash ./scripts/check-public-surface.sh` through Git Bash

The repository's `.gitattributes` checks out text files with LF on every platform, so `zig fmt --check src/` passes on Windows even with `core.autocrlf=true`. A clone created before `.gitattributes` existed keeps its CRLF files, and `zig fmt --check src/` fails on them. Commit or stash your changes, then renormalize and check out again:

```bash
git add --renormalize .
git rm -r --cached -q .
git reset --hard
```

## Verification Workflow

Keep the local development loop focused: run the narrowest test that covers the changed path, build pf, and exercise the change using `./zig-out/bin/pf`. The installed `pf` on `PATH` is not valid development evidence.

Once the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. The **Full CI** workflow runs the complete deterministic suite on native Linux x86_64, Linux aarch64, macOS x86_64, and macOS aarch64 runners. The native matrix builds, tests, and smoke-tests ReleaseSafe on every platform; formatting and the public-surface audit run in those ReleaseSafe jobs. Four duration-balanced, isolated ReleaseSafe E2E shards per platform use checked-in weights to assign every Bun test file once; files inside each shard run sequentially in separate Bun processes so terminal fixtures and process state cannot leak between files. A failed file receives one bounded retry after tmux is reset.

Standard PR CI reports ReleaseSafe Build & Test and deterministic E2E results. Do not mark the draft PR ready until all five Full CI jobs and the final ship gate have succeeded for the exact current commit. Each Linux and macOS aggregate requires its ReleaseSafe native check and all four ReleaseSafe E2E shards; the Windows aggregate requires the Windows job, which also runs the Windows E2E subset. A result from an older commit does not count. Live model evals are separate from this gate because they require credentials and are not deterministic.

Changes to `build.zig` or `scripts/pgso/` also run the native macOS arm64 PGSO candidate workflow. That lane produces retained size, behavior, and performance evidence but does not alter any release artifact or update channel. Its pinned toolchain, local reproduction command, corpus exclusions, and failure rules are documented in [`scripts/pgso/README.md`](scripts/pgso/README.md).

Every pull request also receives informational ReleaseSafe binary-size
comparisons for Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64. Each
comparison builds the pull request merge commit and base commit on the same
native runner, reports exact file and ELF or Mach-O section deltas, and emits a
warning at increases of 52,429 bytes (0.050000 MiB) or more. The warning requests
investigation but does not replace the full PGSO release gate or reject a valid
feature solely for adding code.

## Pull Requests

Every PR must carry exactly one label that describes its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

If you cannot manage labels, a maintainer or repository agent will apply the label before review. For a mixed PR, choose the label that best describes why the PR exists. Keep the title as a clean imperative sentence and do not add bracketed type prefixes such as `[bug]` or `[improvement]`.

If an AI coding agent writes any of your contribution's prose, including the PR title and description, commit messages, documentation, and issues, it must use the `technical-writer` skill in `.pf/skills/technical-writer/`.

## Repo Shape

* `src/main.zig`: composition root only

* `src/core/`: contracts, runtimes, config, sessions, permissions, MCP, skills

* `src/tools/`: built-in tool implementations

* `src/ui/`: terminal rendering, event loop, input, transcript

* `src/gateway/`: AI Gateway client transport

* `.pf/skills/`: optional pf-native workspace-level skill root

* `skills/`: optional shared workspace-level skill root

## Collaboration Rules

Before adding a new feature, answer these first:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified for macOS arm64 PGSO?

If that is unclear, stop and define it first.

### PGSO corpus ownership

Classify every root `tests/e2e/*.test.ts` file in
`scripts/pgso/corpus.json`. Put common or performance-sensitive behavior in
training. Put important correctness, recovery, security, and rare behavior in
verification-only. Exclude only nondeterministic, live-network, credentialed,
sound-related, or harness-only coverage, and record the reason.

Tests added to an existing file inherit its classification. Reconsider that
classification when a feature changes the file's product role, and remove stale
entries when deleting a feature or E2E owner. Normal PR CI rejects missing,
duplicate, stale, and unclassified files without running the full PGSO gate.

## Configuration and State

Config precedence (highest wins):

1. Environment variables such as `PF_PROVIDER`, `PF_MODEL`, `PF_PERMISSION_MODE`, and `PF_MAX_AGENT_STEPS`
2. `~/.pf/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.pf/settings.json` top-level (profile global settings)
4. `<workspace>/.pf.json` (committed project defaults)
5. Built-in defaults

Project `.pf.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `provider`, `providers`, `models`, `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `auto_upgrade`, `update_channel`, `permission_mode`, `permission`, and `skill_symlink_authorities` are ignored from project config before their values are parsed.

`skill_symlink_authorities` is an array of absolute directories that symlinked skills may resolve into, such as an app bundle or `/nix/store`. It is read at startup, a workspace override replaces the global list, and its entries are combined with the `PF_SKILL_SYMLINK_AUTHORITIES` environment variable, whose entries are separated like `PATH`: `:` on Linux and macOS, `;` on Windows.

Runtime state lives under `~/.pf/`:

* `~/.pf/sessions/<session-id>/session.json`

* `~/.pf/sessions/<session-id>/background/`

* `~/.pf/sessions/<session-id>/subagent/`

* `~/.pf/sessions/<session-id>/logs/`

Sessions are global and portable across workspaces. Each session tracks a `workspace_root` that updates when resumed from a different directory.

Subagent children are internal ordinary sessions with their own `~/.pf/sessions/<child-id>/` directory and history. The parent owns one bounded `subagent/children.json` registry; each child carries only an immutable owner marker. Child sessions are hidden from ordinary session discovery and cannot be resumed directly. A first `subagent.message` creates a named persistent child for that parent; later messages continue it, and optional instructions replace only its child-specific system overlay.

## Skills

There are two distinct skill categories in `pf`:

* `pf` roots that belong to the product itself: `.pf/skills`, `skills/`, `~/.pf/skills`

* compatibility roots discovered for other agent installs: `.opencode/skills`, `.codex/skills`, `.claude/skills`, `.agents/skills`, `.claw/skills`, plus their global equivalents

`/skills list` should make that distinction visible to the user.

`/skills add` and `/skills install` install full skill directories into the profile-owned `~/.pf/skills` managed root, not just `SKILL.md`. Workspace `.pf/skills` and `skills/` remain discoverable project-local instructions, not managed install targets.

The interactive agent can also install skills via the `install_skill` tool when the user asks to install one in conversation, including pasted `npx skills add ...` syntax.

## Slack installation testing

`src/core/slack/install.zig` owns workspace bot installation, local credential
persistence, and explicit refresh. The web bridge contract is fixed to
`https://fx.sh/api/slack/install/config`, `/api/slack/install`, and
`/api/slack/oauth/callback`. Employee MCP authentication is separate.

Build with `zig build`, then run `cd tests/e2e && bun test slack-install.test.ts`.
The fixture exercises the freshly built binary and real loopback sockets without
live Slack credentials. `PF_E2E_SLACK_ORIGIN` accepts only an HTTP `127.0.0.1`
origin with a non-privileged port, serving public metadata plus mocked
`/api/oauth.v2.access` and `/api/auth.test` responses. Production uses pinned
Slack endpoints. Local records bind to the bridge origin to prevent fixture
commands from refreshing production credentials. `PF_NO_OPEN_BROWSER=1` prints
the start URL for headless operation; authorization still requires a browser on
the same computer as the listener.

This E2E owner is verification-only in the PGSO corpus because it covers a rare
workspace setup operation and security boundaries. Live Slack authorization and
message attribution are not deterministic tests.

## MCP

Native pf connections use MCP v1 initialization by default over stdio,
Streamable HTTP, and deprecated `2024-11-05` HTTP+SSE. Servers using the newer
`2026-07-28` discovery lifecycle opt in with
`PF_MCP_PROTOCOL_VERSION=2026-07-28` in their configured `environment` map.
The SDK's host-owned client controls its own protocol negotiation. Native
sessions load trusted MCP configuration from the profile:

* `~/.pf/mcp.json`

They also read Claude-compatible workspace configuration from:

* `<workspace>/.mcp.json`

Project `.pf.json` does not define runnable MCP commands, URLs, env, or secrets.
The profile file reads top-level `mcp` and accepts `mcpServers` as a
compatibility alias; `mcp` wins when both exist, and every write uses `mcp`.
Suspicious server-like unsupported keys produce a bounded warning and block
profile mutation instead of being overwritten. The workspace file reads only
top-level `mcpServers`, accepts `command` plus `args`, and is opened as a
bounded no-follow regular file. Profile entries win native name collisions;
ACP request entries win ACP name collisions without deduplicating the request
array. Workspace entries are always optional and never load stored credentials.
Approved workspace `command`, `args`, `env`, and HTTP header values expand
`${VAR}` and `${VAR:-default}` from the pf process environment. Pending and
rejected entries do not read environment values. Missing required variables
leave an approved server unloaded and appear in the `/mcp` and `/mcp list`
menu without exposing values.

Interactive sessions keep pending workspace servers disconnected and request
project trust before any project-defined process or network effect. Pending
resource, prompt, completion, and authentication commands require explicit
`/mcp trust approve <name>` and a retry. Rejected servers remain disconnected.
Choices live only in profile `settings.json` under the canonical workspace key,
using `enabledMcpjsonServers`, `disabledMcpjsonServers`, and
`enableAllProjectMcpServers`. Repository files cannot persist their own
approval. `pf ask` and ACP skip pending workspace servers. Noninteractive users
approve them first with `pf mcp trust approve <name>`; rejected servers remain
disabled.

The core feature surface is Tools, Resources and Resource Templates, Prompts,
Completion, pagination, cache-aware discovery, subscriptions, progress,
cancellation, and form or URL elicitation. Keep modern and legacy protocol
behavior in their existing version-scoped modules.

pf bounds schema size and structure before publication. It accepts schemas
without `$schema`, the canonical JSON Schema 2020-12 declaration, and the
canonical Draft 7 declaration used by legacy SDKs; other declared dialects are
rejected. pf does not resolve network references or evaluate semantic schema
assertions. Servers validate their tool arguments and results.

The interactive surface supports:

* `/mcp`

* `/mcp list` (opens the same server menu)

* `/mcp resource list <server>`

* `/mcp resource templates <server>`

* `/mcp resource read <server> <uri>`

* `/mcp resource complete <server> <uri-template> <variable> [value]`

* `/mcp prompt list <server>`

* `/mcp prompt get <server> <name> [arguments-json]`

* `/mcp prompt complete <server> <name> <argument> [value]`

* `/mcp add <name> <command> [args...]`

* `/mcp add --transport http <name> <url>`

* `/mcp remove <name>`

* `/mcp reload`

* `/mcp auth <name> --open`

* `/mcp logout <name>`

* `/mcp trust approve <name>`

* `/mcp trust reject <name>`

* `/mcp trust approve-all`

* `/mcp trust reset`

* `/mcp path`

The noninteractive MCP surface supports:

* `pf mcp add <name> <command> [args...]`

* `pf mcp add --transport http <name> <url>`

* `pf mcp auth <name>`

* `pf mcp list`

* `pf mcp logout <name>`

* `pf mcp path`

* `pf mcp remove <name>`

* `pf mcp trust approve <name>`

* `pf mcp trust reject <name>`

* `pf mcp trust approve-all`

* `pf mcp trust reset`

The local form saves a stdio command. The HTTP form saves a remote Streamable
HTTP endpoint. List reads effective profile and workspace configuration plus
stored authentication state without connecting servers. Path prints the profile
configuration path. Remove uses the same locked canonical profile writer as
add. Trust updates the canonical workspace entry in profile settings. Auth and
logout run the existing remote credential lifecycle. None of these commands
constructs the TUI or contacts the Gateway.

The default MCP startup timeout is 30 seconds and remains overridable per
server with `startup_timeout_ms`. Exact direct `docker run` stdio commands
without `--cidfile` receive a private cidfile so pf can remove the container
after shutdown or startup failure. An explicit cidfile remains user-owned.

When a stdio server closes its connection before answering `initialize`, for
example because its process exited, the reported failure names the exit code
or signal and includes a bounded, terminal-safe excerpt of the server's stderr
with secrets masked. A startup timeout names the limit that ran out, plus an
earlier launch's exit when there was one, and names the `startup_timeout_ms`
key when that setting set the limit. When a server writes a stdout line that
is not an MCP message, such as a banner, the failure quotes the start of that
line. A startup restart runs only when it could change the outcome: a server
that closed its connection at every offered protocol version is not
restarted, and neither is one whose startup deadline has already passed. A
server that pf stopped because of invalid output still gets its restart. The
model sees the same reason when it searches a named server that is down, or
when a tool call finds its server stopped and the relaunch fails.

MongoDB Atlas Managed MCP configuration service accounts use the OAuth
client-credentials grant. pf does not implement that grant directly. Use
MongoDB's `mongodb-atlas-mcp-remote` stdio wrapper with inherited
`MDB_MCP_API_CLIENT_ID` and `MDB_MCP_API_CLIENT_SECRET` environment variables.
The Atlas App Connection browser flow is user-delegated access and must not be
treated as equivalent to configuration service-account credentials.

Remote authentication supports configured bearer tokens and OAuth credential
discovery, persistence, refresh, scope challenges, and logout. Credential and
private-cache identity changes invalidate prior private state. macOS persists
OAuth credentials in Keychain and migrates the private profile credential file
only after verified publication. If the user account has no default Keychain,
macOS falls back to the same `0600` credential file used on other platforms
under the `0700` profile directory. `PF_DISABLE_KEYCHAIN=1` selects that portable
backend explicitly for deterministic tests and local troubleshooting.

Servers are optional by default. Required startup failures block the first TUI
or `pf ask` model request; optional failures publish a reduced, degraded
capability set. Terminal `pf ask` completes admitted MCP discovery before its
first model request. JSON and other headless asks start required servers first
and defer optional servers until the turn performs an MCP operation or delegates
MCP capability to a child. Server-filtered searches, selected tools, and feature
operations activate only their target; a broad search activates the broader
catalog. Each server owns its startup and recovery progress. Connection deadlines
cover discovery, fallback, and restarts together. Interactive authentication and
logout change only the affected connection. `/mcp` and `/mcp list` open the same
bounded, secret-free menu, which refreshes its live health snapshot while open.
Noninteractive `pf mcp list` renders the health snapshot to stdout.

Search and explicit selection share bounded schema publication. Definitions are
checked against their runtime, connection, catalog, and credential generations
before execution. Tool argument JSON must be bounded and object-shaped; semantic
schema assertions belong to the server. Image results use the shared tool-result,
provider, and versioned history paths. Saved native images use managed result
artifacts that `read_tool_result` can load without repeating the original tool.

`/mcp reload` evaluates a replacement before publication, so invalid config or
a required-server failure leaves the prior runtime callable.

ACP-provided servers are isolated to their owning ACP session. One-off and
persistent subagents receive an immutable, permission-filtered view of the
parent or ACP session's admitted MCP tools, resources, prompts, and completion
capability. Missing, revoked, stale, or closed authority fails before transport.

## Permissions and Auto Mode

Security is permission-first.

* `permission_mode` controls baseline behavior (`ask`, `auto`, or `full-access`; `yolo` remains an alias)

* `permission` config applies OpenCode-style wildcard rules

* session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; `/permissions` lists stable rule IDs and `/permissions revoke <rule-id>` removes one

* routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy; unknown, destructive, hidden, credential-bearing, public, and overwrite effects remain on the review or approval path

* every unresolved `auto` action receives one narrow security review after configured policy, saved-session rules, grants, and deterministic safe authority; review input always contains the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and other static root tools omit task text. Reviewed commands, shell input, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority. Shell input reviews also include the owned receiving session's launch command, working directory, and bounded current screen after verifying session authority, including on resume. The launch command describes startup only; screen content remains untrusted evidence and input still receives its own review

* the reviewer returns `caution` only for concrete prompt injection or malicious activity; destructive, risky, external, public, remote, unrequested, or task-conflicting actions clear when they are not malicious. A `clear` review authorizes only the exact unchanged action; a `caution`, incomplete-evidence result, or unavailable review holds only that action and returns guidance without opening a human permission screen, disabling tools, or ending the turn

* exact cautions and deterministic incomplete-evidence results are cached only for the current turn; an unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable review opportunity per turn and changed actions remain independently reviewable until the bounded current-turn review budget is exhausted. Each review accepts exactly one valid structured decision even with accompanying prose and may retry one malformed completion within the current attempt's deadline. A transport timeout, transient transport failure, or failed transport call is retried once with a fresh 30-second deadline; permanent transport failures, valid cautions, and cancellation are never retried. Legacy `permission_request_id` input is rejected without prompting

* host-generated review holds retain their advice for the agent and transcript, but carry a saved `review_feedback` marker that excludes them from later security evidence, including after recovery. Old unmarked results remain untrusted evidence; never infer the marker from output text. Quoted review accusations and handling instructions as document or test data are not standalone proof of prompt injection

* execution-memory schema 10 preserves review-feedback provenance while reading older schemas with an unmarked default. Conversation records use optional metadata for marked holds. Older builds may reject the new saved metadata or recovery checkpoints; do not downgrade an active session without preserving its files

* the sandbox backend is configured independently; full access uses an effective backend of `none` without rewriting the saved sandbox setting

Do not add new sensitive tool behavior without integrating it into `src/core/permissions/permissions.zig`.

## Writing a Resize Test

Render bugs that appear during window resize are hard to reason about because the footer is inline (hugs the transcript) rather than pinned to the terminal bottom, and the 100 ms debounce can mask ordering mistakes. The testing rig covers three layers. Pick the lowest layer that can catch the bug.

### Zig unit test (fastest, runs in `zig build test`)

Drive `TranscriptRuntime` against the built-in VT emulator. Assertions are on the cell grid after a sequence of writes and resize calls.

```zig
test "my resize scenario" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, 1024, "hello\n", true);
    try h.flush();

    try h.driveResize(60, 20, 4, true);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(h.alloc);
    try h.vt.rowText(1, &row);
    try std.testing.expectEqualStrings("hello               ", row.items);
}
```

Add it to `src/ui/resize_tests.zig`. See the file header for what each Harness method does.

### tmux end-to-end test (real SIGWINCH, seconds per test)

For bugs that only show up with a real terminal and a real signal (timing, input integration, terminal-emulator quirks), add a scenario to `tests/e2e/tui-resize.test.ts` using the helpers in `tmux-helpers.ts`:

```typescript
test("my scenario", async () => {
    session = await TmuxSession.create({ width: 120, height: 40 });
    await session.waitForText(">", 10_000);
    await session.resizeWindow(80, 30);
    const grid = await session.capturePaneGrid();
    expect(findFooter(grid)).not.toBeNull();
}, 30_000);
```

### Tape-based test (replay a real capture)

For bugs reported by a user, have them run the built binary with an exact
`PF_RECORD=<path>`, or use `PF_DEBUG_RECORD=1` for an automatic private tape.
`PF_DEBUG_RECORD_SILENT_BANNER=1` hides the developer-only startup notice from
the inline transcript without disabling capture; Ctrl+O still shows it. Drop
the tape in `tests/e2e/tapes/<name>.pftape` and assert against the built replay
command:

```bash
./zig-out/bin/pf replay tests/e2e/tapes/my-bug.pftape --golden tests/e2e/tapes/my-bug.txt
```

Check in the golden file and wire a regression test that re-runs `pf replay` in CI and diffs.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the shell

* Do not add a second execution path for the same feature without a clear reason

* Do not document intended behavior as if it already exists

* Do not commit generated state from `.pf/`, `.zig-cache/`, or `zig-out/`

* Do not add a general alternate-screen (`\x1b[?1049h/l`) render path. pf is inline by design except for the three exclusive owner classes represented by `AlternateScreenOwner`: interactive tool-approval review, the full-transcript screen, and catalog menus. Every owner must leave or explicitly hand off the alternate buffer and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes before resolving, cancelling, or shutting down

## Releases

pf publishes no release yet, and publishes none until Arthur runs the [go-live checklist](#go-live-checklist). The pipeline below is built and proven by dry runs and tests with fake uploaders; its publishing steps have never run. No install script or package manager (Homebrew, winget, Scoop) is available, and `pf upgrade` reports that no pf release is published and that pf must be rebuilt from source.

Three locks keep anything from being published by accident: the release workflows run only on manual dispatch, so a push to `main` starts none of them; each defaults to a dry run; and every job that holds a signing key or R2 credentials runs in a protected environment that waits for Arthur's approval. An automatic trigger returns only through the go-live checklist.

### Release pipeline

1. **Prepare Release** (`prepare-release.yml`) bumps `pub const version` in `src/main.zig`, inserts a `## X.Y.Z` entry wrapped in release markers at the top of `CHANGELOG.md`, and opens a pull request. Its `changelog` input defaults to `manual`, which writes a placeholder to replace in the pull request and calls no paid service. `ai` is an opt-in that drafts the entry from the source diff through the AI Gateway and runs the public changelog policy lint; it fails before any branch is created when the `AI_GATEWAY_API_KEY` secret is not set. Merging the pull request publishes nothing.
2. **Release** (`release.yml`) runs on `main`. Its `validate_only` input defaults to `true`; see [Validate release artifacts without publishing](#validate-release-artifacts-without-publishing) for what that run does. With `validate_only` disabled and no `vX.Y.Z` tag yet, the `release` job waits for a second `release` approval, refuses a `CHANGELOG.md` entry that still holds the Prepare Release placeholder, creates the tag, and runs `scripts/publish-release.sh`. That script creates the GitHub Release with every archive, `.sha256`, and `.minisig`, uploads the same files to R2 under `agent/vX.Y.Z/` with `Cache-Control: public, max-age=31536000, immutable`, and writes `agent/latest.txt` last with `Cache-Control: no-cache`. A failed upload names the file and leaves `latest.txt` unchanged.
3. **CDN Backfill** (`cdn-backfill.yml`) restores R2 from GitHub Releases, the canonical copy. `scripts/backfill-release.sh` downloads each release, verifies every `.minisig` and its trusted comment against `src/core/upgrade/release_keys.zig`, and uploads through `scripts/publish-release.sh` with the paths and headers above. Its `dry-run` input defaults to `true` and lists the uploads without writing. A release that fails verification is skipped, reported, and makes the run fail at the end. `latest.txt` moves only when `update-latest` is set and the newest GitHub Release was backfilled and verified, so it never points backward.

The release archives are `pf-linux-x86_64.tar.gz`, `pf-linux-aarch64.tar.gz`, `pf-macos-x86_64.tar.gz`, `pf-macos-aarch64.tar.gz`, and `pf-windows-x86_64.zip`. Each carries a `.sha256` and a `.minisig` whose trusted comment is `file:<archive> version:vX.Y.Z channel:stable`, and a GitHub build provenance attestation.

### Signing and protected environments

Three GitHub Environments hold every release secret, each with Arthur as required reviewer and limited to `main`; no release secret exists at repository level:

* `apple-signing` holds Paneflow's Developer ID Application certificate and an App Store Connect API key. `scripts/sign-and-notarize-macos.sh` signs both macOS binaries as `dev.paneflow.agent` with the certificate of `APPLE_TEAM_ID` and notarizes them with `notarytool`.
* `windows-signing` holds the client secret of the service principal dedicated to pf. `scripts/sign-windows.ps1` signs `pf.exe` with Azure Artifact Signing (account `strivex-signing`, certificate profile `StriveX-Release`) and requires `O=Strivex` in the signer subject.
* `release` holds `PF_MINISIGN_SECRET_KEY` and the R2 credentials. `scripts/sign-release-archives.sh` signs every archive and verifies each signature against the active public key before anything is published.

### Release host

Releases are served from the Cloudflare R2 bucket `paneflow-agent-releases` through the custom domain `https://releases.paneflow.dev`. `pf upgrade` and automatic upgrades fetch only from `https://releases.paneflow.dev/agent`: `latest.txt`, then the archive, `.sha256`, and `.minisig` of that tag, and refuse redirects to another host. The R2 token has Object Read & Write on that bucket only. `R2_ENDPOINT` is the account endpoint `https://<account-id>.r2.cloudflarestorage.com` with no path, because a bucket path makes rclone store every key under a second bucket prefix while reporting success; `scripts/publish-release.sh` refuses it.

### Minisign key and rotation

pf installs an archive only after its SHA-256 sidecar and its minisign signature verify against one of the two public keys in `src/core/upgrade/release_keys.zig`, and its trusted comment names the expected file, version, and channel. `active` signs every release; `next` stays empty until a rotation. The secret key exists only as `PF_MINISIGN_SECRET_KEY` in the `release` environment and in Arthur's offline backup.

To rotate the key without stranding installed builds:

1. Generate the new key pair offline with `minisign -G` and back up its secret key.
2. Put the new public key in `next` and publish a release, still signed by the `active` key, so installed builds that upgrade trust both keys.
3. Once that release has been out long enough, move the new public key to `active`, empty `next`, replace `PF_MINISIGN_SECRET_KEY`, and publish the next release with the new key. Builds older than step 2 cannot verify it and must be reinstalled by hand.

If the secret key leaks, skip the wait: remove the leaked key from both slots, publish a release signed by a new key, and tell users that builds trusting the leaked key need a manual reinstall. CDN Backfill verifies only against the two current slots, so a release signed by a retired key fails its backfill.

### Dev channel

`dev-release.yml` runs only on manual dispatch, and its `dry_run` input defaults to `true`. It builds all five targets from the dispatched commit with `-Dupdate-channel=dev`. Under the `release` approval it signs every archive with the pf minisign key, using the trusted comment `file:<archive> version:vX.Y.Z channel:dev commit:<sha>`, verifies each signature, and runs `scripts/publish-release.sh --dev --dry-run`, which lists every destination without writing.

Dev builds carry minisign signatures only: the macOS binaries are not signed with the Apple Developer ID or notarized, `pf.exe` is not signed with Azure Artifact Signing, and no provenance attestation is produced.

With `dry_run` disabled on `main`, a second `release` approval runs `scripts/publish-release.sh --dev`. It uploads the files to `agent/dev/<commit>/` with the immutable cache header, then writes `agent/dev.json` with `Cache-Control: no-cache` only while `main` still points at that commit. Last, it removes the oldest dev builds beyond the newest 30, never the one `dev.json` names. pf refuses a dev archive whose trusted comment names a commit other than the one in `dev.json`.

`pf upgrade --channel dev` and `pf upgrade --channel stable` store the chosen channel in user settings for manual upgrades, automatic upgrades, and the `ctrl+g` handoff; neither channel has a published build yet.

pf does not distribute the `libpf` JavaScript SDK: there is no npm package and no example applications. CI still builds and tests `sdk/`, and the benchmarks still measure it.

### Release notes

Release notes are public product copy. Describe user-visible behavior, always spell the product `pf`, and omit contributor attribution, tracker references, repository or website work, delivery infrastructure, CI and test details, branch history, and implementation-only refactors. Use commits and pull requests as research evidence only. Changelog formatting and release-marker rules live in `AGENTS.md`.

Do not create tags manually. The workflow owns tag creation.

### Validate release artifacts without publishing

Run **Actions > Release** on `main` with the default inputs; `validate_only`
is enabled by default. This builds all five release targets, runs macOS arm64
PGSO qualification, notarizes both macOS targets under the `apple-signing`
approval, and signs `pf.exe` with Azure Artifact Signing under the
`windows-signing` approval. Under the `release` approval it then signs every
archive with the pf minisign key, verifies each signature against the active
key in `src/core/upgrade/release_keys.zig`, attests build provenance, and runs
`scripts/publish-release.sh --dry-run`, which lists every destination and
header without writing. It does not create a tag, publish a GitHub Release,
upload release files, or change a channel. The signed archives stay available
as the `release-signed` workflow artifact.

The arm64 validation retains both 4 KiB and 16 KiB signature variants of the
same PGSO payload for comparison. Intel retains 4 KiB signatures. Download the
workflow artifacts for matched signed-binary performance checks; notarization
and smoke checks alone do not establish performance equivalence. Normal release
runs keep the existing signing default.

To compare the retained signatures on an isolated runner, run **Actions >
Benchmarks** with `signed_run` set to the successful main validation run ID.
This mode downloads already-notarized binaries and does not access Apple
credentials. It records two alternating startup cohorts, an identical-control
status calibration, and a separate native image-flow memory screen. Review the
retained measurements before changing release signing defaults; successful
measurement is not performance approval.

### Go-live checklist

Run these steps in order, in one session, when Arthur decides the CLI is ready. Each names the files it changes and its rollback. A bad release is always superseded by a higher version; never move `latest.txt` backward, because stable builds refuse downgrades and would stay on the bad version anyway.

1. **Prepare the release.** Dispatch **Actions > Prepare Release** with the bump type and `changelog: manual`, replace the placeholder in the pull request with the public release notes, wait for CI, and merge. Changes `src/main.zig` and `CHANGELOG.md`. Rollback: close the pull request unmerged and delete its `prepare-vX.Y.Z` branch; after a merge nothing is published yet, so the next Prepare Release supersedes it.
2. **Publish.** Dispatch **Actions > Release** on `main` with `validate_only: false`, then approve `apple-signing`, `windows-signing`, and both `release` waits. Changes no file; creates the `vX.Y.Z` tag, the GitHub Release, and the R2 objects under `agent/`. Rollback: a failure before **Create git tag** needs only a fix and a new dispatch. A failure after the tag and before the GitHub Release needs the tag deleted with `git push origin :refs/tags/vX.Y.Z` before the next dispatch. A failure during the R2 upload leaves `latest.txt` unchanged; dispatch **CDN Backfill** for `vX.Y.Z` with `update-latest` set, after a dry run. A release found bad after publication is superseded by a fixed higher version.
3. **Document installation and verification.** In `README.md`, replace "Paneflow Agent does not publish releases yet" with install and verification sections that give the minisign public key from `release_keys.zig`, `minisign -Vm pf-linux-x86_64.tar.gz -P <public key>`, and `gh attestation verify pf-linux-x86_64.tar.gz --repo arthjean/pf`. Update the release-state statements in this section, the AGENTS.md Releasing section, and `NOTICE`. Changes `README.md`, `CONTRIBUTING.md`, `AGENTS.md`, and `NOTICE`. Rollback: revert the documentation commit.
4. **Update the Windows notes.** Remove "Release downloads and `pf upgrade`" from the README list of features not yet available on Windows, and add the recovery note: if an upgrade is interrupted and `pf.exe` is missing, rename `pf.exe.old` in the same directory back to `pf.exe`. Changes `README.md`. Rollback: revert the commit.
5. **Upgrade from a previous build.** On Linux, macOS, and Windows, build the commit before the version bump with `zig build -Doptimize=ReleaseSafe`, run its `pf upgrade`, and confirm that `pf --version` reports `X.Y.Z` and that a second `pf upgrade` reports pf up to date. Changes no file. Rollback: a failed upgrade leaves the installed binary unchanged; fix pf and publish a higher version.
6. **Decide the release trigger.** Keep `release.yml` dispatch-only, or restore a push trigger that releases when a merged version bump has no tag. Changes `.github/workflows/release.yml` and `ReleaseWorkflowTests` in `scripts/tests/test_publish_release.py`. Rollback: restore the dispatch-only trigger.
7. **Restore the dev channel.** Dispatch `dev-release.yml` with `dry_run: false` once and approve both `release` waits. Then restore its automatic trigger after a successful CI run on `main`, and have the `metadata` job resolve the commit from `github.event.workflow_run.head_sha`. Changes `.github/workflows/dev-release.yml` and `DevReleaseWorkflowTests` in `scripts/tests/test_publish_release.py`. Rollback: return it to dispatch-only; installed dev builds move on at the next dev build.

## Benchmarks

Startup latency benchmarks run automatically on every PR and push to `main` via `.github/workflows/bench.yml`.

The workflow builds a ReleaseSafe binary, then uses [hyperfine](https://github.com/sharkdp/hyperfine) to measure wall-clock time for six paths:

| Command                | Budget | What it measures                                   |
| ---------------------- | ------ | -------------------------------------------------- |
| `pf` (startup)         | 2ms    | Binary launch through CLI dispatch (no TTY needed) |
| `pf help`              | 2ms    | Minimal startup, pure text output                  |
| `pf status --json`     | 2ms    | Config read + JSON serialization                   |
| `pf background --json` | 2ms    | Background record read                             |
| `pf doctor --json`     | 2ms    | System checks, subprocess spawns                   |
| `pf sessions --json`   | 2ms    | Session directory read                             |

On PRs the check **fails** if any command exceeds its budget.

The table is the authoritative Linux CI contract. Non-Linux local runs report
raw means for comparison but do not assign a substitute product budget because
the host process and dynamic-loader floor can independently exceed 2ms. The
process baseline is diagnostic only and is never subtracted.

The startup benchmark uses `PF_BENCH=1`, which runs through CLI dispatch and exits before TTY initialization.

To run locally:

```bash
brew install hyperfine             # macOS (one-time)
./benchmarks/startup.sh            # full run (100 iterations, builds ReleaseSafe)
./benchmarks/startup.sh --quick    # quick run (20 iterations)
```

CI uses `--runs 100` with a reduced warmup and skips the build step because the
workflow builds ReleaseSafe first. Results are written to
`benchmarks/results/` (gitignored).

The libpf runtime job measures cold startup, warm prompts, host-tool calls,
stream throughput, and Agent cleanup. Its direct Pi comparison uses an external
Zig HTTP server, Pi 0.84.4, and three alternating 100-sample rounds. On Bun,
native libpf must match or beat Pi p50 and stay within 0.25 ms of Pi p95.
The Node comparison is report-only because Node's bundled fetch client and
Pi's dispatcher have different warm-request overhead. Both runtimes still
require valid measurements, 300 samples, and exactly one inference request per
prompt. Native/Wasm latency, host-tool, and resource gates remain blocking.
Live model latency and bulk-stream throughput remain informational.

```sh
zig build-exe benchmarks/libpf/fake-inference-server.zig -O ReleaseSafe -femit-bin=/tmp/libpf-bench-server
node benchmarks/libpf/bench-competitive.mjs --server /tmp/libpf-bench-server --pi-root /tmp/libpf-pi --out benchmarks/results/libpf
```

Build the SDK artifacts and install the pinned Pi package first, as shown in
`.github/workflows/bench.yml`. Raw per-prompt samples remain in the output directory.

## Before Marking a PR Ready

Minimum checklist:

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Run `zig build`, then exercise the change with `./zig-out/bin/pf`.
3. Push the feature branch and open a draft PR immediately.
4. Require all five **Full CI** jobs and the final ship gate to pass for the exact current commit before marking the PR ready.
5. Update `README.md` if user-facing behavior changed.
