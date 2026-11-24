#!/usr/bin/env python3
"""daemon socket 上的最小 pty 客户端（e2e 用）。

  pty_client.py <sock> open <sandbox-id>              → 打印 ptySessionId（保持会话打开）
  pty_client.py <sock> roundtrip <sandbox-id> <标记>   → 打开、echo 标记、读到后关闭；成功打印 OK
"""
import json, socket, sys

def req(sock_path, d, timeout=30):
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

def main():
    sock, action, sid = sys.argv[1], sys.argv[2], sys.argv[3]
    opened = req(sock, {"kind": "ptyOpen", "sandboxId": sid, "argv": ["/bin/ash", "-l"]})
    sess = opened.get("ptySessionId")
    if not sess:
        print("FAIL:open:%s" % (opened.get("error") or opened)); return 1
    if action == "open":
        print(sess); return 0
    marker = sys.argv[4]
    req(sock, {"kind": "ptyInput", "ptySessionId": sess, "dataHex": ("echo %s\n" % marker).encode().hex()})
    out = ""
    for _ in range(20):
        res = req(sock, {"kind": "ptyPoll", "ptySessionId": sess, "waitMillis": 300})
        if res.get("outputHex"):
            out += bytes.fromhex(res["outputHex"]).decode(errors="replace")
        if marker in out:
            req(sock, {"kind": "ptyClose", "ptySessionId": sess})
            print("OK"); return 0
        if res.get("running") is False:
            break
    print("FAIL:roundtrip:%s" % out[-120:].replace("\n", " ")); return 1

if __name__ == "__main__":
    sys.exit(main())
