#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$0")/.."
TEST_BINARY="$(mktemp -t seiren-fx-tests)"
trap 'rm -f "$TEST_BINARY"' EXIT
clang -Wall -Wextra -Wno-unused-parameter -framework CoreAudio -framework CoreFoundation \
  "$ROOT/Driver/SeirenFX/Tests.c" -o "$TEST_BINARY"
"$TEST_BINARY"
