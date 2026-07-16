#!/usr/bin/env bash
# shellcheck disable=SC2016

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
SCRIPT=$REPO_DIR/openclaw.sh
REAL_NODE=$(command -v node || true)

# shellcheck source=tests/testlib.sh
# shellcheck disable=SC1091
. "$TEST_DIR/testlib.sh"

ENDPOINT='https://api.example.test/v1'
API_KEY='sk-openclaw-full-secret-for-tests'
MODEL='gpt-5-mini'

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

json_assert() {
  file=$1
  message=$2
  shift 2
  if ! "$REAL_NODE" - "$file" "$@" >/dev/null 2>&1 <<'NODE'
const fs = require('fs');
const [file, provider, endpoint, model, secretPath] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(file, 'utf8'));
const alias = `ai-cli-installers-${provider}`;
const expectedApi = provider === 'openai' ? 'openai-responses' : 'anthropic-messages';
if (config.models.mode !== 'merge') throw new Error('models.mode');
if (config.models.providers[provider].baseUrl !== endpoint) throw new Error('baseUrl');
if (config.models.providers[provider].api !== expectedApi) throw new Error('api');
const models = config.models.providers[provider].models;
if (!Array.isArray(models)) throw new Error('models');
const selectedModels = models.filter((entry) => entry && entry.id === model);
if (selectedModels.length !== 1 || selectedModels[0].name !== model) throw new Error('selected model');
const secretRef = config.models.providers[provider].apiKey;
if (JSON.stringify(secretRef) !== JSON.stringify({source: 'file', provider: alias, id: 'value'})) throw new Error('apiKey SecretRef');
const providerConfig = config.secrets.providers[alias];
if (!providerConfig || providerConfig.source !== 'file' || providerConfig.path !== secretPath || providerConfig.mode !== 'singleValue') throw new Error('secret provider');
if (config.agents.defaults.model.primary !== `${provider}/${model}`) throw new Error('primary');
NODE
  then
    _test_failure "$message"
  fi
}

setup_fake_openclaw() {
  new_sandbox
  if [ -z "$REAL_NODE" ]; then
    _test_failure 'node is required to run OpenClaw installer tests'
    return 1
  fi

  PATH="$FAKE_BIN:${REAL_NODE%/*}:/usr/bin:/bin:/usr/sbin:/sbin"
  HOME=$(CDPATH='' cd -P -- "$HOME" && pwd -P)
  OPENCLAW_STATE_DIR=$HOME/.openclaw
  export PATH HOME OPENCLAW_STATE_DIR REAL_NODE

  FAKE_CURL_LOG=$SANDBOX/curl.log
  FAKE_INSTALL_LOG=$SANDBOX/install.log
  FAKE_OPENCLAW_LOG=$SANDBOX/openclaw.log
  FAKE_NODE_LOG=$SANDBOX/node.log
  FAKE_CHILD_LOG=$SANDBOX/children.log
  FAKE_CONFIG_COUNT=$SANDBOX/config-count
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_INSTALL_LOG"
  : >"$FAKE_OPENCLAW_LOG"
  : >"$FAKE_NODE_LOG"
  : >"$FAKE_CHILD_LOG"
  export FAKE_CURL_LOG FAKE_INSTALL_LOG FAKE_OPENCLAW_LOG FAKE_NODE_LOG FAKE_CHILD_LOG FAKE_CONFIG_COUNT

  make_fake_command installed-openclaw '#!/bin/sh
{
  printf "child=openclaw\n"
  env
} >>"$FAKE_CHILD_LOG"
{
  printf "argv:"
  for arg do printf " <%s>" "$arg"; done
  printf "\n"
} >>"$FAKE_OPENCLAW_LOG"
if [ "${1-}" = "--version" ]; then
  [ "${FAKE_VERSION_FAIL-}" != 1 ] || exit 43
  printf "OpenClaw fake 1.0\n"
  exit 0
fi
config_path=${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/openclaw.json}
if [ "${1-}" = "config" ] && [ "${2-}" = "file" ]; then
  reported_config=$config_path
  case $reported_config in
    "$HOME"/*) reported_config="~/${reported_config#"$HOME"/}" ;;
  esac
  printf "%s\n" "${FAKE_CONFIG_FILE_OVERRIDE:-$reported_config}"
  exit 0
fi
if [ "${1-}" = "config" ] && [ "${2-}" = "validate" ] && [ "${3-}" = "--json" ]; then
  "$REAL_NODE" - "$config_path" <<NODE
const fs = require("fs");
const path = process.argv[2];
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
function parseConfig() {
  if (!fs.existsSync(path)) return {};
  const source = fs.readFileSync(path, "utf8");
  return Function("\"use strict\"; return (" + source + "\n);")();
}
function validate(config) {
  if (!object(config)) throw new Error("root");
  if (config.models !== undefined) {
    if (!object(config.models)) throw new Error("models");
    if (config.models.providers !== undefined) {
      if (!object(config.models.providers)) throw new Error("providers");
      for (const providerConfig of Object.values(config.models.providers)) {
        if (!object(providerConfig)) throw new Error("provider");
        if (providerConfig.models !== undefined) {
          if (!Array.isArray(providerConfig.models)) throw new Error("provider models");
          for (const modelEntry of providerConfig.models) {
            if (!object(modelEntry) || typeof modelEntry.id !== "string" || !modelEntry.id || typeof modelEntry.name !== "string" || !modelEntry.name) throw new Error("model entry");
          }
        }
      }
    }
  }
  if (config.secrets !== undefined) {
    if (!object(config.secrets)) throw new Error("secrets");
    if (config.secrets.providers !== undefined) {
      if (!object(config.secrets.providers)) throw new Error("secret providers");
      for (const secretProvider of Object.values(config.secrets.providers)) {
        if (!object(secretProvider)) throw new Error("secret provider");
        if (secretProvider.source === "file" && Object.prototype.hasOwnProperty.call(secretProvider, "allowlist")) throw new Error("file provider allowlist");
      }
    }
  }
  if (config.agents !== undefined) {
    if (!object(config.agents)) throw new Error("agents");
    if (config.agents.defaults !== undefined) {
      if (!object(config.agents.defaults)) throw new Error("defaults");
      if (config.agents.defaults.model !== undefined && !object(config.agents.defaults.model)) throw new Error("default model");
    }
  }
}
try {
  validate(parseConfig());
  process.stdout.write(JSON.stringify({valid: true}) + "\n");
} catch (error) {
  process.stdout.write(JSON.stringify({valid: false}) + "\n");
  process.exit(1);
}
NODE
  exit $?
fi
if [ "${1-}" = "config" ] && [ "${2-}" = "set" ] && [ "$#" -ge 5 ]; then
  count=0
  [ ! -f "$FAKE_CONFIG_COUNT" ] || count=$(cat "$FAKE_CONFIG_COUNT")
  count=$((count + 1))
  printf "%s\n" "$count" >"$FAKE_CONFIG_COUNT"
  if [ -n "${FAKE_CONFIG_SIGNAL_AT-}" ] && [ "$count" -eq "$FAKE_CONFIG_SIGNAL_AT" ]; then
    kill -INT "$PPID"
    exit 130
  fi
  if [ -n "${FAKE_CONFIG_SET_FAIL_AT-}" ] && [ "$count" -eq "$FAKE_CONFIG_SET_FAIL_AT" ]; then
    exit 44
  fi
  config_key=$3
  config_value=$4
  config_merge=0
  for config_arg do
    [ "$config_arg" != "--merge" ] || config_merge=1
  done
  "$REAL_NODE" - "$config_path" "$config_key" "$config_value" "$config_merge" <<NODE
const fs = require("fs");
const [path, dottedKey, encodedValue, mergeFlag] = process.argv.slice(2);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const clone = (value) => JSON.parse(JSON.stringify(value));
function parseConfig() {
  if (!fs.existsSync(path)) return {};
  const source = fs.readFileSync(path, "utf8");
  return Function("\"use strict\"; return (" + source + "\n);")();
}
function merge(current, incoming, mergeArrayById) {
  if (Array.isArray(current) && Array.isArray(incoming)) {
    if (!mergeArrayById) return clone(incoming);
    const result = current.map(clone);
    for (const item of incoming) {
      if (object(item) && typeof item.id === "string") {
        const index = result.findIndex((entry) => object(entry) && entry.id === item.id);
        if (index >= 0) result[index] = merge(result[index], item, false);
        else result.push(clone(item));
      } else result.push(clone(item));
    }
    return result;
  }
  if (object(current) && object(incoming)) {
    const result = clone(current);
    for (const [key, value] of Object.entries(incoming)) {
      result[key] = Object.prototype.hasOwnProperty.call(result, key) ? merge(result[key], value, false) : clone(value);
    }
    return result;
  }
  return clone(incoming);
}
const config = parseConfig();
if (!object(config)) throw new Error("root");
const value = JSON.parse(encodedValue);
const parts = dottedKey.split(".");
let parent = config;
for (let index = 0; index < parts.length - 1; index += 1) {
  if (parent[parts[index]] === undefined) parent[parts[index]] = {};
  if (!object(parent[parts[index]])) throw new Error("path");
  parent = parent[parts[index]];
}
const leaf = parts[parts.length - 1];
const mergeArrayById = dottedKey.endsWith(".models");
parent[leaf] = mergeFlag === "1" && Object.prototype.hasOwnProperty.call(parent, leaf) ? merge(parent[leaf], value, mergeArrayById) : clone(value);
fs.mkdirSync(require("path").dirname(path), {recursive: true, mode: 0o700});
fs.writeFileSync(path, JSON.stringify(config, null, 2) + "\n", {mode: 0o600});
NODE
  exit $?
fi
exit 2'

  make_fake_command node '#!/bin/sh
{
  printf "child=node\n"
  env
} >>"$FAKE_CHILD_LOG"
{
  printf "argv:"
  for arg do printf " <%s>" "$arg"; done
  printf "\n"
} >>"$FAKE_NODE_LOG"
exec "$REAL_NODE" "$@"'

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
  "if [ \"\${FAKE_INSTALL_MUTATE_CONFIG-}\" = 1 ]; then config_path=\${OPENCLAW_CONFIG_PATH:-\$OPENCLAW_STATE_DIR/openclaw.json}; mkdir -p \"\$(dirname \"\$config_path\")\" \"\$OPENCLAW_STATE_DIR/secrets\"; printf \"{\\\"installer\\\":\\\"changed\\\"}\\n\" >\"\$config_path\"; printf \"installer-secret\" >\"\$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key\"; fi" \
  "if [ \"\${FAKE_INSTALL_FAIL-}\" = 1 ]; then exit 31; fi" \
  "if [ \"\${FAKE_INSTALL_NO_COMMAND-}\" != 1 ]; then cp \"\$FAKE_BIN/installed-openclaw\" \"\$FAKE_BIN/openclaw\"; chmod +x \"\$FAKE_BIN/openclaw\"; fi"'
}

install_existing_openclaw() {
  cp "$FAKE_BIN/installed-openclaw" "$FAKE_BIN/openclaw"
  chmod +x "$FAKE_BIN/openclaw"
}

run_unattended() {
  run_capture env \
    AI_ENDPOINT="$ENDPOINT/" \
    AI_API_KEY="$API_KEY" \
    AI_MODEL="$MODEL" \
    AI_PROVIDER=openai \
    AI_INSTALL_YES=1 \
    bash "$SCRIPT" "$@"
}

printf '%s\n' 'test: missing OpenClaw uses the stable official unattended installer and verifies the command'
setup_fake_openclaw
run_unattended
assert_success 'missing OpenClaw installation succeeds'
assert_file_contains "$FAKE_CURL_LOG" '-fsSL https://openclaw.ai/install.sh' 'stable official OpenClaw installer URL is fetched'
assert_file_contains "$FAKE_INSTALL_LOG" '<--no-prompt> <--no-onboard>' 'official installer receives non-interactive flags'
assert_file_contains "$FAKE_OPENCLAW_LOG" 'argv: <--version>' 'installed OpenClaw is verified with --version'
assert_output_masks_key 'successful install output masks the API key'
assert_file_not_contains "$FAKE_CHILD_LOG" "$API_KEY" 'API key is absent from child process environments'
assert_file_not_contains "$FAKE_NODE_LOG" "$API_KEY" 'API key is absent from Node argv'
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'new OpenClaw config has the official OpenAI SecretRef schema' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
printf '%s' "$API_KEY" >"$SANDBOX/expected-key"
assert_files_equal "$SANDBOX/expected-key" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'secret file contains the exact API key without a newline'
assert_not_exists "$OPENCLAW_STATE_DIR/agents/main/agent/auth-profiles.json" 'installer does not create the retired auth-profiles.json'
assert_file_not_contains "$OPENCLAW_STATE_DIR/openclaw.json" "$API_KEY" 'API key is absent from openclaw.json'

printf '%s\n' 'test: an inherited exported lowercase shell variable cannot leak the replacement API key'
setup_fake_openclaw
run_capture env \
  api_key='inherited-placeholder' \
  AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 \
  bash "$SCRIPT"
assert_success 'configuration succeeds with an inherited exported lowercase api_key variable'
assert_file_not_contains "$FAKE_CHILD_LOG" "$API_KEY" 'replacement API key is not inherited through the lowercase shell variable export attribute'
assert_output_masks_key 'lowercase-variable regression output masks the API key'

printf '%s\n' 'test: existing OpenClaw unattended skips update while --reinstall forces it'
setup_fake_openclaw
install_existing_openclaw
run_unattended
assert_success 'existing OpenClaw unattended configuration succeeds'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" '--yes skips update of an existing OpenClaw command'
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'skipped installation still configures OpenClaw' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"

setup_fake_openclaw
install_existing_openclaw
run_unattended --reinstall
assert_success 'forced OpenClaw reinstall succeeds'
assert_file_contains "$FAKE_INSTALL_LOG" '<--no-prompt> <--no-onboard>' '--reinstall executes the official installer'
assert_output_masks_key 'reinstall output masks the API key'

printf '%s\n' 'test: dry-run validates without installation or filesystem writes'
setup_fake_openclaw
run_unattended --dry-run
assert_success 'OpenClaw dry-run succeeds'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'dry-run does not fetch an installer'
assert_not_exists "$OPENCLAW_STATE_DIR" 'dry-run does not create the OpenClaw state directory'
assert_output_masks_key 'dry-run output masks the API key'

printf '%s\n' 'test: unattended mode requires provider, endpoint, key, and model before side effects'
for MISSING in provider endpoint key model; do
  setup_fake_openclaw
  case $MISSING in
    provider)
      run_capture env -u AI_PROVIDER AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT"
      ;;
    endpoint)
      run_capture env AI_PROVIDER=openai AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT"
      ;;
    key)
      run_capture env AI_PROVIDER=openai AI_ENDPOINT="$ENDPOINT" AI_MODEL="$MODEL" AI_INSTALL_YES=1 bash "$SCRIPT"
      ;;
    model)
      run_capture env AI_PROVIDER=openai AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_INSTALL_YES=1 bash "$SCRIPT"
      ;;
  esac
  assert_failure "unattended mode fails when $MISSING is missing"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "missing $MISSING does not invoke installer"
  assert_not_exists "$OPENCLAW_STATE_DIR" "missing $MISSING does not write"
  assert_output_masks_key "missing $MISSING output masks the API key"
done

printf '%s\n' 'test: OpenAI and Anthropic modes produce their official transport and SecretRef schemas'
for PROVIDER in openai anthropic; do
  setup_fake_openclaw
  install_existing_openclaw
  if [ "$PROVIDER" = openai ]; then
    PROVIDER_MODEL='gpt-5-mini'
  else
    PROVIDER_MODEL='claude-sonnet-4-5'
  fi
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" \
    --provider "$PROVIDER" --endpoint "$ENDPOINT/" --key "$API_KEY" --model "$PROVIDER_MODEL"
  assert_success "$PROVIDER configuration succeeds"
  json_assert "$OPENCLAW_STATE_DIR/openclaw.json" "$PROVIDER config uses the expected transport and SecretRefs" \
    "$PROVIDER" "$ENDPOINT" "$PROVIDER_MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-$PROVIDER-api-key"
  printf '%s' "$API_KEY" >"$SANDBOX/expected-$PROVIDER-key"
  assert_files_equal "$SANDBOX/expected-$PROVIDER-key" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-$PROVIDER-api-key" "$PROVIDER secret remains exact"
done

printf '%s\n' 'test: official CLI accepts JSON5 and preserves unrelated semantics during merge'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR"
cat >"$OPENCLAW_STATE_DIR/openclaw.json" <<'JSON5'
{
  // OpenClaw config is JSON5, not strict JSON.
  unrelated: {format: "json5", keep: true,},
  models: {
    providers: {
      openai: {
        customProviderField: "keep-json5-provider",
        models: [
          {id: "gpt-5-mini", name: "Old JSON5 name", contextWindow: 99999,},
          {id: "other-json5-model", name: "Other JSON5 model", custom: true,},
        ],
      },
    },
  },
}
JSON5
run_unattended
assert_success 'valid JSON5 config is accepted through the official CLI'
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'JSON5 config receives managed OpenClaw settings' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
if ! "$REAL_NODE" - "$OPENCLAW_STATE_DIR/openclaw.json" >/dev/null 2>&1 <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (c.unrelated.format !== 'json5' || c.unrelated.keep !== true) throw new Error('unrelated JSON5');
if (c.models.providers.openai.customProviderField !== 'keep-json5-provider') throw new Error('provider metadata');
const target = c.models.providers.openai.models.find((entry) => entry.id === 'gpt-5-mini');
const other = c.models.providers.openai.models.find((entry) => entry.id === 'other-json5-model');
if (!target || target.contextWindow !== 99999 || !other || other.custom !== true) throw new Error('model metadata');
NODE
then
  _test_failure 'official JSON5 merge preserves unrelated, provider, and model semantics'
fi

printf '%s\n' 'test: OPENCLAW_CONFIG_PATH selects the active config and participates in backup and rollback'
setup_fake_openclaw
install_existing_openclaw
OPENCLAW_CONFIG_PATH=$HOME/custom-config/active.json5
export OPENCLAW_CONFIG_PATH
mkdir -p "${OPENCLAW_CONFIG_PATH%/*}" "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{customActive: "keep",}' >"$OPENCLAW_CONFIG_PATH"
printf '%s' 'custom-old-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
run_unattended
assert_success 'custom active OpenClaw config is updated'
json_assert "$OPENCLAW_CONFIG_PATH" 'custom active config receives managed settings' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
assert_not_exists "$OPENCLAW_STATE_DIR/openclaw.json" 'default state config is not created when OPENCLAW_CONFIG_PATH is active'
assert_file_contains "$OPENCLAW_CONFIG_PATH.ai-cli-installers.bak" 'customActive' 'custom active config is backed up at its own path'

printf '%s\n' '{customActive: "rollback-original",}' >"$OPENCLAW_CONFIG_PATH"
printf '%s' 'custom-rollback-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
cp "$OPENCLAW_CONFIG_PATH" "$SANDBOX/custom-config-before-failure"
cp "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" "$SANDBOX/custom-secret-before-failure"
printf '%s\n' '0' >"$FAKE_CONFIG_COUNT"
run_capture env FAKE_CONFIG_SET_FAIL_AT=3 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_failure 'official config set failure on a custom active config is reported'
assert_files_equal "$SANDBOX/custom-config-before-failure" "$OPENCLAW_CONFIG_PATH" 'custom active config rolls back byte-for-byte'
assert_files_equal "$SANDBOX/custom-secret-before-failure" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'custom active secret rolls back byte-for-byte'
unset OPENCLAW_CONFIG_PATH

printf '%s\n' 'test: official validation rejects schema errors before reinstall and runs during dry-run'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR"
printf '%s\n' '{models: {providers: {openai: {models: "not-an-array",},},},}' >"$OPENCLAW_STATE_DIR/openclaw.json"
cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/schema-invalid-before"
run_unattended --reinstall
assert_failure 'schema-invalid selected provider is rejected'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'official validation rejects schema error before reinstall fetch'
assert_files_equal "$SANDBOX/schema-invalid-before" "$OPENCLAW_STATE_DIR/openclaw.json" 'schema-invalid config remains byte-for-byte unchanged'
assert_not_exists "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'existing-CLI validation fails before backup'
assert_file_contains "$FAKE_OPENCLAW_LOG" 'argv: <config> <validate> <--json>' 'official full-schema validation is invoked'

setup_fake_openclaw
install_existing_openclaw
run_unattended --dry-run
assert_success 'dry-run with an existing CLI succeeds after read-only validation'
assert_file_contains "$FAKE_OPENCLAW_LOG" 'argv: <config> <validate> <--json>' 'dry-run invokes official read-only validation'
if grep -F 'argv: <config> <set>' "$FAKE_OPENCLAW_LOG" >/dev/null 2>&1; then
  _test_failure 'dry-run does not invoke official config writers'
fi

printf '%s\n' 'test: missing CLI backs up raw config before install, then official validation can reject it safely'
setup_fake_openclaw
mkdir -p "$OPENCLAW_STATE_DIR"
printf '%s\n' '{models: {providers: {openai: {models: [{id: 123, name: "invalid id",},],},},},}' >"$OPENCLAW_STATE_DIR/openclaw.json"
cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/pre-install-invalid-config"
run_unattended
assert_failure 'post-install official validation rejects an invalid model entry'
assert_file_contains "$FAKE_CURL_LOG" 'https://openclaw.ai/install.sh' 'missing CLI is installed before official validation becomes available'
assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'invalid id' 'raw pre-install config backup is retained'
assert_files_equal "$SANDBOX/pre-install-invalid-config" "$OPENCLAW_STATE_DIR/openclaw.json" 'post-install validation failure restores exact raw config bytes'
assert_not_exists "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'post-install validation failure writes no secret'

printf '%s\n' 'test: dangerous state directories are rejected before any mkdir, chmod, or installer action'
for DANGEROUS_KIND in root dot dot-slash traversal home pwd; do
  setup_fake_openclaw
  install_existing_openclaw
  case $DANGEROUS_KIND in
    root) DANGEROUS_STATE=/ ;;
    dot) DANGEROUS_STATE=. ;;
    dot-slash) DANGEROUS_STATE=./ ;;
    traversal) DANGEROUS_STATE=$SANDBOX/state/../escape ;;
    home) DANGEROUS_STATE=$HOME ;;
    pwd) DANGEROUS_STATE=$(pwd -P) ;;
  esac
  FAKE_MUTATION_LOG=$SANDBOX/mutation.log
  : >"$FAKE_MUTATION_LOG"
  export FAKE_MUTATION_LOG
  make_fake_command mkdir '#!/bin/sh
printf "mkdir %s\n" "$*" >>"$FAKE_MUTATION_LOG"
exit 97'
  make_fake_command chmod '#!/bin/sh
printf "chmod %s\n" "$*" >>"$FAKE_MUTATION_LOG"
exit 98'
  run_capture env OPENCLAW_STATE_DIR="$DANGEROUS_STATE" AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
  assert_failure "dangerous state is rejected: $DANGEROUS_STATE"
  assert_eq '0' "$(wc -c <"$FAKE_MUTATION_LOG" | tr -d ' ')" "dangerous state triggers no mkdir or chmod: $DANGEROUS_STATE"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "dangerous state triggers no installer fetch: $DANGEROUS_STATE"
done

setup_fake_openclaw
install_existing_openclaw
ln -s / "$SANDBOX/root-state-link"
FAKE_MUTATION_LOG=$SANDBOX/mutation.log
: >"$FAKE_MUTATION_LOG"
export FAKE_MUTATION_LOG
make_fake_command mkdir '#!/bin/sh
printf "mkdir %s\n" "$*" >>"$FAKE_MUTATION_LOG"
exit 97'
make_fake_command chmod '#!/bin/sh
printf "chmod %s\n" "$*" >>"$FAKE_MUTATION_LOG"
exit 98'
run_capture env OPENCLAW_STATE_DIR="$SANDBOX/root-state-link" AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_failure 'state symlink resolving to root is rejected'
assert_eq '0' "$(wc -c <"$FAKE_MUTATION_LOG" | tr -d ' ')" 'root-resolving state symlink triggers no mkdir or chmod'

printf '%s\n' 'test: merge preserves unrelated config and selected-provider metadata while updating managed fields'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets" "$OPENCLAW_STATE_DIR/agents/main/agent"
cat >"$OPENCLAW_STATE_DIR/openclaw.json" <<'JSON'
{
  "unrelated": {"nested": "keep-me"},
  "models": {
    "mode": "replace",
    "unrelatedModelSetting": 17,
    "providers": {
      "other": {"baseUrl": "https://other.example.test", "custom": true},
      "openai": {
        "customProviderField": {"nested": "keep-provider-metadata"},
        "models": [
          {"id": "other-model", "name": "Other model", "custom": "keep-other-model"},
          {"id": "gpt-5-mini", "name": "Old target name", "contextWindow": 123456, "custom": "keep-target-metadata"}
        ]
      }
    }
  },
  "secrets": {
    "unrelatedSecretSetting": true,
    "providers": {
      "other-secret": {"source": "env", "allowlist": ["OTHER_KEY"]},
      "ai-cli-installers-openai": {"source": "env", "allowlist": ["OLD_KEY"]}
    }
  },
  "agents": {"defaults": {"model": {"primary": "old/model", "fallbacks": ["keep/model"]}, "workspace": "keep-workspace"}}
}
JSON
printf '%s' 'old-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
printf '%s\n' '{"legacy":"leave-byte-for-byte"}' >"$OPENCLAW_STATE_DIR/agents/main/agent/auth-profiles.json"
cp "$OPENCLAW_STATE_DIR/agents/main/agent/auth-profiles.json" "$SANDBOX/original-auth-profiles"
run_unattended
assert_success 'merge into a populated config succeeds'
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'selected provider and secret alias receive current managed fields' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
if ! "$REAL_NODE" - "$OPENCLAW_STATE_DIR/openclaw.json" >/dev/null 2>&1 <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (c.unrelated.nested !== 'keep-me') throw new Error('unrelated root');
if (c.models.unrelatedModelSetting !== 17 || c.models.providers.other.custom !== true) throw new Error('unrelated models');
if (c.models.providers.openai.customProviderField.nested !== 'keep-provider-metadata') throw new Error('selected provider metadata');
const other = c.models.providers.openai.models.find((entry) => entry.id === 'other-model');
if (!other || other.name !== 'Other model' || other.custom !== 'keep-other-model') throw new Error('non-target model');
const target = c.models.providers.openai.models.find((entry) => entry.id === 'gpt-5-mini');
if (!target || target.name !== 'gpt-5-mini' || target.contextWindow !== 123456 || target.custom !== 'keep-target-metadata') throw new Error('target model metadata');
if (c.secrets.unrelatedSecretSetting !== true || c.secrets.providers['other-secret'].source !== 'env') throw new Error('unrelated secrets');
if (Object.prototype.hasOwnProperty.call(c.secrets.providers['ai-cli-installers-openai'], 'allowlist')) throw new Error('obsolete selected secret allowlist');
if (c.agents.defaults.workspace !== 'keep-workspace' || c.agents.defaults.model.fallbacks[0] !== 'keep/model') throw new Error('agent settings');
NODE
then
  _test_failure 'merge preserves unrelated root, selected-provider metadata, non-target models, target metadata, secrets, and agent settings'
fi
assert_files_equal "$SANDBOX/original-auth-profiles" "$OPENCLAW_STATE_DIR/agents/main/agent/auth-profiles.json" 'retired auth-profiles.json remains byte-for-byte unchanged'
assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'keep-provider-metadata' 'pre-merge config backup is retained'
assert_file_contains "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key.ai-cli-installers.bak" 'old-secret' 'pre-merge secret backup is retained'

printf '%s\n' 'test: a missing target model is appended without changing existing provider models'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR"
cat >"$OPENCLAW_STATE_DIR/openclaw.json" <<'JSON'
{
  "models": {
    "providers": {
      "openai": {
        "customProviderField": "keep-provider",
        "models": [
          {"id": "existing-model", "name": "Existing", "contextWindow": 777, "custom": {"keep": true}}
        ]
      }
    }
  }
}
JSON
run_unattended
assert_success 'configuration appends a missing target model'
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'appended target model receives current managed fields' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
if ! "$REAL_NODE" - "$OPENCLAW_STATE_DIR/openclaw.json" >/dev/null 2>&1 <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const provider = c.models.providers.openai;
if (provider.customProviderField !== 'keep-provider') throw new Error('provider field');
if (provider.models.length !== 2) throw new Error('model count');
const existing = provider.models.find((entry) => entry.id === 'existing-model');
if (!existing || existing.name !== 'Existing' || existing.contextWindow !== 777 || existing.custom.keep !== true) throw new Error('existing model');
const added = provider.models.find((entry) => entry.id === 'gpt-5-mini');
if (!added || added.name !== 'gpt-5-mini') throw new Error('added model');
NODE
then
  _test_failure 'missing-target merge preserves the existing provider and model while appending the target'
fi

printf '%s\n' 'test: malformed or structurally unsafe JSON fails before installer, backup, or mutation'
for BAD_JSON in '{malformed' '{"models":[]}' '{"models":{"providers":[]}}' '{"secrets":{"providers":[]}}' '{"agents":{"defaults":{"model":[]}}}'; do
  setup_fake_openclaw
  install_existing_openclaw
  mkdir -p "$OPENCLAW_STATE_DIR"
  printf '%s\n' "$BAD_JSON" >"$OPENCLAW_STATE_DIR/openclaw.json"
  cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/original-bad-json"
  run_unattended
  assert_failure 'unsafe existing JSON is rejected'
  assert_files_equal "$SANDBOX/original-bad-json" "$OPENCLAW_STATE_DIR/openclaw.json" 'unsafe JSON remains byte-for-byte unchanged'
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'unsafe JSON blocks installer fetch'
  assert_not_exists "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'unsafe JSON fails before backup creation'
  assert_output_masks_key 'unsafe JSON failure masks the API key'
done

printf '%s\n' 'test: backups precede installer and discard unexpected installer config mutations'
setup_fake_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{"original":"before-installer"}' >"$OPENCLAW_STATE_DIR/openclaw.json"
printf '%s' 'original-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
run_capture env FAKE_INSTALL_MUTATE_CONFIG=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_success 'configuration succeeds when the no-onboard installer unexpectedly touches managed files'
assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'before-installer' 'config backup contains pre-installer bytes'
assert_file_contains "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key.ai-cli-installers.bak" 'original-secret' 'secret backup contains pre-installer bytes'
assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json" 'before-installer' 'original config is restored before merge'
assert_file_not_contains "$OPENCLAW_STATE_DIR/openclaw.json" '"installer"' 'installer config mutation is discarded'

printf '%s\n' 'test: installer and version failures roll managed files back to their original bytes'
for FAILURE_KIND in installer version; do
  setup_fake_openclaw
  mkdir -p "$OPENCLAW_STATE_DIR/secrets"
  printf '%s\n' '{"original":"rollback"}' >"$OPENCLAW_STATE_DIR/openclaw.json"
  printf '%s' 'rollback-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
  cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/pre-failure-config"
  cp "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" "$SANDBOX/pre-failure-secret"
  if [ "$FAILURE_KIND" = installer ]; then
    run_capture env FAKE_INSTALL_MUTATE_CONFIG=1 FAKE_INSTALL_FAIL=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
  else
    run_capture env FAKE_INSTALL_MUTATE_CONFIG=1 FAKE_VERSION_FAIL=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
  fi
  assert_failure "$FAILURE_KIND failure is reported"
  assert_files_equal "$SANDBOX/pre-failure-config" "$OPENCLAW_STATE_DIR/openclaw.json" "$FAILURE_KIND failure restores config bytes"
  assert_files_equal "$SANDBOX/pre-failure-secret" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" "$FAILURE_KIND failure restores secret bytes"
  assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'rollback' "$FAILURE_KIND retains config backup"
  assert_output_masks_key "$FAILURE_KIND failure output masks the API key"
done

printf '%s\n' 'test: a config merge failure rolls secret and config back, including initially absent files'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{"original":"merge-rollback"}' >"$OPENCLAW_STATE_DIR/openclaw.json"
printf '%s' 'merge-rollback-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/pre-merge-config"
cp "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" "$SANDBOX/pre-merge-secret"
run_capture env FAKE_CONFIG_SET_FAIL_AT=3 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_failure 'simulated official config set failure is reported'
assert_files_equal "$SANDBOX/pre-merge-config" "$OPENCLAW_STATE_DIR/openclaw.json" 'merge failure restores config bytes'
assert_files_equal "$SANDBOX/pre-merge-secret" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'merge failure restores secret bytes'

setup_fake_openclaw
install_existing_openclaw
run_capture env FAKE_CONFIG_SET_FAIL_AT=3 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_failure 'official config set failure from an empty state is reported'
assert_not_exists "$OPENCLAW_STATE_DIR/openclaw.json" 'empty-state rollback removes partial config'
assert_not_exists "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'empty-state rollback removes partial secret'

printf '%s\n' 'test: SIGINT during official config writes restores originals and cleans transaction temporaries'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{signalOriginal: true,}' >"$OPENCLAW_STATE_DIR/openclaw.json"
printf '%s' 'signal-original-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
cp "$OPENCLAW_STATE_DIR/openclaw.json" "$SANDBOX/pre-signal-config"
cp "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" "$SANDBOX/pre-signal-secret"
run_capture env FAKE_CONFIG_SIGNAL_AT=3 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_eq '130' "$RUN_STATUS" 'SIGINT exits with status 130'
assert_files_equal "$SANDBOX/pre-signal-config" "$OPENCLAW_STATE_DIR/openclaw.json" 'SIGINT restores raw config bytes'
assert_files_equal "$SANDBOX/pre-signal-secret" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" 'SIGINT restores secret bytes'
assert_file_contains "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak" 'signalOriginal' 'SIGINT retains the private config backup'
if find "$OPENCLAW_STATE_DIR" -name '*.ai-cli-installers.tmp.*' -print | grep . >/dev/null 2>&1; then
  _test_failure 'SIGINT leaves no transaction temporary files'
fi

printf '%s\n' 'test: a normal relative state path is normalized and SecretRef uses an absolute path'
setup_fake_openclaw
install_existing_openclaw
RUN_CWD=$SANDBOX/relative-work
mkdir -p "$RUN_CWD"
export RUN_CWD SCRIPT
run_capture env \
  OPENCLAW_STATE_DIR=relative-state \
  AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 \
  bash -c 'cd "$RUN_CWD" && exec bash "$SCRIPT"'
assert_success 'normal relative state directory is accepted and normalized'
RELATIVE_STATE=$(CDPATH='' cd -P -- "$RUN_CWD" && pwd -P)/relative-state
json_assert "$RELATIVE_STATE/openclaw.json" 'relative state config receives an absolute SecretRef path' \
  openai "$ENDPOINT" "$MODEL" "$RELATIVE_STATE/secrets/ai-cli-installers-openai-api-key"
case $("$REAL_NODE" -e 'const fs=require("fs"); const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(c.secrets.providers["ai-cli-installers-openai"].path);' "$RELATIVE_STATE/openclaw.json") in
  /*) ;;
  *) _test_failure 'relative state SecretRef path is absolute' ;;
esac

printf '%s\n' 'test: repeated configuration is idempotent and creates unique private backups'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{"seed":true}' >"$OPENCLAW_STATE_DIR/openclaw.json"
printf '%s' 'old-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
run_unattended
assert_success 'first OpenClaw configuration succeeds'
run_unattended
assert_success 'second OpenClaw configuration succeeds'
if [ ! -f "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak.1" ]; then
  _test_failure 'repeat run creates a unique second config backup'
fi
if [ ! -f "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key.ai-cli-installers.bak.1" ]; then
  _test_failure 'repeat run creates a unique second secret backup'
fi
json_assert "$OPENCLAW_STATE_DIR/openclaw.json" 'repeat run keeps one canonical selected provider configuration' \
  openai "$ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"

printf '%s\n' 'test: active config and managed secret symlinks fail closed before installation'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/real" "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{"linked":"config"}' >"$OPENCLAW_STATE_DIR/real/config.json"
printf '%s' 'linked-secret' >"$OPENCLAW_STATE_DIR/real/key"
ln -s 'real/config.json' "$OPENCLAW_STATE_DIR/openclaw.json"
ln -s '../real/key' "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
run_unattended
assert_failure 'official active config symlink is rejected'
assert_symlink_points_to "$OPENCLAW_STATE_DIR/openclaw.json" 'real/config.json' 'config symlink remains unchanged after rejection'
assert_symlink_points_to "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" '../real/key' 'secret symlink remains unchanged after rejection'
assert_file_contains "$OPENCLAW_STATE_DIR/real/config.json" '"linked":"config"' 'linked config target remains unchanged'
assert_file_contains "$OPENCLAW_STATE_DIR/real/key" 'linked-secret' 'linked secret target remains unchanged'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'managed symlinks are rejected before installer fetch'

printf '%s\n' 'test: broken or cyclic managed-file symlinks fail before installation'
setup_fake_openclaw
mkdir -p "$OPENCLAW_STATE_DIR"
ln -s 'missing.json' "$OPENCLAW_STATE_DIR/openclaw.json"
run_unattended
assert_failure 'broken config symlink causes a safe failure'
assert_symlink_points_to "$OPENCLAW_STATE_DIR/openclaw.json" 'missing.json' 'broken config symlink is unchanged'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'broken config symlink blocks installer fetch'

setup_fake_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets" "$OPENCLAW_STATE_DIR/real"
ln -s '../real/key-cycle' "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
ln -s '../secrets/ai-cli-installers-openai-api-key' "$OPENCLAW_STATE_DIR/real/key-cycle"
run_unattended
assert_failure 'cyclic secret symlink causes a safe failure'
assert_symlink_points_to "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key" '../real/key-cycle' 'cyclic secret symlink is unchanged'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'cyclic secret symlink blocks installer fetch'

printf '%s\n' 'test: state, secrets, config, secret, and backups are private and temporary files are cleaned'
setup_fake_openclaw
install_existing_openclaw
mkdir -p "$OPENCLAW_STATE_DIR/secrets"
chmod 755 "$OPENCLAW_STATE_DIR" "$OPENCLAW_STATE_DIR/secrets"
printf '%s\n' '{"seed":"mode"}' >"$OPENCLAW_STATE_DIR/openclaw.json"
printf '%s' 'mode-secret' >"$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
chmod 644 "$OPENCLAW_STATE_DIR/openclaw.json" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
run_unattended
assert_success 'private-mode configuration succeeds'
assert_eq '700' "$(file_mode "$OPENCLAW_STATE_DIR")" 'OpenClaw state directory is private'
assert_eq '700' "$(file_mode "$OPENCLAW_STATE_DIR/secrets")" 'OpenClaw secrets directory is private'
assert_eq '600' "$(file_mode "$OPENCLAW_STATE_DIR/openclaw.json")" 'config mode is private'
assert_eq '600' "$(file_mode "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key")" 'secret mode is private'
assert_eq '600' "$(file_mode "$OPENCLAW_STATE_DIR/openclaw.json.ai-cli-installers.bak")" 'config backup mode is private'
assert_eq '600' "$(file_mode "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key.ai-cli-installers.bak")" 'secret backup mode is private'
if find "$OPENCLAW_STATE_DIR" -name '*.ai-cli-installers.tmp.*' -print | grep . >/dev/null 2>&1; then
  _test_failure 'configuration leaves no temporary files behind'
fi

printf '%s\n' 'test: installation must produce a verifiable OpenClaw command'
setup_fake_openclaw
run_capture env FAKE_INSTALL_NO_COMMAND=1 AI_ENDPOINT="$ENDPOINT" AI_API_KEY="$API_KEY" AI_MODEL="$MODEL" AI_PROVIDER=openai AI_INSTALL_YES=1 bash "$SCRIPT"
assert_failure 'installer success without OpenClaw fails verification'
assert_not_exists "$OPENCLAW_STATE_DIR/openclaw.json" 'configuration does not remain after install verification failure'
assert_output_masks_key 'verification failure output masks the API key'

printf '%s\n' 'test: endpoint, provider, model, and key validation reject unsafe values before writes'
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
  setup_fake_openclaw
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --provider openai --endpoint "$INVALID_ENDPOINT" --key "$API_KEY" --model "$MODEL"
  assert_failure "invalid endpoint is rejected: $INVALID_ENDPOINT"
  assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "invalid endpoint does not fetch: $INVALID_ENDPOINT"
  assert_not_exists "$OPENCLAW_STATE_DIR" "invalid endpoint does not write: $INVALID_ENDPOINT"
done

for INVALID_PROVIDER in custom OPENAI 'open ai' ''; do
  setup_fake_openclaw
  run_capture env -u AI_PROVIDER AI_INSTALL_YES=1 bash "$SCRIPT" --provider "$INVALID_PROVIDER" --endpoint "$ENDPOINT" --key "$API_KEY" --model "$MODEL"
  assert_failure "invalid provider is rejected: $INVALID_PROVIDER"
  assert_not_exists "$OPENCLAW_STATE_DIR" "invalid provider does not write: $INVALID_PROVIDER"
done

for INVALID_MODEL in '' 'bad model' 'bad?model' 'bad#model' '../escape' '.hidden' '-flag'; do
  setup_fake_openclaw
  run_capture env -u AI_MODEL AI_INSTALL_YES=1 bash "$SCRIPT" --provider openai --endpoint "$ENDPOINT" --key "$API_KEY" --model "$INVALID_MODEL"
  assert_failure "invalid model is rejected: $INVALID_MODEL"
  assert_not_exists "$OPENCLAW_STATE_DIR" "invalid model does not write: $INVALID_MODEL"
done

setup_fake_openclaw
NON_ASCII_KEY='clé-secret'
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --provider openai --endpoint "$ENDPOINT" --key "$NON_ASCII_KEY" --model "$MODEL"
assert_failure 'non-ASCII API key is rejected'
assert_not_exists "$OPENCLAW_STATE_DIR" 'non-ASCII API key does not write'
case $RUN_OUTPUT in
  *"$NON_ASCII_KEY"*) _test_failure 'non-ASCII API key is not echoed' ;;
esac

setup_fake_openclaw
run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" "$API_KEY"
assert_failure 'unexpected positional argument is rejected'
assert_output_masks_key 'positional parse error does not echo the supplied value'
assert_eq '0' "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" 'positional parse error does not fetch installer'

printf '%s\n' 'test: host ports and bracketed IPv6 endpoints are accepted exactly'
for VALID_ENDPOINT in 'http://127.0.0.1:8080/v1' 'https://[2001:db8::1]:8443/v1'; do
  setup_fake_openclaw
  install_existing_openclaw
  run_capture env AI_INSTALL_YES=1 bash "$SCRIPT" --provider openai --endpoint "$VALID_ENDPOINT/" --key "$API_KEY" --model "$MODEL"
  assert_success "valid endpoint is accepted: $VALID_ENDPOINT"
  json_assert "$OPENCLAW_STATE_DIR/openclaw.json" "endpoint is configured exactly: $VALID_ENDPOINT" \
    openai "$VALID_ENDPOINT" "$MODEL" "$OPENCLAW_STATE_DIR/secrets/ai-cli-installers-openai-api-key"
done

printf '%s\n' 'test: help is side-effect free, generic, and contains only the official hard-coded HTTPS URL'
setup_fake_openclaw
run_capture bash "$SCRIPT" --help
assert_success 'OpenClaw help succeeds without inputs'
assert_not_exists "$OPENCLAW_STATE_DIR" 'help does not create the OpenClaw state directory'
case $RUN_OUTPUT in
  *'OpenAI or Anthropic compatible endpoint'*) ;;
  *) _test_failure 'help describes generic OpenAI and Anthropic compatible endpoints' ;;
esac
for DEPLOYMENT_PLACEHOLDER in SITE_NAME SITE_DOMAIN AI_HOST PROVIDER_ID_PREFIX; do
  assert_file_not_contains "$SCRIPT" "$DEPLOYMENT_PLACEHOLDER" "installer does not depend on deployment placeholder: $DEPLOYMENT_PLACEHOLDER"
done
HARDCODED_HTTPS_URLS=$(grep -Eo 'https://[A-Za-z0-9._/-]+' "$SCRIPT" | sort -u)
assert_eq 'https://openclaw.ai/install.sh' "$HARDCODED_HTTPS_URLS" 'the official OpenClaw installer is the only hard-coded HTTPS endpoint'

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'ok - OpenClaw shell installer'
