#!/usr/bin/env bash
# Desk Box M4 fuzz run（guest C 解析家族）。
# - clang -fsanitize=address,undefined 宿主（macOS）直用口；
# - ASAN/UBSAN 生成即 halt；
# - 每次改动 parse 面后多跑一次看是否污点。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 依赖宿主 clang（Linux/macOS）。
CC=${CC:-clang}
OUT="${1:-/tmp/dbx-fuzz-harness}"

$CC -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
    -Wall -Wextra -Werror \
    "$ROOT/fuzz/c-harness.c" -o "$OUT"

ASAN_OPTIONS=halt_on_error=1 \
  UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  "$OUT"
echo "M4 FUZZ PASS (no taint, no crash)"
