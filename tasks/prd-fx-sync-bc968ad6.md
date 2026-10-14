[PRD]
# PRD: fx Sync to `/home/arthur/dev/fx@bc968ad6` (Zig 0.17, MCP-v2, durable libpf, native indexer)

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-10-13 | Arthur Jean | Initial draft from a full-range dry run, one isolated port per fx merge, cumulative ports at every slice boundary, and nine verified analysis reports (one per merge cluster), with each key claim rechecked against `/home/arthur/dev/fx` pulled to `bc968ad6` |
| 1.1 | 2026-10-13 | Arthur Jean | Every Windows-host test and runtime check moved into a final epic (EP-006), so EP-001 to EP-005 are implemented and verified on Linux; the Zig 0.17 epic merged with merges 31 to 44; stories renumbered |
| 1.2 | 2026-10-13 | Arthur Jean | Baseline at 6708560 recorded (US-001) |
| 1.3 | 2026-10-13 | Arthur Jean | Merges 1 to 16 ported (EP-002); UPSTREAM.md holds the `.github/` hunks of `ff3b8d33` (#1180) and `1df91f0b` (#1202) under Q5 until US-022 |
| 1.4 | 2026-10-13 | Arthur Jean | EP-002 review: US-004 expects -32602 for `session/set_mode` without a session, as fx and `6708560` answer; US-005 names the World versions of fx `1eed0348` |
| 1.5 | 2026-10-13 | Arthur Jean | Q5 answered for #1180 and #1202: their `.github/` hunks are ported in EP-002 and their Held rows removed; the rest of Q5 is unchanged |
| 1.6 | 2026-10-14 | Arthur Jean | Merges 17 to 29 ported (EP-003): sign-in modules held under Q2, the Slack bridge under Q3 and the `.github/` hunks of #1209, #1211 and #1212 under Q5; Release 1 recorded on Linux at `cfe5947` |

## Problem Statement

pf finished its previous sync (`tasks/prd-fx-sync-0-0-13.md`, every story DONE at pf `6708560`) with UPSTREAM.md "Last ported" at `/home/arthur/dev/fx@9d7937d5`. Every reference to fx in this PRD points at the local clone `/home/arthur/dev/fx`, which was fetched and fast-forwarded on 2026-10-13 to `/home/arthur/dev/fx@bc968ad6` (origin/main of vercel-labs/fx, 2026-10-13 04:56 -0400).

1. **pf is 51 fx merges behind again, eight days after the last sync target.** The range `/home/arthur/dev/fx@9d7937d5..bc968ad6` holds 51 first-parent pull request merges and no direct commits: 271 commits, 745 files, +79,084 and -32,719 lines. pf users miss fx's ACP Fast mode and permission modes, `pf status --json` effort and modes, the Program Status Protocol (OSC 7501) that Paneflow already reads (`/home/arthur/dev/paneflow/ARCHITECTURE.md:343`), the opt-in MCP-v2 engine, a workspace indexer that never runs git on untrusted repositories, streaming grep over large files, a per-request image budget, and a set of crash fixes (host HTTP statuses above 1023 panic in ReleaseSafe, fixed by `/home/arthur/dev/fx@29fc2014:src/gateway/host_stream_provider.zig:44`).
2. **fx moved to Zig 0.17.0 in the middle of the range.** fx #1163 (`/home/arthur/dev/fx@f7d6cd11`, merge 30 of 51) sets `minimum_zig_version = "0.17.0"` (`/home/arthur/dev/fx@f7d6cd11:build.zig.zon:28`), and every later merge uses 0.17-only APIs: `@backingInt` (`/home/arthur/dev/fx@38815efe:src/core/terminal/shell_snapshot.zig:831`), `alloc.print` (`/home/arthur/dev/fx@cbce8416:src/ui/transcript/tool_group_projection.zig:388`), `std.Io.Dir.path.resolveAlloc` (`/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/layout.zig:33`). pf and its host run Zig 0.16.0 (`build.zig.zon:28`). Zig 0.17 removes the `**` operator (`/home/arthur/dev/fx@f7d6cd11:AGENTS.md:183`), which pf-only Windows code still uses (`src/core/terminal/native_session.zig:607`, `:610`), and fx's own termios fix for glibc (commit `/home/arthur/dev/fx@84464cf5`, a ReleaseSafe crash at startup) does not reach pf-only call sites (`src/core/shared/console_prompt.zig:92`, `:111`, `:123`). fx runs no Windows CI (`.github/workflows/windows.yml` is absent at `/home/arthur/dev/fx@bc968ad6`), so about 12,100 lines of pf Windows code meet the new compiler without any upstream test.
3. **Clean merges break pf silently.** A one-shot dry run of `python3 scripts/rebrand.py port 9d7937d5 bc968ad6 --upstream /home/arthur/dev/fx` on a clone of pf `6708560` adds 175 files, merges 552, deletes 11, skips 1 and stops on 104 conflict files (384 hunks). The merges 1 to 29 alone leave only 9 conflict files (17 hunks), but several clean merges do not compile or misbehave in pf:
   - `runMcpVerbs` calls `deps.getenv(deps.env_ctx, "HOME")` (`/home/arthur/dev/fx@ac097183:src/core/cli/cli_surface.zig:2618`), and pf's `RunDeps` (`src/core/cli/cli_surface.zig:363`) no longer has `getenv` or `env_ctx`, so the Linux build fails;
   - MCP-v2 spawns servers with `std.posix.kill`, `std.c.waitpid` and `.pgid = 0` (`/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:154`, `:155`, `:317`), so `pf.exe` stops compiling;
   - the new indexer and usage cache call `Permissions.toMode` and `.fromMode` (`/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/snapshot.zig:67`, `:119`, `/home/arthur/dev/fx@bc968ad6:src/usage/cache.zig:265`), which do not exist on Windows in Zig 0.16 or 0.17;
   - `saveSessionPermissionMode` reads `getenv("HOME")` (`/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500`), so an ACP mode change is never saved on a Windows host without `HOME`;
   - `AI_AGENT` reaches only the POSIX bootstrap (`/home/arthur/dev/fx@86d4b6b8:src/core/terminal/shell_resolver.zig:381`), not pf's PowerShell bootstrap (`src/core/terminal/shell_resolver.zig:511`);
   - the PGSO candidate counter merges to 60 while pf needs 61 after fx #1206 (`/home/arthur/dev/fx@ac097183:scripts/pgso/tests/test_corpus.py:376` against `scripts/pgso/tests/test_corpus.py:379`).
4. **Some merges carry identities and services that pf does not own.** fx #1216 applies Vercel's Slack app (`client_id` `12364000946.12017137861236`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:14`) to every `mcp.slack.com` server through the fx.sh bridge (`/home/arthur/dev/fx@53a561be:src/core/mcp_host/config.zig:121`), which pf declined for v1 (UPSTREAM.md Skipped, fx #1101, Q1 answered D). fx #1209 and #1211 reuse the Codex CLI and Grok Build OAuth clients (`/home/arthur/dev/fx@016cdc54:sdk/chatgpt.js:7`, `/home/arthur/dev/fx@7e9b98bf:sdk/grok.js:7`) for third-party servers that embed libpf. fx #1226 calls undocumented provider usage endpoints (`/home/arthur/dev/fx@bc968ad6:src/usage/codex.zig:13-15`) and removes pf's local cost ledger.
5. **pf has a crash that fx already fixed.** With a relative `HOME`, `pf sessions` panics with `reached unreachable code` in `std.Io.Dir.openDirAbsolute`; reproduced on 2026-10-13 with `env -i HOME=relative/home ./zig-out/bin/pf sessions` (build of 2026-10-10). fx #1240 makes `homeDir()` return only an absolute `HOME` (`/home/arthur/dev/fx@cfecba7c:src/core/shared/io.zig:426-428`).

**Why now:** the backlog grew from 0 to 51 merges in eight days, and the share of it written for Zig 0.17 grows with every fx merge: 21 of the 51 merges already need 0.17 (`/home/arthur/dev/fx@f7d6cd11..bc968ad6`). Deferring #1163 and back-porting merges 31 to 51 to Zig 0.16 was measured at 37 conflict hunks plus at least 108 lines of 0.17-only API to rewrite on fx alone (`git merge-tree` with base `f7d6cd11`), a cost paid again at every later sync. Zig 0.17.0 has been an official release since 2026-10-01 ([ziglang.org/download](https://ziglang.org/download/)), and Zig 0.18 removes the deprecated names pf still uses (`builtin.os`, `std.fs.path`).

## Overview

pf ports `/home/arthur/dev/fx@9d7937d5..bc968ad6` as a ladder of contiguous first-parent slices, each one `python3 scripts/rebrand.py port <FROM> <TO> --upstream /home/arthur/dev/fx` where FROM is the previous slice's TO, resolved, gate-checked, and committed with UPSTREAM.md updated. The mechanics are unchanged from `tasks/prd-fx-sync-0-0-13.md`: a skip is one commit that moves "Last ported" and adds a Skipped row; a hold is commit A (fx's resolution, never gate-checked) then commit B (pf's side restored, gates pass, Held row added).

The ladder splits at fx #1163 because the toolchain changes there:
- **Release 1 (EP-001 to EP-003, 11 stories, Zig 0.16)** prepares the tooling and ports merges 1 to 29 (`/home/arthur/dev/fx@e4915028..786247dc`): ACP Fast mode and permission modes, status JSON, OSC 7501, `AI_AGENT`, libpf durability, MCP-v2 (refused on Windows), libpf provider routes, gateway robustness and the image budget. It ends with a Linux validation whose commit becomes the Release 1 checkpoint.
- **Release 2 (EP-004 and EP-005, 11 stories, Zig 0.17)** ports fx #1163 alone, migrates pf-only code to Zig 0.17, then ports merges 31 to 51 (`/home/arthur/dev/fx@d93acc52..bc968ad6`): docs, Ctrl+O fixes, libpf durability follow-ups, the native indexer with `safe_git`, relative `HOME` handling, and `/usage`. It ends with the answers to the Open Questions and the closure.
- **Windows validation (EP-006, 4 stories)** runs every test and runtime check that needs the Windows host, once, on the final tree, and attributes each failure through checkpoint commits (D-WINGATE).

Release 2 starts only after Arthur answers Q1 (Zig 0.17). Release 1 does not depend on any Open Question being answered.

The PRD decides every question that is not reserved for Arthur:
- **D-SPLIT (two releases at fx #1163):** #1163 cannot precede merges 1 to 29 (it rewrites code they add, such as `/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig`), cannot be cut along its commits (its branch merges main ten times, for example `/home/arthur/dev/fx@b91598c8` "Port the latest main changes to Zig 0.17"), and pre-applying its renames to pf under 0.16 raised the conflicts of the 1-to-30 port from 95 files and 358 hunks to 107 files and 416 hunks. It is ported alone, as one slice.
- **D-MCPV2 (port, refuse on Windows):** MCP-v2 is opt-in through `PF_MCP_ENGINE=v2` (`/home/arthur/dev/fx@ac097183:src/core/mcp_host/runtime.zig:41`), with no setting and no project key, and v1 stays the default. pf ports it and refuses it on Windows with an explicit message, as it refuses sessions v2 (`src/core/session/session_adapter.zig:84-91`), because its process layer is POSIX-only and a Windows implementation (Job Object, handle waits, a non-blocking console read) has no fx specification. Skipping it would turn the edits of fx #1219, #1163 and #1242 to `src/mcp/**` into permanent held hunks.
- **D-HOME (absolute profile home on every OS):** `io_mod.homeDir()` keeps pf's Windows order (`USERPROFILE`, then `HOME`; `src/core/shared/io.zig:663-673`) and adds fx's rule that a relative value counts as unset, checked on each candidate. Every profile path in ported code goes through it, never through `getenv("HOME")`.
- **D-SAFEGIT (one git on Windows):** `safe_git` trusts on Windows the git of the Git Bash that pf already selected for commands (`src/core/execution/shell_selection.zig:40-46`, mapped by `src/core/permissions/direct_command.zig:771-787`), instead of fx's fixed `C:\Program Files\Git` list (`/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:143-144`), so preparation and execution run the same git. Its Windows environment adds `SYSTEMROOT`, `USERPROFILE`, `HOMEDRIVE` and `HOMEPATH`.
- **D-ACP (ACP modes follow fx):** as in the previous sync (D-ACP), ACP session modes become `auto`, `ask` and `full-access` with `auto` as the default (`/home/arthur/dev/fx@7b5b4a29:src/builtins/modes.zig:11-17`), and `session/set_mode` persists `permission_mode`. No pf ACP client exists (`tasks/prd-fx-sync-0-0-13.md:150`).
- **D-OSC (Program Status as fx):** pf emits OSC 7501 with `app=pf` in the interactive shell only (`/home/arthur/dev/fx@3dfcef6a:src/ui/terminal/program_status.zig:19-21`), including the 256-byte one-line `msg` of a pending approval, which the approval card already shows on the same terminal. The spec requires terminals to treat `msg` as untrusted text ([Program Status](https://www.superlogical.com/rex/docs/build/program-status)).
- **D-IMGBUDGET (fx parity):** requests keep under 30 MiB and 100 images by dropping the oldest images from the request only (`/home/arthur/dev/fx@786247dc:src/core/agent/runtime/request_image_budget.zig:16-18`).
- **D-DOCS (pf keeps its document model):** fx moved feature documentation out of its README to an internal site (`/home/arthur/dev/fx@d93acc52:AGENTS.md:418-420`). pf has no such site (`https://paneflow.dev/agent/docs` answers 404 on 2026-10-13), so pf's README stays the product reference and CONTRIBUTING the developer reference. Doc merges resolve toward pf's structure and absorb only facts that are true for pf, listed per story.
- **D-SDK (libpf in lockstep, not distributed):** as in the previous sync, `sdk/` follows fx because CI builds and tests it with the Zig cores, and pf still publishes nothing. The durable World packages (`/home/arthur/dev/fx@bc968ad6:sdk/durable/package.json:7-9`) land in `sdk/durable/package.json` only; Q6 asks Arthur to confirm before any libpf distribution.
- **D-WINGATE (one Windows-host epic at the end, decided by Arthur on 2026-10-13):** every story of EP-001 to EP-005 is implemented and verified on Linux, including its Windows and macOS code paths, which compile at every slice through the `x86_64-windows-gnu` cross-builds and run in Linux unit tests that inject the OS tag. Every run on the Windows 11 host is grouped in EP-006, so Arthur moves to the host once, as the previous sync did (its Q10). A Windows failure is attributed to the 0.16 ladder, the 0.17 toolchain or the 0.17 ladder by rerunning only the failing test on three checkpoints: `6708560`, the US-011 commit (end of Release 1, Zig 0.16.0) and the US-012 commit (Zig 0.17.0). Trade-off: a Windows regression from Zig 0.17 surfaces after merges 31 to 51 instead of before them.

Each Stop-for-Arthur item is an Open Question (Q1 to Q5) with a pre-decision state that leaves pf's behavior unchanged, so the ladder never stalls: Q1 blocks Release 2; Q2 and Q3 hold the sign-in modules and the Slack bridge; Q4 skips fx #1226; Q5 holds every `.github/` hunk. US-022 applies the answers.

**Merge ledger.** Each row gives the merge order, the fx pull request, the merge commit in `/home/arthur/dev/fx`, the planned disposition and the story. "Port" means ported with pf's resolutions; "Skip" and "Hold" follow UPSTREAM.md.

| # | fx PR | Merge | Disposition | Story |
|---|---|---|---|---|
| 1 | #1161 | `e4915028` | Skip, permanent (Vercel contributor label policy in pf-owned docs) | US-003 |
| 2 | #1165 | `8ceb7f85` | Port | US-003 |
| 3 | #1166 | `d9a05d4e` | Port | US-003 |
| 4 | #1162 | `c1db9191` | Skip, permanent (libpf publishing; `publish-libpf.yml` stays absent) | US-003 |
| 5 | #1168 | `61ea1a27` | Port | US-003 |
| 6 | #1171 | `f7a6c23b` | Port | US-003 |
| 7 | #1146 | `607b1632` | Port | US-003 |
| 8 | #1182 | `699910ec` | Port | US-003 |
| 9 | #1181 | `3dfcef6a` | Port | US-003 |
| 10 | #1189 | `7b5b4a29` | Port | US-004 |
| 11 | #1190 | `47943cbd` | Port | US-004 |
| 12 | #1192 | `d5a7bc50` | Port | US-004 |
| 13 | #1180 | `ff3b8d33` | Port, `.github/` included (Q5 answered for this merge) | US-005 |
| 14 | #1200 | `2456a696` | Port | US-005 |
| 15 | #1202 | `1df91f0b` | Port, `.github/` included (Q5 answered for this merge) | US-005 |
| 16 | #1204 | `1eed0348` | Port | US-005 |
| 17 | #1206 | `ac097183` | Port, refused on Windows | US-006 |
| 18 | #1207 | `ea115f8d` | Port | US-007 |
| 19 | #1208 | `9b73d5d6` | Port (README resolved toward pf) | US-007 |
| 20 | #1209 | `016cdc54` | Port; ChatGPT sign-in module held (Q2); `.github/` held (Q5) | US-008 |
| 21 | #1216 | `53a561be` | Port; Slack bridge held (Q3) | US-008 |
| 22 | #640 | `86d4b6b8` | Port | US-009 |
| 23 | #1210 | `6d622072` | Port | US-009 |
| 24 | #1211 | `7e9b98bf` | Port; Grok sign-in module held (Q2); `.github/` held (Q5) | US-009 |
| 25 | #1212 | `914f01f6` | Port; `.github/` held (Q5) | US-009 |
| 26 | #1067 | `8870252e` | Port | US-010 |
| 27 | #1217 | `29fc2014` | Port | US-010 |
| 28 | #1219 | `6fc796a7` | Port | US-010 |
| 29 | #1199 | `786247dc` | Port | US-010 |
| 30 | #1163 | `f7d6cd11` | Port after Q1; workflow pins per Q1 | US-012 |
| 31 | #1221 | `d93acc52` | Port (docs resolved toward pf) | US-014 |
| 32 | #1222 | `8f75c7d7` | Port (AGENTS.md facts absorbed) | US-014 |
| 33 | #1220 | `96adf2dc` | Port | US-014 |
| 34 | #1214 | `5ec2519d` | Port (README resolved toward pf) | US-014 |
| 35 | #1224 | `2c7a4f83` | Port | US-014 |
| 36 | #1225 | `cbce8416` | Port | US-015 |
| 37 | #1231 | `b9ca60d0` | Port (CONTRIBUTING facts absorbed) | US-015 |
| 38 | #1241 | `31ddc74d` | Port | US-015 |
| 39 | #1230 | `c673abcd` | Port; `.github/` held (Q5) | US-016 |
| 40 | #1228 | `73567067` | Port | US-016 |
| 41 | #1227 | `899daf23` | Port | US-016 |
| 42 | #1242 | `8da4aa06` | Port; `.github/` held (Q5) | US-016 |
| 43 | #1252 | `43f3eddd` | Port | US-016 |
| 44 | #1251 | `4e9f1491` | Port | US-016 |
| 45 | #1196 | `f3bc7e6b` | Port with Windows adaptations; `.github/` held (Q5) | US-017, US-018 |
| 46 | #1240 | `cfecba7c` | Port with D-HOME | US-019 |
| 47 | #1248 | `c3b4b926` | Port | US-020 |
| 48 | #1257 | `38815efe` | Port | US-020 |
| 49 | #1223 | `1a19ec99` | Skip (Q5 pre-decision: CODEOWNERS names `@fazxes`) | US-020 |
| 50 | #1254 | `f666cca0` | Port; `.github/` held (Q5) | US-020 |
| 51 | #1226 | `bc968ad6` | Skip until Q4 is answered, then port or skip permanently | US-021 |

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| First-parent merges of `/home/arthur/dev/fx@9d7937d5..bc968ad6` ported, or recorded in UPSTREAM.md as skipped or held with an Open Question | Release 1: 29 of 29 | 51 of 51, with every Skipped or Held row either revisited or marked `permanent` |
| Conflict markers and unexpected fx spellings in the tree (`python3 scripts/rebrand.py check`) | 0 at every slice commit | 0 |
| Slice commits whose tree builds on Linux and cross-compiles `pf.exe` and both Windows test executables | 100% | 100% |
| Unit and E2E failures outside the baseline recorded by US-001 (or, from US-012 on, by US-012's Zig 0.17 run) | 0 | 0 |
| Story points certified DONE (81 in total) | Release 1 on Linux: 33 of 33 | 81 of 81 |
| Zig toolchain | 0.16.0 through Release 1 | 0.17.0 in `build.zig.zon`, on the Linux host and the Windows host (if Q1 is answered "adopt") |

## Target Users

### pf maintainer
- **Role:** Arthur, sole maintainer of pf, who ports fx by hand and owns the Stop-for-Arthur decisions.
- **Behaviors:** Works on Fedora Linux with a Windows 11 host for Windows checks. Ports with `scripts/rebrand.py`, commits locally, pushes nothing and opens no pull request unless he asks.
- **Pain points:** A 51-merge backlog whose second half needs a new compiler. Clean merges that break the Linux build (`RunDeps.getenv`) or the Windows build (POSIX process code, `fromMode`). Upstream identities (Slack app, Codex and Grok clients in a server library) that arrive without a conflict marker.
- **Current workaround:** None. pf stays at `/home/arthur/dev/fx@9d7937d5` and fx fixes are unavailable.
- **Success looks like:** Each slice is one reviewable commit (two for a hold) that builds on Linux and cross-compiles for Windows; UPSTREAM.md says which merges are in, skipped or held and why; Release 1 is certified even if Release 2 waits on Q1.

### pf user on Linux or macOS
- **Role:** A developer who runs `pf` interactively, through `pf ask`, or embedded through ACP.
- **Behaviors:** Works in git repositories of any origin, attaches screenshots, runs MCP servers, reads `pf status --json` from scripts.
- **Pain points:** `git ls-files` runs on every `@`-completion and glob, and a direct `git status` could run repository-configured programs before fx's `safe_git`; a request with many images fails at the provider instead of fitting; `pf sessions` crashes with a relative `HOME`.
- **Current workaround:** Avoids untrusted repositories, trims images by hand, sets an absolute `HOME`.
- **Success looks like:** fx's behaviors with pf's names, profile and identity headers; v1 sessions and the d7ceb0e compaction fixture still resume.

### pf user on Windows
- **Role:** A developer who runs `pf.exe` natively with Git Bash or PowerShell.
- **Behaviors:** Relies on ConPTY terminals, Job Objects, DPAPI credentials, `USERPROFILE` as the profile root.
- **Pain points:** Upstream code that does not compile on Windows, `HOME`-only lookups that fail without `HOME`, and engines that are POSIX-only.
- **Current workaround:** Runs the `6708560` build.
- **Success looks like:** `pf.exe` keeps building and running; `PF_MCP_ENGINE=v2` and sessions v2 exit 1 with an explicit message; the indexer, `safe_git` and `AI_AGENT` work in Git Bash and PowerShell.

### ACP embedder
- **Role:** A client such as a future Paneflow integration that drives `pf acp`.
- **Behaviors:** Opens sessions, selects modes and config options, reads `usage_update`.
- **Pain points:** Modes named `code` and `ask` that do not match the CLI, no Fast option, unknown option ids silently ignored.
- **Current workaround:** None needed today: no pf ACP client exists.
- **Success looks like:** fx's ACP surface with `_meta.pf.*` keys: modes `auto`, `ask`, `full-access`, the `fast` option, and -32602 for an unknown mode or option.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **Electron:** replays its patch series on each upstream roll and warns that a patch can break "without even a patch conflict or a compilation error" ([Electron patches](https://www.electronjs.org/docs/latest/development/patches)). This range shows the same failure class: `RunDeps.getenv`, `saveSessionPermissionMode` and the PGSO counter merge cleanly and are wrong.
- **Forgejo:** its weekly cherry-picks from Gitea stopped in 2025 when conflicts and dependencies on unpicked changes accumulated ([forgejo/cherry-pick-tools](https://codeberg.org/forgejo/cherry-pick-tools)). pf keeps first-parent order and contiguous slices, and refuses to cut #1163 along its commits.
- **VSCodium and Copybara:** keep divergence to a build script or a transformation with persisted sync state ([VSCodium](https://github.com/VSCodium/vscodium), [Copybara](https://github.com/google/copybara)). pf's `rebrand.py` and UPSTREAM.md play these roles; this PRD extends the rules and hardens `port` (US-002).
- **Coding agents and untrusted git:** in 2026, repository-local git config (`core.fsmonitor`, hooks, filters) executed code through `git status` in several CLI agents ([Mistral Vibe advisory](https://www.vulncheck.com/advisories/mistral-vibe-arbitrary-command-execution-via-git-fsmonitor-hook), [CVE-2026-45033](https://vuln.today/cve/CVE-2026-45033)). fx #1196 answers with a git-free indexer and `safe_git` (`/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig`), which pf adopts.
- **Market gap:** no tool ports "rename plus platform divergence plus an upstream compiler change". Mitigation is process: ordered slices, a compiler slice alone, Windows cross-builds at every slice, and one Windows-host epic at the end with checkpoint runs to attribute failures.

### Best Practices Applied
- Land the toolchain bump as its own slice, before the features that need it, and verify it on the platform upstream does not test (Zig 0.17 release notes list Windows linker and libc changes: [release notes](https://ziglang.org/download/0.17.0/release-notes.html)). Here: US-012 alone, cross-compiled for Windows at every later slice, then run on the Windows host in EP-006.
- Treat silent semantic changes as audit targets, not compiler errors: Zig 0.17 swaps the parameters of `std.mem.containsAtLeastScalar`, restricts `@bitCast`, and makes `@hasDecl` see only `pub` declarations (release notes). Here: US-012 lists each pf site and compares skipped-test counts on Linux, and US-023 does the same on Windows to catch tests that stop running.
- Record every sync point, skip and hold with its reason (Electron patch provenance, Copybara state). Here: UPSTREAM.md rows, NOTICE bullets, Open Questions with pre-decision states.
- Never run git as a subprocess on untrusted repositories with repository-controlled programs enabled (advisories above). Here: `safe_git` with `core.fsmonitor=false`, `core.hooksPath=/dev/null` and filters cleared.
- MCP clients follow the 2025-11-25 specification (PKCE, exact redirect URIs, CIMD; [changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog)). MCP-v2 implements it; pf adds no client identity of its own beyond `client_name "pf"`.

*Full research: the nine per-cluster reports and the verification log produced for this PRD, and the sources linked above.*

## Assumptions & Constraints

### Assumptions (to validate)
- The target stays `/home/arthur/dev/fx@bc968ad6`. Verified on 2026-10-13: after `git -C /home/arthur/dev/fx fetch origin` and `git pull --ff-only`, `main` and `origin/main` are both `bc968ad656221cfb86a84532a240b2da874d4bcb`. Later fx merges go to a follow-up PRD.
- The per-slice conflict sets measured by cumulative throwaway ports on pf `6708560` stay valid once US-002's rules land: 2 files (3 hunks) after merge 9, 4 (5) after merge 12, 4 (5) after merge 16, 7 (10) after merge 17, 7 (15) after merge 19, 9 (17) after merge 25 and merge 29; 95 files (358 hunks) after merge 30; 104 files (384 hunks) after merge 51. US-002 reruns them.
- Merges 1 to 29 build with Zig 0.16 and cross-compile for Windows once the listed resolutions are applied. Verified in throwaway trees: merge 2 alone, merges 13 to 15 cumulatively, merges 20 and 23 to 25 in sequence, merges 26 to 29 stacked, and merges 1 to 21 cumulatively on Linux only (the Windows cross-build needs US-006's guards). Every other combination, and the ladder as one sequence, is inferred from the per-merge dry runs. Merges 38, 44, 47 and 48 also built alone on Zig 0.16 once `@backingInt` became `@intFromEnum`, which informed D-SPLIT but is not part of this plan.
- fx's Zig 0.17 renames apply mechanically to 310 of the 364 conflicting Zig hunks of #1163 (the fx side equals the renamed base), and 54 need a decision; measured by a diff3 classification of the 1-to-30 port.
- Zig 0.17.0 builds pf for `x86_64-windows-gnu`, and the `std.os.windows` symbols pf uses exist in 0.17.0 (40 checked by name, signatures not compared). US-012 checks it by cross-compilation and EP-006 at runtime; fx cannot, because it has no Windows build.
- Arthur's Windows 11 host can install Zig 0.17.0 next to Zig 0.16.0 (for the checkpoint runs) and runs Bun 1.4.2, as for the previous sync's Windows-host run.
- No Paneflow flow drives pf over ACP today, so D-ACP breaks no client (`grep` of `/home/arthur/dev/paneflow` finds `session/set_mode` only in Claude fixtures).
- Node 24 is not the system Node on the Linux host (`node --version` prints v22.23.1), so SDK lanes that need JSPI run only where Node 24 is available; stories record them as unverified otherwise.

### Hard Constraints
- pf `CLAUDE.md` governs: Stop-for-Arthur items are not decided by stories; new fx spellings get a rule in `scripts/rebrand.py`, never a hand edit; each port commit updates `UPSTREAM.md`; `NOTICE` records notable modifications; nothing is pushed and no pull request is opened unless Arthur asks.
- `CHANGELOG.md` is not ported; stories append pf entries under `## Unreleased` (`CHANGELOG.md:3`).
- `pub const version` in `src/main.zig` stays `0.0.12` (previous Q7, answered "keep 0.0.12"); fx adds no version bump in this range.
- `/home/arthur/dev/fx` is read only during this PRD: no checkout, fetch, reset or commit there.
- Every slice commit builds on Linux and cross-compiles `pf.exe` and both Windows test executables; hold commit A is never gate-checked.
- Release 1 uses Zig 0.16.0; Release 2 uses the Zig version that Q1's answer names. Allocators stay explicit, I/O goes through `std.Io`, and no Zig dependency is added.
- Every profile path goes through `io_mod.homeDir()` (D-HOME); ported code never reads `HOME` directly for a profile path.
- Sessions v2 stays refused on Windows (previous D-V2WIN A) and libpf stays undistributed (`sdk/README.md:7`).
- LICENSE, THIRD_PARTY_NOTICES.md, Vercel's copyright and `vercel-labs/fx` attribution links stay unchanged.
- US English; no em dash in prose or code comments.

## Quality Gates

These commands must pass for every user story:
- `zig build` - builds `./zig-out/bin/pf` on Linux with the release's Zig (0.16.0 in Release 1, Q1's version in Release 2)
- `zig build -Dtarget=x86_64-windows-gnu` - cross-compiles `pf.exe`, so a slice cannot break the Windows build silently
- `zig build test -Dtarget=x86_64-windows-gnu` - compiles and links both Windows test executables; its only error is "unable to spawn foreign binary"
- `zig build test --summary all` - full unit suite before each slice commit; failures are compared by name with the baseline of US-001 (Release 1) or US-012 (Release 2)
- `zig fmt --check src/` - formatting
- `python3 scripts/rebrand.py check` - no conflict markers and no unexpected fx spelling, tracked or untracked
- `bash scripts/check-public-surface.sh` - public-surface and mode-conversion audit
- `bash scripts/check-compactor-boundary.sh` - compactor boundary; from US-017 on also `bash scripts/check-indexer-boundary.sh`
- `python3 -m unittest scripts.pgso.tests.test_corpus` - E2E corpus classification and counters
- `cd tests/e2e && bun test <files named by the story>` - focused E2E with `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and `TMUX_TMPDIR` set to fresh empty directories under `/dev/shm`
- `cd tests/e2e && bun test compaction-policy.test.ts` - with an isolated `HOME`: the d7ceb0e compaction checkpoint fixture still resumes
- `./zig-out/bin/pf` - a real run of the story's happy path, with stderr clean

Each slice commit also updates `UPSTREAM.md`, and each slice handoff records the stripped ReleaseSafe size of `pf` on Linux x86_64 against the previous slice, explaining any delta of 52,429 bytes or more. CI does not run, because nothing is pushed; each handoff says so. Only EP-006 runs on the Windows host. Every earlier story implements Windows and macOS code on Linux, checks it through the cross-builds above and through unit tests that inject the OS tag, and states in its handoff that its Windows runtime is verified by EP-006.

**Baseline at 6708560 (recorded by US-001):** measured on 2026-10-13 on Fedora 44 (Linux 7.2.9, Zig 0.16.0, Bun 1.4.2, tmux 3.7c, Node v22.23.1) in a git clone of `6708560` under `/dev/shm`, built with `zig build` (Debug), with `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and `TMUX_TMPDIR` set to fresh empty directories under `/dev/shm`. `zig build test --summary all` reports `Build Summary: 10/12 steps succeeded (1 failed); 9910/9975 tests passed (59 skipped, 2 failed, 4 crashed)`, of which the main test executable is `run test 9806 pass, 54 skip, 2 fail, 4 crash (9866 total)`. The E2E run took the 71 files that the 4 shards of `bun ci-shards.ts` select, one `bun test --max-concurrency 1 ./<file>` per file with its own `TMUX_TMPDIR` and one retry after `tmux kill-server`: 68 passed on the first attempt, and the 3 files below failed both attempts with the same test. No failure named `no such window`. Both failures known before measurement reproduce. Compared with the d7ceb0e baseline, this run does not reproduce the 6 `/etc/zlogout` `clear` failures of `tool_runtime.zig`, `command_runner.zig` and `tui-command-permissions.test.ts`, or the `tui-interrupt-recovery.test.ts` and `acp.test.ts` failures; `terminal-host.test.ts` no longer exists; it adds the ACP host-disabled unit test and the `tui-file-picker.test.ts` failure. A regression is a failure outside this table, or a listed test that fails for a different cause.

| Suite | File | Test | Cause |
|---|---|---|---|
| Unit | `src/core/gateway/model_catalog.zig` | catalog capability lookup distinguishes unsupported and unknown without fetching | Aborts: `panic: switch on corrupt value` in `std.testing.expectEqualDeep` (`testing.zig:872`); root cause not isolated, as at d7ceb0e |
| Unit | `src/gateway/chat_completions.zig` | configured capability lookup matches catalog projection and preserves unknowns | Aborts: same `switch on corrupt value` panic in `expectEqualDeep` |
| Unit | `src/core/subagent/agent_adapter.zig` | child runtime capability callbacks preserve fallback and child cancellation | Aborts: same `switch on corrupt value` panic in `expectEqualDeep` |
| Unit | `src/core/subagent/tool_host.zig` | subagent yielded identity is owned and allocation failures do not leak | Aborts: general protection exception freeing `result.body` in `removeYielded` (`tool_host.zig:938`), reached from `checkYieldedOwnership` under `checkAllAllocationFailures` |
| Unit | `src/core/execution/command_runner.zig` | supervisor handoff does not extend the parent timeout deadline | Fails without output; cause not isolated, as at d7ceb0e |
| Unit | `src/acp/sessions.zig` | ACP host-disabled new load and resume skip project MCP effects | Fails without output: the three session responses list the Gateway model catalog and exceed the 64 KiB read at `src/acp/sessions.zig:3255`; with the read raised to 1 MiB, as fx #1227 does (`/home/arthur/dev/fx@899daf23:src/acp/sessions.zig`), the test passes in the same tree |
| E2E | `tests/e2e/tui-resume.test.ts` | suspended sessions retain exclusive writer ownership until close | `waitForPane` times out after 31 s at `tui-resume.test.ts:289`, the d7ceb0e symptom, which that baseline traced to the resumed pf being stopped by `SIGTSTP` under the pane's `/bin/sh` job control (not rechecked here); 66 other tests pass |
| E2E | `tests/e2e/review-model-override.test.ts` | review model override > a failing Jev evaluation endpoint holds the action instead of executing unreviewed | The fake gateway answers twice with one `Response`, and Bun 1.4.2 raises `ERR_BODY_ALREADY_USED`, as at d7ceb0e |
| E2E | `tests/e2e/tui-file-picker.test.ts` | @ file picker > workspace mutation exposes absolute added-root files and directories | Times out after 60 s; `waitForPane` then reports an empty last pane in its session; cause not isolated; 19 other tests pass |

Cross-target builds of the same tree: `zig build -Dtarget=x86_64-windows-gnu`, `zig build -Dtarget=aarch64-macos`, `zig build -Dwasm-surface=core -Doptimize=ReleaseSmall` and `zig build -Dwasm-surface=term` exit 0. `zig build test -Dtarget=x86_64-windows-gnu` links both test executables and exits 1 only with two `unable to spawn foreign binary` errors. Size and startup: `zig build -Doptimize=ReleaseSafe` writes a stripped `zig-out/bin/pf` of 13,360,176 bytes; `hyperfine -N --warmup 20 --runs 300 'env PF_BENCH=1 ./zig-out/bin/pf help'` (hyperfine 2.0.0) on that binary reports a wall-clock median of 0.989 ms (mean 1.020 ms, σ 0.214 ms). Identity values: `git grep -nE '"(originator|referrer|x-grok-client-identifier)"' -- src/core/auth src/gateway` finds 6 production sites, each with the value `"pf"`: `src/core/auth/chatgpt_oauth.zig:711`, `src/core/auth/grok_oauth.zig:775`, `src/gateway/openai_codex.zig:249`, `src/gateway/openai_codex_models.zig:199`, `src/gateway/xai_grok.zig:238` and `src/gateway/xai_grok_models.zig:220`. PGSO corpus: `scripts/pgso/tests/test_corpus.py:378-379` pins 35 scenarios and 60 candidate scenarios, and `python3 -m unittest scripts.pgso.tests.test_corpus` passes 32 tests. The Windows baseline is the previous sync's Windows-host run on 2026-10-12 (`tasks/prd-fx-sync-0-0-13.md`, its EP-006) (9,643 of 9,858 unit tests passed, 215 skipped; `windows-subset.ts` 13 of 13 files).

**Release 1 on Linux (recorded by US-011):** measured on 2026-10-14 on Fedora 44 (Linux 7.2.10, Zig 0.16.0, Bun 1.4.2, tmux 3.7c, Node v22.23.1) at `cfe5947`, the last code commit of Release 1 and the Release 1 checkpoint that US-023 uses (UPSTREAM.md "Last ported" `786247dc`; the US-011 commit changes only `tasks/`). `zig build test --summary all`, with `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and `TMUX_TMPDIR` fresh under `/dev/shm`, reports `Build Summary: 10/12 steps succeeded (1 failed); 10248/10313 tests passed (59 skipped, 2 failed, 4 crashed)`, main executable `run test 10144 pass, 54 skip, 2 fail, 4 crash (10204 total)`. The 4 crashes are the 4 baseline crashes with the same causes. The 2 failures, "initial allocation failure reports failure and a later load retries" and "failed generation starts one queued refresh after reap" in `src/core/workspace/file_index.zig`, which Release 1 does not touch, come from the host: on 2026-10-14 `.zig-cache` became a symbolic link to `~/.cargo-target/pf-zig-cache`, so `std.testing.tmpDir` resolves outside the git checkout, where its file is no longer ignored (`expected 0, found 1`); the same commit in a `/dev/shm` worktree with a real `.zig-cache` passes both (22 of 22), as did every slice run of EP-003 on 2026-10-13. Of the baseline failures, "ACP host-disabled new load and resume skip project MCP effects" passes since `346e270`, and "supervisor handoff does not extend the parent timeout deadline" did not reproduce in any EP-003 run. The E2E run took the 72 files of the 4 shards of `bun ci-shards.ts` (the 71 of US-001 plus `mcp-verbs.test.ts`) through `ci-run-files.sh`, each shard with fresh `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and `RUNNER_TEMP` under `/dev/shm` and `AI_GATEWAY_API_KEY` and `VERCEL_OIDC_TOKEN` empty: 69 files passed on the first attempt, none passed only on retry, and the 3 baseline files failed both attempts with the baseline test and cause (`tui-resume.test.ts:289` `waitForPane` timeout, `review-model-override.test.ts` `ERR_BODY_ALREADY_USED`, `tui-file-picker.test.ts` 60 s timeout). Cross-targets of the same code: `zig build -Dtarget=x86_64-windows-gnu` and `zig build -Dtarget=aarch64-macos` exit 0, and `zig build test -Dtarget=x86_64-windows-gnu` fails only with the two `unable to spawn foreign binary` errors. A real run of `./zig-out/bin/pf` with fresh homes and the E2E fake gateway: the interactive shell started in tmux and recorded with `PF_RECORD` emits `ESC]7501;state=idle:app=pf ESC\` then `state=clear` on exit; `PF_MCP_ENGINE=v2 pf mcp add demo -- node tests/e2e/fixtures/mcp-modern-stdio.mjs` then `pf mcp list` lists `demo` (stdio, not started); `pf ask --full-access 'echo $AI_AGENT'` with `AI_AGENT=other` exits 0 and the command prints `pf`; and a `pf acp` client's `session/set_mode` to `ask` writes `{"permission_mode":"ask"}` to `~/.pf/settings.json`; no run aborted, and stderr held only `pf ask`'s activity lines. Size and startup: `zig build -Doptimize=ReleaseSafe` writes a stripped `pf` of 14,061,648 bytes (+701,472 against US-001, of which +499,936 come from MCP-v2), and `hyperfine -N --warmup 20 --runs 300 'env PF_BENCH=1 ./zig-out/bin/pf help'` reports a median of 1.025 ms (US-001: 0.989 ms, +3.6%), both measured on 2026-10-13 on the same code.

## Epics & User Stories

### EP-001: Port groundwork

Record pf's failure, size and startup baseline at `6708560`, and make the rename rules and the port tool carry the 51-merge range: one new binary magic, two check false positives, the possessive spellings of Vercel's Slack bridge, and a `port` crash on chained deletions. No fx change is ported and no product behavior changes.

**fx references:** `/home/arthur/dev/fx@bc968ad6:src/core/agent/runtime/journal.zig:239` (`FXSN`), `/home/arthur/dev/fx@bc968ad6:sdk/types/libfx.d.cts:887` (`FxXtermLike`), `/home/arthur/dev/fx@bc968ad6:sdk/tests/fixtures/libfx-0.0.11-checkpoint.json:3` (base64 checkpoint), `/home/arthur/dev/fx@53a561be:src/mcp/auth/oauth.zig:32`, `:396` and `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:2`, `:16` (Slack bridge wording), `/home/arthur/dev/fx@7e9b98bf:sdk/tests/test-durable-subscription-crash.mjs` (a file renamed again by `/home/arthur/dev/fx@914f01f6`).

**Definition of Done:** At the last EP-001 commit, all of the following hold:
- The Quality Gates section lists every unit and E2E test that fails at `6708560` by name and cause, the cross-target build outcomes, the stripped ReleaseSafe size of `pf`, and the `PF_BENCH=1 pf help` median.
- A throwaway full-range port of the EP-001 tree (`python3 scripts/rebrand.py port 9d7937d5 bc968ad6 --upstream /home/arthur/dev/fx`) leaves `python3 scripts/rebrand.py check` reporting only `>>>>>>> fx bc968ad6` conflict-marker lines (399 lines, 15 of them unexpected spellings, on `6708560`).
- Chaining `port` over `/home/arthur/dev/fx@016cdc54`, `6d622072` and `7e9b98bf` without a commit in between ends with its summary instead of a Python traceback.
- UPSTREAM.md "Last ported" is still `9d7937d5e5a0bab70953bd8dfbe5c12e7e074da2`, and `./zig-out/bin/pf --version` prints `0.0.12`.

#### US-001: Record the baseline at 6708560
**Description:** As Arthur, the pf maintainer, I want every failure, the binary size and the startup time of pf `6708560` recorded by name and number before any port, so that each later slice can tell a regression from a pre-existing failure and explain its size delta.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**fx references:** `/home/arthur/dev/fx@899daf23:src/acp/sessions.zig:2754` (the capture limit that explains one known failure), `/home/arthur/dev/fx@9d7937d5:scripts/pgso/tests/test_corpus.py` (59 candidate scenarios upstream, against pf's 60).

**Acceptance Criteria:**
- [ ] Given a git checkout of `6708560` built with `zig build` and an environment where `HOME`, `XDG_CONFIG_HOME`, `TMPDIR` and `TMUX_TMPDIR` are fresh empty directories under `/dev/shm`, when `zig build test --summary all` runs, then every failing or crashing test is listed by file, full name and cause in place of the paragraph **Baseline at 6708560 (recorded by US-001)** in the Quality Gates section, as a table with columns Suite | File | Test | Cause, and the summary line (passed, skipped, failed, crashed) is quoted.
- [ ] Given the same tree and isolation, when every file selected by the 4 E2E shards runs with `bun test --max-concurrency 1 ./<file>` and one retry after `tmux kill-server`, then each test that fails both attempts is added to the same table by file and name, and a failure that names `no such window: <session>:0` is rerun with the isolated `HOME` instead of being recorded.
- [ ] Given the two failures known before measurement, "subagent yielded identity is owned and allocation failures do not leak" (`src/core/subagent/tool_host.zig`) and "ACP host-disabled new load and resume skip project MCP effects", when the run reports them, then each row names its cause; when the run does not reproduce one, the table says so instead of listing it.
- [ ] Given the tree, when these commands run, then the baseline records the outcome of each: `zig build -Dtarget=x86_64-windows-gnu`, `zig build test -Dtarget=x86_64-windows-gnu` (expected: both test executables link and the only error is "unable to spawn foreign binary"), `zig build -Dtarget=aarch64-macos`, `zig build -Dwasm-surface=core -Doptimize=ReleaseSmall` and `zig build -Dwasm-surface=term`.
- [ ] Given `zig build -Doptimize=ReleaseSafe` on Linux x86_64 (stripped by `build.zig:77`), then the baseline records the byte size of `zig-out/bin/pf`, and the median of `hyperfine -N --warmup 20 --runs 300 'env PF_BENCH=1 ./zig-out/bin/pf help'` on that binary.
- [ ] Given `git grep -nE '"(originator|referrer|x-grok-client-identifier)"' -- src/core/auth src/gateway`, then the baseline lists every production site and its value, each `"pf"`.
- [ ] Given `scripts/pgso/tests/test_corpus.py:378-379`, then the baseline records 35 scenarios and 60 candidate scenarios, and `python3 -m unittest scripts.pgso.tests.test_corpus` passes.
- [ ] Given `tasks/prd-fx-sync-bc968ad6.md` and `tasks/prd-fx-sync-bc968ad6-status.json`, which name fx on purpose, then both are added to `SKIP_FILES` (`scripts/rebrand.py:27`) next to the previous sync PRD, and `python3 scripts/rebrand.py check` passes on the tree.
- [ ] Given the story diff, then no file under `src/` changes, `NOTICE` and `CHANGELOG.md` are unchanged, UPSTREAM.md "Last ported" stays `9d7937d5e5a0bab70953bd8dfbe5c12e7e074da2`, and the PRD Changelog gains row `| 1.2 | <commit date> | Arthur Jean | Baseline at 6708560 recorded (US-001) |`.
- [ ] Given the story commit, when `./zig-out/bin/pf --version` and `./zig-out/bin/pf help` run, then they print `0.0.12` and the help text with exit 0 and empty stderr.

#### US-002: Extend the rename rules and harden the port tool
**Description:** As Arthur, the pf maintainer, I want `scripts/rebrand.py` to cover every spelling the range introduces and `port` to survive chained deletions, so that the full-range dry run leaves 0 unexpected fx spellings (15 today) and no slice stops on a traceback.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-001

**fx references:** `/home/arthur/dev/fx@ff3b8d33:src/core/agent/runtime/journal.zig:181` (`const snapshot_magic = "FXSN";`, at `:239` in `/home/arthur/dev/fx@bc968ad6`), `/home/arthur/dev/fx@bc968ad6:sdk/fx-sdk.js` and `sdk/fx-harness.js` (the same magic in JavaScript), `/home/arthur/dev/fx@bc968ad6:sdk/types/libfx.d.cts:887`, `:900`, `/home/arthur/dev/fx@bc968ad6:sdk/tests/fixtures/libfx-0.0.11-checkpoint.json:3`, `/home/arthur/dev/fx@53a561be:src/mcp/auth/oauth.zig:396`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:2`, `:16`.

**Acceptance Criteria:**
- [ ] Given the binary-magic allowlist `FX(?:CP|RPLY\d+|REL[HP]\d+|TE|TH|TP)\b` (`scripts/rebrand.py:120`), when `SN` is added, then the renamed `/home/arthur/dev/fx@bc968ad6:src/core/agent/runtime/journal.zig:239` keeps `const snapshot_magic = "FXSN";`, the renamed `sdk/pf-sdk.js` and `sdk/pf-harness.js` keep `"FXSN"`, and `check` reports none of these lines.
- [ ] Given `FxXtermLike`, which the rules rename to `PfXtermLike` (`/home/arthur/dev/fx@bc968ad6:sdk/types/libfx.d.cts:887`), when the check allowlist accepts `PfXterm`, then `check` reports none of the 7 `PfXtermLike` lines, and a new spelling such as `FxXwidget` still renames to `PfXwidget` and still surfaces when it stays `FxX`.
- [ ] Given the base64 `checkpoint` value of `sdk/tests/fixtures/libpf-0.0.11-checkpoint.json:3`, when the allowlist accepts a `"checkpoint": "<base64>"` value, then `check` does not report it, the value stays byte-identical after renaming, and its `"libfx"` key still becomes `"libpf"` (the fixture is not added to `SKIP_FILES`).
- [ ] Given `PROTECTED` (`scripts/rebrand.py:66-80`), when `fx's Slack app` and `fx\.sh's` are added next to `the fx Slack app` (`:74`), then `printf "a bridge such as fx.sh's takes no shorter one\nThe user scopes fx's Slack app has\n" | python3 scripts/rebrand.py filter` prints both lines unchanged; today it prints `paneflow.dev/agent's` and `pf's Slack app`.
- [ ] Given a deletion whose destination is staged with changes (`git rm --quiet` at `scripts/rebrand.py:294`), when `port 016cdc54^1 016cdc54`, `port 6d622072^1 6d622072` and `port 7e9b98bf^1 7e9b98bf` run in a fresh pf clone without a commit in between, then the third run removes `sdk/tests/test-durable-codex-crash.mjs` and prints its summary, where today it ends with `subprocess.CalledProcessError`.
- [ ] Given a destination that differs from the renamed base, then `port` still reports `deleted upstream but changed in pf` and never deletes it.
- [ ] Given the new rules, when every text file of `/home/arthur/dev/fx@9d7937d5` is renamed once with the `6708560` rules and once with the new rules (a throwaway comparison under `/dev/shm`), then every differing line is one of the categories above, and no path is renamed differently.
- [ ] Given a throwaway full-range port of the US-002 tree, then `check` reports only conflict-marker lines, and cumulative throwaway ports to `/home/arthur/dev/fx@3dfcef6a`, `d5a7bc50`, `1eed0348`, `ac097183`, `9b73d5d6`, `53a561be`, `914f01f6`, `786247dc`, `f7d6cd11` and `bc968ad6` report 2, 4, 4, 7, 7, 7, 9, 9, 95 and 104 conflict files; any different count is recorded in Assumptions with its cause.
- [ ] Given no fx merge in the range changes a pinned digest (`git diff 9d7937d5 bc968ad6 -- src/builtins/tools.zig src/builtins/browser_workspace_tools.zig src/core/permissions/auto_classifier.zig` changes no 64-hex literal), then `RETARGETS` is unchanged and `zig build test -Dtest-filter="tool contract stays byte exact" --summary all` passes.
- [ ] Given the story commit, then `./zig-out/bin/pf --version` prints `0.0.12`, `NOTICE` and `CHANGELOG.md` are unchanged, and UPSTREAM.md "Last ported" stays `9d7937d5e5a0bab70953bd8dfbe5c12e7e074da2`.

---

### EP-002: ACP, status, Program Status, and libpf durability (merges 1 to 16)

Port `/home/arthur/dev/fx@9d7937d5..1eed0348` on Zig 0.16: ACP Fast mode and permission modes, `status --json` effort and modes, the Program Status Protocol, tall-prompt scrollback fixes, AGENTS.md for the browser terminal, and libpf's durable sessions, with fx #1161 and #1162 skipped permanently.

**fx references:** `/home/arthur/dev/fx@d9a05d4e:src/acp/server.zig:2516`, `/home/arthur/dev/fx@607b1632:src/builtins/context.zig:239`, `/home/arthur/dev/fx@3dfcef6a:src/ui/terminal/program_status.zig:1-21`, `/home/arthur/dev/fx@7b5b4a29:src/builtins/modes.zig:11-17`, `/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500`, `/home/arthur/dev/fx@47943cbd:src/core/output/output_contracts.zig:699`, `/home/arthur/dev/fx@ff3b8d33:src/acp/libfx_journal.zig:3`, `/home/arthur/dev/fx@ff3b8d33:sdk/node.js:657`, `/home/arthur/dev/fx@ff3b8d33:.github/workflows/ci.yml:238-239`.

**Definition of Done:** UPSTREAM.md "Last ported" is `1eed0348b40f8a96b18cd3ebe57f72735b323f2d`, with Skipped rows for `e4915028` (#1161) and `c1db9191` (#1162) marked `permanent`, and the `.github/` hunks of `ff3b8d33` (#1180) and `1df91f0b` (#1202) ported under Q5's answer for those merges, with no Held row for them. On Linux, an interactive `pf` emits `ESC]7501;state=idle:app=pf ESC\` at startup, `pf status --json` contains `"effort"` and `"modes"`, and `pf acp` answers `session/set_mode` with `full-access`. Every gate passes on the last commit.

#### US-003: Port merges 1 to 9 (Fast mode, status effort, Program Status)
**Description:** As a pf user, I want fx's ACP Fast option, `models --json` details, the default effort in `pf status`, tall-prompt scrollback, AGENTS.md in the browser terminal and the OSC 7501 status reports, so that pf matches fx through `/home/arthur/dev/fx@3dfcef6a` and Paneflow can read pf's turn state.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-002

**fx references:** `/home/arthur/dev/fx@e4915028` (#1161, AGENTS.md and CONTRIBUTING.md labels text), `/home/arthur/dev/fx@8ceb7f85:src/core/images/png_downscale.zig:61-82` (only test fixtures remain), `/home/arthur/dev/fx@d9a05d4e:src/acp/server.zig:2516` (`LIBFX_MODEL_UNSUPPORTED_FAST`), `/home/arthur/dev/fx@c1db9191` (#1162, `publish-libfx.yml` and `sdk/tests/test-node-package.mjs`), `/home/arthur/dev/fx@61ea1a27:src/core/app/app_render_runtime.zig:2103`, `/home/arthur/dev/fx@f7a6c23b:src/core/output/output_contracts.zig:789-790`, `/home/arthur/dev/fx@607b1632:src/builtins/context.zig:239`, `/home/arthur/dev/fx@607b1632:src/main.zig` (`workspace_read_file` import), `/home/arthur/dev/fx@699910ec:src/core/output/output_contracts.zig:507`, `/home/arthur/dev/fx@3dfcef6a:src/ui/terminal/program_status.zig:19-21`.

**Acceptance Criteria:**
- [ ] Given `/home/arthur/dev/fx@e4915028` (#1161), which only adds Vercel's label policy for outside contributors to AGENTS.md and CONTRIBUTING.md, when the story starts, then one commit sets "Last ported" to `e4915028b87319bdada544545a4095f0bdf2108b` and adds its Skipped row with `D-DOCS: Vercel contributor policy` and `permanent`, without running the port.
- [ ] Given the port `e4915028..d9a05d4e` (#1165, #1166), then it merges without conflict, `downscaleOversized` no longer exists in `src/`, and `cd tests/e2e && bun test ultrafast-fake-gateway.test.ts` passes, including the Fast tests whose `PF_SESSIONS_V2=1` variants stay out of `tests/e2e/windows-subset.ts`.
- [ ] Given `/home/arthur/dev/fx@c1db9191` (#1162), whose test reads `.github/workflows/publish-libfx.yml` (absent in pf by the previous sync's FR-29), when the story reaches it, then one commit records it as Skipped with `permanent` and the reason "libpf is not distributed", and `node sdk/tests/test-node-package.mjs` still passes on the tree.
- [ ] Given the port `c1db9191..3dfcef6a` (#1168, #1171, #1146, #1182, #1181), when its 2 conflict files are resolved, then `src/builtins/context.zig` keeps fx's `instruction_files` switch with `.filesystem => io_mod.homeDir()` (pf's line `src/builtins/context.zig:239`, fx's `getenv("HOME")` at `/home/arthur/dev/fx@607b1632:src/builtins/context.zig:239`), and `src/core/output/output_contracts.zig` keeps both pf's test "status reports the profile settings path in text and JSON" (`:2052`) and fx's test "status reports the effort a new session starts with after the model".
- [ ] Given the ported tree, when an interactive `./zig-out/bin/pf` starts in tmux with `PF_RECORD=<tape>` and quits, then the tape contains `ESC]7501;state=idle:app=pf ESC\` before the first prompt and `state=clear` at exit, and `cd tests/e2e && bun test tui-decision-prompts.test.ts` passes.
- [ ] Given `pf ask` or `pf acp`, then neither writes `ESC]7501` to stdout or stderr (Program Status belongs to the interactive shell only, `/home/arthur/dev/fx@3dfcef6a:src/ui/terminal/program_status.zig:1`).
- [ ] Given `./zig-out/bin/pf status --json` with a profile whose model resolves an effort, then the JSON contains `"effort":"<level>"` after `model_origin`; with no resolvable effort, it contains no `effort` key.
- [ ] Given `./zig-out/bin/pf models --json` against the fake gateway, then each Gateway model lists `name`, `efforts` without `auto`, `fast` and `ultrafast`, and `cd tests/e2e && bun test cli.test.ts` passes.
- [ ] Given the browser terminal adapter, when `sdk/node/test-term-agents-md.mjs` runs where Node 24 is available, then it passes, the new WASM import is `pf_workspace_read_file`, and the host reads only absolute `*/AGENTS.md` paths under `root` or `home`; without Node 24 the handoff states this test is unverified.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `3dfcef6a6954cfd004bfa8bcc2094cb1425d12fa`, `CHANGELOG.md` gains `## Unreleased` entries for ACP Fast mode, `models --json` details, the status effort, tall prompts, and Program Status reports, and NOTICE gains no bullet (no pf divergence beyond the two skips, which UPSTREAM.md records).

#### US-004: Port merges 10 to 12 (ACP permission modes, status modes)
**Description:** As an ACP embedder, I want session modes that match the CLI's permission modes and appear in `pf status --json`, so that a client selects `auto`, `ask` or `full-access` exactly as `/permissions` does, and a mode chosen on Windows without `HOME` is saved.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-003

**fx references:** `/home/arthur/dev/fx@7b5b4a29:src/builtins/modes.zig:11-17`, `/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500` (`home_override orelse io_mod.getenv("HOME")`), `/home/arthur/dev/fx@7b5b4a29:src/core/config/config_runtime.zig:1132-1136` (`attemptUserPreferencesInHome`), `/home/arthur/dev/fx@47943cbd:src/core/output/output_contracts.zig:699`, `/home/arthur/dev/fx@d5a7bc50:src/ui/transcript/runtime.zig:1763`.

**Acceptance Criteria:**
- [ ] Given the port `3dfcef6a..d5a7bc50`, when its 2 conflict files are resolved, then `src/core/config/config_runtime.zig` keeps `io_mod.homeDir()` in `attemptUserPreferences` (pf `:1132`) and adds fx's `attemptUserPreferencesInHome`, and README.md keeps pf's paragraph "pf does not distribute a JavaScript SDK" and adds fx's paragraph on ACP modes.
- [ ] Given `saveSessionPermissionMode`, which merges cleanly with `state.cfg.home_override orelse io_mod.getenv("HOME")` (`/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500`), then it reads `state.cfg.home_override orelse io_mod.homeDir()`, as pf's `src/acp/sessions.zig:1112` does, and a unit test with `USERPROFILE` set, `HOME` unset and the Windows branch of `homeDir` selected proves the mode is written.
- [ ] Given `pf acp`, when a client sends `session/set_mode` with `modeId: "full-access"`, then the response succeeds, `~/.pf/settings.json` holds `"permission_mode": "yolo"`, and a later `session/new` starts in `full-access`; with `modeId: "careful"` the response is JSON-RPC error -32602, and with no session it is -32602 "No active session", from the session target check that pf `6708560` and `/home/arthur/dev/fx@d5a7bc50:src/acp/server.zig:1774` share.
- [ ] Given a fresh profile, when `pf acp` opens a session, then its current mode is `auto` (`/home/arthur/dev/fx@7b5b4a29:src/builtins/modes.zig:11`) and `_meta.pf.permissionMode` carries the permission mode.
- [ ] Given `./zig-out/bin/pf status --json`, then it lists `"mode"` and `"modes"` with ids `auto`, `ask` and `full-access`, and the text output does not list them.
- [ ] Given a tall prompt submitted at the bottom of a full screen, when `cd tests/e2e && bun test tui-gateway-stream-lifecycle.test.ts` runs, then it passes.
- [ ] Given `cd tests/e2e && bun test acp.test.ts`, then it passes except for failures recorded in the US-001 baseline, and the file stays in `tests/e2e/windows-subset.ts`.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `d5a7bc50d12d4a3a9eab6f852b5033ccfb596484`, and `CHANGELOG.md` gains entries for ACP permission modes (noting that `code` is gone and `auto` is the default) and the status modes.

#### US-005: Port merges 13 to 16 (durable libpf sessions)
**Description:** As Arthur, the pf maintainer, I want libpf's durable sessions, model and instruction choices, lease takeover and README rewrite ported in lockstep with the Zig core, so that the SDK keeps building against pf's ACP server while pf still publishes nothing and the CLI behaves as before.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-004

**fx references:** `/home/arthur/dev/fx@ff3b8d33:src/acp/libfx_journal.zig:3`, `/home/arthur/dev/fx@ff3b8d33:src/acp/server.zig:86` (`libfx_journal_open`), `/home/arthur/dev/fx@ff3b8d33:src/core/agent/runtime/journal.zig:181`, `/home/arthur/dev/fx@ff3b8d33:sdk/node.js:14`, `:657` (`createFxEngine`), `/home/arthur/dev/fx@ff3b8d33:.github/workflows/ci.yml:236-239` (`npm ci --prefix sdk/durable`), `/home/arthur/dev/fx@2456a696:sdk/node.js`, `/home/arthur/dev/fx@1df91f0b:sdk/durable.js:4-14` (leases), `/home/arthur/dev/fx@1eed0348:sdk/README.md:32`.

**Acceptance Criteria:**
- [ ] Given the port `d5a7bc50..1eed0348`, then it adds no conflict file beyond those already open (the cumulative count stays 4), and the renamed files are `src/acp/libpf_journal.zig`, `sdk/pf-harness.js`, `sdk/types/libpf.d.cts` and `benchmarks/libpf/*`.
- [ ] Given the `.github/` hunks of `/home/arthur/dev/fx@ff3b8d33` and `/home/arthur/dev/fx@1df91f0b` (SDK lanes in `ci.yml` that run `npm ci --prefix sdk/durable`), given Q5 answered for these two merges (Arthur, 2026-10-13: keep fx's lanes, because `sdk/scripts/package-libpf.mjs` needs the Worlds that `ci.yml` packages and tests), then `.github/workflows/ci.yml` carries fx's resolution of both merges, and UPSTREAM.md and NOTICE carry no hold for them.
- [ ] Given the CLI, when `pf acp` receives `libpf/journal_open`, then it answers "Method not found", because `libpf/*` methods need the minimal kernel (pf `src/acp/server.zig` method gate `method.isLibpf() and !state.cfg.minimal_kernel`).
- [ ] Given the journal, then `FXSN` stays the snapshot magic in Zig and JavaScript (US-002), and `zig build test -Dtest-filter="journal" --summary all` passes.
- [ ] Given Bun 1.4.2, when `sdk/tests/test-journal.mjs native native` and `sdk/tests/test-durable.mjs memory native` run, then they pass; the `local`, `world` and `queue` durabilities, which need `npm ci --prefix sdk/durable` (Vercel World packages), are recorded as not run.
- [ ] Given `sdk/durable/package.json`, then it names `@vercel/oidc` 3.8.10, `@workflow/world-local` 5.0.2 and `@workflow/world-vercel` 5.1.0 as in fx at the ported merge (`/home/arthur/dev/fx@1eed0348:sdk/durable/package.json`; 5.1.1 and 5.2.1 arrive with fx #1242, merge 42), `sdk/package.json` stays at version `0.0.0`, and only the SDK jobs of `.github/workflows/ci.yml` install them, with `npm ci --prefix sdk/durable` from `sdk/durable/package-lock.json`, as fx does.
- [ ] Given `sdk/README.md`, then its line 7 still reads "pf does not distribute `libpf`; it is not published to npm.", and the rest follows fx (US-022 rewrites the libpf-specific links once).
- [ ] Given the stripped ReleaseSafe build, then the handoff records the size delta of this story (about +136,656 bytes measured for fx #1180, the journal being compiled into `pf` unconditionally) and explains it.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `1eed0348b40f8a96b18cd3ebe57f72735b323f2d`, `CHANGELOG.md` gains no entry (no CLI behavior changes), and the PRD Changelog notes the Held rows.

---

### EP-003: MCP-v2, libpf providers, gateway robustness, and Release 1 validation on Linux (merges 17 to 29)

Port `/home/arthur/dev/fx@1eed0348..786247dc` on Zig 0.16: the opt-in MCP-v2 engine refused on Windows, tool-intent journaling, libpf on Codex, Grok and custom providers with their sign-in modules held under Q2, the Slack bridge held under Q3, `AI_AGENT` for child commands on every shell, gateway timer and status fixes, and the per-request image budget. Then validate Release 1 on Linux and record its commit as the checkpoint EP-006 uses.

**fx references:** `/home/arthur/dev/fx@ac097183:src/core/mcp_host/runtime.zig:41`, `/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:121-155`, `:317`, `/home/arthur/dev/fx@ac097183:src/core/cli/cli_surface.zig:2617-2618`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:14`, `/home/arthur/dev/fx@016cdc54:sdk/chatgpt.js:7`, `/home/arthur/dev/fx@7e9b98bf:sdk/grok.js:7`, `/home/arthur/dev/fx@86d4b6b8:src/core/execution/command_runner.zig:46-48`, `/home/arthur/dev/fx@8870252e:src/gateway/client.zig:478-486`, `/home/arthur/dev/fx@786247dc:src/core/agent/runtime/request_image_budget.zig:16-18`.

**Definition of Done:** UPSTREAM.md "Last ported" is `786247dccbe3890bd3ff050d74abaadc8219b919`, with Held rows for the ChatGPT and Grok sign-in modules (Q2), the Slack bridge (Q3) and the `.github/` hunks of `016cdc54`, `7e9b98bf` and `914f01f6` (Q5). The Linux suite matches the US-001 baseline, `PF_MCP_ENGINE=v2 pf mcp list` works on Linux, `pf.exe` and both Windows test executables cross-compile at every slice, and US-011 records the Release 1 commit. The Windows runtime of these merges is verified by US-024.

#### US-006: Port fx #1206 (MCP-v2) and refuse it on Windows
**Description:** As a pf user on Linux or macOS, I want the opt-in MCP-v2 engine behind `PF_MCP_ENGINE=v2`, and as a Windows user an explicit refusal instead of a build that does not compile, so that pf follows fx's MCP work while `pf.exe` keeps building and v1 stays the default everywhere.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-005

**fx references:** `/home/arthur/dev/fx@ac097183:src/mcp/mcp.zig:1`, `/home/arthur/dev/fx@ac097183:src/core/mcp_host/runtime.zig:6`, `:41`, `/home/arthur/dev/fx@ac097183:src/core/cli/cli_surface.zig:2617-2618`, `/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:121`, `:154-155`, `:317`, `:336`, `/home/arthur/dev/fx@ac097183:src/core/mcp_host/verbs.zig:713`, `:786-787`, `/home/arthur/dev/fx@ac097183:src/core/mcp_host/credentials.zig:245`, `/home/arthur/dev/fx@ac097183:src/acp/mcp_servers.zig:133`, `/home/arthur/dev/fx@ac097183:src/builtins/mcp.zig:530`, `:541`, `/home/arthur/dev/fx@ac097183:src/main.zig:1662`, `:1679`, `/home/arthur/dev/fx@ac097183:scripts/pgso/tests/test_corpus.py:376`, `/home/arthur/dev/fx@ac097183:scripts/pgso/corpus.json:114`.

**Acceptance Criteria:**
- [ ] Given the port `1eed0348..ac097183`, when its 3 new conflict files are resolved, then: `src/builtins/mcp.zig` keeps pf's `add_usage` literal without Slack and drops `profile_lock_deadline_ms`, takes fx's `errdefer freeConfigs` with `io_mod.homeDir()`, and drops `addSlackToPath` (code of the skipped fx #1101 that fx #1206 only touched); `src/core/cli/cli_surface.zig` takes `runMcpVerbs`, `CliMcpHosts` and `DepsWriter` without `authenticateMcpCommand`; `src/main.zig` keeps the eight-operation test list without the two `mcp add slack` expectations.
- [ ] Given `runMcpVerbs`, which merges with `deps.getenv(deps.env_ctx, "HOME")` (`/home/arthur/dev/fx@ac097183:src/core/cli/cli_surface.zig:2618`) although pf's `RunDeps` (`src/core/cli/cli_surface.zig:363`) has no `getenv`, then it reads `io_mod.homeDir()`, and `zig build` succeeds.
- [ ] Given the other profile lookups the merge adds (`/home/arthur/dev/fx@ac097183:src/acp/mcp_servers.zig:133`, `src/builtins/mcp.zig:530`, `:541`, `src/main.zig:1662`, `:1679`), then each reads `io_mod.homeDir()`, and `git grep -n 'getenv("HOME")' -- src/mcp src/core/mcp_host src/acp/mcp_servers.zig src/builtins/mcp.zig` returns only test fixtures.
- [ ] Given Linux, when `PF_MCP_ENGINE=v2 ./zig-out/bin/pf mcp add demo -- node <fixture>` then `PF_MCP_ENGINE=v2 ./zig-out/bin/pf mcp list` run against an isolated `HOME`, then the server is listed, and `cd tests/e2e && bun test mcp-verbs.test.ts` passes 13 of 13 tests.
- [ ] Given Windows, when any entry point that loads MCP (interactive `pf.exe`, `pf.exe ask`, `pf.exe acp`, `pf.exe mcp ...`) starts with `PF_MCP_ENGINE=v2`, then it exits 1 with `pf: MCP-v2 is not available on Windows yet; unset PF_MCP_ENGINE to use the default MCP engine` before starting any MCP server or writing under the profile, through a predicate that takes the OS tag like `refusesOnWindows` (`src/core/session/session_adapter.zig:89-91`); a unit test proves the `.windows` and `.linux` outcomes on Linux, and US-024 checks the runtime on the host.
- [ ] Given the POSIX-only process and paste code (`/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:154-155`, `:317`, `:336`, `src/core/mcp_host/verbs.zig:786-787`), then each sits behind a comptime Windows branch that returns `error.Unsupported`, and `zig build -Dtarget=x86_64-windows-gnu` and `zig build test -Dtarget=x86_64-windows-gnu` compile (4 and 3 errors without these branches).
- [ ] Given the POSIX-only tests (`/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:607-613`, `src/core/mcp_host/credentials.zig:245`, `src/core/mcp_host/fake_server.zig:13`), then each skips on Windows with a reason comment.
- [ ] Given `scripts/pgso/tests/test_corpus.py:379`, which merges at 60 because pf was already one ahead of fx, then it asserts 61, `scripts/pgso/corpus.json` classifies `mcp-verbs.test.ts` as verification-only (`/home/arthur/dev/fx@ac097183:scripts/pgso/corpus.json:114`), `tests/e2e/ci-shard-weights.json` gives it weight 5, and `python3 -m unittest scripts.pgso.tests.test_corpus` passes.
- [ ] Given v1 (no `PF_MCP_ENGINE`), then `cd tests/e2e && bun test mcp-stdio.test.ts mcp-auth.test.ts` passes except for US-001 baseline failures, and an ACP client that announces `session.notices` receives MCP notices as Session Notices.
- [ ] Given the stripped ReleaseSafe build, then the handoff records the size delta (about +500,000 bytes measured for fx #1206) and the `PF_BENCH=1 pf help` median, which stays within 10% of the US-001 median.
- [ ] Given the commit, then UPSTREAM.md "Last ported" is `ac0971839c90d67e1bd585c3a33dd7fc311feea9`, NOTICE gains the bullet "MCP-v2 (`PF_MCP_ENGINE=v2`) is refused on Windows, where pf keeps the default MCP engine.", AGENTS.md's Architecture section lists `src/mcp/` and `src/core/mcp_host/`, and `CHANGELOG.md` gains an entry for MCP-v2 as an opt-in engine on Linux and macOS.

#### US-007: Port merges 18 and 19 (tool intent, README)
**Description:** As a libpf embedder, I want an idempotent tool call's intent stored before it runs, and as a reader of pf's README I want fx's short-README rewrite resolved toward pf's document, so that pf matches fx through `/home/arthur/dev/fx@9b73d5d6` without losing pf's product documentation.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-006

**fx references:** `/home/arthur/dev/fx@ea115f8d:src/core/agent/runtime/journal.zig:18`, `:57` (`tool_intent`), `/home/arthur/dev/fx@9b73d5d6:README.md` (README cut from 269 to 161 lines; "For coding agents" arrives only with `/home/arthur/dev/fx@5ec2519d:README.md:100`, in US-014).

**Acceptance Criteria:**
- [ ] Given the port `ac097183..9b73d5d6`, then `src/` merges without conflict and the journal records `tool_intent` for idempotent calls before they run: `zig build test -Dtest-filter="intent" --summary all` passes "a commit ends the turn's intents, and an intent needs an open turn", and `sdk/tests/test-journal.mjs native native` passes on Bun 1.4.2.
- [ ] Given README.md's 6 conflict hunks, when they are resolved under D-DOCS, then pf's sections stay (Windows, Ultrafast, Gateway routing, themes, compaction, ACP embedding, MCP, Build from source), including the paragraphs that US-003 and US-004 added for ACP Fast, Program Status and ACP modes, which `/home/arthur/dev/fx@9b73d5d6` deletes.
- [ ] Given the facts of `/home/arthur/dev/fx@9b73d5d6:README.md` that hold for pf, then the README gains them in pf's sections: `pf doctor` in the quick start, and sessions saved under `~/.pf/sessions/` that `pf -c` continues.
- [ ] Given the merged README, then it does not claim that pf runs only on macOS and Linux, names no installer, `pf upgrade`, npm package, browser trial, Examples directory or `vercel-labs/fx` issue tracker, and every `paneflow.dev` link it adds is listed in Q8 rather than presented as live.
- [ ] Given `./zig-out/bin/pf --help`, then `doctor` and `-c` appear in it.
- [ ] Given the commit, then UPSTREAM.md "Last ported" is `9b73d5d65eefde798f66e7325a58ba48b61eb17a`.

#### US-008: Port merges 20 and 21 (libpf on Codex, MCP-v2 dogfood fixes) with holds
**Description:** As Arthur, the pf maintainer, I want libpf's Codex route and MCP-v2's dogfood fixes ported while the ChatGPT sign-in module (Q2) and the Slack bridge (Q3) wait for my answers, so that no flow obtains tokens under the Codex CLI client for third parties and no server signs in through Vercel's Slack app before I decide.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-007

**fx references:** `/home/arthur/dev/fx@016cdc54:sdk/chatgpt.js:7`, `/home/arthur/dev/fx@016cdc54:sdk/chatgpt-sign-in.js:11`, `/home/arthur/dev/fx@016cdc54:src/gateway/host_openai_codex.zig:48`, `/home/arthur/dev/fx@016cdc54:sdk/package.json:69`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:14-18`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/config.zig:121-122`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/login.zig:5`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/verbs.zig:144-145`, `:193`, `/home/arthur/dev/fx@53a561be:src/mcp/auth/oauth.zig:32`, `:396`.

**Acceptance Criteria:**
- [ ] Given the port `9b73d5d6..016cdc54` (#1209), then `src/` merges without conflict, the renamed `src/gateway/host_openai_codex.zig:48` sends `originator: pf`, and the production identity sites recorded by US-001 keep their values (`git grep` finds the new site `host_openai_codex.zig` with `"pf"` and no other value).
- [ ] Given Q2 unanswered, when commit B of the #1209 hold lands, then `sdk/chatgpt-sign-in.js`, `sdk/types/chatgpt.d.ts`, the `./chatgpt` export and `files` entry of `sdk/package.json`, the `sdk/scripts/package-libpf.mjs` entry, `sdk/tests/test-chatgpt-sign-in.mjs` and its lines in `sdk/tests/test-node-napi.mjs`, `sdk/tests/test-types.mjs` and `sdk/tests/types/adapters.mts` are absent, `sdk/chatgpt.js` (the provider spec used by `sdk/pf-sdk.js`) stays, and UPSTREAM.md gains a Held row for `016cdc54` naming Q2 and US-022.
- [ ] Given the `.github/` hunks of `016cdc54`, then they are held under Q5 in the same pair of commits.
- [ ] Given the port `016cdc54..53a561be` (#1216), then it adds no conflict file, and fx's generic bridge support in `src/mcp/auth/oauth.zig` and `src/mcp/auth/client.zig` merges with the US-002 wording (`fx.sh's` kept, never `paneflow.dev/agent's`).
- [ ] Given Q3 unanswered (pre-decision state consistent with the previous Q1 answer D), when commit B of the #1216 hold lands, then `src/core/mcp_host/slack.zig` is absent, `src/core/mcp_host/config.zig` never fills `client_id` from Slack (`/home/arthur/dev/fx@53a561be:src/core/mcp_host/config.zig:121-122` removed), `login.zig`, `runtime.zig` and `verbs.zig` have no Slack bridge path or `add slack` verb, the Slack tests of `tests/e2e/mcp-auth.test.ts` and `mcp-verbs.test.ts` are absent, and UPSTREAM.md gains a Held row for `53a561be` naming Q3 and US-022.
- [ ] Given `PF_MCP_ENGINE=v2` and a `mcp.json` server whose URL is `https://mcp.slack.com/mcp` without `client_id`, when `pf mcp login <name>` runs, then pf starts a standard OAuth flow (or reports that the server needs a client id) and never opens `https://fx.sh/api/slack/auth`.
- [ ] Given `git grep -n "12364000946" -- src tests`, then it returns nothing.
- [ ] Given the other #1216 fixes (Ctrl+C in `/mcp`, filtering, `mcp R/N` status, background start, `"type": "streamable-http"` read as HTTP for v1 and v2, project stdio servers started in the ACP session directory), then `cd tests/e2e && bun test mcp-verbs.test.ts mcp-auth.test.ts` passes (without the held Slack tests), and a v1 login is carried into the v2 store once.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `53a561beabad811e9ef55375d4147591f76ea33f`, and `CHANGELOG.md` gains an entry for the MCP-v2 fixes.

#### US-009: Port merges 22 to 25 (AI_AGENT, libpf credentials, Grok, custom providers)
**Description:** As a pf user, I want every command pf starts to see `AI_AGENT=pf`, including PowerShell tty sessions on Windows, and as Arthur I want libpf's credential callback, Grok route and custom providers ported with the Grok sign-in module held under Q2, so that tools can detect pf as an agent and libpf stays in lockstep.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008

**fx references:** `/home/arthur/dev/fx@86d4b6b8:src/core/execution/command_runner.zig:46-48`, `/home/arthur/dev/fx@86d4b6b8:src/core/permissions/direct_command.zig:220`, `/home/arthur/dev/fx@86d4b6b8:src/core/terminal/shell_resolver.zig:381`, `/home/arthur/dev/fx@6d622072:sdk/fx-sdk.js:156`, `/home/arthur/dev/fx@7e9b98bf:sdk/grok.js:7`, `/home/arthur/dev/fx@7e9b98bf:sdk/grok-sign-in.js:48`, `/home/arthur/dev/fx@7e9b98bf:src/gateway/host_xai_grok.zig:110-112`, `/home/arthur/dev/fx@7e9b98bf:sdk/subscription.js:94`, `/home/arthur/dev/fx@914f01f6:sdk/custom-provider.js:10`, `:37`.

**Acceptance Criteria:**
- [ ] Given the port `53a561be..86d4b6b8` (#640), when its 2 conflict files are resolved, then `src/core/execution/command_runner.zig` keeps pf's Job Object (`createCommandJob`, `:1276`) and `spawnCommand` and clones the environment with `applyAgentEnvironment` before the spawn, and `src/core/permissions/direct_command.zig` keeps `windowsDirectArgv` and the MSYS `PATH` (`:227-231`) and calls `applyAgentEnvironment` after them.
- [ ] Given pf's PowerShell bootstrap (`src/core/terminal/shell_resolver.zig:511`), which fx does not edit, then it sets `$env:AI_AGENT='pf'` before the user command, and a unit test asserts the bootstrap text for both dialects.
- [ ] Given `pf ask --full-access 'echo $AI_AGENT'` on Linux with `AI_AGENT=other` in the parent environment, then the command prints `pf`, and `cd tests/e2e && bun test tui-command-permissions.test.ts` passes except for US-001 baseline failures.
- [ ] Given the port `86d4b6b8..914f01f6` (#1210, #1211, #1212), then it adds no conflict file, `sdk/grok-sign-in.js`, `sdk/types/grok.d.ts`, the `./grok` export and their tests are held under Q2 (Held row for `7e9b98bf`, same criteria as US-008's ChatGPT hold), and the `.github/` hunks of `7e9b98bf` and `914f01f6` are held under Q5.
- [ ] Given the renamed `src/gateway/host_xai_grok.zig:112`, then it sends `x-grok-client-identifier: pf` and `X-XAI-Token-Auth: xai-grok-cli`, the same values as pf's CLI (`src/gateway/xai_grok.zig`), and no production identity site holds any other value.
- [ ] Given a custom provider named `gateway`, `codex` or `grok`, or a `baseUrl` with `http:` outside loopback, then libpf rejects it (`/home/arthur/dev/fx@914f01f6:sdk/custom-provider.js:10`, `:37`), and `sdk/tests/test-agent-custom.mjs` passes where Node 24 is available.
- [ ] Given `zig build test -Dtest-filter="host Codex" -Dtest-filter="host Grok" -Dtest-filter="host chat completions" -Dtest-filter="ACP provider routes" --summary all`, then it passes, and `pf acp` keeps its provider behavior (the new `acp_runner.Config` fields are set only by `src/napi_core_main.zig` and `src/wasm_core_main.zig`).
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `914f01f6d015d83152a957dc2d9d116a0e085ebe`, and `CHANGELOG.md` gains an entry for `AI_AGENT`.

#### US-010: Port merges 26 to 29 (gateway timers, host statuses, error handling, image budget)
**Description:** As a pf user, I want gateway timers that never interrupt other connections, host HTTP statuses checked before use, no remaining `catch unreachable` on reachable errors, and requests that keep under provider size limits, so that long sessions with images and libpf hosts stop failing on these paths.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-009

**fx references:** `/home/arthur/dev/fx@8870252e:src/gateway/client.zig:478-486` (`BoundedRequestWatch`), `/home/arthur/dev/fx@29fc2014:src/gateway/host_stream_provider.zig:42-44`, `/home/arthur/dev/fx@6fc796a7:src/core/session_manager/log.zig:328`, `/home/arthur/dev/fx@6fc796a7:src/core/images/image_commands.zig:13`, `/home/arthur/dev/fx@786247dc:src/core/agent/runtime/request_image_budget.zig:16-24`, `/home/arthur/dev/fx@786247dc:src/core/agent/runtime/orchestrator.zig:4544`, `/home/arthur/dev/fx@786247dc:src/gateway/vercel_failure_diagnostics.zig:33`.

**Acceptance Criteria:**
- [ ] Given the port `914f01f6..786247dc`, then it adds no conflict file, and pf's Windows block `interruptConnectedStream` in `src/gateway/client.zig` stays next to fx's `BoundedRequestWatch`.
- [ ] Given a libpf host status of 1024 or 0, when `httpStatus` reads it, then it returns null and the request fails with a provider error instead of a ReleaseSafe panic, and the tests "host statuses outside 100 to 599 are not HTTP statuses" and "catalog GET fails cleanly on a status outside the HTTP range" pass.
- [ ] Given #1219, then `git grep -n "catch unreachable" -- src` lists no site that #1219 removes in fx, and every remaining pf site is named in the handoff with a reason it cannot fail (pf-only sites include `src/core/execution/shell_selection.zig:300`, `src/core/shared/console_prompt.zig:196`, `src/ui/shell_runtime.zig:502`, and `src/core/upgrade/upgrade_helpers.zig:538`, which stays unchanged because `src/core/upgrade/**` is a Stop zone).
- [ ] Given a conversation whose next request body exceeds 30 MiB or 100 images, when pf builds the request, then the oldest images are replaced by a note naming `read_file` or `read_tool_result`, the saved history keeps every image, and `cd tests/e2e && bun test vision-route-fake-gateway.test.ts -t "request size budget"` passes 2 of 2.
- [ ] Given an AI Gateway 400 whose `providerMetadata.gateway.routing` reports a 413 attempt, then it is classified `request_too_large`, the request is rebuilt at most 2 times per turn with the learned limit at 3/4 of the rejected body, and no compaction starts for it.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `786247dccbe3890bd3ff050d74abaadc8219b919`, and `CHANGELOG.md` gains entries for the image budget and the gateway connection fix.

#### US-011: Validate Release 1 on Linux
**Description:** As Arthur, the pf maintainer, I want Release 1 proven end to end on Linux, with its Windows and macOS code cross-compiled, before the compiler changes, so that its commit is a known-good checkpoint for the Linux baseline and for the Windows attribution runs of US-023.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-010

**fx references:** `/home/arthur/dev/fx@786247dc` (Release 1 target), `/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:154` (the code refused on Windows), `/home/arthur/dev/fx@86d4b6b8:src/core/terminal/shell_resolver.zig:381` (the POSIX bootstrap pf mirrors in PowerShell), `/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500` (the mode save pf routes through `homeDir`).

**Acceptance Criteria:**
- [ ] Given the Release 1 tree on Linux with the US-001 isolation, when `zig build test --summary all` and the 4 E2E shards run, then every failure is in the US-001 baseline or fixed by a Release 1 merge (recorded by name), and the test counts are recorded.
- [ ] Given a failure outside the baseline, then its fix lands as a separate commit attributed to the story that brought it in, and US-011 is not certified until the full run matches the baseline.
- [ ] Given the Release 1 commit, then `zig build -Dtarget=x86_64-windows-gnu` and `zig build test -Dtarget=x86_64-windows-gnu` succeed (the only test error is "unable to spawn foreign binary"), and `zig build -Dtarget=aarch64-macos` has the outcome US-001 recorded.
- [ ] Given `./zig-out/bin/pf` on Linux, then one run exercises Release 1 end to end: an interactive start in tmux emits `ESC]7501;state=idle:app=pf ESC\`, `PF_MCP_ENGINE=v2 ./zig-out/bin/pf mcp list` lists a server added with the same engine, `./zig-out/bin/pf ask --full-access 'echo $AI_AGENT'` prints `pf`, and a `pf acp` client's `session/set_mode` to `ask` is saved; stderr stays clean.
- [ ] Given the stripped ReleaseSafe build, then its size is at most 1 MiB above the US-001 size and the `PF_BENCH=1 pf help` median stays within 10% of the US-001 median.
- [ ] Given the run, then the PRD Quality Gates section gains a paragraph **Release 1 on Linux (recorded by US-011)** with the date, the commit hash that US-023 uses as the Release 1 checkpoint, the counts, the size and the median.

---

### EP-004: Zig 0.17 toolchain, docs, Ctrl+O, and libpf follow-ups (merges 30 to 44)

Port fx #1163 alone once Arthur answers Q1 "adopt", migrate the pf-only code that Zig 0.17 breaks or misreads, and retire the deprecated names pf still uses; then port `/home/arthur/dev/fx@f7d6cd11..4e9f1491` on Zig 0.17: fx's document rewrites resolved toward pf's documents with their true facts absorbed, the Gateway key masked in libpf error details, wrapped tool rows and a pinned reading position in Ctrl+O, libpf queue leases and latency work, the PGSO log fix, and the gVisor process-tree fix.

**fx references:** `/home/arthur/dev/fx@f7d6cd11:build.zig.zon:28` (`minimum_zig_version = "0.17.0"`), `/home/arthur/dev/fx@f7d6cd11:build.zig:86-89` (`test_paths` module), `/home/arthur/dev/fx@f7d6cd11:src/core/shared/io.zig:954`, `:967` (termios helpers from commit `/home/arthur/dev/fx@84464cf5`), `/home/arthur/dev/fx@f7d6cd11:src/core/shared/text_utils.zig:18` (`repeat`), `/home/arthur/dev/fx@f7d6cd11:src/core/shared/testing_allocator.zig:1`, `/home/arthur/dev/fx@f7d6cd11:AGENTS.md:183`, `:215-217`, `/home/arthur/dev/fx@f7d6cd11:scripts/pgso/toolchain.py:15-16`, `/home/arthur/dev/fx@f7d6cd11:.github/actions/setup-pgso/action.yml:40`, `:48`, `/home/arthur/dev/fx@d93acc52:AGENTS.md:418-420`, `/home/arthur/dev/fx@8f75c7d7:AGENTS.md:57`, `:122`, `/home/arthur/dev/fx@96adf2dc:src/gateway/host_stream_provider.zig:175`, `:255`, `/home/arthur/dev/fx@5ec2519d:README.md:100`, `/home/arthur/dev/fx@cbce8416:src/ui/render_engine/transcript_blocks.zig:912`, `/home/arthur/dev/fx@b9ca60d0:CONTRIBUTING.md:37`, `/home/arthur/dev/fx@899daf23:src/acp/sessions.zig:2754`, `/home/arthur/dev/fx@8da4aa06:sdk/fx-sdk.js:2093`, `/home/arthur/dev/fx@43f3eddd:src/core/output/transcript_presentation.zig:148`, `/home/arthur/dev/fx@4e9f1491:src/core/execution/process_tree.zig:525`.

**Definition of Done:** UPSTREAM.md "Last ported" is `4e9f14916adf099d9b43b20d65919c305e87791a`, with Held rows for the `.github/` hunks of `f7d6cd11`, `c673abcd` and `8da4aa06` (Q5). `build.zig.zon` requires 0.17.0 and `zig version` prints `0.17.0` on the Linux host; `git grep -n "PF_TEST_PRODUCT_EXE\|PF_TEST_SOURCE_ROOT\|std.posix.tc[gs]etattr" -- src build.zig` lists only the helpers in `src/core/shared/io.zig`; a ReleaseSafe `pf` starts interactively on Linux without a crash; the cumulative conflict count matches the analysis (95 files at merge 30, 97 at merges 35 and 44, before resolution); the Linux unit suite matches the US-012 baseline, in which "ACP host-disabled new load and resume skip project MCP effects" now passes; AGENTS.md lines 21, 58, 114, 133, 141, 299, 349 and 392 state facts true for pf; and every gate passes on the last commit, including both Windows cross-builds. The Windows runtime is verified by EP-006.

#### US-012: Port fx #1163 and migrate pf-only code to Zig 0.17
**Description:** As Arthur, the pf maintainer, I want fx's Zig 0.17 upgrade ported in one slice together with the pf-only code it does not cover, so that every later fx merge applies to a compiler it was written for and no pf test stops running silently.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-011; starts only after Q1 is answered "adopt"

**fx references:** `/home/arthur/dev/fx@f7d6cd11:build.zig.zon:28`, `/home/arthur/dev/fx@f7d6cd11:build.zig:86-89`, `/home/arthur/dev/fx@84464cf5` (termios through `TCGETS` and `TCSETS` on Linux, "ReleaseSafe builds crashed in the terminal launcher and on interactive startup"), `/home/arthur/dev/fx@f7d6cd11:src/core/shared/io.zig:954`, `:967`, `/home/arthur/dev/fx@f7d6cd11:src/core/shared/text_utils.zig:18`, `/home/arthur/dev/fx@f16f2018` (`ZIG_GLOBAL_CACHE_DIR`), `/home/arthur/dev/fx@b91598c8` (one of ten "Port the latest main changes to Zig 0.17" commits), `/home/arthur/dev/fx@f7d6cd11:AGENTS.md:183`, `/home/arthur/dev/fx@f7d6cd11:scripts/pgso/toolchain.py:15-16`.

**Acceptance Criteria:**
- [ ] Given Q1 unanswered, when US-011 is certified, then US-012 to US-022 stay TODO and no Release 2 commit lands; given Q1 answered "stop after merge 29" or "skip #1163 and back-port", then US-012 to US-022 become CANCELLED, the PRD Changelog records the answer, EP-006 runs on the US-011 commit with Zig 0.16.0, and the rest of the range goes to a follow-up PRD.
- [ ] Given Zig 0.17.0 from ziglang.org on the Linux host, when `zig version` runs, then it prints `0.17.0`, and `build.zig.zon` sets `minimum_zig_version = "0.17.0"`.
- [ ] Given the port `786247dc..f7d6cd11`, whose cumulative tree holds 95 conflict files (358 hunks), when each hunk whose fx side equals the renamed base (310 of the 364 Zig hunks measured) is resolved by keeping pf's side with fx's 0.17 renames applied, then every hunk that pf's commit `a18cef8` caused by removing a Windows test skip keeps the skip removed, and the handoff lists the 54 other hunks with their resolution.
- [ ] Given `build.zig`, then it keeps installing `pf.exe` under `exe.out_filename`, creates fx's `test_paths` module (`/home/arthur/dev/fx@f7d6cd11:build.zig:86-89`) with `product_exe` pointing at that installed file for both Linux and `x86_64-windows-gnu`, and sets no `PF_TEST_PRODUCT_EXE` or `PF_TEST_SOURCE_ROOT` variable (pf `build.zig:100-106` at `6708560`).
- [ ] Given the five readers of those variables (pf `src/core/execution/command_runner.zig:1516`, `src/core/session/session_adapter.zig:4837`, `src/core/shared/self_exe.zig:73`, `src/core/terminal/client.zig:1097`, `src/core/terminal/native_session.zig:4811` at `6708560`), when they read `@import("test_paths")`, then `zig build test --summary all` runs the session boundary test and the installed-binary tests instead of skipping them, and the handoff names each with its outcome.
- [ ] Given the pf-only termios calls (`src/core/shared/console_prompt.zig:92`, `:111`, `:123` and `src/ui/shell_runtime.zig:147`, `:186`, `:215`, `:881`, `:891`, `:924`, `:928`, `:935` at `6708560`), then each goes through `io_mod.tcgetattr` or `io_mod.tcsetattr` (`/home/arthur/dev/fx@f7d6cd11:src/core/shared/io.zig:954`, `:967`), and a ReleaseSafe `./zig-out/bin/pf` started in tmux on Fedora (glibc) shows its prompt, accepts one prompt against the fake gateway, and quits with exit 0 and empty stderr.
- [ ] Given the pf-only code that Zig 0.17 rejects (`"a" ** 66` and `"a" ** 65` at `src/core/terminal/native_session.zig:607`, `:610`, `"x" ** 40` at `src/core/shared/io.zig:2705`, `"x" ** 300` at `src/core/session/session_event.zig:3657`, `@typeInfo(Preference).@"enum".fields` at `src/core/execution/shell_selection.zig:104`, `std.fmt.bufPrintZ` at `src/core/shared/io.zig:1497`, `:1526` and `src/core/skills/skill_runtime.zig:4034`), then each uses `text_utils.repeat`, `@splat`, `field_names` or `std.mem.printSentinel`, and `zig build`, `zig build -Dtarget=x86_64-windows-gnu` and `zig build test -Dtarget=x86_64-windows-gnu` succeed.
- [ ] Given Zig 0.17's silent changes, then the handoff records a check of each pf site: `std.mem.containsAtLeastScalar` at `src/core/shared/darwin_process_spawn.zig:363` uses 0.17's parameter order, the `@bitCast` sites at `src/core/mcp/mcp_auth.zig:1106`, `src/core/auth/browser_callback.zig:64`, `src/core/hosts/native.zig:139` and `src/core/terminal/native_session.zig:61`, `:987`, `:4123` compile and keep their tests passing, and no pf-only file uses `@hasDecl` on a non-`pub` declaration.
- [ ] Given the `.github/` hunks of `/home/arthur/dev/fx@f7d6cd11` (setup-zig `"0.17.0"`, `brew install llvm@22`), when Q5 is unanswered, then they are held in commit A and B with a Held row naming Q5 and US-022, and the handoff states that pf's workflows still pin 0.16.0 (`.github/workflows/windows.yml:66` and the others recorded by the analysis) and therefore would fail if pushed.
- [ ] Given the documents, then `README.md:165`, `:178`, `CONTRIBUTING.md:23`, `:42`, `:54` and `AGENTS.md:33`, `:187`, `:189` name Zig 0.17.0, and AGENTS.md gains fx's "Zig 0.17 Standard Library" section worded "New pf code does not use declarations that Zig 0.17 deprecates" until US-013 makes the stronger sentence true.
- [ ] Given Zig 0.17, when the US-001 measurements run again on Linux, then the Quality Gates section gains a paragraph **Baseline at Zig 0.17 (recorded by US-012)** with test counts, failures and skips by name compared with US-011, the stripped ReleaseSafe size delta (with the deletion of `src/core/shared/memset.zig`), and the `PF_BENCH=1 pf help` median, which stays within 10% of the US-001 median.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `f7d6cd1120f25438b200761d133fb32dce38c729`, `CHANGELOG.md` gains "Building pf requires Zig 0.17.0", and the files under `src/core/upgrade/` change only where Zig 0.17 requires it to compile (`pf upgrade` stays disabled and behaves as at `6708560`).

#### US-013: Retire deprecated Zig names in pf code
**Description:** As Arthur, the pf maintainer, I want the about 821 pf sites that still use names Zig 0.17 deprecates rewritten to fx's forms, so that pf follows fx's AGENTS.md rule, later fx merges meet the same spelling on both sides, and Zig 0.18 does not break the build.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-012; may land between any two later slices of EP-004 or EP-005, never inside one

**fx references:** `/home/arthur/dev/fx@f7d6cd11:AGENTS.md:215-217` ("does not use declarations that Zig 0.17 deprecates"), `/home/arthur/dev/fx@b5f0d705` (script-driven renames outside strings and comments, 322 files), `/home/arthur/dev/fx@457c1409` (hand-checked replacements), `/home/arthur/dev/fx@f7d6cd11:src/acp/client_instructions.zig:180` (`alloc.print`), `/home/arthur/dev/fx@f7d6cd11:src/builtins/context.zig:893` (`@fromBackingInt`).

**Acceptance Criteria:**
- [ ] Given a count script committed under `scripts/` that matches fx's table (`std.fmt.allocPrint`, `std.fmt.bufPrint`, the `std.mem.indexOf` family, `std.fs.path`, `std.fs.max_path_bytes`, `std.fs.path.resolve` and `relative`, `builtin.os` and `builtin.cpu`, `std.builtin`, the `*Unmanaged` aliases, `@intFromEnum`, `@enumFromInt`, `std.mem.copyForwards` and `copyBackwards`) outside strings and comments, when it runs on the US-012 tree, then the story records the count per pattern (about 821 measured on the 1-to-30 dry run).
- [ ] Given the rewrite, then the same script reports 0 sites in `src/`, `benchmarks/` and `build.zig`, except in `src/core/upgrade/**` (a Stop zone), which the story lists by count without changing.
- [ ] Given the diff, then no string literal and no comment changes, `zig fmt --check src/` passes, and `zig build -Dtarget=x86_64-windows-gnu` and `zig build test -Dtarget=x86_64-windows-gnu` succeed.
- [ ] Given `zig build test --summary all`, then the passed, skipped and failed counts equal those recorded by US-012, test for test.
- [ ] Given a throwaway cumulative port from the current "Last ported" to `/home/arthur/dev/fx@bc968ad6` before and after the rewrite, then the conflict count after is not higher than before; a rename family that raises it is reverted and listed with its count.
- [ ] Given AGENTS.md, then its section reads "pf does not use declarations that Zig 0.17 deprecates" and names the count script.
- [ ] Given the commit, then UPSTREAM.md, NOTICE and CHANGELOG.md are unchanged (no fx merge, no behavior change).

#### US-014: Port merges 31 to 35 (docs model, Gateway key masking, README, sdk/README)
**Description:** As a reader of pf's documents and as a libpf embedder, I want fx's AGENTS.md, README and sdk/README rewrites resolved toward pf's documents, with every statement that fx corrected and that is true for pf absorbed, and the Gateway key removed from libpf error details, so that pf's docs stop contradicting its code and no error leaks a key.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-012

**fx references:** `/home/arthur/dev/fx@d93acc52:AGENTS.md:418-420` (feature docs moved to the private fx.sh manual), `/home/arthur/dev/fx@8f75c7d7:AGENTS.md:57` (camelCase functions), `:122` (command specs in `src/builtins/commands.zig`), `/home/arthur/dev/fx@96adf2dc:src/gateway/host_stream_provider.zig:175`, `:255` (`withoutCredential`), `/home/arthur/dev/fx@5ec2519d:README.md:100` ("For coding agents"), `/home/arthur/dev/fx@2c7a4f83:sdk/README.md:131`, `:139` ("On Vercel", `wakeHandler`).

**Acceptance Criteria:**
- [ ] Given the port `f7d6cd11..d93acc52` (#1221), when its AGENTS.md and CONTRIBUTING.md hunks are resolved under D-DOCS, then no pf document states that feature documentation lives in a manual or a private repository, and README.md stays the feature reference.
- [ ] Given the port `d93acc52..8f75c7d7` (#1222), then pf's AGENTS.md states, each checked against the tree: functions in `camelCase`, variables, fields and files in `snake_case` (replacing `AGENTS.md:58`); command specs in `src/builtins/commands.zig` with kinds in `src/core/slash_commands/command_specs.zig` (replacing `:114`, `:392`); project `.pf.json` keys `provider_order`, `provider_strict`, `max_agent_steps`, `max_tool_result_bytes` and `context` as read by `parseProjectSafeFields` (replacing `:133`, and `CONTRIBUTING.md:163`); no effective-sandbox claim for full access (replacing `:141`); the `file_approval` owner class (replacing `:299`); `Startup Latency` also running `tests/e2e/tui-performance.test.ts` (`:349`); an installed copy "on `PATH`" instead of `~/.pf/bin/pf` (`:21`).
- [ ] Given the same merge, then AGENTS.md also names `zig fmt --check src/`, `scripts/check-public-surface.sh`, the mandatory weight in `tests/e2e/ci-shard-weights.json`, `sdk/AGENTS.md` for the WASM and N-API entry points, and `src/mcp/` as MCP-v2's owner, and it keeps pf's sections that fx drops (Declaring Work Ready, Before Marking a PR Ready, Releasing as pf's manual dispatch).
- [ ] Given the port `8f75c7d7..96adf2dc` (#1220), when a libpf Gateway request fails with a body that contains the direct Gateway key, then the error detail replaces the key (`/home/arthur/dev/fx@96adf2dc:src/gateway/host_stream_provider.zig:255`), and the test "a key quoted in a gateway error never reaches the failure detail" passes.
- [ ] Given the port `96adf2dc..5ec2519d` (#1214), then README.md gains a "For coding agents" section with facts true for pf: `pf ask` takes the prompt as arguments or on stdin, progress and diagnostics go to stderr, `pf ask --json` prints `final_output`, `pf doctor --json` and `pf status --json` exist, and `--full-access` is passed only when the user asks; every flag it names appears in `./zig-out/bin/pf ask --help`.
- [ ] Given the merged README, then it still names Windows as supported, and it names no installer, `pf upgrade`, npm package, browser trial or `vercel-labs/fx` issue tracker.
- [ ] Given the port `5ec2519d..2c7a4f83` (#1224), then `sdk/README.md` takes fx's text except that line 7 keeps "pf does not distribute `libpf`; it is not published to npm.", and US-022 does the single pf pass on the rest.
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `2c7a4f83f06f417d4f7e4a09fb18058e30379fb1`, and `CHANGELOG.md` gains no entry (no CLI behavior change).

#### US-015: Port merges 36 to 38 (Ctrl+O tool rows, CONTRIBUTING, PGSO log)
**Description:** As a pf user reading the full transcript, I want long tool rows wrapped instead of cut with an ellipsis, and as a contributor I want CONTRIBUTING to keep pf's Windows and release sections while gaining fx's empty-profile recipe and E2E registration table, so that Ctrl+O shows whole commands and the developer guide stays correct.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-014

**fx references:** `/home/arthur/dev/fx@cbce8416:src/ui/render_engine/transcript_blocks.zig:912` (`wrapFullToolStatus`), `/home/arthur/dev/fx@cbce8416:src/ui/transcript/tool_group_projection.zig:388`, `/home/arthur/dev/fx@b9ca60d0:CONTRIBUTING.md:37` (empty-profile recipe), `/home/arthur/dev/fx@31ddc74d:scripts/pgso/qualify.py:1020` (`--output=inherit`).

**Acceptance Criteria:**
- [ ] Given the port `2c7a4f83..cbce8416` (#1225), then it adds no conflict file, and in Ctrl+O a tool row longer than the width wraps with its style reopened on each line, and an argument line is hidden only when the first status line contains its value.
- [ ] Given `cd tests/e2e && bun test tui-terminal-tool.test.ts tui-resume.test.ts`, then both pass except for baseline failures.
- [ ] Given the port `cbce8416..b9ca60d0` (#1231), when CONTRIBUTING.md's 8 hunks and README.md's 2 are resolved under D-DOCS, then pf's sections `### Windows` (`CONTRIBUTING.md:38`), `## Releases` and its subsections, the libpf non-distribution line and `## ACP Embedding` (linked from `README.md`) stay.
- [ ] Given the same merge, then CONTRIBUTING.md gains the empty-profile recipe `HOME="$(mktemp -d)" PF_DISABLE_KEYCHAIN=1 ./zig-out/bin/pf` with a PowerShell variant that sets `USERPROFILE`, a table of the files a new `tests/e2e/*.test.ts` must update (`scripts/pgso/corpus.json`, `tests/e2e/ci-shard-weights.json`, `tests/e2e/macos-platform-tests.json`, `tests/e2e/windows-subset.ts`), and the note that evals make billed calls and are not a check.
- [ ] Given the merged CONTRIBUTING.md, then it names no Vercel maintainer, signed-commit requirement, automatic release, `pf upgrade --channel dev` or private docs repository.
- [ ] Given the port `b9ca60d0..31ddc74d` (#1241), then `python3 -m unittest scripts.pgso.tests.test_qualify` passes (27 tests at the analysis).
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `31ddc74d6487682a2e1effafa4db70ca9f55c4b0`, and `CHANGELOG.md` gains an entry for wrapped tool rows in Ctrl+O.

#### US-016: Port merges 39 to 44 (libpf leases and latency, Ctrl+O anchor, gVisor)
**Description:** As a libpf embedder, I want queue-held leases, agent routing fixes and the durable latency work, and as a pf user I want Ctrl+O to keep my reading position and the shell snapshot to survive gVisor, so that pf matches fx through `/home/arthur/dev/fx@4e9f1491` and a baseline ACP test passes again.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-015

**fx references:** `/home/arthur/dev/fx@c673abcd:sdk/durable.js:345`, `/home/arthur/dev/fx@73567067:sdk/durable.js:1286`, `/home/arthur/dev/fx@899daf23:src/acp/sessions.zig:2754` (capture read raised to 1 MiB), `/home/arthur/dev/fx@8da4aa06:sdk/fx-sdk.js:2093`, `/home/arthur/dev/fx@8da4aa06:src/mcp/io/process.zig:504` (SIGTERM then SIGKILL test), `/home/arthur/dev/fx@43f3eddd:src/core/output/transcript_presentation.zig:148` (`pin_reading_position`), `/home/arthur/dev/fx@4e9f1491:src/core/execution/process_tree.zig:525` (`iterateAssumeFirstIteration`).

**Acceptance Criteria:**
- [ ] Given the port `31ddc74d..4e9f1491`, then it adds no conflict file beyond those of US-015's tree, and the `.github/` hunks of `c673abcd` and `8da4aa06` are held under Q5 with Held rows naming US-022.
- [ ] Given the test "ACP host-disabled new load and resume skip project MCP effects", which fails in the US-001 baseline on its 64 KiB capture limit, then it passes after #1227, and the Quality Gates baseline notes the fix.
- [ ] Given `/home/arthur/dev/fx@8da4aa06`, then `createPfAgent` refuses a tool without `idempotent` and `libpfApiVersion` is 3; `sdk/tests/test-journal.mjs native native` and `sdk/tests/test-durable.mjs memory native` pass on Bun 1.4.2, and the `local`, `world` and `queue` durabilities are recorded as not run.
- [ ] Given the MCP-v2 process test that #1242 changes (`/home/arthur/dev/fx@8da4aa06:src/mcp/io/process.zig:504`), then it runs on Linux and stays skipped on Windows (US-006).
- [ ] Given the full transcript open on an entry whose height changes during a rebuild, then the same entry stays at the top of the page, and the tests "transcript presentation pins the reading position to its entry for a rebuilt page" and "rebuilt full transcript page keeps the entry the viewer was reading" pass.
- [ ] Given a `/proc/<pid>/task` directory that disappears between reads (gVisor), when `appendLinuxChildren` scans it, then the scan ends without an error (pf `src/core/execution/process_tree.zig:524` uses `iterateAssumeFirstIteration`), and Windows builds are unaffected (the function returns `error.ProcessTreeUnsupported` there).
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `4e9f14916adf099d9b43b20d65919c305e87791a`, and `CHANGELOG.md` gains entries for the Ctrl+O reading position and the gVisor fix.

---

### EP-005: Native indexer, safe git, relative HOME, usage, and closure (merges 45 to 51)

Port `/home/arthur/dev/fx@4e9f1491..bc968ad6` on Zig 0.17: the git-free workspace indexer and `safe_git` with pf's Windows git and environment, streaming grep and the relative-HOME guard with pf's Windows home order, the benchmark and trace fixes, `/usage` according to Q4, then apply Arthur's answers and close the sync.

**fx references:** `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/snapshot.zig:18`, `:67`, `:119`, `/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:104-106`, `:125`, `:138-144`, `/home/arthur/dev/fx@f3bc7e6b:src/core/tooling/tool_admission.zig:2120`, `/home/arthur/dev/fx@cfecba7c:src/core/shared/io.zig:426`, `/home/arthur/dev/fx@cfecba7c:src/core/workspace/grep_search.zig:598`, `:608`, `/home/arthur/dev/fx@38815efe:src/core/terminal/shell_snapshot.zig:831`, `/home/arthur/dev/fx@1a19ec99:.github/CODEOWNERS:4`, `/home/arthur/dev/fx@bc968ad6:src/usage/codex.zig:13-15`, `/home/arthur/dev/fx@bc968ad6:scripts/pgso/tests/test_corpus.py:67`.

**Definition of Done:** UPSTREAM.md "Last ported" is `bc968ad656221cfb86a84532a240b2da874d4bcb`, every row for the 51 merges is Ported, Skipped or Held with a reason, and every Held row names an answered Open Question or is marked `permanent`. On Linux, `@`-completion never starts git, `git status` through pf runs only via `safe_git`, and `env -i HOME=relative/home ./zig-out/bin/pf sessions` exits 1 with a message instead of a panic. Every gate passes on the last commit, including both Windows cross-builds, and the status JSON lists every story of EP-001 to EP-005 DONE or CANCELLED. The Windows runtime is verified by EP-006.

#### US-017: Port fx #1196 (native indexer and safe git)
**Description:** As a pf user in a repository I did not write, I want `@`-completion, `glob_files` and `grep_files` to list files without starting git, and every git that pf runs itself to run with repository-configured programs disabled, so that opening an untrusted repository cannot execute its `core.fsmonitor`, hooks or filters.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-016

**fx references:** `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/snapshot.zig:18` (`pf-file-index-v3` once renamed), `:67` (`toMode`), `:119` (`.fromMode(0o700)`), `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/bounded_read.zig:166` (`mkfifo` test), `/home/arthur/dev/fx@f3bc7e6b:src/core/workspace/file_index.zig:865`, `/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:104-106` (`core.fsmonitor=false`, `core.hooksPath=/dev/null`), `/home/arthur/dev/fx@f3bc7e6b:src/core/tooling/tool_admission.zig:2120`, `/home/arthur/dev/fx@f3bc7e6b:.github/workflows/ci.yml:55-56`, `/home/arthur/dev/fx@f3bc7e6b:scripts/pgso/corpus.json:121`, `/home/arthur/dev/fx@f3bc7e6b:scripts/check-indexer-boundary.sh`, `/home/arthur/dev/fx@f3bc7e6b:tests/e2e/poisoned-repository.test.ts`.

**Acceptance Criteria:**
- [ ] Given the port `4e9f1491..f3bc7e6b`, when its conflicts are resolved, then `src/core/shell_command/command_effect.zig` keeps pf's `shell_selection` import and `dialect` parameter and adds fx's `safe_git` import and `planWithGit` with `dialect`, and `src/core/permissions/direct_command.zig` keeps `SYSTEMROOT` on Windows (pf `:433-436`) for both git profiles.
- [ ] Given the deletion of `src/core/workspace/file_index_cache.zig` (changed by pf `f9b1080`), then its Windows fixes reach the new code: `src/core/indexer/snapshot.zig` uses `io_mod.isOwnerOnlyMode` and `io_mod.applyPrivatePermissions` in place of `toMode` and `.fromMode(0o700)`, and `src/core/workspace/file_index.zig` reads `io_mod.homeDir()`.
- [ ] Given the Windows cross-build, then the test-only `.fromMode` sites (`safe_git.zig:341`, `snapshot.zig:347`, `:353`) and the `mkfifo` test (`bounded_read.zig:166-173`) sit behind a comptime Windows skip with a reason comment, and `zig build test -Dtarget=x86_64-windows-gnu` links both test executables.
- [ ] Given `bash scripts/check-public-surface.sh`, then it passes (it rejects `toMode` and `fromMode` outside Windows-guarded code).
- [ ] Given a repository whose `.git/config` sets `core.fsmonitor` to a script that writes a marker file, when `@`-completion opens, `glob_files` and `grep_files` run, and `pf ask --full-access 'git status'` runs, then the marker is never written, and `cd tests/e2e && bun test poisoned-repository.test.ts tui-file-picker.test.ts` passes.
- [ ] Given `auto` permission mode and a git command that `safe_git` refuses, then the tool result is "pf did not run this git command" (`/home/arthur/dev/fx@f3bc7e6b:src/core/tooling/tool_admission.zig:2120`, renamed) without a security review, and `ask` mode still prompts.
- [ ] Given `scripts/pgso/tests/test_corpus.py`, then it asserts 62 candidate scenarios, `scripts/pgso/corpus.json` classifies `poisoned-repository.test.ts` as verification-only, `tests/e2e/ci-shard-weights.json` gives it weight 5, and `python3 -m unittest scripts.pgso.tests.test_corpus` passes.
- [ ] Given `bash scripts/check-indexer-boundary.sh`, then it passes and is added to the Quality Gates; the `ci.yml` step that runs it is held under Q5 with the other `.github/` hunks of `f3bc7e6b`.
- [ ] Given AGENTS.md, then its Architecture section names `src/core/indexer/` (never starts a process) and `src/core/shell_command/safe_git.zig` (the only path that runs git for pf), and the `ci.yml` sentence names the indexer boundary.
- [ ] Given the stripped ReleaseSafe build, then the handoff records the size delta and the `PF_BENCH=1 pf help` median, which stays within 10% of the US-001 median.
- [ ] Given the commit, then UPSTREAM.md "Last ported" is `f3bc7e6bf415cffbda532b0bd6964f73aaa2b3c9`, and `CHANGELOG.md` gains entries for the git-free file index, `safe_git` and the `@` menu changes (Enter on a folder mentions it, Tab opens it).

#### US-018: Make safe git and the indexer correct on Windows
**Description:** As a pf user on Windows, I want `safe_git` to run the git of the Git Bash that pf already selected, with an environment that finds my global config, and the indexer to handle `\` paths and NTFS file ids, so that `git status` and `@`-completion work in Git Bash and PowerShell instead of failing or listing nothing.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-017

**fx references:** `/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:118-125` (`PATH=/usr/bin:/bin`), `:138-144` (fixed `C:\Program Files\Git` list), `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/layout.zig:33` (`resolveAlloc`), `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/tree.zig:92` (`@intCast` of the inode), `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/git_config.zig:299` (`/etc/gitconfig`), `:310` (`HOME`).

**Acceptance Criteria:**
- [ ] Given Windows, when `safe_git` resolves its executable, then it uses the Git Bash root that `shell_selection` selected (`src/core/execution/shell_selection.zig:40-46`, honoring `PF_GIT_BASH_PATH`), trying `mingw64\bin\git.exe` then `cmd\git.exe` under it, never `PATH`; with no Git Bash selected it reports `git_missing`.
- [ ] Given `windowsDirectArgv` (`src/core/permissions/direct_command.zig:771-787`), when argv[0] is already an absolute Windows path to `git.exe`, then it runs that path unchanged instead of building `<usr\bin>\C:\...\git.exe.exe`, and a unit test covers both forms.
- [ ] Given the `safe_git` environment on Windows, then it holds `SYSTEMROOT`, `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`, the `GIT_CONFIG_*` values fx keeps, and a `PATH` limited to the selected Git Bash root's `usr\bin` and `mingw64\bin`, and a unit test asserts the exact key set for `.windows` and for `.linux`.
- [ ] Given a workspace root that is a subdirectory of the repository on Windows (`C:\repo\src\core`), then the indexer's rule prefix uses `/` separators, tracked files under the root are listed, and anchored patterns match; a unit test runs the prefix logic on a Windows-style path on every OS.
- [ ] Given `tree.zig:92`, `:113` and `scan.zig:301`, then the inode conversion uses `@bitCast` on Windows, where `ino_t` is signed, so a file id with the high bit set does not panic in ReleaseSafe.
- [ ] Given `tool_files.zig:70`, then a leading `\` is stripped like a leading `/`, so a subdirectory search reuses the snapshot on Windows.
- [ ] Given the tests that need POSIX (`SentinelRepo` with `#!/bin/sh` scripts, "A file others can read is not trusted", the symlink fixtures of `scan.zig:736-737`), then each skips on Windows at comptime with a reason, and `zig build test -Dtarget=x86_64-windows-gnu` links.
- [ ] Given Git for Windows' system config (`<install>\etc\gitconfig`), which the indexer does not read (`/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/git_config.zig:299`), then README.md's Windows section states this limit.
- [ ] Given the story, then NOTICE gains the bullet "On Windows, `safe_git` runs the git of the Git Bash that pf selected, with the Windows profile variables, instead of a fixed install path.", and the Windows runtime of these criteria is verified by US-025.

#### US-019: Port fx #1240 (streaming grep, FIFO, relative HOME) with D-HOME
**Description:** As a pf user, I want `grep_files` to search files larger than 200 KiB, never block on a FIFO, and treat a relative `HOME` or `USERPROFILE` as unset, so that large logs are searchable and `pf sessions` reports a missing home instead of panicking.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-017

**fx references:** `/home/arthur/dev/fx@cfecba7c:src/core/shared/io.zig:426` (`homeDir`, absolute `HOME` only), `/home/arthur/dev/fx@cfecba7c:src/core/workspace/grep_search.zig:598` (`scanLines`, 64 KiB blocks), `:608` (`openExistingReadOnlyRegularFile`), `:1034`, `:1046` (`mkfifo` test), `/home/arthur/dev/fx@cfecba7c:tests/e2e/file-tool-paths.test.ts:1756`.

**Acceptance Criteria:**
- [ ] Given the port `f3bc7e6b..cfecba7c`, when `src/core/shared/io.zig` is resolved, then `homeDir()` returns, on Windows, the first non-empty absolute value among `USERPROFILE` then `HOME`, and elsewhere `HOME` only when absolute; a relative candidate counts as unset (D-HOME).
- [ ] Given `src/builtins/context.zig`, then it keeps pf's `return io_mod.homeDir();` (pf `:2232-2234`) instead of fx's `orelse io_mod.getenv("USERPROFILE")`, and `src/core/tooling/tool_runtime.zig:4966` takes fx's assertion.
- [ ] Given `env -i HOME=relative/home ./zig-out/bin/pf sessions`, then it prints `pf sessions: HOME is not set` and exits 1, with no panic and nothing created in the current directory; `env -i HOME=relative/home ./zig-out/bin/pf status --json` exits 0.
- [ ] Given unit tests with the OS tag injected, then `USERPROFILE=relative` with `HOME=C:\Users\a` resolves to `HOME`, `USERPROFILE=C:\Users\a` wins over `HOME`, and `/git-bash/home` still counts as absolute on Windows (`.rooted`).
- [ ] Given `src/core/terminal/shell_snapshot.zig:659`, the last raw `getenv("HOME")` in pf, then it reads `io_mod.homeDir()`, and `git grep -n 'getenv("HOME")' -- src` lists only `io.zig` and test fixtures.
- [ ] Given a 5 MiB text file with a match on its last line and a line longer than 64 KiB, when `grep_files` runs, then both matches are reported, a NUL byte anywhere still skips the file, and the 7 new or rewritten grep tests pass.
- [ ] Given a symlink to a FIFO in the workspace, when `grep_files` runs, then it returns without blocking; on Windows the FIFO test skips at comptime (`// Creates a POSIX FIFO; Windows has no mkfifo.`), and `zig build test -Dtarget=x86_64-windows-gnu` links.
- [ ] Given `cd tests/e2e && bun test file-tool-paths.test.ts`, then it passes, including "relative HOME is treated like a missing HOME instead of aborting".
- [ ] Given the commit, then UPSTREAM.md "Last ported" is `cfecba7c2ebd54d3b0bfed6be6bcc7f03613012c`, NOTICE gains the bullet "`homeDir` checks `USERPROFILE` then `HOME` on Windows and ignores a relative value on every OS.", and `CHANGELOG.md` gains entries for large-file grep and the relative-HOME fix.

#### US-020: Port merges 47 to 50 (benchmark, traces, CODEOWNERS skip, agent routing)
**Description:** As Arthur, the pf maintainer, I want the paired ui-activity measurement, the shell-snapshot traces and libpf's routing by agent name ported, and Vercel's CODEOWNERS skipped, so that pf reaches `/home/arthur/dev/fx@f666cca0` with no reviewer assignment pointing at a Vercel account.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-019

**fx references:** `/home/arthur/dev/fx@c3b4b926:benchmarks/activity_progress.zig:93` (`measurePairedP95`), `/home/arthur/dev/fx@38815efe:src/core/terminal/shell_snapshot.zig:831` (`@backingInt`), `/home/arthur/dev/fx@38815efe:src/core/execution/command_runner.zig:1501`, `:1528`, `/home/arthur/dev/fx@1a19ec99:.github/CODEOWNERS:4` (`@fazxes`), `/home/arthur/dev/fx@f666cca0:sdk/durable.js:520`, `:597`.

**Acceptance Criteria:**
- [ ] Given the port `cfecba7c..38815efe` (#1248, #1257), then it merges without conflict on Zig 0.17, `zig build test-ui-activity-benchmark` passes 4 of 4, and a `PF_DEBUG_TRACE` run of a shell command shows the new supervisor spawn, ready and release lines.
- [ ] Given `/home/arthur/dev/fx@1a19ec99` (#1223), when Q5 is unanswered, then one commit records it as Skipped with "Q5 pre-decision: names a Vercel reviewer" and no `.github/CODEOWNERS` exists in pf.
- [ ] Given the port `1a19ec99..f666cca0` (#1254), then it adds no conflict file, its `.github/` hunk is held under Q5, and `sdk/tests/test-durable.mjs memory native` passes on Bun 1.4.2.
- [ ] Given a libpf agent name that breaks `/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/`, then libpf rejects it (`/home/arthur/dev/fx@f666cca0:sdk/durable.js:520`).
- [ ] Given the commits, then UPSTREAM.md "Last ported" is `f666cca0768918895554986422abb0025e86d6b5`, and `CHANGELOG.md` gains no entry.

#### US-021: Resolve fx #1226 (/usage from provider reports) per Q4
**Description:** As Arthur, the pf maintainer, I want fx's provider-reported `/usage` either skipped while Q4 is open or ported with pf's Windows and session fixes once I answer, so that pf never calls the undocumented ChatGPT, Grok and Vercel usage endpoints or drops its local cost ledger without my decision.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-020; certification needs Q4 answered

**fx references:** `/home/arthur/dev/fx@bc968ad6:src/usage/codex.zig:13-15` (`wham/usage`, `wham/profiles/me`, `daily-token-usage-breakdown`), `/home/arthur/dev/fx@bc968ad6:src/usage/report.zig:201`, `:217`, `/home/arthur/dev/fx@bc968ad6:src/usage/grok.zig:12`, `/home/arthur/dev/fx@bc968ad6:src/usage/cache.zig:265`, `:276`, `:290`, `/home/arthur/dev/fx@bc968ad6:src/usage/usage.zig:512`, `/home/arthur/dev/fx@bc968ad6:src/usage/policy.zig:12`, `/home/arthur/dev/fx@bc968ad6:src/builtins/commands.zig:245`, `/home/arthur/dev/fx@bc968ad6:src/core/output/output_contracts.zig:248`, `/home/arthur/dev/fx@bc968ad6:src/acp/types.zig:413`, `/home/arthur/dev/fx@bc968ad6:src/core/cli/cli_surface.zig:1860`, `/home/arthur/dev/fx@bc968ad6:scripts/pgso/tests/test_corpus.py:67`.

**Acceptance Criteria:**
- [ ] Given Q4 unanswered when US-020 is certified, then one commit moves "Last ported" to `bc968ad656221cfb86a84532a240b2da874d4bcb` with a Skipped row "until Q4", and `/usage`, `/cost`, `pf usage --period 24h|7d|30d` and ACP `usage_update.cost` behave as at `6708560`.
- [ ] Given Q4 answered "skip permanently", then the Skipped row is marked `permanent` and the story ends.
- [ ] Given Q4 answered "port" or "port AI Gateway only", when `bc968ad6^1..bc968ad6` is ported, then `src/core/cli/cli_surface.zig` reads `io_mod.homeDir()` (fx's `deps.getenv("HOME")` at `/home/arthur/dev/fx@bc968ad6:src/core/cli/cli_surface.zig:1860` does not compile against pf's `RunDeps`), and `src/core/session/session_store.zig` keeps `another_platform_message` and `isNativeWorkspaceRoot` (pf `:527`, `:532`).
- [ ] Given the same port, then fx's `tests/e2e/tmux-helpers.ts` hunk (the `usage?` option, no `/v1/generation` route) is applied to `tests/e2e/e2e-helpers.ts:287-437`, where pf moved `serveFakeGateway`, and `cd tests/e2e && bun test tui-usage.test.ts cli.test.ts session-recovery.test.ts` passes.
- [ ] Given `src/usage/cache.zig:265`, `:276`, `:290` and `src/usage/usage.zig:512` (`.fromMode`, absent on Windows), then each uses a local comptime Windows branch, so `src/usage/` still imports only `std`, and the POSIX-only tests (`usage.zig:962`, `:1083`, `session_adapter.zig:4155-4170`) skip on Windows at comptime.
- [ ] Given `VERIFICATION_E2E_TESTS` in `scripts/pgso/tests/test_corpus.py`, which still lists `tui-cost.test.ts` in fx (`/home/arthur/dev/fx@bc968ad6:scripts/pgso/tests/test_corpus.py:67`), then pf lists `tui-usage.test.ts` there, the candidate count stays 62, and `python3 -m unittest scripts.pgso.tests.test_corpus` passes.
- [ ] Given Q4 answered "port AI Gateway only", then Codex and Grok connections show `unsupported_provider` in `/usage` and `pf usage --json`, and `git grep -n "wham/\|/v1/billing" -- src` returns nothing.
- [ ] Given no connection, when `pf usage --json` runs, then it exits with a handled failure and `status` other than `ready`, as fx does, and the CHANGELOG entry states the breaking changes: `/cost` removed, periods `today|7d|month`, JSON `schema_version` 2, ACP `usage_update` without `cost`.
- [ ] Given the port, then AGENTS.md no longer mentions `~/.pf/usage-recovery-v2/` (`AGENTS.md:135`), the orphaned `~/.pf/usage.jsonl`, `usage-recovery*` and `usage-v2.json` files are left in place and named in the CHANGELOG entry, and UPSTREAM.md "Last ported" is `bc968ad656221cfb86a84532a240b2da874d4bcb` with the row updated from Skipped to Ported.

#### US-022: Apply Arthur's answers and close the sync
**Description:** As Arthur, the pf maintainer, I want every Held and Skipped row of this sync resolved by my answers to Q2, Q3, Q5 and Q6, the libpf README rewritten once for pf, and UPSTREAM.md, NOTICE and CHANGELOG brought to their final state, so that the sync ends with no undecided upstream code.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-021

**fx references:** `/home/arthur/dev/fx@016cdc54:sdk/chatgpt-sign-in.js:11`, `/home/arthur/dev/fx@7e9b98bf:sdk/grok-sign-in.js:48` (Q2), `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:14`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/config.zig:121-122` (Q3), `/home/arthur/dev/fx@ff3b8d33:.github/workflows/ci.yml:236-239`, `/home/arthur/dev/fx@f3bc7e6b:.github/workflows/ci.yml:55-56`, `/home/arthur/dev/fx@f7d6cd11:.github/actions/setup-pgso/action.yml:40`, `:48` (Q5), `/home/arthur/dev/fx@bc968ad6:sdk/node.js:684`, `:719` (Q6), `/home/arthur/dev/fx@2c7a4f83:sdk/README.md:131`.

**Acceptance Criteria:**
- [ ] Given an answer to Q2, Q3 or Q5 that restores fx's side, when the story applies it, then it restores commit A's content for that row only, the gates pass, and the Held row becomes Ported; given an answer that keeps pf's side, then the row is marked `permanent`; given a question still unanswered, then its rows stay Held with the PRD's pre-decision and the handoff lists them.
- [ ] Given Q2 answered "port the sign-in modules", then the ChatGPT and Grok modules use the identity values Arthur names, and `git grep` finds no identity value outside those named by Q2's answer and the six recorded by US-001.
- [ ] Given Q3 answered with any option other than D, then the Slack bridge path follows that option, and no `mcp.slack.com` server receives a client id without the option's explicit opt-in.
- [ ] Given `sdk/README.md`, then a single pf pass keeps the non-distribution note at line 7, removes `npm install libpf`, npm links, `fx.sh/docs/lib`, `llms.txt` and "Upgrading from 0.0.13", documents only the providers and sign-in modules that pf ported, and states the Vercel Workflow dependency of durable sessions as Q6's answer decides.
- [ ] Given UPSTREAM.md, then "Last ported" is `bc968ad656221cfb86a84532a240b2da874d4bcb`, each of the 51 merges appears as Ported or in a Skipped or Held row with a reason, and each Held row names its Open Question.
- [ ] Given NOTICE, then it holds a bullet for each notable modification of this sync (MCP-v2 refused on Windows, `homeDir` order and guard, `safe_git` on Windows, and each Held or permanent Skip that changes user-visible behavior).
- [ ] Given `CHANGELOG.md`, then `## Unreleased` describes every user-visible change of the 51 merges once, in pf's format, with no pull request number, commit hash or contributor name.
- [ ] Given `tasks/prd-fx-sync-bc968ad6-status.json`, then every other story of EP-001 to EP-005 is DONE or CANCELLED and those epics roll up accordingly.

---

### EP-006: Windows host validation

Run every test and runtime check that needs the Windows 11 host, once, on the final tree: build and unit-test `pf.exe`, run the Windows E2E subset, drive the Release 1 and Release 2 behaviors that differ on Windows, attribute each failure to the 0.16 ladder, the 0.17 toolchain or the 0.17 ladder through checkpoint commits, fix it on Linux, and certify the final commit (D-WINGATE).

**fx references:** `/home/arthur/dev/fx@bc968ad6:.github/workflows/` (no `windows.yml`: fx never builds or tests Windows), `/home/arthur/dev/fx@f7d6cd11:build.zig.zon:28`, `/home/arthur/dev/fx@ac097183:src/core/mcp_host/runtime.zig:41`, `/home/arthur/dev/fx@86d4b6b8:src/core/terminal/shell_resolver.zig:381`, `/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:138-144`, `/home/arthur/dev/fx@cfecba7c:src/core/shared/io.zig:426`.

**Definition of Done:** On the Windows 11 host with Zig 0.17.0 and Bun 1.4.2 (or Zig 0.16.0 on the US-011 commit if Q1 stops the sync after merge 29), the final commit builds `pf.exe` and the ConPTY driver, its unit suite passes with every skip named, `windows-subset.ts` passes 13 of 13 files, every runtime criterion of US-024 and US-025 holds on that same commit, every Windows failure found was fixed in its own commit with its source attributed, and the status JSON lists every story DONE or CANCELLED.

#### US-023: Run the Windows build and test suites and attribute failures
**Description:** As Arthur, the pf maintainer, I want the final tree built and tested on my Windows 11 host in one session, with each failure traced to the checkpoint where it first appears, so that every Windows regression of the sync is fixed once at its source without going back and forth between Linux and Windows during the ladder.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-022

**fx references:** `/home/arthur/dev/fx@bc968ad6:.github/workflows/` (no `windows.yml`), `/home/arthur/dev/fx@f7d6cd11:build.zig.zon:28`, `/home/arthur/dev/fx@f7d6cd11:src/core/shared/io.zig:954` (the termios branch that applies to Linux only and leaves Windows on its existing path).

**Acceptance Criteria:**
- [ ] Given the Windows 11 host with Zig 0.17.0 (Q9) and Bun 1.4.2, and the final commit delivered as a `git bundle`, when `zig build`, `zig build conpty-driver` and `zig build test --summary all` run, then they pass, and the passed and skipped counts are compared with the previous sync's Windows-host run (9,643 of 9,858 passed, 215 skipped on 2026-10-12).
- [ ] Given a full `zig build test --summary all` on the `6708560` checkpoint with Zig 0.16.0, then every test skipped on the final commit and not on that checkpoint is named with its cause, and none of the tests of `src/core/terminal/conpty.zig`, `src/core/shared/secret_file.zig`, `src/core/shared/process_job.zig`, `src/core/shared/win32.zig` and `src/core/terminal/windows_socket.zig` is skipped for a missing `test_paths` value or a `@hasDecl` probe that Zig 0.17 no longer sees.
- [ ] Given `TEMP=C:\pfe2e-tmp`, when `bun windows-subset.ts` runs, then 13 of 13 files pass.
- [ ] Given a failing or newly skipped test, when it runs on the checkpoints `6708560` and the US-011 commit with Zig 0.16.0 and on the US-012 commit with Zig 0.17.0, then the handoff records the first checkpoint where it fails and therefore its source: pre-existing, the 0.16 ladder (US-003 to US-010), the 0.17 toolchain (US-012, US-013), or the 0.17 ladder (US-014 to US-021).
- [ ] Given each such failure, then its fix is a separate commit on top of the final tree, made on Linux, named after the story that brought the failure in, covered by a Linux unit test that injects the OS tag when the logic allows it, and passing both Windows cross-builds; the failing test then passes on the host.
- [ ] Given a failure that a Zig 0.17 regression explains (the release notes list zig libc replacing MinGW functions and a reworked COFF linker), when no workaround fits in the story, then US-023 becomes BLOCKED with the failing test, the Zig issue number and the proposed workaround recorded.
- [ ] Given the run, then the PRD Quality Gates section gains a paragraph **Windows host run (recorded by US-023)** with the date, host build, Zig versions, counts, attributions and fix commits.

#### US-024: Exercise Release 1 changes on Windows
**Description:** As a pf user on Windows, I want the Release 1 behaviors that differ on Windows checked in `pf.exe`, so that the MCP-v2 refusal, ACP mode persistence without `HOME`, `AI_AGENT` and Program Status work in PowerShell and Git Bash.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-023

**fx references:** `/home/arthur/dev/fx@ac097183:src/mcp/io/process.zig:154` (the POSIX process code pf refuses on Windows), `/home/arthur/dev/fx@7b5b4a29:src/acp/server.zig:3500` (the mode save pf routes through `homeDir`), `/home/arthur/dev/fx@86d4b6b8:src/core/terminal/shell_resolver.zig:381` (the POSIX bootstrap pf mirrors in PowerShell), `/home/arthur/dev/fx@3dfcef6a:src/ui/terminal/program_status.zig:19`.

**Acceptance Criteria:**
- [ ] Given PowerShell without `HOME`, when `PF_MCP_ENGINE=v2 pf.exe ask hi`, `PF_MCP_ENGINE=v2 pf.exe acp` and `PF_MCP_ENGINE=v2 pf.exe mcp list` run, then each exits 1 with the US-006 message and writes nothing under `%USERPROFILE%\.pf`.
- [ ] Given PowerShell without `HOME`, when a `pf.exe acp` client sets mode `ask`, then `%USERPROFILE%\.pf\settings.json` holds `"permission_mode": "ask"`, and a later `session/new` starts in `ask`.
- [ ] Given `AI_AGENT=other` in the parent environment and a `tty: true` PowerShell session started by `pf.exe`, when it runs `$env:AI_AGENT`, then it prints `pf`; a Git Bash command `echo $AI_AGENT` prints `pf` too.
- [ ] Given interactive `pf.exe` in Windows Terminal, when it starts and quits, then the handoff records whether `ESC]7501` reaches the terminal through ConPTY (observed, not required), the process does not abort, and stderr is clean.
- [ ] Given a failure, then it follows US-023's attribution and fix procedure, and the handoff names the fix commit.

#### US-025: Exercise Release 2 changes on Windows
**Description:** As a pf user on Windows, I want the Zig 0.17 build, the indexer, `safe_git`, the relative-home guard and `/usage` driven in `pf.exe` from Git Bash and PowerShell, so that the Windows adaptations made on Linux in US-012 and US-017 to US-021 hold at runtime.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-023

**fx references:** `/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:138-144` (the executable rule pf replaces on Windows), `/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/layout.zig:33` (the path normalization that yields `\` on Windows), `/home/arthur/dev/fx@cfecba7c:src/core/shared/io.zig:426` (the guard pf extends to `USERPROFILE`), `/home/arthur/dev/fx@bc968ad6:src/usage/cache.zig:265` (`.fromMode`, absent on Windows).

**Acceptance Criteria:**
- [ ] Given interactive `pf.exe` built with Zig 0.17.0 in Windows Terminal, when it starts, runs a `tty: true` PowerShell command and a Git Bash command, and quits, then the process does not abort and stderr is clean.
- [ ] Given a repository cloned in Git Bash whose `.git/config` sets `core.fsmonitor` to a script that writes a marker, when interactive `pf.exe` opens `@`-completion and runs `git status` through a direct command, then tracked files are listed, `git status` prints the repository state, and the marker is never written.
- [ ] Given the same repository opened from a subdirectory, then `@`-completion lists the tracked files under it.
- [ ] Given PowerShell with `USERPROFILE` absolute and `HOME` unset, when `pf.exe status --json` and `pf.exe sessions` run, then they read `%USERPROFILE%\.pf` and exit 0.
- [ ] Given `USERPROFILE` relative and `HOME` absolute, then `pf.exe sessions` reads the profile under `HOME`; given both relative, then it prints `pf sessions: HOME is not set` and exits 1 without a panic.
- [ ] Given #1226 ported (Q4), when `pf.exe usage --json` runs from PowerShell without `HOME`, then it reads the cache under `%USERPROFILE%\.pf\usage-cache` and does not report `HomeNotSet`; given #1226 skipped, then `/usage` behaves as at `6708560`.
- [ ] Given a failure, then it follows US-023's attribution and fix procedure, and the handoff names the fix commit.

#### US-026: Certify the final commit on Windows and Linux
**Description:** As Arthur, the pf maintainer, I want one clean host run on the exact commit that holds every Windows fix, with the Linux gates rerun on that same commit, so that the sync's result on both systems belongs to the commit I keep.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-024, US-025

**fx references:** `/home/arthur/dev/fx@bc968ad6` (sync target), `/home/arthur/dev/fx@bc968ad6:.github/workflows/` (no Windows coverage upstream).

**Acceptance Criteria:**
- [ ] Given the commit that holds every fix of US-023 to US-025, when `zig build`, `zig build conpty-driver`, `zig build test --summary all` and `bun windows-subset.ts` run on the host, then they pass, and the skipped tests equal US-023's list minus the ones its fixes removed.
- [ ] Given the same commit on Linux, then `zig build test --summary all` matches the US-012 baseline, the focused E2E files of every story that a Windows fix touched pass, and both Windows cross-builds succeed.
- [ ] Given a failure in either run, then the story returns to US-023's procedure and is never certified on a commit other than the one both runs used.
- [ ] Given a Windows fix that changes user-visible behavior, then `CHANGELOG.md` describes it, and NOTICE gains a bullet when the fix diverges from fx.
- [ ] Given the run, then the PRD Quality Gates section gains a paragraph **Final Windows host run (recorded by US-026)** with the date, commit, counts and outcomes, the handoff states that CI did not run, and `tasks/prd-fx-sync-bc968ad6-status.json` lists every other story DONE or CANCELLED.

## Functional Requirements

- FR-01: Each slice must port contiguous first-parent fx merges in order with `python3 scripts/rebrand.py port <FROM> <TO> --upstream /home/arthur/dev/fx`, where FROM is the previous slice's TO; no slice may cherry-pick commits inside a merge, and fx #1163 must be ported alone.
- FR-02: Each slice commit must update UPSTREAM.md "Last ported"; a skip must be one commit that adds a Skipped row with its reason; a hold must be commit A (fx's resolution) followed by commit B (pf's side restored) and a Held row that names its Open Question.
- FR-03: pf must not send any OAuth client id, `originator`, `referrer`, `x-grok-client-identifier`, `X-XAI-Token-Auth` or Slack client id value that the US-001 baseline does not record, unless the Open Question that covers it has an answer naming that value.
- FR-04: When `PF_MCP_ENGINE=v2` is set on Windows, every entry point that loads MCP must exit 1 with `pf: MCP-v2 is not available on Windows yet; unset PF_MCP_ENGINE to use the default MCP engine` before it starts a server or writes under the profile.
- FR-05: Every profile path must be resolved through `io_mod.homeDir()`, which returns on Windows the first non-empty absolute value among `USERPROFILE` then `HOME`, and elsewhere `HOME` only when it is absolute.
- FR-06: ACP session modes must be `auto`, `ask` and `full-access`, with `auto` for a fresh profile; `session/set_mode` must persist `permission_mode` and answer -32602 for an unknown mode id.
- FR-07: The interactive shell must emit OSC 7501 with `app=pf`; `pf ask` and `pf acp` must not emit it; a pending-approval `msg` must be one line of at most 256 bytes.
- FR-08: Each model request must stay under 30 MiB and 100 images by replacing the oldest images in that request with a note; the saved history must keep every image.
- FR-09: `@`-completion, `glob_files` and `grep_files` must not start any process; every git process that pf starts itself must go through `safe_git` with `core.fsmonitor=false`, `core.hooksPath=/dev/null` and every repository-configured filter cleared.
- FR-10: On Windows, `safe_git` must run the git of the Git Bash root that pf selected, never a git found on `PATH`.
- FR-11: Every command pf starts must see `AI_AGENT=pf`, including PowerShell tty sessions on Windows.
- FR-12: `pf status --json` must report `effort` when the model resolves one, plus `mode` and `modes`; the text output must not list modes.
- FR-13: `grep_files` must read files of any size in 64 KiB blocks and must not open a FIFO or other non-regular file.
- FR-14: The system must NOT change `pf upgrade`, install scripts, release channels or signing; `pf upgrade` stays disabled.
- FR-15: The system must NOT publish libpf, push a branch, open a pull request, or edit `.github/` beyond the hunks Q5's answer releases.
- FR-16: Until Q4 is answered "port", `/usage`, `/cost` and `pf usage` must behave as at `6708560`.
- FR-17: Sessions v2 must stay refused on Windows, and sessions saved at `6708560` (including the d7ceb0e compaction checkpoint fixture) must resume.

## Non-Functional Requirements

- **Performance:** The median of `hyperfine -N --warmup 20 --runs 300 'env PF_BENCH=1 ./zig-out/bin/pf help'` on a stripped ReleaseSafe build stays at or below 110% of the US-001 median at every slice commit. The stripped ReleaseSafe size of `pf` on Linux x86_64 grows by at most 1 MiB (1,048,576 bytes) over the US-001 size at the end of Release 1 and by at most 1.5 MiB (1,572,864 bytes) at the end of the sync; every slice delta of 52,429 bytes or more is explained in its handoff. `grep_files` keeps its 2,000-match cap, and the indexer keeps fx's caps of 100,000 files, 128 MiB of git index and 64 MiB per snapshot.
- **Security:** 0 identity values outside the US-001 baseline without an answered Open Question (`git grep` of the identity header names and client id literals). 0 marker files written by repository-configured programs in the poisoned-repository scenarios on Linux (US-017) and Windows (US-025). Index snapshots and the usage cache are written with mode 0600 in directories with mode 0700 on POSIX, and through `io_mod.applyPrivatePermissions` on Windows. 0 Gateway keys in libpf error details (US-014 test). 0 `.github/` hunks applied without Q5's answer.
- **Accessibility:** OSC 7501 adds 0 visible characters to the transcript. Wrapped Ctrl+O tool rows keep every character of the status at widths of 40 and 120 columns, checked by the `resize_tests.zig` and `tui-terminal-tool.test.ts` cases that #1225 adds.
- **Scalability:** The indexer lists repositories up to 100,000 files with at most 8 workers and marks larger, split or sparse indexes incomplete instead of failing (fx's limits, unchanged).
- **Reliability:** 0 unit or E2E failures outside the baseline (US-001 for Release 1, US-012 for Release 2) at every slice commit. 0 ReleaseSafe panics for a relative `HOME` or `USERPROFILE`. 100% of slice commits build on Linux and cross-compile `pf.exe` and both Windows test executables. `windows-subset.ts` passes 13 of 13 files at US-023 and US-026. 0 tests that ran at the US-011 commit are skipped after US-012 without a named cause, on Linux (US-012) and on Windows (US-023).

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | Relative `HOME` on Linux | `env -i HOME=relative/home pf sessions` | Treated as unset; exit 1; nothing created in the current directory (US-019) | "pf sessions: HOME is not set" |
| 2 | Relative `USERPROFILE` on Windows | `USERPROFILE=relative`, `HOME=C:\Users\a` | `HOME` is used (US-019) | None |
| 3 | Both Windows homes relative | `USERPROFILE` and `HOME` relative | Exit 1, no panic (US-025) | "pf sessions: HOME is not set" |
| 4 | MCP-v2 on Windows | `PF_MCP_ENGINE=v2 pf.exe ask hi` | Exit 1 before any MCP server starts (US-006) | "pf: MCP-v2 is not available on Windows yet; unset PF_MCP_ENGINE to use the default MCP engine" |
| 5 | Slack server while Q3 holds the bridge | `mcp.json` URL `https://mcp.slack.com/mcp` without `client_id`, `pf mcp login` under MCP-v2 | Standard OAuth flow or a missing-client-id error; never `https://fx.sh/api/slack/auth` (US-008) | The standard MCP OAuth prompt or error |
| 6 | Unknown ACP mode | `session/set_mode` with `modeId: "careful"` | JSON-RPC error -32602; mode unchanged (US-004) | JSON-RPC error message |
| 7 | Poisoned repository | `.git/config` sets `core.fsmonitor` to a script | Listing never starts git; `safe_git` disables the program; the script never runs (US-017, US-025) | None |
| 8 | Git refused by `safe_git` in `auto` | Repository config `safe_git` cannot neutralize | Tool failure without security review; `ask` still prompts (US-017) | "pf did not run this git command..." |
| 9 | No usable git on Windows | No Git Bash selected, or git older than 2.25 | `safe_git` refuses to run; `pf pr` and `pf issue` snapshot sections unavailable; `auto` returns a tool failure (US-017, US-018) | Snapshot sections marked unavailable |
| 10 | Workspace inside a repository subdirectory on Windows | Root `C:\repo\src\core` | Rule prefix uses `/`; tracked files listed (US-018) | None |
| 11 | Split, sparse or oversized git index | `link` or `sdir` extension, more than 100,000 files | Listing marked incomplete instead of failing (`/home/arthur/dev/fx@f3bc7e6b:src/core/indexer/git_index.zig:161-162`) | None |
| 12 | Oversized request | Body over 30 MiB or more than 100 images | Oldest images replaced by a note in the request only (US-010) | Note naming `read_file` or `read_tool_result` |
| 13 | Provider 413 behind AI Gateway | Gateway 400 whose routing reports a 413 attempt | Classified `request_too_large`; at most 2 rebuilds per turn; no compaction (US-010) | None unless the rebuilds fail |
| 14 | Host status outside HTTP range | libpf host returns status 1024 or 0 | Provider error instead of a ReleaseSafe panic (US-010) | Provider error text |
| 15 | Binary or blocking file in a grep | File with a NUL byte; symlink to a FIFO | File skipped; grep returns without blocking (US-019) | None |
| 16 | Older Zig after the toolchain slice | `zig build` with Zig 0.16 after US-012 | Build refuses through `minimum_zig_version` | Zig's minimum-version error |
| 17 | Q1 unanswered at the end of Release 1 | US-011 certified, Q1 open | Release 2 stays TODO; Release 1 remains a complete, certified state | None |
| 18 | `pf usage` offline after a Q4 port | No provider connection | Handled failure with `status` other than `ready` (US-021) | The `reason` that fx's usage report gives |
| 19 | Old index snapshots | `~/.pf/file-index/*.idx` with `pf-file-index-v1` | Ignored under the v3 key; left on disk (US-017) | None |
| 20 | libpf tool without `idempotent` | `createPfAgent` with such a tool after #1242 | Refused at creation (US-016) | libpf error naming the tool |
| 21 | New fx spelling in a later slice | `rebrand.py check` reports a line | Slice stops; a rule is added to `scripts/rebrand.py`, never a hand edit (pf CLAUDE.md) | `check` output |
| 22 | Chained ports with a staged deletion | `port` deletes a file staged as added | File removed; summary printed (US-002) | `port` summary |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Zig 0.17 or a Release 1 merge changes Windows behavior where fx has no build, and with every host run in EP-006 the regression surfaces only after merges 31 to 51 | Med | High | Both Windows test executables cross-compile at every slice; every Windows branch the PRD adds gets a Linux unit test that injects the OS tag; US-023 attributes each failure through the `6708560`, US-011 and US-012 checkpoints and fixes it once on the final tree; Q1's option "stop after merge 29" remains available |
| 2 | Tests stop running silently after `PF_TEST_PRODUCT_EXE` and `PF_TEST_SOURCE_ROOT` disappear, or after `@hasDecl` sees only `pub` declarations | High | Med | US-012 moves the five readers to `test_paths` and compares pass and skip counts test for test with US-011; US-023 does the same on Windows |
| 3 | glibc termios overrun in pf-only paths crashes ReleaseSafe at startup | High if missed | High | US-012 routes every listed call through `io_mod.tcgetattr` and `tcsetattr` and runs a ReleaseSafe interactive start on Fedora |
| 4 | Further clean merges break pf silently beyond the six found by the analysis | Med | Med | Every slice builds on Linux, cross-compiles both Windows test executables, and runs the story's focused tests and a real `pf` run |
| 5 | A held identity (Codex CLI, Grok Build, Vercel Slack app) slips in through a later merge | Low | High | FR-03; holds in US-008 and US-009; `git grep` of identity names and `12364000946` in US-008 and US-022 |
| 6 | Q1 stays unanswered and the backlog grows | Med | Med | Release 1 is independent and certifiable; the PRD target stays `bc968ad6`, and later fx merges go to a follow-up PRD |
| 7 | The Windows host is unavailable or cannot install Zig 0.17.0 | Med | Med | Q9; EP-006 cannot be certified without it, while EP-001 to EP-005 are certified on Linux and state that their Windows runtime is verified by EP-006 |
| 8 | pf's `safe_git` and `homeDir` divergences from fx raise conflicts at every later sync | Med | Low | Divergences sit in Windows branches and are recorded in NOTICE (US-018, US-019) |
| 9 | The PGSO candidate counter merges to a wrong value | High | Low | Explicit criteria: 61 after US-006, 62 after US-017, unchanged by US-021 |
| 10 | Document merges reintroduce false statements (macOS and Linux only, installer, `pf upgrade`) | Med | Low | D-DOCS and per-story lists of statements to keep and to refuse |
| 11 | libpf durability ties `sdk/` to Vercel Workflow packages | Low today | Med if libpf ships | `sdk/durable` packages are not installed by pf scripts; Q6 before any distribution |
| 12 | `/tmp` quota exhausted by Zig caches during throwaway ports | Med | Low | Build with a shared `--cache-dir` under the session scratch directory; remove throwaway clones after each measurement |

## Non-Goals

- Porting fx merges after `/home/arthur/dev/fx@bc968ad6`; they go to a follow-up PRD.
- MCP-v2 on Windows (Job Object, handle waits, non-blocking console input); it stays refused until fx specifies a Windows process layer or pf writes one in its own PRD.
- Sessions v2 on Windows, which stays refused (previous D-V2WIN A).
- Publishing libpf, any release, the install script, release signing, or enabling `pf upgrade` (Stop for Arthur, distribution).
- Pushing to GitHub, opening pull requests, enabling Actions, or adding CODEOWNERS.
- A documentation site for pf (D-DOCS); README.md stays the product reference.
- Removing orphaned `~/.pf/file-index/*.idx` v1 snapshots or the old usage ledger files.
- Reading Git for Windows' system config (`<install>\etc\gitconfig`) in the indexer.
- Changing Paneflow (Q7) or the pages behind `paneflow.dev/agent` (Q8).
- A version bump: `pub const version` stays `0.0.12`.

## Files NOT to Modify

- `LICENSE`, `THIRD_PARTY_NOTICES.md`: license terms and Vercel's copyright stay as they are.
- `src/core/upgrade/**`: distribution is a Stop-for-Arthur zone; only US-012 may change it, and only where Zig 0.17 requires it to compile.
- `.github/**`: every hunk stays held until Q5 is answered; only US-022 applies that answer.
- OAuth and identity constants (`src/core/auth/chatgpt_oauth.zig:20`, the Vercel OAuth client id under `src/core/auth/`, the `originator`, `referrer`, `x-grok-client-identifier` and `X-XAI-Token-Auth` values in `src/gateway/openai_codex.zig`, `src/gateway/xai_grok.zig` and `src/gateway/xai_grok_models.zig`): Stop for Arthur, authentication and provider access.
- `src/core/session/session_adapter.zig:71-109`: the sessions v2 refusal on Windows.
- The existing entries of `RETARGETS`, `PROTECTED` and `SKIP_FILES` in `scripts/rebrand.py`: US-001 and US-002 only add entries.
- `/home/arthur/dev/fx`: read only for the whole PRD.
- `tasks/prd-fx-sync-0-0-13.md` and `tasks/prd-fx-sync-0-0-13-status.json`: certified record of the previous sync.
- `pub const version` in `src/main.zig` and the version in `build.zig.zon`: no version bump.
- Released sections of `CHANGELOG.md` below `## Unreleased`.
- `sdk/package.json` `version` (`0.0.0`) and the absence of a libpf publish workflow.

## Technical Considerations

- **Architecture:** Where does the MCP-v2 Windows refusal live? Recommended: one predicate next to `PF_MCP_ENGINE` parsing in `src/core/mcp_host/runtime.zig` that takes the OS tag, as `refusesOnWindows` does for sessions v2 (`src/core/session/session_adapter.zig:89-91`), called by the interactive, `ask`, `acp` and `mcp` entry points. Engineering to confirm that no other entry point loads the v2 host.
- **Architecture:** How should `safe_git` build `PATH` on Windows? Recommended: the selected Git Bash root's `usr\bin` and `mingw64\bin` only, so `core.fsmonitor=false` resolves to Git Bash's `false.exe` as `/usr/bin/false` does on POSIX (`/home/arthur/dev/fx@f3bc7e6b:src/core/shell_command/safe_git.zig:17-19`). Alternative: `SYSTEMROOT\System32` added for git's helper DLLs. Engineering to confirm on the host which DLLs git needs.
- **Data Model:** The indexer writes `pf-file-index-v3` snapshots keyed by roots and home variables, while `pf-file-index-v1` files stay orphaned. Recommended: leave them (fx's choice) and name them in the CHANGELOG. Should the snapshot key include `USERPROFILE` on Windows, since pf's `homeDir` reads it first? Recommended: yes, through fx's `environment_names` list, if the change stays inside a Windows branch.
- **API Design:** ACP mode ids change from `code` and `ask` to `auto`, `ask` and `full-access` with no compatibility alias, because no pf ACP client exists (Assumptions). `pf status --json` adds fields without changing `schema_version`; `pf usage --json` moves to `schema_version` 2 only if Q4 is answered "port".
- **Dependencies:** Zig 0.17.0 replaces 0.16.0 for Release 2 (Q1). No Zig package is added. `sdk/durable/package.json` names `@vercel/oidc` 3.8.10, `@workflow/world-local` 5.1.1 and `@workflow/world-vercel` 5.2.1, installed by no pf script (Q6). PGSO qualification on macOS needs LLVM 22.1.8 (`/home/arthur/dev/fx@f7d6cd11:scripts/pgso/toolchain.py:16`), which no story runs.
- **Migration:** Profiles, sessions and saved permissions stay backward compatible; no stored format changes except the new index snapshot and, after a Q4 port, the usage cache. Rollback for Release 1 is reverting its slice commits; rollback for Release 2 is resetting to the certified US-011 commit and reinstalling Zig 0.16.0.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| fx merges of the range ported or recorded in UPSTREAM.md | 0 of 51 | 29 of 51 at the end of Release 1; 51 of 51 at the end | Month-1 / Month-6 | UPSTREAM.md rows and "Last ported" |
| Unexpected fx spellings in a full-range throwaway port | 15 lines at `6708560` | 0 | After US-002 | `python3 scripts/rebrand.py check` on the throwaway tree |
| Unit and E2E failures outside the baseline | Measured by US-001 | 0 at every slice commit | Every slice | Test logs compared by name |
| `PF_BENCH=1 pf help` median | Measured by US-001 | At most 110% of baseline | Every slice | `hyperfine -N --runs 300` |
| Stripped ReleaseSafe size of `pf` | Measured by US-001 | At most +1 MiB (Release 1), +1.5 MiB (end) | US-011 / US-022 | `stat -c %s zig-out/bin/pf` |
| `windows-subset.ts` on the Windows host | 13 of 13 (2026-10-12) | 13 of 13 | US-023, US-026 | `bun windows-subset.ts` |
| Identity values in production code | 6 sites, all `pf`, at `6708560` | No value added without an answered Open Question | Every slice | `git grep` of identity header names and client id literals |
| Relative-HOME behavior of `pf sessions` | Panic ("reached unreachable code") | Exit 1 with "pf sessions: HOME is not set" | US-019 | `env -i HOME=relative/home ./zig-out/bin/pf sessions` |
| Processes started by file listing in a poisoned repository | `git ls-files` on every `@`-completion and glob | 0 | US-017 | Marker file absent after the poisoned-repository scenarios |
| Stop-for-Arthur questions (Q1 to Q5) without an answer or a recorded pre-decision at closure | 5 open | 0 | US-022 | Open Questions section and UPSTREAM.md Held rows |

## Open Questions

- **Q1. Zig 0.17 for pf (blocks Release 2; Arthur, before US-012).** fx requires 0.17.0 from merge 30 on. Options: (1) adopt 0.17 in this sync as three slices (merges 1 to 29 on 0.16, #1163 alone, 31 to 51 on 0.17), with every Windows-host run grouped in a final epic: pf stays aligned with fx and later syncs stay cheap; cost about 341 conflict hunks (310 mechanical), about 10 hard pf-only breaks, two runtime hazards (termios, test variables), Zig 0.17 on both hosts; risk: a release from 2026-10-01 with known regressions and a Windows libc change. (2) stop the sync after merge 29 (`786247dc`): no toolchain work now; the next sync must start with #1163 and the gap grows. (3) skip #1163 and back-port merges 31 to 51 to 0.16: no compiler change; at least 37 conflict hunks plus 108 lines of 0.17-only API now, a tax at every later sync, and a dead end when 0.18 removes the deprecated names. (4) migrate pf to 0.17 before the sync with a script: measured worse in its naive form (+58 hunks). The PRD's evidence favors (1); the choice is Arthur's. Sub-decisions that touch Stop-for-Arthur zones, presented without a choice: pin `0.17.0` exactly or accept `0.17+`; the workflow pins (`.github/workflows/windows.yml:66`, `release.yml`, `dev-release.yml`, `bench.yml`, `binary-size.yml`, `ci.yml`, `macos.yml`, `.github/actions/setup-pgso`), which fall under Q5; macOS 15 as the minimum of release binaries (Zig 0.17's default); LLVM 22.1.8 for PGSO qualification; keeping pf's `windows_spawn_mutex` (`src/core/shared/io.zig:54`) now that Zig 0.17 serializes its own spawns.
- **Q2. libpf sign-in modules under the Codex CLI and Grok Build OAuth clients (Arthur, before US-022; pre-decision: held).** fx #1209 and #1211 add `sdk/chatgpt-sign-in.js` and `sdk/grok-sign-in.js`, which obtain tokens for servers that embed libpf with client id `app_EMoamEEZ73f0CkXaXp7hrann` (`/home/arthur/dev/fx@016cdc54:sdk/chatgpt.js:7`, the same value as pf's `src/core/auth/chatgpt_oauth.zig:20`), redirect `localhost:1455` (`/home/arthur/dev/fx@016cdc54:sdk/chatgpt-sign-in.js:11`), and client id `b1a00492-073a-47ea-816f-4c329264a828` (`/home/arthur/dev/fx@7e9b98bf:sdk/grok.js:7`). Options: (A) keep them held permanently: libpf hosts bring their own tokens; no third-party server uses these clients through pf; divergence of about 10 SDK files at every later sync. (B) port them with the same identities as pf's CLI: parity with fx; extends clients registered for other CLIs to arbitrary servers, under terms for third-party servers that pf has not verified. (C) port them but require the host to pass its own client id and redirect: no borrowed identity in pf's code; the modules differ from fx. (D) ask OpenAI and xAI for pf's own OAuth clients first: cleanest, with an unknown delay and no guarantee. Decides: US-022 and the Held rows of `016cdc54` and `7e9b98bf`.
- **Q3. Slack bridge in MCP-v2 (Arthur, before US-022; pre-decision: held, consistent with the answer D to the previous sync's Q1 for fx #1101).** fx #1216 applies Vercel's Slack app (`12364000946.12017137861236`, `/home/arthur/dev/fx@53a561be:src/core/mcp_host/slack.zig:14`) to any `mcp.slack.com` server without a client id, through `https://fx.sh/api/slack/auth` (`/home/arthur/dev/fx@53a561be:src/core/mcp_host/config.zig:121-122`). Options: (A) take fx's code: Slack works out of the box; pf users sign in through Vercel's app and bridge, which pf does not own. (B) register pf's own Slack app and bridge on paneflow.dev: same experience under pf's identity; a new service with hosting cost and Slack review. (C) generic OAuth only: users put their own `client_id` in `mcp.json`; no shared app; more setup for users. (D) keep held: no Slack preset; same as today. Decides: US-022 and the Held row of `53a561be`.
- **Q4. fx #1226, `/usage` from provider reports (Arthur, before US-021 is certified; pre-decision: skipped).** fx replaces pf's local cost ledger with reports read from AI Gateway (`/v1/report`, and `api.vercel.com/ai-gateway/usage-report` with the Vercel OAuth token), ChatGPT (`chatgpt.com/backend-api/wham/usage`, `/wham/profiles/me`, `/wham/usage/daily-token-usage-breakdown`, `/home/arthur/dev/fx@bc968ad6:src/usage/codex.zig:13-15`) and Grok (`/v1/billing`, `/v1/settings`), under the identities pf already sends for inference. Options: (1) port as is: parity with fx; new calls to undocumented endpoints; `/cost`, `24h`, `30d`, the per-session view and ACP `cost` disappear. (2) port with AI Gateway only: documented Vercel endpoints only; Codex and Grok show `unsupported_provider`; a pf divergence in `src/usage/`. (3) skip permanently and keep the local ledger: no new calls; a durable divergence over about 20,000 lines of session code that later fx merges touching sessions, ACP or `gateway_step` will conflict with. Sub-decision: leave the orphaned ledger files (fx's choice) or clean them once.
- **Q5. `.github/` hunks of the range (Arthur, before US-022; pre-decision: held; CODEOWNERS skipped).** The range edits `.github/` in #1162, #1180, #1202, #1209, #1211, #1212, #1163, #1230, #1242, #1196, #1223 and #1254: Zig 0.17 pins and `brew install llvm@22`, SDK lanes that run `npm ci --prefix sdk/durable` (Vercel packages) and download `tla2tools.jar` with Java, the indexer boundary step, and a CODEOWNERS file naming `@fazxes`. Options: (A) take every hunk except CODEOWNERS and align pf-only workflows (`windows.yml`, `release.yml`) to the same Zig: CI matches fx once Actions is enabled; network installs and a Java download in CI. (B) take only checks that need no network install or secret (Zig pins, indexer boundary), keep SDK durable lanes on `memory`: smaller CI; libpf durability less covered. (C) keep everything held until pf is pushed with Actions enabled: no CI edits now; workflows stay pinned to Zig 0.16 and would fail if pushed after US-012. For CODEOWNERS: skip, a pf file naming Arthur, or fx's file (which would request a Vercel reviewer). **Answered for #1180 and #1202 (Arthur, 2026-10-13):** port their `.github/` hunks, because the ported `sdk/scripts/package-libpf.mjs` cannot package libpf without the Worlds that those SDK lanes install; the other merges' hunks keep the pre-decision.
- **Q6. libpf durability on Vercel Workflow (non-blocking; Arthur, before any libpf distribution).** `createPfAgent()` defaults to `local()` sessions, or `vercel()` when `VERCEL` is set (`/home/arthur/dev/fx@bc968ad6:sdk/node.js:684`), and falls back to `VERCEL_OIDC_TOKEN` (`:719`). The PRD ports this in lockstep (D-SDK) because pf distributes nothing. Options before distribution: keep fx's behavior; drop `vercel.mjs` and the Vercel default; or default to `memory()`.
- **Q7. Paneflow's runtime catalog does not know pf (non-blocking; Arthur, Paneflow repository).** Paneflow reads OSC 7501 as its source of turn state (`/home/arthur/dev/paneflow/ARCHITECTURE.md:343`) and lists `fx` as a contested alias (`/home/arthur/dev/paneflow/crates/paneflow-agent-config/build_support.rs:53`, `:107`) but not `pf`. Should Paneflow add a `pf` entry so that `app=pf` reports reach its UI?
- **Q8. Dead `paneflow.dev/agent` links (non-blocking; Arthur).** `https://paneflow.dev/agent/docs` and `/agent/feedback` answer 404 on 2026-10-13, while `README.md:67`, `:78`, `:130` and `src/core/feedback/runtime.zig:3` link to them. Options: publish the pages; point the links at this repository's documents; or remove them.
- **Q9. Zig on the Windows host (Arthur, before EP-006).** Can the Windows 11 host install Zig 0.17.0 next to 0.16.0, so US-023 runs the final tree on 0.17 and the attribution checkpoints (`6708560` and the US-011 commit) on 0.16? EP-006 cannot be certified without the host; EP-001 to EP-005 do not need it.
[/PRD]
