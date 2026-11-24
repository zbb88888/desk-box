#!/usr/bin/env bash
# M39：exec 的输出（真机，1 台 VM）。
#
# guest 的 exec 输出处理有两个版本，脚本自动识别（stats 里的 execOutputVersion）：
#   版本 2（当前源码）：
#     X1  小输出逐字节一致
#     X2  3KB / 200KB 的 stdout 完整返回（此前：3KB 被静默截到 1023 字节；200KB 卡到超时）
#     X3  超过上限（每路 1MiB）：正好保留 1MiB，明确提示截断，命令不被卡住，退出码不变
#     X4  stdout 与 stderr 同时大量输出：两路都完整
#     X5  非 UTF-8 的二进制输出不会让请求失败
#     X6  超时：约在超时时刻返回（不是超时 + 宽限），保留超时前的输出，exit 254，stderr 说明
#     X7  大输出 + 非零退出码：两者都保留
#     X8  后台子进程拿着管道不放：不拖住 exec
#     X9  之后 guest 仍然响应，没有残留的 exec cgroup
#   版本 1（旧 guest）：断言宿主的**提示**是对的——
#     L1  小输出不提示
#     L2  3KB 输出：仍被截到 1023 字节，但 stderr 提示「输出可能被截断」
#     L3  200KB 输出：命令超时（exit 254）而不是含糊的通道错误，并提示可能的原因
#
# 用法同 e2e-workspace-sync.sh（MANIFEST / RUN_FLAGS）。资源纪律：scripts/lib/e2e-common.sh。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init xo
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"

e2e_start_daemon || die "daemon 未就绪"
# shellcheck disable=SC2086
ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
[ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
XV=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('execOutputVersion') or 1)" 2>/dev/null || echo 1)
log "guest 的 exec 输出处理版本：$XV"
if [ -n "${EXPECT_EXEC_OUTPUT_VERSION:-}" ]; then
  [ "$XV" = "$EXPECT_EXEC_OUTPUT_VERSION" ] && pass "guest exec 输出版本 = $XV（符合预期）" || fail "guest exec 输出版本 = $XV（期望 $EXPECT_EXEC_OUTPUT_VERSION）"
fi

O="$E2E_WORK/out"; E="$E2E_WORK/err"
# x <超时秒> <guest shell 命令>：stdout → $O，stderr → $E；设置 RC 与 MS
x() {
  local t0; t0=$(now_ms)
  "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout "$1" -- /bin/sh -c "$2" >"$O" 2>"$E" && RC=0 || RC=$?
  MS=$(( $(now_ms) - t0 ))
}
bytes() { wc -c < "$1" | tr -d ' '; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
want_seq() { seq 1 "$1" > "$E2E_WORK/want"; }
notice() { grep -c '^dbx-poc: 注意：' "$E" || true; }

# ---------- 两个版本都成立 ----------
x 10 'printf "a b\n\tc\n"; printf "e1\n" >&2'
[ "$RC" = 0 ] && [ "$(cat "$O")" = "$(printf 'a b\n\tc')" ] && [ "$(cat "$E")" = e1 ] && [ "$(notice)" = 0 ] \
  && pass "X1 小输出：stdout / stderr 逐字节一致，没有多余的提示" || fail "X1 rc=$RC out=[$(cat "$O")] err=[$(cat "$E")]"

x 10 'echo out; echo err >&2; exit 5'
[ "$RC" = 5 ] && [ "$(cat "$O")" = out ] && [ "$(cat "$E")" = err ] \
  && pass "X1 guest 命令的退出码原样传给调用方（exit 5 → 5；此前一律是 2，还往 stderr 多打一行）" || fail "X1 退出码：rc=$RC out=[$(cat "$O")] err=[$(cat "$E")]"
"$BIN" exec --daemon-sock "$SOCK" "$ID" --no-such-option -- /bin/echo x >"$O" 2>"$E" && RC=0 || RC=$?
[ "$RC" = 2 ] && grep -q 'unknown option' "$E" && pass "X1 CLI 自身的用法错误仍是 exit 2" || fail "X1 用法错误：rc=$RC $(cat "$E")"

if [ "$XV" -ge 2 ]; then
  want_seq 600
  x 10 'seq 1 600'
  [ "$RC" = 0 ] && cmp -s "$O" "$E2E_WORK/want" && [ ! -s "$E" ] \
    && pass "X2 3KB stdout 完整返回（$(bytes "$O") 字节；此前静默截到 1023）" || fail "X2 3KB：rc=$RC $(bytes "$O") 字节 err=[$(head -c 200 "$E")]"
  want_seq 40000
  x 20 'seq 1 40000'
  [ "$RC" = 0 ] && cmp -s "$O" "$E2E_WORK/want" && [ ! -s "$E" ] && [ "$MS" -lt 10000 ] \
    && pass "X2 $(bytes "$O") 字节的 stdout 完整返回，${MS}ms（此前卡到超时）" || fail "X2 大输出：rc=$RC $(bytes "$O") 字节 ${MS}ms err=[$(head -c 200 "$E")]"

  # 上限：每路 1MiB。1.5MB 的输出 → 正好保留前 1MiB。
  x 30 'i=0; while [ $i -lt 1500 ]; do printf "%01000d" $i; i=$((i+1)); done; echo tail-marker >&2; exit 3'
  [ "$(bytes "$O")" = 1048576 ] && pass "X3 超过上限：正好保留 1048576 字节" || fail "X3 保留了 $(bytes "$O") 字节（期望 1048576）"
  [ "$(head -c 1000 "$O")" = "$(printf '%01000d' 0)" ] && pass "X3 保留的是开头的部分" || fail "X3 保留的内容不是开头"
  grep -q '^dbx-poc: 注意：stdout 被截断：只保留了前 1048576 字节' "$E" && pass "X3 stderr 明确提示截断" || fail "X3 没有截断提示：$(head -c 300 "$E")"
  grep -q '^tail-marker$' "$E" && [ "$RC" = 3 ] && pass "X3 命令没有被卡住：跑到了最后（stderr 的结尾标记在，退出码 3 保留）" || fail "X3 rc=$RC err=[$(head -c 300 "$E")]"
  log "X3 1.5MB 输出用时 ${MS}ms"

  x 20 'seq 1 20000 & seq 30001 50000 >&2; wait'
  seq 1 20000 > "$E2E_WORK/want"; seq 30001 50000 > "$E2E_WORK/want-err"
  [ "$RC" = 0 ] && cmp -s "$O" "$E2E_WORK/want" && cmp -s "$E" "$E2E_WORK/want-err" \
    && pass "X4 stdout（$(bytes "$O") 字节）与 stderr（$(bytes "$E") 字节）同时大量输出：两路都完整" || fail "X4 rc=$RC out=$(bytes "$O") err=$(bytes "$E")"

  x 10 'printf "A\377\376B\000C\n"'
  [ "$RC" = 0 ] && grep -q 'A' "$O" && grep -q 'C' "$O" && [ "$(notice)" = 0 ] \
    && pass "X5 非 UTF-8 / 含 NUL 的输出：请求成功（无效字节按替换字符显示）" || fail "X5 rc=$RC out=[$(od -c "$O" | head -2)] err=[$(cat "$E")]"

  x 3 'echo before-timeout; echo err-before >&2; sleep 30; echo never'
  [ "$RC" = 254 ] && pass "X6 超时：退出码 254（guest 的 -2）" || fail "X6 rc=$RC"
  [ "$MS" -ge 2500 ] && [ "$MS" -lt 6000 ] && pass "X6 在超时时刻返回（${MS}ms；超时 3s）" || fail "X6 用时 ${MS}ms"
  [ "$(cat "$O")" = before-timeout ] && grep -q '^err-before$' "$E" && grep -q 'exec timed out; process group killed' "$E" && ! grep -q never "$O" \
    && pass "X6 超时前的 stdout / stderr 都保留，stderr 说明了超时" || fail "X6 out=[$(cat "$O")] err=[$(cat "$E")]"
  [ "$(notice)" = 0 ] && pass "X6 新 guest 的超时不带「旧 guest」提示" || fail "X6 多余的提示：$(cat "$E")"

  want_seq 20000
  x 20 'seq 1 20000; exit 7'
  [ "$RC" = 7 ] && cmp -s "$O" "$E2E_WORK/want" && pass "X7 大输出 + 退出码 7：两者都保留" || fail "X7 rc=$RC $(bytes "$O") 字节"

  x 20 '(sleep 25 &) ; echo foreground-done'
  [ "$RC" = 0 ] && [ "$(cat "$O")" = foreground-done ] && [ "$MS" -lt 5000 ] \
    && pass "X8 后台子进程拿着管道不放：exec 在 ${MS}ms 返回（没有等它）" || fail "X8 rc=$RC ${MS}ms out=[$(cat "$O")]"
  x 10 'ps 2>/dev/null | grep -c "[s]leep 25" || true'
  [ "$(cat "$O")" = 0 ] && pass "X8 那个后台进程没有活下来" || log "X8 注意：ps 输出=[$(cat "$O")]（exec 各自在独立的 PID 命名空间里，看不到别的 exec 的进程）"
else
  x 10 'seq 1 600'
  [ "$RC" = 0 ] && [ "$(bytes "$O")" = 1023 ] && pass "L2 旧 guest：3KB 输出仍被截到 1023 字节（guest 的行为，宿主改不了）" || fail "L2 rc=$RC $(bytes "$O") 字节"
  grep -q '^dbx-poc: 注意：输出可能被截断' "$E" && pass "L2 但不再是静默的：stderr 提示「输出可能被截断」" || fail "L2 没有提示：$(cat "$E")"
  x 4 'seq 1 40000'
  [ "$RC" = 254 ] && grep -q 'exec timed out; process group killed' "$E" && ! grep -q 'DBX-BOOT-PROOF-MISMATCH' "$E" \
    && pass "L3 旧 guest：200KB 输出 → 报告为命令超时（exit 254），不再是含糊的 DBX-BOOT-PROOF-MISMATCH" || fail "L3 rc=$RC err=[$(head -c 300 "$E")]"
  grep -q '^dbx-poc: 注意：.*64KB' "$E" && pass "L3 并提示可能的原因（旧 guest 上输出超过 64KB 会卡住）" || fail "L3 没有原因提示：$(cat "$E")"
  [ "$MS" -lt 8500 ] && pass "L3 在超时 + 宽限之内返回（${MS}ms；超时 4s）" || fail "L3 用时 ${MS}ms"
fi

# ---------- 收尾（两个版本） ----------
x 10 'echo still-alive'
[ "$RC" = 0 ] && [ "$(cat "$O")" = still-alive ] && pass "X9 之后 guest 仍然响应" || fail "X9 rc=$RC out=[$(cat "$O")] err=[$(cat "$E")]"
GROUPS_LEFT=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('activeExecGroups'))" 2>/dev/null)
[ "$GROUPS_LEFT" = 0 ] && pass "X9 没有残留的 exec cgroup（activeExecGroups=0）" || fail "X9 activeExecGroups=$GROUPS_LEFT"

"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "沙箱已移除" || fail "rm 失败"
e2e_finish
