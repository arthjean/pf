# Upstream

Paneflow Agent follows [vercel-labs/fx](https://github.com/vercel-labs/fx) without sharing its git history. Changes from fx are ported by hand, one slice of first-parent fx merges at a time.

| Field | Commit |
|---|---|
| Base | `1b1f9af1619de4dbf7b4a48a50bb11f77469e988` (2026-09-30) |
| Last ported | `2c7a4f83f06f417d4f7e4a09fb18058e30379fb1` |

"Last ported" means that every first-parent fx merge up to and including that commit is ported, except the merges listed under "Skipped", and that the hunks listed under "Held" are kept at pf's state.

## Skipped

| fx merge | fx PR | Open Question | Revisited by |
|---|---|---|---|
| `73308320925d5c31b4f57b875f07e77eb8b051d6` | #1101 | Q1, answered D: skip the Slack preset; denied message ported by hand | permanent |
| `4d966e272cfc4296cdf703f409480088cf2e72ba` | #1153 | Q7, answered keep 0.0.12: no release during the sync | permanent |
| `e4915028b87319bdada544545a4095f0bdf2108b` | #1161 | D-DOCS: Vercel contributor policy | permanent |
| `c1db919112c5c83fdcc0be508f8d34d189d149af` | #1162 | libpf is not distributed | permanent |

Each row gives the fx merge's full 40-character SHA, its fx pull request, the Open Question that blocks it, and the story that revisits it.

## Held

| fx merge | fx PR | Held | Hold commit | Open Question | Revisited by |
|---|---|---|---|---|---|
| `34f1ed14de47760b44d628ec2d5eb28055b9adf0` | #1062 | The AI Gateway compaction summary fallback to another model family in `src/core/compactor/model.zig`, the unit tests "a failed or empty summary falls back to another family at its lowest reasoning" in `src/core/compactor/model.zig` and "compaction writes the summary with the least reasoning each model accepts" in `src/core/agent/runtime/tests/gateway_flow.zig`, and the retry expectations in `tests/e2e/tui-compaction-activity.test.ts` and `tests/e2e/gateway-stream-lifecycle.test.ts`, which pf rewrites to expect the primary error, and the README sentence on the retry | `9c1cbd1590daf75961e42ea7df94cb7afff76340` | Q3, answered 2026-10-10: keep pf's behavior | permanent |
| `6bdd49736abd4a85fb6dd60a824e4329784f34c0` | #1137 | The AI Gateway-billed shell-path evaluation `tests/evals/shell-path-ab.test.ts` | `3c65e02f8d4ec0163b4e9bab3c924d21c8d6595f` | Q8, answered 2026-10-10: not ported | permanent |
| `016cdc543148643317c3061c16689f0c25ac8dc3` | #1209 | The libpf ChatGPT sign-in module: `sdk/chatgpt-sign-in.js`, `sdk/types/chatgpt.d.ts`, the `./chatgpt` export and `files` entry of `sdk/package.json`, its `sdk/scripts/package-libpf.mjs` entry, `sdk/tests/test-chatgpt-sign-in.mjs` and its lines in `sdk/tests/test-node-napi.mjs`, `sdk/tests/test-types.mjs` and `sdk/tests/types/adapters.mts`, and its section of `sdk/README.md` | `72e7979ec6e58bd2d658d6d570cbd17f9ff20531` | Q2 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `016cdc543148643317c3061c16689f0c25ac8dc3` | #1209 | The `.github/workflows/ci.yml` lines that run `sdk/tests/test-durable-codex-crash.mjs` | `72e7979ec6e58bd2d658d6d570cbd17f9ff20531` | Q5 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `53a561beabad811e9ef55375d4147591f76ea33f` | #1216 | The MCP-v2 Slack bridge: `src/core/mcp_host/slack.zig`, the Slack client id and resource that `src/core/mcp_host/config.zig` fills in for `mcp.slack.com`, the bridged sign-in of `src/core/mcp_host/login.zig` and `src/core/mcp_host/runtime.zig`, the `add slack` verb of `src/core/mcp_host/verbs.zig`, their unit tests, and the test "Slack signs in through fx.sh: the bridge's form comes back from its origin only" in `tests/e2e/mcp-auth.test.ts` | `ace8f2e9e6e621878fb6b6b2b25af006a0362577` | Q3 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `6d622072127955b56369dea847e3c57dd5c30091` | #1210 | Its edit of the held `sdk/types/chatgpt.d.ts` | `defae9808550da44a0868eb5804dbda4acf45f42` | Q2 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `7e9b98bff0011781a84d81437c5206d26599955f` | #1211 | The libpf Grok sign-in module: `sdk/grok-sign-in.js`, `sdk/types/grok.d.ts`, the shared sign-in helpers `sdk/oauth.js`, the `./grok` export and the `files` entries of `sdk/package.json`, their `sdk/scripts/package-libpf.mjs` entries, `sdk/tests/test-grok-sign-in.mjs` and its lines in `sdk/tests/test-node-napi.mjs`, `sdk/tests/test-types.mjs` and `sdk/tests/types/adapters.mts`, the Grok sign-in paragraph of `sdk/README.md`, and its edit of the held `sdk/chatgpt-sign-in.js` | `defae9808550da44a0868eb5804dbda4acf45f42` | Q2 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `7e9b98bff0011781a84d81437c5206d26599955f` | #1211 | Its `.github/workflows/ci.yml` lines for the provider crash test | `defae9808550da44a0868eb5804dbda4acf45f42` | Q5 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `914f01f6d015d83152a957dc2d9d116a0e085ebe` | #1212 | Its `.github/workflows/ci.yml` lines for the provider crash test | `defae9808550da44a0868eb5804dbda4acf45f42` | Q5 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `6fc796a7ec94dff5a086e91064bf536545a56c42` | #1219 | Its edit of the held Slack bridge form handler `answerForm` in `src/core/mcp_host/login.zig` | `ace8f2e9e6e621878fb6b6b2b25af006a0362577` | Q3 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `f7d6cd1120f25438b200761d133fb32dce38c729` | #1163 | Its edit of `src/core/mcp/slack_preset.zig`, the Slack preset that pf skipped with fx #1101 | `7742a8320e6164febb3593cb4ff39f296fa7ab40` | Q1 of `tasks/prd-fx-sync-0-0-13.md`, answered D | permanent |
| `f7d6cd1120f25438b200761d133fb32dce38c729` | #1163 | Its edit of the held Slack bridge `src/core/mcp_host/slack.zig` | `7742a8320e6164febb3593cb4ff39f296fa7ab40` | Q3 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |
| `f7d6cd1120f25438b200761d133fb32dce38c729` | #1163 | Its Zig 0.17.0 and LLVM 22 pins in `.github/actions/setup-pgso/action.yml`, `.github/workflows/bench.yml`, `binary-size.yml`, `ci.yml`, `dev-release.yml`, `macos.yml` and `release.yml`, including `ZIG_GLOBAL_CACHE_DIR` in place of `--global-cache-dir` | `7742a8320e6164febb3593cb4ff39f296fa7ab40` | Q5 of `tasks/prd-fx-sync-bc968ad6.md` | US-022 |

Each row gives the fx merge's full 40-character SHA, its fx pull request, the held files or hunks, the full SHA of the pf hold commit, the Open Question that keeps them, and the story that revisits them.

A row leaves its section only when its merge or hunk is ported. A divergence that Arthur decides to keep stays listed, with `permanent` in place of the revisiting story, so that "Last ported" stays exact. Open Questions and stories refer to the PRD of the sync that recorded the row, such as `tasks/prd-fx-sync-0-0-13.md`.

While any Held row that is not `permanent` exists, `NOTICE` carries one provisional bullet that names the held fx behavior. The first slice that holds a hunk adds it (US-007 of `tasks/prd-fx-sync-0-0-13.md`, if its Q4 is still open), and the story that resolves the last such row removes it. Each `permanent` row gets its own `NOTICE` line.

## Porting a slice

Keep a clone of fx next to this repository, at `../fx`, never as a remote of this repository:

```sh
git clone git@github.com:vercel-labs/fx.git ../fx
```

Refresh the clone only when a new sync starts, never while a sync PRD such as `tasks/prd-fx-sync-0-0-13.md` is open, then list the pending first-parent merges:

```sh
git -C ../fx fetch origin
git -C ../fx log --first-parent --reverse --format='%H %s' <last-ported>..origin/main
```

Port one slice at a time. A slice is a contiguous run of one or more of those merges, and it always ends on a merge, so that a port never stops inside a merged branch:

```sh
python3 scripts/rebrand.py port <last-ported> <last merge of the slice>
```

`port` reads `../fx` unless `--upstream` names another clone. It renames each changed fx file with the rules in `scripts/rebrand.py` and 3-way merges it into the worktree. It writes files that fx adds with fx's file mode and stages them, so review them with `git diff --cached`. Files where pf diverged keep conflict markers and are listed as `CONFLICT`. Resolve them, then:

1. Run `python3 scripts/rebrand.py check`.
2. Run `zig build`, the focused tests for the ported changes, and `zig fmt --check src/`. Some tests pin a digest over text that the rename changes, such as the model-facing tool contracts and the automatic review policy. When fx changes that text, update the pin and its mapping in `scripts/rebrand.py`.
3. Replace the "Last ported" commit above with the full SHA of the slice's last merge, and commit it together with the port. Name the slice's fx range in the commit message as `fx <from>..<to>` with short SHAs and its fx pull request numbers, never with an absolute path.

`CHANGELOG.md` is skipped: pf writes its own entries.

## Skipping a slice

When a slice waits on an unanswered Open Question whose pre-decision state is "skip":

1. Do not run the slice.
2. In one commit, set "Last ported" to the skipped merge's full SHA and add its Skipped row.
3. Port the next slice from that SHA, and resolve later conflicts toward pf without the skipped pull request.
4. Once the Open Question is answered in favor of fx, the revisiting story (US-028 of `tasks/prd-fx-sync-0-0-13.md`) ports the merge alone with `python3 scripts/rebrand.py port <merge>^1 <merge>` and removes its Skipped row.

pf does not take fx version bumps. pf changes `pub const version` in `src/main.zig` only through its own release flow, so a merge that only bumps fx's version and its changelog is skipped this way and listed as `permanent`.

## Holding a hunk

When a slice contains a hunk or file that waits on an unanswered Open Question:

1. Commit A takes fx's resolution of the whole slice and leaves `UPSTREAM.md` and `NOTICE` unchanged. It is never gate-checked, pushed, or built as a release.
2. Commit B restores pf's side of the held hunks or files and passes the checks. It sets "Last ported" to the full SHA of the slice's last merge and adds the Held row with its hold commit set to `pending`.
3. The next commit that edits `UPSTREAM.md` replaces `pending` with B's full SHA from `git rev-parse`.
4. Once the Open Question is answered in favor of fx, the revisiting story (US-028 of `tasks/prd-fx-sync-0-0-13.md`) runs `git revert <B>`. When the revert conflicts in `UPSTREAM.md`, "Last ported" keeps its current value and only that Held row is removed.
