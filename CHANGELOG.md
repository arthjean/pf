## 0.0.13

<!-- release:start -->
<!-- release:placeholder -->
Replace this placeholder with the public release notes before publishing.
<!-- release:end -->

# Paneflow Agent

## Unreleased

Paneflow Agent starts from fx 0.0.12 ([vercel-labs/fx](https://github.com/vercel-labs/fx) commit `1b1f9af1`). For changes before that point, see the [fx changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md).

### Breaking Changes

- **New name:** The command is `pf`. Profile state moves from `~/.fx` to `~/.pf`, project defaults from `.fx.json` to `.pf.json`, workspace skills from `.fx/skills` to `.pf/skills`, and environment variables from `FX_*` to `PF_*`. Existing fx settings, sessions, and credentials are not read.
- **SDK:** The JavaScript package is `libpf`, with `createPfAgent()` and `createPfTerminal()`, and its error codes use the `LIBPF_` prefix.

### Improvements

- **Upgrades:** `pf upgrade` reports that no release channel is available, and automatic upgrades are off until Paneflow Agent publishes its own releases.
