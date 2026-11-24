#!/usr/bin/env bash
# M30：真 GUI 进程的端到端测试（不需要辅助功能权限，不操作用户桌面）。
#
#   G1  隔离启动：GUI 识别 DBX_SUPPORT_ROOT，自动拉起的 daemon 落在隔离目录
#   G2  主菜单里有「Quit Desk Box  ⌘Q」，action = terminate:
#   G3  合成 ⌘Q（应用内自检）→ 经 terminate 路径退出，退出码 0
#   G4  GUI 退出后，它拉起的 daemon 按设计继续运行（可被 CLI 正常 shutdown）
#   G5  daemon 无响应（连得上、不回话）时主线程不被卡住，⌘Q 仍然即时生效
#       —— 这是最初「⌘Q 无法退出」的根因；同时验证 GUI 不删除该 daemon 的 socket
#   G6  非法 DBX_SUPPORT_ROOT：GUI 直接 exit 2，不回落到真实目录
#
# 做法：把 GUI 二进制装进临时目录里的一个 .app（独立 bundle id、LSUIElement=后台代理：
# 无 Dock 图标、不抢焦点），直接执行其二进制（不经 LaunchServices 注册）。
# 应用内自检钩子见 GUISelfTest.swift（仅当设置 DBX_GUI_SELFTEST 时启用）。
#
# 没有覆盖：真实键盘事件的分发、Display 窗口（VZVirtualMachineView）聚焦时的 ⌘Q、
# 任何需要点击的流程。见 docs/design/m30-gui-automation.md。
#
# 资源纪律：scripts/lib/e2e-common.sh；另外清理 macOS 按 bundle id 在 ~/Library 下生成的文件。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init gui
e2e_build_sign
cd "$E2E_ROOT"

BID="com.deskbox.gui.e2e.$$"
APP="$E2E_WORK/DeskBoxE2E.app"
GUI_PIDS=""

# macOS 会按 bundle id 在用户 Library 下落文件（偏好设置等）；它们在临时目录之外，必须单独清。
library_residue() {
  for d in "Preferences/$BID.plist" "Saved Application State/$BID.savedState" "Caches/$BID" \
           "HTTPStorages/$BID" "WebKit/$BID" "Application Scripts/$BID" "Containers/$BID"; do
    [ -e "$HOME/Library/$d" ] && printf '%s\n' "$HOME/Library/$d"
  done
  return 0
}
e2e_extra_cleanup() {
  for p in $GUI_PIDS; do kill -9 "$p" 2>/dev/null; done
  case "$BID" in com.deskbox.gui.e2e.[0-9]*) ;; *) return 0 ;; esac   # 只动本次运行的 bundle id
  defaults delete "$BID" >/dev/null 2>&1
  library_residue | while IFS= read -r path; do rm -rf "$path"; done
  _left=$(library_residue | tr '\n' ' ')
  [ -z "$_left" ] || printf '[gui] LEAK: ~/Library 残留：%s\n' "$_left" >&2
}

# ---------- 组装临时 .app ----------
( swift build -c release --product DeskBoxGUI >"$E2E_WORK/gui-build.log" 2>&1 ) || { tail -5 "$E2E_WORK/gui-build.log"; die "GUI 构建失败"; }
mkdir -p "$APP/Contents/MacOS"
cp "$E2E_ROOT/.build/release/DeskBoxGUI" "$APP/Contents/MacOS/DeskBoxGUI"
cp "$BIN" "$APP/Contents/MacOS/dbx-poc"          # 保留签名：GUI 拉起的 daemon 用它
python3 - "$E2E_ROOT/gui/DeskBoxGUI/Resources/Info.plist" "$APP/Contents/Info.plist" "$BID" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
info["CFBundleIdentifier"] = sys.argv[3]
info["LSUIElement"] = True          # 后台代理：无 Dock 图标、不激活
with open(sys.argv[2], "wb") as f:
    plistlib.dump(info, f)
PY
GUI_BIN="$APP/Contents/MacOS/DeskBoxGUI"
DEFAULT_SOCK="$DBX_SUPPORT_ROOT/dbxd.sock"

# launch_gui <report> <quit-after-seconds> <autostart YES|NO>：后台启动，PID 记入 GUI_PID。
launch_gui() {
  DBX_GUI_SELFTEST="$1" DBX_GUI_SELFTEST_QUIT_AFTER="$2" \
    "$GUI_BIN" -autostartDaemon "$3" -manifestPath "$MANIFEST" >"$1.stdout" 2>&1 &
  GUI_PID=$!
  GUI_PIDS="$GUI_PIDS $GUI_PID"
}
# wait_gui_exit <pid> <秒>：限时等待；超时则杀掉并返回 "alive"。输出 GUI_RC。
wait_gui_exit() {
  if e2e_wait_exit "$1" $(( $2 * 10 )); then
    wait "$1" 2>/dev/null && GUI_RC=0 || GUI_RC=$?
  else
    GUI_RC=alive
    kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null
  fi
}
field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));v=d.get(sys.argv[2]);print('' if v is None else v)" "$1" "$2" 2>/dev/null; }

# ================= G1–G4：隔离启动 + 自动拉起 daemon + ⌘Q =================
R1="$E2E_WORK/report-1.json"
launch_gui "$R1" 6 YES
GUI1=$GUI_PID
# GUI 运行期间：它拉起的 daemon 应出现在隔离目录的默认 socket 上。
DAEMON_UP=0
for _ in $(seq 1 50); do "$BIN" ps >/dev/null 2>&1 && { DAEMON_UP=1; break; }; sleep 0.1; done
SPAWNED=$(pgrep -f "$APP/Contents/MacOS/dbx-poc daemon" | head -1)
[ -n "$SPAWNED" ] && { E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $SPAWNED"; E2E_DAEMON_SOCKS="$E2E_DAEMON_SOCKS $DEFAULT_SOCK"; }
[ "$DAEMON_UP" = 1 ] && [ -S "$DEFAULT_SOCK" ] && pass "G1 GUI 自动拉起的 daemon 监听在隔离目录（$(basename "$E2E_WORK")/support/dbxd.sock）" \
  || fail "G1 隔离目录里没有可用的 daemon（autostart 未生效或落到了别处）"
[ -n "$SPAWNED" ] && [ "$(ps -o ppid= -p "$SPAWNED" | tr -d ' ')" = "$GUI1" ] \
  && pass "G1 该 daemon 是这个 GUI 进程拉起的（pid $SPAWNED，ppid=$GUI1）" || fail "G1 找不到由 GUI 拉起的 daemon（pid=${SPAWNED:-none}）"
[ -f "$DBX_SUPPORT_ROOT/dbxd-gui.log" ] && pass "G1 daemon 日志写在隔离目录" || fail "G1 daemon 日志不在隔离目录"

wait_gui_exit "$GUI1" 15
[ -s "$R1" ] || fail "自检报告未生成（自检钩子未启动？）：$(head -c 300 "$R1.stdout" 2>/dev/null)"
[ "$(field "$R1" supportRoot)" = "$DBX_SUPPORT_ROOT" ] && [ "$(field "$R1" sockPath)" = "$DEFAULT_SOCK" ] \
  && pass "G1 GUI 自报的状态根目录 / socket 路径 = 隔离目录" || fail "G1 GUI 路径：root=$(field "$R1" supportRoot) sock=$(field "$R1" sockPath)"
[ "$(field "$R1" bundleIdentifier)" = "$BID" ] && pass "G1 运行的是临时 bundle（$BID）" || fail "G1 bundle id=$(field "$R1" bundleIdentifier)"

# ---------- G2 ----------
python3 - "$R1" >"$E2E_WORK/menu.out" 2>&1 <<'PY' && pass "G2 主菜单有且仅有一个 ⌘Q 项：$(cat "$E2E_WORK/menu.out")" || fail "G2 菜单检查失败：$(cat "$E2E_WORK/menu.out")"
import json, sys
menu = json.load(open(sys.argv[1]))["menu"]
cmd_q = [m for m in menu if m["keyEquivalent"].lower() == "q" and m["command"] and not (m["shift"] or m["option"] or m["control"])]
assert len(cmd_q) == 1, f"⌘Q 项数量={len(cmd_q)}：{[m['path'] for m in cmd_q]}（菜单共 {len(menu)} 项）"
item = cmd_q[0]
assert "Quit" in item["title"], item
assert item["enabled"], item
print(f"{item['path']} → {item['action'] or '(SwiftUI closure)'}")
PY

# ---------- G3 ----------
[ "$GUI_RC" = 0 ] && pass "G3 合成 ⌘Q 后 GUI 退出，退出码 0" || fail "G3 GUI 未因 ⌘Q 退出（rc=$GUI_RC）"
[ "$(field "$R1" phase)" = before-cmd-q ] && pass "G3 ⌘Q 之后进程没有继续运行（报告停在 before-cmd-q）" \
  || fail "G3 ⌘Q 之后 App 仍在运行：phase=$(field "$R1" phase) handled=$(field "$R1" cmdQHandledByMenu)"
[ -f "$R1.terminated" ] && pass "G3 退出经由 applicationShouldTerminate（不是崩溃或被杀）" || fail "G3 没有经过 terminate 路径"
LAG1=$(field "$R1" maxMainThreadLagMs); LAG1=${LAG1%.*}
[ -n "$LAG1" ] && [ "$LAG1" -lt 1000 ] && pass "G3 正常运行时主线程最大卡顿 ${LAG1}ms（$(field "$R1" lagSamples) 次采样）" || fail "G3 主线程卡顿 ${LAG1:-?}ms"

# ---------- G4 ----------
if [ -n "$SPAWNED" ] && kill -0 "$SPAWNED" 2>/dev/null && "$BIN" ps >/dev/null 2>&1; then
  pass "G4 GUI 退出后 daemon 仍在运行且可达（daemon 不随 GUI 退出，符合设计）"
else
  fail "G4 GUI 退出后 daemon 不可达（pid=${SPAWNED:-none}）"
fi
"$BIN" shutdown >/dev/null 2>&1 && e2e_wait_exit "${SPAWNED:-0}" 100 && [ ! -e "$DEFAULT_SOCK" ] \
  && pass "G4 该 daemon 可被 CLI 正常 shutdown，socket 已清除" || fail "G4 daemon shutdown 失败"

# ================= G5：daemon 无响应时主线程不卡 =================
# 假 daemon：accept 之后一言不发。GUI 每 3s 的探活会在这里等满 2s 超时。
python3 - "$DEFAULT_SOCK" >"$E2E_WORK/fake.log" 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(64)
held = []
while True:
    c, _ = s.accept(); held.append(c)      # 不读不写，保持连接
PY
FAKE=$!
for _ in $(seq 1 50); do [ -S "$DEFAULT_SOCK" ] && break; sleep 0.1; done
[ -S "$DEFAULT_SOCK" ] || die "假 daemon 未就绪：$(cat "$E2E_WORK/fake.log")"
INODE_BEFORE=$(stat -f '%i' "$DEFAULT_SOCK")

R2="$E2E_WORK/report-2.json"
t0=$(now_ms)
launch_gui "$R2" 8 NO          # 8s ≈ 3 轮探活，每轮主线程（旧实现）被卡 2s
GUI2=$GUI_PID
wait_gui_exit "$GUI2" 20
G5_MS=$(( $(now_ms) - t0 ))
[ -s "$R2" ] || fail "G5 自检报告未生成：$(head -c 300 "$R2.stdout" 2>/dev/null)"
LAG2=$(field "$R2" maxMainThreadLagMs); LAG2=${LAG2%.*}
# 旧实现：探活在主线程同步执行，2s 读超时 → 卡顿 ≈ 2000ms。
[ -n "$LAG2" ] && [ "$LAG2" -lt 500 ] && pass "G5 daemon 无响应时主线程最大卡顿 ${LAG2}ms < 500ms（旧实现 ≈ 2000ms；$(field "$R2" lagSamples) 次采样）" \
  || fail "G5 主线程被卡住 ${LAG2:-?}ms（探活又回到主线程了？）"
[ "$GUI_RC" = 0 ] && [ -f "$R2.terminated" ] && [ "$(field "$R2" phase)" = before-cmd-q ] \
  && pass "G5 daemon 无响应时 ⌘Q 仍经 terminate 路径退出（rc=0）" || fail "G5 ⌘Q 未能退出（rc=$GUI_RC phase=$(field "$R2" phase)）"
# 计划 8s 后发 ⌘Q；若主线程被卡，定时器本身也会被拖后。
[ "$G5_MS" -lt 11000 ] && pass "G5 从启动到退出 ${G5_MS}ms（计划 8000ms 发 ⌘Q，无明显拖延）" || fail "G5 退出被拖延到 ${G5_MS}ms"
kill -0 "$FAKE" 2>/dev/null && [ -S "$DEFAULT_SOCK" ] && [ "$(stat -f '%i' "$DEFAULT_SOCK")" = "$INODE_BEFORE" ] \
  && pass "G5 GUI 没有删除/替换无响应 daemon 的 socket" || fail "G5 socket 被 GUI 动过"
grep -q "dbx-poc" "$R2.stdout" 2>/dev/null; pgrep -f "$APP/Contents/MacOS/dbx-poc daemon" >/dev/null \
  && fail "G5 autostart=NO 时 GUI 仍然拉起了 daemon" || pass "G5 autostart=NO 时 GUI 没有拉起 daemon"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; rm -f "$DEFAULT_SOCK"

# ================= G6：非法 DBX_SUPPORT_ROOT =================
t0=$(now_ms)
DBX_SUPPORT_ROOT="relative/path" DBX_GUI_SELFTEST="$E2E_WORK/report-3.json" DBX_GUI_SELFTEST_QUIT_AFTER=5 \
  "$GUI_BIN" -autostartDaemon NO >"$E2E_WORK/g6.out" 2>&1 &
GUI3=$!; GUI_PIDS="$GUI_PIDS $GUI3"
wait_gui_exit "$GUI3" 8
[ "$GUI_RC" = 2 ] && grep -q 'DBX_SUPPORT_ROOT' "$E2E_WORK/g6.out" && [ $(( $(now_ms) - t0 )) -lt 4000 ] \
  && pass "G6 非法 DBX_SUPPORT_ROOT → GUI exit 2（未回落到真实目录）" || fail "G6 rc=$GUI_RC：$(head -c 200 "$E2E_WORK/g6.out")"

# ================= 收尾自检 =================
LEFT=$(pgrep -f "$APP/Contents/MacOS/" | tr '\n' ' ')
[ -z "$LEFT" ] && pass "没有残留的 GUI / daemon 进程" || fail "残留进程：$LEFT"
# 偏好设置等由 e2e_extra_cleanup 清理；这里先确认残留只在预期位置（清理后由 harness 报 LEAK）。
defaults delete "$BID" >/dev/null 2>&1
library_residue | while IFS= read -r path; do rm -rf "$path"; done
[ -z "$(library_residue)" ] && pass "~/Library 下无该 bundle id 的残留" || fail "~/Library 残留：$(library_residue | tr '\n' ' ')"

e2e_finish
