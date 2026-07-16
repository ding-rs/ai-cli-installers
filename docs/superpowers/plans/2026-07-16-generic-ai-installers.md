# Generic AI CLI Installers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify five brand-neutral, one-click installer/configuration scripts for Claude Code, Codex, Hermes, and OpenClaw.

**Architecture:** Each downloadable script is standalone so `curl | bash` and `irm | iex` remain possible. A dependency-free Bash test harness runs scripts in isolated homes with fake official installers; CI adds ShellCheck and PowerShell parsing. A tag-only workflow publishes fixed asset names and checksums after verification.

**Tech Stack:** Bash 3.2+, PowerShell 5.1+, Node.js for safe JSON merging where the installed tool already requires it, GitHub Actions, ShellCheck.

---

## File map

- `claude-code.sh`: macOS/Linux/WSL Claude native install and environment configuration.
- `claude-code.ps1`: Windows Claude native install and user environment configuration.
- `codex.sh`: macOS/Linux/WSL Node bootstrap, Codex npm install, TOML/JSON configuration.
- `hermes.sh`: official Hermes install and YAML configuration.
- `openclaw.sh`: official unattended OpenClaw install and merged JSON configuration.
- `tests/testlib.sh`: isolated HOME/fake command/assertion helpers.
- `tests/test_claude_code.sh`: Claude shell behavior and PowerShell static contract tests.
- `tests/test_codex.sh`: Codex install/configuration behavior.
- `tests/test_hermes.sh`: Hermes install/configuration behavior.
- `tests/test_openclaw.sh`: OpenClaw install/configuration behavior.
- `tests/test_repository.sh`: brand-neutral and Release asset contract checks.
- `tests/run.sh`: deterministic test discovery and summary.
- `.github/workflows/ci.yml`: tests, ShellCheck, and PowerShell parser gate.
- `.github/workflows/release.yml`: tag-triggered verified Release upload.
- `README.md`, `LICENSE`, `AGENTS.md`: usage, licensing, and local contributor instructions.

### Task 1: Repository test harness

**Files:**
- Create: `tests/testlib.sh`
- Create: `tests/run.sh`
- Create: `tests/test_testlib.sh`
- Create: `AGENTS.md`

- [ ] **Step 1: Write the failing harness self-test**

Create `tests/test_testlib.sh` that sources `tests/testlib.sh`, creates an isolated home, installs a fake executable, and verifies `assert_file_contains`, `assert_file_not_contains`, `assert_eq`, and `assert_not_exists`. It must fail initially because `tests/testlib.sh` does not exist.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_testlib.sh`

Expected: non-zero with a missing `tests/testlib.sh` error.

- [ ] **Step 3: Implement the minimal harness**

`tests/testlib.sh` must expose `new_sandbox`, `cleanup_sandbox`, `make_fake_command`, `run_capture`, the four assertions above, and a failure counter. `tests/run.sh` must execute `tests/test_*.sh` in lexical order and return non-zero when any test script fails. All temporary state must live below the platform temporary directory and be removed by traps.

`AGENTS.md` must point local agents to `../memory/MEMORY.md`, state that this repository is public and brand-neutral, and list `bash tests/run.sh` as the primary gate.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test_testlib.sh && bash tests/run.sh`

Expected: both commands exit 0 and report the harness self-test passed.

- [ ] **Step 5: Controller review and commit**

Inspect `git diff`, run `bash -n tests/*.sh`, then commit as `test: add installer test harness`.

### Task 2: Claude Code shell and PowerShell installers

**Files:**
- Create: `tests/test_claude_code.sh`
- Create: `claude-code.sh`
- Create: `claude-code.ps1`

- [ ] **Step 1: Write failing Claude tests**

Cover these behaviors with isolated homes and fake `claude`/`curl` commands:

- a missing command invokes the official native installer and then writes `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`;
- an existing command plus `--yes` skips installer invocation but still updates configuration;
- `--reinstall --yes` invokes the installer for an existing command;
- `--dry-run` writes no files and invokes no installer;
- unattended missing endpoint or key exits non-zero;
- output never contains the full API key;
- the PowerShell file contains a named parameter block, environment fallbacks, official `install.ps1`, installed-skip logic, and user-scoped environment writes.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_claude_code.sh`

Expected: non-zero because both installer files are absent.

- [ ] **Step 3: Implement the standalone installers**

`claude-code.sh` must support `--endpoint`, `--key`, `--yes|-y`, `--reinstall`, `--dry-run`, and `--help`; environment fallbacks are `AI_ENDPOINT`, `AI_API_KEY`, and `AI_INSTALL_YES=1`. It uses `https://claude.ai/install.sh`, verifies `claude --version`, updates marked shell-rc blocks without duplicating them, backs up and merges `~/.claude.json`, and continues configuration after a skipped reinstall.

`claude-code.ps1` provides equivalent `-Endpoint`, `-Key`, `-Yes`, `-Reinstall`, and `-DryRun` parameters plus the same environment fallbacks. It invokes `https://claude.ai/install.ps1`, verifies `claude`, writes user-scoped environment variables, and merges the onboarding flag without discarding valid unrelated JSON fields.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test_claude_code.sh && bash -n claude-code.sh && shellcheck claude-code.sh`

Expected: all exit 0.

- [ ] **Step 5: Controller review and commit**

Inspect endpoint validation, secret masking, skip/reinstall branches, and config backups; commit as `feat: add generic Claude Code installers`.

### Task 3: Codex installer

**Files:**
- Create: `tests/test_codex.sh`
- Create: `codex.sh`

- [ ] **Step 1: Write failing Codex tests**

Cover missing installation through a fake `npm`, existing-command skip under `--yes`, forced reinstall, dry-run non-mutation, required unattended inputs, exact endpoint/model/provider values, preservation of unrelated TOML and auth JSON fields, backup creation, idempotent managed blocks, and full-key absence from output.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_codex.sh`

Expected: non-zero because `codex.sh` is absent.

- [ ] **Step 3: Implement `codex.sh`**

Support the common flags plus `--model` (default `gpt-5.4`) and `--provider-id` (default `custom`). Validate provider IDs as lowercase letters, digits, `_`, or `-`. Use `npm install --global @openai/codex`; if Node/npm is absent, bootstrap Node 22 using official nvm `v0.40.3` before installation. Verify `codex --version`.

Write a replaceable `# >>> ai-cli-installers codex >>>` block in `~/.codex/config.toml`, removing conflicting top-level `model`/`model_provider` keys and the previously managed block while preserving unrelated sections. Merge `OPENAI_API_KEY` into `~/.codex/auth.json`, maintain a marked `OPENAI_API_KEY` shell-rc block, set restrictive permissions, and make backups before changing existing files.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test_codex.sh && bash -n codex.sh && shellcheck codex.sh`

Expected: all exit 0.

- [ ] **Step 5: Controller review and commit**

Inspect the TOML block replacement against fixtures and confirm repeated execution is stable; commit as `feat: add generic Codex installer`.

### Task 4: Hermes installer

**Files:**
- Create: `tests/test_hermes.sh`
- Create: `hermes.sh`

- [ ] **Step 1: Write failing Hermes tests**

Cover missing installation through the official installer with `--skip-setup`, installed-command skip under `--yes`, forced reinstall, dry-run non-mutation, required unattended endpoint/key/model, custom provider/model YAML output, backup creation, restrictive permissions, and secret masking.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_hermes.sh`

Expected: non-zero because `hermes.sh` is absent.

- [ ] **Step 3: Implement `hermes.sh`**

Support the common flags plus required `--model` and optional `--provider-id` (default `custom`). Invoke `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh` with `--skip-setup`, verify `hermes --version`, back up an existing `~/.hermes/config.yaml`, then write the current `custom_providers` schema with the exact endpoint/key/model and `platform_toolsets.cli` core set. Set the file mode to 600 where supported.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test_hermes.sh && bash -n hermes.sh && shellcheck hermes.sh`

Expected: all exit 0.

- [ ] **Step 5: Controller review and commit**

Inspect installer flags and YAML quoting for endpoint, key, model, and provider values; commit as `feat: add generic Hermes installer`.

### Task 5: OpenClaw installer

**Files:**
- Create: `tests/test_openclaw.sh`
- Create: `openclaw.sh`

- [ ] **Step 1: Write failing OpenClaw tests**

Cover missing installation with official `--no-prompt --no-onboard`, installed-command skip under `--yes`, forced reinstall, dry-run non-mutation, unattended provider/model validation, Anthropic and OpenAI provider rendering, preservation of unrelated JSON providers/settings, auth-profile merge, backups, restrictive permissions, and secret masking.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_openclaw.sh`

Expected: non-zero because `openclaw.sh` is absent.

- [ ] **Step 3: Implement `openclaw.sh`**

Support the common flags plus required `--provider anthropic|openai` and `--model`. Invoke `https://openclaw.ai/install.sh` with `--no-prompt --no-onboard`, verify `openclaw --version`, and use Node to merge `~/.openclaw/openclaw.json` plus `~/.openclaw/agents/main/agent/auth-profiles.json`. Preserve unrelated providers/settings, set `models.mode = "merge"`, select `<provider>/<model>` as the primary model, set `api = "openai-responses"` only for OpenAI, and remove the selected provider's obsolete default auth profile. Back up both files before mutation.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test_openclaw.sh && bash -n openclaw.sh && shellcheck openclaw.sh`

Expected: all exit 0.

- [ ] **Step 5: Controller review and commit**

Inspect both provider branches and JSON merge fixtures; commit as `feat: add generic OpenClaw installer`.

### Task 6: Repository, CI, and Release contract

**Files:**
- Create: `tests/test_repository.sh`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `README.md`
- Create: `LICENSE`

- [ ] **Step 1: Write the failing repository contract test**

Assert the five fixed assets exist, have expected shebangs/extensions, contain no known brand/domain placeholders (`aitongdao`, `tokencat`, `aiwanai`, `SITE_NAME`, `SITE_DOMAIN`, `AI_HOST`, `PROVIDER_ID_PREFIX`), README examples use `--endpoint`, CI names every validation gate, and Release uploads exactly the five assets plus `SHA256SUMS` only after CI succeeds.

- [ ] **Step 2: Verify RED**

Run: `bash tests/test_repository.sh`

Expected: non-zero because workflows, README, and LICENSE are absent.

- [ ] **Step 3: Implement repository files**

README documents interactive, unattended, reinstall, dry-run, endpoint semantics, environment fallbacks, exact official installer provenance, and `releases/latest/download` URLs. CI runs `bash tests/run.sh`, `bash -n`, ShellCheck, and `pwsh` parser validation. Release triggers only on `v*` tags, depends on the full validation job, generates `SHA256SUMS`, and publishes with `gh release create` using `GITHUB_TOKEN`; it must never run on ordinary branch pushes.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/run.sh && bash -n ./*.sh tests/*.sh && shellcheck ./*.sh tests/*.sh && git diff --check`

Expected: all exit 0 with every test script passing.

- [ ] **Step 5: Self-review and commit**

Compare every design requirement to a test or documented behavior, scan the repository for full secret fixtures and brand terms, and commit as `docs: add installer distribution workflow`.

### Task 7: Final independent verification

**Files:**
- Modify only files required to fix verified defects.

- [ ] **Step 1: Run complete local gates**

Run without output-filtering pipelines:

```bash
bash tests/run.sh
bash -n ./*.sh tests/*.sh
shellcheck ./*.sh tests/*.sh
git diff --check main...HEAD
git status --short
```

Expected: zero failures, zero ShellCheck findings, clean diff check, and no untracked implementation files.

- [ ] **Step 2: Perform mutation checks**

Temporarily change one installed-tool fake to missing and confirm its skip test fails; restore with an exact reverse patch and rerun. Temporarily remove OpenClaw's `--no-prompt` argument and confirm its install test fails; restore with an exact reverse patch and rerun.

- [ ] **Step 3: Independent final review**

Review actual files against the design, grep for every required command/flag/config field, and confirm no website, GUI, Relay, or deployment files were added.

- [ ] **Step 4: Prepare handoff without publishing**

Record the feature branch SHA, local verification evidence, GitHub repository creation/push steps, and the later tag command that would publish the first Release. Do not create a tag or Release in this task.

