#!/usr/bin/env bash
# M42：用**当前源码**的 guest bootstrap 跑 broker 入口套件（验证 guest 侧的修复）。
# 夹具的构建与 SKIP / FAIL 规则见 scripts/lib/patched-guest.sh。
set -u
cd "$(dirname "$0")/.."
. scripts/lib/patched-guest.sh
patched_guest_prepare bkp
MANIFEST="$PATCHED_MANIFEST" RUN_FLAGS=--allow-unsigned-manifest EXPECT_BROKER_VERSION=2 ./scripts/e2e-broker-exec.sh
