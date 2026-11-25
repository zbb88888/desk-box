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
#   G7  Display（M31）：Open Display 不崩溃；guest 画面获得键盘焦点、Display sheet 打开时 ⌘Q 仍能退出；
#       退出后会话私盘（rootfs 临时副本）被清除
#   G8  任意 sheet 打开时（Settings，不依赖 VM）⌘Q 仍能退出 —— AppKit 在有 sheet 时会让 terminate 变成空操作
#   G9  sheet 打开时收到 quit AppleEvent（Dock 的 Quit / 注销走的路）同样能退出
#   G10 操作全链路（M32/M33）：GUI 拉起 daemon → Run → Exec（带引号）→ Terminal(PTY，含关掉再开) →
#       Console → Stats → Workspace 同步 → Suspend → Resume → Rm，
#       全部经由视图模型 / 面板模型里界面所用的同一入口，对着真实 daemon 与真实 VM
#   G11 应用级模态面板（文件选择）打开时收到 quit AppleEvent 仍能退出
#
# 做法：把 GUI 二进制装进临时目录里的一个 .app（独立 bundle id、LSUIElement=后台代理：
# 无 Dock 图标、不抢焦点），直接执行其二进制（不经 LaunchServices 注册）。
# 应用内自检钩子见 GUISelfTest.swift（仅当设置 DBX_GUI_SELFTEST 时启用）。
#
# 没有覆盖：来自窗口服务器的真实键盘事件、任何需要点击的流程。
# 见 docs/design/m30-gui-automation.md 与 m31-display-cmdq.md。
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
# Display 会话私盘落在 $TMPDIR（不在 E2E_WORK 里）：记录基线，退出时删掉本次运行新增的。
display_disks() { ls -1 "${TMPDIR:-/tmp}" 2>/dev/null | grep '^deskbox-display-root-.*\.raw$' | sort; }
DISKS_BEFORE="$(display_disks)"
# GUI 崩溃会在 ~/Library/Logs/DiagnosticReports 留下 .ips；任何新增的崩溃报告都算失败。
crash_reports() { ls -1 "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep '^DeskBoxGUI' | sort; }
CRASHES_BEFORE="$(crash_reports)"
new_crash_reports() { crash_reports | grep -vxF -e "$CRASHES_BEFORE" -e ''; }
new_display_disks() { display_disks | grep -vxF -e "$DISKS_BEFORE" -e '' ; }
e2e_extra_cleanup() {
  for p in $GUI_PIDS; do kill -9 "$p" 2>/dev/null; done
  new_display_disks | while IFS= read -r f; do
    printf '[gui] LEAK: display 会话私盘残留（已删除）：%s\n' "$f" >&2
    rm -f "${TMPDIR:-/tmp}/$f"
  done
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
# G7 要在 GUI 进程内起 display VM：需要 virtualization entitlement（与正式打包一致）。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$E2E_ROOT/Resources/DeskBox.entitlements" \
  --timestamp "$GUI_BIN" >/dev/null 2>&1 || die "GUI codesign 失败"
DEFAULT_SOCK="$DBX_SUPPORT_ROOT/dbxd.sock"

# launch_gui <report> <quit-after-seconds> <autostart YES|NO> [scenario] [quit-via]：后台启动，PID 记入 GUI_PID。
launch_gui() {
  DBX_GUI_SELFTEST="$1" DBX_GUI_SELFTEST_QUIT_AFTER="$2" DBX_GUI_SELFTEST_SCENARIO="${4:-}" DBX_GUI_SELFTEST_QUIT_VIA="${5:-cmd-q}" \
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
# assert_quit <标签> <report>：退出请求之后 App 必须已经退出——
# 退出码 0、经由 applicationShouldTerminate（标记文件内容 terminate；forced 表示走了 AppQuit 的兜底）、
# 且自检没有写下「之后仍在运行」的报告。依赖调用方刚执行过 wait_gui_exit（读 GUI_RC）。
assert_quit() {
  _how=$(cat "$2.terminated" 2>/dev/null)
  _phase=$(field "$2" phase)
  if [ "$GUI_RC" = 0 ] && [ "$_how" = terminate ] && [ "$_phase" != after-cmd-q ] && [ "$_phase" != after-quit-event ]; then
    pass "$1：App 经 terminate 路径退出（rc=0）"
  else
    fail "$1：未能正常退出 rc=$GUI_RC 退出方式=${_how:-none} phase=$_phase sheet=$(field "$2" sheetAttachedBeforeQuit) consumedByWindow=$(field "$2" cmdQConsumedByWindow) handledByMenu=$(field "$2" cmdQHandledByMenu) quitItemEnabled=$(field "$2" quitItemEnabledAfterValidation)"
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
# M35：日志里有 guest console 输出。
[ "$(stat -f '%Lp' "$DBX_SUPPORT_ROOT/dbxd-gui.log" 2>/dev/null)" = 600 ] && pass "G1 daemon 日志权限 0600" \
  || fail "G1 daemon 日志权限=$(stat -f '%Lp' "$DBX_SUPPORT_ROOT/dbxd-gui.log" 2>/dev/null)"

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
assert_quit "G3 合成 ⌘Q（无 sheet）" "$R1"
[ "$(field "$R1" sheetAttachedBeforeQuit)" = False ] && pass "G3 对照：此场景没有 sheet" || fail "G3 意外存在 sheet"
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
assert_quit "G5 daemon 无响应时的 ⌘Q" "$R2"
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

# ================= G7：Display 聚焦时的 ⌘Q + 会话私盘清理 =================
GUEST_DIR="$(dirname "$MANIFEST")"
if [ -f "$GUEST_DIR/vmlinuz-virt-gpu" ] && [ -f "$GUEST_DIR/root-disk.raw" ]; then
  R4="$E2E_WORK/report-4.json"
  launch_gui "$R4" 12 NO display
  GUI4=$GUI_PID
  # 对照：display 确实启动了——会话私盘在运行期间出现。
  DISK_SEEN=0
  for _ in $(seq 1 80); do [ -n "$(new_display_disks)" ] && { DISK_SEEN=1; break; }; kill -0 "$GUI4" 2>/dev/null || break; sleep 0.1; done
  [ "$DISK_SEEN" = 1 ] && pass "G7 对照：Display 启动后会话私盘出现在 \$TMPDIR（$(new_display_disks | head -1)）" || fail "G7 Display 没有启动（没有出现会话私盘）"
  wait_gui_exit "$GUI4" 25
  [ -s "$R4" ] || fail "G7 自检报告未生成：$(head -c 300 "$R4.stdout" 2>/dev/null)"
  [ "$(field "$R4" displayViewFound)" = True ] && [ "$(field "$R4" displayVMRunning)" = True ] \
    && pass "G7 guest 画面已挂载且 display VM 处于 running" || fail "G7 display 未就绪：found=$(field "$R4" displayViewFound) vmState=$(field "$R4" displayVMState)"
  [ "$(field "$R4" firstResponderIsDisplayView)" = True ] && pass "G7 键盘焦点（first responder）确实在 guest 画面上" \
    || fail "G7 焦点不在 guest 画面上（accepted=$(field "$R4" makeFirstResponderAccepted)）——后面的 ⌘Q 断言不成立"
  [ "$(field "$R4" capturesSystemKeys)" = False ] && pass "G7 capturesSystemKeys = false" || fail "G7 capturesSystemKeys=$(field "$R4" capturesSystemKeys)"
  [ "$(field "$R4" sheetAttachedBeforeQuit)" = True ] && pass "G7 对照：发 ⌘Q 时 Display sheet 处于打开状态" || fail "G7 Display sheet 未打开"
  assert_quit "G7 Display sheet 打开且 guest 画面聚焦时的 ⌘Q" "$R4"
  [ -z "$(new_display_disks)" ] && pass "G7 退出后会话私盘已清除" || fail "G7 会话私盘残留：$(new_display_disks | tr '\n' ' ')"
  [ -f "$DBX_SUPPORT_ROOT/display-console.log" ] && pass "G7 display console 日志写在隔离目录" || fail "G7 display console 日志不在隔离目录"
else
  skip "G7 Display：缺少 vmlinuz-virt-gpu / root-disk.raw（先 build guest）"
fi

# ================= G8：任意 sheet 打开时的 ⌘Q（不依赖 VM） =================
R5="$E2E_WORK/report-5.json"
launch_gui "$R5" 5 NO sheet
wait_gui_exit "$GUI_PID" 15
[ -s "$R5" ] || fail "G8 自检报告未生成：$(head -c 300 "$R5.stdout" 2>/dev/null)"
[ "$(field "$R5" sheetAttachedBeforeQuit)" = True ] && pass "G8 对照：发 ⌘Q 时 Settings sheet 处于打开状态" || fail "G8 sheet 未打开（场景无效）"
assert_quit "G8 sheet 打开时的 ⌘Q" "$R5"

# ================= G9：sheet 打开时的 quit AppleEvent =================
R6="$E2E_WORK/report-6.json"
launch_gui "$R6" 5 NO sheet appleevent
wait_gui_exit "$GUI_PID" 15
[ -s "$R6" ] || fail "G9 自检报告未生成：$(head -c 300 "$R6.stdout" 2>/dev/null)"
[ "$(field "$R6" sheetAttachedBeforeQuit)" = True ] && [ "$(field "$R6" quitVia)" = appleevent ] \
  && pass "G9 对照：sheet 打开，退出请求经 quit AppleEvent 发出" || fail "G9 场景无效：sheet=$(field "$R6" sheetAttachedBeforeQuit) via=$(field "$R6" quitVia)"
assert_quit "G9 sheet 打开时的 quit AppleEvent（Dock Quit / 注销）" "$R6"

# ================= G10：操作全链路（真实 daemon + 真实 VM） =================
R7="$E2E_WORK/report-7.json"
# Workspace 同步用的宿主目录（带一个标记文件）。
mkdir -p "$E2E_WORK/ws" && echo "gui-flow-marker" > "$E2E_WORK/ws/marker.txt"
export DBX_GUI_SELFTEST_WORKSPACE="$E2E_WORK/ws"
launch_gui "$R7" 150 YES flow        # 150s 只是保险丝；flow 走完会自己发 ⌘Q
GUI7=$GUI_PID
for _ in $(seq 1 80); do "$BIN" ps >/dev/null 2>&1 && break; sleep 0.1; done
SPAWNED7=$(pgrep -f "$APP/Contents/MacOS/dbx-poc daemon" | head -1)
[ -n "$SPAWNED7" ] && { E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $SPAWNED7"; E2E_DAEMON_SOCKS="$E2E_DAEMON_SOCKS $DEFAULT_SOCK"; }
wait_gui_exit "$GUI7" 170
[ -s "$R7" ] || fail "G10 自检报告未生成：$(head -c 300 "$R7.stdout" 2>/dev/null)"
python3 - "$R7" >"$E2E_WORK/flow.out" 2>&1 <<'PY'
import json, sys
flow = json.load(open(sys.argv[1])).get("flow", [])
for s in flow:
    print(("PASS" if s["ok"] else "FAIL") + "\t" + s["name"] + "\t" + s.get("detail", "").replace("\n", " ⏎ ")[:200])
PY
step_ok() { grep -q "^PASS	$1	" "$E2E_WORK/flow.out"; }
step_detail() { grep "	$1	" "$E2E_WORK/flow.out" | head -1 | cut -f3; }
FAILED_STEP=$(grep '^FAIL' "$E2E_WORK/flow.out" | head -1)
[ -z "$FAILED_STEP" ] || fail "G10 流程在这一步失败：$FAILED_STEP"
step_ok daemon-connected && pass "G10 GUI 自动拉起的 daemon 已连接" || fail "G10 daemon 未连接"
step_ok run && step_ok listed-running && pass "G10 Run New Sandbox：真实 VM 引导完成并出现在列表（$(step_detail run)）" || fail "G10 run 未完成"
step_ok exec-quoted && pass "G10 Exec：带引号的命令行在 guest 内正确执行（/bin/sh -c 'echo flow-ok; id -u' → uid 65534）" || fail "G10 exec 失败：$(step_detail exec-quoted)"
step_ok exec-bad-quoting-rejected && pass "G10 Exec：引号未闭合的命令行在本地被拒" || fail "G10 非法命令行未被拒"
case "$(step_detail exec-cancel)" in
  cancelled)    step_ok exec-cancel && pass "G10 Cancel：在途的命令被取消，输出里保留了取消之前的内容" || fail "G10 Cancel 失败" ;;
  unsupported*) step_ok exec-cancel && pass "G10 Cancel：旧 guest 不支持取消 → 界面显示可读原因，命令照常跑完" || fail "G10 Cancel（旧 guest）异常" ;;
  *)            fail "G10 Cancel 步骤缺失或失败：$(step_detail exec-cancel)" ;;
esac
step_ok exec-cancel-idle && pass "G10 命令结束后 Cancel 恢复为不可用" || fail "G10 Cancel 状态未复位：$(step_detail exec-cancel-idle)"
step_ok rejection-keeps-daemon-connected && pass "G10 被 daemon 拒绝的请求显示可读原因，daemon 状态保持 connected" || fail "G10 拒绝处理异常：$(step_detail rejection-keeps-daemon-connected)"
step_ok pty-roundtrip-1 && pass "G10 Terminal：PTY 打开 → 输入 → 看到输出（$(step_detail pty-roundtrip-1)），输出里没有转义/控制字符" || fail "G10 PTY 失败：$(grep 'pty-' "$E2E_WORK/flow.out" | tail -1)"
step_ok pty-roundtrip-2 && pass "G10 Terminal：关闭后再次打开仍可用（$(step_detail pty-roundtrip-2)）" || fail "G10 PTY 关闭后无法再次打开：$(grep 'pty-' "$E2E_WORK/flow.out" | tail -1)"
step_ok pty-carriage-return && pass "G10 终端：\\r 行内重绘按语义显示（step-A\\rstep-B\\rstep-C → 只剩 step-C）" || fail "G10 终端 \\r 重绘：$(step_detail pty-carriage-return)"
step_ok console && pass "G10 Console：guest serial 内容可读（$(step_detail console)）" || fail "G10 console：$(step_detail console)"
step_ok stats && pass "G10 Stats：两次采样后有内存与 CPU%（$(step_detail stats)）" || fail "G10 stats：$(step_detail stats)"
step_ok stats-error-visible && pass "G10 Stats：沙箱不存在时错误可见、旧数字被清掉（$(step_detail stats-error-visible)）" || fail "G10 stats 错误不可见：$(step_detail stats-error-visible)"
step_ok workspace-sync && step_ok workspace-sync-content \
  && pass "G10 Workspace 同步（在运行任何程序之前）：宿主文件出现在 guest 的 /workspace（$(step_detail workspace-sync)）" \
  || fail "G10 workspace 同步：$(step_detail workspace-sync) $(step_detail workspace-sync-content)"
case "$(step_detail workspace-resync)" in
  allowed) step_ok workspace-resync && pass "G10 运行过程序之后再次同步：guest 是新接收端，允许" || fail "G10 再次同步失败" ;;
  gated*)  step_ok workspace-resync && pass "G10 运行过程序之后再次同步：旧 guest 被挡住，界面显示可读原因（$(step_detail workspace-resync | cut -c8-60)…）" || fail "G10 再次同步闸门异常" ;;
  *)       fail "G10 再次同步步骤缺失或失败：$(step_detail workspace-resync)" ;;
esac
step_ok workspace-sync-precheck && pass "G10 Workspace 同步：把文件当目录会在本地被拒" || fail "G10 workspace 前置检查：$(step_detail workspace-sync-precheck)"
step_ok suspend && [ "$(step_detail suspend)" = "console,resume,rm" ] \
  && pass "G10 Suspend：状态变为 suspended，行内操作变为 console,resume,rm" || fail "G10 suspend：$(step_detail suspend)"
if step_ok resume && step_ok exec-after-resume; then
  pass "G10 Resume：恢复为 running，之后 exec 正常"
elif step_ok resume-host-locked-presented; then
  pass "G10 宿主锁屏：Resume 的失败以可读原因呈现（$(step_detail resume-host-locked-presented)），沙箱保持 suspended"
  skip_locked "G10 Resume 成功 + 之后 exec 正常"
else
  fail "G10 resume 步骤缺失"
fi
step_ok rm && step_ok flow-complete && pass "G10 Rm：沙箱从列表消失，流程完整走完" || fail "G10 流程未走完（最后一步：$(tail -1 "$E2E_WORK/flow.out" | cut -f2)）"
assert_quit "G10 流程结束后的 ⌘Q" "$R7"
[ "$("$BIN" ps 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && pass "G10 daemon 上没有遗留沙箱" || fail "G10 遗留沙箱：$("$BIN" ps 2>&1 | head -2)"
"$BIN" shutdown >/dev/null 2>&1 && e2e_wait_exit "${SPAWNED7:-0}" 100 && pass "G10 daemon 正常 shutdown" || fail "G10 daemon shutdown 失败"
LEFT=$(find "$DBX_SUPPORT_ROOT/cows" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "G10 cow-root 零残留" || fail "G10 cow-root 残留：$LEFT"

# ================= G12：失去控制面的沙箱在界面上的表现（M46；需要带故障注入的 guest 夹具） =================
# 夹具要签名（GUI 走的是不带 --allow-unsigned-manifest 的正常路径）：用本机的开发密钥。
FAULT_MANIFEST=""
if [ -f "$E2E_ROOT/guest/dev-sign-key.local" ]; then
  FAULT_MANIFEST=$(
    export E2E_PATCHED_GUEST_DIR="${E2E_PATCHED_GUEST_DIR:-$E2E_WORK/patched-guest}"
    . "$E2E_ROOT/scripts/lib/patched-guest.sh"
    patched_guest_prepare gui faults >"$E2E_WORK/fault-fixture.log" 2>&1
    printf '%s' "${PATCHED_MANIFEST:-}"
  )
fi
if [ -n "$FAULT_MANIFEST" ] && [ -f "$FAULT_MANIFEST" ] && "$BIN" validate-assets "$FAULT_MANIFEST" >/dev/null 2>&1; then
  R9="$E2E_WORK/report-9.json"
  SAVED_MANIFEST="$MANIFEST"; MANIFEST="$FAULT_MANIFEST"
  launch_gui "$R9" 120 YES failed
  MANIFEST="$SAVED_MANIFEST"
  GUI9=$GUI_PID
  for _ in $(seq 1 80); do "$BIN" ps >/dev/null 2>&1 && break; sleep 0.1; done
  SPAWNED9=$(pgrep -f "$APP/Contents/MacOS/dbx-poc daemon" | head -1)
  [ -n "$SPAWNED9" ] && { E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $SPAWNED9"; E2E_DAEMON_SOCKS="$E2E_DAEMON_SOCKS $DEFAULT_SOCK"; }
  wait_gui_exit "$GUI9" 140
  [ -s "$R9" ] || fail "G12 自检报告未生成：$(head -c 300 "$R9.stdout" 2>/dev/null)"
  python3 - "$R9" >"$E2E_WORK/flow.out" 2>&1 <<'PY'
import json, sys
for s in json.load(open(sys.argv[1])).get("flow", []):
    print("%s\t%s\t%s" % ("PASS" if s["ok"] else "FAIL", s["name"], s.get("detail", "")))
PY
  step_ok row-becomes-failed && pass "G12 guest 的控制进程退出后，列表里那一行靠定时刷新变成 failed 并带原因（$(step_detail row-becomes-failed | cut -c1-48)…）" \
    || fail "G12 行状态：$(grep 'row-becomes-failed\|fault-armed\|run' "$E2E_WORK/flow.out" | tail -1)"
  step_ok failed-row-actions && pass "G12 failed 的行只提供 $(step_detail failed-row-actions)，并有说明文字" || fail "G12 行内操作：$(step_detail failed-row-actions)"
  step_ok exec-on-failed-explains && pass "G12 对 failed 的沙箱 Exec：界面显示「沙箱失去响应」，daemon 状态不变" || fail "G12 Exec 说明：$(step_detail exec-on-failed-explains)"
  step_ok restart && step_ok exec-after-restart && pass "G12 Restart：重建出一台新沙箱（$(step_detail restart | cut -c1-8)…），Exec 正常" \
    || fail "G12 Restart：$(step_detail restart) $(step_detail exec-after-restart)"
  step_ok rm && step_ok flow-complete && pass "G12 流程完整走完" || fail "G12 流程未走完（最后一步：$(tail -1 "$E2E_WORK/flow.out" | cut -f2)）"
  assert_quit "G12 流程结束后的 ⌘Q" "$R9"
  [ "$("$BIN" ps 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && pass "G12 daemon 上没有遗留沙箱" || fail "G12 遗留沙箱：$("$BIN" ps 2>&1 | head -2)"
  "$BIN" shutdown >/dev/null 2>&1 && e2e_wait_exit "${SPAWNED9:-0}" 100 && pass "G12 daemon 正常 shutdown" || fail "G12 daemon shutdown 失败"
  LEFT=$(find "$DBX_SUPPORT_ROOT/cows" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | tr '\n' ' ')
  [ -z "$LEFT" ] && pass "G12 cow-root 零残留" || fail "G12 cow-root 残留：$LEFT"
else
  skip "G12 failed 沙箱的界面流程：需要带故障注入的 guest 夹具（交叉编译器 + 本机开发签名密钥）：$(tail -1 "$E2E_WORK/fault-fixture.log" 2>/dev/null | cut -c1-120)"
fi

# ================= G11：应用级模态面板打开时的 quit AppleEvent =================
R8="$E2E_WORK/report-8.json"
launch_gui "$R8" 5 NO modal appleevent
wait_gui_exit "$GUI_PID" 15
[ -s "$R8" ] || fail "G11 自检报告未生成：$(head -c 300 "$R8.stdout" 2>/dev/null)"
[ "$(field "$R8" appModalBeforeQuit)" = True ] && pass "G11 对照：退出请求发出时文件选择面板（应用级模态）处于打开状态" || fail "G11 模态面板未打开（场景无效）"
HOW=$(cat "$R8.terminated" 2>/dev/null)
[ "$GUI_RC" = 0 ] && { [ "$HOW" = terminate ] || [ "$HOW" = forced ]; } \
  && pass "G11 模态面板打开时收到 quit AppleEvent 仍能退出（rc=0，退出方式=$HOW）" \
  || fail "G11 未能退出：rc=$GUI_RC 退出方式=${HOW:-none} phase=$(field "$R8" phase)"

# ================= 收尾自检 =================
sleep 1   # 崩溃报告由 ReportCrash 异步落盘
NEW_CRASH="$(new_crash_reports | tr '\n' ' ')"
[ -z "$NEW_CRASH" ] && pass "整个套件期间 GUI 没有产生崩溃报告" \
  || fail "GUI 崩溃过，报告保留供排查：~/Library/Logs/DiagnosticReports/{$NEW_CRASH}"
LEFT=$(pgrep -f "$APP/Contents/MacOS/" | tr '\n' ' ')
[ -z "$LEFT" ] && pass "没有残留的 GUI / daemon 进程" || fail "残留进程：$LEFT"
# 偏好设置等由 e2e_extra_cleanup 清理；这里先确认残留只在预期位置（清理后由 harness 报 LEAK）。
defaults delete "$BID" >/dev/null 2>&1
library_residue | while IFS= read -r path; do rm -rf "$path"; done
[ -z "$(library_residue)" ] && pass "~/Library 下无该 bundle id 的残留" || fail "~/Library 残留：$(library_residue | tr '\n' ' ')"

e2e_finish
