#!/usr/bin/env python3
"""M17 buttons-e2e：pty Send/Ctrl+C 路径验证。env vars: SOCK2USE, ID2TEST"""
import json, os, socket, sys

sock_path = os.environ["SOCK2USE"]
sid = os.environ["ID2TEST"]

def req(d):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    s.settimeout(30)
    s.sendall((json.dumps(d) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode().strip() or "{}")

r = req({"kind": "ptyOpen", "sandboxId": sid, "argv": ["/bin/ash", "-l"], "waitMillis": 200})
sess = r.get("ptySessionId")
if not sess:
    print("NOSESS", r)
    sys.exit(1)
req({"kind": "ptyInput", "ptySessionId": sess, "dataHex": "6563686f2042544e2d5452543b206964202d750a"})
out = ""
for _ in range(12):
    res = req({"kind": "ptyPoll", "ptySessionId": sess, "waitMillis": 300})
    h = res.get("outputHex") or ""
    if h:
        out += bytes.fromhex(h).decode(errors="replace")
    if "BTN-TRT" in out and "65534" in out:
        break
req({"kind": "ptyInput", "ptySessionId": sess, "dataHex": "03"})
req({"kind": "ptyClose", "ptySessionId": sess})
print("PTYOK" if ("BTN-TRT" in out and "65534" in out) else "PTYPART:" + out[-120:])
