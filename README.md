# Paneflow Agent

Tiny, open, embeddable, native coding agent. The command is `pf`.

⚠ Status: Experimental. Use at your own risk.

Paneflow Agent is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal. It derives from [fx](https://github.com/vercel-labs/fx) by Vercel; see [NOTICE](NOTICE).

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `pf ask` for scripts, or embedded through libpf and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

## Install

Paneflow Agent does not publish releases yet. [Build it from source](#build-from-source), then put `zig-out/bin/pf` on your `PATH`.

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

The SDK package is `libpf`; it is not published to npm yet. See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Slack workspace installation

`pf slack install` and personal Slack MCP authorization still use the fx Slack app and its bridge on fx.sh, which Vercel operates. Paneflow Agent does not run its own Slack app yet. Run `pf slack --help` for the commands; credentials stay in the owner-only file `~/.pf/slack/installation.json`.

## Build from source

Building pf requires [Zig 0.16.0+](https://ziglang.org/download/). From a clone of this repository:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/pf
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities privately through GitHub's private vulnerability reporting on this repository instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
