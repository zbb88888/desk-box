#!/usr/bin/env bash
# M46：guest 的控制进程死掉之后，宿主的表现（真机，5 台 VM，依次）。
#
# 新 guest 上不可信程序已经杀不掉控制进程（M42），所以用一套**带测试用故障注入**的 guest 夹具
#（-DDBX_TEST_FAULTS，见 scripts/lib/patched-guest.sh 的 faults 变体）按需制造这件事：
#   /workspace/.dbx-test-die-idle → 主循环下一轮退出；/workspace/.dbx-test-die-exec → exec 等待期间退出。
#
#   N1  对照：正式资产（默认 manifest）**没有**这个开关——不上报 testFaults，触发文件不起作用
#   L1  空闲时死亡：不发任何后续请求，ps 在 2s 内显示 failed 并带原因
#   L2  之后的 exec / stats / ws-sync / 打开终端：立刻失败，原因是 DBX-GUEST-CONTROL-LOST
#   L3  restart：重建出一台可用的新沙箱（旧的被移除）
#   L4  exec 在途时死亡：那条 exec 在 3s 内以 DBX-GUEST-CONTROL-LOST 失败（不是等到超时 + 5s）
#   L5  排在它后面的 exec 同样立刻失败，不会被发给一个已经不存在的控制进程然后等到超时
#   L6  终端会话进行中死亡：轮询立刻报错（此前会一直返回「还在运行、没有输出」）
#   L7  failed 的沙箱都能 rm；daemon 与新建的沙箱不受影响
#
# 没有交叉编译器 / 网络（构建夹具需要）时整个套件 SKIP（计入「环境缺失」）。
# 资源纪律：scripts/lib/e2e-common.sh；夹具建在本次运行的临时目录（或 e2e-all 的共享缓存）里。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init cl
e2e_build_sign
cd "$E2E_ROOT"
STOCK_MANIFEST="$MANIFEST"
export E2E_PATCHED_GUEST_DIR="${E2E_PATCHED_GUEST_DIR:-$E2E_WORK/patched-guest}"
. "$E2E_ROOT/scripts/lib/patched-guest.sh"
patched_guest_prepare cl faults          # 不可用时在这里打印 SKIP 结果并退出（harness 照常清理）
FAULT_MANIFEST="$PATCHED_MANIFEST"
PTY="python3 $E2E_ROOT/scripts/lib/pty_client.py"

e2e_start_daemon || die "daemon 未就绪"
run_sandbox() { # <manifest> → 设置 ID
  ID=$("$BIN" run --daemon-sock "$SOCK" "$1" --memory-mib 1024 --cpus 1 --allow-unsigned-manifest 2>"$E2E_WORK/run.err" | sid_of)
  [ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
}
O="$E2E_WORK/out"; E="$E2E_WORK/err"
x() { # <超时> <命令>
  local t0; t0=$(now_ms)
  "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout "$1" -- /bin/sh -c "$2" >"$O" 2>"$E" && RC=0 || RC=$?
  MS=$(( $(now_ms) - t0 ))
}
state_of() { "$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | awk -F'\t' -v id="$1" '$1==id {print $2}'; }
detail_of() { "$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | awk -F'\t' -v id="$1" '$1==id {print $6}'; }
stat_field() { "$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
wait_failed() { # <id> <最多毫秒> → 0 = 变成 failed；WAITED_MS 是等了多久
  local t0; t0=$(now_ms)
  while [ "$(state_of "$1")" != failed ]; do
    WAITED_MS=$(( $(now_ms) - t0 )); [ "$WAITED_MS" -lt "$2" ] || return 1
    sleep 0.1
  done
  WAITED_MS=$(( $(now_ms) - t0 ))
}

# ---------- N1：正式资产没有这个开关 ----------
run_sandbox "$STOCK_MANIFEST"
[ "$(stat_field testFaults)" = None ] && pass "N1 正式资产不上报 testFaults" || fail "N1 正式资产上报了 testFaults=$(stat_field testFaults)"
x 8 'touch /workspace/.dbx-test-die-idle /workspace/.dbx-test-die-exec; sleep 1.5; echo unaffected'
[ "$RC" = 0 ] && [ "$(cat "$O")" = unaffected ] && pass "N1 正式资产上触发文件不起作用：exec 照常完成" || fail "N1 rc=$RC out=[$(cat "$O")] err=[$(cat "$E")]"
sleep 1
x 5 'ls /workspace/.dbx-test-die-idle /workspace/.dbx-test-die-exec | wc -l'
[ "$RC" = 0 ] && [ "$(tr -d ' ' < "$O")" = 2 ] && [ "$(state_of "$ID")" = running ] \
  && pass "N1 两个触发文件原样留着，沙箱仍是 running" || fail "N1 rc=$RC out=[$(cat "$O")] state=$(state_of "$ID")"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1

# ---------- L1 / L2 / L3：空闲时死亡 ----------
run_sandbox "$FAULT_MANIFEST"
[ "$(stat_field testFaults)" = True ] && pass "对照：这台沙箱跑在带故障注入的夹具上（testFaults=true）" || die "夹具没有故障注入开关（testFaults=$(stat_field testFaults)）"
x 8 'touch /workspace/.dbx-test-die-idle; echo armed'
[ "$RC" = 0 ] && [ "$(cat "$O")" = armed ] && pass "L1 对照：触发故障的那条 exec 自己正常返回" || fail "L1 arm rc=$RC err=[$(cat "$E")]"
wait_failed "$ID" 2000 && pass "L1 控制进程退出后 ${WAITED_MS}ms，ps 显示 failed（期间没有发任何请求）" || fail "L1 2s 后 ps 仍显示 $(state_of "$ID")"
detail_of "$ID" | grep -q 'DBX-GUEST-CONTROL-LOST' && pass "L1 ps 带上了原因（$(detail_of "$ID" | cut -c1-50)）" || fail "L1 ps 没有原因：[$(detail_of "$ID")]"
grep -q "lost its guest control plane" "$DAEMON_LOG" && pass "L1 daemon 日志里有记录" || fail "L1 daemon 日志里没有记录"

x 8 'echo should-not-run'
[ "$RC" != 0 ] && [ "$MS" -lt 1500 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$E" && pass "L2 exec：${MS}ms 内失败，原因 DBX-GUEST-CONTROL-LOST" || fail "L2 exec rc=$RC ${MS}ms err=[$(head -c 200 "$E")]"
t0=$(now_ms); "$BIN" stats --daemon-sock "$SOCK" "$ID" >"$O" 2>"$E" && RC=0 || RC=$?
# stats 是「软失败」：请求本身成功，采样为空，原因放在 statsError 里（界面的资源面板靠它显示）。
[ "$RC" = 0 ] && [ $(( $(now_ms) - t0 )) -lt 1500 ] && grep -q '^statsError=.*DBX-GUEST-CONTROL-LOST' "$O" && grep -q '^cpuUsageUsec=null$' "$O" \
  && pass "L2 stats：立刻返回，没有采样，statsError 给出同样的原因" || fail "L2 stats rc=$RC out=[$(tr '\n' '|' < "$O" | head -c 300)]"
mkdir -p "$E2E_WORK/ws"; echo x > "$E2E_WORK/ws/f.txt"
t0=$(now_ms); "$BIN" ws-sync --daemon-sock "$SOCK" "$ID" "$E2E_WORK/ws" >"$O" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && [ $(( $(now_ms) - t0 )) -lt 1500 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$O" && pass "L2 ws-sync：立刻失败，同样的原因" || fail "L2 ws-sync rc=$RC [$(head -c 200 "$O")]"
t0=$(now_ms); RES=$($PTY "$SOCK" open "$ID" 2>&1)
case "$RES" in FAIL*DBX-GUEST-CONTROL-LOST*) [ $(( $(now_ms) - t0 )) -lt 1500 ] && pass "L2 打开终端：立刻失败，同样的原因" || fail "L2 ptyOpen 等了 $(( $(now_ms) - t0 ))ms" ;; *) fail "L2 ptyOpen：$(printf '%s' "$RES" | head -c 200)" ;; esac

OLD=$ID
NEW=$("$BIN" restart --daemon-sock "$SOCK" "$OLD" 2>"$E2E_WORK/restart.err" | sed -n 's/^restarted -> //p')
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] && [ "$(state_of "$NEW")" = running ] && [ -z "$(state_of "$OLD")" ] \
  && pass "L3 restart：failed 的沙箱被移除，重建出一台 running 的新沙箱" || fail "L3 new=$NEW old-state=$(state_of "$OLD") $(head -c 200 "$E2E_WORK/restart.err")"
ID=${NEW:-$OLD}
x 8 'echo rebuilt-ok; ls /workspace/.dbx-test-die-idle 2>/dev/null | wc -l'
[ "$RC" = 0 ] && [ "$(sed -n 1p "$O")" = rebuilt-ok ] && [ "$(sed -n 2p "$O" | tr -d ' ')" = 0 ] \
  && pass "L3 新沙箱正常工作，而且是全新的（没有带着旧沙箱的 /workspace）" || fail "L3 rc=$RC out=[$(tr '\n' '|' < "$O")] err=[$(cat "$E")]"

# ---------- L4 / L5：exec 在途时死亡 ----------
# （接着用 L3 重建出来的那台）
( "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 30 -- /bin/sh -c 'echo queued-ran' >"$E2E_WORK/q.out" 2>"$E2E_WORK/q.err"; echo $? >"$E2E_WORK/q.rc" ) &
sleep 0.05
# 上面那条先到先跑完；下面这条在途时让控制进程退出。
x 30 'echo started; touch /workspace/.dbx-test-die-exec; sleep 20; echo never'
[ "$RC" != 0 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$E" && pass "L4 exec 在途时控制进程退出：那条 exec 以 DBX-GUEST-CONTROL-LOST 失败" || fail "L4 rc=$RC err=[$(head -c 200 "$E")]"
[ "$MS" -lt 3000 ] && pass "L4 在 ${MS}ms 内失败（命令超时 30s；此前要等到超时 + 5s）" || fail "L4 用时 ${MS}ms"
[ "$(state_of "$ID")" = failed ] && pass "L4 沙箱随即显示 failed" || fail "L4 state=$(state_of "$ID")"
# L5：再排两条进去——它们不应该被发给已经不存在的控制进程然后各等 30s。
t0=$(now_ms)
"$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 30 -- /bin/echo a >/dev/null 2>"$E2E_WORK/l5a.err" && A=0 || A=$?
"$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 30 -- /bin/echo b >/dev/null 2>"$E2E_WORK/l5b.err" && B=0 || B=$?
[ "$A" != 0 ] && [ "$B" != 0 ] && [ $(( $(now_ms) - t0 )) -lt 2000 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$E2E_WORK/l5a.err" "$E2E_WORK/l5b.err" \
  && pass "L5 之后的两条 exec 合计 $(( $(now_ms) - t0 ))ms 内失败并说明原因" || fail "L5 a=$A b=$B $(( $(now_ms) - t0 ))ms"
for _ in $(seq 1 50); do [ -s "$E2E_WORK/q.rc" ] && break; sleep 0.1; done
[ "$(cat "$E2E_WORK/q.rc" 2>/dev/null)" = 0 ] && [ "$(cat "$E2E_WORK/q.out")" = queued-ran ] && pass "L5 对照：故障之前排队的那条 exec 正常完成（不是所有请求都被误伤）" || fail "L5 之前的 exec rc=$(cat "$E2E_WORK/q.rc" 2>/dev/null)"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "L7 exec 中途失去控制面的沙箱可以 rm" || fail "L7 rm 失败"

# ---------- L6：终端会话进行中死亡 ----------
run_sandbox "$FAULT_MANIFEST"
SESS=$($PTY "$SOCK" spawn "$ID" 'echo pty-ready; sleep 1; touch /workspace/.dbx-test-die-idle')
case "$SESS" in FAIL*|"") fail "L6 终端打不开：$SESS" ;; esac
python3 - "$SOCK" "$SESS" >"$E2E_WORK/l6.out" 2>&1 <<'PY'
import json, socket, sys, time
def req(d):
    s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(30)
    s.sendall((json.dumps(d) + "\n").encode()); b = b""
    while not b.endswith(b"\n"):
        c = s.recv(65536)
        if not c: break
        b += c
    return json.loads(b.decode() or "{}")
t0 = time.time(); saw_ready = False
while time.time() - t0 < 15:
    r = req({"kind": "ptyPoll", "ptySessionId": sys.argv[2], "waitMillis": 500})
    if r.get("outputHex") and b"pty-ready" in bytes.fromhex(r["outputHex"]): saw_ready = True
    if not r.get("ok"):
        print("ready=%s failed-after=%.1f code=%s" % (saw_ready, time.time() - t0, "DBX-GUEST-CONTROL-LOST" if "DBX-GUEST-CONTROL-LOST" in (r.get("error") or "") else (r.get("error") or "")[:80]))
        break
else:
    print("ready=%s never-failed" % saw_ready)
PY
grep -q '^ready=True failed-after=.* code=DBX-GUEST-CONTROL-LOST$' "$E2E_WORK/l6.out" \
  && pass "L6 终端会话进行中控制进程退出：轮询报错并说明原因（$(cat "$E2E_WORK/l6.out")）" || fail "L6 $(cat "$E2E_WORK/l6.out")"
FAILED_AFTER=$(sed -n 's/.*failed-after=\([0-9.]*\).*/\1/p' "$E2E_WORK/l6.out")
python3 -c "import sys; sys.exit(0 if float('${FAILED_AFTER:-99}') < 5 else 1)" && pass "L6 没有一直轮询下去（${FAILED_AFTER}s 内报错；终端里的命令先睡了 1s）" || fail "L6 用时 ${FAILED_AFTER:-?}s"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "L7 终端中途失去控制面的沙箱可以 rm" || fail "L7 rm 失败"

# ---------- L7：daemon 不受影响 ----------
run_sandbox "$FAULT_MANIFEST"
x 8 'echo fresh-ok'
[ "$RC" = 0 ] && [ "$(cat "$O")" = fresh-ok ] && pass "L7 daemon 不受影响：之后新建的沙箱正常工作" || fail "L7 新沙箱 rc=$RC err=[$(cat "$E")]"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
[ "$("$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && pass "L7 没有遗留沙箱" || fail "L7 遗留：$("$BIN" ps --daemon-sock "$SOCK" 2>&1 | head -3)"
e2e_finish
