#!/usr/bin/env bash
# M17 buttons-e2e：GUI 每个按钮的功能路径用同一 daemon socket 协议验证。
#
# M25：默认**隔离运行**——自起一个私有 daemon（临时 support-root），不碰用户的 GUI daemon。
#      旧行为（对着用户真实 daemon 跑，并在最后把它 shutdown）必须显式选择：
#        E2E_GUI_LIVE=1 ./scripts/e2e-gui-buttons.sh
#      该模式要求 GUI 已 launch 且 autostartDaemon=true，且会停掉该 daemon。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init btn
e2e_build_sign
cd "$E2E_ROOT"

if [ "${E2E_GUI_LIVE:-0}" = 1 ]; then
  unset DBX_SUPPORT_ROOT
  SOCK="$HOME/Library/Application Support/DeskBox/dbxd.sock"
  printf '[btn] LIVE 模式 sock=%s\n' "$SOCK"
  # --- 0. GUI/daemon 存活（Start Daemon / autostart path）
  if ps aux | grep -q 'DeskBoxGU[I]'; then pass "GUI 进程在"; else fail "GUI 不在"; fi
else
  e2e_start_daemon || die "daemon 未就绪"
  skip "GUI 进程检查（隔离模式不依赖 GUI；E2E_GUI_LIVE=1 时检查）"
fi
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
case "$PY" in *PTYOK*) pass "Terminal Send/Ctrl+C pty 三阶";; *) fail "pty=$PY";; esac
# M33：pty 生命周期（daemon 协议层）
case "$PY" in *BUSYOK*) pass "已有活会话时第二个 ptyOpen 被拒";; *) fail "pty busy 规则：$PY";; esac
case "$PY" in *CLOSED*) pass "ptyClose 在 guest 内真正关闭会话（daemon 看到 exit 事件）";; *) fail "pty close：$PY";; esac
case "$PY" in *REOPENOK*) pass "关闭后再次打开终端可用（此前 guest 里的 shell 未被杀，再开必超时）";; *) fail "pty reopen：$PY";; esac
case "$PY" in *RACEOK*) pass "关闭与重开并发时新终端的输出不丢";; *) fail "pty close/open 并发：$PY";; esac
case "$PY" in *PREEMPTOK*) pass "被遗弃的会话（客户端未关闭就消失）不再阻止新终端";; *) fail "pty preempt：$PY";; esac

# B6 wsSync ("Sync to /workspace" + drag&drop 同源)
TMPDIR_WS="$E2E_WORK/ws"; mkdir -p "$TMPDIR_WS"
echo "btn-ws-marker" > "$TMPDIR_WS/hello.txt"
python3 -c "import json,socket
s=socket.socket(socket.AF_UNIX); s.connect('$SOCK'); s.settimeout(30)
s.sendall((json.dumps({'kind':'wsSync','sandboxId':'$ID','workspaceDir':'$TMPDIR_WS'})+'\n').encode())
print(s.recv(65536).decode())" > "$E2E_WORK/ws.json" 2>/dev/null
# M37：此时这台沙箱已经运行过 exec / pty。结果取决于 guest 的 workspace 接收端：
#   新接收端 → 允许；旧 guest → 以 DBX-WS-RESYNC-UNSAFE 拒绝（GUI 的 Sync 按钮看到的就是这个）。
if grep -q ws-sync "$E2E_WORK/ws.json"; then
  pass "wsSync（workload 运行之后；guest 是新接收端，允许）"
elif grep -q 'DBX-WS-RESYNC-UNSAFE' "$E2E_WORK/ws.json"; then
  pass "wsSync（workload 运行之后；旧 guest → 被 DBX-WS-RESYNC-UNSAFE 挡住）"
  "$BIN" ws-sync --daemon-sock "$SOCK" "$ID" "$TMPDIR_WS" --allow-unsafe-resync >"$E2E_WORK/ws2.out" 2>&1 \
    && grep -q ws-sync "$E2E_WORK/ws2.out" && pass "wsSync 显式放行后可用（CLI ws-sync --allow-unsafe-resync）" || fail "显式放行失败：$(cat "$E2E_WORK/ws2.out")"
else
  fail "wsSync=$(cat "$E2E_WORK/ws.json")"
fi

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

e2e_finish
