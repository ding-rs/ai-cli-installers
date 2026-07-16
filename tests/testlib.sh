#!/usr/bin/env bash

TEST_FAILURES=${TEST_FAILURES:-0}

_TEST_SANDBOX_ROOT=
_TEST_ORIGINAL_HOME_SET=0
_TEST_ORIGINAL_HOME=
if [ "${HOME+x}" = x ]; then
  _TEST_ORIGINAL_HOME_SET=1
  _TEST_ORIGINAL_HOME=$HOME
fi
_TEST_ORIGINAL_PATH_SET=0
_TEST_ORIGINAL_PATH=
if [ "${PATH+x}" = x ]; then
  _TEST_ORIGINAL_PATH_SET=1
  _TEST_ORIGINAL_PATH=$PATH
fi

cleanup_sandbox() {
  if [ -n "$_TEST_SANDBOX_ROOT" ] && [ -d "$_TEST_SANDBOX_ROOT" ]; then
    /bin/rm -rf "$_TEST_SANDBOX_ROOT"
  fi

  _TEST_SANDBOX_ROOT=
  SANDBOX=
  FAKE_BIN=

  if [ "$_TEST_ORIGINAL_HOME_SET" -eq 1 ]; then
    HOME=$_TEST_ORIGINAL_HOME
    export HOME
  else
    unset HOME
  fi

  if [ "$_TEST_ORIGINAL_PATH_SET" -eq 1 ]; then
    PATH=$_TEST_ORIGINAL_PATH
    export PATH
  else
    unset PATH
  fi
}

new_sandbox() {
  cleanup_sandbox

  _TEST_SANDBOX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ai-cli-installers-tests.XXXXXX") || return 1
  SANDBOX=$_TEST_SANDBOX_ROOT
  HOME=$SANDBOX/home
  FAKE_BIN=$SANDBOX/bin
  mkdir -p "$HOME" "$FAKE_BIN"
  PATH="$FAKE_BIN${_TEST_ORIGINAL_PATH:+:$_TEST_ORIGINAL_PATH}"
  export SANDBOX HOME FAKE_BIN PATH
}

make_fake_command() {
  if [ "$#" -ne 2 ]; then
    printf 'make_fake_command: expected a command name and script body\n' >&2
    return 2
  fi
  if [ -z "${FAKE_BIN-}" ] || [ ! -d "$FAKE_BIN" ]; then
    printf 'make_fake_command: call new_sandbox first\n' >&2
    return 2
  fi
  case $1 in
    ''|*/*)
      printf 'make_fake_command: command name must not contain a slash\n' >&2
      return 2
      ;;
  esac

  printf '%s\n' "$2" >"$FAKE_BIN/$1"
  chmod +x "$FAKE_BIN/$1"
}

run_capture() {
  if [ "$#" -eq 0 ]; then
    RUN_OUTPUT='run_capture: command required'
    RUN_STATUS=2
    return 0
  fi

  # RUN_OUTPUT and RUN_STATUS are the public result variables for callers.
  # shellcheck disable=SC2034
  if RUN_OUTPUT=$("$@" 2>&1); then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

_test_failure() {
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf 'not ok - %s\n' "$1" >&2
  return 0
}

assert_file_contains() {
  if [ ! -f "$1" ]; then
    _test_failure "${3:-expected file to exist: $1}"
  elif ! grep -F -- "$2" "$1" >/dev/null 2>&1; then
    _test_failure "${3:-expected $1 to contain: $2}"
  fi
  return 0
}

assert_file_not_contains() {
  if [ ! -f "$1" ]; then
    _test_failure "${3:-expected file to exist: $1}"
  elif grep -F -- "$2" "$1" >/dev/null 2>&1; then
    _test_failure "${3:-expected $1 not to contain: $2}"
  fi
  return 0
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    if [ "$#" -ge 3 ]; then
      _test_failure "$3"
    else
      _test_failure "expected $1, got $2"
    fi
  fi
  return 0
}

assert_not_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    _test_failure "${2:-expected path not to exist: $1}"
  fi
  return 0
}

trap 'cleanup_sandbox' EXIT
