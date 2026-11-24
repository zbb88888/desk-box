#!/usr/bin/env bash
# M18：guest 内核级加固 e2e（Landlock 路径面 + seccomp-bpf syscall 面）。
# 判据见 docs/design/m18-guest-kernel-hardening.md §4。
# M25：隔离运行（scripts/lib/e2e-common.sh）——状态全在临时目录，退出自动清理。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init kern
e2e_build_sign
cd "$E2E_ROOT"
e2e_start_daemon || die "daemon 未就绪"
OWN_DAEMON=1

OUT=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>&1)
ID=$(printf '%s' "$OUT" | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
if [ -z "$ID" ]; then
  printf '[kern] FATAL: run failed: %s\n' "$OUT"
  [ "$OWN_DAEMON" = "1" ] && "$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1
  exit 2
fi
printf '[kern] sandbox=%s\n' "$ID"

probe() { "$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/hardening-probe "$1" 2>&1 | tr -d '\r'; }

# 期望正例：rc=0
expect_ok() {
  local name="$1" out
  out=$(probe "$name")
  case "$out" in
    *"case=$name rc=0"*) pass "正例 $name 允许 ($out)";;
    *) fail "正例 $name 被拒 ($out)";;
  esac
}

# 期望被拒：rc=-1 且 errno 为指定值
expect_denied() {
  local name="$1" want_errno="$2" out
  out=$(probe "$name")
  case "$out" in
    *"case=$name rc=-1 errno=$want_errno"*) pass "负例 $name 被拒 errno=$want_errno";;
    *) fail "负例 $name 期望 errno=$want_errno，实际 ($out)";;
  esac
}

EACCES=13
EPERM=1

# --- 正例：合法路径与系统调用必须照常工作（防过严 → 破坏 workload）
expect_ok writespace
expect_ok writetmp
expect_ok readbin

# --- Landlock：127.0.0.1 乱码? no：/opt/landlock-canary 是 0777，无 Landlock 时可写
expect_denied outwrite "$EACCES"
expect_denied outwrite_etc "$EACCES"

# --- seccomp：危险 syscall 必须 EPERM
expect_denied mount "$EPERM"
expect_denied ptrace "$EPERM"
expect_denied unshare "$EPERM"
expect_denied keyctl "$EPERM"
expect_denied bpf "$EPERM"

# --- 现有 workload 零回归：busybox shell / id / workspace 读写
SH=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'echo kern-ok; id -u' 2>&1 | tr -d '\r')
case "$SH" in
  *kern-ok*65534*) pass "既有 exec workload 未受影响";;
  *) fail "exec workload 回归: $SH";;
esac

WS=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'echo wsdata > /workspace/kern-ws && cat /workspace/kern-ws' 2>&1 | tr -d '\r')
case "$WS" in
  *wsdata*) pass "/workspace 读写正常";;
  *) fail "/workspace 读写失败: $WS";;
esac

"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
if [ "$OWN_DAEMON" = "1" ]; then
  "$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1
fi

printf '\n[kern] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
