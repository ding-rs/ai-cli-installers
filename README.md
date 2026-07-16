# AI CLI Installers

Standalone, brand-neutral installers for configuring popular AI command-line tools with a caller-supplied API endpoint and key.

## Installers

| Tool | Installer | Platform | Upstream installation source |
| --- | --- | --- | --- |
| Claude Code | [`claude-code.sh`](https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.sh) | macOS, Linux, WSL | Anthropic's official `https://claude.ai/install.sh` |
| Claude Code | [`claude-code.ps1`](https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.ps1) | Windows PowerShell 5.1+ | Anthropic's official `https://claude.ai/install.ps1` |
| Codex | [`codex.sh`](https://github.com/ding-rs/ai-cli-installers/releases/latest/download/codex.sh) | macOS, Linux, WSL | The official `@openai/codex` npm package; Node 22 is bootstrapped with the official nvm installer when needed |
| Hermes Agent | [`hermes.sh`](https://github.com/ding-rs/ai-cli-installers/releases/latest/download/hermes.sh) | macOS, Linux | Nous Research's official `https://hermes-agent.nousresearch.com/install.sh` |
| OpenClaw | [`openclaw.sh`](https://github.com/ding-rs/ai-cli-installers/releases/latest/download/openclaw.sh) | macOS, Linux, WSL | OpenClaw's official `https://openclaw.ai/install.sh` |

These `releases/latest/download` links are stable after a GitHub Release exists. Before the first release, the latest download URLs do not exist and return 404. The repository intentionally does not publish a release from an ordinary branch push.

## Quick start

The Bash installers prompt for any required value that is not supplied. The API key prompt disables terminal echo. This example supplies the exact endpoint as an argument and lets the installer prompt for the key:

```sh
curl -fsSL https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.sh \
  | bash -s -- --endpoint https://api.example.test/anthropic
```

For PowerShell, download the script before running it. The key is still entered interactively and is never placed in the process arguments:

```powershell
$installer = Join-Path $env:TEMP 'claude-code.ps1'
Invoke-WebRequest https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.ps1 -OutFile $installer
& $installer -Endpoint https://api.example.test/anthropic
```

## Common behavior

The shell installers support these common options:

- `--endpoint URL`: the exact API base URL.
- `--key KEY`: the API key. Interactive input or `AI_API_KEY` is safer than placing a key in shell history.
- `--yes` / `-y`: unattended mode. A missing tool is installed; an existing installation is skipped; configuration is still updated.
- `--reinstall`: install or update even when the command already exists.
- `--dry-run`: validate inputs and describe actions without installing or writing configuration.
- `--help`: show installer-specific options.

An interactive run asks whether to reinstall when it finds an existing installation. Choosing no skips the upstream installer but continues configuration. Unattended mode never prompts and fails if a required value is missing.

### Inputs by installer

“Required” means required to configure the tool. Interactive runs prompt for missing required values; unattended runs require the matching option or environment fallback.

| Installer | Required inputs | Optional inputs and defaults | Environment fallbacks |
| --- | --- | --- | --- |
| `claude-code.sh` | endpoint and key: `--endpoint`, `--key` | `--yes`, `--reinstall`, `--dry-run` | `AI_ENDPOINT`, `AI_API_KEY`, `AI_INSTALL_YES=1` |
| `claude-code.ps1` | endpoint and key: `-Endpoint`, `-Key` | `-Yes`, `-Reinstall`, `-DryRun` | `AI_ENDPOINT`, `AI_API_KEY`, `AI_INSTALL_YES=1` |
| `codex.sh` | endpoint and key: `--endpoint`, `--key` | model optional via `--model` (default `gpt-5.4`); provider-id via `--provider-id` (default `custom`) | `AI_ENDPOINT`, `AI_API_KEY`, `AI_INSTALL_YES=1` |
| `hermes.sh` | endpoint, key, and model: `--endpoint`, `--key`, `--model` | provider-id via `--provider-id` (default `custom`) | `AI_ENDPOINT`, `AI_API_KEY`, `AI_MODEL`, `AI_INSTALL_YES=1` |
| `openclaw.sh` | endpoint, key, model, and provider: `--endpoint`, `--key`, `--model`, `--provider` | `--yes`, `--reinstall`, `--dry-run` | `AI_ENDPOINT`, `AI_API_KEY`, `AI_MODEL`, `AI_PROVIDER`, `AI_INSTALL_YES=1` |

PowerShell maps the common Bash controls directly: `--endpoint` to `-Endpoint`, `--key` to `-Key`, `--yes` to `-Yes`, `--reinstall` to `-Reinstall`, and `--dry-run` to `-DryRun`. `-Endpoint`, `-Key`, and `-Yes` have the environment fallbacks shown above; `-Reinstall` and `-DryRun` are explicit switches.

Equivalent environment variables are useful for automation:

| Variable | Meaning |
| --- | --- |
| `AI_ENDPOINT` | Exact API base URL |
| `AI_API_KEY` | API key |
| `AI_MODEL` | Model identifier for installers that require one |
| `AI_PROVIDER` | OpenClaw provider: `anthropic` or `openai` |
| `AI_INSTALL_YES=1` | Enable unattended behavior |

Keep `AI_API_KEY` in a secret store and inject it at runtime. For example, after exporting `AI_API_KEY` from a secret manager:

```sh
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl -fsSL https://github.com/ding-rs/ai-cli-installers/releases/latest/download/codex.sh -o "$installer"
AI_ENDPOINT=https://api.example.test/openai/v1 AI_API_KEY="$AI_API_KEY" AI_INSTALL_YES=1 \
  bash "$installer" --model gpt-5.4
```

PowerShell automation can likewise receive `AI_API_KEY` from the calling secret manager and invoke the downloaded script without passing the secret as a parameter.

## Endpoint semantics

`--endpoint` and `AI_ENDPOINT` are exact base URLs, not a website or account root. The scripts preserve the path while removing trailing `/` characters, and reject embedded credentials, query strings, fragments, backslashes, control characters, and URLs without an `http://` or `https://` authority.

- Claude Code expects an Anthropic-compatible base URL.
- Codex and Hermes expect an OpenAI-compatible base URL, commonly ending in `/v1`.
- OpenClaw interprets the same URL according to `--provider anthropic|openai` (or `AI_PROVIDER`). OpenClaw also requires `--model` or `AI_MODEL`.

Codex accepts `--provider-id` for the local provider identifier. Hermes accepts its own `--provider-id`. These identifiers do not change the endpoint.

## Configuration safety

Before replacing an existing configuration, each installer creates a numbered `.ai-cli-installers.bak` backup and preserves unrelated settings. Writes use temporary files and restrictive permissions where the platform supports them. A failed merge or validation leaves the original configuration in place.

Secrets are masked in installer output. OpenClaw stores the selected provider credential through its supported SecretRef (secret reference) configuration instead of embedding the key in the main configuration. Avoid command-line `--key` in unattended systems because process arguments and shell history can be inspected; prefer `AI_API_KEY` supplied by the calling secret manager.

## OpenClaw example

```sh
installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl -fsSL https://github.com/ding-rs/ai-cli-installers/releases/latest/download/openclaw.sh -o "$installer"
AI_ENDPOINT=https://api.example.test/openai/v1 AI_API_KEY="$AI_API_KEY" \
AI_MODEL=gpt-5.4 AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$installer"
```

The explicit form is `--provider openai --model gpt-5.4`; use `--provider anthropic` for an Anthropic-compatible endpoint.

## Verify a downloaded installer

Every tagged release includes `SHA256SUMS` for exactly the five installer files:

GNU/Linux (`sha256sum`):

```sh
verify_dir=$(mktemp -d)
trap 'rm -rf "$verify_dir"' EXIT
cd "$verify_dir"
curl -fLO https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.sh
curl -fLO https://github.com/ding-rs/ai-cli-installers/releases/latest/download/SHA256SUMS
grep '  claude-code.sh$' SHA256SUMS | sha256sum -c -
```

macOS (`shasum`):

```sh
verify_dir=$(mktemp -d)
trap 'rm -rf "$verify_dir"' EXIT
cd "$verify_dir"
curl -fLO https://github.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code.sh
curl -fLO https://github.com/ding-rs/ai-cli-installers/releases/latest/download/SHA256SUMS
grep '  claude-code.sh$' SHA256SUMS | shasum -a 256 -c -
```

## Development

Run the same primary gate used by CI:

```sh
bash tests/run.sh
bash -n ./*.sh tests/*.sh
shellcheck ./*.sh tests/*.sh
```

## License

MIT
