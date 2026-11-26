#!/usr/bin/env python3
"""M51/M52 测试夹具：模拟一个早于 M51 的 daemon。

只会应答 `ps`（空列表）；其它请求一律用旧 daemon 对不认识的请求的固定措辞拒绝。
每收到一个请求，把它的 kind 追加到日志文件（一行一个），供测试断言「问了几次」。

用法：fake-old-daemon.py <socket 路径> [<日志路径>]
"""
import json, os, socket, sys

path = sys.argv[1]
log = sys.argv[2] if len(sys.argv) > 2 else None
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
os.chmod(path, 0o600)
srv.listen(16)
while True:
    conn, _ = srv.accept()
    try:
        conn.settimeout(5)
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        if not data:
            continue
        kind = json.loads(data.decode()).get("kind", "?")
        if log:
            with open(log, "a") as f:
                f.write(kind + "\n")
        if kind == "ps":
            reply = {"ok": True, "sandboxes": []}
        else:
            reply = {"ok": False, "error": "request rejected (kind=%s): unknown kind=%s" % (kind, kind)}
        conn.sendall((json.dumps(reply) + "\n").encode())
    except Exception:
        pass
    finally:
        conn.close()
