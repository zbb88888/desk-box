#!/bin/sh
# M24：daemon 并发化 + 优雅停机的真机端到端测试。
#
#   T1  run 引导期间 ps 不被阻塞（队头阻塞回归）
#   T2  并行 run：互不丢失（registry 并发 read-modify-write）
#   T3  跨沙箱 exec 真并行、输出不串台
#   T4  A 的长 exec 不阻塞 B 的 exec / ps
#   T5  同沙箱并发 exec 串行化且各自输出正确
#   T6  suspend 与并发 run（sweep）互不破坏：在途快照临时文件不被当孤儿删除
#   T7  并发 rm 同一沙箱：恰好一个成功
#   T8  引导中途 shutdown：ack、run 被中止、进程退出、sock 清除、零残留
#
# 资源纪律（M25，scripts/lib/e2e-common.sh）：全部状态（sock / support-root / cow-root /
# 快照密钥 / 日志 / 调度证据）都在一个 mktemp 目录里，不触碰用户真实状态，也不影响正在运行的
# GUI daemon；EXIT/INT/TERM 统一清理并自检零残留。
set -eu

[ -n "${1:-}" ] && MANIFEST="$1"
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init m24
e2e_build_sign
cd "$E2E_ROOT"
WORK="$E2E_WORK"
COW="$COW_ROOT"
LOG="$DAEMON_LOG"
VM_FLAGS="--memory-mib 1024 --cpus 1"   # 512MiB 不足以引导当前 guest（见 m24 文档）

start_daemon() { e2e_start_daemon || die "daemon 未就绪"; }
start_daemon

# ---------- T1：run 引导期间 ps 不被阻塞 ----------
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-a.out" 2>&1 &
RUN_A=$!
PS_N=0; PS_MAX=0
while kill -0 $RUN_A 2>/dev/null; do
  t0=$(now_ms)
  "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 || true
  dt=$(( $(now_ms) - t0 ))
  PS_N=$((PS_N+1)); [ "$dt" -gt "$PS_MAX" ] && PS_MAX=$dt
  sleep 0.2
done
wait $RUN_A && RC=0 || RC=$?
A=$(sid_of "$WORK/run-a.out")
[ "$RC" = 0 ] && [ -n "$A" ] && pass "run A 成功 ($A)" || { fail "run A 失败：$(cat "$WORK/run-a.out")"; exit 1; }
[ "$PS_N" -ge 2 ] && pass "引导期间 ps 应答 $PS_N 次（旧实现为 0 次，全程阻塞）" || fail "引导期间 ps 仅应答 $PS_N 次"
[ "$PS_MAX" -lt 2000 ] && pass "引导期间 ps 最大延迟 ${PS_MAX}ms < 2000ms" || fail "ps 最大延迟 ${PS_MAX}ms"

# ---------- T2：并行 run ----------
t0=$(now_ms)
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-b.out" 2>&1 & PB=$!
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-c.out" 2>&1 & PC=$!
wait $PB && RB=0 || RB=$?
wait $PC && RCC=0 || RCC=$?
PAR_MS=$(( $(now_ms) - t0 ))
B=$(sid_of "$WORK/run-b.out"); C=$(sid_of "$WORK/run-c.out")
[ "$RB" = 0 ] && [ "$RCC" = 0 ] && [ -n "$B" ] && [ -n "$C" ] && [ "$B" != "$C" ] && [ "$B" != "$A" ] \
  && pass "并行 run B/C 均成功且 id 互异（${PAR_MS}ms）" \
  || { fail "并行 run 失败：B=$(cat "$WORK/run-b.out") C=$(cat "$WORK/run-c.out")"; exit 1; }
N_PS=$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')
[ "$N_PS" = 3 ] && pass "ps 列出 3 个沙箱" || fail "ps 列出 $N_PS 个"
N_REG=$(python3 -c "import json;print(len(json.load(open('$COW/registry.json'))))")
[ "$N_REG" = 3 ] && pass "registry.json 含 3 项（并发 upsert 无丢失）" || fail "registry.json 含 $N_REG 项"

# ---------- T3：跨沙箱 exec 真并行 ----------
t0=$(now_ms)
"$BIN" exec --daemon-sock "$SOCK" "$A" -- /bin/sh -c 'sleep 3; echo par-a' >"$WORK/x-a.out" 2>&1 & XA=$!
"$BIN" exec --daemon-sock "$SOCK" "$B" -- /bin/sh -c 'sleep 3; echo par-b' >"$WORK/x-b.out" 2>&1 & XB=$!
"$BIN" exec --daemon-sock "$SOCK" "$C" -- /bin/sh -c 'sleep 3; echo par-c' >"$WORK/x-c.out" 2>&1 & XC=$!
wait $XA || true; wait $XB || true; wait $XC || true
X_MS=$(( $(now_ms) - t0 ))
[ "$(cat "$WORK/x-a.out")" = par-a ] && [ "$(cat "$WORK/x-b.out")" = par-b ] && [ "$(cat "$WORK/x-c.out")" = par-c ] \
  && pass "3 沙箱并行 exec 输出不串台" || fail "并行 exec 输出错误：$(cat "$WORK"/x-?.out | tr '\n' ' ')"
# 串行需 ≥9s；并行应 ≈3s。
[ "$X_MS" -lt 7000 ] && pass "3×sleep 3 并行耗时 ${X_MS}ms < 7000ms（串行 ≥ 9000ms）" || fail "并行 exec 耗时 ${X_MS}ms（疑似串行）"

# ---------- T4：A 的长 exec 不阻塞 B / ps ----------
"$BIN" exec --daemon-sock "$SOCK" "$A" -- /bin/sh -c 'sleep 5; echo long-a' >"$WORK/long-a.out" 2>&1 & LA=$!
sleep 0.5
t0=$(now_ms)
QB=$("$BIN" exec --daemon-sock "$SOCK" "$B" -- /bin/echo quick-b 2>&1 || true)
QB_MS=$(( $(now_ms) - t0 ))
t0=$(now_ms)
"$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 || true
QP_MS=$(( $(now_ms) - t0 ))
[ "$QB" = quick-b ] && [ "$QB_MS" -lt 2500 ] && pass "A 长 exec 期间 B exec 立即返回（${QB_MS}ms）" || fail "B exec 被阻塞：out=$QB ${QB_MS}ms"
[ "$QP_MS" -lt 1500 ] && pass "A 长 exec 期间 ps 立即返回（${QP_MS}ms）" || fail "ps 被阻塞 ${QP_MS}ms"
wait $LA || true
[ "$(cat "$WORK/long-a.out")" = long-a ] && pass "A 长 exec 自身正常完成" || fail "A 长 exec 输出=$(cat "$WORK/long-a.out")"

# ---------- T5：同沙箱并发 exec（按沙箱串行化） ----------
PIDS=""
for i in 1 2 3 4; do
  "$BIN" exec --daemon-sock "$SOCK" "$A" -- /bin/echo "same-$i" >"$WORK/same-$i.out" 2>&1 & PIDS="$PIDS $!"
done
for p in $PIDS; do wait "$p" || true; done
OK=1
for i in 1 2 3 4; do [ "$(cat "$WORK/same-$i.out")" = "same-$i" ] || OK=0; done
[ "$OK" = 1 ] && pass "同沙箱 4 路并发 exec 各自输出正确（响应不错配）" || fail "同沙箱并发 exec 响应错配：$(cat "$WORK"/same-?.out | tr '\n' ' ')"

# ---------- T6：suspend 与并发 run(sweep) ----------
"$BIN" suspend --daemon-sock "$SOCK" "$B" >"$WORK/susp.out" 2>&1 & PS_=$!
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-d.out" 2>&1 & PD=$!
wait $PS_ && RS=0 || RS=$?
wait $PD && RD=0 || RD=$?
D=$(sid_of "$WORK/run-d.out")
[ "$RS" = 0 ] && pass "并发 run 期间 suspend B 成功" || fail "suspend 失败：$(cat "$WORK/susp.out")"
[ "$RD" = 0 ] && [ -n "$D" ] && pass "suspend 期间 run D 成功" || fail "run D 失败：$(cat "$WORK/run-d.out")"
[ -f "$COW/snapshots/$B.snap" ] && pass "B 的快照未被并发 sweep 误删" || fail "B 的快照缺失"
if e2e_screen_locked; then
  expect_locked_resume "$SOCK" "$B"
  skip_locked "B resume 后 exec 正常"
elif "$BIN" resume --daemon-sock "$SOCK" "$B" >"$WORK/resume.out" 2>&1; then
  RB_OUT=$("$BIN" exec --daemon-sock "$SOCK" "$B" -- /bin/echo resumed-b 2>&1 || true)
  [ "$RB_OUT" = resumed-b ] && pass "B resume 后 exec 正常" || fail "resume 后 exec=$RB_OUT"
else
  fail "resume B 失败：$(cat "$WORK/resume.out")"
fi
TMP_LEFT=$(ls -1 "$COW/snapshots" 2>/dev/null | grep -c '^tmp-' || true)
[ "$TMP_LEFT" = 0 ] && pass "快照目录无 tmp-* 残留" || fail "快照目录残留 $TMP_LEFT 个 tmp 文件"

# ---------- T7：并发 rm 同一沙箱 ----------
"$BIN" rm --daemon-sock "$SOCK" "$C" --force >"$WORK/rm-1.out" 2>&1 & R1=$!
"$BIN" rm --daemon-sock "$SOCK" "$C" --force >"$WORK/rm-2.out" 2>&1 & R2=$!
wait $R1 && S1=0 || S1=1
wait $R2 && S2=0 || S2=1
[ $((S1+S2)) = 1 ] && pass "并发 rm 同一沙箱：恰好一个成功" || fail "并发 rm 结果 S1=$S1 S2=$S2（$(cat "$WORK"/rm-?.out | tr '\n' ' ')）"
N_PS=$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')
[ "$N_PS" = 3 ] && pass "rm 后 ps 剩 3 个（A/B/D）" || fail "rm 后 ps=$N_PS"

# M27：让 shutdown 面对一个 suspended 沙箱（其快照必须随销毁一起清除，见 INV-10）。
"$BIN" suspend --daemon-sock "$SOCK" "$D" >/dev/null 2>&1 && [ -f "$COW/snapshots/$D.snap" ] \
  && pass "shutdown 前 D 处于 suspended 且快照存在（对照）" || fail "D suspend 失败"

# ---------- T8：引导中途 shutdown ----------
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-e.out" 2>&1 & PE=$!
sleep 1
t0=$(now_ms)
"$BIN" shutdown --daemon-sock "$SOCK" >"$WORK/shutdown.out" 2>&1 && SD=0 || SD=$?
SD_MS=$(( $(now_ms) - t0 ))
[ "$SD" = 0 ] && pass "shutdown 得到 ack（${SD_MS}ms，含销毁 3 个运行中沙箱 + 中止 1 个引导）" || fail "shutdown 失败：$(cat "$WORK/shutdown.out")"
wait $PE && RE=0 || RE=$?
if [ "$RE" != 0 ] && grep -q 'draining' "$WORK/run-e.out"; then
  pass "引导中的 run E 被 draining 中止（未静默成功）"
elif [ "$RE" != 0 ]; then
  fail "run E 失败但原因不是 draining：$(cat "$WORK/run-e.out")"
else
  fail "shutdown 之后 run E 竟然成功：$(cat "$WORK/run-e.out")"
fi
e2e_wait_exit "$DAEMON_PID" 100 && pass "daemon 进程已退出" || fail "daemon 进程在 shutdown 后 10s 仍存活"
[ ! -e "$SOCK" ] && pass "daemon 退出时已 unlink socket（无 stale sock）" || fail "socket 残留：$SOCK"

# 零残留：registry 为空、无 COW 克隆盘、无快照、sweep 无孤儿。
N_REG=$(python3 -c "import json,os;p='$COW/registry.json';print(len(json.load(open(p))) if os.path.exists(p) else 0)")
[ "$N_REG" = 0 ] && pass "registry.json 清空" || fail "registry.json 仍有 $N_REG 项"
CLONES=$(find "$COW" -maxdepth 1 -type f ! -name 'registry.json' ! -name 'registry.lock' | wc -l | tr -d ' ')
[ "$CLONES" = 0 ] && pass "cow-root 无克隆盘残留" || fail "cow-root 残留 $CLONES 个文件：$(find "$COW" -maxdepth 1 -type f | tr '\n' ' ')"
SNAPS=$(ls -1 "$COW/snapshots" 2>/dev/null | wc -l | tr -d ' ')
[ "$SNAPS" = 0 ] && pass "快照目录为空" || fail "快照残留 $SNAPS 个"
SWEEP_OK=$("$BIN" sweep | python3 -c "import json,sys;d=json.load(sys.stdin);sys.stdout.write('OK' if len(d['orphanedSandboxes'])==0 and len(d['removedCloneFiles'])==0 else 'LEAK')" 2>/dev/null || echo LEAK)
[ "$SWEEP_OK" = OK ] && pass "sweep 报告零孤儿" || fail "sweep 发现孤儿"
grep -q 'Fatal error\|SIGTRAP\|EXC_BAD' "$LOG" && fail "daemon 日志含崩溃痕迹" || pass "daemon 日志无崩溃痕迹"

# ---------- T9：崩溃（kill -9）后 sweep 零残留（含 M23 域标记 sidecar） ----------
start_daemon
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" $VM_FLAGS >"$WORK/run-f.out" 2>&1 && F=$(sid_of "$WORK/run-f.out") || F=""
if [ -n "$F" ]; then
  ls "$COW" | grep -q '\.domain$' && pass "运行中存在域标记 sidecar（对照组）" || fail "对照组失败：没有 .domain sidecar"
  e2e_kill9 "$DAEMON_PID"
  sleep 1
  FIRST=$("$BIN" sweep | python3 -c "import json,sys;print(len(json.load(sys.stdin)['orphanedSandboxes']))" 2>/dev/null || echo ERR)
  [ "$FIRST" = 1 ] && pass "崩溃后 sweep 发现 1 个孤儿" || fail "崩溃后 sweep 发现 $FIRST 个孤儿"
  LEFT=$(find "$COW" -type f ! -name 'registry.json' ! -name 'registry.lock' | tr '\n' ' ')
  [ -z "$LEFT" ] && pass "崩溃 + sweep 后 cow-root 零残留（clone / sidecar / 快照）" || fail "崩溃后残留：$LEFT"
  [ -S "$SOCK" ] && pass "对照：kill -9 留下 stale socket（位于临时目录，随目录清理）" || fail "kill -9 后 socket 不存在？"
else
  fail "run F 失败：$(cat "$WORK/run-f.out")"
fi

# M25：隔离性自证——快照密钥与调度证据都落在临时 support-root。
[ -f "$DBX_SUPPORT_ROOT/snapshot.key" ] && pass "snapshot.key 位于隔离 support-root" || fail "snapshot.key 不在隔离目录"
[ -f "$DBX_SUPPORT_ROOT/scheduler-decisions.jsonl" ] && pass "调度证据位于隔离 support-root" || fail "调度证据不在隔离目录"

e2e_finish
