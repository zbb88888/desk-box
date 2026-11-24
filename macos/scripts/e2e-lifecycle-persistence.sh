#!/usr/bin/env bash
# M20：生命周期持久化 e2e（INV-10）：suspend/resume + 加密快照 + 三道闸 + 销毁零残留。
# M25：隔离运行（scripts/lib/e2e-common.sh）——状态全在临时目录，退出自动清理。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init m20
e2e_build_sign
cd "$E2E_ROOT"
e2e_start_daemon || die "daemon 未就绪"

ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>&1 | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
[ -z "$ID" ] && { echo '[m20] FATAL: run failed'; exit 2; }
printf '[m20] sandbox=%s\n' "$ID"
SNAP="$COW_ROOT/snapshots/$ID.snap"
COW_PATH=$(python3 -c "import json,sys;print()" 2>/dev/null || true)

# 前置：写入标记 + 确认 uid
PRE=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'echo M20-MARKER > /workspace/m20.txt; id -u' 2>&1 | tr -d '\r')
case "$PRE" in *65534*) pass "前置 exec 正常（uid=65534）";; *) fail "前置 exec 失败: $PRE";; esac

# 0) M28：suspend 中途失败必须回滚到 running（此前会卡在 suspending，只能 rm）。
#    不依赖 resume，锁屏与否都执行。
SNAPDIR="$COW_ROOT/snapshots"; mkdir -p "$SNAPDIR"
state_of() { "$BIN" ps --daemon-sock "$SOCK" | awk -v id="$1" '$1==id{print $2}'; }
assert_usable_after_abort() { # <场景>
  [ "$(state_of "$ID")" = running ] && pass "$1：状态回到 running" || fail "$1：状态=$(state_of "$ID")（期望 running）"
  OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'cat /workspace/m20.txt' 2>&1 | tr -d '\r')
  [ "$OUT" = M20-MARKER ] && pass "$1：exec 可用且数据仍在（VM 已恢复运行、会话未断）" || fail "$1：exec=$OUT"
}

# 0a) 保存阶段失败：快照目录不可写 → VZ 保存失败（此时 VM 已被 pause）。
chmod 500 "$SNAPDIR"
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/abort-a.out" 2>&1 && RC=0 || RC=$?
chmod 700 "$SNAPDIR"
[ "$RC" != 0 ] && grep -q 'DBX-LIFECYCLE-SUSPEND-ABORTED' "$E2E_WORK/abort-a.out" \
  && pass "保存失败：suspend 以 DBX-LIFECYCLE-SUSPEND-ABORTED 失败" || fail "保存失败场景 rc=$RC：$(head -c 300 "$E2E_WORK/abort-a.out")"
assert_usable_after_abort "保存失败"
[ -z "$(ls -A "$SNAPDIR")" ] && pass "保存失败：快照目录无残留（无半截临时文件 / 快照）" || fail "保存失败后残留：$(ls -A "$SNAPDIR" | tr '\n' ' ')"

# 0b) 加密落盘阶段失败：快照路径被一个目录占住 → 保存成功、seal 失败。
mkdir "$SNAP"
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/abort-b.out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q 'DBX-LIFECYCLE-SUSPEND-ABORTED' "$E2E_WORK/abort-b.out" \
  && pass "落盘失败：suspend 以 DBX-LIFECYCLE-SUSPEND-ABORTED 失败" || fail "落盘失败场景 rc=$RC：$(head -c 300 "$E2E_WORK/abort-b.out")"
assert_usable_after_abort "落盘失败"
[ -d "$SNAP" ] && [ "$(ls -A "$SNAPDIR")" = "$ID.snap" ] && pass "落盘失败：占位目录原样保留，无临时文件残留" || fail "落盘失败后目录内容：$(ls -A "$SNAPDIR" | tr '\n' ' ')"
rmdir "$SNAP"

# 1) suspend（两次中止之后，正常 suspend 仍然可用）
#    M33：suspend 时有一个**开着的终端**（不关闭）。此前 guest 里的 shell 会被一起冻进快照，
#    resume 之后仍占着唯一的 pty 槽位，终端再也打不开。
PTY_SID=$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" open "$ID" 2>&1)
case "$PTY_SID" in FAIL*|"") fail "suspend 前打开终端失败：$PTY_SID";; *) pass "suspend 前打开了一个终端（保持打开）";; esac
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 && pass "suspend 成功（有打开的终端）" || fail "suspend 失败"
STATE=$("$BIN" ps --daemon-sock "$SOCK" | awk '{print $2}' | head -1)
[ "$STATE" = "suspended" ] && pass "ps 显示 suspended" || fail "ps 状态=$STATE"

# 2) 快照存在且是密文、权限 0600
[ -f "$SNAP" ] && pass "快照文件已生成" || fail "快照文件缺失"
if grep -qa 'M20-MARKER' "$SNAP" 2>/dev/null; then
  fail "快照中泄漏明文标记"
else
  pass "快照为密文（无明文标记）"
fi
PERM=$(stat -f '%Lp' "$SNAP" 2>/dev/null)
[ "$PERM" = "600" ] && pass "快照权限 0600" || fail "快照权限=$PERM"

# 3) 篡改 → 拒绝恢复
cp "$SNAP" "$SNAP.bak"
python3 - "$SNAP" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
d[-24] ^= 0xFF
open(p, 'wb').write(d)
PY
if "$BIN" resume --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/tamper.log" 2>&1; then
  fail "篡改后的快照竟然恢复成功"
else
  grep -qi 'decrypt\|完整性\|DECRYPT' "$E2E_WORK/tamper.log" && pass "篡改快照被拒（AEAD 完整性）" || fail "篡改被拒但原因不明: $(head -1 "$E2E_WORK/tamper.log")"
fi
mv "$SNAP.bak" "$SNAP"

# 4) 原始快照恢复（按结果分类，见 e2e_resume）
e2e_resume "$SOCK" "$ID"
if [ "$RESUME_OUTCOME" = locked ]; then
  # 锁屏：VZ 拒绝 restore。能验证的是「失败得明确、不丢状态」（已由 e2e_resume 断言）。
  skip_locked "原始快照可恢复 / 恢复后状态 running"
  skip_locked "恢复后可以打开新终端（suspend 前的终端没有占住 pty）"
  skip_locked "恢复后数据仍在、权限未复活"
  skip_locked "二次 suspend/resume"
else
[ "$RESUME_OUTCOME" = ok ] && pass "原始快照可恢复" || fail "原始快照恢复失败：$(head -c 300 "$E2E_WORK/resume.out")"
STATE=$("$BIN" ps --daemon-sock "$SOCK" | awk '{print $2}' | head -1)
[ "$STATE" = "running" ] && pass "恢复后状态 running" || fail "恢复后状态=$STATE"
# M33：suspend 前开着的终端已在 guest 里被关闭，恢复后可以打开新的终端。
PTY_AFTER=$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" roundtrip "$ID" "after-resume-pty" 2>&1)
[ "$PTY_AFTER" = OK ] && pass "恢复后可以打开新终端（suspend 前的终端没有占住 pty）" || fail "恢复后终端不可用：$PTY_AFTER"

# 5) 恢复后数据仍在、权限未复活
POST=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c 'cat /workspace/m20.txt; id -u' 2>&1 | tr -d '\r')
case "$POST" in
  *M20-MARKER*65534*) pass "恢复后状态保持且 uid 仍 65534（权限未复活）";;
  *) fail "恢复后验证失败: $POST";;
esac

# 6) 二次 suspend/resume（可重复）
"$BIN" suspend --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 && pass "二次 suspend 成功" || fail "二次 suspend 失败"
e2e_resume "$SOCK" "$ID"
case "$RESUME_OUTCOME" in
  ok)     pass "二次 resume 成功" ;;
  locked) skip_locked "二次 resume（会话在套件运行中途锁屏）" ;;
  *)      fail "二次 resume 失败：$(head -c 300 "$E2E_WORK/resume.out")" ;;
esac
fi

# 7) 对 **suspended** 沙箱直接 rm：快照必须随之删除（INV-10）。
#    M27 之前这条路径从未被覆盖（总是先 resume 再 rm），destroy 实际上不删快照。
if [ "$(state_of "$ID")" = running ]; then
  "$BIN" suspend --daemon-sock "$SOCK" "$ID" >/dev/null 2>&1 || fail "rm 前的 suspend 失败"
fi
"$BIN" ps --daemon-sock "$SOCK" | grep "$ID" | grep -q suspended && [ -f "$SNAP" ] \
  && pass "对照：rm 之前沙箱为 suspended 且快照存在" || fail "对照失败：沙箱不是 suspended 或快照不存在"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
[ ! -f "$SNAP" ] && pass "rm suspended 沙箱后快照已删除" || fail "快照残留: $SNAP"
LEFT=$(find "$COW_ROOT" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "rm 后 cow-root 零残留（clone / 域标记 / 快照）" || fail "rm 后残留：$LEFT"
LEFT=$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && pass "rm 后 ps 为空" || fail "ps 仍列出 $LEFT 个"
ID=""

# 8) 未知沙箱 suspend/resume 必须拒绝
if "$BIN" suspend --daemon-sock "$SOCK" 00000000-0000-0000-0000-000000000000 >/dev/null 2>&1; then
  fail "未知沙箱 suspend 应失败"
else
  pass "未知沙箱 suspend 拒绝"
fi

# 9) M25：快照密钥落在隔离目录（0600），未触碰用户真实 snapshot.key
KPERM=$(stat -f '%Lp' "$DBX_SUPPORT_ROOT/snapshot.key" 2>/dev/null)
[ "$KPERM" = "600" ] && pass "snapshot.key 生成于隔离 support-root（0600）" || fail "隔离 snapshot.key 权限=$KPERM"

e2e_finish
