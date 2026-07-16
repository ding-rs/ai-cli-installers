#!/usr/bin/env bash

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
LC_ALL=C
export LC_ALL

status=0
for test_script in "$TEST_DIR"/test_*.sh; do
  [ -f "$test_script" ] || continue
  printf '==> %s\n' "${test_script##*/}"
  if ! bash "$test_script"; then
    status=1
  fi
done

exit "$status"
