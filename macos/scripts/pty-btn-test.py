#!/usr/bin/env python3
"""pty 协议路径验证（daemon socket 层）。env vars: SOCK2USE, ID2TEST

输出一行，由若干标记组成：
  PTYOK        打开 → 输入 → 读到输出（uid 65534）→ Ctrl+C → 关闭
  REOPENOK     关闭之后再次打开并读到输出（M33：此前 guest 里的 shell 没被杀，再开必超时）
  CLOSED       ptyClose 返回 state=closed（daemon 看到了 guest 的 exit 事件）
  BUSYOK       已有活会话时第二个 ptyOpen 被拒
  RACEOK       关闭与重开并发时，新会话的输出不被关闭过程吃掉
  PREEMPTOK    会话被遗弃（超过阈值没有 poll）后，新的 ptyOpen 抢占成功
失败时输出 FAIL:<阶段>:<细节>。
"""
import json, os, socket, sys, time

sock_path = os.environ["SOCK2USE"]
sid = os.environ["ID2TEST"]
STALE_AFTER = 5.0   # 与 SandboxDaemon.PtyEntry.staleAfter 一致

def req(d, timeout=30):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    s.settimeout(timeout)
    s.sendall((json.dumps(d) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode().strip() or "{}")

def open_pty():
    return req({"kind": "ptyOpen", "sandboxId": sid, "argv": ["/bin/ash", "-l"], "waitMillis": 200})

def roundtrip(sess, marker):
    line = "echo %s; id -u\n" % marker
    req({"kind": "ptyInput", "ptySessionId": sess, "dataHex": line.encode().hex()})
    out = ""
    for _ in range(20):
        res = req({"kind": "ptyPoll", "ptySessionId": sess, "waitMillis": 300})
        h = res.get("outputHex") or ""
        if h:
            out += bytes.fromhex(h).decode(errors="replace")
        if marker in out and "65534" in out:
            return True, out
        if res.get("running") is False:
            break
    return False, out

marks = []
def fail(stage, detail):
    print(" ".join(marks + ["FAIL:%s:%s" % (stage, str(detail)[-160:].replace("\n", " "))]))
    sys.exit(1)

# 1) 基本往返
r = open_pty()
sess = r.get("ptySessionId")
if not sess: fail("open", r)
ok, out = roundtrip(sess, "BTN-TRT")
if not ok: fail("roundtrip", out)
req({"kind": "ptyInput", "ptySessionId": sess, "dataHex": "03"})

# 2) 活会话存在时第二个 open 被拒
busy = open_pty()
if busy.get("ok") is False and "already has an active pty session" in (busy.get("error") or ""):
    marks.append("BUSYOK")
else:
    fail("busy", busy)

# 3) 关闭 → guest 确认退出
closed = req({"kind": "ptyClose", "ptySessionId": sess})
marks.insert(0, "PTYOK")
if closed.get("state") == "closed":
    marks.append("CLOSED")
else:
    fail("close", closed)

# 3b) 关闭与重开并发（GUI 的关闭是异步的，用户关掉终端立刻再开就是这个时序）：
#     关闭过程不得吃掉新会话的输出。
import threading
r_mid = open_pty()
sess_mid = r_mid.get("ptySessionId")
if not sess_mid: fail("reopen-before-race", r_mid)
closer = threading.Thread(target=lambda: req({"kind": "ptyClose", "ptySessionId": sess_mid}))
closer.start()
r_race = None
for _ in range(40):                      # 关闭登记之后才允许新的 open
    r_race = open_pty()
    if r_race.get("ptySessionId"): break
    time.sleep(0.05)
sess_race = (r_race or {}).get("ptySessionId")
if not sess_race: fail("race-open", r_race)
ok, out = roundtrip(sess_race, "RACE-TRT")
closer.join()
if not ok: fail("race-roundtrip", out)
marks.append("RACEOK")
req({"kind": "ptyClose", "ptySessionId": sess_race})

# 4) 再次打开
r2 = open_pty()
sess2 = r2.get("ptySessionId")
if not sess2: fail("reopen", r2)
ok, out = roundtrip(sess2, "REOPEN-TRT")
if not ok: fail("reopen-roundtrip", out)
marks.append("REOPENOK")

# 5) 不关闭、也不再 poll（模拟客户端崩溃）。超过阈值后新的 open 应抢占它。
time.sleep(STALE_AFTER + 1.0)
r3 = open_pty()
sess3 = r3.get("ptySessionId")
if not sess3: fail("preempt", r3)
ok, out = roundtrip(sess3, "PREEMPT-TRT")
if not ok: fail("preempt-roundtrip", out)
# 被抢占的旧会话 id 应已失效。
old = req({"kind": "ptyPoll", "ptySessionId": sess2, "waitMillis": 50})
if old.get("ok") is not False: fail("old-session-still-valid", old)
marks.append("PREEMPTOK")
req({"kind": "ptyClose", "ptySessionId": sess3})
print(" ".join(marks))
