#!/usr/bin/env bash
# M20b：阶段故障注入矩阵（INV-10）。
# 在每个生命周期阶段杀 daemon（模拟崩溃），断言：
#   1) 崩溃后 sweep 能把孤儿状态清理干净（零残留：clone / 域标记 / 快照）；
#   2) 崩溃后不会「复活」出可用的旧沙箱（重启 daemon 后 ps 为空）。
# M25：隔离运行（scripts/lib/e2e-common.sh）——状态全在临时目录，退出自动清理；
#      被 kill -9 的 daemon 留下的 socket 也在该目录内，随目录一并删除。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init inject
e2e_build_sign
cd "$E2E_ROOT"

sock_for() { echo "$E2E_WORK/$1.sock"; }

start_daemon() { e2e_start_daemon "$1" "$2"; }

kill_daemon() {
  e2e_kill9 "$1"
  sleep 1
}

count_orphans() {
  "$BIN" sweep 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d.get('orphanedSandboxes',[])))" 2>/dev/null || echo "ERR"
}

count_snapshots() {
  ls -1 "$COW_ROOT/snapshots" 2>/dev/null | wc -l | tr -d ' '
}

# clone / 域标记 sidecar / 快照 / 临时文件，一律算残留（registry 自身除外）。
count_residue() {
  find "$COW_ROOT" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | wc -l | tr -d ' '
}

# 每个阶段跑一次「起 → 到该阶段 → 杀 → sweep → 断言」
run_stage() {
  local stage="$1" action="$2"
  local sock; sock=$(sock_for "$stage")
  local log="$E2E_WORK/$stage.log"
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
  local residue; residue=$(count_residue)
  # first 必须正好是 1：0 说明崩溃根本没留下可清理的东西（用例失效），不是「干净」。
  if [ "$first" = "1" ] && [ "$second" = "0" ] && [ "$snapshots" = "0" ] && [ "$residue" = "0" ]; then
    pass "$stage: 崩溃后 sweep 收敛（首轮发现 1，次轮 0，快照 0，cow-root 残留 0）"
  else
    fail "$stage: 崩溃后 first=$first second=$second snapshots=$snapshots residue=$residue"
  fi
  # 重启 daemon：不得复活旧沙箱
  local sock2; sock2=$(sock_for "$stage-restart")
  if start_daemon "$sock2" "$E2E_WORK/$stage-restart.log"; then
    local listed; listed=$("$BIN" ps --daemon-sock "$sock2" | wc -l | tr -d ' ')
    if [ "$listed" = "0" ]; then pass "$stage: 重启后不复活旧沙箱"; else fail "$stage: 重启后 ps=$listed"; fi
    "$BIN" shutdown --daemon-sock "$sock2" >/dev/null 2>&1
    e2e_wait_exit "$DAEMON_PID" 100 || fail "$stage: 重启的 daemon 未退出"
  else
    fail "$stage: 重启 daemon 失败"
  fi
}

run_stage "after-run"     none
run_stage "after-exec"    exec
run_stage "after-suspend" suspend

e2e_finish
