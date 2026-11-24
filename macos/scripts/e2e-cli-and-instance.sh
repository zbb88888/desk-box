#!/usr/bin/env bash
# M27：宿主侧健壮性——CLI 参数 fail-closed、daemon 单实例守卫、跨进程 sweep 安全。
#
#   C1  --daemon-sock 缺值/空值不得回落默认 socket（不误伤「默认路径上的 daemon」）
#   C2  未知选项 / 非法整数 / 非法 --env 被拒，且不产生副作用
#   C3  选项位置无关（exec --timeout N <id> …）
#   C4  `--` 之后原样透传到 guest（同名选项不被宿主吃掉）
#   C5  --env 真正到达 guest
#   C6  rm 声明了错误的 --domain 被拒（此前 rm 不比对域）
#   G1  第二个 daemon 拒绝接管正在运行的 daemon 的 socket；原 daemon 及其 VM 不受影响
#   G2  崩溃残留的 stale socket 可被接管
#   S1  跨进程 sweep：属主存活的在途临时文件保留；属主已死/过期的删除
#   S2  CLI sweep 持续并发时 suspend/resume 循环仍然成功
#
# 资源纪律：scripts/lib/e2e-common.sh（隔离 support-root，退出自动清理并自检）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init m27
e2e_build_sign
cd "$E2E_ROOT"

alive() { kill -0 "$1" 2>/dev/null; }
# second_daemon <log> [daemon 参数...]：尝试再起一个 daemon，**限时 3s**。
# 守卫正常时它会立刻以非零退出；守卫失效时它会接管 socket 并一直服务下去——
# 这里必须把那种情况变成一次失败，而不是让整个套件挂死。
# 输出：SECOND_RC（退出码；仍在运行记为 "alive"）。
second_daemon() {
  local log="$1"; shift
  "$BIN" daemon "$@" >"$log" 2>&1 &
  local pid=$!
  if e2e_wait_exit "$pid" 30; then
    wait "$pid" && SECOND_RC=0 || SECOND_RC=$?
  else
    SECOND_RC=alive
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  fi
}
# expect_reject <描述> <期望子串> -- <命令...>：命令必须以非零退出且 stderr 含子串。
expect_reject() {
  local what="$1" needle="$2"; shift 3
  if "$@" >"$E2E_WORK/rej.out" 2>&1; then
    fail "$what：竟然成功（$(head -1 "$E2E_WORK/rej.out")）"
  elif grep -qF -- "$needle" "$E2E_WORK/rej.out"; then
    pass "$what"
  else
    fail "$what：被拒但原因不符（$(head -1 "$E2E_WORK/rej.out")）"
  fi
}

# 「受害者」：监听在**默认路径**（$DBX_SUPPORT_ROOT/dbxd.sock）上的 daemon。
# fail-open 的 --daemon-sock 解析会让下面的命令打到它身上。
DEFAULT_SOCK="$DBX_SUPPORT_ROOT/dbxd.sock"
"$BIN" daemon >"$E2E_WORK/victim.log" 2>&1 &
VICTIM_PID=$!
E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $VICTIM_PID"; E2E_DAEMON_SOCKS="$E2E_DAEMON_SOCKS $DEFAULT_SOCK"
for _ in $(seq 1 50); do "$BIN" ps >/dev/null 2>&1 && break; sleep 0.1; done
"$BIN" ps >/dev/null 2>&1 && pass "对照：默认路径上的 daemon 在运行（不带 --daemon-sock 可达）" || die "victim daemon 未就绪"

e2e_start_daemon || die "daemon 未就绪"
MAIN_PID=$DAEMON_PID

# ================= C：CLI =================
# ---------- C1 ----------
expect_reject "shutdown --daemon-sock（缺值）被拒" "missing value for --daemon-sock" -- "$BIN" shutdown --daemon-sock
expect_reject "shutdown --daemon-sock ''（空值）被拒" "empty value for --daemon-sock" -- "$BIN" shutdown --daemon-sock ""
UNSET_SOCK=""
expect_reject "shutdown --daemon-sock \$UNSET（未加引号的空变量）被拒" "missing value for --daemon-sock" -- "$BIN" shutdown --daemon-sock $UNSET_SOCK
expect_reject "ps --daemon-sock= 被拒" "empty value for --daemon-sock" -- "$BIN" ps --daemon-sock=
alive "$VICTIM_PID" && "$BIN" ps >/dev/null 2>&1 && pass "默认路径上的 daemon 未被误伤（仍存活且可达）" || fail "默认路径上的 daemon 被误关"
alive "$MAIN_PID" && pass "主 daemon 未受影响" || fail "主 daemon 被关"
second_daemon "$E2E_WORK/c1-a.log" --daemon-sock
[ "$SECOND_RC" = 2 ] && grep -q 'missing value for --daemon-sock' "$E2E_WORK/c1-a.log" \
  && pass "daemon --daemon-sock（缺值）拒绝启动" || fail "daemon 缺值未被拒（rc=$SECOND_RC）：$(head -1 "$E2E_WORK/c1-a.log")"
second_daemon "$E2E_WORK/c1-b.log" --daemon-sok "$E2E_WORK/x.sock"
[ "$SECOND_RC" = 2 ] && grep -q 'unknown option' "$E2E_WORK/c1-b.log" \
  && pass "daemon 未知选项拒绝启动" || fail "daemon 未知选项未被拒（rc=$SECOND_RC）：$(head -1 "$E2E_WORK/c1-b.log")"
[ ! -e "$E2E_WORK/x.sock" ] && pass "被拒的 daemon 启动没有创建 socket" || fail "被拒的启动留下了 socket"

# ---------- C2（无副作用） ----------
expect_reject "run --memory-mib 4G 被拒" "invalid value for --memory-mib" -- "$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 4G
expect_reject "run 未知选项被拒" "unknown option '--memroy-mib'" -- "$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memroy-mib 1024
expect_reject "run 多余位置参数被拒" "unexpected argument" -- "$BIN" run --daemon-sock "$SOCK" "$MANIFEST" extra.json
[ "$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')" = 0 ] && pass "被拒的 run 没有创建沙箱" || fail "被拒的 run 创建了沙箱"
grep -q 'daemon create' "$DAEMON_LOG" && fail "被拒的 run 到达了 daemon" || pass "被拒的 run 未到达 daemon（客户端侧拒绝）"

ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 2>&1 | sid_of)
[ -n "$ID" ] || die "run 失败"
expect_reject "rm --froce（拼错）被拒" "unknown option '--froce'" -- "$BIN" rm --daemon-sock "$SOCK" "$ID" --froce
expect_reject "exec --env 无 '=' 被拒" "invalid --env 'NOEQ'" -- "$BIN" exec --daemon-sock "$SOCK" "$ID" --env NOEQ -- /bin/echo x
expect_reject "exec --timeout 0 被拒" "invalid value for --timeout" -- "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout 0 -- /bin/echo x
expect_reject "exec 缺 '--' 被拒" "unexpected argument" -- "$BIN" exec --daemon-sock "$SOCK" "$ID" /bin/echo x
expect_reject "stop --force（stop 无此选项）被拒" "unknown option '--force'" -- "$BIN" stop --daemon-sock "$SOCK" "$ID" --force
"$BIN" ps --daemon-sock "$SOCK" | grep "$ID" | grep -q running && pass "一连串被拒的命令之后沙箱仍 running" || fail "沙箱状态被改变"

# ---------- C3 ----------
OUT=$("$BIN" exec --timeout 20 --daemon-sock "$SOCK" "$ID" -- /bin/echo pos-ok 2>&1)
[ "$OUT" = pos-ok ] && pass "选项在 id 之前：exec --timeout 20 <id> 正常" || fail "exec 选项前置失败：$OUT"
OUT=$("$BIN" exec "$ID" --daemon-sock="$SOCK" --timeout=20 -- /bin/echo eq-ok 2>&1)
[ "$OUT" = eq-ok ] && pass "--opt=value 形式正常" || fail "--opt=value 失败：$OUT"

# ---------- C4 ----------
OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo --timeout 5 --env A=B --domain other --daemon-sock /evil -- --force 2>&1)
[ "$OUT" = "--timeout 5 --env A=B --domain other --daemon-sock /evil -- --force" ] \
  && pass "'--' 之后原样透传到 guest（同名选项未被宿主吃掉）" || fail "透传被改写：$OUT"

# ---------- C5 ----------
OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" --env E2E_A=alpha --env E2E_B=b=eta -- /bin/sh -c 'echo "$E2E_A|$E2E_B"' 2>&1)
[ "$OUT" = "alpha|b=eta" ] && pass "--env 到达 guest（含值里的 '='）" || fail "--env 未生效：$OUT"
# guest 侧策略：保留前缀 DBX_ 与 PATH/HOME/USER 不允许被覆盖（CLI 原样转发，由 guest 拒绝）。
expect_reject "guest 拒绝 DBX_ 前缀的 env 键" "env key rejected" -- "$BIN" exec --daemon-sock "$SOCK" "$ID" --env DBX_X=1 -- /bin/echo x
expect_reject "guest 拒绝覆盖 PATH" "env key rejected" -- "$BIN" exec --daemon-sock "$SOCK" "$ID" --env PATH=/evil -- /bin/echo x

# ---------- C6 ----------
expect_reject "rm --domain <错误域> --force 被拒" "DBX-DOMAIN-SESSION-MISMATCH" -- "$BIN" rm --daemon-sock "$SOCK" "$ID" --domain not-my-domain --force
expect_reject "stop --domain <错误域> 被拒" "DBX-DOMAIN-SESSION-MISMATCH" -- "$BIN" stop --daemon-sock "$SOCK" "$ID" --domain not-my-domain
expect_reject "stats --domain <错误域> 被拒" "DBX-DOMAIN-SESSION-MISMATCH" -- "$BIN" stats --daemon-sock "$SOCK" "$ID" --domain not-my-domain
"$BIN" ps --daemon-sock "$SOCK" | grep "$ID" | grep -q running && pass "跨域 rm/stop 被拒后沙箱仍 running" || fail "沙箱被跨域操作影响"
DOM=$("$BIN" ps --daemon-sock "$SOCK" | grep "$ID" | awk -F'\t' '{print $5}')
"$BIN" stats --daemon-sock "$SOCK" "$ID" --domain "$DOM" --json >/dev/null 2>&1 && pass "同域（$DOM）stats 正常" || fail "同域 stats 失败"

# ================= G：单实例守卫 =================
# ---------- G1 ----------
INODE_BEFORE=$(stat -f '%i' "$SOCK")
t0=$(now_ms)
second_daemon "$E2E_WORK/second.log" --daemon-sock "$SOCK"
G_MS=$(( $(now_ms) - t0 ))
[ "$SECOND_RC" != 0 ] && [ "$SECOND_RC" != alive ] && pass "第二个 daemon 立即退出（rc=$SECOND_RC，${G_MS}ms）" \
  || fail "第二个 daemon 没有拒绝启动（rc=$SECOND_RC）——它接管了正在运行的 daemon 的 socket"
grep -q 'DBX-DAEMON-ALREADY-RUNNING' "$E2E_WORK/second.log" && pass "原因码 DBX-DAEMON-ALREADY-RUNNING" || fail "原因：$(cat "$E2E_WORK/second.log")"
[ "$(stat -f '%i' "$SOCK")" = "$INODE_BEFORE" ] && pass "原 daemon 的 socket 文件未被替换" || fail "socket 被替换（inode 变了）"
OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo still-mine 2>&1)
[ "$OUT" = still-mine ] && pass "原 daemon 仍可达，其 VM 未成孤儿（exec 正常）" || fail "原 daemon 的沙箱不可达：$OUT"
# 默认路径同理（victim）。
second_daemon "$E2E_WORK/second-default.log"
[ "$SECOND_RC" != 0 ] && [ "$SECOND_RC" != alive ] && grep -q 'DBX-DAEMON-ALREADY-RUNNING' "$E2E_WORK/second-default.log" && alive "$VICTIM_PID" \
  && pass "默认路径上同样拒绝接管" || fail "默认路径守卫失败 rc=$SECOND_RC"

# ================= S：跨进程 sweep =================
SNAPS="$COW_ROOT/snapshots"; mkdir -p "$SNAPS"
LIVE_TMP="tmp-p${MAIN_PID}-11111111-1111-1111-1111-111111111111.vzstate"
LIVE_RESTORE="tmp-restore-p${MAIN_PID}-22222222-2222-2222-2222-222222222222.vzstate"
DEAD_TMP="tmp-p999999999-33333333-3333-3333-3333-333333333333.vzstate"
LEGACY_YOUNG="tmp-44444444-4444-4444-4444-444444444444.vzstate"
LEGACY_OLD="tmp-restore-55555555-5555-5555-5555-555555555555.vzstate"
for f in "$LIVE_TMP" "$LIVE_RESTORE" "$DEAD_TMP" "$LEGACY_YOUNG" "$LEGACY_OLD"; do echo x > "$SNAPS/$f"; done
touch -t 202001010000 "$SNAPS/$LEGACY_OLD"

# ---------- S1 ----------
"$BIN" sweep >"$E2E_WORK/sweep1.json" 2>&1 || fail "sweep 失败：$(cat "$E2E_WORK/sweep1.json")"
[ -e "$SNAPS/$LIVE_TMP" ] && [ -e "$SNAPS/$LIVE_RESTORE" ] && pass "另一进程的 sweep 保留了活 daemon 的在途临时文件" || fail "在途临时文件被跨进程 sweep 删除"
[ ! -e "$SNAPS/$DEAD_TMP" ] && pass "属主已死的临时文件被删除" || fail "死属主的临时文件残留"
[ -e "$SNAPS/$LEGACY_YOUNG" ] && pass "旧格式且年轻的临时文件保留（宽限期）" || fail "旧格式年轻文件被删"
[ ! -e "$SNAPS/$LEGACY_OLD" ] && pass "旧格式且过期的临时文件被删除" || fail "旧格式过期文件残留"
python3 -c "import json;d=json.load(open('$E2E_WORK/sweep1.json'));assert d['orphanedSandboxes']==[] and d['removedCloneFiles']==[]" 2>/dev/null \
  && pass "sweep 未把运行中的沙箱当孤儿" || fail "sweep 报告异常：$(cat "$E2E_WORK/sweep1.json")"
OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo after-sweep 2>&1)
[ "$OUT" = after-sweep ] && pass "sweep 之后运行中的沙箱不受影响" || fail "sweep 之后 exec=$OUT"
rm -f "$SNAPS/$LEGACY_YOUNG"

# ---------- S2 ----------
( while :; do "$BIN" sweep >/dev/null 2>&1; done ) &
SWEEPER=$!
if e2e_screen_locked; then
  # 锁屏：只能验证保存路径——并发 sweep 下 suspend 成功、快照完整落盘。
  "$BIN" suspend --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/s2-susp.out" 2>&1 && SUSP=0 || SUSP=1
  kill "$SWEEPER" 2>/dev/null; wait "$SWEEPER" 2>/dev/null
  [ "$SUSP" = 0 ] && [ -s "$SNAPS/$ID.snap" ] && pass "CLI sweep 持续并发下 suspend 成功且快照落盘" \
    || fail "并发 sweep 下 suspend 失败：$(cat "$E2E_WORK/s2-susp.out")"
  expect_locked_resume "$SOCK" "$ID"
  skip_locked "CLI sweep 持续并发下 3 轮 suspend/resume"
  LEFT=$(ls -1 "$SNAPS" | grep -v -e "^$LIVE_TMP\$" -e "^$LIVE_RESTORE\$" -e "^$ID.snap\$" | tr '\n' ' ')
  [ -z "$LEFT" ] && pass "快照目录除植入文件与该沙箱快照外无残留" || fail "快照目录残留：$LEFT"
else
  CYCLES_OK=0
  for i in 1 2 3; do
    "$BIN" suspend --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/s2-susp-$i.out" 2>&1 \
      && "$BIN" resume --daemon-sock "$SOCK" "$ID" >"$E2E_WORK/s2-res-$i.out" 2>&1 \
      && CYCLES_OK=$((CYCLES_OK+1))
  done
  kill "$SWEEPER" 2>/dev/null; wait "$SWEEPER" 2>/dev/null
  [ "$CYCLES_OK" = 3 ] && pass "CLI sweep 持续并发下 3 轮 suspend/resume 全部成功" \
    || fail "并发 sweep 下只成功 $CYCLES_OK/3：$(cat "$E2E_WORK"/s2-*.out | grep -v ' ok ' | head -3)"
  OUT=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/echo after-cycles 2>&1)
  [ "$OUT" = after-cycles ] && pass "循环之后 exec 正常" || fail "循环之后 exec=$OUT"
  LEFT=$(ls -1 "$SNAPS" | grep -v -e "^$LIVE_TMP\$" -e "^$LIVE_RESTORE\$" | tr '\n' ' ')
  [ -z "$LEFT" ] && pass "快照目录除两份植入的在途文件外无残留" || fail "快照目录残留：$LEFT"
fi

# ---------- G2：崩溃残留可接管（顺带验证：属主死后在途文件被清） ----------
e2e_kill9 "$MAIN_PID"
[ -S "$SOCK" ] && pass "对照：kill -9 留下 stale socket" || fail "kill -9 后 socket 不存在？"
e2e_start_daemon && pass "新 daemon 接管了 stale socket" || fail "新 daemon 无法在 stale socket 上启动：$(tail -2 "$DAEMON_LOG")"
"$BIN" sweep >"$E2E_WORK/sweep2.json" 2>&1
[ ! -e "$SNAPS/$LIVE_TMP" ] && [ ! -e "$SNAPS/$LIVE_RESTORE" ] && pass "属主死亡后，其在途临时文件被清除" || fail "属主已死但临时文件残留"
python3 -c "import json;d=json.load(open('$E2E_WORK/sweep2.json'));assert len(d['orphanedSandboxes'])==1" 2>/dev/null \
  && pass "崩溃 daemon 的沙箱被识别为孤儿并清理" || fail "sweep2：$(cat "$E2E_WORK/sweep2.json")"
[ "$("$BIN" ps --daemon-sock "$SOCK" | wc -l | tr -d ' ')" = 0 ] && pass "新 daemon 不复活旧沙箱" || fail "新 daemon 列出了旧沙箱"

# ---------- 收尾 ----------
"$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1 && e2e_wait_exit "$DAEMON_PID" 100 && pass "主 daemon 正常停机" || fail "主 daemon 停机失败"
"$BIN" shutdown >/dev/null 2>&1 && e2e_wait_exit "$VICTIM_PID" 100 && pass "默认路径 daemon 经无参 shutdown 正常停机" || fail "victim 停机失败"
LEFT=$(find "$COW_ROOT" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "cow-root 零残留" || fail "cow-root 残留：$LEFT"

e2e_finish
