#!/usr/bin/env bash
# M46：runtime 状态的并发访问（真机，2 台 VM，约 30 秒）。
#
# 背景：VZRuntime 的「在队列上执行」此前并不在队列上（`queue.async { Task { … } }`），操作实际跑在
# Swift 并发的线程池里，与队列上的帧处理并行读写同一个沙箱的状态。全量 E2E 里实际崩过一次：
# 终端输出帧的 `ptyEvents.append` 与终端轮询的 filter / removeAll 撞在一起（EXC_BAD_ACCESS）。
#
# 这个套件把那个场景压到极端：终端里不停地刷输出，同时多个客户端高频轮询、另有 exec 与 stats 并发。
#   R1  压力期间 daemon 不崩溃（进程仍在、没有新的崩溃报告）
#   R2  压力期间的请求没有协议级错误（轮询全部成功；exec 的输出逐条正确）
#   R3  压力之后沙箱照常可用，没有残留
#
# 资源纪律：scripts/lib/e2e-common.sh。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init race
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"
SECONDS_OF_STRESS="${RACE_SECONDS:-20}"
crash_reports() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^dbx-poc' || true; }
CRASHES_BEFORE=$(crash_reports)

e2e_start_daemon || die "daemon 未就绪"
IDS=""
for _ in 1 2; do
  # shellcheck disable=SC2086
  ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
  [ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
  IDS="$IDS $ID"
done

python3 - "$SOCK" "$SECONDS_OF_STRESS" $IDS >"$E2E_WORK/stress.out" 2>&1 <<'PY'
import json, socket, sys, threading, time
sock_path, seconds, ids = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
def req(d, timeout=30):
    s = socket.socket(socket.AF_UNIX); s.connect(sock_path); s.settimeout(timeout)
    s.sendall((json.dumps(d) + "\n").encode()); b = b""
    while not b.endswith(b"\n"):
        c = s.recv(1 << 16)
        if not c: break
        b += c
    s.close()
    return json.loads(b.decode() or "{}")
stats = {"polls": 0, "poll_errors": 0, "poll_bytes": 0, "execs": 0, "exec_errors": 0, "stats": 0, "transport_errors": 0}
lock = threading.Lock()
def bump(key, n=1):
    with lock: stats[key] += n
sessions = {}
for sid in ids:
    opened = req({"kind": "ptyOpen", "sandboxId": sid, "argv": ["/bin/ash", "-l"]})
    sess = opened.get("ptySessionId")
    if not sess:
        print("FATAL open %s" % opened); sys.exit(1)
    sessions[sid] = sess
    # 不停地刷输出：每行都触发一个终端输出帧。
    req({"kind": "ptyInput", "ptySessionId": sess, "dataHex": b"while :; do echo 0123456789abcdefghijklmnopqrstuvwxyz; done\n".hex()})
deadline = time.time() + seconds
def poller(sess):
    while time.time() < deadline:
        try:
            r = req({"kind": "ptyPoll", "ptySessionId": sess, "waitMillis": 5})
        except Exception:
            bump("transport_errors"); time.sleep(0.05); continue
        bump("polls")
        if not r.get("ok"): bump("poll_errors")
        bump("poll_bytes", len(r.get("outputHex") or "") // 2)
def execer(sid, n):
    i = 0
    while time.time() < deadline:
        i += 1
        try:
            r = req({"kind": "exec", "sandboxId": sid, "argv": ["/bin/echo", "x-%d-%d" % (n, i)], "timeoutSeconds": 10})
        except Exception:
            bump("transport_errors"); time.sleep(0.05); continue
        bump("execs")
        if not r.get("ok") or (r.get("stdout") or "").strip() != "x-%d-%d" % (n, i): bump("exec_errors")
def statser(sid):
    while time.time() < deadline:
        try:
            req({"kind": "stats", "sandboxId": sid}); req({"kind": "ps"})
        except Exception:
            bump("transport_errors")
        bump("stats"); time.sleep(0.02)
threads = []
for sid in ids:
    for _ in range(4): threads.append(threading.Thread(target=poller, args=(sessions[sid],)))
    for n in range(2): threads.append(threading.Thread(target=execer, args=(sid, n)))
    threads.append(threading.Thread(target=statser, args=(sid,)))
for t in threads: t.start()
for t in threads: t.join()
for sid in ids:
    try: req({"kind": "ptyClose", "ptySessionId": sessions[sid]})
    except Exception: bump("transport_errors")
print(" ".join("%s=%d" % kv for kv in sorted(stats.items())))
PY
RESULT=$(tail -1 "$E2E_WORK/stress.out")
val() { printf '%s' "$RESULT" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
log "压力 ${SECONDS_OF_STRESS}s：$RESULT"

kill -0 "$DAEMON_PID" 2>/dev/null && pass "R1 压力期间 daemon 没有崩溃（进程仍在）" || fail "R1 daemon 进程已经不在了：$(tail -3 "$DAEMON_LOG" | tr '\n' ' ' | head -c 300)"
sleep 2
[ "$(crash_reports)" = "$CRASHES_BEFORE" ] && pass "R1 没有新的 dbx-poc 崩溃报告" || fail "R1 出现了新的崩溃报告：$(ls -t "$HOME/Library/Logs/DiagnosticReports" | grep '^dbx-poc' | head -1)"
# 轮询次数随机器负载变化很大（每次轮询取回的输出越多，次数越少）；真正说明「撞上了」的是取回的字节数。
[ "$(val polls)" -ge 50 ] 2>/dev/null && [ "$(val poll_bytes)" -ge 1000000 ] 2>/dev/null \
  && pass "R2 对照：压力确实打上去了（$(val polls) 次轮询，取回 $(val poll_bytes) 字节终端输出，$(val execs) 条 exec）" || fail "R2 压力不足：$RESULT"
[ "$(val poll_errors)" = 0 ] && [ "$(val transport_errors)" = 0 ] && pass "R2 轮询全部成功，没有连接层错误" || fail "R2 poll_errors=$(val poll_errors) transport_errors=$(val transport_errors)"
[ "$(val exec_errors)" = 0 ] && [ "$(val execs)" -ge 20 ] 2>/dev/null && pass "R2 并发的 $(val execs) 条 exec 输出逐条正确" || fail "R2 exec_errors=$(val exec_errors) execs=$(val execs)"

AFTER_OK=1
for ID in $IDS; do
  OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo after-stress 2>&1)
  [ "$OUT" = after-stress ] || { AFTER_OK=0; log "压力之后 exec 失败：$(printf '%s' "$OUT" | head -c 160)"; }
  "$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 || AFTER_OK=0
done
[ "$AFTER_OK" = 1 ] && pass "R3 压力之后两台沙箱都照常可用，并已移除" || fail "R3 压力之后沙箱不可用或无法移除"
e2e_finish
