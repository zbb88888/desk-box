# shellcheck shell=sh
# M25：e2e 公共 harness（被各 e2e-*.sh `.` 引入；兼容 /bin/sh 与 bash）。
#
# 契约：
#   - 全部宿主侧状态落在一个 `mktemp -d` 目录（$E2E_WORK）：
#       $DBX_SUPPORT_ROOT = $E2E_WORK/support   （domains.json / snapshot.key / cows / 调度证据）
#       $COW_ROOT         = $DBX_SUPPORT_ROOT/cows
#       $SOCK             = $E2E_WORK/d.sock
#       日志、临时文件     = $E2E_WORK/*
#     不读写 ~/Library/Application Support/DeskBox，可与用户正在运行的 daemon 并存。
#   - EXIT/INT/TERM 统一走 e2e_cleanup：shutdown 已登记的 daemon → 等退出 → 兜底 kill -9
#     → 回收后台 job → 失败时打印 daemon 日志尾部 → 删除 $E2E_WORK → 自检零残留。
#   - 只杀自己登记的 PID；绝不 pkill。
#   - 脚本若有目录外的状态要还原（如仓库内被临时改写的文件），定义函数
#     `e2e_extra_cleanup`，harness 会在停 daemon 之后、删目录之前调用它。
#
# 调试：E2E_KEEP=1 保留 $E2E_WORK（会打印路径）。

E2E_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
E2E_TAG="e2e"
E2E_WORK=""
E2E_DAEMON_PIDS=""
E2E_DAEMON_SOCKS=""
PASS=0
FAIL=0
SKIP=0
DAEMON_PID=""

pass() { PASS=$((PASS+1)); printf '[%s] PASS: %s\n' "$E2E_TAG" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[%s] FAIL: %s\n' "$E2E_TAG" "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '[%s] SKIP: %s\n' "$E2E_TAG" "$1"; }
log()  { printf '[%s] %s\n' "$E2E_TAG" "$1"; }
die()  { printf '[%s] FATAL: %s\n' "$E2E_TAG" "$1" >&2; exit 2; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
# 从 `run ok sandboxId=… state=…` 文本里取 id（参数：文件；无参数读 stdin）。
sid_of() { sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p' ${1:+"$1"} | head -1; }

# e2e_screen_locked：宿主登录会话是否锁屏（返回 0 = 锁屏）。
# 锁屏期间 Virtualization.framework 拒绝 restoreMachineStateFrom（"permission denied"），
# 所有依赖 resume 的断言都无法成立——那是宿主状态，不是代码缺陷。
# 套件不要用它来预测 resume 的结果（见 e2e_resume）；它只用于提示信息。
e2e_screen_locked() {
  python3 - <<'PY'
import plistlib, subprocess, sys
try:
    d = plistlib.loads(subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True).stdout)
    locked = any(u.get("CGSSessionScreenIsLocked") for u in d.get("IOConsoleUsers", []) if u.get("kCGSSessionOnConsoleKey"))
except Exception:
    locked = False
sys.exit(0 if locked else 1)
PY
}
# M44：跳过分三类，e2e-all.sh 按标记分类——
#   skip_locked  宿主锁屏（[HOST-LOCKED：…]）                → 结果「不完整」
#   skip_na      这个模式下本来就不该做的检查（[NOT-APPLICABLE：…]） → 不影响结论
#   skip         其它一切（缺工具、没网络、缺资产……）          → 结果「不完整」
# 默认是「算不完整」：新写的 skip 不加标记就不会被悄悄当成通过。
skip_na() { skip "$1 [NOT-APPLICABLE：$2]"; }
# 固定措辞，e2e-all.sh 据此统计「因锁屏未验证」的条目。
skip_locked() { skip "$1 [HOST-LOCKED：宿主锁屏，VZ 无法恢复 VM 状态；解锁后重跑]"; }

# e2e_resume <sock> <id> [额外参数...]：尝试 resume，并**按结果**（而不是按事先探测的锁屏状态）分类。
# 结果写入 RESUME_OUTCOME：
#   ok      resume 成功
#   locked  daemon 报 DBX-RESUME-HOST-LOCKED（宿主锁屏，VZ 拒绝恢复）。此时顺带断言锁屏下应有的
#           行为：沙箱仍为 suspended、快照保留。调用方随后用 skip_locked 标出未验证的断言。
#   failed  其它任何失败——这是真正的失败，调用方应 fail。
# 为什么不先探测锁屏：锁屏标志与 VZ 实际能否恢复之间有时间差（刚锁屏的几秒内仍可恢复），
# 「预测」会在边界上误报。daemon 的诊断同时看了 VZ 的错误和会话状态，以它为准。
e2e_resume() {
  _sock="$1"; _id="$2"; shift 2
  if "$BIN" resume --daemon-sock "$_sock" "$@" "$_id" >"$E2E_WORK/resume.out" 2>&1; then
    RESUME_OUTCOME=ok
  elif grep -q 'DBX-RESUME-HOST-LOCKED' "$E2E_WORK/resume.out"; then
    RESUME_OUTCOME=locked
    pass "宿主锁屏：resume 以 DBX-RESUME-HOST-LOCKED 失败（原因明确）"
    "$BIN" ps --daemon-sock "$_sock" | grep "$_id" | grep -q suspended \
      && pass "resume 失败后沙箱仍为 suspended" || fail "resume 失败后状态异常：$("$BIN" ps --daemon-sock "$_sock" | grep "$_id")"
    [ -f "$COW_ROOT/snapshots/$_id.snap" ] && pass "resume 失败后快照保留" || fail "resume 失败后快照丢失"
  else
    RESUME_OUTCOME=failed
  fi
}

# e2e_init <tag>：建隔离目录、导出环境、装 trap。
e2e_init() {
  E2E_TAG="$1"
  # sun_path 上限 104 字节：固定用 /tmp 短路径（$TMPDIR 在 macOS 上太长）。
  E2E_WORK="$(mktemp -d "/tmp/dbx-$E2E_TAG.XXXXXX")" || die "mktemp 失败"
  DBX_SUPPORT_ROOT="$E2E_WORK/support"
  COW_ROOT="$DBX_SUPPORT_ROOT/cows"
  SOCK="$E2E_WORK/d.sock"
  DAEMON_LOG="$E2E_WORK/daemon.log"
  mkdir -p "$DBX_SUPPORT_ROOT"
  chmod 700 "$E2E_WORK" "$DBX_SUPPORT_ROOT"
  export DBX_SUPPORT_ROOT
  BIN="${BIN:-$E2E_ROOT/.build/release/dbx-poc}"
  MANIFEST="${MANIFEST:-$E2E_ROOT/guest/manifest.json}"
  trap e2e_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# e2e_build_sign：构建并签名 release dbx-poc。E2E_SKIP_BUILD=1 时跳过（e2e-all.sh 统一构建一次）。
# e2e_sign_if_needed：二进制没有 virtualization entitlement（刚被重新链接过）且本机有签名身份时补签。
# 不需要 VM 的套件（没有 guest 资产也要能跑）在自己 swift build 之后调用——
# 否则它们会把签名弄丢，随后带 E2E_SKIP_BUILD=1 运行的 VM 套件全部因缺 entitlement 失败。
e2e_sign_if_needed() {
  [ -x "$BIN" ] || return 0
  codesign -d --entitlements - "$BIN" 2>/dev/null | grep -q 'com.apple.security.virtualization' && return 0
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CODESIGN_IDENTITY" || return 0
  codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$E2E_ROOT/Resources/DeskBox.entitlements" \
    --timestamp "$BIN" >/dev/null 2>&1 || true
}

e2e_build_sign() {
  [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST (run ./scripts/build-alpine-guest.sh ./guest first)"
  if [ "${E2E_SKIP_BUILD:-0}" != 1 ]; then
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
    ( cd "$E2E_ROOT" && swift build -c release --product dbx-poc >/dev/null 2>&1 ) || die "swift build failed"
    codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$E2E_ROOT/Resources/DeskBox.entitlements" \
      --timestamp "$E2E_ROOT/.build/release/dbx-poc" >/dev/null 2>&1 || die "codesign failed"
  fi
  [ -x "$BIN" ] || die "dbx-poc 不存在：$BIN"
}

# e2e_start_daemon [sock] [log]：后台起 daemon 并等就绪；PID 记入 $DAEMON_PID 并登记清理。
e2e_start_daemon() {
  _sock="${1:-$SOCK}"
  _log="${2:-$DAEMON_LOG}"
  rm -f "$_sock"
  "$BIN" daemon --daemon-sock "$_sock" >"$_log" 2>&1 &
  DAEMON_PID=$!
  E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $DAEMON_PID"
  E2E_DAEMON_SOCKS="$E2E_DAEMON_SOCKS $_sock"
  _i=0
  while [ $_i -lt 100 ]; do
    "$BIN" ps --daemon-sock "$_sock" >/dev/null 2>&1 && return 0
    kill -0 "$DAEMON_PID" 2>/dev/null || return 1
    sleep 0.1; _i=$((_i+1))
  done
  return 1
}

# e2e_wait_exit <pid> [deciseconds=100]：等进程退出；超时返回 1。
e2e_wait_exit() {
  _i=0
  while kill -0 "$1" 2>/dev/null && [ $_i -lt "${2:-100}" ]; do sleep 0.1; _i=$((_i+1)); done
  ! kill -0 "$1" 2>/dev/null
}

# e2e_kill9 <pid>：模拟崩溃（故障注入用）。
e2e_kill9() {
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

e2e_cleanup() {
  _status=$?
  trap - EXIT INT TERM
  set +e
  for _s in $E2E_DAEMON_SOCKS; do
    [ -S "$_s" ] && "$BIN" shutdown --daemon-sock "$_s" >/dev/null 2>&1
  done
  for _p in $E2E_DAEMON_PIDS; do
    e2e_wait_exit "$_p" 100 || kill -9 "$_p" 2>/dev/null
  done
  for _p in $(jobs -p 2>/dev/null); do kill "$_p" 2>/dev/null; done
  wait 2>/dev/null
  if command -v e2e_extra_cleanup >/dev/null 2>&1; then e2e_extra_cleanup; fi
  if { [ "$_status" -ne 0 ] || [ "$FAIL" -ne 0 ]; } && [ -d "$E2E_WORK" ]; then
    for _l in "$E2E_WORK"/*.log; do
      [ -f "$_l" ] || continue
      printf '[%s] ---- %s (tail) ----\n' "$E2E_TAG" "$(basename "$_l")" >&2
      tail -15 "$_l" >&2
    done
  fi
  if [ "${E2E_KEEP:-0}" = 1 ]; then
    printf '[%s] E2E_KEEP=1：保留 %s\n' "$E2E_TAG" "$E2E_WORK" >&2
  elif [ -n "$E2E_WORK" ]; then
    # 故障注入用例会临时收紧目录权限；即便它们没来得及还原，清理也必须成功。
    chmod -R u+rwX "$E2E_WORK" 2>/dev/null
    rm -rf "$E2E_WORK"
    # 自检：目录没了、没有任何进程还引用它。残留即失败（即便用例全过）。
    if [ -e "$E2E_WORK" ]; then
      printf '[%s] LEAK: 临时目录未清理：%s\n' "$E2E_TAG" "$E2E_WORK" >&2
      [ "$_status" -eq 0 ] && _status=97
    fi
    _left=$(pgrep -f "$E2E_WORK" 2>/dev/null | tr '\n' ' ')
    if [ -n "$_left" ]; then
      printf '[%s] LEAK: 仍有进程引用 %s：%s\n' "$E2E_TAG" "$E2E_WORK" "$_left" >&2
      kill -9 $_left 2>/dev/null
      [ "$_status" -eq 0 ] && _status=97
    fi
  fi
  exit "$_status"
}

# e2e_finish：打印汇总并以失败数退出。
e2e_finish() {
  printf '\n[%s] 结果：PASS=%d FAIL=%d SKIP=%d\n' "$E2E_TAG" "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}
