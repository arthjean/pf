[PRD]
# PRD: Windows Native Support

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-10-01 | Arthur Jean | Initial draft from the verified Windows audit, a native Zig 0.16 build on Windows 11, and web, documentation, and codebase research |
| 1.1 | 2026-10-01 | Arthur Jean | EP-001 review: binary-level checks of US-002 and US-003 move to US-008, which first produces `pf.exe`; the Linux suite gate compares against the baseline |

## Problem Statement

pf runs only on macOS and Linux. On Windows it does not compile, and the parts that would compile would misbehave silently.

1. **pf does not build for Windows.** A native `zig build` on Windows 11 with Zig 0.16.0 stops at 31 compile errors for the binary and 136 for the test target. These are only the first analysis wave, because Zig analyzes lazily and more errors sit behind them. A Linux cross-build from the same host succeeds, so every error is Windows-specific.
2. **The errors come from five POSIX assumptions repeated across the tree.**
   - `std.Io.File.Permissions.fromMode/toMode` appears 248 times in 49 files.
   - `std.posix.pid_t` and `std.posix.fd_t` are used as integers, while on Windows they are `HANDLE` pointers (142 `pid_t` references).
   - `getenv("HOME")` is read at 67 sites in 30 files, with a `USERPROFILE` fallback at only one of them.
   - `std.posix.poll`, `read`, `termios`, `sigaction`, and `setsockopt` are `@compileError` on Windows in the 0.16 standard library.
   - About 150 existing `.windows` guards turn features into silent no-ops.
3. **The existing Windows code path is unsafe.** The shell tool would run commands with `cmd /C` (`src/core/execution/command_runner.zig:1633`), while every permission decision parses POSIX sh (`src/core/shell_command/command_lex.zig`). Timeouts kill only the direct child (`command_runner.zig:2377`), so grandchildren keep the output pipes open and collection can hang. The Zig standard library also resolves a bare executable name in the child's working directory before `PATH` (`lib/std/Io/Threaded.zig:15676-15710`). A planted `git.exe` in an untrusted repository would therefore run.
4. **Windows users get silent data loss instead of errors.** `HOME` is usually unset on Windows, so `config_runtime.zig:368` loads an empty configuration. Credentials and sessions resolve to no profile, and `syncVerifiedDir` returns `OperationUnsupported` (`src/core/shared/io.zig:620`), which fails every durable settings and session write.
5. **The checkout itself breaks the toolchain.** With `core.autocrlf=true` and no `.gitattributes`, files are checked out with CRLF, and `zig fmt --check src/main.zig` fails on a clean tree.

**Why now:** Arthur's primary workstation is Windows 11. Paneflow already ships on Windows: it is installed at `C:\Program Files\PaneFlow` on the reference machine, and its MCP server runs there. Every comparable coding agent now runs natively on Windows: Claude Code, Codex CLI, Gemini CLI, and Copilot CLI in experimental mode. Today the only way to use pf on Windows is WSL. A previous attempt left Windows fixture binaries in `zig-out/bin` but no source in the tree, so the work restarts from the measured baseline above.

## Overview

pf becomes a native Windows x86_64 program for Windows 10 version 1809 or later and Windows 11. It targets Windows Terminal and the VS Code integrated terminal, and is built as `x86_64-windows-gnu` with the existing `link_libc = true`. The port is organized around a small platform layer in `src/core/shared/io.zig` and the existing host abstractions in `src/core/hosts/host.zig`. That layer provides home and temp resolution, a private-state file API, canonical paths, durable replace, and platform-neutral process ids, so that module ports call one API instead of repeating platform branches. The headless path (`pf help`, `pf status`, `pf ask`) ships first. The interactive TUI follows on a Windows console backend inside `TerminalState`, validated through a ConPTY driver because tmux does not exist on Windows.

Command execution keeps pf's permission-first model intact. When Git Bash is available, pf runs commands with `bash -lc`, so the existing POSIX parsing, fast paths, and allow rules remain sound. Otherwise pf runs PowerShell (`pwsh`, then Windows PowerShell 5.1) and treats every PowerShell command as opaque: no parsed fast path, no wildcard allow rule, and only exact-command approvals and configured denies apply. In auto mode, each such command goes through the security review. `cmd.exe` is never the execution shell. Every process tree runs in a Job Object, so timeouts, cancellation, and pf's own exit reap all descendants. Every executable pf launches by name is resolved to an absolute path from `PATH` without searching the working directory. The model's turn context states the Windows version, the shell dialect, and path conventions, which addresses the most reported failure of competing tools: models emitting bash into PowerShell.

Delivery is phased. **Release 1 (Windows preview)** contains all P0 stories: the platform layer, a green native build, headless commands, the TUI, safe command execution, line-ending-preserving edits, workspace containment, a passing Windows unit test suite, and documentation. **Release 2 (Windows parity)** contains the P1 stories: terminal capability tuning, background process control, URL opening and integrations, an end-to-end subset, a Windows CI job, DPAPI-encrypted credentials, interactive MCP OAuth, and hosted terminal sessions over ConPTY. **Release 3** contains the P2 stories: hosted sessions that survive restarts, plus clipboard and notifications. Distribution (artifacts, install channels, signing), the CI workflow change, and the secret-storage backend are decisions reserved for Arthur by the repository's CLAUDE.md. They are recorded in Open Questions, with the dependent stories gated on them.

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| Native Windows compile errors (binary and test targets) | 0 (baseline 31 and 136) | 0 |
| Windows unit tests passing among non-skipped tests | 100% | 100% |
| Share of the 9,545 Zig tests skipped on Windows, each with a stated reason | 5% or less | 3% or less |
| Release 1 P0 stories certified DONE | 100% of EP-001 and EP-002 P0 stories | 100% of Release 1 and Release 2 stories |
| Orphaned child processes 2 s after a command timeout or pf exit, measured by the Job Object tests | 0 | 0 |
| Working sessions Arthur runs with `pf.exe` on Windows (count of `%USERPROFILE%\.pf\sessions` entries) | 20 or more | 200 or more |

## Target Users

### Maintainer on a Windows workstation
- **Role:** Arthur, sole maintainer of pf, who ports fx changes and builds Paneflow, with Windows 11 as the primary machine.
- **Behaviors:** Works in Windows Terminal and VS Code with PowerShell 7 and Git Bash, and keeps WSL Ubuntu available. Runs other coding agents natively on Windows.
- **Pain points:** Cannot run or develop pf natively on the main machine. CRLF checkouts break `zig fmt --check`. There is no Windows verification signal.
- **Current workaround:** Runs pf and its tests inside WSL, or uses Claude Code and Codex CLI on Windows instead of pf.
- **Success looks like:** `zig build` and `zig build test` pass natively, and `pf.exe` runs daily in Windows Terminal with the same permission guarantees as on Linux.

### Paneflow user on Windows
- **Role:** A developer who uses Paneflow on Windows and wants Paneflow Agent inside the same panes.
- **Behaviors:** Uses PowerShell by default, may have Git for Windows installed, and edits repositories that contain CRLF files.
- **Pain points:** Paneflow Agent is unavailable on Windows. Competitors sometimes emit bash into PowerShell or leave orphaned processes.
- **Current workaround:** Runs Claude Code or Codex CLI in Paneflow panes, or runs pf through WSL with Linux paths.
- **Success looks like:** pf starts from PowerShell or Git Bash, finds the same profile either way, edits CRLF files without corrupting them, and kills every process it starts.

### Contributor running verification
- **Role:** An implementation agent or contributor executing `/implement-epic` and `/review-epic` on Windows.
- **Behaviors:** Must exercise the built binary end to end before declaring work ready, as required by AGENTS.md.
- **Pain points:** The TUI verification harness depends on tmux, which does not exist natively on Windows.
- **Current workaround:** None on Windows. Verification happens on Linux or macOS only.
- **Success looks like:** A scripted ConPTY driver and a Windows end-to-end subset provide a deterministic signal.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **Claude Code:** Runs natively on Windows. Its Bash tool uses Git Bash when Git for Windows is installed, otherwise a PowerShell tool. It installs through `install.ps1`, and its sandbox works only under WSL2 ([setup docs](https://code.claude.com/docs/en/setup)). pf follows the same shell preference order.
- **Codex CLI:** Runs natively in PowerShell, with a native Windows sandbox built on dedicated sandbox users, ACL boundaries, and firewall rules. It requires Windows 10 1809 or later ([Codex Windows sandbox](https://developers.openai.com/codex/windows/windows-sandbox)). pf does not ship an OS sandbox on any platform, so Windows keeps parity rather than adding one.
- **GitHub Copilot CLI:** Native Windows support is experimental and WSL is recommended. The top complaints are that users cannot select Git Bash and that models emit bash syntax into PowerShell ([copilot-cli #508](https://github.com/github/copilot-cli/issues/508), [copilot-cli #1034](https://github.com/github/copilot-cli/issues/1034)). pf exposes `PF_WINDOWS_SHELL` and reports the dialect to the model.
- **Gemini CLI:** Installed through npm and runs PowerShell on Windows, with no native sandbox.
- **Market gap:** No competitor keeps a parsed, fail-closed permission model consistent with the shell that actually executes. pf's existing static-command allow rules and parsed fast path stay sound under Git Bash and are disabled, not approximated, under PowerShell.

### Best Practices Applied
- ConPTY (`CreatePseudoConsole`, Windows 10 1809 or later) for pseudo terminals, and virtual terminal mode for input and output ([CreatePseudoConsole](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole), [classic vs VT](https://learn.microsoft.com/en-us/windows/console/classic-vs-vt)).
- Console input read as UTF-16 (`ReadConsoleW`) because console `ReadFile` does not reliably deliver UTF-8 ([analysis](https://nullprogram.com/blog/2020/05/04/)).
- Job Objects with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and `TerminateJobObject` for process trees. Nested jobs are allowed since Windows 8 (Microsoft Learn, retrieved through Context7).
- DPAPI (`CryptProtectData`, user scope) instead of Credential Manager, whose blob limit of 2,560 bytes is too small for some OAuth token sets.
- Executables resolved to absolute paths before spawning, to avoid binary planting. `.bat` and `.cmd` arguments with CR, LF, or NUL are rejected, which the Zig 0.16 `std.process.spawn` already enforces against the BatBadBut class ([CVE-2024-24576](https://nvd.nist.gov/vuln/detail/CVE-2024-24576)).
- Terminal features detected rather than assumed. Windows Terminal 1.25 supports the kitty keyboard protocol and synchronized output ([WT 1.25](https://github.com/microsoft/terminal/releases/tag/v1.25.622.0)).

*Full research sources available in project documentation.*

## Assumptions & Constraints

### Assumptions (to validate)
- Under ConPTY in Windows Terminal and VS Code, `ReadConsoleW` with `ENABLE_VIRTUAL_TERMINAL_INPUT` delivers the escape sequences pf's parser decodes: arrows with modifiers, bracketed paste, focus events, and the kitty keyboard protocol where supported. Evidence: Microsoft VT input documentation. Validated by US-009.
  - **Validated (US-009):** `tests/e2e/fixtures/windows-vt-input-probe-report.json` records 23 inputs sent through `conpty-driver` to a probe that reads like pf's backend. Every input arrives byte for byte as sent: plain and modified arrows (`CSI 1;2A`, `CSI 1;3A`, `CSI 1;5A`, `CSI 1;5D`, `CSI 1;3C`), Home `CSI H`, End `CSI F`, Delete `CSI 3~`, Enter `0d`, Backspace `7f`, Tab, Shift+Tab `CSI Z`, a lone Escape, a two-line bracketed paste, non-ASCII text with a surrogate pair, Ctrl+C as `03`, Alt+b `1b 62`, a focus-in report `CSI I`, and a kitty `CSI 97;5u`. Bracketed paste and focus reports arrive only after the client enables modes 2004 and 1004. No sequence pf's parser needs is missing or altered, so US-010 needs no `ReadConsoleInputW` key-event fallback.
- The Zig 0.16 standard library populates `Stat.nlink` from `NumberOfLinks` on Windows. Evidence: `File.zig` exposes `nlink` on all platforms. Validated by US-004.
  - **Validated (US-004):** `lib/std/Io/Threaded.zig:3989` fills `nlink` from `FILE_STANDARD_INFORMATION.NumberOfLinks`, and the native Windows test `private file verification rejects hard links and junctions` (`src/core/shared/io.zig`) observes `nlink == 2` after `CreateHardLinkW`. No `GetFileInformationByHandle` fallback is needed.
  - **Standard library gaps found on Windows (EP-001), handled in `src/core/shared/io.zig`:** a `dirOpenFile` with `follow_symlinks = false` returns an asynchronous handle marked blocking, so the first read reaches `unreachable` (fixed once by wrapping the `Io` vtable on Windows); `Dir.rename` maps `STATUS_SHARING_VIOLATION` to `error.Unexpected` (durable replace uses `MoveFileExW` instead); `File.Permissions.readOnly` and `setReadOnly` name a missing Windows constant and do not compile there; `setPermissions` needs write-attribute access that read handles lack (private state skips it on Windows); `Dir.hardLink` returns `OperationUnsupported`; and Windows refuses to rename a directory while handles below it are open (session publication closes and reopens the new session).
- A child spawned with `start_suspended` through `std.process.spawn` exposes a thread handle that pf can resume after `AssignProcessToJobObject`. Evidence: `Threaded.zig` sets `create_suspended` and returns `thread_handle`. Validated by US-017.
- Most Windows developers who use git have Git for Windows, and therefore Git Bash, installed. Evidence: Git for Windows bundles bash, and Claude Code relies on it when present. The PowerShell fallback covers the rest.
- The compile errors hidden behind the first analysis wave are bounded and fixable inside the stories that own each module. Evidence: the test target's first wave (136 errors) maps entirely onto the five root causes. US-008 absorbs residual errors.
- DPAPI user-scope keys are available in interactive desktop sessions. They may be unavailable over OpenSSH key-based logons, which US-028 handles explicitly.

### Hard Constraints
- Zig 0.16 standard library only. No dependency outside the standard library (AGENTS.md, What Not To Do). Win32 functions missing from `std.os.windows` are declared as `extern` in pf.
- Linux and macOS behavior, tests, the 2 ms Linux CI startup budget, and the binary size thresholds must not regress. Every Windows branch is selected at comptime.
- Module ownership from AGENTS.md: `src/main.zig` stays a composition root, UI code owns no product state, and gateway code owns no product state.
- Permission-first security: every sensitive tool path integrates with `src/core/permissions/permissions.zig`, and no Windows path may bypass it.
- No silent degradation: a feature that is unavailable on Windows returns an explicit error that names the feature. It must never do a no-op that reports success.
- The repository's CLAUDE.md reserves authentication and provider access, distribution, `pf upgrade`, and `.github/workflows/` for Arthur's decision.
- Public copy names the product Paneflow Agent and the command `pf`, and prose uses no em dashes.

## Quality Gates

These commands must pass for every user story:
- `zig build -Dtarget=x86_64-linux-gnu` - the Linux target still compiles
- `zig build -Dtarget=aarch64-macos` - the macOS target still compiles
- `zig build test` run inside WSL Ubuntu on a copy of the checkout in the WSL filesystem - no test that passes on the baseline commit fails or crashes; run the focused tests for the changed paths while developing and the full suite before handoff. A DrvFs mount such as `/mnt/c` without the `metadata` option ignores `chmod`, so private-state tests fail there. The baseline `ee1dafb` already has 8 failing or crashing tests outside this PRD (`model_catalog`, `chat_completions`, `file_index`, `command_effect` printf forms, `subagent` adapter and tool host, `assistant_stream`); they are compared by name and do not block a story
- `zig fmt --check src/` - formatting, valid on a Windows checkout from US-001 onward
- `zig build` on Windows - before US-008, the build log contains no compile error located in a file the story changed; from US-008 onward, the native build succeeds
- `zig build test` on Windows - from US-024 onward, the native unit test suite passes
- `bash ./scripts/check-public-surface.sh` - public surface audit, run through Git Bash
- `python -m scripts.pgso.corpus --manifest scripts/pgso/corpus.json --list` - required when a `tests/e2e/*.test.ts` file is added, renamed, or removed

For stories that change runtime behavior, additional gates:
- From US-008 onward, run `.\zig-out\bin\pf.exe help` and `.\zig-out\bin\pf.exe status --json` from PowerShell with `HOME` unset. Both exit 0 with empty stderr.
- Exercise the story's happy path through the freshly built `.\zig-out\bin\pf.exe`, never a `pf` from `PATH`. Drive TUI stories through the ConPTY driver from US-009 and attach its capture.
- The handoff states that Full CI did not run until US-026 is decided and implemented.

## Epics & User Stories

### EP-001: Windows platform layer

Give every module one Windows-capable implementation of the platform primitives it needs, so that module ports stop duplicating platform logic and stop compiling POSIX-only calls.

**Definition of Done:** `src/core/shared/io.zig` and `src/core/shared/profile_paths.zig` expose Windows-backed Unicode process entry, home and temp resolution, private-state files, canonical paths, and durable replace. The native build log contains zero errors in files changed by EP-001. Linux and macOS targets build, and the Linux suite passes in WSL.

#### US-001: Normalize line endings and document the Windows build
**Description:** As the maintainer on Windows, I want the repository to check out with LF line endings and a documented Windows build so that `zig fmt --check src/` and byte-compared fixtures behave the same as on Linux.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Given a `.gitattributes` with `* text=auto eol=lf` and `binary` entries for `*.pftape`, image fixtures, and any byte-compared golden file, when the repository is cloned on Windows with `core.autocrlf=true`, then `git ls-files --eol src/main.zig` reports `w/lf`.
- [ ] Given that fresh Windows clone, when `zig fmt --check src/` runs, then it exits 0.
- [ ] Given a renormalization commit, when `git diff --stat` compares the result with the previous tree on Linux, then no file content changes except line endings.
- [ ] Given a file marked `binary`, when it is checked out on Windows, then its bytes are identical to the blob in the index.
- [ ] Given an existing Windows clone created before this story, when `zig fmt --check src/` still fails on CRLF files, then the CONTRIBUTING Windows section names `git add --renormalize .` followed by a fresh checkout as the fix.
- [ ] Given `CONTRIBUTING.md`, when a contributor follows its new Windows section, then it lists Zig 0.16.0, the native `zig build` command, running Linux tests in WSL, and Git Bash for `scripts/check-public-surface.sh`.

#### US-002: Read Unicode arguments and environment on Windows
**Description:** As a Windows user, I want pf to receive my command-line arguments and environment exactly as typed so that non-ASCII paths and prompts reach pf intact.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given Windows, when `src/main.zig` builds `std.process.Args` and `std.process.Environ.Block`, then it uses the WTF-16 command line from `GetCommandLineW` and the global environment block. The POSIX construction at `src/main.zig:3564-3572` is unchanged.
- [ ] Given the WTF-16 command line `pf.exe ask "résumé de C:\Users\Zoë\projet"`, when pf decodes it into arguments on Windows, then the prompt's bytes equal the UTF-8 encoding of the typed text. Launching the built `pf.exe` from PowerShell is verified in US-008, the first story with a native binary.
- [ ] Given Windows, when `io_mod.getenv("Path")` and `io_mod.getenv("PATH")` are called, then both return the same value. On POSIX, lookups remain case-sensitive.
- [ ] Given `PF_BENCH=1` on Linux, when the startup benchmark path runs, then it performs no allocation and no Io initialization added by this story, because the Windows branch is selected at comptime.
- [ ] Given an argument containing an unpaired UTF-16 surrogate, when pf parses arguments, then the argument is preserved as WTF-8 and pf does not abort.

#### US-003: Resolve the profile home and temp directory on Windows
**Description:** As a Windows user, I want pf to find one profile directory and one temp directory whether I start it from PowerShell or Git Bash so that settings, sessions, and credentials never disappear silently.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-002

**Acceptance Criteria:**
- [ ] Given Windows, when the home resolver runs, then it returns `USERPROFILE`, else `HOME`. On POSIX, it returns `HOME` exactly as today.
- [ ] Given the repository after this story, when production code is searched for `getenv("HOME")`, then the only matches are inside the resolver. All 67 current sites in 30 files call the resolver.
- [ ] Given Windows, when the temp resolver runs, then it returns `TEMP`, else `TMP`, else the result of `GetTempPathW`. On POSIX, it returns `TMPDIR`, else `/tmp`. All 8 production `TMPDIR orelse "/tmp"` sites and `src/builtins/skills.zig:268` use it.
- [ ] Given `HOME` unset and `USERPROFILE=C:\Users\a`, when pf loads configuration on Windows, then it reads `C:\Users\a\.pf\settings.json`, and the status snapshot reports that path in text and JSON (`pf status --json` reports it on Linux). The same check through the built `pf.exe` is verified in US-008.
- [ ] Given `HOME` set to a directory different from `USERPROFILE`, as Git Bash exports it, when the home resolver and configuration loading run on Windows, then they use the `.pf` directory under `USERPROFILE`. Running the built `pf.exe` from Git Bash and from PowerShell is verified in US-008.
- [ ] Given Windows, when a path argument starts with `~\` or `~/`, then it expands against the resolved home.
- [ ] Given neither `USERPROFILE` nor `HOME` is set on Windows, when `runBeforeInteractive` starts, then it returns exit code 1 after printing a message naming `USERPROFILE`, before CLI dispatch and before any file is written. The same check through the built `pf.exe status` is verified in US-008.

#### US-004: Create and verify private state files through one API
**Description:** As a security-conscious user, I want every private pf file created and verified through one platform API so that credential and session files keep their protections on POSIX and compile and stay protected on Windows.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given `src/core/shared/io.zig`, when this story lands, then it exposes `ensurePrivateDir`, `createPrivateFile`, `verifyPrivateFile`, `verifyPrivateDir`, and `isWritable`. The POSIX backends keep modes 0700 and 0600 and the existing mode and `nlink` checks.
- [ ] Given Windows, when a private file or directory is created, then it inherits the profile directory ACL. No mode conversion is attempted.
- [ ] Given Windows, when a private file is verified, then pf checks that it is a regular file, not a reparse point, and has `nlink == 1`. This story records whether the standard library populates `nlink` and falls back to `GetFileInformationByHandle` if it does not.
- [ ] Given production code after this story, when it is searched for `fromMode(` and `toMode(`, then the only matches are inside `io.zig`. Writability checks use `Permissions.readOnly()`.
- [ ] Given `scripts/check-public-surface.sh`, when a file outside `io.zig` reintroduces `Permissions.fromMode` or `toMode` in production code, then the audit fails and names the file.
- [ ] Given Windows, when `syncVerifiedDir` is called after a file flush, then it returns success, so settings and session writes complete.
- [ ] Given a credential file that is a hard link (`nlink == 2`) or a junction, when pf loads it on Windows, then pf rejects it with the existing insecure-file error.

#### US-005: Canonicalize paths and replace files durably on Windows
**Description:** As a Windows user, I want pf to resolve real paths and retry file replacement within a bounded budget so that workspace identity is stable and antivirus or indexer locks do not lose my settings.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-004

**Acceptance Criteria:**
- [ ] Given Windows, when `realpathAlloc` or `dirRealpathAlloc` runs, then it opens a handle and returns `GetFinalPathNameByHandleW` output with symlinks and junctions resolved, the `\\?\` prefix removed, `\\?\UNC\server\share` rewritten to `\\server\share`, and the drive letter uppercased.
- [ ] Given a path comparison helper, when it compares two paths on Windows, then it ignores ASCII and Unicode case using NTFS upcase semantics. On POSIX it compares bytes.
- [ ] Given a durable replace that hits a sharing violation or access denied error, when it retries, then it makes up to 10 attempts within 2,000 ms total, and after that it returns an error naming the path.
- [ ] Given two pf processes that write `settings.json` concurrently on Windows, when both writes finish, then both complete without error and the file contains valid JSON from one of the writes.
- [ ] Given a new session and a resumed session on Windows, when the session directory is published (`src/core/session/session_log.zig:4273`), then publication succeeds and leaves no staging directory behind.
- [ ] Given `src/core/shared/debug_trace.zig`, when it appends to a trace file on Windows, then it uses `std.Io` file positioning, not `std.c.lseek`.
- [ ] Given a workspace path longer than 260 characters, when pf canonicalizes it and reads a file below it, then both operations succeed.
- [ ] Given a dangling junction, when pf canonicalizes it, then it returns `FileNotFound` without aborting.

---

### EP-002: Native Windows runtime

Make `pf.exe` build natively and run its headless commands, then its interactive TUI, inside Windows Terminal and the VS Code terminal.

**Definition of Done:** `zig build` succeeds natively on Windows. `pf help`, `pf status --json`, and `pf ask --json` against the fake gateway exit 0 with empty stderr from PowerShell with `HOME` unset. A ConPTY-driven TUI session starts, accepts a prompt, renders a reply, resizes, exits on Ctrl+C, and restores the console modes.

#### US-006: Replace POSIX process ids with a platform-neutral type
**Description:** As a maintainer, I want pf to represent process ids with its own type so that process tracking compiles on Windows and stops depending on `std.posix.pid_t`.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given a `ProcessId` type (`u32`) owned by pf, when the repository is searched after this story, then `std.posix.pid_t` appears only inside POSIX-only backends selected at comptime. All 142 current references are migrated.
- [ ] Given Windows, when `src/tools/shell/process_provider.zig` parses a pid string, then it parses into `ProcessId`.
- [ ] Given Windows, when `src/core/execution/process_tree.zig` refreshes a snapshot, then it returns `error.Unsupported` until US-019, and it no longer fails to compile.
- [ ] Given Windows, when the `/status` process summary renders (`src/core/app/app_commands.zig:2367`), then it shows the pid from `GetCurrentProcessId`, memory from `K32GetProcessMemoryInfo`, and the handle count from `GetProcessHandleCount`.
- [ ] Given Windows, when the image normalizer must stop (`src/core/images/image_attachments.zig:1211`), then pf terminates it through the child handle instead of `std.posix.kill`.
- [ ] Given a pid that no longer exists, when a status line queries it, then it reports the process as exited without an error.

#### US-007: Move pf sockets onto std.Io.net
**Description:** As a Windows user, I want web fetches and the OAuth loopback callback to use the standard library's portable network layer so that they compile and work on Windows.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given `src/tools/web/http_fetch.zig`, when it opens connections, then it uses `std.Io.net` instead of `posix.system.socket` and `fcntl`, and its existing tests pass in WSL.
- [ ] Given Windows, when `web_fetch` requests an `http://127.0.0.1` fixture, then it returns the fixture body.
- [ ] Given `src/core/auth/browser_callback.zig`, when the loopback listener waits for the OAuth redirect, then it uses `std.Io` accept and receive deadlines instead of `std.posix.poll` and `std.c.setsockopt`.
- [ ] Given `src/core/upgrade/upgrade_helpers.zig`, when it compiles for Windows, then the platform constant is optional instead of a `@compileError`, the receive timeout uses `std.Io`, and `pf upgrade` still prints the existing disabled message.
- [ ] Given Windows, when the herdr hook would run, then it is disabled at comptime and records a debug trace entry.
- [ ] Given the callback port is already in use, when a login starts, then pf reports the port conflict and exits non-zero within 5 s.

#### US-008: Reach a green native Windows build with headless commands
**Description:** As the maintainer, I want the native build to succeed and the headless commands to run so that every later story has a real binary to exercise.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-002, US-003, US-004, US-005, US-006, US-007

**Acceptance Criteria:**
- [ ] Given a Windows checkout, when `zig build` runs natively, then it succeeds with zero errors.
- [ ] Given a residual compile error in a feature owned by a later story (interactive TUI, console prompts, hosted terminals), when it is resolved here, then the feature returns an explicit error that names the feature and points to the Windows support documentation, and the later story removes that gate.
- [ ] Given `src/acp/jsonrpc.zig:326`, when ACP reads stdin on Windows, then it uses `std.Io.File.stdin()` streaming.
- [ ] Given PowerShell with `HOME` unset and `USERPROFILE` set, when `.\zig-out\bin\pf.exe help` and `.\zig-out\bin\pf.exe status --json` run, then both exit 0 with empty stderr, and the status JSON reports `settings_path` as `%USERPROFILE%\.pf\settings.json` (moved from US-003).
- [ ] Given `pf.exe ask "résumé de C:\Users\Zoë\projet"` launched from PowerShell against the fake gateway, when the CLI parser receives the prompt, then its bytes equal the UTF-8 encoding of the typed text (moved from US-002).
- [ ] Given Git Bash exporting `HOME` to a directory different from `USERPROFILE`, when `pf.exe status --json` runs from Git Bash and from PowerShell, then both runs report the same `settings_path` under `USERPROFILE` (moved from US-003).
- [ ] Given neither `USERPROFILE` nor `HOME` is set, when `pf.exe status` runs, then it exits 1 with the message `pf cannot find your profile directory: set USERPROFILE.` and writes no file (moved from US-003).
- [ ] Given the fake gateway from `tests/e2e`, when `pf.exe ask --json "say hi"` runs, then it prints the gateway reply as JSON and exits 0.
- [ ] Given no `%USERPROFILE%\.pf` directory, when `pf.exe ask --json "say hi"` runs against the fake gateway, then pf creates the profile and session directories through the US-004 API and exits 0.
- [ ] Given a ReleaseSafe build, when hyperfine runs `pf.exe help` 20 times on the reference machine, then the p50 is 40 ms or less, and the measurement is recorded in the story handoff.
- [ ] Given stripped ReleaseSafe builds of `pf.exe` and of the Linux x86_64 binary, when their sizes are compared, then `pf.exe` is at most 10% larger.
- [ ] Given `pf.exe` started without arguments in a console before US-010, when interactive mode is requested, then pf exits 1 with the message that interactive mode is not yet available on Windows, without leaving the console in raw mode.

#### US-009: Validate assumption: VT console input reaches pf intact through ConPTY
**Description:** As a contributor verifying TUI work on Windows, I want a scripted ConPTY driver and a measured input probe so that console-input assumptions are proven before the TUI backend depends on them.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Given a ConPTY module under `src/core/terminal/` that wraps `CreatePseudoConsole`, `ResizePseudoConsole`, and `ClosePseudoConsole` with a dedicated output reader thread, when its unit test runs `cmd.exe /c echo pf-conpty`, then the captured output contains `pf-conpty`.
- [ ] Given `zig build conpty-driver`, when the driver runs a command with a size, a script of timed inputs and resizes, and an output path, then it writes the captured output and exits with the child's exit code.
- [ ] Given a probe program that enables `ENABLE_VIRTUAL_TERMINAL_INPUT` and reads with `ReadConsoleW`, when the driver sends arrows with Shift, Ctrl, and Alt, Home, End, Delete, Enter, Backspace, Tab, Escape, a bracketed paste, and a non-ASCII string, then the probe report lists the exact bytes received for each input, and the report is committed under `tests/e2e/fixtures/`.
- [ ] Given the probe report, when a sequence pf's escape parser needs is missing or altered, then the story records the gap and the fallback used by US-010 in this PRD's Assumptions.
- [ ] Given a child that exits while input is pending, when the driver detects the exit, then it stops writing, drains output, and returns within 5 s without deadlocking `ClosePseudoConsole`.

#### US-010: Run the TUI on the Windows console
**Description:** As a Windows user, I want pf's interactive interface to work in Windows Terminal and the VS Code terminal so that I can use pf daily without WSL.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-008, US-009

**Acceptance Criteria:**
- [ ] Given `TerminalState` in `src/ui/shell_runtime.zig`, when this story lands, then it stores `std.Io.File` handles instead of `std.posix.fd_t`, and its posix, windows, and wasi backends are selected at comptime.
- [ ] Given Windows, when raw mode is enabled, then pf saves the original input and output console modes and code pages, enables virtual terminal input and window input, disables line, echo, and processed input, enables virtual terminal processing, and sets the output code page to UTF-8. On normal exit it restores all saved values.
- [ ] Given Windows, when `pollInput` waits, then it waits on the console input handle, consumes non-key records, and turns `WINDOW_BUFFER_SIZE_EVENT` into a resize notification for `src/ui/resize_runtime.zig`.
- [ ] Given Windows, when `queryLayout` runs, then it reads the visible window size through `GetConsoleScreenBufferInfo`. `src/ui/ask_presentation.zig` and `TranscriptRuntime.stdout_file` no longer use fd constants or comptime `File.stdout()` defaults.
- [ ] Given the ConPTY driver types `héllo ✓` and Enter, when the prompt reaches the fake gateway, then its bytes equal the UTF-8 encoding of the typed text.
- [ ] Given the ConPTY driver resizes the console from 120x30 to 80x24, when the next frame renders, then it uses 80 columns within 500 ms.
- [ ] Given the ConPTY driver sends 100 printable keystrokes, when it measures the time from each write to its echo in the composer, then the p95 is 50 ms or less.
- [ ] Given a console where `SetConsoleMode` cannot enable virtual terminal processing, when pf starts interactively, then it exits 1 with a message that names Windows Terminal and the VS Code terminal as supported hosts, instead of printing raw escape sequences.
- [ ] Given stdin redirected from a file, when interactive mode starts, then pf exits with the same not-a-terminal error and exit code as on Linux.

#### US-011: Read console prompts outside the TUI
**Description:** As a Windows user, I want `pf setup`, sign-in flows, and pasted authorization codes to read from the console correctly so that I can configure and authenticate pf on Windows.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-010

**Acceptance Criteria:**
- [ ] Given one console prompt helper with POSIX `termios` and Windows console-mode backends, when this story lands, then `src/core/auth/login_flow.zig`, `src/core/auth/grok_oauth.zig`, and `pf setup` (`src/core/cli/cli_surface.zig:2079-2174`) use it, and the gates added by US-008 for these flows are removed.
- [ ] Given `pf setup` on Windows, when the user types an API key, then no character is echoed, Backspace removes the last character, and Enter submits.
- [ ] Given a sign-in that waits for Enter or a pasted code, when the user presses Ctrl+C, then the flow cancels and pf exits 130.
- [ ] Given stdin is a pipe, when `pf setup` reads the key, then it reads one line from the pipe without changing console modes.
- [ ] Given console modes changed by a prompt, when the prompt returns or fails, then the original modes are restored.

#### US-012: Handle Ctrl+C and console close events
**Description:** As a Windows user, I want Ctrl+C, Ctrl+Break, and closing the window to stop pf with the session flushed so that no turn is lost and my shell is never left in raw mode.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-010

**Acceptance Criteria:**
- [ ] Given `GracefulExitSigintGuard` (`src/core/app/app_entry_runtime.zig:38`), when it is installed on Windows, then it ignores `CTRL_C_EVENT` through `SetConsoleCtrlHandler` during the handoff and restores the previous handler afterward.
- [ ] Given `pf ask` running headless, when Ctrl+C arrives, then the turn is canceled, the session is flushed, and pf exits 130. When Ctrl+Break arrives, pf exits 143.
- [ ] Given a second Ctrl+C within 2 s of the first in headless mode, when it arrives, then pf exits immediately with 130.
- [ ] Given the TUI is running, when `CTRL_CLOSE_EVENT` arrives, then pf restores the saved console modes and flushes the session within 1,000 ms.
- [ ] Given the TUI is running in raw mode, when Ctrl+C is pressed, then it arrives as input byte `0x03` and follows the same key handling as on Linux.

#### US-013: Tune terminal capabilities and path input for Windows
**Description:** As a Windows user, I want pf to use the colors, keys, and path syntax my terminal supports so that rendering and `@` file references behave as expected.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-010

**Acceptance Criteria:**
- [ ] Given `WT_SESSION` is set, or `TERM_PROGRAM=vscode`, when pf selects a color depth, then it uses truecolor.
- [ ] Given the kitty keyboard protocol query, when the terminal answers (Windows Terminal 1.25 or later), then pf enables CSI-u decoding. Otherwise it keeps the legacy decoding with no visible delay beyond 100 ms.
- [ ] Given the theme queries (`?2031`, OSC 11), when the terminal does not answer within 100 ms, then pf falls back to `PF_THEME` or the default theme without waiting again during the session.
- [ ] Given `@C:\dev\pf\src\main.zig`, `@src\main.zig`, and `@src/main.zig` in the composer on Windows, when the file picker resolves them, then all three resolve to the same file, and backslash is not treated as an escape character on Windows.
- [ ] Given `pf doctor` on Windows, when it looks for `gh`, then it searches `PATH` with the `.exe`, `.com`, `.cmd`, and `.bat` extensions.

---

### EP-003: Safe command execution on Windows

Run model-proposed commands through a shell whose syntax matches pf's permission analysis, and contain every process pf starts.

**Definition of Done:** The shell tool runs commands through Git Bash when available and PowerShell otherwise, never `cmd.exe`. Permission analysis matches the executing dialect. Timeouts and cancellation terminate whole process trees within 2 s. MCP stdio servers resolve through `PATH` without the working directory, log their stderr, and are reaped when pf exits.

#### US-014: Resolve executables without searching the working directory
**Description:** As a user opening untrusted repositories, I want pf to launch only executables found on my `PATH` so that a planted `git.exe` or `git.bat` in a repository never runs.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] Given a bare executable name on Windows, when pf resolves it, then it searches only the absolute entries of `PATH` with the `.exe`, `.com`, `.cmd`, and `.bat` extensions, skips the working directory and relative entries, and returns an absolute path.
- [ ] Given pf's internal spawns of `git`, `gh`, `docker`, the execution shell, and every configured MCP stdio command, when they start on Windows, then argv[0] is the resolved absolute path.
- [ ] Given a repository root containing `git.exe` and `git.bat` fixtures that write a marker file, when pf runs its git integrations in that repository, then no marker file is created and the `PATH` git runs.
- [ ] Given a command that is not found, when pf tries to start it, then the error names the command and states that it was not found on `PATH`.
- [ ] Given a `.cmd` or `.bat` target whose arguments contain CR, LF, or NUL, when pf starts it, then pf surfaces the standard library's `InvalidBatchScriptArg` as an error that names the argument position.
- [ ] Given Linux or macOS, when pf resolves executables, then behavior is unchanged.

#### US-015: Select the Windows execution shell and tell the model its dialect
**Description:** As a Windows user, I want pf to run commands in Git Bash when I have it and in PowerShell otherwise, and to tell the model which one, so that proposed commands use the right syntax.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-014

**Acceptance Criteria:**
- [ ] Given `PF_WINDOWS_SHELL` unset or `auto`, when pf selects the shell, then it uses `PF_GIT_BASH_PATH` if set. Otherwise it uses `bin\bash.exe` beside the resolved `git.exe` install root, then `%ProgramFiles%\Git\bin\bash.exe`, then `pwsh.exe`, then `powershell.exe`. It never selects `cmd.exe`.
- [ ] Given the bash dialect, when the shell tool runs a command, then it uses the existing POSIX launcher (`-lc` with the script on stdin) through the selected `bash.exe`.
- [ ] Given the PowerShell dialect, when the shell tool runs a command, then it runs `-NoProfile -NonInteractive -EncodedCommand` with a UTF-16LE script. The script sets UTF-8 output encoding, and the tool result carries `$LASTEXITCODE` or a non-zero exit code when the last pipeline fails.
- [ ] Given the model turn context (`src/builtins/context.zig:2078`), when a turn starts on Windows, then it reports the Windows product name and build from `RtlGetVersion`, the dialect (`bash (Git Bash)` or `PowerShell <version>`), and path conventions for that dialect.
- [ ] Given `pf doctor` on Windows, when it runs, then it reports the selected shell, its path, and why it was selected.
- [ ] Given `PF_WINDOWS_SHELL=bash` and no Git Bash found, when the shell tool runs, then it returns an error naming `PF_GIT_BASH_PATH` and does not fall back to PowerShell.
- [ ] Given neither Git Bash nor PowerShell is found, when the shell tool runs, then it returns an error stating that no supported shell was found.

#### US-016: Match permission analysis to the execution dialect
**Description:** As a security-conscious user, I want pf's permission decisions to depend on the shell that actually runs the command so that a command judged harmless in one dialect cannot do something else in another.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-015

**Acceptance Criteria:**
- [ ] Given the dialect selected by US-015, when a command reaches admission, then the dialect value (`posix_sh` or `powershell`) is available to `src/core/permissions/permissions.zig` and `src/core/tooling/tool_admission.zig` without being inferred per call site.
- [ ] Given the PowerShell dialect, when a configured `bash` allow rule contains a wildcard, then it never matches (`ruleTargetMatches`, `permissions.zig:1587`). Exact-command allows, session approvals of the exact command, and configured denies still apply.
- [ ] Given the PowerShell dialect in auto mode, when a command is unresolved by configured and session rules, then it always goes to the security review. The parsed fast path and `command_effect` plans are not used.
- [ ] Given the bash dialect on Windows, when `src/core/shell_command/command_effect.zig` evaluates a command, then it uses the POSIX plans instead of returning `unsupported_platform`.
- [ ] Given `"git *": "allow"` in the profile, the PowerShell dialect, and the command `git status; Remove-Item -Recurse x`, when the command is admitted, then it is not auto-allowed.
- [ ] Given either dialect, when a command contains `Remove-Item -Recurse`, `rd /s`, `del /s`, `format`, `diskpart`, `reg delete`, `Set-ExecutionPolicy`, or `Invoke-Expression`, then `src/core/tooling/command_policy.zig` attaches a destructive or risky note, including when it is invoked through `cmd //c` or `powershell -c` from bash.

#### US-017: Contain command process trees with Job Objects
**Description:** As a user, I want every command pf runs, and everything that command starts, to stop when it times out, when I cancel it, or when pf exits so that no orphaned process keeps running or holds my files.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-006, US-008

**Acceptance Criteria:**
- [ ] Given a shell-tool or hook command on Windows, when it starts, then pf spawns it suspended, assigns it to a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, and resumes it. This validates the start-suspended assumption.
- [ ] Given a command whose descendants run longer than its 2 s timeout, when the timeout fires, then `TerminateJobObject` ends every descendant, and output collection completes within 2 s after the kill.
- [ ] Given a running command, when its process exits while output is streaming, then a waiter thread reports the exit status, replacing the Windows no-op in `ProcessObserver.observe` (`command_runner.zig:2300`).
- [ ] Given pf itself is terminated with `TerminateProcess`, when its job handles close, then every process in its jobs exits.
- [ ] Given pf runs inside a parent job, as in the VS Code terminal, when it creates a job for a command, then assignment succeeds through nested jobs.
- [ ] Given the timeout test, when a process snapshot is taken 2 s after the kill, then it contains no descendant of the command.

#### US-018: Run MCP stdio servers safely on Windows
**Description:** As a user configuring MCP servers such as `npx` packages, I want them to start, report errors, and stop completely on Windows so that MCP tools work and no `node.exe` survives pf.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-014, US-017

**Acceptance Criteria:**
- [ ] Given an MCP stdio server on Windows, when it starts, then it runs in a Job Object and its stderr is captured by a blocking reader thread instead of `.ignore` (`src/core/mcp/server_transport.zig:928`).
- [ ] Given the configuration `npx -y @modelcontextprotocol/server-everything`, when pf starts it, then `npx.cmd` resolves through US-014 and the server's tools are listed.
- [ ] Given a server that exits during startup after writing to stderr, when pf shows MCP status, then it includes the last stderr lines.
- [ ] Given a server that spawned grandchild processes, when pf exits or restarts the server, then no process from that server's job remains after 2 s.
- [ ] Given MCP configuration files under the profile home, when pf discovers them on Windows, then it reads them through the US-003 resolver (`src/builtins/mcp.zig:514-667`).

#### US-019: Control background processes on Windows
**Description:** As a user who runs long-lived background commands, I want to list, stop, and kill them on Windows with protection against reused process ids so that pf never terminates an unrelated process.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-017

**Acceptance Criteria:**
- [ ] Given a background process on Windows, when pf records its identity, then the token combines the process id and the creation time from `GetProcessTimes`.
- [ ] Given a stop or kill request, when the token still matches, then pf terminates the process's Job Object.
- [ ] Given `src/core/execution/process_tree.zig` on Windows, when it captures a snapshot, then it uses `CreateToolhelp32Snapshot`.
- [ ] Given this story, when the host capabilities are built, then `process_control` is true on Windows (`src/core/hosts/host.zig:266`).
- [ ] Given a process that already exited, when a stop request arrives, then pf reports that it already exited.
- [ ] Given a process id reused by an unrelated process, when a stop request arrives, then pf refuses it with a token mismatch error.

---

### EP-004: Files, workspace, and integrations

Make file edits, workspace identity, and everyday integrations correct on Windows file systems and conventions.

**Definition of Done:** Edits preserve each file's line endings. Workspace keys and file-tool containment are canonical and case-insensitive on Windows, with reparse points resolved. URLs open in the default browser. Skills install, images, and git integrations work without POSIX tools.

#### US-020: Preserve line endings in file edits
**Description:** As a user editing CRLF repositories, I want pf's edits to match text regardless of line endings and to keep the file's existing endings so that edits succeed and diffs stay minimal.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] Given a CRLF file and an `old_string` written with LF, when `edit_file` runs, then the match succeeds by comparing line-ending-normalized text and mapping offsets back to the original bytes.
- [ ] Given a file whose CRLF count is greater than its bare LF count, when `edit_file` writes the replacement, then the replacement uses CRLF. Otherwise it uses LF.
- [ ] Given any edit, when the file is written, then bytes outside the replaced span are unchanged.
- [ ] Given `write_file` replacing an existing file, when the new content is written, then it uses the existing file's dominant line ending. New files are written as provided.
- [ ] Given an `old_string` copied from `read_file` output of a CRLF file, when `edit_file` runs, then it succeeds.
- [ ] Given an `old_string` that matches twice after normalization, when `edit_file` runs, then it returns the existing ambiguity error.
- [ ] Given Linux or macOS and an LF file, when the existing edit tests run, then they pass unchanged.

#### US-021: Enforce workspace identity and containment on Windows
**Description:** As a security-conscious user, I want workspace keys and file-tool boundaries to use canonical, case-insensitive paths with links resolved so that one workspace has one identity and no path escapes it.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-005, US-008

**Acceptance Criteria:**
- [ ] Given `C:\dev\pf`, `c:/dev/pf/`, and `C:\DEV\PF`, when pf resolves the `workspaces["<path>"]` key (`src/core/config/config_runtime.zig:393`), then all three map to one entry. Existing keys are normalized when read, without rewriting the user's file.
- [ ] Given a junction inside the workspace that points to `C:\Windows`, when a file tool writes through it, then the write is rejected as outside the workspace.
- [ ] Given the workspace `C:\dev\pf` and the target `C:\DEV\PF\src\x.zig`, when a file tool checks containment, then the target is inside.
- [ ] Given an 8.3 short path such as `C:\PROGRA~1\...`, when it is checked, then it is canonicalized to its long form before comparison.
- [ ] Given tool inputs with `\` or `/` separators, when pf resolves them, then both forms are accepted. Workspace-relative paths in tool output use `/`.
- [ ] Given a file mutation targeting a reserved device name such as `NUL`, `CON.txt`, or `com1.log` in any path component, when it is admitted on Windows, then it is rejected before any file is opened, with a message naming the reserved name.
- [ ] Given a session saved on Linux with `workspace_root` `/home/a/x`, when it is resumed on Windows, then pf exits 1 with a message stating that the session belongs to another platform.

#### US-022: Open URLs and run integrations on Windows
**Description:** As a Windows user, I want sign-in links to open in my browser and skills, images, and git integrations to work without POSIX tools so that everyday flows need no manual workaround.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-003, US-014

**Acceptance Criteria:**
- [ ] Given Windows, when pf opens a URL, then it calls `ShellExecuteW` with the `open` verb (`src/core/hosts/url_opener.zig`), and `url_open` is true in the Windows host capabilities. `PF_NO_OPEN_BROWSER` is still honored.
- [ ] Given a URL containing `&`, `%`, and spaces, when pf opens it, then the browser receives the exact URL.
- [ ] Given no default browser, when `ShellExecuteW` fails, then pf prints the URL with an instruction to open it manually and continues waiting for the callback.
- [ ] Given a skill install from a git URL, when it runs on Windows, then it clones into the US-003 temp directory and removes the clone afterward.
- [ ] Given an image attachment on Windows, when pf normalizes it, then it uses the native PNG downscaler without spawning `sips`. File URIs use the form `file:///C:/path/image.png`.
- [ ] Given a request to copy an image to the clipboard on Windows before US-032, when it runs, then pf reports that image clipboard copy is unavailable on Windows.

---

### EP-005: Windows quality signal

Give every change a deterministic Windows verification signal and document what Windows users get.

**Definition of Done:** `zig build test` passes natively on Windows, with every skipped test justified. A Windows end-to-end subset runs with Bun, including a ConPTY TUI smoke. A Windows CI job exists once Arthur decides its form. README and CONTRIBUTING describe Windows support exactly as shipped.

#### US-023: Compile the unit test suite for Windows
**Description:** As the maintainer, I want `zig build test` to compile on Windows so that unit tests become a Windows signal.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] Given a Windows checkout, when `zig build test` compiles, then it reports zero compile errors (baseline: 136 in the first wave).
- [ ] Given test assertions on private-state permissions, when they are migrated, then they use an `expectPrivateFile` helper next to the US-004 API, and on POSIX they still assert modes 0600 and 0700.
- [ ] Given POSIX-only tests (`mkfifo`, `chmod`, `sigaction`, pseudo-terminal fixtures, `src/core/shared/darwin_process_spawn.zig`, `/bin/sh` spawns), when they compile for Windows, then each is skipped with `if (comptime builtin.os.tag == .windows) return error.SkipZigTest;` and a comment stating the reason.
- [ ] Given test fixtures that use `/tmp/...` as an absolute workspace root, when they run on Windows, then they use paths derived from `std.testing.tmpDir`, because `/tmp/x` is not absolute on Windows.
- [ ] Given Linux in WSL, when `zig build test` runs after the migration, then the same tests pass as before.

#### US-024: Pass the unit test suite on Windows
**Description:** As the maintainer, I want every non-skipped unit test to pass on Windows so that regressions in the Windows port are caught locally.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-023

**Acceptance Criteria:**
- [ ] Given a Windows checkout, when `zig build test` runs natively, then it passes.
- [ ] Given the test summary, when skipped tests are counted on Windows, then they are 5% or less of all tests (at most 477 of 9,545), and each skip has a stated reason.
- [ ] Given a test that fails on Windows because of a product defect, when it is handled, then the product is fixed or the defect is filed as a story in this PRD. It is never skipped without a stated platform reason.
- [ ] Given `PF_TEST_PRODUCT_EXE` set by `build.zig`, when tests spawn the product binary on Windows, then they find `pf.exe`.

#### US-025: Run a Windows end-to-end subset
**Description:** As a contributor, I want the deterministic end-to-end tests that do not need tmux to run on Windows, plus a ConPTY TUI smoke test, so that headless, ACP, MCP, and interactive behavior are verified end to end.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008, US-009, US-010

**Acceptance Criteria:**
- [ ] Given `tests/e2e`, when this story lands, then the tmux-free helpers (fake gateway, environment, and binary path helpers) live in a module that does not require tmux, and `tests/e2e/tmux-helpers.ts` re-exports them so the existing 57 importing files keep working.
- [ ] Given Windows, when the e2e binary path helper runs, then it resolves `zig-out\bin\pf.exe`.
- [ ] Given a documented list of Windows-capable e2e files (CLI, ACP, MCP, and non-TUI), when the Windows subset runs with Bun, then all listed files pass.
- [ ] Given a new `tests/e2e/windows-tui-smoke.test.ts` driven by the US-009 ConPTY driver, when it runs, then it starts pf, sends a prompt, observes the fake gateway reply, resizes, sends Ctrl+C, and asserts exit code and restored console state.
- [ ] Given the new test file, when the corpus check runs, then the file has exactly one classification in `scripts/pgso/corpus.json`, as an intentional exclusion with the reason that it requires Windows ConPTY, and it appears in `tests/e2e/ci-shard-weights.json`.
- [ ] Given the subset is run without `pf.exe` built, when it starts, then it fails immediately with a message to run `zig build`.

#### US-026: Add a Windows CI job
**Description:** As the maintainer, I want Windows built and tested automatically so that Linux or macOS changes cannot silently break Windows.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-024, US-025

**Acceptance Criteria:**
- [ ] Given Arthur's recorded decision on Open Question Q2, when this story starts, then the workflow change follows that decision. This story must not start without it, as required by the CLAUDE.md rule on `.github/workflows/`.
- [ ] Given a pull request, when the Windows job runs, then it builds `pf.exe` in ReleaseSafe, runs `zig build test`, runs the US-025 Windows subset, and smoke-tests `pf.exe help` and `pf.exe status --json` with empty stderr.
- [ ] Given a failing Windows step, when the job reports, then the failing step and test file are named in the job summary.
- [ ] Given the existing four Full CI runners, when the Windows job is added, then their configuration and shard weights are unchanged.

#### US-027: Document Windows support
**Description:** As a Windows user, I want the README and CONTRIBUTING to state exactly what works on Windows and how to configure it so that I can install from source and choose my shell.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-015, US-016

**Acceptance Criteria:**
- [ ] Given `README.md`, when a user reads the Windows section, then it lists the supported versions (Windows 10 1809 or later, Windows 11, x86_64), the supported terminals (Windows Terminal and the VS Code terminal), building from source, and the profile location `%USERPROFILE%\.pf`.
- [ ] Given `README.md`, when a user reads the shell section, then it documents `PF_WINDOWS_SHELL` and `PF_GIT_BASH_PATH`, the selection order, and that PowerShell commands always require an exact approval or the security review.
- [ ] Given features that are not yet available on Windows, when they are documented, then they are listed as unavailable. Nothing is documented as shipped before its story is DONE.
- [ ] Given key bindings that do not work in Windows Terminal 1.25 or later, when the README Windows section is read, then each one is listed with its alternative, or the section states that every binding works.
- [ ] Given `NOTICE`, when this story lands, then it records the Windows port as a notable modification of fx without altering existing notices.
- [ ] Given `src/core/slash_commands/command_specs.zig`, when help text lists environment variables, then it includes the two new variables.

---

### EP-006: Windows parity

Close the remaining feature gaps between Windows and the POSIX platforms after the preview ships.

**Definition of Done:** Credentials are encrypted at rest with DPAPI once Arthur confirms the backend. Interactive MCP OAuth works. The terminal tool hosts interactive sessions over ConPTY, and those sessions survive pf restarts. Clipboard and notifications work through Win32.

#### US-028: Encrypt stored credentials with DPAPI
**Description:** As a Windows user, I want my OAuth tokens and API keys encrypted to my Windows account at rest so that another account or a copied disk image cannot read them.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-004, US-008

**Acceptance Criteria:**
- [ ] Given Arthur's recorded decision on Open Question Q3, when this story starts, then the backend follows that decision. This story assumes DPAPI unless the decision differs.
- [ ] Given Windows, when the `SecretStore` (`src/core/hosts/host.zig:114`) writes a secret, then it stores the output of `CryptProtectData` with user scope and `CRYPTPROTECT_UI_FORBIDDEN` in the existing profile file layout.
- [ ] Given an existing plaintext credential file, when pf first reads it on Windows, then it encrypts and durably replaces it, and the plaintext no longer exists on disk.
- [ ] Given a second standard Windows account on the same machine, when it reads the credential file with read access granted, then `CryptUnprotectData` fails and no token is recovered.
- [ ] Given decryption fails, for example over an OpenSSH key-based logon without DPAPI keys or after a profile move, when pf loads credentials, then it renames the file to a `.unreadable` backup, reports that a new sign-in is required, and never deletes the file.
- [ ] Given Linux or macOS, when credentials are stored, then behavior is unchanged.

#### US-029: Complete interactive MCP OAuth on Windows
**Description:** As a user of remote MCP servers that require OAuth, I want the authorization flow to complete on Windows so that those servers are usable.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-007, US-022

**Acceptance Criteria:**
- [ ] Given `src/core/mcp/mcp_auth.zig`, when this story lands, then `listenPinnedCallback` uses `std.Io.net`, and the Windows guard returning `InteractiveMcpAuthorizationUnsupported` (`mcp_auth.zig:1204`) is removed.
- [ ] Given a remote MCP server that requires OAuth, when the user authorizes it on Windows, then the browser opens through US-022, the callback is received, and the server's tools are listed.
- [ ] Given the user closes the browser without authorizing, when the existing authorization window expires, then pf reports the timeout and leaves the server unauthorized.
- [ ] Given the pinned callback port is in use, when authorization starts, then pf reports the conflict and exits the flow within 5 s.

#### US-030: Host terminal sessions over ConPTY
**Description:** As a user, I want the terminal tool to run interactive programs on Windows so that the agent can drive REPLs, installers, and long-running processes like it does on Linux.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-009, US-015, US-017

**Acceptance Criteria:**
- [ ] Given Windows 10 1809 or later, when host capabilities are built, then `terminalSupportForOs(.windows)` returns `.supported` (`src/core/hosts/host.zig:258`).
- [ ] Given a hosted session on Windows, when it starts, then it runs the US-015 shell in a ConPTY inside a Job Object, and a reader thread feeds output to the existing terminal engine without changing `src/core/terminal/engine.zig` semantics.
- [ ] Given the bash and PowerShell dialects, when a session bootstraps, then it uses a bootstrap script written for that dialect.
- [ ] Given the agent sends input to `python` running in a hosted session, when it reads the screen, then the REPL output appears.
- [ ] Given a resize request, when it is applied, then `ResizePseudoConsole` changes the session size and the next screen read reflects it.
- [ ] Given the session's shell exits, when the session is queried, then it is marked exited with the exit code.
- [ ] Given pf exits, when its job handles close, then every process of every hosted session exits.

#### US-031: Keep hosted sessions across pf restarts on Windows
**Description:** As a user, I want hosted terminal sessions to keep running and to be reattachable after pf restarts on Windows so that long-running work is not lost.

**Priority:** P2
**Size:** L (5 pts)
**Dependencies:** Blocked by US-019, US-030

**Acceptance Criteria:**
- [ ] Given a hosted session on Windows, when pf exits normally, then a detached supervisor process keeps the ConPTY and its Job Object alive.
- [ ] Given the supervisor, when pf restarts and resumes the session, then it reconnects over an AF_UNIX control socket (supported by `std.Io.net` on Windows 10 1803 and later), and the screen is restored through the existing recovery path.
- [ ] Given the supervisor's identity token from US-019, when pf reconnects, then a reused process id is refused.
- [ ] Given the supervisor crashed, when pf resumes, then the session is reported as lost, and no process from its job remains.

#### US-032: Use the Windows clipboard and notifications
**Description:** As a Windows user, I want copy commands and turn-completion notifications to work so that the TUI matches its Linux behavior.

**Priority:** P2
**Size:** S (2 pts)
**Dependencies:** Blocked by US-010

**Acceptance Criteria:**
- [ ] Given a copy command on Windows, when it runs, then text is placed on the clipboard as `CF_UNICODETEXT` through `OpenClipboard` and `SetClipboardData`.
- [ ] Given an image copy on Windows, when it runs, then the image is placed on the clipboard as `CF_DIB`, and the message added by US-022 is removed.
- [ ] Given the clipboard is held by another process, when pf copies, then it retries for up to 500 ms and then reports that the clipboard is busy.
- [ ] Given a turn completes while the window is unfocused, when notifications are enabled, then pf emits an OSC 9 notification on Windows Terminal, and otherwise a terminal bell.

#### US-033: Load linked skills through symlink authorities on Windows
**Description:** As a Windows user who links skills into a workspace, I want linked skill candidates to load and reopen as they do on Linux so that `skill_symlink_authorities` and contained links work on Windows.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-021

**Acceptance Criteria:**
- [ ] Given a contained directory link under a workspace skill root, when skills are discovered and the candidate is reopened, then `openValidatedSkillCandidate` returns it as current instead of failing with `IsDir` (filed by the EP-005 review from `loadVisibleSkills discovers and reopens a contained linked workspace candidate`).
- [ ] Given a link whose target lies under an external or configured symlink authority, when skills are discovered on Windows, then the linked candidate and its linked metadata load (`loadVisibleSkills discovers linked metadata through external authority`, `loadVisibleSkills discovers a linked candidate resolved via external symlink authority`).
- [ ] Given those three tests, when this story lands, then their Windows skips are removed and they pass natively on Windows.
- [ ] Given a link outside every authority, when skills are discovered on Windows, then it is still rejected with the same diagnostic as on Linux.

---

## Functional Requirements

- FR-01: The system must build natively on Windows x86_64 with Zig 0.16 as `x86_64-windows-gnu` using the existing `link_libc = true`, and must keep building for every existing Linux and macOS target.
- FR-02: On Windows, the system must resolve the profile home from `USERPROFILE`, else `HOME`, and the temp directory from `TEMP`, else `TMP`, else `GetTempPathW`. Every reader of the home or temp directory must use these resolvers.
- FR-03: The system must create and verify private state only through the `io.zig` private-state API. No other production file may call `Permissions.fromMode` or `toMode`.
- FR-04: The system must never run model-proposed commands with `cmd.exe`. It must use Git Bash when available and PowerShell otherwise, as controlled by `PF_WINDOWS_SHELL` and `PF_GIT_BASH_PATH`.
- FR-05: When the execution dialect is PowerShell, the system must not auto-allow a command through a wildcard rule or a parsed fast path.
- FR-06: The system must resolve every executable it launches by name to an absolute path from the absolute entries of `PATH`, and must never search the working directory.
- FR-07: The system must place every command, hook, MCP stdio server, and hosted session process tree in a Job Object that kills the tree on timeout, cancellation, and pf exit.
- FR-08: When an edit replaces text in an existing file, the system must preserve the file's dominant line ending and leave bytes outside the replaced span unchanged.
- FR-09: On Windows, the system must compare workspace paths case-insensitively after resolving symlinks, junctions, `\\?\` prefixes, and 8.3 short names.
- FR-10: The system must state the Windows version, the shell dialect, and path conventions in the model turn context on Windows.
- FR-11: The system must NOT report success for a feature that is unavailable on Windows. It must return an error naming the feature.
- FR-12: The system must restore the original console modes and code pages on every exit path it controls, including Ctrl+C, Ctrl+Break, and console close.

## Non-Functional Requirements

- **Performance:** `pf.exe help` has a p50 of 40 ms or less over 20 hyperfine runs on the reference Windows 11 machine. This is an informational budget, and the Linux CI budget of 2 ms per command is unchanged. A resize renders the next frame within 500 ms. Typed input appears in the composer within 50 ms at p95, measured through the ConPTY driver.
- **Security:** No bare executable name resolves inside the working directory (0 occurrences in the US-014 fixture test). No PowerShell command is auto-allowed by a wildcard rule (0 in the US-016 tests). A credential file that is a reparse point or has `nlink` greater than 1 is rejected (100% in the US-004 tests). From US-028, a second Windows account recovers 0 tokens from the credential file.
- **Accessibility:** Every key binding available on Linux works in Windows Terminal 1.25 or later. Each exception is listed in the README Windows section. With `NO_COLOR=1`, pf emits 0 SGR color sequences in the ConPTY driver capture.
- **Scalability:** Workspace paths up to 400 characters and file names with non-ASCII characters are created, read, edited, and canonicalized in tests (US-005, US-021).
- **Reliability:** Durable replace retries up to 10 times within 2,000 ms on sharing violations. 0 orphaned processes remain 2 s after a timeout, cancellation, or pf exit. A console close flushes the session within 1,000 ms.
- **Compatibility:** Windows 10 version 1809 (build 17763) or later and Windows 11, x86_64. Windows Terminal and the VS Code integrated terminal are supported. A console without virtual terminal processing gets an explicit exit with exit code 1. The stripped ReleaseSafe `pf.exe` is at most 10% larger than the stripped ReleaseSafe Linux x86_64 binary.

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | First run, no profile | `%USERPROFILE%\.pf` does not exist | Create the private profile directory through the US-004 API, then continue onboarding | None beyond the existing onboarding |
| 2 | No home variable | `USERPROFILE` and `HOME` unset | Exit 1 before writing any file | "pf cannot find your profile directory: set USERPROFILE." |
| 3 | Settings locked by antivirus | Sharing violation during a durable replace | Retry up to 10 times within 2,000 ms, then fail with the path | "Could not replace <path> because another program has it open. Close it and retry." |
| 4 | Git Bash missing with `PF_WINDOWS_SHELL=bash` | No `bash.exe` found | Shell tool returns an error and does not fall back | "Git Bash not found. Set PF_GIT_BASH_PATH or PF_WINDOWS_SHELL=auto." |
| 5 | No supported shell | Neither Git Bash nor PowerShell found | Shell tool disabled for the session | "No supported shell found. Install Git for Windows or PowerShell 7." |
| 6 | Planted executable | `git.exe` or `git.bat` at the repository root | Run the `PATH` git, never the planted file | None |
| 7 | Command times out with descendants | A descendant outlives the timeout | Terminate the job, complete output collection within 2 s | Existing timeout message |
| 8 | pf killed externally | `TerminateProcess` on pf | Job handles close and all descendants exit | None |
| 9 | Console window closed | `CTRL_CLOSE_EVENT` | Restore console modes and flush the session within 1,000 ms | None |
| 10 | Non-VT console | `SetConsoleMode` cannot enable virtual terminal processing | Exit 1 before rendering | "pf needs Windows Terminal or the VS Code terminal on this system." |
| 11 | CRLF file edited | `old_string` written with LF | Match after normalization, write with CRLF | None |
| 12 | Junction escape | A junction in the workspace points outside it | Reject the file mutation | Existing path-outside-workspace message |
| 13 | Long path | A workspace path longer than 260 characters | All file operations succeed | None |
| 14 | Reserved device name | A model asks to write `NUL` or `CON.txt` | Reject the file mutation before opening | "<name> is a reserved Windows device name." |
| 15 | Cross-platform resume | A Linux session resumed on Windows | Exit 1 without modifying the session | "This session belongs to another platform. Resume it on the original machine or start a new session." |
| 16 | `.cmd` argument injection | An argument with CR or LF sent to `npx.cmd` | Refuse to start the process | "Argument <n> contains a line break, which Windows batch files cannot receive safely." |
| 17 | Callback port busy | The OAuth loopback port is already bound | Exit the flow within 5 s | "Port <port> is in use. Close the program using it and retry." |
| 18 | DPAPI unavailable | OpenSSH key-based logon or a moved profile | Rename the credential file to `.unreadable` and request a new sign-in | "Your saved credentials cannot be decrypted on this logon. Sign in again." |
| 19 | Two pf instances write settings | Concurrent writes to `settings.json` | The existing lock file serializes writes through `NtLockFile` | None |
| 20 | MCP server crashes at startup | Non-zero exit with stderr output | Show the last stderr lines in MCP status | Server-provided stderr |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Hidden compile waves are larger than measured | Med | Med | Root-cause stories (US-002 to US-007) remove whole classes of errors. US-008 absorbs residual errors with explicit feature gates. The error count is tracked per story. |
| 2 | ConPTY or VT input omits sequences the parser needs | Med | High | US-009 measures every needed sequence before US-010. A missing sequence gets a recorded fallback through `ReadConsoleInputW` key events. |
| 3 | Models emit bash syntax when the dialect is PowerShell | High | Med | US-015 states the dialect in every turn context. Git Bash is preferred when present. PowerShell commands always pass an exact approval or the security review. |
| 4 | The PowerShell opaque policy increases review latency and cost | High | Low | The policy is accepted as the security trade-off for v1. A PowerShell-aware parser is a separate decision in Open Question Q4. |
| 5 | Linux or macOS regress while the Windows port touches shared code | Med | High | Comptime-selected branches, Linux tests in WSL and macOS cross-builds as gates for every story, and Full CI before any release. |
| 6 | Antivirus locks cause intermittent write failures | Med | Med | Bounded retries in US-005 and actionable errors. Edge case 3 is covered in tests. |
| 7 | Private-state protection on Windows relies on ACL inheritance | Low | High | The profile directory under `USERPROFILE` is private to the user by default. US-004 rejects links. DPAPI encryption lands in US-028. |
| 8 | Git Bash path conversion rewrites arguments that look like POSIX paths | Med | Med | The model context documents the Git Bash path convention. pf passes the script on stdin, which avoids argument conversion of the script itself. |
| 9 | The scope of 32 stories delays a usable preview | Med | Med | Phased releases: Release 1 contains only P0 stories, and the headless path ships before the TUI inside it. |
| 10 | No Windows CI until Arthur decides Open Question Q2 | High | Med | US-024 and US-025 give a local signal. The handoff states that Full CI did not run. |

## Non-Goals

What this version explicitly does NOT include:

- **A PowerShell-aware command parser for auto-approval.** PowerShell commands stay opaque in this PRD because a parser mismatch is a security boundary failure. Revisit through Open Question Q4.
- **An OS sandbox on Windows** (AppContainer, restricted tokens, sandbox users). pf ships no OS sandbox on Linux or macOS either, and its `sandbox` keys are inert (`src/core/config/config_runtime.zig:3806`).
- **Release artifacts, install channels, and code signing** (zip, `install.ps1`, winget, scoop, Authenticode). These are reserved for Arthur's decision in Open Question Q1.
- **`pf upgrade` on Windows.** It stays disabled on every platform until pf has its own release channel. Replacing a running executable on Windows is deferred with it.
- **libpf N-API and the Node SDK on Windows** (`src/napi_core_main.zig` socketpair, `sdk/node.js` loader). Deferred until there is demand.
- **Shipping `aarch64-windows`.** Windows on ARM runs the x64 binary through emulation. A native ARM64 build has no CI runner to verify it.
- **Legacy consoles without virtual terminal processing.** pf exits with an explicit message instead of degrading.
- **tmux, herdr, and the Slack bridge on Windows.** tmux and herdr do not exist natively. The Slack bridge is owned by fx and reserved for Arthur.
- **A WSL integration mode.** WSL users run the Linux build inside WSL.

## Files NOT to Modify

- `LICENSE`, `THIRD_PARTY_NOTICES.md`: license texts. `NOTICE` may only gain a modification record (US-027). Vercel's copyright notice is never altered.
- `UPSTREAM.md`: changes only when fx changes are ported.
- `scripts/rebrand.py`: rename rules and protected fx strings. Binary magics such as `FXCP` and `FXTP` stay.
- `src/core/terminal/engine.zig`: the shared deterministic VT engine for replay, recovery, and resize tests. ConPTY output feeds it without changing its semantics.
- OAuth client ids, `originator`, `referrer`, and `x-grok-client-identifier` values, and the Vercel AI Gateway configuration: reserved for Arthur (CLAUDE.md).
- `.github/workflows/*`: unchanged until Open Question Q2 is decided. Only US-026 may change them afterward.
- `src/core/upgrade/upgrade_helpers.zig` `cdn_base`: stays `null`. US-007 changes only compile-time platform handling and the timeout mechanism.
- `build.zig.zon` version: placeholder, never bumped manually.

## Technical Considerations

Framed as questions for engineering input:

- **Architecture:** Windows-specific code lives behind comptime branches inside the owning module, plus `io.zig` and `host.zig` seams for shared primitives. Should any primitive with three or more callers (console prompts, the job-wrapped spawn, ConPTY) get its own module under `src/core/shared/` or `src/core/terminal/`? The recommendation is yes for the job-wrapped spawn and ConPTY, and no otherwise. Engineering to confirm.
- **Win32 bindings:** Functions missing from `std.os.windows` (`CreatePseudoConsole`, `CryptProtectData`, `ShellExecuteW`, `CreateToolhelp32Snapshot`, `K32GetProcessMemoryInfo`) are declared as `extern` with the correct `callconv(.winapi)`. Should they live in one `src/core/shared/win32.zig` file to keep the binding surface auditable? The recommendation is one file. Linking `shell32`, `crypt32`, and `advapi32` adds system import libraries only.
- **Data Model:** Persisted files keep their formats. Does any persisted value embed a platform path that must be normalized, for example `workspace_root` and `workspaces` keys? The recommendation is to normalize on read and never rewrite user files implicitly (US-021).
- **Dialect plumbing:** Where should the dialect value live so that admission, the turn context, and execution read the same value? The recommendation is the shell selection result owned by `src/core/execution`, passed through the tool runtime configuration. Engineering to confirm it can reach `permissions.zig` without an import cycle.
- **Dependencies:** No new library. Bun and the ConPTY driver are test-only. Is `start_suspended` plus `AssignProcessToJobObject` sufficient, or is `PROC_THREAD_ATTRIBUTE_JOB_LIST` needed for race-free assignment? US-017 validates the former first.
- **Migration:** Plaintext credentials migrate to DPAPI on first read (US-028). Is a rollback needed if a user downgrades to a build without DPAPI? The recommendation is no, because the preview has no prior Windows release.
- **Startup:** Do any Windows initializations (console modes, code pages, ctrl handler) need to run before CLI dispatch? The recommendation is to run them only on the interactive and `ask` paths, so `pf help` stays minimal.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Native compile errors, binary target | 31 (first wave) | 0 | Month-1 | `zig build` log on Windows |
| Native compile errors, test target | 136 (first wave) | 0 | Month-1 | `zig build test` log on Windows |
| Non-skipped unit tests passing on Windows | N/A (does not compile) | 100% | Month-1 | `zig build test` summary |
| Share of tests skipped on Windows | 43 existing skips (0.45%), suite does not compile | 5% or less | Month-1 | Count of skipped tests in the Windows summary |
| Orphaned processes after a timeout or exit | Unbounded (direct child only) | 0 | Month-1 | US-017 and US-018 process snapshot tests |
| `pf.exe help` p50 latency | N/A (new) | 40 ms or less | Month-1 | hyperfine, 20 runs, reference machine |
| Release 1 and Release 2 stories certified DONE | 0 of 30 | 30 of 30 | Month-6 | `tasks/prd-windows-native-support-status.json` |
| Working sessions with `pf.exe` on Windows | 0 | 200 or more | Month-6 | Count of `%USERPROFILE%\.pf\sessions` entries on Arthur's machine |

## Open Questions

- **Q1 (Arthur, before Release 2 ships; reserved by CLAUDE.md, distribution):** How should Windows users get `pf.exe`? Options: (a) a zip on GitHub Releases plus an `install.ps1` script: smallest effort, but SmartScreen warns on unsigned binaries; (b) a winget manifest: the expected channel on Windows, requires a stable release URL and benefits from signing; (c) a scoop bucket: popular with developers, requires maintaining a bucket repository. Authenticode signing costs a certificate but removes SmartScreen friction. Nothing in this PRD depends on the answer except the README install section.
- **Q2 (Arthur, before US-026; reserved by CLAUDE.md, `.github/workflows/`):** What form should Windows CI take? Options: (a) add a Windows runner to `full-ci.yml` as a required job: strongest guarantee, longer CI, and the gate becomes part of the ship rule; (b) a separate informational workflow: visible signal without blocking merges; (c) local qualification only: no CI cost, no automatic protection. US-026 is blocked by this decision.
  - **Decided (Arthur, 2026-10-02):** (a), a Windows runner added to `full-ci.yml` as a required job.
- **Q3 (Arthur, before US-028; authentication storage):** Which backend should store secrets on Windows? Options: (a) DPAPI on the existing profile files: no size limit, transparent, bound to the Windows account; (b) Credential Manager: visible in Windows settings, but limited to 2,560 bytes per secret, which some OAuth token sets exceed; (c) plaintext files under the profile ACL: parity with Linux, no protection from administrators or copied disks. The PRD assumes (a).
- **Q4 (Arthur, after Release 1 dogfooding):** Should a follow-up PRD specify a PowerShell-aware parser so that routine PowerShell commands can use fast paths and allow rules? It depends on the review latency and cost measured in Release 1.
- **Q5 (Arthur, before Release 3):** Is persistent hosted-session reattachment on Windows (US-031) worth its size, or is per-process session lifetime enough?
- **Q6 (Arthur, when Windows on ARM demand appears):** When should an `aarch64-windows-gnu` artifact ship, given that no hosted CI runner can test it?
[/PRD]
