#!/usr/bin/env bash
# shellcheck disable=SC2016

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
SCRIPT=$REPO_DIR/codex.sh
REAL_NODE=$(command -v node 2>/dev/null || true)
REAL_PYTHON=$(command -v python3 2>/dev/null || true)

# shellcheck source=tests/testlib.sh
# shellcheck disable=SC1091
. "$TEST_DIR/testlib.sh"

ENDPOINT='https://api.example.test/openai/v1'
API_KEY='sk-openai-full-secret-value-for-tests'
CODEX_BLOCK_START='# >>> ai-cli-installers codex >>>'
CODEX_BLOCK_END='# <<< ai-cli-installers codex <<<'

shell_rc_path() {
  case $(uname -s 2>/dev/null || printf 'unknown\n') in
    Darwin) printf '%s/.zshrc\n' "$HOME" ;;
    *) printf '%s/.bashrc\n' "$HOME" ;;
  esac
}

setup_fake_codex() {
  new_sandbox
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH

  FAKE_NPM_LOG=$SANDBOX/npm.log
  FAKE_CODEX_LOG=$SANDBOX/codex.log
  FAKE_CURL_LOG=$SANDBOX/curl.log
  FAKE_BASH_LOG=$SANDBOX/bash.log
  FAKE_NVM_LOG=$SANDBOX/nvm.log
  FAKE_NODE_ARGV_LOG=$SANDBOX/node-argv.log
  FAKE_CHILD_ENV_LOG=$SANDBOX/child-env.log
  : >"$FAKE_NPM_LOG"
  : >"$FAKE_CODEX_LOG"
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_BASH_LOG"
  : >"$FAKE_NVM_LOG"
  : >"$FAKE_NODE_ARGV_LOG"
  : >"$FAKE_CHILD_ENV_LOG"
  export REAL_NODE FAKE_NPM_LOG FAKE_CODEX_LOG FAKE_CURL_LOG FAKE_BASH_LOG FAKE_NVM_LOG
  export FAKE_NODE_ARGV_LOG FAKE_CHILD_ENV_LOG

  make_fake_command installed-codex '#!/bin/sh
printf "codex=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
printf "%s\n" "$*" >>"$FAKE_CODEX_LOG"
if [ "${1-}" = "--version" ]; then
  printf "codex-cli fake 1.0\n"
  exit 0
fi
exit 0'

  make_fake_command npm '#!/bin/sh
printf "npm=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
printf "%s\n" "$*" >>"$FAKE_NPM_LOG"
if [ "$*" = "install --global @openai/codex" ]; then
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  chmod +x "$FAKE_BIN/codex"
  exit 0
fi
exit 3'

  if [ -n "$REAL_NODE" ]; then
    make_fake_command node '#!/bin/sh
printf "node=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
printf "%s\n" "$*" >>"$FAKE_NODE_ARGV_LOG"
exec "$REAL_NODE" "$@"'
  else
    printf '%s\n' 'node is required to run the Codex installer tests' >&2
    exit 2
  fi
}

setup_fake_node_bootstrap() {
  setup_fake_codex
  cp "$FAKE_BIN/node" "$SANDBOX/fake-node"
  rm -f "$FAKE_BIN/node" "$FAKE_BIN/npm"
  FAKE_NVM_BIN=$SANDBOX/nvm-bin
  mkdir -p "$FAKE_NVM_BIN"
  cp "$SANDBOX/fake-node" "$FAKE_NVM_BIN/node"
  cp "$FAKE_BIN/installed-codex" "$FAKE_NVM_BIN/installed-codex"
  export FAKE_NVM_BIN

  cat >"$SANDBOX/fake-nvm.sh" <<'NVM'
nvm() {
  printf '%s\n' "$*" >>"$FAKE_NVM_LOG"
  case ${1-} in
    install|use)
      PATH="$FAKE_NVM_BIN:$PATH"
      export PATH
      ;;
  esac
}
NVM

  cat >"$FAKE_NVM_BIN/npm" <<'NPM'
#!/bin/sh
printf "nvm-npm=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
printf "%s\n" "$*" >>"$FAKE_NPM_LOG"
if [ "$*" = "install --global @openai/codex" ]; then
  cp "$FAKE_NVM_BIN/installed-codex" "$FAKE_NVM_BIN/codex"
  chmod +x "$FAKE_NVM_BIN/codex"
  exit 0
fi
exit 3
NPM
  chmod +x "$FAKE_NVM_BIN/npm"

  make_fake_command curl '#!/bin/sh
printf "curl=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
printf "%s\n" "$*" >>"$FAKE_CURL_LOG"
printf "%s\n" "fake nvm installer body"'

  make_fake_command bash '#!/bin/sh
printf "bash=%s\n" "${AI_API_KEY-<unset>}" >>"$FAKE_CHILD_ENV_LOG"
cat >/dev/null
printf "%s\n" "nvm-installer-executed" >>"$FAKE_BASH_LOG"
printf "%s\n" "$*" >>"$FAKE_BASH_LOG"
profile_path=${PROFILE:-$FAKE_PROFILE_FALLBACK}
printf "%s\n" "nvm-installer-profile-mutation" >>"$profile_path"
mkdir -p "$NVM_DIR"
cp "$SANDBOX/fake-nvm.sh" "$NVM_DIR/nvm.sh"'
}

setup_temp_instrumentation() {
  FAKE_CHMOD_LOG=$SANDBOX/chmod.log
  FAKE_MV_LOG=$SANDBOX/mv.log
  FAKE_MKTEMP_LOG=$SANDBOX/mktemp.log
  : >"$FAKE_CHMOD_LOG"
  : >"$FAKE_MV_LOG"
  : >"$FAKE_MKTEMP_LOG"
  export FAKE_CHMOD_LOG FAKE_MV_LOG FAKE_MKTEMP_LOG

  make_fake_command chmod '#!/bin/sh
for candidate in "$@"; do
  case $candidate in
    *.ai-cli-installers.tmp.*)
      if mode=$(stat -f "%Lp" "$candidate" 2>/dev/null); then :; else mode=$(stat -c "%a" "$candidate"); fi
      printf "%s|%s\n" "$candidate" "$mode" >>"$FAKE_CHMOD_LOG"
      ;;
  esac
done
/bin/chmod "$@"'

  make_fake_command mv '#!/bin/sh
source_path=
destination_path=
for candidate in "$@"; do
  case $candidate in
    -*) ;;
    *)
      if [ -z "$source_path" ]; then source_path=$candidate; else destination_path=$candidate; fi
      ;;
  esac
done
printf "%s|%s\n" "$source_path" "$destination_path" >>"$FAKE_MV_LOG"
/bin/mv "$@"'

  make_fake_command mktemp '#!/bin/sh
printf "%s\n" "$*" >>"$FAKE_MKTEMP_LOG"
/usr/bin/mktemp "$@"'
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

assert_mode_600() {
  local mode
  if mode=$(stat -f '%Lp' "$1" 2>/dev/null); then
    :
  else
    mode=$(stat -c '%a' "$1" 2>/dev/null || printf 'unknown')
  fi
  assert_eq '600' "$mode" "$2"
}

assert_toml_effective_config() {
  local config_path expected_model expected_provider expected_endpoint message
  config_path=$1
  expected_model=$2
  expected_provider=$3
  expected_endpoint=$4
  message=$5
  if [ -z "$REAL_PYTHON" ]; then
    _test_failure 'Python 3.11+ with tomllib is required for TOML semantic tests'
    return 0
  fi
  if ! "$REAL_PYTHON" - "$config_path" "$expected_model" "$expected_provider" "$expected_endpoint" <<'PY'
import pathlib
import sys
import tomllib

path, model, provider, endpoint = sys.argv[1:]
value = tomllib.loads(pathlib.Path(path).read_text(encoding="utf-8"))
assert value["model"] == model
assert value["model_provider"] == provider
custom = value["model_providers"][provider]
assert custom["base_url"] == endpoint
assert custom["env_key"] == "OPENAI_API_KEY"
assert custom["wire_api"] == "responses"
PY
  then
    _test_failure "$message"
  fi
}

printf '%s\n' 'test: missing command uses the official npm package and writes official provider schema'
setup_fake_codex
run_capture env AI_INSTALL_YES=1 /bin/bash "$SCRIPT" --endpoint "$ENDPOINT/" --key "$API_KEY"
assert_success 'missing Codex installation succeeds'
assert_file_contains "$FAKE_NPM_LOG" 'install --global @openai/codex' 'official Codex npm package is installed globally'
assert_file_contains "$FAKE_CODEX_LOG" '--version' 'new Codex installation is verified with codex --version'
assert_file_contains "$HOME/.codex/config.toml" 'model = "gpt-5.4"' 'default model is written exactly'
assert_file_contains "$HOME/.codex/config.toml" 'model_provider = "custom"' 'default provider id is written exactly'
assert_file_contains "$HOME/.codex/config.toml" '[model_providers.custom]' 'official custom-provider table is written'
assert_file_contains "$HOME/.codex/config.toml" "base_url = \"$ENDPOINT\"" 'exact endpoint is written without its trailing slash'
assert_file_contains "$HOME/.codex/config.toml" 'env_key = "OPENAI_API_KEY"' 'official provider env_key is written'
assert_file_contains "$HOME/.codex/config.toml" 'wire_api = "responses"' 'official responses wire API is written'
assert_file_contains "$HOME/.codex/auth.json" "\"OPENAI_API_KEY\": \"$API_KEY\"" 'auth JSON receives the API key'
assert_file_contains "$(shell_rc_path)" "export OPENAI_API_KEY='$API_KEY'" 'shell environment receives the API key'
assert_mode_600 "$HOME/.codex/config.toml" 'Codex config is owner-only'
assert_mode_600 "$HOME/.codex/auth.json" 'Codex auth is owner-only'
assert_mode_600 "$(shell_rc_path)" 'shell rc is owner-only'
assert_output_masks_key 'successful install output masks the full key'

printf '%s\n' 'test: fallback API key is absent from child env and argv while secret temps start private'
setup_fake_codex
setup_temp_instrumentation
umask 022
run_capture env AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 /bin/bash "$SCRIPT"
assert_success 'instrumented fallback-key installation succeeds'
if grep -F "$API_KEY" "$FAKE_CHILD_ENV_LOG" >/dev/null 2>&1; then
  _test_failure 'fallback API key is unset before invoking node, npm, or codex children'
fi
if grep -F "$API_KEY" "$FAKE_NODE_ARGV_LOG" >/dev/null 2>&1; then
  _test_failure 'API key is not passed through the Node command line'
fi
assert_eq '3' "$(wc -l <"$FAKE_MKTEMP_LOG" | tr -d ' ')" 'all three managed files use mktemp instead of predictable PID paths'
if [ "$(wc -l <"$FAKE_CHMOD_LOG" | tr -d ' ')" != '3' ] || grep -v '|600$' "$FAKE_CHMOD_LOG" >/dev/null 2>&1; then
  _test_failure 'every secret-bearing temp is already mode 600 before chmod or rename'
fi
while IFS='|' read -r temp_source final_destination; do
  [ -n "$temp_source" ] || continue
  assert_eq "${final_destination%/*}" "${temp_source%/*}" 'temporary file is created in the destination directory for atomic rename'
done <"$FAKE_MV_LOG"
assert_output_masks_key 'instrumented fallback-key output masks the full key'

printf '%s\n' 'test: existing command plus --yes skips install but still configures'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
run_capture env AI_ENDPOINT="$ENDPOINT/" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 /bin/bash "$SCRIPT"
assert_success 'existing command unattended configuration succeeds'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" '--yes skips reinstalling an existing command'
assert_file_contains "$HOME/.codex/config.toml" "base_url = \"$ENDPOINT\"" 'skipped reinstall still configures Codex'
assert_file_contains "$HOME/.codex/auth.json" "\"OPENAI_API_KEY\": \"$API_KEY\"" 'skipped reinstall still configures auth'
assert_output_masks_key 'existing-command output masks the full key'

printf '%s\n' 'test: --reinstall installs an existing command'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --reinstall --yes
assert_success 'forced reinstall succeeds'
assert_file_contains "$FAKE_NPM_LOG" 'install --global @openai/codex' 'forced reinstall uses the official npm package'
assert_output_masks_key 'forced-reinstall output masks the full key'

printf '%s\n' 'test: dry-run makes no writes and runs no installer'
setup_fake_codex
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT/" --key "$API_KEY" --model 'gpt-test' --provider-id 'team_1' --dry-run --yes
assert_success 'dry-run succeeds with valid unattended input'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" 'dry-run does not invoke npm'
assert_not_exists "$HOME/.codex" 'dry-run does not create Codex configuration'
assert_not_exists "$(shell_rc_path)" 'dry-run does not create a shell rc file'
assert_output_masks_key 'dry-run output masks the full key'

printf '%s\n' 'test: unattended mode requires endpoint and key'
setup_fake_codex
run_capture env -u AI_ENDPOINT -u AI_API_KEY AI_INSTALL_YES=1 /bin/bash "$SCRIPT" --key "$API_KEY"
assert_failure 'unattended mode fails without an endpoint'
assert_output_masks_key 'missing-endpoint output masks the full key'
setup_fake_codex
run_capture env -u AI_ENDPOINT -u AI_API_KEY /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --yes
assert_failure 'unattended mode fails without a key'

printf '%s\n' 'test: missing Node and npm bootstrap official nvm v0.40.3 and Node 22'
setup_fake_node_bootstrap
FAKE_PROFILE_FALLBACK=$(shell_rc_path)
CUSTOM_NVM_DIR="$HOME/nvm dir's"
export FAKE_PROFILE_FALLBACK
printf '%s\n' 'export ORIGINAL_RC_BEFORE_NVM=keep' >"$FAKE_PROFILE_FALLBACK"
cp "$FAKE_PROFILE_FALLBACK" "$SANDBOX/original-rc-before-nvm"
run_capture env NVM_DIR="$CUSTOM_NVM_DIR" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 /bin/bash "$SCRIPT" --endpoint "$ENDPOINT"
assert_success 'Node bootstrap succeeds without preinstalled Node or npm'
assert_file_contains "$FAKE_CURL_LOG" '-fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh' 'official pinned nvm installer is fetched'
assert_file_contains "$FAKE_BASH_LOG" 'nvm-installer-executed' 'downloaded nvm installer body is executed by bash'
assert_file_contains "$FAKE_NVM_LOG" 'install 22' 'Node 22 is installed through nvm'
assert_file_contains "$FAKE_NVM_LOG" 'use 22' 'Node 22 is activated through nvm'
assert_file_contains "$FAKE_NPM_LOG" 'install --global @openai/codex' 'Codex installs after Node bootstrap'
if grep -F "$API_KEY" "$FAKE_CHILD_ENV_LOG" >/dev/null 2>&1; then
  _test_failure 'fallback key is absent from nvm curl, bash, npm, node, and codex child environments'
fi
if grep -F "$API_KEY" "$FAKE_NODE_ARGV_LOG" >/dev/null 2>&1; then
  _test_failure 'bootstrap path never passes fallback key through Node argv'
fi
assert_files_equal "$SANDBOX/original-rc-before-nvm" "$FAKE_PROFILE_FALLBACK.ai-cli-installers.bak" 'nvm installer cannot mutate shell rc before its safety backup'
assert_file_not_contains "$FAKE_PROFILE_FALLBACK" 'nvm-installer-profile-mutation' 'PROFILE=/dev/null keeps nvm installer mutation out of user rc'
assert_file_contains "$FAKE_PROFILE_FALLBACK" 'export ORIGINAL_RC_BEFORE_NVM=keep' 'managed phase preserves original rc content after nvm bootstrap'
assert_file_contains "$FAKE_PROFILE_FALLBACK" "export NVM_DIR='" 'managed block persists quoted NVM_DIR'
assert_file_contains "$FAKE_PROFILE_FALLBACK" "nvm dir'\\''s'" 'managed NVM_DIR safely quotes an apostrophe'
assert_file_contains "$FAKE_PROFILE_FALLBACK" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' 'managed block persists nvm initialization for future shells'
run_capture env PATH="$FAKE_NVM_BIN:$PATH" NVM_DIR="$CUSTOM_NVM_DIR" /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'repeat run with bootstrapped nvm succeeds'
assert_eq '1' "$(grep -c '^export NVM_DIR=' "$FAKE_PROFILE_FALLBACK")" 'repeat run keeps one NVM_DIR export'
assert_eq '1' "$(grep -c '^\[ -s \"\$NVM_DIR/nvm.sh\" \] && \. \"\$NVM_DIR/nvm.sh\"$' "$FAKE_PROFILE_FALLBACK")" 'repeat run keeps one nvm initialization line'
/bin/bash -n "$FAKE_PROFILE_FALLBACK" || _test_failure 'managed nvm initialization remains valid Bash syntax'
assert_output_masks_key 'bootstrap output masks the full key'

printf '%s\n' 'test: config merge removes only conflicting top-level keys and preserves sections'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
cat >"$HOME/.codex/config.toml" <<'TOML'
# keep this header
model = "old-top-level"
model_provider = "old-provider"
approval_policy = "on-request"

  [profiles.work]
model = "section-model-must-stay"
model_provider = "section-provider-must-stay"
custom_setting = "keep"

[model_providers.other]
base_url = "https://other.example.test/v1"
env_key = "OTHER_API_KEY"

[model_providers.team_1]
base_url = "https://stale.example.test/v1"
env_key = "STALE_API_KEY"
wire_api = "chat"
TOML
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --model 'gpt-custom-1' --provider-id 'team_1' --yes
assert_success 'existing TOML merge succeeds'
assert_file_not_contains "$HOME/.codex/config.toml" 'old-top-level' 'conflicting top-level model is removed'
assert_file_not_contains "$HOME/.codex/config.toml" 'old-provider' 'conflicting top-level provider is removed'
assert_file_contains "$HOME/.codex/config.toml" 'approval_policy = "on-request"' 'unrelated top-level TOML is preserved'
assert_file_contains "$HOME/.codex/config.toml" 'model = "section-model-must-stay"' 'model inside another section is preserved'
assert_file_contains "$HOME/.codex/config.toml" 'model_provider = "section-provider-must-stay"' 'model_provider inside another section is preserved'
assert_file_contains "$HOME/.codex/config.toml" '[model_providers.other]' 'unrelated provider section is preserved'
assert_eq '1' "$(grep -c '^\[model_providers\.team_1\]$' "$HOME/.codex/config.toml")" 'conflicting provider table is replaced instead of duplicated'
assert_file_not_contains "$HOME/.codex/config.toml" 'https://stale.example.test/v1' 'stale fields from the conflicting provider table are removed'
assert_file_contains "$HOME/.codex/config.toml" 'model = "gpt-custom-1"' 'requested model is written exactly'
assert_file_contains "$HOME/.codex/config.toml" 'model_provider = "team_1"' 'requested provider id is written exactly'
assert_file_contains "$HOME/.codex/config.toml" '[model_providers.team_1]' 'requested provider table is written exactly'
MANAGED_LINE=$(grep -n -F "$CODEX_BLOCK_START" "$HOME/.codex/config.toml" | cut -d: -f1)
FIRST_SECTION_LINE=$(grep -n -F '[profiles.work]' "$HOME/.codex/config.toml" | cut -d: -f1)
if [ "$MANAGED_LINE" -ge "$FIRST_SECTION_LINE" ]; then
  _test_failure 'managed block is inserted before the first existing TOML table so model keys stay top-level'
fi
assert_file_contains "$HOME/.codex/config.toml.ai-cli-installers.bak" 'old-top-level' 'original TOML is backed up'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-custom-1' 'team_1' "$ENDPOINT" 'merged config parses and exposes the requested effective values'

printf '%s\n' 'test: TOML merge understands quoted keys, quoted provider tables, and multiline strings'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
cat >"$HOME/.codex/config.toml" <<'TOML'
"model" = "old-quoted-model"
'model_provider' = 'old-quoted-provider'
approval_policy = "on-request"
basic_instructions = """
[looks.like.table]
model = "multiline-basic-content"
"""
literal_instructions = '''
[looks.like.literal]
model_provider = "multiline-literal-content"
'''

[model_providers."custom"]
base_url = "https://stale.example.test/v1"
env_key = "STALE_KEY"
wire_api = "chat"
TOML
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'quoted-key and multiline TOML merge succeeds'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" 'quoted-key and multiline result is valid TOML with effective managed values'
if ! "$REAL_PYTHON" - "$HOME/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

value = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["approval_policy"] == "on-request"
assert "[looks.like.table]" in value["basic_instructions"]
assert 'model = "multiline-basic-content"' in value["basic_instructions"]
assert "[looks.like.literal]" in value["literal_instructions"]
assert 'model_provider = "multiline-literal-content"' in value["literal_instructions"]
PY
then
  _test_failure 'unrelated multiline basic and literal TOML strings are preserved semantically'
fi

printf '%s\n' 'test: conflicting top-level multiline model is removed as one lexical value'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
cat >"$HOME/.codex/config.toml" <<'TOML'
model = """
old multiline model
[looks.like.table.but.is.model.content]
"""
approval_policy = "never"
TOML
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'conflicting multiline model merge succeeds'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" 'conflicting multiline model is removed without leaving invalid TOML fragments'
assert_file_contains "$HOME/.codex/config.toml" 'approval_policy = "never"' 'unrelated key after multiline model is preserved'
assert_file_not_contains "$HOME/.codex/config.toml" 'old multiline model' 'old multiline model content is removed'

printf '%s\n' 'test: TOML merge recognizes whitespace around an equivalent provider table'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
cat >"$HOME/.codex/config.toml" <<'TOML'
approval_policy = "never"
[ model_providers.custom ]
base_url = "https://stale-space.example.test/v1"
env_key = "STALE_KEY"
TOML
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'whitespace provider table merge succeeds'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" 'whitespace provider table is replaced without creating invalid TOML'
assert_file_not_contains "$HOME/.codex/config.toml" 'stale-space' 'whitespace-equivalent stale provider table is removed'

printf '%s\n' 'test: TOML merge recognizes quoted model_providers root table segments'
for QUOTED_PROVIDER_HEADER in '["model_providers".custom]' "['model_providers'.custom]"; do
  setup_fake_codex
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  mkdir -p "$HOME/.codex"
  printf '%s\n' "$QUOTED_PROVIDER_HEADER" 'base_url = "https://stale-quoted-root.example.test/v1"' >"$HOME/.codex/config.toml"
  run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
  assert_success "quoted model_providers root merge succeeds: $QUOTED_PROVIDER_HEADER"
  assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" "quoted model_providers root is replaced semantically: $QUOTED_PROVIDER_HEADER"
  assert_file_not_contains "$HOME/.codex/config.toml" 'stale-quoted-root' "quoted-root stale provider table is removed: $QUOTED_PROVIDER_HEADER"
done

assert_unsafe_toml_conflict_rejected() {
  local conflict_name conflict_content
  conflict_name=$1
  conflict_content=$2
  setup_fake_codex
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  mkdir -p "$HOME/.codex"
  printf '%s\n' "$conflict_content" >"$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$SANDBOX/original-conflicting-toml"
  run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
  assert_failure "$conflict_name conflict is rejected before merge"
  assert_files_equal "$SANDBOX/original-conflicting-toml" "$HOME/.codex/config.toml" "$conflict_name conflict leaves config unchanged"
  assert_not_exists "$HOME/.codex/config.toml.ai-cli-installers.bak" "$conflict_name conflict fails before backup"
  case $RUN_OUTPUT in
    *'unsupported TOML'*) ;;
    *) _test_failure "$conflict_name conflict reports an explicit unsupported TOML error" ;;
  esac
}

printf '%s\n' 'test: unsafe TOML table forms fail explicitly before backup or writes'
assert_unsafe_toml_conflict_rejected 'array-table' '[[model_providers.custom]]
base_url = "https://array.example.test/v1"'
assert_unsafe_toml_conflict_rejected 'bare-parent-array-table' '[[model_providers]]
name = "unsafe-parent-array"'
assert_unsafe_toml_conflict_rejected 'double-quoted-parent-array-table' '[["model_providers"]]
name = "unsafe-parent-array"'
assert_unsafe_toml_conflict_rejected 'single-quoted-parent-array-table' "[['model_providers']]
name = \"unsafe-parent-array\""
assert_unsafe_toml_conflict_rejected 'inline-table' 'model_providers = { custom = { base_url = "https://inline.example.test/v1" } }'
assert_unsafe_toml_conflict_rejected 'dotted-key' 'model_providers.custom.base_url = "https://dotted.example.test/v1"'
assert_unsafe_toml_conflict_rejected 'parent-table-inline-provider' '[model_providers]
custom = { base_url = "https://parent-inline.example.test/v1" }'
assert_unsafe_toml_conflict_rejected 'dotted-model-key' 'model.variant = "unsafe-table-conflict"'
assert_unsafe_toml_conflict_rejected 'quoted-dotted-model-key' '"model".variant = "unsafe-table-conflict"'
assert_unsafe_toml_conflict_rejected 'dotted-model-provider-key' "'model_provider'.variant = \"unsafe-table-conflict\""
assert_unsafe_toml_conflict_rejected 'model-table' '[model]
variant = "unsafe-table-conflict"'
assert_unsafe_toml_conflict_rejected 'model-array-table' '[[model]]
variant = "unsafe-table-conflict"'
assert_unsafe_toml_conflict_rejected 'quoted-model-table' '["model"]
variant = "unsafe-table-conflict"'
assert_unsafe_toml_conflict_rejected 'model-provider-table' "['model_provider']
variant = \"unsafe-table-conflict\""
assert_unsafe_toml_conflict_rejected 'multiline-model-array' 'model = [
  "unsafe-array-value",
]'

printf '%s\n' 'test: unsafe TOML preflight runs before installing a missing Codex command'
setup_fake_codex
mkdir -p "$HOME/.codex"
printf '%s\n' '[[model_providers.custom]]' 'base_url = "https://unsafe-before-install.example.test/v1"' >"$HOME/.codex/config.toml"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'unsafe TOML fails even when Codex is missing'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" 'unsafe TOML preflight prevents npm installation side effects'
assert_not_exists "$HOME/.codex/config.toml.ai-cli-installers.bak" 'unsafe TOML before install creates no backup'

printf '%s\n' 'test: unrelated multiline nested arrays do not look like TOML headers'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
cat >"$HOME/.codex/config.toml" <<'TOML'
matrix = [
  [1, 2],
  [3, 4],
  { label = "row", values = [5, 6] },
]
approval_policy = "never"
TOML
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'nested array TOML merge succeeds'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" 'nested array result is valid TOML with effective managed values'
if ! "$REAL_PYTHON" - "$HOME/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

value = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["matrix"] == [[1, 2], [3, 4], {"label": "row", "values": [5, 6]}]
assert value["approval_policy"] == "never"
PY
then
  _test_failure 'unrelated nested arrays and inline table values are preserved semantically'
fi

printf '%s\n' 'test: unrelated dotted provider configuration remains mergeable'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
printf '%s\n' 'model_providers.other.base_url = "https://other-dotted.example.test/v1"' >"$HOME/.codex/config.toml"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'unrelated dotted provider does not block the custom provider merge'
assert_toml_effective_config "$HOME/.codex/config.toml" 'gpt-5.4' 'custom' "$ENDPOINT" 'unrelated dotted provider result remains valid TOML'
if ! "$REAL_PYTHON" - "$HOME/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

value = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["model_providers"]["other"]["base_url"] == "https://other-dotted.example.test/v1"
PY
then
  _test_failure 'unrelated dotted provider value is preserved'
fi

printf '%s\n' 'test: endpoint rejects every control character including ESC'
setup_fake_codex
ESC_ENDPOINT=$(printf 'https://api.example.test/v1\033hidden')
run_capture /bin/bash "$SCRIPT" --endpoint "$ESC_ENDPOINT" --key "$API_KEY" --yes
assert_failure 'endpoint containing ESC is rejected'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" 'control-character endpoint does not install'
assert_not_exists "$HOME/.codex" 'control-character endpoint does not write configuration'
assert_output_masks_key 'control-character endpoint failure masks key'

printf '%s\n' 'test: auth JSON merge preserves unrelated fields, backs up, and stays idempotent'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
printf '%s\n' '{"theme":"dark","nested":{"keep":7},"OPENAI_API_KEY":"old"}' >"$HOME/.codex/auth.json"
printf '%s\n' 'export UNRELATED=safe' >"$(shell_rc_path)"
cp "$(shell_rc_path)" "$SANDBOX/original-shell-rc"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'first auth merge succeeds'
cp "$(shell_rc_path)" "$SANDBOX/first-managed-shell-rc"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'second auth merge succeeds'
assert_file_contains "$HOME/.codex/auth.json" '"theme": "dark"' 'auth merge preserves an unrelated scalar'
assert_file_contains "$HOME/.codex/auth.json" '"keep": 7' 'auth merge preserves an unrelated nested field'
assert_file_contains "$HOME/.codex/auth.json" "\"OPENAI_API_KEY\": \"$API_KEY\"" 'auth merge updates the key'
assert_file_contains "$HOME/.codex/auth.json.ai-cli-installers.bak" '"OPENAI_API_KEY":"old"' 'existing auth is backed up before changing'
assert_files_equal "$SANDBOX/original-shell-rc" "$(shell_rc_path).ai-cli-installers.bak" 'first shell rc backup contains the original rc bytes'
assert_files_equal "$SANDBOX/first-managed-shell-rc" "$(shell_rc_path).ai-cli-installers.bak.1" 'repeat run backs up the first managed rc result to a unique path'
assert_eq '1' "$(grep -c "^$CODEX_BLOCK_START$" "$HOME/.codex/config.toml")" 'repeat run leaves one config managed block'
assert_eq '1' "$(grep -c "^$CODEX_BLOCK_START$" "$(shell_rc_path)")" 'repeat run leaves one shell managed block'
assert_eq '1' "$(grep -c '^export OPENAI_API_KEY=' "$(shell_rc_path)")" 'repeat run leaves one key export'
assert_file_contains "$(shell_rc_path)" 'export UNRELATED=safe' 'shell merge preserves unrelated content'
assert_output_masks_key 'repeat-run output masks the full key'

printf '%s\n' 'test: malformed auth JSON is backed up and left unchanged'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex"
MALFORMED_JSON='{"keep":true,'
printf '%s\n' "$MALFORMED_JSON" >"$HOME/.codex/auth.json"
printf '%s\n' 'export RC_BEFORE_INVALID_JSON=keep' >"$(shell_rc_path)"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'malformed auth JSON causes failure'
assert_eq "$MALFORMED_JSON" "$(cat "$HOME/.codex/auth.json")" 'malformed auth remains unchanged'
assert_eq "$MALFORMED_JSON" "$(cat "$HOME/.codex/auth.json.ai-cli-installers.bak")" 'malformed auth is backed up'
assert_not_exists "$(shell_rc_path).ai-cli-installers.bak" 'malformed auth validation does not create an unnecessary shell rc backup'
assert_output_masks_key 'malformed-auth output masks the full key'

printf '%s\n' 'test: malformed auth preflight runs before npm installs a missing Codex command'
setup_fake_codex
mkdir -p "$HOME/.codex"
printf '%s\n' '{"broken":' >"$HOME/.codex/auth.json"
cp "$HOME/.codex/auth.json" "$SANDBOX/malformed-auth-before-install"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'malformed auth fails when Codex is missing'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" 'malformed auth preflight prevents npm installation side effects'
assert_files_equal "$SANDBOX/malformed-auth-before-install" "$HOME/.codex/auth.json" 'malformed auth before install remains unchanged'
assert_files_equal "$SANDBOX/malformed-auth-before-install" "$HOME/.codex/auth.json.ai-cli-installers.bak" 'malformed auth before install is still backed up'
assert_output_masks_key 'malformed-auth-before-install output masks key'

assert_invalid_marker_layout() {
  local file_kind path start end content
  file_kind=$1
  content=$2
  setup_fake_codex
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  mkdir -p "$HOME/.codex"
  case $file_kind in
    config)
      path=$HOME/.codex/config.toml
      start=$CODEX_BLOCK_START
      end=$CODEX_BLOCK_END
      RC_VALIDATION_GUARD=$(shell_rc_path)
      printf '%s\n' 'export RC_BEFORE_INVALID_TOML=keep' >"$RC_VALIDATION_GUARD"
      ;;
    rc)
      path=$(shell_rc_path)
      start=$CODEX_BLOCK_START
      end=$CODEX_BLOCK_END
      ;;
  esac
  printf '%s\n' "$content" | sed "s|START|$start|g; s|END|$end|g" >"$path"
  cp "$path" "$SANDBOX/original-managed-file"
  run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
  assert_failure "$file_kind invalid marker layout causes safe failure"
  assert_files_equal "$SANDBOX/original-managed-file" "$path" "$file_kind invalid marker layout leaves original unchanged"
  assert_not_exists "$path.ai-cli-installers.bak" "$file_kind invalid marker validation does not create an unnecessary backup"
  if [ "$file_kind" = config ]; then
    assert_not_exists "$RC_VALIDATION_GUARD.ai-cli-installers.bak" 'invalid TOML marker validation does not create an unnecessary shell rc backup'
  fi
  assert_output_masks_key "$file_kind marker failure masks the full key"
}

printf '%s\n' 'test: malformed or duplicate managed markers fail safely'
assert_invalid_marker_layout config 'before
START
inside-without-end'
assert_invalid_marker_layout config 'START
first
END
START
second
END'
assert_invalid_marker_layout rc 'END
START'
assert_invalid_marker_layout rc 'START
START
END
END'

printf '%s\n' 'test: relative config, auth, and rc symlinks remain links while targets update'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex" "$HOME/dotfiles"
printf '%s\n' 'approval_policy = "never"' >"$HOME/dotfiles/codex-config.toml"
printf '%s\n' '{"theme":"symlinked"}' >"$HOME/dotfiles/codex-auth.json"
printf '%s\n' 'export UNRELATED_LINK=keep' >"$HOME/dotfiles/shell-rc"
cp "$HOME/dotfiles/shell-rc" "$SANDBOX/original-symlinked-shell-rc"
ln -s '../dotfiles/codex-config.toml' "$HOME/.codex/config.toml"
ln -s '../dotfiles/codex-auth.json' "$HOME/.codex/auth.json"
ln -s 'dotfiles/shell-rc' "$(shell_rc_path)"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'relative symlink configuration succeeds'
assert_symlink_points_to "$HOME/.codex/config.toml" '../dotfiles/codex-config.toml' 'config symlink is preserved'
assert_symlink_points_to "$HOME/.codex/auth.json" '../dotfiles/codex-auth.json' 'auth symlink is preserved'
assert_symlink_points_to "$(shell_rc_path)" 'dotfiles/shell-rc' 'shell rc symlink is preserved'
assert_files_equal "$SANDBOX/original-symlinked-shell-rc" "$(shell_rc_path).ai-cli-installers.bak" 'symlinked shell rc backup contains the original target bytes'
assert_file_contains "$HOME/dotfiles/codex-config.toml" "base_url = \"$ENDPOINT\"" 'config symlink target is updated'
assert_file_contains "$HOME/dotfiles/codex-auth.json" "\"OPENAI_API_KEY\": \"$API_KEY\"" 'auth symlink target is updated'
assert_file_contains "$HOME/dotfiles/shell-rc" "export OPENAI_API_KEY='$API_KEY'" 'shell symlink target is updated'

printf '%s\n' 'test: broken and cyclic symlinks fail without replacing links'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex" "$HOME/dotfiles"
ln -s '../dotfiles/missing-config.toml' "$HOME/.codex/config.toml"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'broken config symlink causes safe failure'
assert_symlink_points_to "$HOME/.codex/config.toml" '../dotfiles/missing-config.toml' 'broken config symlink is not replaced'
assert_not_exists "$HOME/dotfiles/missing-config.toml" 'broken config target is not created'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex" "$HOME/dotfiles"
ln -s '../dotfiles/auth-cycle' "$HOME/.codex/auth.json"
ln -s '../.codex/auth.json' "$HOME/dotfiles/auth-cycle"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'cyclic auth symlink causes safe failure'
assert_symlink_points_to "$HOME/.codex/auth.json" '../dotfiles/auth-cycle' 'cyclic auth symlink is not replaced'
assert_symlink_points_to "$HOME/dotfiles/auth-cycle" '../.codex/auth.json' 'cyclic auth partner remains unchanged'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex" "$HOME/dotfiles"
RC_FILE=$(shell_rc_path)
ln -s 'dotfiles/missing-shell-rc' "$RC_FILE"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'broken shell rc symlink causes safe failure'
assert_symlink_points_to "$RC_FILE" 'dotfiles/missing-shell-rc' 'broken shell rc symlink is not replaced'
assert_not_exists "$HOME/dotfiles/missing-shell-rc" 'broken shell rc target is not created'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
mkdir -p "$HOME/.codex" "$HOME/dotfiles"
RC_FILE=$(shell_rc_path)
RC_NAME=${RC_FILE##*/}
ln -s 'dotfiles/shell-rc-cycle' "$RC_FILE"
ln -s "../$RC_NAME" "$HOME/dotfiles/shell-rc-cycle"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_failure 'cyclic shell rc symlink causes safe failure'
assert_symlink_points_to "$RC_FILE" 'dotfiles/shell-rc-cycle' 'cyclic shell rc symlink is not replaced'
assert_symlink_points_to "$HOME/dotfiles/shell-rc-cycle" "../$RC_NAME" 'cyclic shell rc partner remains unchanged'

printf '%s\n' 'test: API key is shell-quoted safely'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
QUOTED_KEY="sk-value'with-quote"
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$QUOTED_KEY" --yes
assert_success 'key containing a single quote is configured'
assert_file_contains "$(shell_rc_path)" "export OPENAI_API_KEY='sk-value'\\''with-quote'" 'single quote is escaped for POSIX shell'
case $RUN_OUTPUT in
  *"$QUOTED_KEY"*) _test_failure 'quoted full key is absent from output' ;;
esac

printf '%s\n' 'test: unattended configuration works when SHELL is unset'
setup_fake_codex
cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
run_capture env -u SHELL /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --yes
assert_success 'unattended invocation does not require SHELL to be set'
assert_file_contains "$(shell_rc_path)" "export OPENAI_API_KEY='$API_KEY'" 'unset SHELL falls back to a platform rc file'
assert_output_masks_key 'unset-SHELL output masks the full key'

printf '%s\n' 'test: model rejects line breaks that could corrupt TOML'
setup_fake_codex
run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --model "bad
model" --yes
assert_failure 'model containing a newline is rejected'
assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" 'invalid multiline model does not install'
assert_not_exists "$HOME/.codex" 'invalid multiline model does not write configuration'
assert_output_masks_key 'invalid-model output masks the full key'

printf '%s\n' 'test: parser errors never echo a positional API key'
setup_fake_codex
run_capture /bin/bash "$SCRIPT" "$API_KEY"
assert_failure 'unexpected positional input is rejected'
assert_output_masks_key 'unexpected positional input is not echoed back'

printf '%s\n' 'test: endpoint validation accepts ports and bracketed IPv6'
for VALID_ENDPOINT in \
  'http://127.0.0.1:8080/v1' \
  'https://[2001:db8::1]:8443/v1'
do
  setup_fake_codex
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  run_capture /bin/bash "$SCRIPT" --endpoint "$VALID_ENDPOINT/" --key "$API_KEY" --yes
  assert_success "valid exact endpoint is accepted: $VALID_ENDPOINT"
  assert_file_contains "$HOME/.codex/config.toml" "base_url = \"$VALID_ENDPOINT\"" "exact valid endpoint is configured: $VALID_ENDPOINT"
  assert_output_masks_key "valid-endpoint output masks key: $VALID_ENDPOINT"
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
  'https://api.example.test\\evil/v1' \
  'https:///missing-host'
do
  setup_fake_codex
  run_capture /bin/bash "$SCRIPT" --endpoint "$INVALID_ENDPOINT" --key "$API_KEY" --yes
  assert_failure "invalid endpoint is rejected: $INVALID_ENDPOINT"
  assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" "invalid endpoint does not install: $INVALID_ENDPOINT"
  assert_output_masks_key "invalid-endpoint output masks key: $INVALID_ENDPOINT"
done

printf '%s\n' 'test: provider id validation accepts only lowercase safe identifiers'
for VALID_PROVIDER in custom team_1 team-2 abc123; do
  setup_fake_codex
  cp "$FAKE_BIN/installed-codex" "$FAKE_BIN/codex"
  run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --provider-id "$VALID_PROVIDER" --yes
  assert_success "valid provider id is accepted: $VALID_PROVIDER"
  assert_file_contains "$HOME/.codex/config.toml" "[model_providers.$VALID_PROVIDER]" "provider table uses exact id: $VALID_PROVIDER"
done
for INVALID_PROVIDER in '' Custom 'team.one' 'team/one' 'team one' '../bad'; do
  setup_fake_codex
  run_capture /bin/bash "$SCRIPT" --endpoint "$ENDPOINT" --key "$API_KEY" --provider-id "$INVALID_PROVIDER" --yes
  assert_failure "invalid provider id is rejected: $INVALID_PROVIDER"
  assert_eq '0' "$(wc -c <"$FAKE_NPM_LOG" | tr -d ' ')" "invalid provider does not install: $INVALID_PROVIDER"
done

printf '%s\n' 'test: --help is side-effect free and documents the public contract'
setup_fake_codex
run_capture /bin/bash "$SCRIPT" --help
assert_success '--help succeeds without required inputs'
case $RUN_OUTPUT in
  *'--endpoint'*'--key'*'--model'*'--provider-id'*'--reinstall'*'--dry-run'*) ;;
  *) _test_failure '--help lists all supported options' ;;
esac
assert_not_exists "$HOME/.codex" '--help does not create Codex configuration'
assert_not_exists "$(shell_rc_path)" '--help does not create shell config'

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'ok - Codex shell installer'
