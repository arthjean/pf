# Upstream

Paneflow Agent follows [vercel-labs/fx](https://github.com/vercel-labs/fx) without sharing its git history. Changes from fx are ported by hand, one slice of first-parent fx merges at a time.

| Field | Commit |
|---|---|
| Base | `1b1f9af1619de4dbf7b4a48a50bb11f77469e988` (2026-09-30) |
| Last ported | `7e39bf132a816141b43b8b051949fbff1827915f` |

"Last ported" means that every first-parent fx merge up to and including that commit is ported, except the merges listed under "Skipped", and that the hunks listed under "Held" are kept at pf's state.

## Skipped

| fx merge | fx PR | Open Question | Revisited by |
|---|---|---|---|
| `73308320925d5c31b4f57b875f07e77eb8b051d6` | #1101 | Q1, answered D: skip the Slack preset; denied message ported by hand | permanent |

Each row gives the fx merge's full 40-character SHA, its fx pull request, the Open Question that blocks it, and the story that revisits it.

## Held

| fx merge | fx PR | Held | Hold commit | Open Question | Revisited by |
|---|---|---|---|---|---|
| `14893f6460dcba305c5e11d510f5f303eee3b574` | #1082 | The upgrade relaunch argv block and `writeUpgradeRelaunchFailure` in `src/core/app/app_entry_runtime.zig`, the unit test "a v2 handoff relaunches and hints with --sessions-v2", and the relaunch argv expectation in `tests/e2e/tui-resume.test.ts` | `fa515c535aa555ebf8252e962670961fc0e50d38` | Q4 | US-028 |
| `34f1ed14de47760b44d628ec2d5eb28055b9adf0` | #1062 | The AI Gateway compaction summary fallback to another model family in `src/core/compactor/model.zig`, the unit tests "a failed or empty summary falls back to another family at its lowest reasoning" in `src/core/compactor/model.zig` and "compaction writes the summary with the least reasoning each model accepts" in `src/core/agent/runtime/tests/gateway_flow.zig`, and the retry expectations in `tests/e2e/tui-compaction-activity.test.ts` and `tests/e2e/gateway-stream-lifecycle.test.ts`, which pf rewrites to expect the primary error, and the README sentence on the retry | `9c1cbd1590daf75961e42ea7df94cb7afff76340` | Q3 | US-028 |
| `34f1ed14de47760b44d628ec2d5eb28055b9adf0` | #1062 | The "Check compactor boundary" steps and the lint-scripts entry in `.github/workflows/ci.yml` and `.github/workflows/full-ci.yml`, and the CI wording on the compactor boundary check in `AGENTS.md` and `CONTRIBUTING.md` | `9c1cbd1590daf75961e42ea7df94cb7afff76340` | Q6 | US-028 |

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

## Holding a hunk

When a slice contains a hunk or file that waits on an unanswered Open Question:

1. Commit A takes fx's resolution of the whole slice and leaves `UPSTREAM.md` and `NOTICE` unchanged. It is never gate-checked, pushed, or built as a release.
2. Commit B restores pf's side of the held hunks or files and passes the checks. It sets "Last ported" to the full SHA of the slice's last merge and adds the Held row with its hold commit set to `pending`.
3. The next commit that edits `UPSTREAM.md` replaces `pending` with B's full SHA from `git rev-parse`.
4. Once the Open Question is answered in favor of fx, the revisiting story (US-028 of `tasks/prd-fx-sync-0-0-13.md`) runs `git revert <B>`. When the revert conflicts in `UPSTREAM.md`, "Last ported" keeps its current value and only that Held row is removed.
