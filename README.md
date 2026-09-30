```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://paneflow.dev/agent/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

pf is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `pf ask` for scripts, or embedded through libpf and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/releases/latest"><img alt="pf CLI release" src="https://img.shields.io/github/v/release/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Install

```bash
curl -fsSL https://paneflow.dev/agent/setup.sh | bash
```

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

The SDK is published to npm as [libpf](https://www.npmjs.com/package/libpf). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Slack workspace installation

Run `pf slack install` to install the pf bot in the configured Vercel Slack
workspace. Keep the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at paneflow.dev/agent returns the authorization to the CLI;
PKCE state and the verifier stay in memory. The companion web bridge must be
deployed and configured first.

After the CLI saves the installation, the browser returns to an paneflow.dev/agent confirmation
page. You can close that tab or refresh it after the command exits.

`pf slack status --json` reports local installation metadata without tokens.
Plain-text output omits Slack IDs and shows expiration as a readable UTC date
and time. JSON output retains the IDs and Unix timestamps for scripts.
`pf slack refresh` rotates the local bot credentials when needed. Credentials
live in the owner-only file `~/.pf/slack/installation.json`; no hosted database
or background refresh service is created. An expired refresh token requires
installation again. This workspace operation is separate from each employee's
MCP user authorization. Employees connect their own account with
`/mcp auth slack --open` in an pf session (or `pf mcp auth slack` from a terminal).
For `https://mcp.slack.com/mcp`, the CLI recognizes the pf app by its public
Client ID and uses the HTTPS callback for personal login. Changing that Client
ID requires a CLI update. OAuth uses the canonical form of Slack's advertised
resource, `https://mcp.slack.com/`, while the MCP transport remains at
`https://mcp.slack.com/mcp`. First login and reauthorization request the full shared
`user_scopes` list from paneflow.dev/agent. If local `scopes` are configured, they must include
every shared scope; extra local scopes are not requested. A narrower or explicitly
empty list stops authorization before opening the browser, leaving the configuration
and stored credentials unchanged. Remove the override only if you want to authorize
the full shared scope set. Per-user read-only subsets are not supported for the pf app. Saved scopes,
Slack's advertised capabilities, and scope challenges cannot expand this
request. The shared list contains nine personal scopes configured for pf and
advertised by Slack MCP; changing it requires a deliberate configuration update
and any necessary Slack approval. This does not revoke
permissions on previously issued tokens or change token refresh behavior. It
opens an ephemeral loopback listener instead of the configured `callback_port`,
keeps PKCE and personal tokens in the CLI, and shows “Slack connected” after
saving to the existing MCP credential store. Other MCP providers and different
Slack app Client IDs retain their direct callback behavior without contacting
paneflow.dev/agent. Pf app authorization requires paneflow.dev/agent to be available; an unavailable
metadata endpoint returns `SlackBridgeUnavailable`. Deploy the web
personal-authorization routes and scope metadata before releasing this CLI.
Missing or invalid shared scopes stop authorization rather than falling back
to Slack's broader capabilities. Keep the registered
localhost callback for older clients until they have upgraded. Slack workspace
approval requirements still apply to personal authorization.

Bot installation does not establish whether
Slack will display a hoverable “Sent using @pf” attribution; that requires a
live message test.

## Build from source

Building pf requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd pf
zig build -Doptimize=ReleaseSafe
./zig-out/bin/pf
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities through the [contact page](https://paneflow.dev/agent/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
