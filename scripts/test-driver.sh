#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$0")/.."
TEST_BINARY="$(mktemp -t seiren-fx-tests)"
trap 'rm -rf "$TEST_BINARY" "$TEST_BINARY.dSYM"' EXIT
# SANITIZE=1 builds the tests with AddressSanitizer and UndefinedBehaviorSanitizer,
# and makes any undefined-behavior report fail the run.
SANITIZE_FLAGS=""
if [[ "${SANITIZE:-0}" == 1 ]]; then
  SANITIZE_FLAGS="-g -fsanitize=address,undefined -fno-sanitize-recover=undefined"
fi
# shellcheck disable=SC2086 # SANITIZE_FLAGS is a list of separate flags.
clang -Wall -Wextra -Wno-unused-parameter $SANITIZE_FLAGS -framework CoreAudio -framework CoreFoundation \
  "$ROOT/Driver/SeirenFX/Tests.c" -o "$TEST_BINARY"
"$TEST_BINARY"
