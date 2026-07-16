#!/usr/bin/env bash

set -u
set -o pipefail
LC_ALL=C
export LC_ALL

PROGRAM_NAME=${0##*/}
INSTALL_URL='https://hermes-agent.nousresearch.com/install.sh'
TEMP_FILE=
TEMP_DIR=
TTY_ECHO_DISABLED=0
TRANSACTION_ACTIVE=0

endpoint=${AI_ENDPOINT-}
api_key=${AI_API_KEY-}
model=${AI_MODEL-}
unset AI_API_KEY

assume_yes=0
reinstall=0
dry_run=0
provider_id=custom

if [ "${AI_INSTALL_YES-}" = 1 ]; then
  assume_yes=1
fi

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options]

Install and configure Hermes Agent for an OpenAI-compatible endpoint.

Options:
  --endpoint URL       Exact API base URL (or set AI_ENDPOINT)
  --key KEY            API key (or set AI_API_KEY)
  --model MODEL        Default model identifier (or set AI_MODEL)
  --provider-id ID     Hermes provider id (default: custom)
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
  if [ -n "$TEMP_FILE" ] && [ -e "$TEMP_FILE" ]; then
    rm -f -- "$TEMP_FILE"
  fi
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    /bin/rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case $1 in
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
    --provider-id)
      [ "$#" -ge 2 ] || die '--provider-id requires a value'
      provider_id=$2
      shift 2
      ;;
    --provider-id=*)
      provider_id=${1#--provider-id=}
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
    -*)
      die 'unknown option or unexpected positional argument; use --help for supported syntax'
      ;;
    *)
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

case $provider_id in
  ''|*[!a-z0-9_-]*) die 'provider id must contain only lowercase letters, digits, underscores, and hyphens' ;;
esac

case $model in
  ''|.*|-*|*[!A-Za-z0-9._:/-]*) die 'model must be a non-empty model identifier using letters, digits, dot, underscore, colon, slash, or hyphen' ;;
esac
case $model in
  *[A-Za-z]*) ;;
  *) die 'model must contain an ASCII letter and must not be a YAML scalar' ;;
esac
model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case $model_lower in
  true|false|null|yes|no|on|off|.nan|.inf|-.inf) die 'model must not be a YAML boolean, null, numeric, or timestamp scalar' ;;
esac
case $model_lower in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][tT]*) die 'model must not be a YAML timestamp scalar' ;;
esac

[ -n "$api_key" ] || die 'API key must not be empty'
printf -v dotenv_expansion_prefix '%s%s' '$' '{'
case $api_key in
  *[![:print:]]*|*"$dotenv_expansion_prefix"*) die 'API key must contain only printable ASCII characters that are safe in dotenv format' ;;
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

raw_hermes_home=${HERMES_HOME:-$HOME/.hermes}
case $raw_hermes_home in
  /|.|./|..|'') die 'HERMES_HOME must name a dedicated directory, not root, HOME, or the current directory' ;;
esac
if ! normalized_hermes_home=$(normalize_directory_destination "$raw_hermes_home"); then
  die 'HERMES_HOME must be a safe directory path without parent traversal'
fi
[ "$normalized_hermes_home" != / ] || die 'HERMES_HOME must not resolve to root'
physical_pwd=$(pwd -P) || die 'could not resolve the current directory safely'
physical_home=
if [ -n "${HOME-}" ] && [ -d "$HOME" ]; then
  physical_home=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P) || die 'could not resolve HOME safely'
fi
[ "$normalized_hermes_home" != "$physical_pwd" ] || die 'HERMES_HOME must not resolve to the current directory'
if [ -n "$physical_home" ] && [ "$normalized_hermes_home" = "$physical_home" ]; then
  die 'HERMES_HOME must not resolve to HOME itself'
fi
HERMES_HOME=$normalized_hermes_home
export HERMES_HOME
config_file=$HERMES_HOME/config.yaml
env_file=$HERMES_HOME/.env

resolve_write_target() {
  local current link_target parent hops followed_link
  current=$1
  hops=0
  followed_link=0

  while [ -L "$current" ]; do
    followed_link=1
    hops=$((hops + 1))
    [ "$hops" -le 32 ] || return 1
    link_target=$(readlink "$current") || return 1
    [ -n "$link_target" ] || return 1
    case $link_target in
      /*) current=$link_target ;;
      *)
        parent=${current%/*}
        [ "$parent" != "$current" ] || parent=.
        current=$parent/$link_target
        ;;
    esac
  done

  if [ "$followed_link" -eq 1 ] && [ ! -e "$current" ]; then
    return 1
  fi
  printf '%s\n' "$current"
}

if [ -e "$HERMES_HOME" ] || [ -L "$HERMES_HOME" ]; then
  [ -d "$HERMES_HOME" ] || die 'HERMES_HOME must be a directory'
  [ -w "$HERMES_HOME" ] || die 'HERMES_HOME must be writable'
else
  home_parent=$HERMES_HOME
  while [ ! -e "$home_parent" ] && [ ! -L "$home_parent" ]; do
    next_parent=${home_parent%/*}
    if [ "$next_parent" = "$home_parent" ]; then
      home_parent=.
      break
    fi
    [ -n "$next_parent" ] || next_parent=/
    home_parent=$next_parent
  done
  if [ ! -d "$home_parent" ] || [ ! -w "$home_parent" ]; then
    die 'HERMES_HOME cannot be created under its nearest existing parent'
  fi
fi

if ! config_target=$(resolve_write_target "$config_file"); then
  die 'Hermes config symlink is broken or cyclic; the link was left unchanged'
fi
if ! env_target=$(resolve_write_target "$env_file"); then
  die 'Hermes dotenv symlink is broken or cyclic; the link was left unchanged'
fi
if [ -e "$config_target" ] && [ ! -f "$config_target" ]; then
  die 'Hermes config does not resolve to a regular file'
fi
if [ -e "$env_target" ] && [ ! -f "$env_target" ]; then
  die 'Hermes dotenv file does not resolve to a regular file'
fi

encode_provider_env() {
  local remaining char encoded
  remaining=$provider_id
  encoded=
  while [ -n "$remaining" ]; do
    char=${remaining%"${remaining#?}"}
    remaining=${remaining#?}
    case $char in
      _) encoded=${encoded}_U ;;
      -) encoded=${encoded}_H ;;
      [a-z]) encoded=$encoded$(printf '%s' "$char" | tr '[:lower:]' '[:upper:]') ;;
      *) encoded=$encoded$char ;;
    esac
  done
  provider_key_env=HERMES_PROVIDER_${encoded}_API_KEY
}

encode_provider_env

filter_dotenv() {
  awk -v target="$provider_key_env" '
    function closes_quote(value, quote, start_at,    loop_index, character, escaped) {
      escaped = 0
      for (loop_index = start_at; loop_index <= length(value); loop_index++) {
        character = substr(value, loop_index, 1)
        if (escaped) {
          escaped = 0
        } else if (character == "\\") {
          escaped = 1
        } else if (character == quote) {
          return 1
        }
      }
      return 0
    }

    function opening_quote(line,    equals_at, value, quote, single_quote) {
      if (line !~ assignment_pattern) return ""
      equals_at = index(line, "=")
      value = substr(line, equals_at + 1)
      sub(/^[[:space:]]*/, "", value)
      quote = substr(value, 1, 1)
      single_quote = sprintf("%c", 39)
      if (quote != "\"" && quote != single_quote) return ""
      if (closes_quote(value, quote, 2)) return ""
      return quote
    }

    BEGIN {
      assignment_pattern = "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*="
      target_pattern = "^[[:space:]]*(export[[:space:]]+)?" target "[[:space:]]*="
      quote_state = ""
      dropping = 0
    }

    {
      line = $0
      if (quote_state != "") {
        if (!dropping) print line
        if (closes_quote(line, quote_state, 1)) {
          quote_state = ""
          dropping = 0
        }
        next
      }

      is_target = line ~ target_pattern
      next_quote = opening_quote(line)
      if (next_quote != "") {
        quote_state = next_quote
        dropping = is_target
      }
      if (!is_target) print line
    }

    END {
      if (quote_state != "") exit 2
    }
  ' "$1"
}

if [ -e "$env_target" ] && ! filter_dotenv "$env_target" >/dev/null; then
  die 'Hermes dotenv file has an unclosed quoted value; the original was left unchanged'
fi

command_exists=0
if command -v hermes >/dev/null 2>&1; then
  command_exists=1
fi

install_requested=0
if [ "$command_exists" -eq 0 ] || [ "$reinstall" -eq 1 ]; then
  install_requested=1
elif [ "$assume_yes" -eq 0 ]; then
  answer=
  if can_prompt; then
    printf 'Hermes Agent is already installed. Reinstall or update it? [y/N] ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=
  fi
  case $answer in
    y|Y|yes|YES|Yes) install_requested=1 ;;
  esac
fi

if [ "$dry_run" -eq 1 ]; then
  info 'Dry run: endpoint, provider id, model, and API key are valid (key masked).'
  if [ "$install_requested" -eq 1 ]; then
    info "Dry run: would run the official Hermes installer from $INSTALL_URL."
  else
    info 'Dry run: would keep the existing Hermes installation.'
  fi
  info 'Dry run: would merge Hermes provider settings and its private dotenv secret.'
  exit 0
fi

umask 077
mkdir -p "$HERMES_HOME" || die 'could not create HERMES_HOME'
[ -d "$HERMES_HOME" ] || die 'HERMES_HOME is not a directory'
chmod 700 "$HERMES_HOME" || die 'could not make HERMES_HOME private'
[ -w "$HERMES_HOME" ] || die 'HERMES_HOME must be writable'

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
env_existed=0
config_backup=
env_backup=

create_private_backup() {
  local source_file public_file result_variable candidate
  source_file=$1
  public_file=$2
  result_variable=$3
  candidate=$(next_backup_path "$public_file")
  TEMP_FILE=$(mktemp "$candidate.ai-cli-installers.tmp.XXXXXX") || die 'could not create a private backup temporary file'
  if ! /bin/cat <"$source_file" >"$TEMP_FILE"; then
    die 'could not read a configuration file for backup'
  fi
  chmod 600 "$TEMP_FILE" || die 'could not make a configuration backup private'
  mv -f -- "$TEMP_FILE" "$candidate" || die 'could not publish a configuration backup'
  TEMP_FILE=
  printf -v "$result_variable" '%s' "$candidate"
}

if [ -e "$config_target" ]; then
  config_existed=1
  create_private_backup "$config_target" "$config_file" config_backup
fi

if [ -e "$env_target" ]; then
  env_existed=1
  create_private_backup "$env_target" "$env_file" env_backup
fi

restore_private_file() {
  local source_file target_file
  source_file=$1
  target_file=$2
  TEMP_FILE=$(mktemp "$target_file.ai-cli-installers.tmp.XXXXXX") || return 1
  if ! /bin/cat <"$source_file" >"$TEMP_FILE"; then
    return 1
  fi
  chmod 600 "$TEMP_FILE" || return 1
  mv -f -- "$TEMP_FILE" "$target_file" || return 1
  TEMP_FILE=
}

rollback_configuration() {
  local rollback_failed
  rollback_failed=0
  if [ "$config_existed" -eq 1 ]; then
    restore_private_file "$config_backup" "$config_target" || rollback_failed=1
  else
    rm -f -- "$config_target" || rollback_failed=1
  fi
  if [ "$env_existed" -eq 1 ]; then
    restore_private_file "$env_backup" "$env_target" || rollback_failed=1
  else
    rm -f -- "$env_target" || rollback_failed=1
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    printf '%s\n' 'Error: configuration failed and automatic rollback was incomplete; retained backups contain the original files' >&2
  fi
  return "$rollback_failed"
}

configuration_failed() {
  TRANSACTION_ACTIVE=0
  rollback_configuration || true
  die "$1; the original Hermes configuration was restored"
}

TRANSACTION_ACTIVE=1

if [ "$install_requested" -eq 1 ]; then
  info "Running the official Hermes installer from $INSTALL_URL ..."
  if ! curl -fsSL "$INSTALL_URL" | bash -s -- --skip-setup --non-interactive; then
    configuration_failed 'the official Hermes installer failed'
  fi
  PATH="$HOME/.local/bin:$HOME/.hermes/bin:$HOME/.local/share/hermes/bin:$PATH"
  export PATH
  if ! command -v hermes >/dev/null 2>&1 || ! hermes version >/dev/null 2>&1; then
    configuration_failed 'Hermes was not available after installation'
  fi
  if ! rollback_configuration; then
    TRANSACTION_ACTIVE=0
    die 'the official installer touched configuration and restoring the original snapshot was incomplete'
  fi
else
  info 'Keeping the existing Hermes installation.'
fi

if [ -e "$config_target" ]; then
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ai-cli-installers-hermes-parse.XXXXXX") || configuration_failed 'could not create an isolated YAML preflight directory'
  chmod 700 "$TEMP_DIR" || configuration_failed 'could not make the YAML preflight directory private'
  TEMP_FILE=$TEMP_DIR/config.yaml
  if ! /bin/cat <"$config_target" >"$TEMP_FILE"; then
    configuration_failed 'could not copy Hermes YAML for isolated preflight'
  fi
  chmod 600 "$TEMP_FILE" || configuration_failed 'could not make the YAML preflight copy private'
  if yaml_diagnostics=$(HERMES_HOME="$TEMP_DIR" hermes config show 2>&1 >/dev/null); then
    yaml_status=0
  else
    yaml_status=$?
  fi
  /bin/rm -rf "$TEMP_DIR"
  TEMP_DIR=
  TEMP_FILE=
  case $yaml_diagnostics in
    *'Failed to parse'*) configuration_failed 'existing Hermes YAML could not be parsed safely' ;;
  esac
  [ "$yaml_status" -eq 0 ] || configuration_failed 'Hermes could not read the existing YAML safely'
fi

DOTENV_ESCAPED=${api_key//\\/\\\\}
DOTENV_ESCAPED=${DOTENV_ESCAPED//\"/\\\"}

TEMP_FILE=$(mktemp "$env_target.ai-cli-installers.tmp.XXXXXX") || configuration_failed 'could not create a private temporary dotenv file'
if [ -e "$env_target" ]; then
  filter_dotenv "$env_target" >"$TEMP_FILE" || configuration_failed 'Hermes dotenv changed after preflight and is no longer safely mergeable'
fi
printf '%s="%s"\n' "$provider_key_env" "$DOTENV_ESCAPED" >>"$TEMP_FILE" || configuration_failed 'could not write the provider secret'
chmod 600 "$TEMP_FILE" || configuration_failed 'could not make the provider secret private'
mv -f -- "$TEMP_FILE" "$env_target" || configuration_failed 'could not replace the Hermes dotenv file'
TEMP_FILE=

set_hermes_config() {
  hermes config set "$1" "$2" >/dev/null 2>&1
}

set_hermes_config "providers.$provider_id.api" "$endpoint" || configuration_failed 'could not configure the provider API endpoint'
set_hermes_config "providers.$provider_id.key_env" "$provider_key_env" || configuration_failed 'could not configure the provider key environment variable'
set_hermes_config "providers.$provider_id.default_model" "$model" || configuration_failed 'could not configure the provider default model'
set_hermes_config "providers.$provider_id.transport" 'chat_completions' || configuration_failed 'could not configure the provider transport'
set_hermes_config 'model.default' "$model" || configuration_failed 'could not configure the default model'
set_hermes_config 'model.provider' "custom:$provider_id" || configuration_failed 'could not select the custom provider'

[ -f "$config_target" ] || configuration_failed 'Hermes did not create its config file'
chmod 600 "$config_target" || configuration_failed 'could not make the Hermes config private'
chmod 600 "$env_target" || configuration_failed 'could not make the Hermes dotenv file private'

TRANSACTION_ACTIVE=0
info 'Hermes Agent is ready; the API key was stored privately without being displayed.'
