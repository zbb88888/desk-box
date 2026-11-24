#!/usr/bin/env bash
# M35：宿主侧状态文件的权限——不依赖父目录，也不依赖 umask（真机，1 台 VM）。
#
# 最坏情况下运行：daemon 的 umask 是 000；cow-root 一次放在 daemon 新建的目录里，
# 一次直接放在一个已存在的 0755 目录里（模拟用户把 --cow-root 指到一个共享位置）。
#
#   P1  daemon 新建的 cow-root 是 0700；用户给的已存在目录**不被 chmod**
#   P2  沙箱盘（clone）0600——不继承基础镜像的 0644；域标记、registry 同样 0600
#   P3  socket 0600；单实例锁文件、调度证据、快照密钥 0600
#   P4  suspend 之后：快照目录 0700、快照文件 0600
#   P5  兜底：daemon 产生的所有文件里，没有任何一个带组/其他用户的权限位
#
# 资源纪律：scripts/lib/e2e-common.sh（隔离 support-root，退出自动清理并自检）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init perm
e2e_build_sign
cd "$E2E_ROOT"

mode() { stat -f '%Lp' "$1" 2>/dev/null; }
is_mode() { # <描述> <路径> <期望>
  [ "$(mode "$2")" = "$3" ] && pass "$1（$3）" || fail "$1：权限=$(mode "$2")（期望 $3）— $2"
}

LOOSE="$E2E_WORK/shared"; mkdir -p "$LOOSE"; chmod 755 "$LOOSE"
NEW_COWS="$E2E_WORK/shared/made-by-daemon/cows"

# 最坏情况：daemon 以 umask 000 运行。
umask 000
e2e_start_daemon || die "daemon 未就绪"
umask 022

BASE_MODE=$(mode "$(dirname "$MANIFEST")/root-disk.raw")
log "基础镜像 root-disk.raw 的权限：$BASE_MODE"

# ---------- P1 / P2：daemon 新建的 cow-root ----------
A=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 --cow-root "$NEW_COWS" 2>&1 | sid_of)
[ -n "$A" ] || die "run A 失败"
is_mode "P1 daemon 新建的 cow-root" "$NEW_COWS" 700
is_mode "P1 daemon 新建的中间目录" "$E2E_WORK/shared/made-by-daemon" 700
is_mode "P2 沙箱盘 clone（基础镜像是 $BASE_MODE）" "$NEW_COWS/sandbox-$A.vhd" 600
is_mode "P2 域标记" "$NEW_COWS/sandbox-$A.vhd.domain" 600
is_mode "P2 registry.json" "$NEW_COWS/registry.json" 600
is_mode "P2 registry.lock" "$NEW_COWS/registry.lock" 600

# ---------- P1 / P2：用户给的、已存在的 0755 目录 ----------
B=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 --cow-root "$LOOSE" 2>&1 | sid_of)
[ -n "$B" ] || die "run B 失败"
is_mode "P1 用户提供的已存在目录没有被 chmod" "$LOOSE" 755
is_mode "P2 放在 0755 目录里的沙箱盘自己是" "$LOOSE/sandbox-$B.vhd" 600
is_mode "P2 放在 0755 目录里的域标记" "$LOOSE/sandbox-$B.vhd.domain" 600
is_mode "P2 放在 0755 目录里的 registry.json" "$LOOSE/registry.json" 600

# 让沙箱盘里真的有 guest 写入的数据（这正是要保护的东西）。
OUT=$("$BIN" exec --daemon-sock "$SOCK" "$B" -- /bin/sh -c 'echo PERM-SECRET > /workspace/secret.txt; sync; echo ok' 2>&1)
[ "$OUT" = ok ] && pass "guest 写入了数据" || fail "guest 写入失败：$OUT"

# ---------- P3 ----------
is_mode "P3 daemon socket" "$SOCK" 600
is_mode "P3 单实例锁文件" "$SOCK.lock" 600
is_mode "P3 调度证据（cow-root 的上一级）" "$E2E_WORK/shared/made-by-daemon/scheduler-decisions.jsonl" 600

# ---------- P4：suspend ----------
"$BIN" suspend --daemon-sock "$SOCK" "$B" >"$E2E_WORK/susp.out" 2>&1 && pass "suspend B" || fail "suspend 失败：$(cat "$E2E_WORK/susp.out")"
is_mode "P4 快照目录（suspend 期间落过明文 VM 状态）" "$LOOSE/snapshots" 700
is_mode "P4 快照文件" "$LOOSE/snapshots/$B.snap" 600
is_mode "P4 快照加密密钥" "$DBX_SUPPORT_ROOT/snapshot.key" 600
grep -qa 'PERM-SECRET' "$LOOSE/snapshots/$B.snap" && fail "快照里出现明文" || pass "P4 快照是密文"
TMP_LEFT=$(ls -A "$LOOSE/snapshots" | grep -v "^$B.snap\$" | tr '\n' ' ')
[ -z "$TMP_LEFT" ] && pass "P4 快照目录里没有遗留的明文临时文件" || fail "P4 遗留：$TMP_LEFT"

COW_ROOT="$LOOSE"            # e2e_resume 在锁屏分支里检查快照是否保留：这台沙箱的 cow-root 是自定义的
e2e_resume "$SOCK" "$B"
case "$RESUME_OUTCOME" in
  ok)
    OUT=$("$BIN" exec --daemon-sock "$SOCK" "$B" -- /bin/sh -c 'cat /workspace/secret.txt' 2>&1)
    [ "$OUT" = PERM-SECRET ] && pass "P4 resume 后数据仍在（恢复路径的临时文件走了新的写入方式）" || fail "resume 后数据=$OUT"
    TMP_LEFT=$(ls -A "$LOOSE/snapshots" 2>/dev/null | tr '\n' ' ')
    [ -z "$TMP_LEFT" ] && pass "P4 resume 后快照目录为空（无遗留的解密临时文件）" || fail "P4 resume 后遗留：$TMP_LEFT" ;;
  locked) skip_locked "P4 resume 后数据仍在 / 无遗留的解密临时文件" ;;
  *) fail "resume 失败：$(head -c 300 "$E2E_WORK/resume.out")" ;;
esac

# ---------- P5：兜底扫描 ----------
# daemon 产生的全部文件（两个 cow-root + support-root + socket 旁的锁）里，不应有任何组/其他用户权限位。
LOOSE_FILES=$(find "$LOOSE" "$DBX_SUPPORT_ROOT" "$SOCK.lock" -type f -perm +077 2>/dev/null | tr '\n' ' ')
[ -z "$LOOSE_FILES" ] && pass "P5 daemon 产生的文件没有任何组/其他用户权限位" || fail "P5 权限过宽的文件：$LOOSE_FILES"
LOOSE_DIRS=$(find "$LOOSE" -mindepth 1 -type d -perm +077 2>/dev/null | tr '\n' ' ')
[ -z "$LOOSE_DIRS" ] && pass "P5 daemon 新建的目录没有任何组/其他用户权限位" || fail "P5 权限过宽的目录：$LOOSE_DIRS"

"$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1 && e2e_wait_exit "$DAEMON_PID" 100 && pass "daemon 正常停机" || fail "停机失败"
LEFT=$(find "$LOOSE" -type f ! -name 'registry.json' ! -name 'registry.lock' ! -name 'scheduler-decisions.jsonl' 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "停机后两个 cow-root 零残留" || fail "残留：$LEFT"

e2e_finish
