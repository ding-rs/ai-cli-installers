# Generic AI CLI Installers Design

## Goal

Create a public, brand-neutral installer repository for the five installation entrypoints already used by the website:

- `claude-code.sh`
- `claude-code.ps1`
- `codex.sh`
- `hermes.sh`
- `openclaw.sh`

The scripts install the official tool when it is missing and configure it for a caller-supplied API endpoint and key.

## Scope

This iteration only builds scripts, tests, documentation, CI, and a tag-driven GitHub Release workflow. It does not change zhongzhuan, publish a Release, deploy a website, or build GUI/Relay integration.

## User-facing behavior

All scripts accept an exact endpoint and API key. Shell scripts use `--endpoint` and `--key`; PowerShell accepts named parameters and `AI_ENDPOINT` / `AI_API_KEY` environment fallbacks. Secrets are masked in output.

When a tool is already installed, an interactive run asks whether to reinstall/update it. Choosing skip still continues configuration. `--yes` is unattended mode: it installs a missing tool, skips reinstalling an existing tool, and continues configuration. `--reinstall` forces installation/update in either mode. An unattended run with missing required input fails instead of prompting.

`--dry-run` validates input and reports planned actions without installing software or writing files.

## Endpoint contract

The endpoint is exact, not a brand root:

- Claude Code receives an Anthropic-compatible base URL.
- Codex and Hermes receive an OpenAI-compatible base URL, normally ending in `/v1`.
- OpenClaw receives the base URL matching `--provider anthropic|openai`.

The scripts trim a trailing slash, accept `http://` or `https://`, and reject embedded credentials, queries, fragments, and empty endpoints.

## Official install paths

- Claude Code shell: Anthropic native installer at `https://claude.ai/install.sh`.
- Claude Code PowerShell: Anthropic native installer at `https://claude.ai/install.ps1`.
- Codex: `npm install --global @openai/codex`; when Node/npm is missing on macOS/Linux/WSL, install Node 22 through official nvm.
- Hermes: official `scripts/install.sh --skip-setup`.
- OpenClaw: official `install.sh --no-prompt --no-onboard`, including in interactive wrapper runs so only this wrapper owns configuration prompts.

Every installation path verifies that the expected command is available afterward.

## Configuration safety

Scripts back up an existing configuration before changing it. Claude writes its documented environment variables and merges the onboarding flag. Codex preserves unrelated TOML content while replacing a marked managed block, merges `OPENAI_API_KEY` into `auth.json`, and maintains a marked shell environment block. Hermes backs up its YAML before writing the single custom-provider configuration required by its current schema. OpenClaw merges only the selected provider and default model into its JSON files, preserving unrelated providers and settings.

## Distribution

Git tags named `v*` trigger a Release workflow that first runs tests and linting, then uploads the five fixed-name scripts plus `SHA256SUMS`. Consumers can later use `releases/latest/download/<filename>` without querying the GitHub API.

## Verification

Tests run in isolated temporary homes with fake official installers and fake commands. They prove missing-install, installed-skip, forced-reinstall, exact endpoint configuration, secret masking, backup/merge behavior, dry-run non-mutation, unattended validation, brand-neutral content, and release asset completeness. Shellcheck validates all shell scripts; PowerShell syntax is parsed on GitHub Actions.
