#!/usr/bin/env bash
# M41：取消在途的 exec（真机，1 台 VM）。
#
# 脚本按 guest 是否支持取消（stats 里的 execCancelVersion）自动分支：
#   支持（当前源码）：
#     C1  exec-cancel：立刻返回「exec cancelled」；那条 exec 带着取消之前的输出返回，exit 253
#     C2  guest 里的进程真的没了（心跳文件不再增长）
#     C3  没有在途 exec 时：DBX-EXEC-NOT-RUNNING
#     C4  排队中的 exec 不会被误伤：取消只命中在途的那一条，排队的随后正常执行
#     C5  Ctrl-C（SIGINT 给 `dbx-poc exec` 客户端）：命令被取消，客户端以 130 退出并带回已有输出
#     C6  exec 期间到达的其它帧不丢：取消之前送入终端的输入，取消之后照常生效
#     C7  大量输出中取消：照样立刻停
#     C8  之后 guest 响应正常，没有残留的 exec cgroup
#   M42：客户端断开（两种 guest 都测；标 * 的只在支持取消的 guest 上成立）：
#     D1* 在途 exec 的客户端被 kill -9：daemon 发现后请求取消，guest 里的命令被杀，沙箱随即可用
#     D2  排队中 exec 的客户端被 kill -9：轮到它时不再执行
#     D3  半关闭的客户端（发完请求就 shutdown 写端，仍在等应答）不被当成断开
#   不支持（旧 guest）——宿主按**实际结果**如实报告：
#     K1  exec-cancel：约 3s 后报 DBX-EXEC-CANCEL-UNSUPPORTED；那条 exec 不受影响，照常跑完
#     K2  Ctrl-C：客户端在数秒内以 130 退出并说明原因（命令留在 guest 里跑完——与此前行为相同）
#     K3  那个旧 guest 不认识的取消帧没有破坏控制通道：之后 exec 正常
#
# 用法同 e2e-workspace-sync.sh（MANIFEST / RUN_FLAGS）。资源纪律：scripts/lib/e2e-common.sh。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init xc
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"
PTY="python3 $E2E_ROOT/scripts/lib/pty_client.py"

e2e_start_daemon || die "daemon 未就绪"
# shellcheck disable=SC2086
ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
[ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
CV=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('execCancelVersion') or 0)" 2>/dev/null || echo 0)
log "guest 的 exec 取消支持：$CV（0 = 不支持）"
if [ -n "${EXPECT_EXEC_CANCEL_VERSION:-}" ]; then
  [ "$CV" = "$EXPECT_EXEC_CANCEL_VERSION" ] && pass "guest exec 取消版本 = $CV（符合预期）" || fail "guest exec 取消版本 = $CV（期望 $EXPECT_EXEC_CANCEL_VERSION）"
fi

gexec() { "$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c "$1" 2>&1; }
cancel() { "$BIN" exec-cancel --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/cancel.out" 2>&1; }
# bg_exec <名字> <超时> <命令>：后台启动一条 exec；输出在 $E2E_WORK/<名字>.{out,err,rc}；PID 记在 BG_PID 并登记给 harness
bg_exec() {
  local name="$1" timeout="$2" cmd="$3"
  ( "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout "$timeout" -- /bin/sh -c "$cmd" >"$E2E_WORK/$name.out" 2>"$E2E_WORK/$name.err"; echo $? >"$E2E_WORK/$name.rc" ) &
  BG_PID=$!
}
# wait_rc <名字> <最多毫秒>：等后台 exec 结束；成功返回 0，RC 里是它的退出码
wait_rc() {
  local name="$1" limit="$2" t0; t0=$(now_ms)
  while [ ! -s "$E2E_WORK/$name.rc" ]; do
    [ $(( $(now_ms) - t0 )) -lt "$limit" ] || return 1
    sleep 0.05
  done
  RC=$(cat "$E2E_WORK/$name.rc")
}
hb_count() { gexec 'wc -l < /workspace/hb 2>/dev/null || echo 0' | tr -d ' \n'; }
HEARTBEAT='echo started; while :; do echo x >> /workspace/hb; sleep 0.2; done'

# ---------- 两种 guest 都成立 ----------
cancel && RC=0 || RC=$?
[ "$RC" = 2 ] && grep -q 'DBX-EXEC-NOT-RUNNING' "$E2E_WORK/cancel.out" && pass "C3 没有在途 exec 时：exec-cancel 报 DBX-EXEC-NOT-RUNNING" || fail "C3 rc=$RC $(cat "$E2E_WORK/cancel.out")"

if [ "$CV" -ge 1 ]; then
  # ---------- C1 / C2 ----------
  bg_exec c1 60 "$HEARTBEAT"
  sleep 1.5
  t0=$(now_ms); cancel && RC=0 || RC=$?; CANCEL_MS=$(( $(now_ms) - t0 ))
  [ "$RC" = 0 ] && [ "$(cat "$E2E_WORK/cancel.out")" = "exec cancelled" ] && [ "$CANCEL_MS" -lt 2000 ] \
    && pass "C1 exec-cancel 返回「exec cancelled」（${CANCEL_MS}ms）" || fail "C1 cancel rc=$RC ${CANCEL_MS}ms $(cat "$E2E_WORK/cancel.out")"
  wait_rc c1 3000 && pass "C1 被取消的 exec 随即返回（没有等到 60s 超时）" || fail "C1 exec 没有返回"
  [ "${RC:-}" = 253 ] && [ "$(cat "$E2E_WORK/c1.out")" = started ] && grep -q 'exec cancelled; process group killed' "$E2E_WORK/c1.err" \
    && pass "C1 exec 的结果：exit 253，取消之前的输出还在，stderr 说明了取消" || fail "C1 rc=${RC:-?} out=[$(cat "$E2E_WORK/c1.out")] err=[$(cat "$E2E_WORK/c1.err")]"
  H1=$(hb_count); sleep 1; H2=$(hb_count)
  [ "$H1" -ge 3 ] && [ "$H1" = "$H2" ] && pass "C2 guest 里的进程真的没了（心跳停在 $H1，1 秒后仍是 $H2）" || fail "C2 心跳 $H1 → $H2"

  # ---------- C4：排队中的 exec ----------
  bg_exec c4a 60 'echo A-started; sleep 50'
  sleep 1
  bg_exec c4b 20 'echo B-ran'
  sleep 0.7
  [ ! -s "$E2E_WORK/c4b.rc" ] && pass "C4 对照：B 确实在排队（A 在途时它还没有结果）" || fail "C4 对照失败：B 已经返回"
  cancel && RC=0 || RC=$?
  [ "$RC" = 0 ] && pass "C4 取消成功" || fail "C4 cancel rc=$RC $(cat "$E2E_WORK/cancel.out")"
  wait_rc c4a 3000 && [ "$RC" = 253 ] && pass "C4 在途的 A 被取消（exit 253）" || fail "C4 A rc=${RC:-?}"
  wait_rc c4b 5000 && [ "$RC" = 0 ] && [ "$(cat "$E2E_WORK/c4b.out")" = B-ran ] && pass "C4 排队的 B 没有被误伤：随后正常执行" || fail "C4 B rc=${RC:-?} out=[$(cat "$E2E_WORK/c4b.out")] err=[$(cat "$E2E_WORK/c4b.err")]"

  # ---------- C5：Ctrl-C ----------
  gexec 'rm -f /workspace/hb' >/dev/null
  "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 60 -- /bin/sh -c "$HEARTBEAT" >"$E2E_WORK/c5.out" 2>"$E2E_WORK/c5.err" &
  CLIENT=$!
  sleep 1.5
  t0=$(now_ms); kill -INT "$CLIENT"
  wait "$CLIENT"; RC=$?; INT_MS=$(( $(now_ms) - t0 ))
  [ "$RC" = 130 ] && [ "$INT_MS" -lt 3000 ] && pass "C5 Ctrl-C：客户端以 130 退出（${INT_MS}ms）" || fail "C5 rc=$RC ${INT_MS}ms err=[$(cat "$E2E_WORK/c5.err")]"
  [ "$(cat "$E2E_WORK/c5.out")" = started ] && grep -q 'exec cancelled' "$E2E_WORK/c5.err" && pass "C5 已有的输出被带回，stderr 说明了取消" || fail "C5 out=[$(cat "$E2E_WORK/c5.out")] err=[$(cat "$E2E_WORK/c5.err")]"
  H1=$(hb_count); sleep 1; H2=$(hb_count)
  [ "$H1" -ge 3 ] && [ "$H1" = "$H2" ] && pass "C5 guest 里的命令被杀掉了（心跳停在 $H1）；沙箱随即可用" || fail "C5 心跳 $H1 → $H2"

  # ---------- C6：exec 期间到达的其它帧 ----------
  SESS=$($PTY "$SOCK" open "$ID")
  case "$SESS" in FAIL*|"") fail "C6 终端打不开：$SESS" ;; esac
  bg_exec c6 60 'sleep 50'
  sleep 1
  [ "$($PTY "$SOCK" input "$SESS" 'echo queued-$((40+2))-frame')" = OK ] && pass "C6 exec 在途时向终端送入一行（guest 此刻读到的是一个「不是取消」的帧）" || fail "C6 送入失败"
  sleep 0.5
  cancel && RC=0 || RC=$?
  wait_rc c6 3000 && [ "$RC" = 253 ] && pass "C6 之后的取消仍然命中在途的 exec" || fail "C6 exec rc=${RC:-?} cancel=$(cat "$E2E_WORK/cancel.out")"
  [ "$($PTY "$SOCK" expect "$SESS" 'queued-42-frame' 6)" = OK ] && pass "C6 那一行输入没有丢：exec 结束后照常生效（终端里出现了它的输出）" || fail "C6 终端输入丢失"
  $PTY "$SOCK" close "$SESS" >/dev/null 2>&1

  # ---------- C7：大量输出中取消 ----------
  bg_exec c7 60 'while :; do echo yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy; done'
  sleep 1.5
  t0=$(now_ms); cancel && RC=0 || RC=$?; CANCEL_MS=$(( $(now_ms) - t0 ))
  [ "$RC" = 0 ] && [ "$CANCEL_MS" -lt 2500 ] && pass "C7 输出不停的命令也能取消（${CANCEL_MS}ms）" || fail "C7 cancel rc=$RC ${CANCEL_MS}ms $(cat "$E2E_WORK/cancel.out")"
  wait_rc c7 5000 && [ "$RC" = 253 ] && [ "$(wc -c < "$E2E_WORK/c7.out" | tr -d ' ')" -gt 1000 ] \
    && pass "C7 exec 返回 exit 253，带回 $(wc -c < "$E2E_WORK/c7.out" | tr -d ' ') 字节的已有输出" || fail "C7 rc=${RC:-?} bytes=$(wc -c < "$E2E_WORK/c7.out")"
else
  # ---------- K1 ----------
  bg_exec k1 30 'echo k1-started; sleep 6; echo k1-finished'
  sleep 1
  t0=$(now_ms); cancel && RC=0 || RC=$?; CANCEL_MS=$(( $(now_ms) - t0 ))
  [ "$RC" = 2 ] && grep -q 'DBX-EXEC-CANCEL-UNSUPPORTED' "$E2E_WORK/cancel.out" && pass "K1 旧 guest：exec-cancel 如实报告 DBX-EXEC-CANCEL-UNSUPPORTED" || fail "K1 rc=$RC $(cat "$E2E_WORK/cancel.out")"
  [ "$CANCEL_MS" -ge 2500 ] && [ "$CANCEL_MS" -lt 4500 ] && pass "K1 是等了约 3s、确认命令没有结束之后才下的结论（${CANCEL_MS}ms）" || fail "K1 用时 ${CANCEL_MS}ms"
  wait_rc k1 9000 && [ "$RC" = 0 ] && [ "$(cat "$E2E_WORK/k1.out")" = "$(printf 'k1-started\nk1-finished')" ] \
    && pass "K1 那条 exec 不受影响：照常跑完，输出完整" || fail "K1 exec rc=${RC:-?} out=[$(cat "$E2E_WORK/k1.out")] err=[$(cat "$E2E_WORK/k1.err")]"
  [ "$(gexec 'echo after-stray-cancel')" = after-stray-cancel ] && pass "K3 旧 guest 不认识的取消帧没有破坏控制通道：之后 exec 正常" || fail "K3 之后 exec 失败"

  # ---------- K2：Ctrl-C ----------
  "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 30 -- /bin/sh -c 'echo k2-started; sleep 5' >"$E2E_WORK/k2.out" 2>"$E2E_WORK/k2.err" &
  CLIENT=$!
  sleep 1
  t0=$(now_ms); kill -INT "$CLIENT"
  wait "$CLIENT"; RC=$?; INT_MS=$(( $(now_ms) - t0 ))
  [ "$RC" = 130 ] && [ "$INT_MS" -lt 4500 ] && pass "K2 旧 guest 上 Ctrl-C：客户端以 130 退出（${INT_MS}ms，不会陪着命令等到结束）" || fail "K2 rc=$RC ${INT_MS}ms"
  grep -q '无法取消 guest 里的命令' "$E2E_WORK/k2.err" && grep -q 'DBX-EXEC-CANCEL-UNSUPPORTED' "$E2E_WORK/k2.err" && pass "K2 并说明了原因" || fail "K2 没有说明：$(cat "$E2E_WORK/k2.err")"
  sleep 3   # 让留在 guest 里的那条命令跑完，免得影响收尾检查
fi

# ---------- M42：客户端断开 ----------
gexec 'rm -f /workspace/hb /workspace/d2-ran' >/dev/null
# D2：排队中的 exec，客户端在它开始之前就被杀（宿主侧逻辑，与 guest 版本无关）
bg_exec d2a 20 'sleep 3; echo d2a-done'
sleep 0.8
"$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 20 -- /bin/sh -c 'echo ran > /workspace/d2-ran' >/dev/null 2>&1 &
QUEUED=$!
sleep 0.6
kill -9 "$QUEUED" 2>/dev/null; wait "$QUEUED" 2>/dev/null
wait_rc d2a 8000 && [ "$RC" = 0 ] && pass "D2 对照：在途的那条（别人的）exec 照常跑完" || fail "D2 在途 exec rc=${RC:-?}"
sleep 0.5
[ "$(gexec '[ -e /workspace/d2-ran ] && echo ran || echo not-run')" = not-run ] && pass "D2 排队中的 exec：客户端被 kill -9 之后，轮到它时没有执行" || fail "D2 没人要的 exec 仍然执行了"
grep -q 'DBX-EXEC-CLIENT-GONE' "$DAEMON_LOG" && pass "D2 daemon 日志记录了原因（DBX-EXEC-CLIENT-GONE）" || fail "D2 daemon 日志里没有 DBX-EXEC-CLIENT-GONE"

# D3：半关闭的客户端
python3 - "$SOCK" "$ID" >"$E2E_WORK/d3.out" 2>&1 <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(20)
s.sendall((json.dumps({"kind": "exec", "sandboxId": sys.argv[2], "argv": ["/bin/sh", "-c", "sleep 1.5; echo half-close-ok"], "timeoutSeconds": 10}) + "\n").encode())
s.shutdown(socket.SHUT_WR)
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
r = json.loads(buf.decode())
print("exit=%s cancelled=%s out=%s" % (r.get("exitCode"), r.get("cancelled"), (r.get("stdout") or "").strip()))
PY
[ "$(cat "$E2E_WORK/d3.out")" = "exit=0 cancelled=None out=half-close-ok" ] && pass "D3 半关闭的客户端不被当成断开：命令跑完，应答完整（前导探测字节不影响解析）" || fail "D3 $(cat "$E2E_WORK/d3.out")"

# D1：在途 exec 的客户端被 kill -9
"$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 8 -- /bin/sh -c "$HEARTBEAT" >/dev/null 2>&1 &
VICTIM=$!
sleep 1.5
kill -9 "$VICTIM" 2>/dev/null; wait "$VICTIM" 2>/dev/null
sleep 1
grep -q 'exec client disconnected; cancelling in-flight exec' "$DAEMON_LOG" && pass "D1 daemon 发现在途 exec 的客户端断开，并请求取消" || fail "D1 daemon 没有发现客户端断开"
if [ "$CV" -ge 1 ]; then
  t0=$(now_ms); H1=$(hb_count); PROBE_MS=$(( $(now_ms) - t0 )); sleep 1; H2=$(hb_count)
  [ "$H1" -ge 3 ] && [ "$H1" = "$H2" ] && pass "D1 guest 里的命令被杀掉了（心跳停在 $H1）" || fail "D1 心跳 $H1 → $H2"
  [ "$PROBE_MS" -lt 2000 ] && pass "D1 沙箱随即可用（下一条 exec ${PROBE_MS}ms 返回，没有排在那条 8s 的命令后面）" || fail "D1 下一条 exec 等了 ${PROBE_MS}ms"
else
  log "D1 旧 guest：取消帧被忽略，命令在 guest 里跑到超时（与此前行为相同）"
  sleep 7
fi

# ---------- 收尾 ----------
[ "$(gexec 'echo still-alive')" = still-alive ] && pass "C8 之后 guest 仍然响应" || fail "C8 之后 guest 不再响应"
GROUPS_LEFT=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('activeExecGroups'))" 2>/dev/null)
[ "$GROUPS_LEFT" = 0 ] && pass "C8 没有残留的 exec cgroup（activeExecGroups=0）" || fail "C8 activeExecGroups=$GROUPS_LEFT"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "沙箱已移除" || fail "rm 失败"
e2e_finish
