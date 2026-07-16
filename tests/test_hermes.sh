#!/usr/bin/env bash
# shellcheck disable=SC2016

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
SCRIPT=$REPO_DIR/hermes.sh

# shellcheck source=tests/testlib.sh
# shellcheck disable=SC1091
. "$TEST_DIR/testlib.sh"

ENDPOINT='https://api.example.test/v1'
API_KEY='sk-hermes-full-secret-for-tests'
MODEL='openai/gpt-4.1-mini'
PROVIDER='edge_v1-test'
KEY_ENV='HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY'

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

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

setup_fake_hermes() {
  new_sandbox
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  HERMES_HOME=$HOME/.hermes
  export PATH HERMES_HOME

  FAKE_CURL_LOG=$SANDBOX/curl.log
  FAKE_INSTALL_LOG=$SANDBOX/install.log
  FAKE_HERMES_LOG=$SANDBOX/hermes.log
  FAKE_CHILD_LOG=$SANDBOX/children.log
  FAKE_CONFIG_COUNT=$SANDBOX/config-count
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_INSTALL_LOG"
  : >"$FAKE_HERMES_LOG"
  : >"$FAKE_CHILD_LOG"
  export FAKE_CURL_LOG FAKE_INSTALL_LOG FAKE_HERMES_LOG FAKE_CHILD_LOG FAKE_CONFIG_COUNT

  make_fake_command installed-hermes '#!/bin/sh
{
  printf "child=hermes\n"
  env
} >>"$FAKE_CHILD_LOG"
{
  printf "argv:"
  for arg do printf " <%s>" "$arg"; done
  printf "\n"
} >>"$FAKE_HERMES_LOG"

if [ "${1-}" = "version" ]; then
  printf "Hermes fake 1.0\n"
  exit 0
fi

if [ "${1-}" = "config" ] && [ "${2-}" = "show" ]; then
  : >"$HERMES_HOME/show-side-effect"
  if [ -f "$HERMES_HOME/config.yaml" ] && grep -F "malformed: [" "$HERMES_HOME/config.yaml" >/dev/null 2>&1; then
    printf "Failed to parse config: simulated YAML error\n" >&2
  fi
  exit 0
fi

if [ "${1-}" = "config" ] && [ "${2-}" = "set" ] && [ "$#" -eq 4 ]; then
  count=0
  [ ! -f "$FAKE_CONFIG_COUNT" ] || count=$(cat "$FAKE_CONFIG_COUNT")
  count=$((count + 1))
  printf "%s\n" "$count" >"$FAKE_CONFIG_COUNT"
  mkdir -p "$HERMES_HOME"
  printf "fake_partial_%s: true\n" "$count" >>"$HERMES_HOME/config.yaml"
  if [ -n "${FAKE_CONFIG_FAIL_AT-}" ] && [ "$count" -eq "$FAKE_CONFIG_FAIL_AT" ]; then
    printf "simulated config failure\n" >&2
    exit 42
  fi
  printf "%s=%s\n" "$3" "$4" >>"$HERMES_HOME/config.yaml"
  exit 0
fi

exit 2'

  make_fake_command curl '#!/bin/sh
{
  printf "child=curl\n"
  env
} >>"$FAKE_CHILD_LOG"
printf "%s\n" "$*" >>"$FAKE_CURL_LOG"
printf "%s\n" \
  "#!/bin/sh" \
  "{ printf \"child=official-installer\\n\"; env; } >>\"\$FAKE_CHILD_LOG\"" \
  "{ printf \"argv:\"; for arg do printf \" <%s>\" \"\$arg\"; done; printf \"\\n\"; } >>\"\$FAKE_INSTALL_LOG\"" \
  "if [ \"\${FAKE_INSTALL_MUTATE_CONFIG-}\" = 1 ]; then mkdir -p \"\$HERMES_HOME\"; printf \"installer: changed\\n\" >\"\$HERMES_HOME/config.yaml\"; printf \"INSTALLER_ENV=changed\\n\" >\"\$HERMES_HOME/.env\"; fi" \
  "if [ \"\${FAKE_INSTALL_FAIL-}\" = 1 ]; then exit 31; fi" \
  "if [ \"\${FAKE_INSTALL_NO_COMMAND-}\" != 1 ]; then cp \"\$FAKE_BIN/installed-hermes\" \"\$FAKE_BIN/hermes\"; chmod +x \"\$FAKE_BIN/hermes\"; fi"'
}

install_existing_hermes() {
  cp "$FAKE_BIN/installed-hermes" "$FAKE_BIN/hermes"
  chmod +x "$FAKE_BIN/hermes"
}

run_unattended() {
  run_capture env \
    AI_ENDPOINT="$ENDPOINT/" \
    AI_API_KEY="$API_KEY" \
    AI_MODEL="$MODEL" \
    AI_INSTALL_YES=1 \
    bash "$SCRIPT" --provider-id "$PROVIDER" "$@"
}

printf '%s\n' 'test: missing Hermes invokes the stable official installer and verifies the command'
setup_fake_hermes
run_unattended
assert_success 'missing Hermes installation succeeds'
assert_file_contains "$FAKE_CURL_LOG" '-fsSL https://hermes-agent.nousresearch.com/install.sh' 'stable official Hermes installer URL is fetched'
assert_file_contains "$FAKE_INSTALL_LOG" '<--skip-setup> <--non-interactive>' 'official installer receives non-interactive no-setup flags'
assert_file_contains "$FAKE_HERMES_LOG" 'argv: <version>' 'installed Hermes is verified with hermes version'
assert_output_masks_key 'successful install output masks the API key'
assert_file_not_contains "$FAKE_CHILD_LOG" "$API_KEY" 'API key is absent from curl, installer, and Hermes child environments'
assert_file_not_contains "$FAKE_HERMES_LOG" "$API_KEY" 'API key is absent from Hermes child argv'

printf '%s\n' 'test: existing Hermes plus --yes skips installation but continues configuration'
setup_fake_hermes
install_existing_hermes
run_unattended
assert_success 'existing Hermes unattended configuration succeeds'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" '--yes skips update of an existing Hermes command'
assert_file_contains "$FAKE_HERMES_LOG" 'providers.edge_v1-test.api' 'skipped installation still configures Hermes'
assert_output_masks_key 'existing Hermes output masks the API key'

printf '%s\n' 'test: --reinstall updates an existing Hermes command'
setup_fake_hermes
install_existing_hermes
run_unattended --reinstall
assert_success 'forced Hermes reinstall succeeds'
assert_file_contains "$FAKE_INSTALL_LOG" '<--skip-setup> <--non-interactive>' '--reinstall executes the official installer'
assert_output_masks_key 'reinstall output masks the API key'

printf '%s\n' 'test: dry-run validates without installation, subprocess calls, or filesystem writes'
setup_fake_hermes
run_unattended --dry-run
assert_success 'Hermes dry-run succeeds'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'dry-run does not fetch an installer'
assert_eq '0' "$(wc -c <"$FAKE_HERMES_LOG" | tr -d ' ')" 'dry-run does not invoke Hermes'
assert_not_exists "$HERMES_HOME" 'dry-run does not create HERMES_HOME'
assert_output_masks_key 'dry-run output masks the API key'

printf '%s\n' 'test: unattended mode requires endpoint, key, and model'
for MISSING in endpoint key model; do
  setup_fake_hermes
  case $MISSING in
    endpoint)
      run_capture env -u AI_ENDPOINT -u AI_API_KEY -u AI_MODEL AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT" --provider-id "$PROVIDER"
      ;;
    key)
      run_capture env -u AI_ENDPOINT -u AI_API_KEY -u AI_MODEL AI_ENDPOINT="$ENDPOINT" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT" --provider-id "$PROVIDER"
      ;;
    model)
      run_capture env -u AI_ENDPOINT -u AI_API_KEY -u AI_MODEL AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 bash "$SCRIPT" --provider-id "$PROVIDER"
      ;;
  esac
  assert_failure "unattended mode fails when $MISSING is missing"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "missing $MISSING does not invoke installer"
  assert_output_masks_key "missing $MISSING output masks the API key"
done

printf '%s\n' 'test: malformed YAML is rejected before config set and remains byte-for-byte unchanged'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'keep: original' 'malformed: [' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'KEEP_ENV=original' >"$HERMES_HOME/.env"
cp "$HERMES_HOME/config.yaml" "$SANDBOX/original-malformed-config"
run_unattended
assert_failure 'malformed existing YAML is rejected even though Hermes config get exits zero'
assert_files_equal "$SANDBOX/original-malformed-config" "$HERMES_HOME/config.yaml" 'malformed YAML remains byte-for-byte unchanged'
assert_not_exists "$HERMES_HOME/show-side-effect" 'YAML preflight isolates read-command side effects from the real HERMES_HOME'
if grep -F 'argv: <config> <set>' "$FAKE_HERMES_LOG" >/dev/null 2>&1; then
  _test_failure 'malformed YAML never reaches hermes config set'
fi
assert_output_masks_key 'malformed-YAML failure masks the API key'

printf '%s\n' 'test: YAML-coercible model scalars are rejected before installation or writes'
for COERCIBLE_MODEL in true FALSE null Yes no ON off 123 1.25 2026-07-16; do
  setup_fake_hermes
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --model "$COERCIBLE_MODEL" --provider-id "$PROVIDER"
  assert_failure "YAML-coercible model is rejected: $COERCIBLE_MODEL"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "coercible model does not fetch: $COERCIBLE_MODEL"
  assert_not_exists "$HERMES_HOME" "coercible model does not write: $COERCIBLE_MODEL"
done

printf '%s\n' 'test: invalid HERMES_HOME fails preflight before installer fetch'
setup_fake_hermes
: >"$HERMES_HOME"
run_unattended
assert_failure 'HERMES_HOME pointing to a regular file fails preflight'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'file HERMES_HOME does not fetch installer'

setup_fake_hermes
mkdir -p "$HERMES_HOME"
chmod 500 "$HERMES_HOME"
run_unattended
assert_failure 'unwritable HERMES_HOME fails preflight'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'unwritable HERMES_HOME does not fetch installer'
chmod 700 "$HERMES_HOME"

printf '%s\n' 'test: backups precede the official installer and preserve pre-installer bytes'
setup_fake_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'original: before-installer' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'ORIGINAL_ENV=before-installer' >"$HERMES_HOME/.env"
run_capture env FAKE_INSTALL_MUTATE_CONFIG=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT" --provider-id "$PROVIDER"
assert_success 'configuration succeeds when the no-setup installer unexpectedly touches config files'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'original: before-installer' 'config backup contains the pre-installer bytes'
assert_file_contains "$HERMES_HOME/.env.ai-cli-installers.bak" 'ORIGINAL_ENV=before-installer' 'dotenv backup contains the pre-installer bytes'
assert_file_contains "$HERMES_HOME/config.yaml" 'original: before-installer' 'unexpected installer config mutation is discarded before merge'
assert_file_contains "$HERMES_HOME/.env" 'ORIGINAL_ENV=before-installer' 'unexpected installer dotenv mutation is discarded before merge'

printf '%s\n' 'test: installer failure after touching config rolls both files back'
setup_fake_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'original: rollback-installer' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'ORIGINAL_ENV=rollback-installer' >"$HERMES_HOME/.env"
cp "$HERMES_HOME/config.yaml" "$SANDBOX/pre-installer-config"
cp "$HERMES_HOME/.env" "$SANDBOX/pre-installer-env"
run_capture env FAKE_INSTALL_MUTATE_CONFIG=1 FAKE_INSTALL_FAIL=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT" --provider-id "$PROVIDER"
assert_failure 'official installer failure is reported'
assert_files_equal "$SANDBOX/pre-installer-config" "$HERMES_HOME/config.yaml" 'installer failure restores original config bytes'
assert_files_equal "$SANDBOX/pre-installer-env" "$HERMES_HOME/.env" 'installer failure restores original dotenv bytes'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'original: rollback-installer' 'installer-failure config backup is retained'
assert_file_contains "$HERMES_HOME/.env.ai-cli-installers.bak" 'ORIGINAL_ENV=rollback-installer' 'installer-failure dotenv backup is retained'

printf '%s\n' 'test: dotenv-aware merge preserves unrelated multiline values and removes full target assignments'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' \
  'seed: dotenv-lexical' >"$HERMES_HOME/config.yaml"
printf '%s\n' \
  'OTHER_DOUBLE="double-first' \
  'export HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = inside-double-value' \
  'double-last"' \
  "OTHER_SINGLE='single-first" \
  '  HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = inside-single-value' \
  "single-last'" \
  'export HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = "old-target-first' \
  'old-target-tail"' \
  '  HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = unquoted-old-target' \
  'COMMENT_VALUE=${OTHER_TOKEN}' >"$HERMES_HOME/.env"
run_unattended
assert_success 'dotenv lexical merge succeeds'
assert_file_contains "$HERMES_HOME/.env" 'OTHER_DOUBLE="double-first' 'unrelated double-quoted multiline assignment start is preserved'
assert_file_contains "$HERMES_HOME/.env" 'export HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = inside-double-value' 'target-looking content inside unrelated double quotes is preserved'
assert_file_contains "$HERMES_HOME/.env" 'double-last"' 'unrelated double-quoted multiline assignment end is preserved'
assert_file_contains "$HERMES_HOME/.env" "OTHER_SINGLE='single-first" 'unrelated single-quoted multiline assignment start is preserved'
assert_file_contains "$HERMES_HOME/.env" '  HERMES_PROVIDER_EDGE_UV1_HTEST_API_KEY = inside-single-value' 'target-looking content inside unrelated single quotes is preserved'
assert_file_contains "$HERMES_HOME/.env" "single-last'" 'unrelated single-quoted multiline assignment end is preserved'
assert_file_not_contains "$HERMES_HOME/.env" 'old-target-first' 'target multiline assignment start is removed'
assert_file_not_contains "$HERMES_HOME/.env" 'old-target-tail' 'target multiline assignment continuation is removed'
assert_file_not_contains "$HERMES_HOME/.env" 'unquoted-old-target' 'spaced target assignment is removed'
assert_file_contains "$HERMES_HOME/.env" 'COMMENT_VALUE=${OTHER_TOKEN}' 'unrelated interpolation syntax is preserved'
assert_eq '1' "$(grep -c "^$KEY_ENV=" "$HERMES_HOME/.env")" 'dotenv merge appends one canonical target assignment'

printf '%s\n' 'test: malformed unclosed dotenv quote fails before installer, backup, or mutation'
setup_fake_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'OTHER="unclosed' 'still-open' >"$HERMES_HOME/.env"
cp "$HERMES_HOME/.env" "$SANDBOX/original-unclosed-env"
run_unattended
assert_failure 'unclosed dotenv quote is rejected'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'unclosed dotenv quote does not fetch installer'
assert_files_equal "$SANDBOX/original-unclosed-env" "$HERMES_HOME/.env" 'unclosed dotenv remains byte-for-byte unchanged'
assert_not_exists "$HERMES_HOME/.env.ai-cli-installers.bak" 'unclosed dotenv fails before backup creation'

printf '%s\n' 'test: API keys must be printable ASCII and parser errors never echo positionals'
setup_fake_hermes
NON_ASCII_KEY='clé-secret'
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$NON_ASCII_KEY" --model "$MODEL" --provider-id "$PROVIDER"
assert_failure 'non-ASCII API key is rejected'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'non-ASCII API key does not fetch installer'
assert_not_exists "$HERMES_HOME" 'non-ASCII API key does not write'
case $RUN_OUTPUT in
  *"$NON_ASCII_KEY"*) _test_failure 'non-ASCII API key is not echoed' ;;
esac

setup_fake_hermes
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" "$API_KEY"
assert_failure 'unexpected positional argument is rejected'
assert_output_masks_key 'positional parse error does not echo the supplied value'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'positional parse error does not fetch installer'

printf '%s\n' 'test: official config CLI receives the current providers schema and preserves unrelated YAML'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'unrelated:' '  nested: keep-me' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'UNRELATED_ENV=keep-me' >"$HERMES_HOME/.env"
run_unattended
assert_success 'new-style Hermes configuration succeeds'
assert_file_contains "$FAKE_HERMES_LOG" "<providers.$PROVIDER.api> <$ENDPOINT>" 'provider API uses the exact endpoint without a trailing slash'
assert_file_contains "$FAKE_HERMES_LOG" "<providers.$PROVIDER.key_env> <$KEY_ENV>" 'provider points to its encoded environment variable'
assert_file_contains "$FAKE_HERMES_LOG" "<providers.$PROVIDER.default_model> <$MODEL>" 'provider receives its default model'
assert_file_contains "$FAKE_HERMES_LOG" "<providers.$PROVIDER.transport> <chat_completions>" 'provider uses chat_completions transport'
assert_file_contains "$FAKE_HERMES_LOG" "<model.default> <$MODEL>" 'global model default is configured'
assert_file_contains "$FAKE_HERMES_LOG" "<model.provider> <custom:$PROVIDER>" 'model provider selects the custom provider id'
assert_file_contains "$HERMES_HOME/config.yaml" 'nested: keep-me' 'official config merge preserves unrelated YAML'
assert_file_contains "$HERMES_HOME/.env" 'UNRELATED_ENV=keep-me' '.env update preserves unrelated variables'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'nested: keep-me' 'existing config is backed up before mutation'
assert_file_contains "$HERMES_HOME/.env.ai-cli-installers.bak" 'UNRELATED_ENV=keep-me' 'existing .env is backed up before mutation'
assert_output_masks_key 'configuration output masks the API key'

printf '%s\n' 'test: provider ids encode unambiguously and dotenv values escape quotes and backslashes'
setup_fake_hermes
install_existing_hermes
ESCAPED_KEY='sec"ret\path$dollar'
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" \
  --endpoint "$ENDPOINT" --key "$ESCAPED_KEY" --model "$MODEL" --provider-id 'a_b-c'
assert_success 'dotenv-safe secret configuration succeeds'
assert_file_contains "$FAKE_HERMES_LOG" '<providers.a_b-c.key_env> <HERMES_PROVIDER_A_UB_HC_API_KEY>' 'underscore and hyphen have distinct provider env encodings'
assert_file_contains "$HERMES_HOME/.env" 'HERMES_PROVIDER_A_UB_HC_API_KEY="sec\"ret\\path$dollar"' 'dotenv stores the exact escaped secret in a quoted value'
case $RUN_OUTPUT in
  *"$ESCAPED_KEY"*) _test_failure 'escaped API key is not displayed' ;;
esac

printf '%s\n' 'test: repeated configuration is idempotent and creates unique backups'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'seed: true' >"$HERMES_HOME/config.yaml"
printf '%s\n' "$KEY_ENV=\"old\"" 'OTHER=keep' >"$HERMES_HOME/.env"
run_unattended
assert_success 'first Hermes configuration succeeds'
run_unattended
assert_success 'second Hermes configuration succeeds'
assert_eq '1' "$(grep -c "^$KEY_ENV=" "$HERMES_HOME/.env")" 'repeat run leaves one exact provider secret assignment'
assert_file_contains "$HERMES_HOME/.env" 'OTHER=keep' 'repeat run preserves unrelated .env assignments'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'seed: true' 'first config backup is retained'
if [ ! -f "$HERMES_HOME/config.yaml.ai-cli-installers.bak.1" ]; then
  _test_failure 'repeat run creates a unique second config backup'
fi
if [ ! -f "$HERMES_HOME/.env.ai-cli-installers.bak.1" ]; then
  _test_failure 'repeat run creates a unique second .env backup'
fi

printf '%s\n' 'test: a mid-configuration failure rolls config and env back to their original bytes'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
printf '%s\n' 'original: config' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'ORIGINAL_ENV=1' >"$HERMES_HOME/.env"
cp "$HERMES_HOME/config.yaml" "$SANDBOX/original-config"
cp "$HERMES_HOME/.env" "$SANDBOX/original-env"
run_capture env FAKE_CONFIG_FAIL_AT=3 AI_INSTALL_YES=1 bash "$SCRIPT" \
  --endpoint "$ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
assert_failure 'simulated third config set failure is reported'
assert_files_equal "$SANDBOX/original-config" "$HERMES_HOME/config.yaml" 'config is restored after a partial CLI mutation'
assert_files_equal "$SANDBOX/original-env" "$HERMES_HOME/.env" '.env is restored after a partial CLI mutation'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'original: config' 'rollback retains the user-visible config backup'
assert_file_contains "$HERMES_HOME/.env.ai-cli-installers.bak" 'ORIGINAL_ENV=1' 'rollback retains the user-visible .env backup'
assert_output_masks_key 'rollback failure output masks the API key'

printf '%s\n' 'test: failure on initially absent configuration removes partial files'
setup_fake_hermes
install_existing_hermes
run_capture env FAKE_CONFIG_FAIL_AT=2 AI_INSTALL_YES=1 bash "$SCRIPT" \
  --endpoint "$ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
assert_failure 'partial configuration of an empty HERMES_HOME fails'
assert_not_exists "$HERMES_HOME/config.yaml" 'rollback removes a partially created config when none existed'
assert_not_exists "$HERMES_HOME/.env" 'rollback removes a newly created .env when none existed'
assert_output_masks_key 'empty-state rollback output masks the API key'

printf '%s\n' 'test: relative config and env symlinks remain links while targets are updated'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME/real"
printf '%s\n' 'linked: config' >"$HERMES_HOME/real/config.yaml"
printf '%s\n' 'LINKED_ENV=keep' >"$HERMES_HOME/real/env"
ln -s 'real/config.yaml' "$HERMES_HOME/config.yaml"
ln -s 'real/env' "$HERMES_HOME/.env"
run_unattended
assert_success 'relative symlink configuration succeeds'
assert_symlink_points_to "$HERMES_HOME/config.yaml" 'real/config.yaml' 'config symlink remains unchanged'
assert_symlink_points_to "$HERMES_HOME/.env" 'real/env' '.env symlink remains unchanged'
assert_file_contains "$HERMES_HOME/real/config.yaml" 'linked: config' 'linked config target preserves unrelated YAML'
assert_file_contains "$HERMES_HOME/real/env" "$KEY_ENV=" 'linked .env target receives the provider key'
assert_file_contains "$HERMES_HOME/config.yaml.ai-cli-installers.bak" 'linked: config' 'linked config content is backed up at the public path'
assert_file_contains "$HERMES_HOME/.env.ai-cli-installers.bak" 'LINKED_ENV=keep' 'linked env content is backed up at the public path'

printf '%s\n' 'test: broken or cyclic symlinks fail during preflight before installation'
setup_fake_hermes
mkdir -p "$HERMES_HOME"
ln -s 'missing.yaml' "$HERMES_HOME/config.yaml"
run_unattended
assert_failure 'broken config symlink causes a safe failure'
assert_symlink_points_to "$HERMES_HOME/config.yaml" 'missing.yaml' 'broken config symlink is not replaced'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'broken config symlink blocks installer before fetch'

setup_fake_hermes
mkdir -p "$HERMES_HOME/real"
ln -s 'real/env-cycle' "$HERMES_HOME/.env"
ln -s '../.env' "$HERMES_HOME/real/env-cycle"
run_unattended
assert_failure 'cyclic env symlink causes a safe failure'
assert_symlink_points_to "$HERMES_HOME/.env" 'real/env-cycle' 'cyclic env symlink is not replaced'
assert_symlink_points_to "$HERMES_HOME/real/env-cycle" '../.env' 'cyclic env link partner is not replaced'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'cyclic env symlink blocks installer before fetch'

printf '%s\n' 'test: secret files, backups, directories, and temporary-file cleanup are private'
setup_fake_hermes
install_existing_hermes
mkdir -p "$HERMES_HOME"
chmod 755 "$HERMES_HOME"
printf '%s\n' 'seed: mode' >"$HERMES_HOME/config.yaml"
printf '%s\n' 'MODE_ENV=old' >"$HERMES_HOME/.env"
chmod 644 "$HERMES_HOME/config.yaml" "$HERMES_HOME/.env"
run_unattended
assert_success 'private-mode configuration succeeds'
assert_eq '700' "$(file_mode "$HERMES_HOME")" 'HERMES_HOME is private'
assert_eq '600' "$(file_mode "$HERMES_HOME/config.yaml")" 'config mode is private'
assert_eq '600' "$(file_mode "$HERMES_HOME/.env")" '.env mode is private'
assert_eq '600' "$(file_mode "$HERMES_HOME/config.yaml.ai-cli-installers.bak")" 'config backup mode is private'
assert_eq '600' "$(file_mode "$HERMES_HOME/.env.ai-cli-installers.bak")" '.env backup mode is private'
if find "$HERMES_HOME" -name '*.ai-cli-installers.tmp.*' -print | grep . >/dev/null 2>&1; then
  _test_failure 'configuration leaves no temporary files behind'
fi

printf '%s\n' 'test: installation must produce a verifiable Hermes command'
setup_fake_hermes
run_capture env FAKE_INSTALL_NO_COMMAND=1 AI_INSTALL_YES=1 bash "$SCRIPT" \
  --endpoint "$ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
assert_failure 'installer success without a Hermes command fails verification'
assert_eq '0' "$(wc -c <"$FAKE_HERMES_LOG" | tr -d ' ')" 'configuration does not run after installation verification fails'
assert_output_masks_key 'verification failure output masks the API key'

printf '%s\n' 'test: endpoint, provider id, and model validation reject unsafe values before writes'
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
  setup_fake_hermes
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$INVALID_ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
  assert_failure "invalid endpoint is rejected: $INVALID_ENDPOINT"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "invalid endpoint does not fetch: $INVALID_ENDPOINT"
done

for INVALID_CONTROL_ENDPOINT in \
  $'https://api.example.test/v1\tbad' \
  $'https://api.example.test/v1\nbad' \
  $'https://api.example.test/v1\001bad' \
  $'https://api.example.test/v1\177bad'
do
  setup_fake_hermes
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$INVALID_CONTROL_ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
  assert_failure 'endpoint containing a control character is rejected'
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'control-character endpoint does not fetch'
done

for INVALID_PROVIDER in 'Upper' 'with.dot' 'with space' 'slash/name' ''; do
  setup_fake_hermes
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --model "$MODEL" --provider-id "$INVALID_PROVIDER"
  assert_failure "invalid provider id is rejected: $INVALID_PROVIDER"
  assert_not_exists "$HERMES_HOME" "invalid provider id does not write: $INVALID_PROVIDER"
done

for INVALID_MODEL in '' 'bad model' 'bad?model' 'bad#model' '../escape'; do
  setup_fake_hermes
  run_capture env -u AI_MODEL AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --model "$INVALID_MODEL" --provider-id "$PROVIDER"
  assert_failure "invalid model is rejected: $INVALID_MODEL"
  assert_not_exists "$HERMES_HOME" "invalid model does not write: $INVALID_MODEL"
done

printf '%s\n' 'test: host ports and bracketed IPv6 endpoints are accepted exactly'
for VALID_ENDPOINT in 'http://127.0.0.1:8080/v1' 'https://[2001:db8::1]:8443/v1'; do
  setup_fake_hermes
  install_existing_hermes
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --endpoint "$VALID_ENDPOINT/" --key "$API_KEY" --model "$MODEL" --provider-id "$PROVIDER"
  assert_success "valid endpoint is accepted: $VALID_ENDPOINT"
  assert_file_contains "$FAKE_HERMES_LOG" "<providers.$PROVIDER.api> <$VALID_ENDPOINT>" "endpoint is configured exactly: $VALID_ENDPOINT"
done

printf '%s\n' 'test: help is side-effect free and brand-neutral'
setup_fake_hermes
run_capture bash "$SCRIPT" --help
assert_success 'Hermes help succeeds without inputs'
assert_not_exists "$HERMES_HOME" 'help does not create HERMES_HOME'
case $RUN_OUTPUT in
  *'OpenAI-compatible endpoint'*) ;;
  *) _test_failure 'help describes a generic OpenAI-compatible endpoint' ;;
esac
case $RUN_OUTPUT in
  *'default: custom'*) ;;
  *) _test_failure 'help documents a generic custom provider default' ;;
esac
for DEPLOYMENT_PLACEHOLDER in SITE_NAME SITE_DOMAIN AI_HOST PROVIDER_ID_PREFIX; do
  assert_file_not_contains "$SCRIPT" "$DEPLOYMENT_PLACEHOLDER" "installer does not depend on deployment placeholder: $DEPLOYMENT_PLACEHOLDER"
done
HARDCODED_HTTPS_URLS=$(grep -Eo 'https://[A-Za-z0-9._/-]+' "$SCRIPT" | sort -u)
assert_eq 'https://hermes-agent.nousresearch.com/install.sh' "$HARDCODED_HTTPS_URLS" 'the official Hermes installer is the only hard-coded HTTPS endpoint'

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'ok - Hermes shell installer'
