# Paneflow Agent

Tiny, open, embeddable, native coding agent. The command is `pf`.

⚠ Status: Experimental. Use at your own risk.

Paneflow Agent is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal. It derives from [fx](https://github.com/vercel-labs/fx) by Vercel; see [NOTICE](NOTICE).

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `pf ask` for scripts, or embedded through ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

## Install

Paneflow Agent does not publish releases yet. [Build it from source](#build-from-source), then put `zig-out/bin/pf` on your `PATH`. No install script or package manager (Homebrew, winget, Scoop) is available.

## Get started

Sign in with one of:

- `pf login`: Vercel AI Gateway
- `pf login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `pf login grok`: Grok subscription (xAI OAuth)
- `pf setup`: AI Gateway API key

Then start the interactive shell from a project:

```bash
cd your_project
pf
```

Or make a one-shot request:

```bash
pf ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
pf preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Documentation

Visit [paneflow.dev/agent/docs](https://paneflow.dev/agent/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://paneflow.dev/agent/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.pf/settings.json`, then select one for the profile or a single invocation:

```bash
pf provider local
PF_PROVIDER=openrouter PF_MODEL=openai/gpt-4.1 pf ask "review this change"
```

See [Custom model connections](https://paneflow.dev/agent/docs/configure-pf/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). pf can tell the gateway which providers to use, in what order:

```jsonc
// ~/.pf/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.pf.json`, and per launch:

```bash
pf --provider-order azure,openai --provider-strict
pf ask --provider-order bedrock "review this change"
PF_PROVIDER_ORDER=vertex PF_PROVIDER_STRICT=1 pf
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

pf ships with `pf-dark` and `pf-light` and follows your terminal's light or dark mode. Pin a variant with `PF_THEME=light` or `PF_THEME=dark`, or drop a VS Code format theme at `~/.pf/themes/<name>.json` and select it with the `theme` setting or `PF_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://paneflow.dev/agent/docs/configure-pf/configuration) for all environment variables.

## Embed pf

pf builds as a native binary or WebAssembly. Applications embedding pf can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `pf acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createPfAgent()` | Embed the agent core in a JavaScript host with `pf-core.wasm`. |
| `createPfTerminal()` | Embed the interactive terminal with `pf-term.wasm`. |

pf does not distribute a JavaScript SDK. The [SDK sources](sdk/README.md) build the `libpf` package from this repository for pf's own tests and benchmarks, and the WebAssembly SDK is experimental. To embed an agent in a JavaScript application from npm, use the SDK that the upstream [fx](https://github.com/vercel-labs/fx) project publishes; it embeds that project's agent, not pf.

## Slack workspace installation

`pf slack install` and personal Slack MCP authorization still use the fx Slack app and its bridge on fx.sh, which Vercel operates. Paneflow Agent does not run its own Slack app yet. Run `pf slack --help` for the commands; credentials stay in the owner-only file `~/.pf/slack/installation.json`.

## Build from source

Building pf requires [Zig 0.16.0+](https://ziglang.org/download/). From a clone of this repository:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/pf
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Windows

pf runs natively on Windows 10 version 1809 or later and Windows 11, on x86_64. The interactive shell needs a console with virtual terminal support: Windows Terminal and the VS Code integrated terminal are supported, and pf exits with an error in a console that cannot process escape sequences. Headless commands such as `pf ask` and `pf status` run from any console.

Build from source as above, from PowerShell or Git Bash, with Zig 0.16.0 for Windows x86_64 on `PATH`. The build produces `zig-out\bin\pf.exe`; put that directory on `PATH`. Your profile lives in `%USERPROFILE%\.pf`, so pf finds the same settings, credentials, and sessions from PowerShell and from Git Bash.

### Command shell

The `shell` tool runs commands in Git Bash when it is available and in PowerShell otherwise. It never uses `cmd.exe`. pf selects the shell once per process, in this order:

1. `PF_GIT_BASH_PATH`, the absolute path of a Git Bash `bash.exe`, when it is set
2. the `bash.exe` installed with the `git.exe` found on `PATH`
3. `%ProgramFiles%\Git\bin\bash.exe`
4. `pwsh.exe` (PowerShell 7) on `PATH`
5. `powershell.exe` (Windows PowerShell 5.1) on `PATH`

Set `PF_WINDOWS_SHELL` to `bash` to require Git Bash, to `powershell` to skip it, or to `auto` (the default) for the order above. With `bash`, pf reports an error instead of falling back when Git Bash is missing. `pf doctor` shows the selected shell and why it was chosen, and the model is told which shell and path conventions to use.

Under Git Bash, permission analysis works as on Linux and macOS. pf does not parse PowerShell, so under PowerShell every command needs an exact approval of that command or a configured rule that names it exactly; in `auto` mode, each one goes through the security review. Wildcard allow rules and the automatic approval of routine read-only commands never apply to PowerShell commands.

### Interactive sessions

Interactive programs that the `shell` tool runs with a terminal, such as REPLs, run in a Windows pseudo console (ConPTY) under the selected Git Bash or PowerShell. A detached terminal host owns these sessions, so they survive the pf process that started them and a later pf run, such as `pf ask --resume last`, continues them. Each session runs inside a Job Object that only the host holds: when the host stops, every process of its sessions stops with it, and those sessions are reported as lost. The host listens on an AF_UNIX socket inside `%USERPROFILE%\.pf` and accepts only processes of the same Windows account. Windows has no tmux, so every session uses this host.

### Credentials and notifications

Stored credentials, such as sign-in sessions, API keys, and MCP OAuth tokens, are encrypted with DPAPI to your Windows account, so another account or a copy of the disk cannot read them. A file that cannot be decrypted on the current logon, for example over an OpenSSH key-based logon or after a profile move, is kept as a `.unreadable` backup next to the original, and pf asks you to sign in again.

Turn notifications ring the terminal bell, as on Linux. In Windows Terminal, pf also requests a desktop notification, which Windows Terminal shows while its window is unfocused when `compatibility.allowOSC777` is enabled in its settings.

### Not yet available on Windows

- Image paste from the clipboard
- `pf slack install`
- The full output of a truncated command in a session that is not saved, such as `pf ask --no-save`: saved sessions keep it
- Release downloads and `pf upgrade`: build from source

### Key bindings in Windows Terminal

Windows Terminal handles some key chords itself before pf receives them ([default actions](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/actions)). Use these alternatives, or remove the Windows Terminal binding in its settings:

| Key | Windows Terminal action | Use instead |
|---|---|---|
| Alt+Enter | Toggle full screen | Shift+Enter, Ctrl+J, or Esc then Enter for a new line |
| Ctrl+V | Paste text | Text paste works; image paste is not available on Windows |
| Ctrl+Tab, Ctrl+Shift+Tab | Switch tabs | Tab, Shift+Tab |
| Alt+Left, Alt+Right | Move pane focus | Ctrl+Left, Ctrl+Right, or Alt+B, Alt+F to move by word |
| Alt+Up, Alt+Down | Move pane focus | Ctrl+Up, Ctrl+Down to move by row |
| Alt+Shift+Arrow | Resize pane | Ctrl+Shift+Left, Ctrl+Shift+Right, or Alt+Shift+B, Alt+Shift+F to select by word; Shift+Up, Shift+Down to select by row |
| Ctrl+Shift+Up, Ctrl+Shift+Down, Ctrl+Shift+PgUp, Ctrl+Shift+PgDn, Ctrl+Shift+Home, Ctrl+Shift+End | Scroll the buffer | Shift+Up, Shift+Down, Shift+PgUp, Shift+PgDn to extend the selection |
| Ctrl+Shift+A, Ctrl+Shift+F | Select all, find | Shift+Home, Shift+Right |
| Ctrl+Shift+C, Ctrl+Shift+V, Ctrl+Shift+P, and other Ctrl+Shift+letter chords | Copy, paste, command palette, tabs | The same chord without Shift |

Ctrl+C reaches pf unless text is selected in Windows Terminal, in which case it copies the selection.

## Security

Report security vulnerabilities privately through GitHub's private vulnerability reporting on this repository instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
