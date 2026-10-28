#!/usr/bin/env bash
# M20b：阶段故障注入矩阵（INV-10）。
# 在每个生命周期阶段杀 daemon（模拟崩溃），断言：
#   1) 崩溃后 sweep 能把孤儿状态清理干净（零残留）；
#   2) 崩溃后不会「复活」出可用的旧沙箱（重启 daemon 后 ps 为空）。
set -u
BIN="${BIN:-./.build/release/dbx-poc}"
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
COW_ROOT="${COW_ROOT:-$HOME/Library/Application Support/DeskBox/cows}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[inject] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[inject] FAIL: %s\n' "$1"; }

sock_for() { echo "/tmp/dbx-inject-$1.sock"; }

start_daemon() {
  local sock="$1" log="$2"
  rm -f "$sock"
  "$BIN" daemon --daemon-sock "$sock" > "$log" 2>&1 &
  DAEMON_PID=$!
  for _ in $(seq 1 40); do "$BIN" ps --daemon-sock "$sock" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

kill_daemon() {
  local pid="$1"
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 1
}

count_orphans() {
  "$BIN" sweep 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('orphanedSandboxes',[])))" 2>/dev/null || echo "ERR"
}

count_snapshots() {
  ls -1 "$COW_ROOT/snapshots" 2>/dev/null | wc -l | tr -d ' '
}

# 每个阶段跑一次「起 → 到该阶段 → 杀 → sweep → 断言」
run_stage() {
  local stage="$1" action="$2"
  local sock; sock=$(sock_for "$stage")
  local log="/tmp/inject-$stage.log"
  if ! start_daemon "$sock" "$log"; then fail "$stage: daemon 未就绪"; return; fi
  local id=""
  id=$("$BIN" run --daemon-sock "$sock" "$MANIFEST" 2>/dev/null | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
  if [ -z "$id" ]; then fail "$stage: run 失败"; kill_daemon "$DAEMON_PID"; return; fi
  # 阶段动作（不用 eval，避免引号/展开问题）
  case "$action" in
    exec)    "$BIN" exec --daemon-sock "$sock" "$id" -- /bin/echo inject >/dev/null 2>&1 || true ;;
    suspend) "$BIN" suspend --daemon-sock "$sock" "$id" >/dev/null 2>&1 || true ;;
    pty)     : ;; # pty 由 daemon 内部持有，崩溃后同样应被清扫
    *)       : ;;
  esac
  kill_daemon "$DAEMON_PID"
  # sweep 的 orphanedSandboxes 是「发现并清理」的数量；残留要看第二次 sweep。
  local first; first=$(count_orphans)
  local second; second=$(count_orphans)
  local snapshots; snapshots=$(count_snapshots)
  if [ "$second" = "0" ] && [ "$snapshots" = "0" ]; then
    pass "$stage: 崩溃后 sweep 收敛（首轮发现 $first，次轮 0，快照 0）"
  else
    fail "$stage: 崩溃后残留 second=$second snapshots=$snapshots"
  fi
  # 重启 daemon：不得复活旧沙箱
  local sock2; sock2=$(sock_for "$stage-restart")
  if start_daemon "$sock2" "/tmp/inject-$stage-restart.log"; then
    local listed; listed=$("$BIN" ps --daemon-sock "$sock2" | wc -l | tr -d ' ')
    if [ "$listed" = "0" ]; then pass "$stage: 重启后不复活旧沙箱"; else fail "$stage: 重启后 ps=$listed"; fi
    "$BIN" shutdown --daemon-sock "$sock2" >/dev/null 2>&1
    sleep 1
  else
    fail "$stage: 重启 daemon 失败"
  fi
  rm -f "$sock" "$sock2"
}

echo '[inject] 清理历史残留...'
"$BIN" sweep >/dev/null 2>&1 || true

run_stage "after-run"     none
run_stage "after-exec"    exec
run_stage "after-suspend" suspend

printf '\n[inject] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
