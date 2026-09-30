# Upstream

Paneflow Agent follows [vercel-labs/fx](https://github.com/vercel-labs/fx) without sharing its git history. Changes from fx are ported by hand, one range at a time.

| Field | Commit |
|---|---|
| Base | `1b1f9af1619de4dbf7b4a48a50bb11f77469e988` (2026-09-30) |
| Last ported | `1b1f9af1619de4dbf7b4a48a50bb11f77469e988` |

## Porting a range

Keep a clone of fx next to this repository, at `../fx-upstream`:

```sh
git clone git@github.com:vercel-labs/fx.git ../fx-upstream
```

Then port everything between the last ported commit and a target:

```sh
git -C ../fx-upstream fetch origin
python3 scripts/rebrand.py port <last-ported> origin/main
```

`port` renames each changed fx file with the rules in `scripts/rebrand.py` and 3-way merges it into the worktree. Files where pf diverged keep conflict markers and are listed as `CONFLICT`. Resolve them, then:

1. Run `python3 scripts/rebrand.py check`.
2. Run `zig build`, the focused tests for the ported changes, and `zig fmt --check src/`. Some tests pin a digest over text that the rename changes, such as the model-facing tool contracts and the automatic review policy. When fx changes that text, update the pin and its mapping in `scripts/rebrand.py`.
3. Replace the "Last ported" commit above with the full target SHA, and commit it together with the port.

`CHANGELOG.md` is skipped: pf writes its own entries.
