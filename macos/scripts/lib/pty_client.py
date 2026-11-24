#!/usr/bin/env python3
"""daemon socket 上的最小 pty 客户端（e2e 用）。

  pty_client.py <sock> open <sandbox-id>              → 打印 ptySessionId（保持会话打开）
  pty_client.py <sock> roundtrip <sandbox-id> <标记>   → 打开、echo 标记、读到后关闭；成功打印 OK
  pty_client.py <sock> spawn <sandbox-id> <命令行>      → 打开、送入一行命令、保持会话打开；打印 ptySessionId
  pty_client.py <sock> close <ptySessionId>            → 关闭会话
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
    if action == "close":
        res = req(sock, {"kind": "ptyClose", "ptySessionId": sid})
        print("OK" if res.get("ok") else "FAIL:close:%s" % (res.get("error") or res)); return 0 if res.get("ok") else 1
    opened = req(sock, {"kind": "ptyOpen", "sandboxId": sid, "argv": ["/bin/ash", "-l"]})
    sess = opened.get("ptySessionId")
    if not sess:
        print("FAIL:open:%s" % (opened.get("error") or opened)); return 1
    if action == "open":
        print(sess); return 0
    if action == "spawn":
        sent = req(sock, {"kind": "ptyInput", "ptySessionId": sess, "dataHex": (sys.argv[4] + "\n").encode().hex()})
        if not sent.get("ok"):
            print("FAIL:input:%s" % (sent.get("error") or sent)); return 1
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
