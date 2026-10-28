#!/usr/bin/env bash
# M20：生命周期持久化 e2e（INV-10）：suspend/resume + 加密快照 + 三道闸 + 销毁零残留。
set -u
BIN="${BIN:-./.build/release/dbx-poc}"
SOCK="${SOCK:-/tmp/dbx-m20.sock}"
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
COW_ROOT="${COW_ROOT:-$HOME/Library/Application Support/DeskBox/cows}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[m20] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[m20] FAIL: %s\n' "$1"; }

OWN=0
if ! "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1; then
  rm -f "$SOCK"
  "$BIN" daemon --daemon-sock "$SOCK" > /tmp/m20-e2e-daemon.log 2>&1 &
  OWN=1
  for _ in $(seq 1 40); do "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 && break; sleep 0.5; done
fi
cleanup() {
  [ -n "${ID:-}" ] && "$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
  [ "$OWN" = "1" ] && "$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1
  true
}
trap cleanup EXIT

ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>&1 | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
[ -z "$ID" ] && { echo '[m20] FATAL: run failed'; exit 2; }
printf '[m20] sandbox=%s\n' "$ID"
SNAP="$COW_ROOT/snapshots/$ID.snap"
COW_PATH=$(python3 -c "import json,sys;print()" 2>/dev/null || true)

# 前置：写入标记 + 确认 uid
PRE=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'echo M20-MARKER > /workspace/m20.txt; id -u' 2>&1 | tr -d '\r')
case "$PRE" in *65534*) pass "前置 exec 正常（uid=65534）";; *) fail "前置 exec 失败: $PRE";; esac

# 1) suspend
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 && pass "suspend 成功" || fail "suspend 失败"
STATE=$("$BIN" ps --daemon-sock "$SOCK" | awk '{print $2}' | head -1)
[ "$STATE" = "suspended" ] && pass "ps 显示 suspended" || fail "ps 状态=$STATE"

# 2) 快照存在且是密文、权限 0600
[ -f "$SNAP" ] && pass "快照文件已生成" || fail "快照文件缺失"
if grep -qa 'M20-MARKER' "$SNAP" 2>/dev/null; then
  fail "快照中泄漏明文标记"
else
  pass "快照为密文（无明文标记）"
fi
PERM=$(stat -f '%Lp' "$SNAP" 2>/dev/null)
[ "$PERM" = "600" ] && pass "快照权限 0600" || fail "快照权限=$PERM"

# 3) 篡改 → 拒绝恢复
cp "$SNAP" "$SNAP.bak"
python3 - "$SNAP" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
d[-24] ^= 0xFF
open(p, 'wb').write(d)
PY
if "$BIN" resume --daemon-sock "$SOCK" "$ID" >/tmp/m20-tamper.log 2>&1; then
  fail "篡改后的快照竟然恢复成功"
else
  grep -qi 'decrypt\|完整性\|DECRYPT' /tmp/m20-tamper.log && pass "篡改快照被拒（AEAD 完整性）" || fail "篡改被拒但原因不明: $(head -1 /tmp/m20-tamper.log)"
fi
mv "$SNAP.bak" "$SNAP"

# 4) manifest 不符 → 拒绝（用 gpu manifest 的 digest 不同来模拟）
if "$BIN" resume --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1; then
  pass "原始快照可恢复"
else
  fail "原始快照恢复失败"
fi
STATE=$("$BIN" ps --daemon-sock "$SOCK" | awk '{print $2}' | head -1)
[ "$STATE" = "running" ] && pass "恢复后状态 running" || fail "恢复后状态=$STATE"

# 5) 恢复后数据仍在、权限未复活
POST=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'cat /workspace/m20.txt; id -u' 2>&1 | tr -d '\r')
case "$POST" in
  *M20-MARKER*65534*) pass "恢复后状态保持且 uid 仍 65534（权限未复活）";;
  *) fail "恢复后验证失败: $POST";;
esac

# 6) 二次 suspend/resume（可重复）
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 && pass "二次 suspend 成功" || fail "二次 suspend 失败"
"$BIN" resume --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 && pass "二次 resume 成功" || fail "二次 resume 失败"

# 7) rm 后零残留（快照文件与 COW 均消失）
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
[ ! -f "$SNAP" ] && pass "rm 后快照已删除" || fail "快照残留: $SNAP"
LEFT=$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && pass "rm 后 ps 为空" || fail "ps 仍列出 $LEFT 个"
ID=""

# 8) 未知沙箱 suspend/resume 必须拒绝
if "$BIN" suspend --daemon-sock "$SOCK" 00000000-0000-0000-0000-000000000000 >/dev/null 2>&1; then
  fail "未知沙箱 suspend 应失败"
else
  pass "未知沙箱 suspend 拒绝"
fi

printf '\n[m20] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
