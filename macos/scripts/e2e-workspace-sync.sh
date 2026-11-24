#!/usr/bin/env bash
# M37 / INV-05：workspace 同步的边界（真机，2 台 VM）。
#
# 宿主侧（任何 guest 都应成立）：
#   W1  正常目录树：嵌套目录、空文件、带空格 / 非 ASCII 的文件名、可执行位 → guest 内容逐字节一致
#   W2  隐藏文件（.env、.git/…）不同步
#   W3  符号链接（指向外部文件 / 外部目录 / 内部文件 / 悬空 / 深层）→ 整次同步被拒，guest 不变
#   W4  限额：单文件 > 16MiB、总量 > 64MiB、文件数 > 4096 → 被拒，guest 不变
#   W5  特殊文件（FIFO）→ 立刻被拒，不挂住
#   W6  单向：guest 对 /workspace 的修改 / 删除 / 新建不会回流到宿主
#   W7  guest 看不到宿主文件系统
#   W10 exec 的 cwd / argv[0] 不能用 `..` 绕出 /workspace
#   G*  再次同步的闸门：workload 运行之前随便同步；运行之后只有新接收端（或显式放行）才允许
#
# guest 侧（取决于 guest 的 workspace 接收端版本，脚本自动识别）：
#   W8  文件变短后重新同步
#   W9  workload 在 /workspace 里预置符号链接 / FIFO，再同步同名文件
#   接收端版本 ≥ 2（补丁版 guest，见 scripts/build-patched-guest.sh）：断言修复生效；
#   接收端版本 1（旧 guest）：断言宿主闸门挡住了默认路径；缺陷本身只作为信息打印，不计入 PASS。
#
# 用法：
#   ./scripts/e2e-workspace-sync.sh                       # 用 guest/manifest.json
#   MANIFEST=<补丁版>/manifest.json RUN_FLAGS=--allow-unsigned-manifest ./scripts/e2e-workspace-sync.sh
#
# 资源纪律：scripts/lib/e2e-common.sh（隔离 support-root，退出自动清理并自检）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init ws
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"
SYNC_FLAGS=""        # 旧 guest 上跑宿主侧用例时要显式放行（一次性测试 VM）

gexec() { "$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c "$1" 2>&1 | tr -d '\r'; }
# sync_ws <目录> [额外参数]：成功返回 0；输出在 $E2E_WORK/sync.out
sync_ws() {
  local dir="$1"; shift
  # shellcheck disable=SC2086
  "$BIN" ws-sync --daemon-sock "$SOCK" "$ID" "$dir" $SYNC_FLAGS "$@" >"$E2E_WORK/sync.out" 2>&1
}
guest_tree_sum() { gexec 'cd /workspace && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | cut -d" " -f1'; }
new_sandbox() { # → 设置 ID
  # shellcheck disable=SC2086
  ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
  [ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
}
# reject_sync <描述> <目录> <期望子串>：同步必须被拒，且 guest 的 /workspace 没有任何变化。
reject_sync() {
  local before after
  before=$(guest_tree_sum)
  if sync_ws "$2"; then fail "$1：竟然同步成功（$(cat "$E2E_WORK/sync.out")）"; return; fi
  grep -qF -- "$3" "$E2E_WORK/sync.out" && pass "$1：被拒（$3）" || fail "$1：被拒但原因不符：$(head -c 200 "$E2E_WORK/sync.out")"
  after=$(guest_tree_sum)
  [ "$before" = "$after" ] && pass "$1：guest 的 /workspace 没有变化（无部分同步）" || fail "$1：guest 的 /workspace 被改动了"
}

e2e_start_daemon || die "daemon 未就绪"

SECRET="HOST-SECRET-$(openssl rand -hex 8)"
OUTSIDE="$E2E_WORK/outside"; mkdir -p "$OUTSIDE/dir"
printf '%s\n' "$SECRET" > "$OUTSIDE/secret.txt"
printf '%s\n' "$SECRET" > "$OUTSIDE/dir/inner-secret.txt"
WS="$E2E_WORK/ws"; mkdir -p "$WS/src/deep/er" "$WS/文档"
printf 'hello\n' > "$WS/README.md"
: > "$WS/empty"
printf 'spaced\n' > "$WS/src/file with spaces.txt"
printf '中文内容\n' > "$WS/文档/说明.txt"
head -c 300000 /dev/urandom > "$WS/src/deep/er/blob.bin"
printf '#!/bin/sh\necho ran-from-workspace\n' > "$WS/run.sh"; chmod 755 "$WS/run.sh"

# ================= G：再次同步的闸门（独立的一台沙箱，保证「workload 尚未运行」） =================
new_sandbox
GV=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('workspaceSyncVersion') or 1)" 2>/dev/null || echo 1)
log "guest 的 workspace 接收端版本：$GV（≥2 = 不跟随符号链接的新接收端）"
# 调用方声明了期望的接收端版本时（补丁版套件），跑到别的版本就是失败——否则会「全绿但什么都没验证」。
if [ -n "${EXPECT_RECEIVER_VERSION:-}" ]; then
  [ "$GV" = "$EXPECT_RECEIVER_VERSION" ] && pass "guest 接收端版本 = $GV（符合预期）" || fail "guest 接收端版本 = $GV（期望 $EXPECT_RECEIVER_VERSION）"
fi
sync_ws "$WS" && pass "G1 workload 运行之前：同步被允许（不需要任何放行参数）" || fail "G1 首次同步被拒：$(cat "$E2E_WORK/sync.out")"
sync_ws "$WS" && pass "G1 workload 运行之前：重复同步同样允许" || fail "G1 重复同步被拒：$(cat "$E2E_WORK/sync.out")"
[ "$(gexec 'cat /workspace/README.md')" = hello ] && pass "G1 内容已到达 guest（此后这台沙箱算「运行过 workload」）" || fail "G1 guest 内容不符"
BEFORE=$(guest_tree_sum)
if [ "$GV" -ge 2 ]; then
  sync_ws "$WS" && pass "G2 新接收端：workload 运行之后的再次同步被允许（不需要放行参数）" || fail "G2 再次同步被拒：$(cat "$E2E_WORK/sync.out")"
else
  if sync_ws "$WS"; then fail "G2 旧 guest 上 workload 运行之后的再次同步竟然被允许"
  else
    grep -q 'DBX-WS-RESYNC-UNSAFE' "$E2E_WORK/sync.out" && pass "G2 旧 guest：workload 运行之后的再次同步被拒（DBX-WS-RESYNC-UNSAFE）" \
      || fail "G2 被拒但原因不符：$(head -c 200 "$E2E_WORK/sync.out")"
  fi
  [ "$(guest_tree_sum)" = "$BEFORE" ] && pass "G2 被拒的同步没有改动 guest" || fail "G2 guest 被改动了"
  sync_ws "$WS" --allow-unsafe-resync && pass "G2 显式 --allow-unsafe-resync 后可以同步" || fail "G2 显式放行仍失败：$(cat "$E2E_WORK/sync.out")"
  grep -q 'UNSAFE workspace re-sync explicitly allowed' "$DAEMON_LOG" && pass "G2 显式放行在 daemon 日志里留痕" || fail "G2 放行没有留痕"
  SYNC_FLAGS="--allow-unsafe-resync"
fi
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1

# ================= 宿主侧边界（第二台沙箱） =================
new_sandbox
gexec 'true' >/dev/null     # 让它成为「运行过 workload」的沙箱：后面的同步都走再次同步路径

# ================= W1 =================
sync_ws "$WS" && pass "W1 同步成功（$(cat "$E2E_WORK/sync.out")）" || { fail "W1 同步失败：$(cat "$E2E_WORK/sync.out")"; e2e_finish; }
HOST_SUM=$(cd "$WS" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f" | awk '{print $1}'; done | shasum -a 256 | awk '{print $1}')
GUEST_SUM=$(gexec 'cd /workspace && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f" | cut -d" " -f1; done | sha256sum | cut -d" " -f1')
[ "$HOST_SUM" = "$GUEST_SUM" ] && pass "W1 guest 内 6 个文件逐字节一致（含空文件、带空格与非 ASCII 文件名、300KB 二进制）" \
  || fail "W1 内容不一致 host=$HOST_SUM guest=$GUEST_SUM；guest 文件：$(gexec 'cd /workspace && find . -type f | sort' | tr '\n' ' ')"
[ "$(gexec 'cd /workspace && find . -type f | wc -l' | tr -d ' ')" = 6 ] && pass "W1 guest 文件数 = 6" || fail "W1 guest 文件数=$(gexec 'cd /workspace && find . -type f | wc -l')"
[ "$(gexec '/workspace/run.sh')" = ran-from-workspace ] && pass "W1 可执行位保留，脚本可在 guest 内执行" || fail "W1 run.sh：$(gexec '/workspace/run.sh')"
[ "$(gexec 'ls -l /workspace/README.md | cut -c1-10')" = "-rw-r--r--" ] && pass "W1 普通文件权限 rw-r--r--" || fail "W1 README 权限=$(gexec 'ls -l /workspace/README.md')"

# ================= W2 =================
W2="$E2E_WORK/ws-hidden"; mkdir -p "$W2/.git" "$W2/.ssh"
printf 'visible\n' > "$W2/visible.txt"
printf 'API_KEY=%s\n' "$SECRET" > "$W2/.env"
printf '%s\n' "$SECRET" > "$W2/.git/config"
printf '%s\n' "$SECRET" > "$W2/.ssh/id_rsa"
ln -s "$OUTSIDE/secret.txt" "$W2/.hidden-link"
sync_ws "$W2" && pass "W2 含隐藏文件的目录可同步" || fail "W2 同步失败：$(cat "$E2E_WORK/sync.out")"
[ "$(gexec 'cat /workspace/visible.txt')" = visible ] && pass "W2 可见文件已同步" || fail "W2 visible.txt 缺失"
HID=$(gexec 'for n in .env .git .ssh .hidden-link; do [ -e "/workspace/$n" ] || [ -L "/workspace/$n" ] && echo "found:$n"; done; echo end' | tr '\n' ' ')
[ "$HID" = "end " ] && pass "W2 隐藏文件 / 目录（.env .git .ssh）没有进入 guest" || fail "W2 guest 里出现了隐藏项：$(gexec 'ls -a /workspace')"
[ "$(gexec "grep -rl '$SECRET' /workspace 2>/dev/null | wc -l" | tr -d ' ')" = 0 ] && pass "W2 guest 的 /workspace 里找不到宿主秘密" || fail "W2 秘密进入了 guest"

# ================= W3 =================
mk() { rm -rf "$E2E_WORK/ws-bad"; mkdir -p "$E2E_WORK/ws-bad"; printf 'ok\n' > "$E2E_WORK/ws-bad/ok.txt"; }
mk; ln -s "$OUTSIDE/secret.txt" "$E2E_WORK/ws-bad/link-to-file"
reject_sync "W3 符号链接 → 外部文件" "$E2E_WORK/ws-bad" "符号链接"
mk; ln -s "$OUTSIDE/dir" "$E2E_WORK/ws-bad/link-to-dir"
reject_sync "W3 符号链接 → 外部目录" "$E2E_WORK/ws-bad" "符号链接"
mk; ln -s ok.txt "$E2E_WORK/ws-bad/link-inside"
reject_sync "W3 符号链接 → workspace 内部文件" "$E2E_WORK/ws-bad" "符号链接"
mk; ln -s /nonexistent/target "$E2E_WORK/ws-bad/dangling"
reject_sync "W3 悬空符号链接" "$E2E_WORK/ws-bad" "符号链接"
mk; mkdir -p "$E2E_WORK/ws-bad/a/b"; ln -s "$OUTSIDE/secret.txt" "$E2E_WORK/ws-bad/a/b/deep-link"
reject_sync "W3 深层目录里的符号链接" "$E2E_WORK/ws-bad" "符号链接"
[ "$(gexec "grep -rl '$SECRET' /workspace 2>/dev/null | wc -l" | tr -d ' ')" = 0 ] && pass "W3 五种符号链接之后 guest 里仍找不到宿主秘密" || fail "W3 秘密进入了 guest"

# ================= W4 =================
mk; mkfile -n 17m "$E2E_WORK/ws-bad/big.bin"
reject_sync "W4 单文件 17MiB（限额 16MiB）" "$E2E_WORK/ws-bad" "超过限额"
mk; for i in 1 2 3 4 5; do mkfile -n 15m "$E2E_WORK/ws-bad/part$i.bin"; done
reject_sync "W4 总量 75MiB（限额 64MiB）" "$E2E_WORK/ws-bad" "超过限额"
mk; ( cd "$E2E_WORK/ws-bad" && python3 -c "
for i in range(4100): open('f%04d' % i, 'w').close()" )
reject_sync "W4 文件数 4101（限额 4096）" "$E2E_WORK/ws-bad" "超过限额"

# ================= W5 =================
mk; mkfifo "$E2E_WORK/ws-bad/pipe"
t0=$(now_ms)
reject_sync "W5 FIFO" "$E2E_WORK/ws-bad" "不支持的文件类型"
[ $(( $(now_ms) - t0 )) -lt 8000 ] && pass "W5 FIFO 被立刻拒绝（没有挂在读取上）" || fail "W5 FIFO 处理耗时 $(( $(now_ms) - t0 ))ms"

# ================= W6 =================
sync_ws "$WS" >/dev/null 2>&1
H_BEFORE=$(cd "$WS" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')
gexec 'echo TAMPERED > /workspace/README.md; rm -f /workspace/run.sh; echo new > /workspace/created-in-guest.txt; echo done' >/dev/null
H_AFTER=$(cd "$WS" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')
[ "$H_BEFORE" = "$H_AFTER" ] && [ ! -e "$WS/created-in-guest.txt" ] && [ -x "$WS/run.sh" ] \
  && pass "W6 guest 对 /workspace 的修改 / 删除 / 新建没有回流到宿主" || fail "W6 宿主 workspace 被 guest 改动了"

# ================= W7 =================
OUT=$(gexec "ls /Users /private /Volumes 2>&1; cat '$OUTSIDE/secret.txt' 2>&1; cat '$WS/README.md' 2>&1")
echo "$OUT" | grep -q "$SECRET" && fail "W7 guest 读到了宿主文件" || pass "W7 guest 无法按宿主路径读到任何东西"
SHARED=$(gexec 'cat /proc/mounts' | awk '{print $3}' | grep -E '^(virtiofs|9p|nfs|nfs4|cifs|smb3|fuse.*)$' | tr '\n' ' ')
[ -z "$SHARED" ] && pass "W7 guest 没有任何共享文件系统挂载（virtiofs / 9p / nfs / cifs / fuse）" || fail "W7 guest 有共享挂载：$SHARED"

# ================= W10：exec 的 cwd / argv0 =================
"$BIN" exec --daemon-sock "$SOCK" "$ID" --cwd /workspace/../etc -- /bin/sh -c pwd >"$E2E_WORK/w10a.out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && ! grep -qx '/etc' "$E2E_WORK/w10a.out" && pass "W10 --cwd /workspace/../etc 被拒（此前会在 /etc 下执行）" || fail "W10 cwd 绕过：$(cat "$E2E_WORK/w10a.out")"
"$BIN" exec --daemon-sock "$SOCK" "$ID" -- /workspace/../bin/busybox echo via-dotdot >"$E2E_WORK/w10b.out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && ! grep -q 'via-dotdot' "$E2E_WORK/w10b.out" && pass "W10 argv[0]=/workspace/../bin/busybox 被拒（此前被当成 workspace 内的可执行文件）" || fail "W10 argv0 绕过：$(cat "$E2E_WORK/w10b.out")"
[ "$("$BIN" exec --daemon-sock "$SOCK" "$ID" --cwd /workspace/src -- /bin/sh -c pwd 2>&1)" = /workspace/src ] && pass "W10 合法的 --cwd /workspace/src 仍然可用" || fail "W10 合法 cwd 被误拒"

# ================= W8：重复同步，文件变短 / 被删除 =================
W8="$E2E_WORK/ws-shrink"; mkdir -p "$W8"
printf 'AAAAAAAAAAAAAAAAAAAA\n' > "$W8/shrink.txt"; printf 'stays\n' > "$W8/gone-later.txt"
sync_ws "$W8" >/dev/null 2>&1
printf 'BB\n' > "$W8/shrink.txt"; rm -f "$W8/gone-later.txt"
sync_ws "$W8" || fail "W8 第二次同步失败：$(cat "$E2E_WORK/sync.out")"
GOT=$(gexec 'cat /workspace/shrink.txt' | tr '\n' '|')
if [ "$GV" -ge 2 ]; then
  [ "$GOT" = "BB|" ] && pass "W8 文件变短后重新同步：guest 内容正好是新内容（旧内容的尾巴被截掉）" || fail "W8 guest 内容=[$GOT]（期望 [BB|]）"
else
  log "KNOWN-DEFECT（旧 guest，仅在显式放行后可达）W8：文件变短后重新同步，guest 内容=[$GOT]（期望 [BB|]）"
fi
# 宿主侧删除的文件不会从 guest 里消失：同步是「覆盖 / 新增」，不是镜像。两种 guest 都如此，这里只记录事实。
log "同步语义（非镜像）：宿主侧已删除的文件在 guest 里$([ "$(gexec '[ -e /workspace/gone-later.txt ] && echo yes || echo no')" = yes ] && echo 仍然存在 || echo 已消失)"

# ================= W9：workload 在 /workspace 里预置的东西 =================
# 沙箱内的 workload 是 uid 65534，写不了 /etc。它能否借「下一次同步」让 root 替它写？
[ "$(gexec 'touch /etc/dbx-w9-self 2>&1 | grep -c "Permission denied"')" = 1 ] && pass "W9 对照：workload 自己写不了 /etc" || fail "W9 对照失败：workload 能写 /etc"
plant() { # <描述> <guest 里的预置命令> <宿主 workspace 目录> <不应出现的 guest 路径>
  local what="$1" setup="$2" dir="$3" forbidden="$4"
  gexec "$setup" >/dev/null
  sync_ws "$dir" && SYNC_RC=0 || SYNC_RC=$?
  local leaked; leaked=$(gexec "[ -e '$forbidden' ] && echo yes || echo no")
  if [ "$GV" -ge 2 ]; then
    [ "$leaked" = no ] && pass "W9 $what：root 没有被引到 /workspace 之外写文件" || fail "W9 $what：$forbidden 被创建了：$(gexec "ls -ln '$forbidden'")"
    [ "$SYNC_RC" != 0 ] && pass "W9 $what：同步失败并报告给宿主（fail-closed）" || fail "W9 $what：同步竟然报告成功"
  else
    log "KNOWN-DEFECT（旧 guest，仅在显式放行后可达）W9 $what：$forbidden $([ "$leaked" = yes ] && echo "被 root 创建：$(gexec "ls -ln '$forbidden'" | tr '\n' ' ')" || echo 未被创建)"
  fi
}
WA="$E2E_WORK/ws-plant-a"; mkdir -p "$WA"; printf 'HOSTDATA-A\n' > "$WA/planted.txt"
plant "符号链接直接放在 /workspace（粘滞位目录）" \
  'rm -rf /workspace/planted.txt; ln -s /etc/dbx-w9-a /workspace/planted.txt' "$WA" /etc/dbx-w9-a
WB="$E2E_WORK/ws-plant-b"; mkdir -p "$WB/sub"; printf 'HOSTDATA-B\n' > "$WB/sub/planted.txt"
plant "符号链接放在 workload 自己建的子目录里" \
  'rm -f /workspace/planted.txt; mkdir -p /workspace/sub; ln -s /etc/dbx-w9-b /workspace/sub/planted.txt' "$WB" /etc/dbx-w9-b
WC="$E2E_WORK/ws-plant-c"; mkdir -p "$WC/a/b"; printf 'HOSTDATA-C\n' > "$WC/a/b/dbx-w9-c.txt"
plant "中间一级目录是指向 /etc 的符号链接" \
  'rm -rf /workspace/sub; mkdir -p /workspace/a; ln -s /etc /workspace/a/b' "$WC" /etc/dbx-w9-c.txt
if [ "$GV" -ge 2 ]; then
  # FIFO：旧实现的 open(O_WRONLY) 会一直阻塞在没有读者的 FIFO 上（整个 bootstrap 主循环随之卡死）。
  WD="$E2E_WORK/ws-plant-d"; mkdir -p "$WD/q"; printf 'HOSTDATA-D\n' > "$WD/q/pipe.txt"
  # guest 的 busybox 没有 mkfifo 命令，用 mknod 建。
  gexec 'rm -rf /workspace/a; mkdir -p /workspace/q; mknod /workspace/q/pipe.txt p' >/dev/null
  [ "$(gexec '[ -p /workspace/q/pipe.txt ] && echo fifo')" = fifo ] && pass "W9 对照：workload 确实在目标位置放了一个 FIFO" || fail "W9 对照失败：FIFO 没有建出来"
  t0=$(now_ms); sync_ws "$WD" && SYNC_RC=0 || SYNC_RC=$?
  [ "$SYNC_RC" != 0 ] && [ $(( $(now_ms) - t0 )) -lt 8000 ] && pass "W9 目标位置是 workload 放的 FIFO：同步失败且没有挂住（$(( $(now_ms) - t0 ))ms）" \
    || fail "W9 FIFO：rc=$SYNC_RC 耗时 $(( $(now_ms) - t0 ))ms"
  [ "$(gexec 'echo still-alive')" = still-alive ] && pass "W9 之后 guest 仍然响应（bootstrap 没有被卡死）" || fail "W9 之后 guest 不再响应"
  # 正常路径没有被误伤：清掉预置物之后，同步恢复正常。
  gexec 'rm -rf /workspace/q /workspace/a /workspace/sub /workspace/planted.txt' >/dev/null
  sync_ws "$WB" && [ "$(gexec 'cat /workspace/sub/planted.txt')" = HOSTDATA-B ] \
    && pass "W9 清掉预置物后，同样的目录可以正常同步（修复没有误伤正常路径）" || fail "W9 正常同步被误伤：$(cat "$E2E_WORK/sync.out")"
fi

# ================= W11：workload 与同步并发（仅新接收端） =================
# W9 的预置物是静止的。这里 workload 在终端里**不停地**把目标文件 / 中间目录在「真实对象」与
# 「指向 /etc 的符号链接」之间切换，同时宿主反复同步——检查「先检查、后打开」之间有没有可乘之机。
if [ "$GV" -ge 2 ]; then
  WR="$E2E_WORK/ws-race"; mkdir -p "$WR/r" "$WR/r2"
  printf 'HOSTDATA-R\n' > "$WR/r/t"; printf 'HOSTDATA-R2\n' > "$WR/r2/dbx-w11b.txt"
  gexec 'rm -rf /workspace/r /workspace/r2; mkdir -p /workspace/r' >/dev/null
  FLIP='while :; do rm -f /workspace/r/t; ln -s /etc/dbx-w11a /workspace/r/t; rm -f /workspace/r/t; echo mine > /workspace/r/t; rm -rf /workspace/r2 2>/dev/null; ln -s /etc /workspace/r2 2>/dev/null; rm -f /workspace/r2 2>/dev/null; mkdir /workspace/r2 2>/dev/null; echo tick >> /workspace/r/ticks; done'
  PTY=$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" spawn "$ID" "$FLIP")
  case "$PTY" in FAIL*|"") fail "W11 无法在终端里启动切换循环：$PTY" ;; esac
  sleep 1
  OKN=0; REJ=0
  for _ in $(seq 1 40); do sync_ws "$WR" && OKN=$((OKN+1)) || REJ=$((REJ+1)); done
  python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" close "$PTY" >/dev/null 2>&1
  TICKS=$(gexec 'wc -l < /workspace/r/ticks 2>/dev/null || echo 0' | tr -d ' ')
  [ "${TICKS:-0}" -ge 20 ] && pass "W11 对照：切换循环在同步期间确实在跑（$TICKS 轮）" || fail "W11 对照失败：切换循环只跑了 ${TICKS:-0} 轮"
  LEAK=$(gexec 'for f in /etc/dbx-w11a /etc/dbx-w11b.txt; do [ -e "$f" ] && echo "leak:$f"; done; echo end' | tr '\n' ' ')
  [ "$LEAK" = "end " ] && pass "W11 并发切换下 40 次同步（$OKN 成功 / $REJ 被拒）：/etc 下始终没有被写入" || fail "W11 并发切换下写到了 /workspace 之外：$LEAK"
  [ "$REJ" -ge 1 ] && pass "W11 确实撞上过符号链接状态（$REJ 次同步被拒）" || log "W11 注意：40 次同步没有一次被拒——竞争窗口可能没有被触及"
  [ "$(gexec 'echo still-alive')" = still-alive ] && pass "W11 之后 guest 仍然响应" || fail "W11 之后 guest 不再响应"
fi

"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "沙箱已移除" || fail "rm 失败"
LEFT=$(find "$COW_ROOT" -type f ! -name 'registry.json' ! -name 'registry.lock' 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "cow-root 零残留" || fail "cow-root 残留：$LEFT"
e2e_finish
