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

if command -v pwsh >/dev/null 2>&1; then
  for test_script in "$TEST_DIR"/test_*.ps1; do
    [ -f "$test_script" ] || continue
    printf '==> %s\n' "${test_script##*/}"
    if ! pwsh -NoLogo -NoProfile -NonInteractive -File "$test_script"; then
      status=1
    fi
  done
else
  printf '%s\n' '==> PowerShell behavior tests (skipped: pwsh not found)'
fi

exit "$status"
