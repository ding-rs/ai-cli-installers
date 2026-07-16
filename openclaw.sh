#!/usr/bin/env bash

set -u
set -o pipefail
LC_ALL=C
export LC_ALL

PROGRAM_NAME=${0##*/}
INSTALL_URL='https://openclaw.ai/install.sh'
TEMP_FILE=
TRANSACTION_ACTIVE=0
TTY_ECHO_DISABLED=0

endpoint=${AI_ENDPOINT-}
api_key=${AI_API_KEY-}
model=${AI_MODEL-}
provider=${AI_PROVIDER-}
unset AI_API_KEY
export -n api_key 2>/dev/null || true

assume_yes=0
reinstall=0
dry_run=0
if [ "${AI_INSTALL_YES-}" = 1 ]; then
  assume_yes=1
fi

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options]

Install and configure OpenClaw for an OpenAI or Anthropic compatible endpoint.

Options:
  --provider NAME      Provider: openai or anthropic (or set AI_PROVIDER)
  --endpoint URL       Exact API base URL (or set AI_ENDPOINT)
  --key KEY            API key (or set AI_API_KEY)
  --model MODEL        Default model identifier (or set AI_MODEL)
  --yes, -y            Run unattended; skip updating an existing installation
  --reinstall          Force installation or update
  --dry-run            Validate and describe actions without making changes
  --help               Show this help

Set AI_INSTALL_YES=1 as an alternative to --yes.
EOF
}

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

restore_tty() {
  if [ "$TTY_ECHO_DISABLED" -eq 1 ]; then
    stty echo </dev/tty 2>/dev/null || true
    TTY_ECHO_DISABLED=0
    printf '\n' >/dev/tty 2>/dev/null || true
  fi
}

cleanup() {
  restore_tty
  if [ "$TRANSACTION_ACTIVE" -eq 1 ]; then
    TRANSACTION_ACTIVE=0
    rollback_configuration
  fi
  if [ -n "$TEMP_FILE" ] && { [ -e "$TEMP_FILE" ] || [ -L "$TEMP_FILE" ]; }; then
    rm -f -- "$TEMP_FILE"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case $1 in
    --provider)
      [ "$#" -ge 2 ] || die '--provider requires a value'
      provider=$2
      shift 2
      ;;
    --provider=*)
      provider=${1#--provider=}
      shift
      ;;
    --endpoint)
      [ "$#" -ge 2 ] || die '--endpoint requires a value'
      endpoint=$2
      shift 2
      ;;
    --endpoint=*)
      endpoint=${1#--endpoint=}
      shift
      ;;
    --key)
      [ "$#" -ge 2 ] || die '--key requires a value'
      api_key=$2
      shift 2
      ;;
    --key=*)
      api_key=${1#--key=}
      shift
      ;;
    --model)
      [ "$#" -ge 2 ] || die '--model requires a value'
      model=$2
      shift 2
      ;;
    --model=*)
      model=${1#--model=}
      shift
      ;;
    --yes|-y)
      assume_yes=1
      shift
      ;;
    --reinstall)
      reinstall=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*|*)
      die 'unknown option or unexpected positional argument; use --help for supported syntax'
      ;;
  esac
done

[ "$#" -eq 0 ] || die 'unknown option or unexpected positional argument; use --help for supported syntax'

can_prompt() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

prompt_value() {
  local prompt_name variable_name value
  prompt_name=$1
  variable_name=$2
  can_prompt || die "$prompt_name is required; pass the corresponding option or environment variable"
  printf '%s: ' "$prompt_name" >/dev/tty
  IFS= read -r value </dev/tty || die "could not read $prompt_name from the terminal"
  printf -v "$variable_name" '%s' "$value"
}

prompt_key() {
  can_prompt || die 'API key is required; pass --key or set AI_API_KEY'
  printf 'API key: ' >/dev/tty
  if ! stty -echo </dev/tty 2>/dev/null; then
    die 'could not disable terminal echo while reading the API key'
  fi
  TTY_ECHO_DISABLED=1
  if ! IFS= read -r api_key </dev/tty; then
    restore_tty
    die 'could not read API key from the terminal'
  fi
  restore_tty
}

if [ -z "$provider" ]; then
  if [ "$assume_yes" -eq 1 ]; then
    die 'provider is required in unattended mode; pass --provider or set AI_PROVIDER'
  fi
  prompt_value 'Provider (openai or anthropic)' provider
fi

if [ -z "$endpoint" ]; then
  if [ "$assume_yes" -eq 1 ]; then
    die 'endpoint is required in unattended mode; pass --endpoint or set AI_ENDPOINT'
  fi
  prompt_value 'Exact API endpoint' endpoint
fi

if [ -z "$api_key" ]; then
  if [ "$assume_yes" -eq 1 ]; then
    die 'API key is required in unattended mode; pass --key or set AI_API_KEY'
  fi
  prompt_key
fi

if [ -z "$model" ]; then
  if [ "$assume_yes" -eq 1 ]; then
    die 'model is required in unattended mode; pass --model or set AI_MODEL'
  fi
  prompt_value 'Default model' model
fi

while [ "${endpoint%/}" != "$endpoint" ]; do
  endpoint=${endpoint%/}
done

validate_numeric_port() {
  [ -n "$1" ] || return 1
  case $1 in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

validate_authority() {
  local authority host port literal suffix
  authority=$1
  [ -n "$authority" ] || return 1
  case $authority in
    *@*|*\\*) return 1 ;;
  esac

  case $authority in
    \[* )
      case $authority in
        *\]*) ;;
        *) return 1 ;;
      esac
      literal=${authority#\[}
      literal=${literal%%\]*}
      suffix=${authority#*\]}
      [ -n "$literal" ] || return 1
      case $literal in
        *:*) ;;
        *) return 1 ;;
      esac
      case $literal in
        *[!0-9A-Fa-f:.]*) return 1 ;;
      esac
      case $suffix in
        '') ;;
        :*)
          port=${suffix#:}
          validate_numeric_port "$port" || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *)
      case $authority in
        *\[*|*\]*) return 1 ;;
      esac
      case $authority in
        *:*)
          host=${authority%%:*}
          port=${authority#*:}
          validate_numeric_port "$port" || return 1
          ;;
        *) host=$authority ;;
      esac
      [ -n "$host" ] || return 1
      case $host in
        *[!A-Za-z0-9._-]*) return 1 ;;
      esac
      ;;
  esac
  return 0
}

validate_endpoint() {
  local remainder authority
  [ -n "$endpoint" ] || return 1
  case $endpoint in
    *'?'*|*'#'*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  case $endpoint in
    http://*) remainder=${endpoint#http://} ;;
    https://*) remainder=${endpoint#https://} ;;
    *) return 1 ;;
  esac
  authority=${remainder%%/*}
  validate_authority "$authority"
}

validate_endpoint || die 'endpoint must be an exact http:// or https:// URL without userinfo, query, fragment, whitespace, backslashes, control characters, or an empty host'

case $provider in
  openai|anthropic) ;;
  *) die 'provider must be openai or anthropic' ;;
esac

case $model in
  ''|.*|-*|*[!A-Za-z0-9._:/-]*) die 'model must be a non-empty identifier using letters, digits, dot, underscore, colon, slash, or hyphen' ;;
esac

[ -n "$api_key" ] || die 'API key must not be empty'
case $api_key in
  *[![:print:]]*) die 'API key must contain only printable ASCII characters' ;;
esac

normalize_directory_destination() {
  local raw absolute cleaned current suffix segment parent resolved physical_pwd
  raw=$1
  [ -n "$raw" ] || return 1
  case $raw in
    *[[:cntrl:]]*) return 1 ;;
  esac
  case /$raw/ in
    */../*) return 1 ;;
  esac
  physical_pwd=$(pwd -P) || return 1
  case $raw in
    /*) absolute=$raw ;;
    *) absolute=$physical_pwd/$raw ;;
  esac
  while :; do
    cleaned=${absolute//\/\//\/}
    cleaned=${cleaned//\/\.\//\/}
    [ "$cleaned" != "$absolute" ] || break
    absolute=$cleaned
  done
  case $absolute in
    */.) absolute=${absolute%/.} ;;
  esac
  while [ "$absolute" != / ] && [ "${absolute%/}" != "$absolute" ]; do
    absolute=${absolute%/}
  done
  current=$absolute
  suffix=
  while [ ! -e "$current" ] && [ ! -L "$current" ]; do
    segment=${current##*/}
    [ -n "$segment" ] || return 1
    suffix=/$segment$suffix
    parent=${current%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$current" ] || return 1
    current=$parent
  done
  if [ -L "$current" ] && [ ! -e "$current" ]; then
    return 1
  fi
  [ -d "$current" ] || return 1
  resolved=$(CDPATH='' cd -P -- "$current" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "$resolved" "$suffix"
}

raw_state_dir=${OPENCLAW_STATE_DIR:-$HOME/.openclaw}
case $raw_state_dir in
  /|.|..|'') die 'OPENCLAW_STATE_DIR must name a dedicated directory, not root or the current directory' ;;
esac
if ! normalized_state_dir=$(normalize_directory_destination "$raw_state_dir"); then
  die 'OPENCLAW_STATE_DIR must be a safe directory path without parent traversal'
fi
[ "$normalized_state_dir" != / ] || die 'OPENCLAW_STATE_DIR must not resolve to root'
physical_pwd=$(pwd -P) || die 'could not resolve the current directory safely'
physical_home=
if [ -n "${HOME-}" ] && [ -d "$HOME" ]; then
  physical_home=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P) || die 'could not resolve HOME safely'
fi
[ "$normalized_state_dir" != "$physical_pwd" ] || die 'OPENCLAW_STATE_DIR must not resolve to the current directory'
if [ -n "$physical_home" ] && [ "$normalized_state_dir" = "$physical_home" ]; then
  die 'OPENCLAW_STATE_DIR must not resolve to HOME itself'
fi
OPENCLAW_STATE_DIR=$normalized_state_dir
export OPENCLAW_STATE_DIR

raw_config_file=${OPENCLAW_CONFIG_PATH:-$OPENCLAW_STATE_DIR/openclaw.json}
case $raw_config_file in
  ''|*[[:cntrl:]]*) die 'OPENCLAW_CONFIG_PATH must name a regular file' ;;
  /*) config_candidate=$raw_config_file ;;
  *) config_candidate=$(pwd -P)/$raw_config_file ;;
esac
case /$config_candidate/ in
  */../*) die 'OPENCLAW_CONFIG_PATH must not contain parent traversal' ;;
esac
config_name=${config_candidate##*/}
[ -n "$config_name" ] || die 'OPENCLAW_CONFIG_PATH must name a regular file'
config_parent_raw=${config_candidate%/*}
[ -n "$config_parent_raw" ] || config_parent_raw=/
if ! config_parent=$(normalize_directory_destination "$config_parent_raw"); then
  die 'the OpenClaw config parent cannot be resolved or created safely'
fi
config_file=$config_parent/$config_name
if [ -L "$config_file" ]; then
  die 'the active OpenClaw config must be a regular file, not a symlink'
fi
if [ -e "$config_file" ] && [ ! -f "$config_file" ]; then
  die 'the active OpenClaw config must be a regular file'
fi
OPENCLAW_CONFIG_PATH=$config_file
export OPENCLAW_CONFIG_PATH

secrets_dir=$OPENCLAW_STATE_DIR/secrets
secret_alias=ai-cli-installers-$provider
secret_file=$secrets_dir/$secret_alias-api-key
if [ -L "$secret_file" ]; then
  die 'the managed OpenClaw secret must be a regular file, not a symlink'
fi
if [ -e "$secret_file" ] && [ ! -f "$secret_file" ]; then
  die 'the managed OpenClaw secret must be a regular file'
fi
if [ -e "$OPENCLAW_STATE_DIR" ]; then
  if [ ! -d "$OPENCLAW_STATE_DIR" ] || [ ! -w "$OPENCLAW_STATE_DIR" ]; then
    die 'OPENCLAW_STATE_DIR must be a writable directory'
  fi
fi
if [ -e "$config_parent" ]; then
  if [ ! -d "$config_parent" ] || [ ! -w "$config_parent" ]; then
    die 'the OpenClaw config parent must be a writable directory'
  fi
fi
if [ -e "$secrets_dir" ] || [ -L "$secrets_dir" ]; then
  if [ ! -d "$secrets_dir" ] || [ ! -w "$secrets_dir" ]; then
    die 'the OpenClaw secrets path must be a writable directory'
  fi
fi

verify_active_config() {
  local reported candidate reported_name reported_parent_raw reported_parent normalized_reported
  if ! reported=$(openclaw config file 2>/dev/null); then
    return 1
  fi
  [ -n "$reported" ] || return 1
  case $reported in
    *[[:cntrl:]]*) return 1 ;;
    \~/*) candidate=$HOME/${reported#\~/} ;;
    /*) candidate=$reported ;;
    *) return 1 ;;
  esac
  [ ! -d "$candidate" ] || return 1
  [ ! -L "$candidate" ] || return 1
  reported_name=${candidate##*/}
  [ -n "$reported_name" ] || return 1
  reported_parent_raw=${candidate%/*}
  [ -n "$reported_parent_raw" ] || reported_parent_raw=/
  if ! reported_parent=$(normalize_directory_destination "$reported_parent_raw"); then
    return 1
  fi
  if [ "$reported_parent" = / ]; then
    normalized_reported=/$reported_name
  else
    normalized_reported=$reported_parent/$reported_name
  fi
  if [ -e "$normalized_reported" ] && [ ! -f "$normalized_reported" ]; then
    return 1
  fi
  [ "$normalized_reported" = "$config_file" ]
}

validate_active_config() {
  openclaw config validate --json >/dev/null 2>&1
}

command_exists=0
if command -v openclaw >/dev/null 2>&1; then
  command_exists=1
  verify_active_config || die 'openclaw config file did not resolve to the expected active config'
  validate_active_config || die 'official OpenClaw validation rejected the active config; the original was left unchanged'
fi

install_requested=0
if [ "$command_exists" -eq 0 ] || [ "$reinstall" -eq 1 ]; then
  install_requested=1
elif [ "$assume_yes" -eq 0 ]; then
  answer=
  if can_prompt; then
    printf 'OpenClaw is already installed. Reinstall or update it? [y/N] ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=
  fi
  case $answer in
    y|Y|yes|YES|Yes) install_requested=1 ;;
  esac
fi

if [ "$dry_run" -eq 1 ]; then
  info 'Dry run: provider, endpoint, model, and API key are valid (key masked).'
  if [ "$install_requested" -eq 1 ]; then
    info "Dry run: would run the official OpenClaw installer from $INSTALL_URL."
  else
    info 'Dry run: would keep the existing OpenClaw installation.'
  fi
  if [ "$command_exists" -eq 0 ]; then
    info 'Dry run: official config validation is deferred until OpenClaw is installed.'
  fi
  info 'Dry run: would merge OpenClaw provider settings and a private file-backed SecretRef.'
  exit 0
fi

umask 077
config_parent_existed=0
[ ! -d "$config_parent" ] || config_parent_existed=1
mkdir -p "$OPENCLAW_STATE_DIR" || die 'could not create OPENCLAW_STATE_DIR'
[ -d "$OPENCLAW_STATE_DIR" ] || die 'OPENCLAW_STATE_DIR is not a directory'
chmod 700 "$OPENCLAW_STATE_DIR" || die 'could not make OPENCLAW_STATE_DIR private'
mkdir -p "$config_parent" || die 'could not create the OpenClaw config parent'
if [ "$config_parent_existed" -eq 0 ]; then
  chmod 700 "$config_parent" || die 'could not make the OpenClaw config parent private'
fi
mkdir -p "$secrets_dir" || die 'could not create the OpenClaw secrets directory'
[ -d "$secrets_dir" ] || die 'OpenClaw secrets path is not a directory'
chmod 700 "$secrets_dir" || die 'could not make the OpenClaw secrets directory private'

next_backup_path() {
  local source_file candidate suffix
  source_file=$1
  candidate=$source_file.ai-cli-installers.bak
  suffix=1
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate=$source_file.ai-cli-installers.bak.$suffix
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate"
}

config_existed=0
secret_existed=0
config_backup=
secret_backup=

create_private_backup() {
  local source_file result_variable candidate
  source_file=$1
  result_variable=$2
  candidate=$(next_backup_path "$source_file")
  TEMP_FILE=$(mktemp "$candidate.ai-cli-installers.tmp.XXXXXX") || die 'could not create a private backup temporary file'
  /bin/cat <"$source_file" >"$TEMP_FILE" || die 'could not read a managed file for backup'
  chmod 600 "$TEMP_FILE" || die 'could not make a backup private'
  mv -f -- "$TEMP_FILE" "$candidate" || die 'could not publish a backup'
  TEMP_FILE=
  printf -v "$result_variable" '%s' "$candidate"
}

if [ -e "$config_file" ]; then
  config_existed=1
  create_private_backup "$config_file" config_backup
fi
if [ -e "$secret_file" ]; then
  secret_existed=1
  create_private_backup "$secret_file" secret_backup
fi

restore_private_file() {
  local source_file target_file
  source_file=$1
  target_file=$2
  TEMP_FILE=$(mktemp "$target_file.ai-cli-installers.tmp.XXXXXX") || return 1
  /bin/cat <"$source_file" >"$TEMP_FILE" || return 1
  chmod 600 "$TEMP_FILE" || return 1
  mv -f -- "$TEMP_FILE" "$target_file" || return 1
  TEMP_FILE=
}

rollback_configuration() {
  local rollback_failed
  rollback_failed=0
  if [ "$config_existed" -eq 1 ]; then
    restore_private_file "$config_backup" "$config_file" || rollback_failed=1
  else
    rm -f -- "$config_file" || rollback_failed=1
  fi
  if [ "$secret_existed" -eq 1 ]; then
    restore_private_file "$secret_backup" "$secret_file" || rollback_failed=1
  else
    rm -f -- "$secret_file" || rollback_failed=1
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    printf '%s\n' 'Error: configuration failed and automatic rollback was incomplete; retained backups contain the original files' >&2
  fi
  return "$rollback_failed"
}

configuration_failed() {
  TRANSACTION_ACTIVE=0
  rollback_configuration || true
  die "$1; the original OpenClaw configuration was restored"
}

TRANSACTION_ACTIVE=1
if [ "$install_requested" -eq 1 ]; then
  info "Running the official OpenClaw installer from $INSTALL_URL ..."
  if ! curl -fsSL "$INSTALL_URL" | bash -s -- --no-prompt --no-onboard; then
    configuration_failed 'the official OpenClaw installer failed'
  fi
  PATH="$HOME/.local/bin:$HOME/.openclaw/bin:$HOME/.local/share/openclaw/bin:$PATH"
  export PATH
  if ! command -v openclaw >/dev/null 2>&1 || ! openclaw --version >/dev/null 2>&1; then
    configuration_failed 'OpenClaw was not available after installation'
  fi
  if ! rollback_configuration; then
    TRANSACTION_ACTIVE=0
    die 'the official installer touched managed files and restoring the original snapshot was incomplete'
  fi
else
  info 'Keeping the existing OpenClaw installation.'
fi

verify_active_config || configuration_failed 'openclaw config file did not resolve to the expected active config'
validate_active_config || configuration_failed 'official OpenClaw validation rejected the active config'
command -v node >/dev/null 2>&1 || configuration_failed 'node is required to encode strict JSON config payloads safely'

TEMP_FILE=$(mktemp "$secret_file.ai-cli-installers.tmp.XXXXXX") || configuration_failed 'could not create a private temporary secret file'
printf '%s' "$api_key" >"$TEMP_FILE" || configuration_failed 'could not write the provider secret'
chmod 600 "$TEMP_FILE" || configuration_failed 'could not make the provider secret private'
mv -f -- "$TEMP_FILE" "$secret_file" || configuration_failed 'could not replace the provider secret'
TEMP_FILE=

if ! secret_provider_payload=$(node - "$secret_file" <<'NODE'
const path = process.argv[2];
process.stdout.write(JSON.stringify({source: 'file', path, mode: 'singleValue'}));
NODE
); then
  configuration_failed 'could not encode the secret provider config safely'
fi
if ! model_provider_payload=$(node - "$endpoint" "$secret_alias" "$provider" <<'NODE'
const [endpoint, secretAlias, provider] = process.argv.slice(2);
const api = provider === 'openai' ? 'openai-responses' : 'anthropic-messages';
process.stdout.write(JSON.stringify({
  baseUrl: endpoint,
  api,
  apiKey: {source: 'file', provider: secretAlias, id: 'value'}
}));
NODE
); then
  configuration_failed 'could not encode the model provider config safely'
fi
if ! model_payload=$(node - "$model" <<'NODE'
const model = process.argv[2];
process.stdout.write(JSON.stringify([{id: model, name: model}]));
NODE
); then
  configuration_failed 'could not encode the provider model safely'
fi
if ! primary_payload=$(node - "$provider/$model" <<'NODE'
process.stdout.write(JSON.stringify(process.argv[2]));
NODE
); then
  configuration_failed 'could not encode the primary model safely'
fi

openclaw config set "secrets.providers.$secret_alias" "$secret_provider_payload" --strict-json >/dev/null 2>&1 || configuration_failed 'could not configure the file-backed secret provider'
openclaw config set "models.providers.$provider" "$model_provider_payload" --strict-json --merge >/dev/null 2>&1 || configuration_failed 'could not merge the selected model provider'
openclaw config set "models.providers.$provider.models" "$model_payload" --strict-json --merge >/dev/null 2>&1 || configuration_failed 'could not merge the selected provider model'
openclaw config set 'models.mode' '"merge"' --strict-json >/dev/null 2>&1 || configuration_failed 'could not configure model merge mode'
openclaw config set 'agents.defaults.model.primary' "$primary_payload" --strict-json >/dev/null 2>&1 || configuration_failed 'could not configure the primary model'
validate_active_config || configuration_failed 'official OpenClaw validation rejected the updated config'

[ -f "$config_file" ] || configuration_failed 'OpenClaw did not create its active config file'
chmod 600 "$config_file" || configuration_failed 'could not make the OpenClaw config private'
chmod 600 "$secret_file" || configuration_failed 'could not make the OpenClaw secret private'
TRANSACTION_ACTIVE=0
info 'OpenClaw is ready; the API key was stored in a private file-backed SecretRef without being displayed.'
