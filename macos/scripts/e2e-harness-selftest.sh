#!/usr/bin/env bash
# M25：e2e harness 自测——证明 scripts/lib/e2e-common.sh 在**失败路径**上也能清干净。
# 不起 VM（只起 daemon），几秒跑完。
#
#   C1 正常结束                     → 目录删除、daemon 退出
#   C2 中途 exit 3（daemon 在跑）    → 同上，且退出码保持 3
#   C3 SIGTERM                      → 同上，退出码 143
#   C4 SIGINT                       → 同上，退出码 130
#   C5 daemon 先被 kill -9（stale sock）→ 同上
#   C6 e2e_extra_cleanup 钩子        → 目录外状态被还原
#   C7 E2E_KEEP=1                   → 目录保留（自测自己删）
#   C8 DBX_SUPPORT_ROOT 生效         → daemon 的 socket/状态只出现在隔离目录
#   C9 非法 DBX_SUPPORT_ROOT         → exit 2（fail-closed），不回落默认目录
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/e2e-common.sh"
BIN="${BIN:-$ROOT/.build/release/dbx-poc}"
[ -x "$BIN" ] || { echo "[selftest] FATAL: 先构建 dbx-poc（swift build -c release --product dbx-poc）"; exit 2; }
export BIN E2E_SKIP_BUILD=1

SCRATCH="$(mktemp -d /tmp/dbx-selftest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[selftest] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[selftest] FAIL: %s\n' "$1" >&2; }

# 子脚本：以 $0=scripts/<name> 运行，使 harness 能定位仓库根。
# 子脚本把自己的 E2E_WORK 与 daemon PID 写到 $INFO，供父进程事后核查。
child() { # child <name> <body>   （后台运行由调用方决定）
  INFO="$SCRATCH/$1.info" LIB="$LIB" /bin/sh -c '
    . "$LIB"
    e2e_init "st-'"$1"'"
    e2e_start_daemon || die "daemon 未就绪"
    printf "%s\n%s\n" "$E2E_WORK" "$DAEMON_PID" > "$INFO"
    '"$2"'
  ' "$ROOT/scripts/selftest-$1"
}

# verify <name> <expected-exit> <actual-exit>
verify() {
  local name="$1" want="$2" got="$3"
  local work pid
  work=$(sed -n 1p "$SCRATCH/$name.info" 2>/dev/null)
  pid=$(sed -n 2p "$SCRATCH/$name.info" 2>/dev/null)
  if [ -z "$work" ] || [ -z "$pid" ]; then fail "$name: 子脚本未写出 info（未真正启动）"; return; fi
  [ "$got" = "$want" ] && pass "$name: 退出码 $got" || fail "$name: 退出码 $got（期望 $want）"
  [ ! -e "$work" ] && pass "$name: 临时目录已删除" || { fail "$name: 临时目录残留 $work"; rm -rf "$work"; }
  if kill -0 "$pid" 2>/dev/null; then fail "$name: daemon($pid) 仍存活"; kill -9 "$pid" 2>/dev/null
  else pass "$name: daemon 已退出"; fi
}

# C1
child ok 'exit 0' >/dev/null 2>&1; verify ok 0 $?

# C2
child midexit 'exit 3' >/dev/null 2>&1; verify midexit 3 $?

# C3 / C4：子脚本空转，等它写出 info 后发信号。
for spec in "term TERM 143" "int INT 130"; do
  set -- $spec
  # 作业控制关闭时后台进程默认忽略 SIGINT；用 `trap - INT` 在子 shell 里恢复不了被忽略的信号，
  # 所以经由 perl 重置信号处置后再 exec。
  INFO="$SCRATCH/$1.info" LIB="$LIB" perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' /bin/sh -c '
    . "$LIB"
    e2e_init "st-'"$1"'"
    e2e_start_daemon || die "daemon 未就绪"
    printf "%s\n%s\n" "$E2E_WORK" "$DAEMON_PID" > "$INFO"
    while :; do sleep 0.1; done
  ' "$ROOT/scripts/selftest-$1" >/dev/null 2>&1 &
  cpid=$!
  for _ in $(seq 1 100); do [ -s "$SCRATCH/$1.info" ] && break; sleep 0.1; done
  kill -"$2" "$cpid" 2>/dev/null
  wait "$cpid"; verify "$1" "$3" $?
done

# C5
child crashed 'e2e_kill9 "$DAEMON_PID"; [ -S "$SOCK" ] || exit 9; exit 0' >/dev/null 2>&1; verify crashed 0 $?

# C6：钩子还原目录外状态
OUTSIDE="$SCRATCH/outside.txt"; echo original > "$OUTSIDE"
OUTSIDE="$OUTSIDE" child hook '
  e2e_extra_cleanup() { echo original > "$OUTSIDE"; }
  echo MUTATED > "$OUTSIDE"
  exit 4' >/dev/null 2>&1; verify hook 4 $?
[ "$(cat "$OUTSIDE")" = original ] && pass "hook: e2e_extra_cleanup 在失败路径上还原了目录外状态" || fail "hook: 目录外状态未还原"

# C7
E2E_KEEP=1 child keep 'exit 0' >/dev/null 2>&1; rc=$?
kwork=$(sed -n 1p "$SCRATCH/keep.info"); kpid=$(sed -n 2p "$SCRATCH/keep.info")
[ "$rc" = 0 ] && [ -d "$kwork" ] && pass "keep: E2E_KEEP=1 保留目录" || fail "keep: 目录未保留（rc=$rc）"
kill -0 "$kpid" 2>/dev/null && { fail "keep: daemon 仍存活"; kill -9 "$kpid"; } || pass "keep: daemon 仍被停掉"
case "$kwork" in /tmp/dbx-st-keep.*) rm -rf "$kwork";; esac

# C8：隔离生效
child iso '
  [ -S "$SOCK" ] || exit 11
  "$BIN" ps >/dev/null 2>&1 && exit 12          # 默认 sock = $DBX_SUPPORT_ROOT/dbxd.sock，不存在 → 必须连不上
  "$BIN" sweep >/dev/null 2>&1 || exit 13
  [ -f "$COW_ROOT/registry.lock" ] || exit 14   # sweep 落在隔离 cow-root
  exit 0' >/dev/null 2>&1; rc=$?
verify iso 0 $rc
case $rc in 12) fail "iso: CLI 默认 socket 没有跟随 DBX_SUPPORT_ROOT（连到了别的 daemon）";; esac

# C9：fail-closed
DBX_SUPPORT_ROOT="relative/path" "$BIN" ps >/dev/null 2>"$SCRATCH/bad.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'DBX_SUPPORT_ROOT' "$SCRATCH/bad.err" && pass "非法 DBX_SUPPORT_ROOT → exit 2" || fail "非法 DBX_SUPPORT_ROOT rc=$rc"
DBX_SUPPORT_ROOT="/tmp/../etc" "$BIN" ps >/dev/null 2>&1; [ $? = 2 ] && pass "含 .. 的 DBX_SUPPORT_ROOT → exit 2" || fail ".. 未被拒绝"

LEFT=$(ls -d /tmp/dbx-st-* 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "无 /tmp/dbx-st-* 残留" || { fail "残留：$LEFT"; rm -rf /tmp/dbx-st-*; }

printf '\n[selftest] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
