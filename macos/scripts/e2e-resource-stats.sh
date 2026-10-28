#!/usr/bin/env bash
# M21：资源统计 e2e（guest cgroup → daemon stats → CLI）。
set -u
BIN="${BIN:-./.build/release/dbx-poc}"
SOCK="${SOCK:-/tmp/dbx-stats.sock}"
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[stats] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[stats] FAIL: %s\n' "$1"; }

OWN=0
if ! "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1; then
  rm -f "$SOCK"
  "$BIN" daemon --daemon-sock "$SOCK" > /tmp/stats-daemon.log 2>&1 &
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
[ -z "$ID" ] && { echo '[stats] FATAL: run failed'; exit 2; }
printf '[stats] sandbox=%s\n' "$ID"

field() { "$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);v=d.get('$1');print('null' if v is None else v)"; }

CPU0=$(field cpuUsageUsec)
MEM0=$(field memoryCurrentBytes)
[ "$CPU0" != "null" ] && pass "cpuUsageUsec 有值 ($CPU0)" || fail "cpuUsageUsec 为 null（cgroup2 未挂载？）"
[ "$MEM0" != "null" ] && pass "memoryCurrentBytes 有值 ($MEM0)" || fail "memoryCurrentBytes 为 null"
ERR=$(field statsError)
[ "$ERR" = "null" ] && pass "无 statsError" || fail "statsError=$ERR"

# CPU 压力：CPU 微秒必须增长
"$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'i=0; while [ $i -lt 800000 ]; do i=$((i+1)); done' >/dev/null 2>&1 || true
CPU1=$(field cpuUsageUsec)
python3 - "$CPU0" "$CPU1" <<'PY'
import sys
a, b = int(sys.argv[1]), int(sys.argv[2])
print(f'[stats] cpu delta={b-a}us')
sys.exit(0 if b > a else 1)
PY
[ $? = 0 ] && pass "CPU 压力后 cpuUsageUsec 增长" || fail "cpuUsageUsec 未增长 ($CPU0 -> $CPU1)"

# 内存压力：写 8MiB 到 /tmp，memory 必须上升
"$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'dd if=/dev/zero of=/tmp/memburn bs=1M count=8 2>/dev/null; sync; echo ok' >/dev/null 2>&1 || true
MEM1=$(field memoryCurrentBytes)
python3 - "$MEM0" "$MEM1" <<'PY'
import sys
a, b = int(sys.argv[1]), int(sys.argv[2])
print(f'[stats] mem delta={(b-a)//1024}KiB')
sys.exit(0 if b >= a else 1)
PY
[ $? = 0 ] && pass "内存写入后 memoryCurrentBytes 未下降 ($MEM0 -> $MEM1)" || fail "memoryCurrentBytes 异常下降"

# 观测面 fail-soft：不存在的沙箱必须报错但不崩 daemon
if "$BIN" stats --daemon-sock "$SOCK" 00000000-0000-0000-0000-000000000000 >/dev/null 2>&1; then
  fail "未知沙箱 stats 应失败"
else
  pass "未知沙箱 stats 正确失败"
fi
"$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 && pass "daemon 仍存活（观测面不致命）" || fail "daemon 已崩溃"

printf '\n[stats] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
