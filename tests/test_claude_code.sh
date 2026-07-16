#!/usr/bin/env bash
# shellcheck disable=SC2016

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
SCRIPT=$REPO_DIR/claude-code.sh

# shellcheck source=tests/testlib.sh
. "$TEST_DIR/testlib.sh"

ENDPOINT='https://api.example.test/anthropic'
API_KEY='sk-ant-full-secret-value-for-tests'

shell_rc_path() {
  case $(uname -s 2>/dev/null || printf 'unknown\n') in
    Darwin) printf '%s/.zshrc\n' "$HOME" ;;
    *) printf '%s/.bashrc\n' "$HOME" ;;
  esac
}

setup_fake_installer() {
  new_sandbox
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH

  FAKE_CURL_LOG=$SANDBOX/curl.log
  FAKE_INSTALL_LOG=$SANDBOX/install.log
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_INSTALL_LOG"
  export FAKE_CURL_LOG FAKE_INSTALL_LOG

  make_fake_command installed-claude '#!/bin/sh
if [ "${1-}" = "--version" ]; then
  printf "Claude fake 1.0\n"
  exit 0
fi
exit 0'

  make_fake_command curl '#!/bin/sh
printf "%s\n" "$*" >>"$FAKE_CURL_LOG"
printf "%s\n" \
  "#!/bin/sh" \
  "printf \"installer-ran\\n\" >>\"\$FAKE_INSTALL_LOG\"" \
  "cp \"\$FAKE_BIN/installed-claude\" \"\$FAKE_BIN/claude\"" \
  "chmod +x \"\$FAKE_BIN/claude\""'
}

assert_success() {
  assert_eq '0' "$RUN_STATUS" "$1"
}

assert_failure() {
  if [ "$RUN_STATUS" -eq 0 ]; then
    _test_failure "$1"
  fi
}

assert_output_masks_key() {
  case $RUN_OUTPUT in
    *"$API_KEY"*) _test_failure "$1" ;;
  esac
}

assert_files_equal() {
  if ! cmp -s "$1" "$2"; then
    _test_failure "$3"
  fi
}

assert_symlink_points_to() {
  if [ ! -L "$1" ]; then
    _test_failure "$3"
  else
    assert_eq "$2" "$(readlink "$1")" "$3"
  fi
}

printf '%s\n' 'test: missing command invokes official installer and writes configuration'
setup_fake_installer
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$ENDPOINT/" --key "$API_KEY"
assert_success 'missing command installation succeeds'
assert_file_contains "$FAKE_CURL_LOG" '-fsSL https://claude.ai/install.sh' 'official installer URL is fetched'
assert_file_contains "$FAKE_INSTALL_LOG" 'installer-ran' 'downloaded installer body is executed'
RC_FILE=$(shell_rc_path)
assert_file_contains "$RC_FILE" "export ANTHROPIC_BASE_URL='$ENDPOINT'" 'exact endpoint is written without its trailing slash'
assert_file_contains "$RC_FILE" "export ANTHROPIC_AUTH_TOKEN='$API_KEY'" 'API key is written to the managed environment block'
assert_file_contains "$HOME/.claude.json" '"hasCompletedOnboarding": true' 'onboarding is enabled'
assert_output_masks_key 'successful install output masks the full API key'

printf '%s\n' 'test: existing command plus --yes skips installer but still configures'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
run_capture env AI_ENDPOINT="$ENDPOINT/" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 bash "$SCRIPT"
assert_success 'existing command unattended configuration succeeds'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'existing command is not reinstalled under --yes'
assert_file_contains "$(shell_rc_path)" "export ANTHROPIC_BASE_URL='$ENDPOINT'" 'skipped reinstall still configures the endpoint'
assert_file_contains "$HOME/.claude.json" '"hasCompletedOnboarding": true' 'skipped reinstall still configures onboarding'
assert_output_masks_key 'existing-command output masks the full API key'

printf '%s\n' 'test: --reinstall --yes invokes installer for existing command'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --reinstall --yes
assert_success 'forced reinstall succeeds'
assert_file_contains "$FAKE_INSTALL_LOG" 'installer-ran' 'forced reinstall executes the official installer'
assert_output_masks_key 'forced reinstall output masks the full API key'

printf '%s\n' 'test: dry-run neither mutates HOME nor invokes installer'
setup_fake_installer
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT/" --key "$API_KEY" --dry-run --yes
assert_success 'dry-run succeeds with valid unattended input'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'dry-run does not fetch the installer'
assert_eq '0' "$(wc -c <"$FAKE_INSTALL_LOG" | tr -d ' ')" 'dry-run does not execute the installer'
assert_not_exists "$(shell_rc_path)" 'dry-run does not create a shell rc file'
assert_not_exists "$HOME/.claude.json" 'dry-run does not create Claude configuration'
assert_output_masks_key 'dry-run output masks the full API key'

printf '%s\n' 'test: unattended mode rejects missing endpoint or key'
setup_fake_installer
run_capture env -u AI_ENDPOINT -u AI_API_KEY AI_INSTALL_YES=1 bash "$SCRIPT" --key "$API_KEY"
assert_failure 'unattended mode fails when endpoint is missing'
assert_output_masks_key 'missing-endpoint output masks the full API key'
setup_fake_installer
run_capture env -u AI_ENDPOINT -u AI_API_KEY bash "$SCRIPT" --endpoint "$ENDPOINT" --yes
assert_failure 'unattended mode fails when API key is missing'

printf '%s\n' 'test: full key is absent from all user-facing output'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" -y
assert_success '-y alias succeeds'
assert_output_masks_key 'configuration output does not reveal the full API key'

printf '%s\n' 'test: unmatched managed start marker fails without changing shell rc content'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
RC_FILE=$(shell_rc_path)
printf '%s\n' \
  'export BEFORE_MARKER=keep' \
  '# >>> ai-cli-installers >>>' \
  'export AFTER_MARKER=keep' >"$RC_FILE"
cp "$RC_FILE" "$SANDBOX/original-rc"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'unmatched managed start marker causes a safe failure'
assert_files_equal "$SANDBOX/original-rc" "$RC_FILE" 'unmatched managed start marker leaves the shell rc byte-for-byte unchanged'
assert_output_masks_key 'unmatched-marker failure output masks the full API key'

assert_invalid_marker_layout() {
  local layout_name layout_content
  layout_name=$1
  layout_content=$2
  setup_fake_installer
  cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
  RC_FILE=$(shell_rc_path)
  printf '%s\n' "$layout_content" >"$RC_FILE"
  cp "$RC_FILE" "$SANDBOX/original-rc"
  run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
  assert_failure "$layout_name managed marker layout causes a safe failure"
  assert_files_equal "$SANDBOX/original-rc" "$RC_FILE" "$layout_name managed marker layout leaves the shell rc byte-for-byte unchanged"
}

printf '%s\n' 'test: malformed managed marker layouts fail without changing shell rc content'
assert_invalid_marker_layout 'unmatched end' 'export BEFORE=keep
# <<< ai-cli-installers <<<
export AFTER=keep'
assert_invalid_marker_layout 'reversed' 'export BEFORE=keep
# <<< ai-cli-installers <<<
# >>> ai-cli-installers >>>
export AFTER=keep'
assert_invalid_marker_layout 'nested' 'export BEFORE=keep
# >>> ai-cli-installers >>>
# >>> ai-cli-installers >>>
export INSIDE=keep
# <<< ai-cli-installers <<<
# <<< ai-cli-installers <<<
export AFTER=keep'
assert_invalid_marker_layout 'duplicate' 'export BEFORE=keep
# >>> ai-cli-installers >>>
export FIRST=managed
# <<< ai-cli-installers <<<
export MIDDLE=keep
# >>> ai-cli-installers >>>
export SECOND=managed
# <<< ai-cli-installers <<<
export AFTER=keep'

printf '%s\n' 'test: repeat run keeps one managed block and preserves unrelated JSON'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
printf '%s\n' '{"theme":"dark","nested":{"keep":7},"hasCompletedOnboarding":false}' >"$HOME/.claude.json"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'first merge succeeds'
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'second merge succeeds'
RC_FILE=$(shell_rc_path)
assert_eq '1' "$(grep -c '^# >>> ai-cli-installers >>>$' "$RC_FILE")" 'repeat run leaves one managed block'
assert_eq '1' "$(grep -c '^export ANTHROPIC_AUTH_TOKEN=' "$RC_FILE")" 'repeat run leaves one managed token assignment'
assert_file_contains "$HOME/.claude.json" '"theme": "dark"' 'JSON merge preserves an unrelated scalar field'
assert_file_contains "$HOME/.claude.json" '"keep": 7' 'JSON merge preserves an unrelated nested field'
assert_file_contains "$HOME/.claude.json" '"hasCompletedOnboarding": true' 'JSON merge updates onboarding'
assert_file_contains "$HOME/.claude.json.ai-cli-installers.bak" '"theme":"dark"' 'existing JSON is backed up before its first change'

printf '%s\n' 'test: relative config symlinks are preserved while their targets are updated'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
mkdir -p "$HOME/dotfiles"
RC_FILE=$(shell_rc_path)
RC_NAME=${RC_FILE##*/}
RC_LINK_TARGET="dotfiles/$RC_NAME"
printf '%s\n' 'export UNRELATED_RC=keep' >"$HOME/$RC_LINK_TARGET"
ln -s "$RC_LINK_TARGET" "$RC_FILE"
printf '%s\n' '{"theme":"symlinked","nested":{"keep":9}}' >"$HOME/dotfiles/claude.json"
ln -s 'dotfiles/claude.json' "$HOME/.claude.json"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'relative config symlink update succeeds'
assert_symlink_points_to "$RC_FILE" "$RC_LINK_TARGET" 'shell rc remains the original relative symlink'
assert_symlink_points_to "$HOME/.claude.json" 'dotfiles/claude.json' 'Claude JSON remains the original relative symlink'
assert_file_contains "$HOME/$RC_LINK_TARGET" 'export UNRELATED_RC=keep' 'symlinked shell rc target preserves unrelated content'
assert_file_contains "$HOME/$RC_LINK_TARGET" "export ANTHROPIC_BASE_URL='$ENDPOINT'" 'symlinked shell rc target receives the managed block'
assert_file_contains "$HOME/dotfiles/claude.json" '"theme": "symlinked"' 'symlinked JSON target preserves unrelated content'
assert_file_contains "$HOME/dotfiles/claude.json" '"hasCompletedOnboarding": true' 'symlinked JSON target receives onboarding configuration'
assert_file_contains "$HOME/.claude.json.ai-cli-installers.bak" '"theme":"symlinked"' 'symlinked JSON content is backed up before changing its target'

printf '%s\n' 'test: broken and cyclic JSON symlinks fail without replacing the link'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
mkdir -p "$HOME/dotfiles"
ln -s 'dotfiles/missing-claude.json' "$HOME/.claude.json"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'broken Claude JSON symlink causes a safe failure'
assert_symlink_points_to "$HOME/.claude.json" 'dotfiles/missing-claude.json' 'broken Claude JSON symlink is not replaced'
assert_not_exists "$HOME/dotfiles/missing-claude.json" 'broken Claude JSON symlink target is not created'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
mkdir -p "$HOME/dotfiles"
ln -s 'dotfiles/claude-cycle' "$HOME/.claude.json"
ln -s '../.claude.json' "$HOME/dotfiles/claude-cycle"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'cyclic Claude JSON symlink causes a safe failure'
assert_symlink_points_to "$HOME/.claude.json" 'dotfiles/claude-cycle' 'cyclic Claude JSON symlink is not replaced'
assert_symlink_points_to "$HOME/dotfiles/claude-cycle" '../.claude.json' 'cyclic Claude JSON link partner is not replaced'

printf '%s\n' 'test: broken and cyclic shell rc symlinks fail without replacing the link'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
mkdir -p "$HOME/dotfiles"
RC_FILE=$(shell_rc_path)
ln -s 'dotfiles/missing-shell-rc' "$RC_FILE"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'broken shell rc symlink causes a safe failure'
assert_symlink_points_to "$RC_FILE" 'dotfiles/missing-shell-rc' 'broken shell rc symlink is not replaced'
assert_not_exists "$HOME/dotfiles/missing-shell-rc" 'broken shell rc symlink target is not created'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
mkdir -p "$HOME/dotfiles"
RC_FILE=$(shell_rc_path)
RC_NAME=${RC_FILE##*/}
ln -s 'dotfiles/shell-rc-cycle' "$RC_FILE"
ln -s "../$RC_NAME" "$HOME/dotfiles/shell-rc-cycle"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'cyclic shell rc symlink causes a safe failure'
assert_symlink_points_to "$RC_FILE" 'dotfiles/shell-rc-cycle' 'cyclic shell rc symlink is not replaced'
assert_symlink_points_to "$HOME/dotfiles/shell-rc-cycle" "../$RC_NAME" 'cyclic shell rc link partner is not replaced'

printf '%s\n' 'test: malformed JSON is backed up and left unchanged'
setup_fake_installer
cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
MALFORMED_JSON='{"keep":true,'
printf '%s\n' "$MALFORMED_JSON" >"$HOME/.claude.json"
run_capture bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'malformed existing JSON causes a failure'
assert_eq "$MALFORMED_JSON" "$(cat "$HOME/.claude.json")" 'malformed JSON is not overwritten'
assert_eq "$MALFORMED_JSON" "$(cat "$HOME/.claude.json.ai-cli-installers.bak")" 'malformed JSON is backed up before failure'
assert_output_masks_key 'malformed-JSON failure output masks the full API key'

printf '%s\n' 'test: endpoint validation accepts host ports and bracketed IPv6'
for VALID_ENDPOINT in \
  'http://127.0.0.1:8080/v1' \
  'https://[2001:db8::1]:8443/v1'
do
  setup_fake_installer
  cp "$FAKE_BIN/installed-claude" "$FAKE_BIN/claude"
  run_capture bash "$SCRIPT" --endpoint "$VALID_ENDPOINT/" --key "$API_KEY" --yes
  assert_success "endpoint with an explicit port is accepted: $VALID_ENDPOINT"
  assert_file_contains "$(shell_rc_path)" "export ANTHROPIC_BASE_URL='$VALID_ENDPOINT'" "exact endpoint with port is configured: $VALID_ENDPOINT"
  assert_output_masks_key "valid port endpoint output masks the full API key: $VALID_ENDPOINT"
done

printf '%s\n' 'test: endpoint validation rejects unsafe or inexact URLs'
for INVALID_ENDPOINT in \
  'ftp://api.example.test/v1' \
  'https://user@example.test/v1' \
  'http://:8080/v1' \
  'https://[]:8443/v1' \
  'http://2001:db8::1/v1' \
  'https://example.test:/v1' \
  'https://example.test:abc/v1' \
  'https://api.example.test/v1?mode=test' \
  'https://api.example.test/v1#fragment' \
  'https://api.example.test/v 1' \
  'https://api.example.test\evil/v1' \
  'https:///missing-host'
do
  setup_fake_installer
  run_capture bash "$SCRIPT" --endpoint "$INVALID_ENDPOINT" --key "$API_KEY" --yes
  assert_failure "invalid endpoint is rejected: $INVALID_ENDPOINT"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "invalid endpoint does not invoke installer: $INVALID_ENDPOINT"
  assert_output_masks_key "invalid endpoint output masks the full API key: $INVALID_ENDPOINT"
done

printf '%s\n' 'test: --help is side-effect free'
setup_fake_installer
run_capture bash "$SCRIPT" --help
assert_success '--help succeeds without required inputs'
assert_not_exists "$(shell_rc_path)" '--help does not create a shell rc file'
assert_not_exists "$HOME/.claude.json" '--help does not create Claude configuration'

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'ok - claude-code shell installer'

POWERSHELL_SCRIPT=$REPO_DIR/claude-code.ps1

printf '%s\n' 'test: PowerShell installer exposes the standalone named parameter contract'
assert_file_contains "$POWERSHELL_SCRIPT" '[CmdletBinding()]' 'PowerShell installer has an advanced-script binding declaration'
assert_file_contains "$POWERSHELL_SCRIPT" 'param(' 'PowerShell installer has a named parameter block'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]$Endpoint' 'PowerShell installer accepts -Endpoint'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]$Key' 'PowerShell installer accepts -Key'
assert_file_contains "$POWERSHELL_SCRIPT" '[switch]$Yes' 'PowerShell installer accepts -Yes'
assert_file_contains "$POWERSHELL_SCRIPT" '[switch]$Reinstall' 'PowerShell installer accepts -Reinstall'
assert_file_contains "$POWERSHELL_SCRIPT" '[switch]$DryRun' 'PowerShell installer accepts -DryRun'

printf '%s\n' 'test: PowerShell installer validates exact endpoints with System.Uri'
assert_file_contains "$POWERSHELL_SCRIPT" '[System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)' 'PowerShell endpoint validation uses the PowerShell 5.1-compatible System.Uri parser'
assert_file_contains "$POWERSHELL_SCRIPT" "\$uri.Scheme -cne 'http'" 'PowerShell endpoint validation restricts the parsed scheme to http or https'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]::IsNullOrEmpty($uri.Host)' 'PowerShell endpoint validation rejects an empty parsed host'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]::IsNullOrEmpty($uri.UserInfo)' 'PowerShell endpoint validation rejects parsed userinfo'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]::IsNullOrEmpty($uri.Query)' 'PowerShell endpoint validation rejects a parsed query'
assert_file_contains "$POWERSHELL_SCRIPT" '[string]::IsNullOrEmpty($uri.Fragment)' 'PowerShell endpoint validation rejects a parsed fragment'
assert_file_contains "$POWERSHELL_SCRIPT" "\$Value -match '[\s\\\\]'" 'PowerShell endpoint validation rejects whitespace and backslashes before parsing'
assert_file_contains "$POWERSHELL_SCRIPT" "\$Value.Contains('?')" 'PowerShell endpoint validation rejects even an empty raw query'
assert_file_contains "$POWERSHELL_SCRIPT" "\$Value.Contains('#')" 'PowerShell endpoint validation rejects even an empty raw fragment'

printf '%s\n' 'test: PowerShell installer includes fallbacks and install decision branches'
assert_file_contains "$POWERSHELL_SCRIPT" '$env:AI_ENDPOINT' 'PowerShell endpoint falls back to AI_ENDPOINT'
assert_file_contains "$POWERSHELL_SCRIPT" '$env:AI_API_KEY' 'PowerShell key falls back to AI_API_KEY'
assert_file_contains "$POWERSHELL_SCRIPT" '$env:AI_INSTALL_YES' 'PowerShell unattended mode falls back to AI_INSTALL_YES'
assert_file_contains "$POWERSHELL_SCRIPT" 'https://claude.ai/install.ps1' 'PowerShell installer uses the official native installer URL'
assert_file_contains "$POWERSHELL_SCRIPT" "Get-Command -Name 'claude'" 'PowerShell installer detects an existing command'
assert_file_contains "$POWERSHELL_SCRIPT" 'if ($Reinstall)' 'PowerShell installer has a forced-reinstall branch'
assert_file_contains "$POWERSHELL_SCRIPT" 'elseif ($Yes)' 'PowerShell installer has an unattended existing-command skip branch'
assert_file_contains "$POWERSHELL_SCRIPT" "& 'claude' '--version'" 'PowerShell installer verifies the installed command'

printf '%s\n' 'test: PowerShell installer persists environment and safely merges JSON'
assert_file_contains "$POWERSHELL_SCRIPT" "'ANTHROPIC_BASE_URL', \$Endpoint, 'Process'" 'PowerShell installer writes the endpoint to Process scope'
assert_file_contains "$POWERSHELL_SCRIPT" "'ANTHROPIC_BASE_URL', \$Endpoint, 'User'" 'PowerShell installer writes the endpoint to User scope'
assert_file_contains "$POWERSHELL_SCRIPT" "'ANTHROPIC_AUTH_TOKEN', \$Key, 'Process'" 'PowerShell installer writes the key to Process scope'
assert_file_contains "$POWERSHELL_SCRIPT" "'ANTHROPIC_AUTH_TOKEN', \$Key, 'User'" 'PowerShell installer writes the key to User scope'
assert_file_contains "$POWERSHELL_SCRIPT" '.ai-cli-installers.bak' 'PowerShell installer backs up an existing JSON configuration'
assert_file_contains "$POWERSHELL_SCRIPT" 'ConvertFrom-Json -ErrorAction Stop' 'PowerShell installer parses existing JSON with terminating errors'
assert_file_contains "$POWERSHELL_SCRIPT" "PSObject.Properties['hasCompletedOnboarding']" 'PowerShell installer merges the onboarding field into the parsed object'
assert_file_contains "$POWERSHELL_SCRIPT" 'Move-Item -LiteralPath $tempPath -Destination $configPath -Force' 'PowerShell installer atomically replaces JSON from a temporary file'

printf '%s\n' 'test: PowerShell installer is brand-neutral'
if [ -f "$POWERSHELL_SCRIPT" ] && LC_ALL=C grep -Eiq 'aitongdao|tokencat|aiwanai|SITE_NAME|SITE_DOMAIN|AI_HOST|PROVIDER_ID_PREFIX' "$POWERSHELL_SCRIPT"; then
  _test_failure 'PowerShell installer contains a private brand or placeholder token'
fi

if command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' 'test: PowerShell parser accepts claude-code.ps1'
  run_capture env POWERSHELL_SCRIPT="$POWERSHELL_SCRIPT" pwsh -NoLogo -NoProfile -NonInteractive -Command \
    '$tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($env:POWERSHELL_SCRIPT, [ref]$tokens, [ref]$errors) > $null; if ($errors.Count -gt 0) { $errors | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }'
  assert_success "PowerShell parser reports no syntax errors: $RUN_OUTPUT"
fi

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'ok - claude-code PowerShell installer contract'
