#!/usr/bin/env bash

set -u
set -o pipefail
umask 077

PROGRAM_NAME=${0##*/}
NVM_INSTALL_URL='https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh'
BLOCK_START='# >>> ai-cli-installers codex >>>'
BLOCK_END='# <<< ai-cli-installers codex <<<'
CONFIG_TEMP=
AUTH_TEMP=
RC_TEMP=
TTY_ECHO_DISABLED=0

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options]

Install and configure Codex CLI for an OpenAI-compatible endpoint.

Options:
  --endpoint URL       Exact OpenAI-compatible API base URL (or AI_ENDPOINT)
  --key KEY            API key (or AI_API_KEY)
  --model MODEL        Model name (default: gpt-5.4)
  --provider-id ID     Lowercase provider id (default: custom)
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
  [ -z "$CONFIG_TEMP" ] || rm -f -- "$CONFIG_TEMP"
  [ -z "$AUTH_TEMP" ] || rm -f -- "$AUTH_TEMP"
  [ -z "$RC_TEMP" ] || rm -f -- "$RC_TEMP"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

endpoint=${AI_ENDPOINT-}
api_key=${AI_API_KEY-}
unset AI_API_KEY
model='gpt-5.4'
provider_id='custom'
assume_yes=0
reinstall=0
dry_run=0

if [ "${AI_INSTALL_YES-}" = '1' ]; then
  assume_yes=1
fi

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
      die 'unknown option'
      ;;
    *)
      die 'unexpected positional argument'
      ;;
  esac
done

[ "$#" -eq 0 ] || die 'unexpected positional argument'

can_prompt() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

prompt_endpoint() {
  can_prompt || die 'endpoint is required; pass --endpoint or set AI_ENDPOINT'
  printf 'Exact API endpoint: ' >/dev/tty
  IFS= read -r endpoint </dev/tty || die 'could not read endpoint from the terminal'
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
  prompt_endpoint
fi

if [ -z "$api_key" ]; then
  if [ "$assume_yes" -eq 1 ]; then
    die 'API key is required in unattended mode; pass --key or set AI_API_KEY'
  fi
  prompt_key
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
  if printf '%s' "$endpoint" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    return 1
  fi
  case $endpoint in
    *'?'*|*'#'*|*[[:space:]]*) return 1 ;;
  esac

  case $endpoint in
    http://*) remainder=${endpoint#http://} ;;
    https://*) remainder=${endpoint#https://} ;;
    *) return 1 ;;
  esac

  authority=${remainder%%/*}
  validate_authority "$authority"
}

validate_endpoint || die 'endpoint must be an exact http:// or https:// URL without userinfo, query, fragment, whitespace, or an empty host'
[ -n "$api_key" ] || die 'API key must not be empty'
[ -n "$model" ] || die 'model must not be empty'
case $model in
  *$'\n'*|*$'\r'*) die 'model must not contain line breaks' ;;
esac
if printf '%s' "$model" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
  die 'model must not contain control characters'
fi
case $provider_id in
  ''|*[!a-z0-9_-]*) die 'provider id must contain only lowercase letters, digits, underscores, or hyphens' ;;
esac

command_exists=0
if command -v codex >/dev/null 2>&1; then
  command_exists=1
fi

install_requested=0
if [ "$command_exists" -eq 0 ] || [ "$reinstall" -eq 1 ]; then
  install_requested=1
elif [ "$assume_yes" -eq 0 ]; then
  answer=
  if can_prompt; then
    printf 'Codex CLI is already installed. Reinstall or update it? [y/N] ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=
  fi
  case $answer in
    y|Y|yes|YES|Yes) install_requested=1 ;;
  esac
fi

if [ "$dry_run" -eq 1 ]; then
  info 'Dry run: endpoint, model, provider id, and API key are valid (key masked).'
  if [ "$install_requested" -eq 1 ]; then
    info 'Dry run: would install the official @openai/codex npm package.'
  else
    info 'Dry run: would keep the existing Codex CLI installation.'
  fi
  info 'Dry run: would update Codex configuration, auth, and the managed shell environment block.'
  exit 0
fi

bootstrap_node() {
  NVM_DIR=${NVM_DIR:-$HOME/.nvm}
  export NVM_DIR
  info "Bootstrapping Node.js 22 with official nvm v0.40.3 from $NVM_INSTALL_URL ..."
  if ! curl -fsSL "$NVM_INSTALL_URL" | PROFILE=/dev/null bash; then
    die 'the official nvm installer failed'
  fi
  [ -s "$NVM_DIR/nvm.sh" ] || die 'nvm was not available after bootstrap'
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
  nvm install 22 || die 'Node.js 22 installation through nvm failed'
  nvm use 22 || die 'Node.js 22 activation through nvm failed'
  command -v node >/dev/null 2>&1 || die 'node was not available after bootstrap'
  command -v npm >/dev/null 2>&1 || die 'npm was not available after bootstrap'
}

next_backup_path() {
  local source_file candidate suffix
  source_file=$1
  candidate="$source_file.ai-cli-installers.bak"
  suffix=1
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate="$source_file.ai-cli-installers.bak.$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate"
}

make_temp_for_target() {
  local target_file target_dir target_name
  target_file=$1
  target_dir=${target_file%/*}
  target_name=${target_file##*/}
  [ "$target_dir" != "$target_file" ] || target_dir=.
  mktemp "$target_dir/.${target_name}.ai-cli-installers.tmp.XXXXXX"
}

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

validate_managed_layout() {
  local source_file
  source_file=$1
  [ -e "$source_file" ] || return 0
  awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    function invalid_layout() {
      invalid = 1
      exit 2
    }
    $0 == start {
      if (managed || blocks > 0) invalid_layout()
      managed = 1
      blocks++
      next
    }
    $0 == end {
      if (!managed) invalid_layout()
      managed = 0
      next
    }
    END {
      if (invalid || managed) exit 2
    }
  ' "$source_file" >/dev/null
}

choose_shell_rc() {
  local shell_name candidate
  shell_name=${SHELL##*/}

  case $shell_name in
    zsh)
      [ -f "$HOME/.zshrc" ] && { printf '%s/.zshrc\n' "$HOME"; return; }
      ;;
    bash)
      for candidate in .bashrc .bash_profile; do
        [ -f "$HOME/$candidate" ] && { printf '%s/%s\n' "$HOME" "$candidate"; return; }
      done
      ;;
  esac

  for candidate in .zshrc .bashrc .bash_profile .profile; do
    [ -f "$HOME/$candidate" ] && { printf '%s/%s\n' "$HOME" "$candidate"; return; }
  done

  case $(uname -s 2>/dev/null || printf 'unknown\n') in
    Darwin) printf '%s/.zshrc\n' "$HOME" ;;
    *) printf '%s/.bashrc\n' "$HOME" ;;
  esac
}

shell_quote() {
  local value
  value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

render_codex_config() {
  AI_CLI_MODEL=$model AI_CLI_PROVIDER=$provider_id AI_CLI_ENDPOINT=$endpoint \
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    function is_escaped(text, position, count) {
      count = 0
      position--
      while (position > 0 && substr(text, position, 1) == "\\") {
        count++
        position--
      }
      return count % 2
    }
    function scan_strings(text, track_structure, position, length_of_text, character, quote_state) {
      position = 1
      length_of_text = length(text)
      quote_state = ""
      while (position <= length_of_text) {
        if (multiline == "basic") {
          if (substr(text, position, 3) == "\"\"\"" && !is_escaped(text, position)) {
            multiline = ""
            position += 3
          } else {
            position++
          }
          continue
        }
        if (multiline == "literal") {
          if (substr(text, position, 3) == "\047\047\047") {
            multiline = ""
            position += 3
          } else {
            position++
          }
          continue
        }

        character = substr(text, position, 1)
        if (quote_state == "basic") {
          if (character == "\"" && !is_escaped(text, position)) quote_state = ""
          position++
          continue
        }
        if (quote_state == "literal") {
          if (character == "\047") quote_state = ""
          position++
          continue
        }
        if (character == "#") return
        if (substr(text, position, 3) == "\"\"\"") {
          multiline = "basic"
          position += 3
          continue
        }
        if (substr(text, position, 3) == "\047\047\047") {
          multiline = "literal"
          position += 3
          continue
        }
        if (character == "\"") quote_state = "basic"
        else if (character == "\047") quote_state = "literal"
        else if (track_structure && character == "[") square_depth++
        else if (track_structure && character == "]") {
          square_depth--
          if (square_depth < 0) invalid_layout()
        }
        else if (track_structure && character == "{") brace_depth++
        else if (track_structure && character == "}") {
          brace_depth--
          if (brace_depth < 0) invalid_layout()
        }
        position++
      }
    }
    function toml_quote(value, result, position, character) {
      result = "\""
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        if (character == "\\" || character == "\"") result = result "\\"
        result = result character
      }
      return result "\""
    }
    function print_managed_block() {
      print start
      print "model = " toml_quote(ENVIRON["AI_CLI_MODEL"])
      print "model_provider = " toml_quote(ENVIRON["AI_CLI_PROVIDER"])
      print ""
      print "[model_providers." ENVIRON["AI_CLI_PROVIDER"] "]"
      print "base_url = " toml_quote(ENVIRON["AI_CLI_ENDPOINT"])
      print "env_key = \"OPENAI_API_KEY\""
      print "wire_api = \"responses\""
      print end
    }
    function named_segment(name, single_quote) {
      single_quote = sprintf("%c", 39)
      return "(\"" name "\"|" single_quote name single_quote "|" name ")"
    }
    function provider_segment() {
      return named_segment(ENVIRON["AI_CLI_PROVIDER"])
    }
    function provider_root_segment() {
      return named_segment("model_providers")
    }
    function is_provider_table(text) {
      return text ~ ("^[ \t]*\\[[ \t]*" provider_root_segment() "[ \t]*\\.[ \t]*" provider_segment() "[ \t]*\\][ \t]*(#.*)?$")
    }
    function is_provider_array_table(text) {
      return text ~ ("^[ \t]*\\[\\[[ \t]*" provider_root_segment() "[ \t]*\\.[ \t]*" provider_segment() "[ \t]*\\]\\][ \t]*(#.*)?$")
    }
    function is_provider_parent_table(text) {
      return text ~ ("^[ \t]*\\[[ \t]*" provider_root_segment() "[ \t]*\\][ \t]*(#.*)?$")
    }
    function is_provider_parent_array_table(text) {
      return text ~ ("^[ \t]*\\[\\[[ \t]*" provider_root_segment() "[ \t]*\\]\\][ \t]*(#.*)?$")
    }
    function is_real_header(text) {
      return square_depth == 0 && brace_depth == 0 && text ~ /^[ \t]*\[/
    }
    function is_root_key(text, key) {
      return text ~ ("^[ \t]*" named_segment(key) "[ \t]*=")
    }
    function is_unsafe_provider_assignment(text) {
      return text ~ ("^[ \t]*" provider_root_segment() "[ \t]*=") || \
        text ~ ("^[ \t]*" provider_root_segment() "[ \t]*\\.[ \t]*" provider_segment() "[ \t]*(=|\\.)")
    }
    function is_selected_provider_assignment(text) {
      return text ~ ("^[ \t]*" provider_segment() "[ \t]*(=|\\.)")
    }
    function is_scalar_dotted_conflict(text) {
      return text ~ ("^[ \t]*" named_segment("model") "[ \t]*\\.") || \
        text ~ ("^[ \t]*" named_segment("model_provider") "[ \t]*\\.")
    }
    function is_unsafe_root_scalar_value(text) {
      return text ~ ("^[ \t]*" named_segment("model") "[ \t]*=[ \t]*[\\[\\{]") || \
        text ~ ("^[ \t]*" named_segment("model_provider") "[ \t]*=[ \t]*[\\[\\{]")
    }
    function is_scalar_table_conflict(text) {
      return text ~ ("^[ \t]*\\[\\[?[ \t]*" named_segment("model") "[ \t]*(\\.|\\])") || \
        text ~ ("^[ \t]*\\[\\[?[ \t]*" named_segment("model_provider") "[ \t]*(\\.|\\])")
    }
    function invalid_layout() {
      invalid = 1
      exit 2
    }
    {
      started_in_multiline = (multiline != "")

      if (skipping_root_multiline) {
        scan_strings($0, 0)
        if (multiline == "") skipping_root_multiline = 0
        next
      }

      if (!started_in_multiline && $0 == start) {
        if (managed || blocks > 0) invalid_layout()
        managed = 1
        blocks++
        next
      }
      if (!started_in_multiline && $0 == end) {
        if (!managed) invalid_layout()
        managed = 0
        next
      }
      if (managed) {
        scan_strings($0, 0)
        next
      }

      if (skipping_provider) {
        if (!started_in_multiline && is_real_header($0)) {
          skipping_provider = 0
        } else {
          scan_strings($0, 1)
          next
        }
      }

      if (!started_in_multiline && (is_provider_array_table($0) || is_provider_parent_array_table($0) || is_scalar_table_conflict($0))) invalid_layout()
      if (!started_in_multiline && !in_table && (is_unsafe_provider_assignment($0) || is_scalar_dotted_conflict($0) || is_unsafe_root_scalar_value($0))) invalid_layout()
      if (!started_in_multiline && in_provider_parent && is_selected_provider_assignment($0)) invalid_layout()

      if (!started_in_multiline && is_provider_table($0)) {
        skipping_provider = 1
        scan_strings($0, 0)
        next
      }

      if (!started_in_multiline && !inserted && is_real_header($0)) {
        print_managed_block()
        inserted = 1
        in_table = 1
      }
      if (!started_in_multiline && is_real_header($0)) {
        in_provider_parent = is_provider_parent_table($0)
      }
      if (!started_in_multiline && !in_table && (is_root_key($0, "model") || is_root_key($0, "model_provider"))) {
        scan_strings($0, 0)
        if (multiline != "") skipping_root_multiline = 1
        next
      }

      print
      if (!started_in_multiline && is_real_header($0)) scan_strings($0, 0)
      else scan_strings($0, 1)
    }
    END {
      if (invalid || managed || multiline != "" || square_depth != 0 || brace_depth != 0) exit 2
      if (!inserted) print_managed_block()
    }
  ' "$1"
}

config_file=$HOME/.codex/config.toml
auth_file=$HOME/.codex/auth.json
rc_file=$(choose_shell_rc)

if ! config_target=$(resolve_write_target "$config_file"); then
  die 'Codex config symlink is broken or cyclic; the link was left unchanged'
fi
if ! auth_target=$(resolve_write_target "$auth_file"); then
  die 'Codex auth symlink is broken or cyclic; the link was left unchanged'
fi
if ! rc_target=$(resolve_write_target "$rc_file"); then
  die 'shell rc symlink is broken or cyclic; the link was left unchanged'
fi

if [ -e "$config_target" ]; then
  [ -f "$config_target" ] || die 'Codex config does not resolve to a regular file'
  render_codex_config "$config_target" >/dev/null || die 'Codex config has an invalid or unsupported TOML layout; the original was left unchanged'
fi
if [ -e "$auth_target" ]; then
  [ -f "$auth_target" ] || die 'Codex auth does not resolve to a regular file'
fi
if [ -e "$rc_target" ]; then
  [ -f "$rc_target" ] || die 'shell rc does not resolve to a regular file'
  validate_managed_layout "$rc_target" || die 'shell rc has an invalid ai-cli-installers managed marker layout; the original was left unchanged'
fi

if [ "$install_requested" -eq 1 ] && \
  { ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; }; then
  bootstrap_node
fi

command -v node >/dev/null 2>&1 || die 'node is required to update Codex auth safely'
if [ -e "$auth_target" ]; then
  if ! node - "$auth_target" 2>/dev/null <<'NODE'
const fs = require("fs");
const source = process.argv[2];
const value = JSON.parse(fs.readFileSync(source, 'utf8'));
if (value === null || Array.isArray(value) || typeof value !== 'object') {
  throw new Error('Codex auth must be a JSON object');
}
NODE
  then
    auth_backup=$(next_backup_path "$auth_file")
    cp -p -- "$auth_target" "$auth_backup" || die 'could not back up invalid Codex auth'
    info 'Backed up the invalid Codex auth.'
    die 'existing Codex auth is not a valid JSON object; the original was left unchanged'
  fi
fi

if [ "$install_requested" -eq 1 ]; then
  info 'Installing the official @openai/codex npm package ...'
  npm install --global @openai/codex || die 'Codex CLI installation failed'
  if ! command -v codex >/dev/null 2>&1 || ! codex --version >/dev/null 2>&1; then
    die 'Codex CLI was not available after installation'
  fi
else
  info 'Keeping the existing Codex CLI installation.'
fi

nvm_init_dir=
if [ -n "${NVM_DIR-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
  nvm_init_dir=$NVM_DIR
elif [ -s "$HOME/.nvm/nvm.sh" ]; then
  nvm_init_dir=$HOME/.nvm
fi

# All input files have now passed validation. Back up every existing file
# before preparing or replacing any managed content.
if [ -e "$auth_target" ]; then
  auth_backup=$(next_backup_path "$auth_file")
  cp -p -- "$auth_target" "$auth_backup" || die 'could not back up existing Codex auth'
  info 'Backed up the existing Codex auth.'
fi
if [ -e "$config_target" ]; then
  config_backup=$(next_backup_path "$config_file")
  cp -p -- "$config_target" "$config_backup" || die 'could not back up existing Codex config'
  info 'Backed up the existing Codex config.'
fi
if [ -e "$rc_target" ]; then
  rc_backup=$(next_backup_path "$rc_file")
  cp -p -- "$rc_target" "$rc_backup" || die 'could not back up existing shell rc'
  info 'Backed up the existing shell rc.'
fi

mkdir -p "$HOME/.codex" || die 'could not create the Codex configuration directory'

if ! AUTH_TEMP=$(make_temp_for_target "$auth_target"); then
  die 'could not create a private Codex auth temporary file'
fi
# The JavaScript program and persisted shell expression must remain literal.
# shellcheck disable=SC2016
if ! printf '%s' "$api_key" | node -e '
const fs = require("fs");
const source = process.argv[1];
const destination = process.argv[2];
const apiKey = fs.readFileSync(0, "utf8");
let value = {};
if (fs.existsSync(source)) {
  value = JSON.parse(fs.readFileSync(source, "utf8"));
}
value.OPENAI_API_KEY = apiKey;
fs.writeFileSync(destination, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
' "$auth_target" "$AUTH_TEMP" 2>/dev/null
then
  rm -f -- "$AUTH_TEMP"
  AUTH_TEMP=
  die 'could not prepare Codex auth'
fi

if ! CONFIG_TEMP=$(make_temp_for_target "$config_target"); then
  die 'could not create a private Codex config temporary file'
fi
config_source=/dev/null
[ ! -e "$config_target" ] || config_source=$config_target
if ! render_codex_config "$config_source" >"$CONFIG_TEMP"; then
  die 'could not prepare Codex config after validation'
fi

if ! RC_TEMP=$(make_temp_for_target "$rc_target"); then
  die 'could not create a private shell rc temporary file'
fi
if [ -e "$rc_target" ]; then
  if ! awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start { managed = 1; next }
    $0 == end { managed = 0; next }
    !managed { print }
  ' "$rc_target" >"$RC_TEMP"; then
    die 'could not prepare shell rc'
  fi
else
  : >"$RC_TEMP" || die 'could not create shell rc'
fi

quoted_key=$(shell_quote "$api_key")
{
  printf '%s\n' "$BLOCK_START"
  if [ -n "$nvm_init_dir" ]; then
    quoted_nvm_dir=$(shell_quote "$nvm_init_dir")
    printf 'export NVM_DIR=%s\n' "$quoted_nvm_dir"
    # shellcheck disable=SC2016
    printf '%s\n' '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
  fi
  printf 'export OPENAI_API_KEY=%s\n' "$quoted_key"
  printf '%s\n' "$BLOCK_END"
} >>"$RC_TEMP" || die 'could not write managed shell environment block'

chmod 600 "$CONFIG_TEMP" "$AUTH_TEMP" "$RC_TEMP" 2>/dev/null || true
mv -f -- "$CONFIG_TEMP" "$config_target" || die 'could not replace Codex config'
CONFIG_TEMP=
mv -f -- "$AUTH_TEMP" "$auth_target" || die 'could not replace Codex auth'
AUTH_TEMP=
mv -f -- "$RC_TEMP" "$rc_target" || die 'could not replace shell rc'
RC_TEMP=

info 'Codex CLI configuration is ready; the API key was stored without being displayed.'
