#!/bin/sh
# M12：sandbox 基本操作 run/ps/exec/stop/rm 的端到端测试。
# 默认严格只在真机（codesign VZ entitlement）运行；ARS 附驻 daemon 会话开始/结束。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
SOCK="${DBX_E2E_SOCK:-/tmp/dbxd-e2e-$$.sock}"
MANIFEST="${1:-$ROOT/guest/manifest.json}"
PASS=0
FAIL=0

log()  { printf '[e2e] %s\n' "$1"; }
pass() { PASS=$((PASS+1)); printf '[e2e] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[e2e] FAIL: %s\n' "$1" >&2; }
die()  { printf '[e2e] FATAL: %s\n' "$1" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST (run ./scripts/build-alpine-guest.sh ./guest first)"

cd "$ROOT"
swift build -c release > /dev/null 2>&1 || die "swift build failed"
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements Resources/DeskBox.entitlements --timestamp .build/release/dbx-poc > /dev/null 2>&1 || die "codesign failed"
BIN=.build/release/dbx-poc

# daemon 后台起（crash 路径：进程结束 VM 也同时结束）
rm -f "$SOCK"
"$BIN" daemon --daemon-sock "$SOCK" > /tmp/dbxd-e2e.log 2>&1 &
DAEMON_PID=$!
cleanup() { "$BIN" shutdown --daemon-sock "$SOCK" > /dev/null 2>&1 || true; kill $DAEMON_PID 2> /dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT
sleep 2

# T1 run → ps
OUT=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST")
ID=$(printf '%s' "$OUT" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sandboxId=/){sub("sandboxId=","",$i); print $i}}')
[ -n "$ID" ] && pass "run 返回 sandboxId ($ID)" || fail "run 未返回 sandboxId"
PS_OUT=$("$BIN" ps --daemon-sock "$SOCK")
printf '%s' "$PS_OUT" | grep -q "$ID" && pass "ps 列出运行态沙箱" || fail "ps 中没有 $ID"

# T2 exec 重入
E1=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo e2e-exec-1)
[ "$E1" = "e2e-exec-1" ] && pass "exec 重入第一次输出正确" || fail "exec 输出=$E1"
E2=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo e2e-exec-2)
[ "$E2" = "e2e-exec-2" ] && pass "exec 重入第二次输出正确" || fail "exec 输出=$E2"

# T3 exec 隔离（多沙箱不干扰）
OUT2=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST")
ID2=$(printf '%s' "$OUT2" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sandboxId=/){sub("sandboxId=","",$i); print $i}}')
[ -n "$ID2" ] && [ "$ID2" != "$ID" ] && pass "第二沙箱独立 id ($ID2)" || fail "第二沙箱失败"
M1=$("$BIN" exec --daemon-sock "$SOCK" "$ID"  -- /bin/echo bear1)
M2=$("$BIN" exec --daemon-sock "$SOCK" "$ID2" -- /bin/echo bear2)
[ "$M1" = "bear1" ] && [ "$M2" = "bear2" ] && pass "多沙箱 exec 不串台" || fail "exec 隔离失败"

# T4 失败面
if "$BIN" rm --daemon-sock "$SOCK" "$ID" > /dev/null 2>&1; then
  die "rm 运行态未加 --force 应拒绝"
else
  pass "rm 运行态不 --force 拒绝"
fi
if "$BIN" exec --daemon-sock "$SOCK" 00000000-0000-0000-0000-000000000000 -- /bin/echo bad > /dev/null 2>&1; then
  fail "exec 无 sandbox 非绝望基本此未拒绝"
else
  pass "exec 未知 sandbox 拒绝"
fi

# T5 stop/rm 正常路径
"$BIN" stop --daemon-sock "$SOCK" "$ID" > /dev/null && pass "stop 正常" || fail "stop 失败"
if "$BIN" rm --daemon-sock "$SOCK" "$ID" > /dev/null 2>&1; then
  pass "stopped 状态无需 --force 可 rm"
else
  fail "stopped 状态 rm 应已可通过（如今仍需 --force）"
fi
"$BIN" rm --daemon-sock "$SOCK" "$ID2" --force > /dev/null && pass "rm --force 成功" || fail "rm --force 失败"
PS2=$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')
[ "$PS2" = "0" ] && pass "rm 后 ps 为空" || fail "ps 仍列为 $PS2 个沙箱"

# T6 daemon shutdown + sweep
"$BIN" shutdown --daemon-sock "$SOCK" > /dev/null && pass "shutdown 正常" || fail "shutdown 失败"
sleep 2
SWEEP_OK=$("$BIN" sweep | python3 -c "import json,sys;d=json.load(sys.stdin);sys.stdout.write('OK' if len(d['orphanedSandboxes'])==0 else 'LEAK')" 2>/dev/null || echo LEAK)
[ "$SWEEP_OK" = "OK" ] && pass "shutdown + sweep 后无孤儿" || fail "shutdown 后尚有孤儿"

printf '\n[e2e] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
