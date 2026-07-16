#!/usr/bin/env bash

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$TEST_DIR/testlib.sh"

original_home=${HOME-}
new_sandbox

assert_file_not_contains "$FAKE_BIN/hello" "anything" "missing fixture is reported" 2>/dev/null

make_fake_command hello '#!/bin/sh
printf "hello %s\n" "$1"'

run_capture hello Codex
assert_eq "0" "$RUN_STATUS" "fake command exits successfully"
assert_eq "hello Codex" "$RUN_OUTPUT" "run_capture records command output"
assert_file_contains "$FAKE_BIN/hello" 'hello %s' "fixture contains expected text"
assert_file_not_contains "$FAKE_BIN/hello" "goodbye" "fixture omits unexpected text"
assert_not_exists "$HOME/not-created" "isolated home starts without unrelated files"

if [ -n "$original_home" ]; then
  if [ "$HOME" = "$original_home" ]; then
    printf 'not ok - new_sandbox did not isolate HOME\n' >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
fi

# The first assertion intentionally failed because its fixture did not exist.
observed_failures=$TEST_FAILURES
TEST_FAILURES=0
assert_eq "1" "$observed_failures" "failed assertions increment the failure counter"

cp "$TEST_DIR/run.sh" "$FAKE_BIN/run.sh"
make_fake_command test_20_second.sh '#!/bin/sh
printf "second\n" >>"$HOME/order"'
make_fake_command test_10_first.sh '#!/bin/sh
printf "first\n" >>"$HOME/order"'
make_fake_command test_30_failing.sh '#!/bin/sh
printf "failing\n" >>"$HOME/order"
exit 7'

run_capture bash "$FAKE_BIN/run.sh"
assert_eq "1" "$RUN_STATUS" "test runner returns nonzero when a test fails"
run_order=$(cat "$HOME/order")
assert_eq "first
second
failing" "$run_order" "test runner executes test scripts in lexical order"

make_fake_command test_30_failing.sh '#!/bin/sh
printf "passing\n" >>"$HOME/order"'
: >"$HOME/order"
run_capture bash "$FAKE_BIN/run.sh"
assert_eq "0" "$RUN_STATUS" "test runner succeeds when all tests pass"

if [ "$TEST_FAILURES" -ne 0 ]; then
  exit 1
fi

printf 'ok - testlib helpers\n'
