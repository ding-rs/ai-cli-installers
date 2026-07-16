#!/usr/bin/env bash

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
cd "$REPO_ROOT" || exit 1

failures=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

require_file() {
  if [ -f "$1" ]; then
    pass "$1 exists"
  else
    fail "$1 exists"
  fi
}

require_text() {
  file=$1
  pattern=$2
  description=$3
  if [ -f "$file" ] && LC_ALL=C grep -Eq -- "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description"
  fi
}

reject_text() {
  file=$1
  pattern=$2
  description=$3
  if [ -f "$file" ] && LC_ALL=C grep -Eq -- "$pattern" "$file"; then
    fail "$description"
  else
    pass "$description"
  fi
}

printf '%s\n' 'test: public repository files exist'
for file in README.md LICENSE AGENTS.md .gitignore .github/workflows/ci.yml .github/workflows/release.yml; do
  require_file "$file"
done

printf '%s\n' 'test: every release asset has its executable contract'
for file in claude-code.sh claude-code.ps1 codex.sh hermes.sh openclaw.sh; do
  require_file "$file"
done
for file in claude-code.sh codex.sh hermes.sh openclaw.sh; do
  if [ -f "$file" ] && [ "$(sed -n '1p' "$file")" = '#!/usr/bin/env bash' ]; then
    pass "$file has the portable Bash shebang"
  else
    fail "$file has the portable Bash shebang"
  fi
  if [ -x "$file" ]; then
    pass "$file is executable"
  else
    fail "$file is executable"
  fi
done
require_text claude-code.ps1 '^#Requires -Version 5\.1$' 'PowerShell installer declares version 5.1 minimum'
require_text claude-code.ps1 '^\[CmdletBinding\(\)\]$' 'PowerShell installer is an advanced script'
require_text claude-code.ps1 '^param\($' 'PowerShell installer declares parameters'
for parameter in Endpoint Key Yes Reinstall DryRun; do
  require_text claude-code.ps1 "\\[([^]]+\\])?[^[:cntrl:]]*\\\$$parameter|\\[switch\\]\\\$$parameter" "PowerShell installer declares -$parameter"
done

printf '%s\n' 'test: README documents the complete installer contract'
for script in claude-code.sh claude-code.ps1 codex.sh hermes.sh openclaw.sh; do
  require_text README.md "${script//./\\.}" "README lists $script"
  require_text README.md "releases/latest/download/${script//./\\.}" "README gives the latest download URL for $script"
done
for option in --endpoint --key --model --provider --yes --reinstall --dry-run; do
  require_text README.md "(^|[^[:alnum:]_])${option}([^[:alnum:]_]|$)" "README documents $option"
done
for variable in AI_ENDPOINT AI_API_KEY AI_MODEL AI_PROVIDER AI_INSTALL_YES; do
  require_text README.md "$variable" "README documents $variable"
done
require_text README.md 'exact[^[:cntrl:]]*(endpoint|base URL)|(endpoint|base URL)[^[:cntrl:]]*exact' 'README explains exact endpoint semantics'
require_text README.md 'already installed|existing installation|already exists' 'README explains existing-install default behavior'
require_text README.md 'skip' 'README names the default skip behavior'
require_text README.md 'unattended|non-interactive' 'README explains unattended operation'
require_text README.md 'interactive' 'README explains interactive operation'
require_text README.md 'backup' 'README documents configuration backups'
require_text README.md 'SecretRef|secret reference' 'README documents OpenClaw secret references'
require_text README.md 'official installer|upstream installer' 'README documents official installer provenance'
require_text README.md 'first release|initial release' 'README warns about latest URLs before the first release'
require_text README.md 'do not exist|will not exist|unavailable|404' 'README states that pre-release latest URLs are unavailable'
reject_text README.md '--key(=|[[:space:]]+)(sk-|[^[:space:]]*(secret|token)[^[:space:]]*)' 'README does not put an API key literal on a command line'
for parameter in Endpoint Key Yes Reinstall DryRun; do
  require_text README.md "(^|[^[:alnum:]_])-$parameter([^[:alnum:]_]|$)" "README maps the PowerShell -$parameter parameter"
done
require_text README.md '\| [^|]*claude-code\.sh[^[:cntrl:]]*endpoint[^[:cntrl:]]*key[^[:cntrl:]]*AI_ENDPOINT[^[:cntrl:]]*AI_API_KEY' 'README lists Claude Bash required inputs and fallbacks'
require_text README.md '\| [^|]*claude-code\.ps1[^[:cntrl:]]*endpoint[^[:cntrl:]]*key[^[:cntrl:]]*AI_ENDPOINT[^[:cntrl:]]*AI_API_KEY' 'README lists Claude PowerShell required inputs and fallbacks'
require_text README.md '\| [^|]*codex\.sh[^[:cntrl:]]*endpoint[^[:cntrl:]]*key[^[:cntrl:]]*model[^[:cntrl:]]*default[^[:cntrl:]]*provider-id' 'README lists Codex inputs, model default, and provider id'
require_text README.md '\| [^|]*hermes\.sh[^[:cntrl:]]*endpoint[^[:cntrl:]]*key[^[:cntrl:]]*model[^[:cntrl:]]*provider-id[^[:cntrl:]]*AI_MODEL' 'README lists Hermes required inputs, provider id, and fallbacks'
require_text README.md '\| [^|]*openclaw\.sh[^[:cntrl:]]*endpoint[^[:cntrl:]]*key[^[:cntrl:]]*model[^[:cntrl:]]*provider[^[:cntrl:]]*AI_PROVIDER' 'README lists OpenClaw required inputs and fallbacks'
require_text README.md 'curl -fLO https://github\.com/ding-rs/ai-cli-installers/releases/latest/download/claude-code\.sh' 'checksum example downloads the asset being verified'
require_text README.md "grep '  claude-code\\.sh\\$' SHA256SUMS \| sha256sum -c -" 'README gives a GNU sha256sum single-asset verification command'
require_text README.md "grep '  claude-code\\.sh\\$' SHA256SUMS \| shasum -a 256 -c -" 'README gives a macOS shasum single-asset verification command'

printf '%s\n' 'test: CI runs all platform gates on branch pushes and pull requests'
CI=.github/workflows/ci.yml
require_text "$CI" '^on:' 'CI declares triggers'
require_text "$CI" '^[[:space:]]+push:' 'CI runs on pushes'
require_text "$CI" '^[[:space:]]+pull_request:' 'CI runs on pull requests'
require_text "$CI" '^[[:space:]]+contents:[[:space:]]+read([[:space:]]*#.*)?$' 'CI uses read-only repository permissions'
require_text "$CI" 'actions/checkout@v6' 'CI uses actions/checkout v6'
require_text "$CI" 'runs-on:[[:space:]]+ubuntu-latest' 'CI has an Ubuntu job'
require_text "$CI" 'bash tests/run\.sh' 'CI runs the full Bash test harness'
require_text "$CI" 'bash -n \./\*\.sh tests/\*\.sh' 'CI parses all Bash scripts'
require_text "$CI" 'shellcheck \./\*\.sh tests/\*\.sh' 'CI runs ShellCheck'
require_text "$CI" 'runs-on:[[:space:]]+macos-latest' 'CI has a macOS Bash 3.2 job'
require_text "$CI" 'bash --version' 'CI records the macOS Bash version'
require_text "$CI" 'pwsh -NoLogo -NoProfile -NonInteractive -File tests/test_claude_code\.ps1' 'CI runs PowerShell 7 behavior tests'
require_text "$CI" 'runs-on:[[:space:]]+windows-latest' 'CI has a Windows job'
require_text "$CI" 'powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/test_claude_code\.ps1' 'CI runs Windows PowerShell 5.1 behavior and parser tests'

printf '%s\n' 'test: release workflow is tag-only and gated'
RELEASE=.github/workflows/release.yml
require_text "$RELEASE" '^on:' 'release workflow declares triggers'
require_text "$RELEASE" '^[[:space:]]+push:' 'release workflow uses a push trigger'
require_text "$RELEASE" "tags:[[:space:]]*\['v\*'\]" 'release workflow accepts v* tags'
reject_text "$RELEASE" 'workflow_dispatch|pull_request|branches:' 'release workflow has no manual, PR, or branch trigger'
require_text "$RELEASE" '^[[:space:]]+contents:[[:space:]]+read([[:space:]]*#.*)?$' 'release verification has read-only default permissions'
require_text "$RELEASE" '^[[:space:]]{6}contents:[[:space:]]+write([[:space:]]*#.*)?$' 'only the release job requests write permission'
require_text "$RELEASE" 'actions/checkout@v6' 'release workflow uses actions/checkout v6'
require_text "$RELEASE" '^[[:space:]]{2}verify:' 'release workflow has a verify job'
require_text "$RELEASE" 'bash tests/run\.sh' 'release verification runs the full test harness'
require_text "$RELEASE" 'bash -n \./\*\.sh tests/\*\.sh' 'release verification parses Bash scripts'
require_text "$RELEASE" 'shellcheck \./\*\.sh tests/\*\.sh' 'release verification runs ShellCheck'
require_text "$RELEASE" '^[[:space:]]+needs:[[:space:]]+verify([[:space:]]*#.*)?$' 'release creation depends on verification'
require_text "$RELEASE" 'sha256sum "\$\{assets\[@\]\}" > SHA256SUMS' 'release workflow generates checksums for the asset array'
# The workflow expression is intentionally a literal contract.
# shellcheck disable=SC2016
require_text "$RELEASE" 'gh release create "\$GITHUB_REF_NAME" "\$\{assets\[@\]\}" SHA256SUMS' 'release command uploads only the asset array and checksums'

expected_assets=$(printf '%s\n' claude-code.sh claude-code.ps1 codex.sh hermes.sh openclaw.sh)
actual_assets=''
if [ -f "$RELEASE" ]; then
  actual_assets=$(awk '
    /assets=\(/ { capture=1; next }
    capture && /^[[:space:]]*\)/ { capture=0; exit }
    capture {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (length($0)) print
    }
  ' "$RELEASE")
fi
if [ "$actual_assets" = "$expected_assets" ]; then
  pass 'release asset list is exact and fixed'
else
  fail 'release asset list is exact and fixed'
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_assets" "$actual_assets" >&2
fi

printf '%s\n' 'test: public repository hygiene'
require_text AGENTS.md '\.\./memory/MEMORY\.md' 'AGENTS.md conditionally references the sibling maintainer memory'
require_text AGENTS.md 'standalone clone' 'AGENTS.md explains that standalone clones do not require sibling memory'
machine_path_markers=$(printf '%s|%s' 'Code''Projects' '/Use''rs/')
reject_text AGENTS.md "$machine_path_markers" 'AGENTS.md has no machine-specific path'
out_of_scope_markers=$(printf '%s|%s|%s' 'G''UI' 'Re''lay' 'website ''deployment')
reject_text README.md "$out_of_scope_markers" 'README stays within installer scope'

forbidden_placeholders=$(printf '%s|%s|%s|%s' 'SITE_''NAME' 'SITE_''DOMAIN' 'AI_''HOST' 'PROVIDER_ID_''PREFIX')
public_files='README.md AGENTS.md claude-code.sh claude-code.ps1 codex.sh hermes.sh openclaw.sh .github/workflows/ci.yml .github/workflows/release.yml'
for file in $public_files; do
  [ -f "$file" ] || continue
  case $file in
    *.md|*.sh|*.ps1|*.yml|*.yaml|*.json|*.toml)
      if LC_ALL=C grep -Eq "$forbidden_placeholders" "$file"; then
        fail "$file contains an unresolved branding placeholder"
      fi
      ;;
  esac
done

if command -v python3 >/dev/null 2>&1; then
  if ! python3 - <<'PY'
import pathlib
import re
import subprocess
import sys

allowed_exact = {
    "127.0.0.1",
    "[2001:db8::1]",
    "claude.ai",
    "github.com",
    "hermes-agent.nousresearch.com",
    "openclaw.ai",
    "raw.githubusercontent.com",
}
bad = []
tracked_files = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
    text=True,
).splitlines()
for name in tracked_files:
    path = pathlib.Path(name)
    if not path.is_file() or path.suffix.lower() not in {".md", ".sh", ".ps1", ".yml", ".yaml"}:
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(r"https?://(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+\.[A-Za-z]{2,})", text):
        host = match.group(0).split("://", 1)[1].lower()
        if host in allowed_exact or host.endswith(".example.test") or host == "example.test":
            continue
        bad.append(f"{name}: unexpected URL host {host}")
if bad:
    print("\n".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    fail 'tracked URL hosts are official or reserved examples'
  else
    pass 'tracked URL hosts are official or reserved examples'
  fi
else
  printf '%s\n' 'skip - URL host hygiene (python3 unavailable)'
fi

if [ "$failures" -ne 0 ]; then
  printf 'repository contract failures: %s\n' "$failures" >&2
  exit 1
fi

printf '%s\n' 'repository contract tests passed'
