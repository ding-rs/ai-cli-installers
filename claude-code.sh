#!/usr/bin/env bash

set -u
set -o pipefail

PROGRAM_NAME=${0##*/}
INSTALL_URL='https://claude.ai/install.sh'
BLOCK_START='# >>> ai-cli-installers >>>'
BLOCK_END='# <<< ai-cli-installers <<<'
TEMP_FILE=
TTY_ECHO_DISABLED=0
CONFIG_TRANSACTION_ACTIVE=0
CLAUDE_CONFIG_TARGET=
CLAUDE_CONFIG_EXISTED=0
CLAUDE_CONFIG_BACKUP=
CLAUDE_CONFIG_MODIFIED=0
SHELL_RC_TARGET=
SHELL_RC_EXISTED=0
SHELL_RC_BACKUP=
SHELL_RC_MODIFIED=0

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options]

Install and configure Claude Code for an Anthropic-compatible endpoint.

Options:
  --endpoint URL   Exact API base URL (or set AI_ENDPOINT)
  --key KEY        API key (or set AI_API_KEY)
  --yes, -y        Run unattended; skip updating an existing installation
  --reinstall      Force installation or update
  --dry-run        Validate and describe actions without making changes
  --help            Show this help

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
  if [ "$CONFIG_TRANSACTION_ACTIVE" -eq 1 ]; then
    if ! rollback_configuration_transaction; then
      printf 'Error: could not fully roll back Claude configuration; preserved backups were left in place.\n' >&2
    fi
  fi
  if [ -n "$TEMP_FILE" ] && [ -e "$TEMP_FILE" ]; then
    rm -f -- "$TEMP_FILE"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

endpoint=${AI_ENDPOINT-}
api_key=${AI_API_KEY-}
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
    -* )
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

[ "$#" -eq 0 ] || die "unexpected argument: $1"

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

validate_endpoint || die 'endpoint must be an exact http:// or https:// URL without userinfo, query, fragment, whitespace, control characters, backslashes, or an empty host'
[ -n "$api_key" ] || die 'API key must not be empty'

command_exists=0
if command -v claude >/dev/null 2>&1; then
  command_exists=1
fi

install_requested=0
if [ "$command_exists" -eq 0 ] || [ "$reinstall" -eq 1 ]; then
  install_requested=1
elif [ "$assume_yes" -eq 0 ]; then
  answer=
  if can_prompt; then
    printf 'Claude Code is already installed. Reinstall or update it? [y/N] ' >/dev/tty
    IFS= read -r answer </dev/tty || answer=
  fi
  case $answer in
    y|Y|yes|YES|Yes) install_requested=1 ;;
  esac
fi

if [ "$dry_run" -eq 1 ]; then
  info 'Dry run: endpoint is valid and the API key is set (masked).'
  if [ "$install_requested" -eq 1 ]; then
    info "Dry run: would run the official Claude Code installer from $INSTALL_URL."
  else
    info 'Dry run: would keep the existing Claude Code installation.'
  fi
  info 'Dry run: would update the managed shell environment block and Claude configuration.'
  exit 0
fi

if [ "$install_requested" -eq 1 ]; then
  info "Running the official Claude Code installer from $INSTALL_URL ..."
  if ! env -u AI_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      curl -fsSL "$INSTALL_URL" | \
      env -u AI_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN bash; then
    die 'the official Claude Code installer failed'
  fi

  PATH="$HOME/.local/bin:$HOME/.claude/local/bin:$PATH"
  export PATH
  if ! command -v claude >/dev/null 2>&1 || \
      ! env -u AI_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
        claude --version >/dev/null 2>&1; then
    die 'Claude Code was not available after installation'
  fi
else
  info 'Keeping the existing Claude Code installation.'
fi

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

begin_configuration_transaction() {
  CONFIG_TRANSACTION_ACTIVE=1
  CLAUDE_CONFIG_TARGET=
  CLAUDE_CONFIG_EXISTED=0
  CLAUDE_CONFIG_BACKUP=
  CLAUDE_CONFIG_MODIFIED=0
  SHELL_RC_TARGET=
  SHELL_RC_EXISTED=0
  SHELL_RC_BACKUP=
  SHELL_RC_MODIFIED=0
}

rollback_configuration_transaction() {
  local rollback_failed
  rollback_failed=0

  [ "$CONFIG_TRANSACTION_ACTIVE" -eq 1 ] || return 0

  if [ "$SHELL_RC_MODIFIED" -eq 1 ] && [ -n "$SHELL_RC_TARGET" ]; then
    if [ "$SHELL_RC_EXISTED" -eq 1 ]; then
      if [ -n "$SHELL_RC_BACKUP" ] && [ -f "$SHELL_RC_BACKUP" ]; then
        cp -p -- "$SHELL_RC_BACKUP" "$SHELL_RC_TARGET" || rollback_failed=1
      else
        rollback_failed=1
      fi
    else
      rm -f -- "$SHELL_RC_TARGET" || rollback_failed=1
    fi
  fi

  if [ "$CLAUDE_CONFIG_MODIFIED" -eq 1 ] && [ -n "$CLAUDE_CONFIG_TARGET" ]; then
    if [ "$CLAUDE_CONFIG_EXISTED" -eq 1 ]; then
      if [ -n "$CLAUDE_CONFIG_BACKUP" ] && [ -f "$CLAUDE_CONFIG_BACKUP" ]; then
        cp -p -- "$CLAUDE_CONFIG_BACKUP" "$CLAUDE_CONFIG_TARGET" || rollback_failed=1
      else
        rollback_failed=1
      fi
    else
      rm -f -- "$CLAUDE_CONFIG_TARGET" || rollback_failed=1
    fi
  fi

  CONFIG_TRANSACTION_ACTIVE=0
  [ "$rollback_failed" -eq 0 ]
}

commit_configuration_transaction() {
  CONFIG_TRANSACTION_ACTIVE=0
}

create_private_backup() {
  local source_file backup_file previous_umask
  source_file=$1
  backup_file=$2
  previous_umask=$(umask)
  umask 077
  if ! cp -- "$source_file" "$backup_file"; then
    umask "$previous_umask"
    rm -f -- "$backup_file"
    return 1
  fi
  umask "$previous_umask"
  if ! chmod 600 "$backup_file"; then
    rm -f -- "$backup_file"
    return 1
  fi
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

merge_claude_json() {
  local config_file config_target backup_file
  config_file=$HOME/.claude.json
  if ! config_target=$(resolve_write_target "$config_file"); then
    die 'Claude configuration symlink is broken or cyclic; the link was left unchanged'
  fi
  CLAUDE_CONFIG_TARGET=$config_target

  if [ -e "$config_file" ] || [ -L "$config_file" ]; then
    CLAUDE_CONFIG_EXISTED=1
    [ -f "$config_target" ] || die "$config_file does not resolve to a regular file"
    backup_file=$(next_backup_path "$config_file")
    create_private_backup "$config_target" "$backup_file" || die 'could not create an owner-only backup of the existing Claude configuration'
    CLAUDE_CONFIG_BACKUP=$backup_file
    info 'Backed up the existing Claude configuration.'
  fi

  TEMP_FILE="$config_target.ai-cli-installers.tmp.$$"
  rm -f -- "$TEMP_FILE"

  if command -v node >/dev/null 2>&1; then
    if ! node - "$config_target" "$TEMP_FILE" 2>/dev/null <<'NODE'
const fs = require('fs');
const source = process.argv[2];
const destination = process.argv[3];
let value = {};
if (fs.existsSync(source)) {
  value = JSON.parse(fs.readFileSync(source, 'utf8'));
}
if (value === null || Array.isArray(value) || typeof value !== 'object') {
  throw new Error('Claude configuration must be a JSON object');
}
value.hasCompletedOnboarding = true;
fs.writeFileSync(destination, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
NODE
    then
      rm -f -- "$TEMP_FILE"
      TEMP_FILE=
      die 'existing Claude configuration is not a valid JSON object; the original was left unchanged'
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 - "$config_target" "$TEMP_FILE" 2>/dev/null <<'PYTHON'
import json
import os
import sys

source, destination = sys.argv[1:3]
value = {}
if os.path.exists(source):
    with open(source, encoding="utf-8") as handle:
        value = json.load(handle)
if not isinstance(value, dict):
    raise ValueError("Claude configuration must be a JSON object")
value["hasCompletedOnboarding"] = True
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(value, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(destination, 0o600)
PYTHON
    then
      rm -f -- "$TEMP_FILE"
      TEMP_FILE=
      die 'existing Claude configuration is not a valid JSON object; the original was left unchanged'
    fi
  else
    TEMP_FILE=
    die 'node or python3 is required to update Claude configuration safely'
  fi

  chmod 600 "$TEMP_FILE" || die 'could not restrict Claude configuration permissions'
  CLAUDE_CONFIG_MODIFIED=1
  mv -f -- "$TEMP_FILE" "$config_target" || die 'could not replace Claude configuration'
  TEMP_FILE=
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

update_shell_rc() {
  local rc_file rc_target rc_backup quoted_endpoint quoted_key
  rc_file=$(choose_shell_rc)
  if ! rc_target=$(resolve_write_target "$rc_file"); then
    die 'shell rc symlink is broken or cyclic; the link was left unchanged'
  fi
  SHELL_RC_TARGET=$rc_target
  quoted_endpoint=$(shell_quote "$endpoint")
  quoted_key=$(shell_quote "$api_key")
  TEMP_FILE="$rc_target.ai-cli-installers.tmp.$$"
  rm -f -- "$TEMP_FILE"

  if [ -e "$rc_target" ]; then
    SHELL_RC_EXISTED=1
    [ -f "$rc_target" ] || die 'shell rc does not resolve to a regular file'
    rc_backup=$(next_backup_path "$rc_file")
    create_private_backup "$rc_target" "$rc_backup" || die 'could not create an owner-only backup of the existing shell rc file'
    SHELL_RC_BACKUP=$rc_backup
    if ! awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
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
      !managed { print }
      END {
        if (invalid || managed) exit 2
      }
    ' "$rc_target" >"$TEMP_FILE"; then
      die 'shell rc has an invalid ai-cli-installers managed marker layout; the original was left unchanged'
    fi
  else
    : >"$TEMP_FILE" || die 'could not create a shell rc file'
  fi

  chmod 600 "$TEMP_FILE" || die 'could not restrict shell rc permissions before writing the API key'

  {
    printf '%s\n' "$BLOCK_START"
    printf 'export ANTHROPIC_BASE_URL=%s\n' "$quoted_endpoint"
    printf 'export ANTHROPIC_AUTH_TOKEN=%s\n' "$quoted_key"
    printf '%s\n' "$BLOCK_END"
  } >>"$TEMP_FILE" || die 'could not write the managed shell environment block'

  chmod 600 "$TEMP_FILE" || die 'could not restrict shell rc permissions'
  SHELL_RC_MODIFIED=1
  mv -f -- "$TEMP_FILE" "$rc_target" || die 'could not replace the shell rc file'
  TEMP_FILE=
  info "Updated the managed environment block in $rc_file."
}

begin_configuration_transaction
merge_claude_json
update_shell_rc
commit_configuration_transaction
info 'Claude Code configuration is ready; the API key was stored without being displayed.'
