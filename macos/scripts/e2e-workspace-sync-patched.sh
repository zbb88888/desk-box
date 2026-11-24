#!/usr/bin/env bash
# M37：用**当前源码**的 guest bootstrap 跑 workspace 同步套件（验证 guest 侧的修复）。
# 夹具的构建与 SKIP / FAIL 规则见 scripts/lib/patched-guest.sh。
set -u
cd "$(dirname "$0")/.."
. scripts/lib/patched-guest.sh
patched_guest_prepare wsp
# 这个套件存在的意义就是验证新接收端：跑到的不是版本 2 就算失败（否则会「全绿但什么都没验证」）。
MANIFEST="$PATCHED_MANIFEST" RUN_FLAGS=--allow-unsigned-manifest EXPECT_RECEIVER_VERSION=2 ./scripts/e2e-workspace-sync.sh
