#!/usr/bin/env bash
# M17 buttons-e2e：GUI 每个按钮的功能路径用同一 daemon socket 协议验证。
# 前提：GUI 已经 launch 且 autostartDaemon=true（在生产环境同一 daemon 域）。
set -u

BIN="${BIN:-./.build/release/dbx-poc}"
SOCK="${SOCK:-$HOME/Library/Application Support/DeskBox/dbxd.sock}"
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[btn] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[btn] FAIL: %s\n' "$1"; }

printf '[btn] sock=%s manifest=%s\n' "$SOCK" "$MANIFEST"

# --- 0. GUI/daemon 存活（Start Daemon / autostart path）
if ps aux | grep -q 'DeskBoxGU[I]'; then pass "GUI 进程在"; else fail "GUI 不在"; fi
if "$BIN" ps --daemon-sock "$SOCK" > /dev/null 2>&1; then pass "Start Daemon/autotart 充 daemon 可连（client.probing ok)"; else fail "daemon 不可连"; fi

# B1 Refresh (ps)
"$BIN" ps --daemon-sock "$SOCK" > /dev/null 2>&1 && pass "Refresh (ps)" || fail "ps"

# B2 Run New Sandbox
OUT=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>/dev/null)
ID=$(printf '%s' "$OUT" | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
[ -n "$ID" ] && pass "Run New Sandbox ($ID)" || fail "run 未得出 sandboxId"

# B3 Exec row (exec)
E=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo btn-exec 2>/dev/null)
[ "$E" = "btn-exec" ] && pass "Exec row (exec)" || fail "exec=$E"

# B4 Console (consoleLog)
C=$("$BIN" console --daemon-sock "$SOCK" "$ID" 2>/dev/null)
[ -n "$C" ] && pass "Console (consoleLog 有输出)" || fail "consoleLog 为空"

# B5 Send/Ctrl+C simulates terminal (pty*)
PY=$(ID2TEST="$ID" SOCK2USE="$SOCK" python3 "$(dirname "$0")/pty-btn-test.py" 2>/dev/null)
case "$PY" in
  PTYOK*) pass "Terminal Send/Ctrl+C pty 三阶";;
  *) fail "pty=$PY";;
esac

# B6 wsSync ("Sync to /workspace" + drag&drop 同源)
TMPDIR_WS=$(mktemp -d)
echo "btn-ws-marker" > "$TMPDIR_WS/hello.txt"
python3 -c "import json,socket
s=socket.socket(socket.AF_UNIX); s.connect('$SOCK'); s.settimeout(30)
s.sendall((json.dumps({'kind':'wsSync','sandboxId':'$ID','workspaceDir':'$TMPDIR_WS'})+'\n').encode())
print(s.recv(65536).decode())" > /tmp/btn-ws.json 2>/dev/null
grep -q ws-sync /tmp/btn-ws.json && pass "wsSync (Sync to workspace / drag-drop 同源)" || fail "wsSync=$(cat /tmp/btn-ws.json)"

# B7 Restart
R1=$("$BIN" restart --daemon-sock "$SOCK" "$ID" 2>/dev/null)
RID=$(printf '%s' "$R1" | awk '/restarted ->/{print $3}')
[ -n "$RID" ] && pass "Restart ($RID)" || fail "restart=$R1"
[ -n "$RID" ] && "$BIN" exec --daemon-sock "$SOCK" "$RID" -- /bin/echo post-restart > /dev/null 2>&1 && pass "Restart 后 exec 可用"

# B8 Stop + Rm
"$BIN" stop --daemon-sock "$SOCK" "$RID" > /dev/null 2>&1 && pass "Stop" || fail "stop"
"$BIN" rm --daemon-sock "$SOCK" "$RID" --force > /dev/null 2>&1 && pass "Rm --force" || fail "rm --force"

# B9 Manifests 面板（Rescan 等同检查）
MS=$(find "$(dirname "$MANIFEST")" -maxdepth 1 -name 'manifest*.json' ! -name '*unsigned*' | wc -l | tr -d ' ')
[ "$MS" -ge 1 ] && pass "Manifests Rescan 至少 1 个 manifest（$MS)" || fail "manifest 目录空"

# B10 Shutdown Daemon
"$BIN" shutdown --daemon-sock "$SOCK" > /dev/null 2>&1 && pass "Shutdown Daemon" || fail "shutdown"

printf '\n[btn] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
