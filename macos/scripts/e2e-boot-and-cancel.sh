#!/usr/bin/env bash
# M26：引导失败快速诊断（a）+ 拆除类操作打断在途 exec（b）的真机端到端测试。
#
#   A1  内存不足（512MiB）→ 秒级失败，原因码 no-console-output，并点明内存低于估算下限
#   A2  估算只是提示不是闸门：低于估算但实际够用的内存（572MiB）仍能引导
#   A3  损坏的 initrd + 充足内存 → 同样秒级失败，但**不**归咎于内存
#   A4  引导失败后零残留（ps 为空、cow-root 干净）
#   A5  健康引导不受影响（首字节远早于静默阈值）
#   A6  DBX_BOOT_TIMEOUT_SECONDS 生效，超时消息带 console 线索
#   B1  长 exec 期间 rm --force 立即返回；exec 以 DBX-OP-CANCELLED 结束
#   B2  长 exec 期间 stop 立即返回；之后普通 rm 可用（取消标记已解除）
#   B3  非 force 的 rm 被拒绝时**不得**打断在途 exec
#   B4  排队中的 exec 也被一并取消
#   B5  邻居沙箱的 exec 不受影响
#   B6  shutdown 不再等 exec 超时；零残留
#
# 资源纪律：scripts/lib/e2e-common.sh（隔离 support-root，退出自动清理并自检）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init m26
e2e_build_sign
cd "$E2E_ROOT"

# 防空跑：长 exec 的客户端此刻必须仍在运行（否则它早已失败，后面的「打断」断言全是假的）。
assert_running() { kill -0 "$1" 2>/dev/null && pass "对照：$2 的长 exec 确实在途" || fail "对照失败：$2 的长 exec 并未在途（$(cat "$3" 2>/dev/null)）"; }
residue() { find "$COW_ROOT" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | wc -l | tr -d ' '; }
run_sb() { "$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 2>&1 | sid_of; }

e2e_start_daemon || die "daemon 未就绪"

# ================= A：引导失败诊断 =================

# ---------- A1 ----------
t0=$(now_ms)
"$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 512 >"$E2E_WORK/a1.out" 2>&1 && RC=0 || RC=$?
A1_MS=$(( $(now_ms) - t0 ))
[ "$RC" != 0 ] && pass "512MiB run 失败（未静默成功）" || fail "512MiB run 竟然成功"
grep -q 'DBX-BOOT-FAILED(no-console-output)' "$E2E_WORK/a1.out" && pass "原因码 DBX-BOOT-FAILED(no-console-output)" || fail "原因码不符：$(cat "$E2E_WORK/a1.out")"
grep -q '内存 512MiB 低于' "$E2E_WORK/a1.out" && grep -q -- '--memory-mib' "$E2E_WORK/a1.out" \
  && pass "消息点明内存不足并给出处置（$(sed -n 's/.*估算下限约 \([0-9]*MiB\).*/估算下限 \1/p' "$E2E_WORK/a1.out")）" || fail "消息未点明内存：$(cat "$E2E_WORK/a1.out")"
# 默认静默阈值 10s；旧行为是 90s。
[ "$A1_MS" -lt 20000 ] && pass "失败用时 ${A1_MS}ms < 20000ms（旧行为 90000ms）" || fail "失败用时 ${A1_MS}ms"
[ "$A1_MS" -ge 9000 ] && pass "未早于静默阈值判定（${A1_MS}ms ≥ 9000ms）" || fail "判定过早：${A1_MS}ms"

# ---------- A4（紧跟 A1：失败引导的清理） ----------
[ "$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')" = 0 ] && pass "引导失败后 ps 为空" || fail "引导失败的沙箱仍在 ps 中"
[ "$(residue)" = 0 ] && pass "引导失败后 cow-root 零残留" || fail "引导失败后残留 $(residue) 个文件"

# ---------- A2 ----------
EST=$(sed -n 's/.*估算下限约 \([0-9]*\)MiB.*/\1/p' "$E2E_WORK/a1.out")
if [ -n "$EST" ] && [ "$EST" -gt 572 ]; then
  ID572=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 572 --cpus 1 2>"$E2E_WORK/a2.err" | sid_of)
  if [ -n "$ID572" ]; then
    pass "572MiB（低于估算 ${EST}MiB）仍可引导：估算是提示不是闸门"
    "$BIN" rm --daemon-sock "$SOCK" "$ID572" --force >/dev/null 2>&1
  else
    fail "572MiB 引导失败（实测下限 568MiB）：$(cat "$E2E_WORK/a2.err")"
  fi
else
  skip "A2：估算值 ${EST:-?}MiB 不高于 572，无法构造「低于估算但可引导」"
fi

# ---------- A3 ----------
FX="$E2E_WORK/junk-guest"; mkdir -p "$FX"
GUEST_DIR="$(dirname "$MANIFEST")"
cp -c "$GUEST_DIR/vmlinuz-virt" "$GUEST_DIR/root-disk.raw" "$FX/" 2>/dev/null || cp "$GUEST_DIR/vmlinuz-virt" "$GUEST_DIR/root-disk.raw" "$FX/"
printf 'not an initramfs at all' > "$FX/initrd-deskbox.img"
python3 - "$GUEST_DIR/manifest.unsigned.json" "$FX" <<'PY'
import json, sys, hashlib
d = json.load(open(sys.argv[1]))
d["fileDigests"]["initrd-deskbox.img"] = hashlib.sha256(open(sys.argv[2] + "/initrd-deskbox.img", "rb").read()).hexdigest()
json.dump(d, open(sys.argv[2] + "/manifest.json", "w"))
PY
t0=$(now_ms)
"$BIN" run --daemon-sock "$SOCK" "$FX/manifest.json" --allow-unsigned-manifest --memory-mib 2048 >"$E2E_WORK/a3.out" 2>&1 && RC=0 || RC=$?
A3_MS=$(( $(now_ms) - t0 ))
[ "$RC" != 0 ] && grep -q 'DBX-BOOT-FAILED(no-console-output)' "$E2E_WORK/a3.out" && [ "$A3_MS" -lt 20000 ] \
  && pass "损坏 initrd：${A3_MS}ms 内失败（no-console-output）" || fail "损坏 initrd：rc=$RC ${A3_MS}ms $(cat "$E2E_WORK/a3.out")"
grep -q '低于该 guest' "$E2E_WORK/a3.out" && fail "损坏 initrd 被误归咎于内存" || pass "损坏 initrd 未被归咎于内存"
grep -q '无法估算\|损坏或不匹配' "$E2E_WORK/a3.out" && pass "消息指向 kernel/initrd" || fail "消息未指向 kernel/initrd：$(cat "$E2E_WORK/a3.out")"
# 未签名 manifest 不带 --allow-unsigned-manifest 必须在引导之前就被拒（诊断逻辑不得成为绕过签名的旁路）。
t0=$(now_ms)
"$BIN" run --daemon-sock "$SOCK" "$FX/manifest.json" >"$E2E_WORK/a3b.out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && ! grep -q 'DBX-BOOT' "$E2E_WORK/a3b.out" && [ $(( $(now_ms) - t0 )) -lt 3000 ] \
  && pass "未签名 manifest 仍在引导前被拒（非引导诊断路径）" || fail "未签名 manifest 处理异常：$(cat "$E2E_WORK/a3b.out")"
[ "$(residue)" = 0 ] && pass "A 组结束 cow-root 零残留" || fail "A 组残留 $(residue) 个文件"

# ---------- A5 ----------
A=$(run_sb)
[ -n "$A" ] || die "健康引导失败"
FIRST=$(grep -o 'first-console-ms=[0-9]*' "$DAEMON_LOG" | tail -1 | cut -d= -f2)
[ -n "$FIRST" ] && [ "$FIRST" -lt 5000 ] && pass "健康引导首字节 ${FIRST}ms（静默阈值 10000ms）" || fail "首字节=${FIRST:-?}ms"
grep -q "diagnosed=" "$DAEMON_LOG" && N_DIAG=$(grep -c "diagnosed=" "$DAEMON_LOG") || N_DIAG=0
[ "$N_DIAG" = 2 ] && pass "只有 2 次失败引导被诊断（健康引导无误报）" || fail "diagnosed 次数=$N_DIAG（期望 2）"

# ================= B：取消在途操作 =================
B=$(run_sb); C=$(run_sb); D=$(run_sb)
[ -n "$B" ] && [ -n "$C" ] && [ -n "$D" ] || die "B 组沙箱创建失败"

# ---------- B1 + B5 ----------
"$BIN" exec --daemon-sock "$SOCK" "$A" --timeout 60 -- /bin/sh -c 'sleep 40; echo never' >"$E2E_WORK/b1.out" 2>&1 & XA=$!
"$BIN" exec --daemon-sock "$SOCK" "$D" --timeout 60 -- /bin/sh -c 'sleep 4; echo neighbour-ok' >"$E2E_WORK/b5.out" 2>&1 & XD=$!
sleep 1
assert_running $XA A "$E2E_WORK/b1.out"
t0=$(now_ms)
"$BIN" rm --daemon-sock "$SOCK" "$A" --force >"$E2E_WORK/b1.rm" 2>&1 && RC=0 || RC=$?
RM_MS=$(( $(now_ms) - t0 ))
[ "$RC" = 0 ] && [ "$RM_MS" -lt 5000 ] && pass "长 exec 期间 rm --force ${RM_MS}ms 返回（旧行为等满 exec）" || fail "rm --force rc=$RC ${RM_MS}ms $(cat "$E2E_WORK/b1.rm")"
t0=$(now_ms); wait $XA && XRC=0 || XRC=$?
[ "$XRC" != 0 ] && [ $(( $(now_ms) - t0 )) -lt 3000 ] && pass "被打断的 exec 客户端随即返回（非零）" || fail "exec 未及时返回 rc=$XRC"
grep -q 'DBX-OP-CANCELLED: exec aborted (sandbox is being removed)' "$E2E_WORK/b1.out" && pass "exec 原因码 DBX-OP-CANCELLED（being removed）" || fail "exec 输出：$(cat "$E2E_WORK/b1.out")"
grep -q never "$E2E_WORK/b1.out" && fail "被取消的 exec 竟然产出了结果" || pass "被取消的 exec 无结果输出"
"$BIN" ps --daemon-sock "$SOCK" | grep -q "$A" && fail "A 仍在 ps" || pass "A 已从 ps 移除"
wait $XD && DRC=0 || DRC=$?
[ "$DRC" = 0 ] && [ "$(cat "$E2E_WORK/b5.out")" = neighbour-ok ] && pass "邻居沙箱 D 的 exec 不受影响" || fail "邻居 exec rc=$DRC out=$(cat "$E2E_WORK/b5.out")"

# ---------- B2 ----------
"$BIN" exec --daemon-sock "$SOCK" "$B" --timeout 60 -- /bin/sh -c 'sleep 40; echo never' >"$E2E_WORK/b2.out" 2>&1 & XB=$!
sleep 1
assert_running $XB B "$E2E_WORK/b2.out"
t0=$(now_ms)
"$BIN" stop --daemon-sock "$SOCK" "$B" >"$E2E_WORK/b2.stop" 2>&1 && RC=0 || RC=$?
STOP_MS=$(( $(now_ms) - t0 ))
[ "$RC" = 0 ] && [ "$STOP_MS" -lt 8000 ] && pass "长 exec 期间 stop ${STOP_MS}ms 返回" || fail "stop rc=$RC ${STOP_MS}ms $(cat "$E2E_WORK/b2.stop")"
wait $XB && XRC=0 || XRC=$?
[ "$XRC" != 0 ] && grep -q 'DBX-OP-CANCELLED: exec aborted (sandbox is being stopped)' "$E2E_WORK/b2.out" && pass "exec 原因码 DBX-OP-CANCELLED（being stopped）" || fail "exec 输出：$(cat "$E2E_WORK/b2.out")"
"$BIN" ps --daemon-sock "$SOCK" | grep "$B" | grep -q stopped && pass "B 状态 stopped" || fail "B 状态：$("$BIN" ps --daemon-sock "$SOCK" | grep "$B")"
"$BIN" rm --daemon-sock "$SOCK" "$B" >"$E2E_WORK/b2.rm" 2>&1 && pass "stop 之后普通 rm 可用（取消标记已解除）" || fail "stop 后 rm 失败：$(cat "$E2E_WORK/b2.rm")"

# ---------- B3 ----------
"$BIN" exec --daemon-sock "$SOCK" "$C" --timeout 30 -- /bin/sh -c 'sleep 4; echo survived' >"$E2E_WORK/b3.out" 2>&1 & XC=$!
sleep 1
assert_running $XC C "$E2E_WORK/b3.out"
"$BIN" rm --daemon-sock "$SOCK" "$C" >"$E2E_WORK/b3.rm" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q 'use --force' "$E2E_WORK/b3.rm" && pass "非 force rm 对 running 沙箱被拒" || fail "非 force rm rc=$RC $(cat "$E2E_WORK/b3.rm")"
wait $XC && XRC=0 || XRC=$?
[ "$XRC" = 0 ] && [ "$(cat "$E2E_WORK/b3.out")" = survived ] && pass "被拒的 rm 没有打断在途 exec" || fail "exec 被误伤 rc=$XRC out=$(cat "$E2E_WORK/b3.out")"
[ "$("$BIN" exec --daemon-sock "$SOCK" "$C" -- /bin/echo still-usable 2>&1)" = still-usable ] && pass "C 之后仍可 exec" || fail "C 不可用"

# ---------- B4 ----------
"$BIN" exec --daemon-sock "$SOCK" "$C" --timeout 60 -- /bin/sh -c 'sleep 40; echo never1' >"$E2E_WORK/b4-1.out" 2>&1 & Q1=$!
sleep 0.5
"$BIN" exec --daemon-sock "$SOCK" "$C" --timeout 60 -- /bin/echo never2 >"$E2E_WORK/b4-2.out" 2>&1 & Q2=$!
sleep 0.5
assert_running $Q1 "C(在途)" "$E2E_WORK/b4-1.out"
assert_running $Q2 "C(排队)" "$E2E_WORK/b4-2.out"
t0=$(now_ms)
"$BIN" rm --daemon-sock "$SOCK" "$C" --force >/dev/null 2>&1 && RC=0 || RC=$?
wait $Q1 && R1=0 || R1=$?; wait $Q2 && R2=0 || R2=$?
Q_MS=$(( $(now_ms) - t0 ))
[ "$RC" = 0 ] && [ "$R1" != 0 ] && [ "$R2" != 0 ] && [ "$Q_MS" -lt 6000 ] && pass "在途 + 排队的 exec 均被打断，rm 完成（${Q_MS}ms）" || fail "rc=$RC r1=$R1 r2=$R2 ${Q_MS}ms"
grep -q 'DBX-OP-CANCELLED' "$E2E_WORK/b4-1.out" && pass "在途 exec：DBX-OP-CANCELLED" || fail "在途 exec 输出：$(cat "$E2E_WORK/b4-1.out")"
# 排队者可能在 rm 之前被取消标记拒绝，也可能在 rm 之后发现沙箱已不存在——两者都必须是明确拒绝且无输出。
grep -q 'DBX-OP-CANCELLED\|sandbox not found' "$E2E_WORK/b4-2.out" && ! grep -q never2 "$E2E_WORK/b4-2.out" \
  && pass "排队 exec：被明确拒绝且未执行（$(grep -o 'DBX-OP-CANCELLED\|sandbox not found' "$E2E_WORK/b4-2.out" | head -1)）" || fail "排队 exec 输出：$(cat "$E2E_WORK/b4-2.out")"

# ---------- B6 ----------
E=$(run_sb)
[ -n "$E" ] || die "E 创建失败"
"$BIN" exec --daemon-sock "$SOCK" "$D" --timeout 60 -- /bin/sh -c 'sleep 40; echo never' >"$E2E_WORK/b6-d.out" 2>&1 & SD=$!
"$BIN" exec --daemon-sock "$SOCK" "$E" --timeout 60 -- /bin/sh -c 'sleep 40; echo never' >"$E2E_WORK/b6-e.out" 2>&1 & SE=$!
sleep 1
assert_running $SD D "$E2E_WORK/b6-d.out"
assert_running $SE E "$E2E_WORK/b6-e.out"
t0=$(now_ms)
"$BIN" shutdown --daemon-sock "$SOCK" >"$E2E_WORK/b6.out" 2>&1 && RC=0 || RC=$?
SH_MS=$(( $(now_ms) - t0 ))
[ "$RC" = 0 ] && [ "$SH_MS" -lt 8000 ] && pass "2 个长 exec 在途时 shutdown ${SH_MS}ms 返回（旧行为等满 exec）" || fail "shutdown rc=$RC ${SH_MS}ms"
wait $SD && R1=0 || R1=$?; wait $SE && R2=0 || R2=$?
[ "$R1" != 0 ] && [ "$R2" != 0 ] && grep -q 'DBX-OP-CANCELLED: exec aborted (daemon is shutting down)' "$E2E_WORK/b6-d.out" \
  && grep -q 'DBX-OP-CANCELLED: exec aborted (daemon is shutting down)' "$E2E_WORK/b6-e.out" \
  && pass "两个 exec 均以 DBX-OP-CANCELLED（shutting down）结束" || fail "d=$(cat "$E2E_WORK/b6-d.out") e=$(cat "$E2E_WORK/b6-e.out")"
e2e_wait_exit "$DAEMON_PID" 100 && pass "daemon 进程已退出" || fail "daemon 未退出"
[ ! -e "$SOCK" ] && pass "socket 已清除" || fail "socket 残留"
[ "$(residue)" = 0 ] && pass "shutdown 后 cow-root 零残留" || fail "残留 $(residue) 个文件：$(find "$COW_ROOT" -type f | tr '\n' ' ')"
grep -q 'Fatal error\|SIGTRAP\|EXC_BAD' "$DAEMON_LOG" && fail "daemon 日志含崩溃痕迹" || pass "daemon 日志无崩溃痕迹"

# ---------- A6：超时旋钮（独立 daemon） ----------
S2="$E2E_WORK/t.sock"
DBX_BOOT_TIMEOUT_SECONDS=6 e2e_start_daemon "$S2" "$E2E_WORK/daemon-timeout.log" || die "第二个 daemon 未就绪"
t0=$(now_ms)
"$BIN" run --daemon-sock "$S2" "$MANIFEST" --memory-mib 512 >"$E2E_WORK/a6.out" 2>&1 && RC=0 || RC=$?
A6_MS=$(( $(now_ms) - t0 ))
[ "$RC" != 0 ] && grep -q 'DBX-BOOT-TIMEOUT: bootstrap did not reach running within 6s' "$E2E_WORK/a6.out" && [ "$A6_MS" -lt 9000 ] \
  && pass "DBX_BOOT_TIMEOUT_SECONDS=6 生效（${A6_MS}ms，先于静默阈值）" || fail "rc=$RC ${A6_MS}ms $(cat "$E2E_WORK/a6.out")"
grep -q 'console: <no console output>' "$E2E_WORK/a6.out" && pass "超时消息带 console 线索" || fail "超时消息无 console 线索"
"$BIN" shutdown --daemon-sock "$S2" >/dev/null 2>&1
e2e_wait_exit "$DAEMON_PID" 100 && pass "第二个 daemon 已退出" || fail "第二个 daemon 未退出"
[ "$(residue)" = 0 ] && pass "全部结束 cow-root 零残留" || fail "残留 $(residue) 个文件"

e2e_finish
