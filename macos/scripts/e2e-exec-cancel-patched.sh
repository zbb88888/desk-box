#!/usr/bin/env bash
# M41：用**当前源码**的 guest bootstrap 跑 exec 取消套件（验证 guest 侧的实现）。
# 夹具的构建与 SKIP / FAIL 规则见 scripts/lib/patched-guest.sh。
set -u
cd "$(dirname "$0")/.."
. scripts/lib/patched-guest.sh
patched_guest_prepare xcp
MANIFEST="$PATCHED_MANIFEST" RUN_FLAGS=--allow-unsigned-manifest EXPECT_EXEC_CANCEL_VERSION=1 ./scripts/e2e-exec-cancel.sh
