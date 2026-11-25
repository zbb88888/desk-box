#!/usr/bin/env bash
# M42：guest 内的 broker 入口（/run/deskbox-broker.sock）不能被 workload 用来搞垮控制面（真机，1–2 台 VM）。
#
# 脚本按 guest 的 broker 入口版本（stats 里的 brokerVersion）自动分支：
#   版本 ≥ 3（当前源码）：
#     B1  在 exec 里调用 brokerreq：立刻返回（此前一直卡到 exec 超时），之后沙箱照常可用；
#         被策略拒绝的请求以非零退出码和原因返回（M43；此前返回 0，只留下一个空文件）
#     B2  broker 客户端在应答之前就退出（连上、发请求、立刻关闭）×20：bootstrap 不会被 SIGPIPE 杀掉
#     B3  连上却什么都不发的客户端：不会把 bootstrap 卡住，宿主的请求照常得到应答
#     B4  workload 的 SIGPIPE 行为保持默认（bootstrap 自己忽略 SIGPIPE，但不能传给子进程）
#     B5  （需要宿主能访问 example.com）brokerreq 返回时文件已经完整落盘；上游 404 以非零退出码返回
#   版本 1（旧 guest）：
#     K1  在 exec 里调用 brokerreq → guest 的控制面被杀，沙箱进入 failed（已知缺陷，只打印，不计入 PASS）
#     K2  宿主一侧能收拾：failed 的沙箱可以 rm，daemon 与其它沙箱不受影响
#     K3  控制面死掉之后，宿主的请求立刻失败并说明原因（M43），不会等到超时
#
# B2 / B3 需要一个能直接操作 unix socket 的小程序：用本机的 aarch64-linux-musl 交叉编译器静态编译后
# 同步进 /workspace 执行；没有交叉编译器时这两项 SKIP。
# 用法同 e2e-workspace-sync.sh（MANIFEST / RUN_FLAGS）。资源纪律：scripts/lib/e2e-common.sh。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init bk
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"

# broker 的策略文件在「manifest 所在目录」。把 manifest 和资产克隆到本次运行的临时目录，在那里放策略
#（不往真实的 guest/ 目录写任何东西）。
SRC_GUEST="$(dirname "$MANIFEST")"
mkdir -p "$E2E_WORK/guest"
cp "$MANIFEST" "$E2E_WORK/guest/manifest.json"
for asset in $(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['fileDigests']))" "$MANIFEST"); do
  cp -c "$SRC_GUEST/$asset" "$E2E_WORK/guest/$asset" 2>/dev/null || cp "$SRC_GUEST/$asset" "$E2E_WORK/guest/$asset"
done
MANIFEST="$E2E_WORK/guest/manifest.json"
printf '{"allowedHosts":["example.com"],"allowedSchemes":["https"],"maxResponseBytes":65536}\n' > "$E2E_WORK/guest/broker-policy.json"

e2e_start_daemon || die "daemon 未就绪"
new_sandbox() {
  # shellcheck disable=SC2086
  ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
  [ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
}
new_sandbox
BV=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('brokerVersion') or 1)" 2>/dev/null || echo 1)
log "guest 的 broker 入口版本：$BV"
if [ -n "${EXPECT_BROKER_VERSION:-}" ]; then
  [ "$BV" = "$EXPECT_BROKER_VERSION" ] && pass "guest broker 入口版本 = $BV（符合预期）" || fail "guest broker 入口版本 = $BV（期望 $EXPECT_BROKER_VERSION）"
fi

O="$E2E_WORK/out"; E="$E2E_WORK/err"
x() { # <超时> <命令>
  local t0; t0=$(now_ms)
  "$BIN" exec --daemon-sock "$SOCK" "$ID" --timeout "$1" -- /bin/sh -c "$2" >"$O" 2>"$E" && RC=0 || RC=$?
  MS=$(( $(now_ms) - t0 ))
}
state_of() { "$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | awk -v id="$1" '$1==id {print $2}'; }

if [ "$BV" -ge 3 ]; then
  # ---------- B1 ----------
  x 8 'brokerreq https://not-allowed.invalid/probe.txt; echo "rc=$?"'
  [ "$RC" = 0 ] && [ "$MS" -lt 3000 ] \
    && pass "B1 exec 里调用 brokerreq：${MS}ms 返回（此前卡到 exec 超时）" || fail "B1 rc=$RC ${MS}ms out=[$(cat "$O")] err=[$(cat "$E")]"
  [ "$(cat "$O")" = "rc=8" ] && grep -q 'allowlist' "$E" \
    && pass "B1 被策略拒绝：brokerreq 退出码 8，stderr 给出原因（$(head -c 60 "$E" | tr '\n' ' ')…）" || fail "B1 拒绝结果：out=[$(cat "$O")] err=[$(cat "$E")]"
  x 5 'echo alive'
  [ "$RC" = 0 ] && [ "$(state_of "$ID")" = running ] && pass "B1 之后沙箱照常可用（state=running）" || fail "B1 之后 rc=$RC state=$(state_of "$ID")"
  sleep 0.5
  grep -q 'broker: fetch failed host=not-allowed.invalid' "$DAEMON_LOG" && pass "B1 被策略拒绝的请求在宿主日志里留痕（只记主机名）" || fail "B1 宿主日志里没有 broker 失败记录"

  # ---------- B4：SIGPIPE 的默认行为没有被继承走 ----------
  x 8 'seq 1 200000 | head -n 1; echo "pipe-rc=$?"'
  [ "$RC" = 0 ] && [ "$(cat "$O")" = "$(printf '1\npipe-rc=0')" ] && [ ! -s "$E" ] \
    && pass "B4 exec 里 \`seq 1 200000 | head -n 1\` 安静结束（写端被 SIGPIPE 终止，没有写错误的报错）" || fail "B4 rc=$RC out=[$(cat "$O")] err=[$(cat "$E")]"
  # SigIgn 位图第 13 位（SIGPIPE，值 0x1000）不应被置位：直接读一个新进程的状态
  x 8 'cat /proc/self/status | grep "^SigIgn:"'
  SIGIGN=$(awk '{print $2}' "$O")
  [ -n "$SIGIGN" ] && [ $(( 0x$SIGIGN & 0x1000 )) = 0 ] && pass "B4 exec 出来的进程没有继承「忽略 SIGPIPE」（SigIgn=$SIGIGN）" || fail "B4 SigIgn=$SIGIGN"

  # ---------- B2 / B3：需要直接操作 unix socket 的小程序 ----------
  CC="${CROSS_CC:-aarch64-linux-musl-gcc}"
  if command -v "$CC" >/dev/null 2>&1; then
    mkdir -p "$E2E_WORK/ws"
    cat > "$E2E_WORK/ubroker.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
static int dial(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un su; memset(&su, 0, sizeof(su)); su.sun_family = AF_UNIX;
    strncpy(su.sun_path, "/run/deskbox-broker.sock", sizeof(su.sun_path) - 1);
    if (fd < 0 || connect(fd, (struct sockaddr *)&su, sizeof(su)) != 0) { perror("connect"); exit(5); }
    return fd;
}
int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "drop") == 0) {          /* 连上、发请求、不等应答就关闭 */
        int n = atoi(argv[2]);
        for (int i = 0; i < n; i++) {
            int fd = dial();
            char req[128]; int len = snprintf(req, sizeof(req), "GET https://not-allowed.invalid/drop-%d.txt\n", i);
            if (write(fd, req, (size_t)len) != len) { perror("write"); return 6; }
            close(fd);
            usleep(20000);
        }
        printf("dropped %d\n", n); return 0;
    }
    if (argc >= 3 && strcmp(argv[1], "idle") == 0) {          /* 连上之后什么都不发，挂着 */
        int fd = dial(); (void)fd;
        printf("idling\n"); fflush(stdout);
        sleep((unsigned)atoi(argv[2]));
        printf("idle-done\n"); return 0;
    }
    return 2;
}
C
    "$CC" -static -O2 -Wall -o "$E2E_WORK/ws/ubroker" "$E2E_WORK/ubroker.c" 2>"$E2E_WORK/cc.err" || die "测试辅助程序编译失败：$(cat "$E2E_WORK/cc.err")"
    chmod 755 "$E2E_WORK/ws/ubroker"
    # 同步在任何 exec 之后：新接收端允许。
    "$BIN" ws-sync --daemon-sock "$SOCK" "$ID" "$E2E_WORK/ws" >"$E2E_WORK/sync.out" 2>&1 || die "辅助程序同步失败：$(cat "$E2E_WORK/sync.out")"

    x 15 '/workspace/ubroker drop 20'
    [ "$RC" = 0 ] && [ "$(cat "$O")" = "dropped 20" ] && pass "B2 对照：20 个「发完请求不等应答就关闭」的 broker 客户端都跑完了" || fail "B2 辅助程序 rc=$RC ${MS}ms out=[$(cat "$O")] err=[$(cat "$E")]"
    sleep 0.5
    x 5 'echo survived-drops'
    [ "$RC" = 0 ] && [ "$(cat "$O")" = survived-drops ] && [ "$(state_of "$ID")" = running ] \
      && pass "B2 bootstrap 没有被 SIGPIPE 杀掉：控制面仍在，沙箱 state=running" || fail "B2 之后 rc=$RC state=$(state_of "$ID") err=[$(cat "$E")]"

    # B3：一个挂着不说话的客户端（在终端里跑，持续 6s），同时宿主的 exec 必须照常工作
    SESS=$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" spawn "$ID" '/workspace/ubroker idle 6')
    case "$SESS" in FAIL*|"") fail "B3 终端打不开：$SESS" ;; esac
    [ "$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" expect "$SESS" idling 5)" = OK ] && pass "B3 对照：有一个 broker 客户端连上了却什么都不发" || fail "B3 对照失败"
    SLOW=0
    for _ in 1 2 3 4 5; do
      x 5 'echo responsive'
      [ "$RC" = 0 ] && [ "$(cat "$O")" = responsive ] && [ "$MS" -lt 1500 ] || SLOW=$((SLOW+1))
    done
    [ "$SLOW" = 0 ] && pass "B3 这期间宿主的 5 条 exec 都在 1.5s 内应答（bootstrap 没有卡在那个客户端上）" || fail "B3 有 $SLOW 条 exec 变慢或失败"
    python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" close "$SESS" >/dev/null 2>&1
  else
    skip "B2 / B3 需要 aarch64-linux-musl 交叉编译器来构建测试辅助程序"
  fi

  # ---------- B5：真实下载，在同一条 exec 期间到达 ----------
  if curl -fsS --max-time 8 -o /dev/null https://example.com/ 2>/dev/null; then
    # 不轮询：brokerreq 返回 0 的那一刻文件就必须完整。
    x 25 'rm -f /workspace/inbound/index.html; brokerreq https://example.com/ || exit 9; wc -c < /workspace/inbound/index.html; grep -c -i "example" /workspace/inbound/index.html'
    BYTES=$(grep -E '^ *[0-9]+ *$' "$O" | sed -n 1p | tr -d ' '); HITS=$(grep -E '^ *[0-9]+ *$' "$O" | sed -n 2p | tr -d ' ')
    HOST_BYTES=$(curl -fsS --max-time 8 https://example.com/ 2>/dev/null | wc -c | tr -d ' ')
    [ "$RC" = 0 ] && [ "${BYTES:-0}" -ge 100 ] 2>/dev/null && [ "${HITS:-0}" -ge 1 ] 2>/dev/null && [ "$BYTES" = "$HOST_BYTES" ] \
      && pass "B5 brokerreq 返回 0 时文件已完整落盘（$BYTES 字节，与宿主直接下载的大小一致；${MS}ms，同一条 exec 内，无需轮询）" || fail "B5 rc=$RC host=$HOST_BYTES out=[$(tr '\n' ' ' < "$O")] err=[$(head -c 200 "$E")]"
    # brokerreq 客户端在 root 盘里：补丁版夹具只换 initrd，客户端仍是旧的（不打印结果行）；正式构建的 guest 才有新客户端。
    if grep -q '^saved ' "$O"; then
      grep -q "^saved $BYTES bytes (HTTP 200)\$" "$O" && pass "B5 新版 brokerreq 打印结果行（saved $BYTES bytes (HTTP 200)）" || fail "B5 结果行不符：$(grep '^saved ' "$O")"
    else
      log "B5 这套 guest 的 brokerreq 客户端是旧版（不打印结果行）；退出码与落盘结果已在上面验证"
    fi
    x 25 'brokerreq https://example.com/dbx-no-such-page-404.txt; echo "rc=$?"'
    grep -q '^rc=8$' "$O" && grep -q '404' "$E" && pass "B5 上游 404：brokerreq 退出码 8，stderr 含状态码" || fail "B5 404：out=[$(cat "$O")] err=[$(cat "$E")]"
  else
    skip "B5 宿主访问不了 https://example.com，无法验证真实下载"
  fi
else
  # ---------- 旧 guest ----------
  x 5 'brokerreq https://not-allowed.invalid/probe.txt; echo "rc=$?"'
  FIRST_RC=$RC; FIRST_MS=$MS
  # M45：不需要再发任何请求——控制连接一断，沙箱就该显示为 failed，并带上原因。
  ST=running; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do ST=$(state_of "$ID"); [ "$ST" = failed ] && break; sleep 0.1; done
  [ "$ST" = failed ] && pass "K4 控制面一死，ps 立刻显示 failed（没有任何后续请求去「撞」它）" || fail "K4 1.5s 后 ps 仍显示 $ST"
  "$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | awk -F'\t' -v id="$ID" '$1==id {print $6}' | grep -q 'DBX-GUEST-CONTROL-LOST' \
    && pass "K4 ps 带上了原因（DBX-GUEST-CONTROL-LOST）" || fail "K4 ps 没有原因列：$("$BIN" ps --daemon-sock "$SOCK" 2>/dev/null | head -2)"
  x 5 'echo probe-after'
  ST=$(state_of "$ID")
  log "KNOWN-DEFECT（旧 guest）K1：exec 里调用 brokerreq → 那条 exec rc=$FIRST_RC（${FIRST_MS}ms，卡到超时）；随后的 exec rc=$RC，沙箱 state=$ST（failed = guest 的控制面被 SIGPIPE 杀掉）"
  [ "$RC" != 0 ] && [ "$MS" -lt 2000 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$E" \
    && pass "K3 控制面死掉之后：随后的 exec ${MS}ms 内失败并说明原因（DBX-GUEST-CONTROL-LOST）" || fail "K3 rc=$RC ${MS}ms err=[$(head -c 200 "$E")]"
  mkdir -p "$E2E_WORK/k3ws"; echo x > "$E2E_WORK/k3ws/f.txt"
  t0=$(now_ms); "$BIN" ws-sync --daemon-sock "$SOCK" "$ID" "$E2E_WORK/k3ws" --allow-unsafe-resync >"$E2E_WORK/k3.out" 2>&1 && WRC=0 || WRC=$?
  [ "$WRC" != 0 ] && [ $(( $(now_ms) - t0 )) -lt 2000 ] && grep -q 'DBX-GUEST-CONTROL-LOST' "$E2E_WORK/k3.out" \
    && pass "K3 同步请求同样立刻失败并说明原因" || fail "K3 ws-sync rc=$WRC $(head -c 200 "$E2E_WORK/k3.out")"
  t0=$(now_ms); PTYRES=$(python3 "$E2E_ROOT/scripts/lib/pty_client.py" "$SOCK" open "$ID" 2>&1)
  case "$PTYRES" in
    FAIL*DBX-GUEST-CONTROL-LOST*) [ $(( $(now_ms) - t0 )) -lt 2000 ] && pass "K3 打开终端同样立刻失败并说明原因" || fail "K3 ptyOpen 等了 $(( $(now_ms) - t0 ))ms" ;;
    *) fail "K3 ptyOpen 结果不符：$(printf '%s' "$PTYRES" | head -c 200)" ;;
  esac
  # M45：failed 的沙箱一步重建（GUI 的 Restart 发的就是这个请求）。
  OLD_ID=$ID
  NEW_ID=$("$BIN" restart --daemon-sock "$SOCK" "$OLD_ID" 2>"$E2E_WORK/restart.err" | sed -n 's/^restarted -> //p')
  [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$OLD_ID" ] && [ "$(state_of "$NEW_ID")" = running ] && [ -z "$(state_of "$OLD_ID")" ] \
    && pass "K5 restart：failed 的沙箱被移除，同样的参数重建出一台 running 的新沙箱" || fail "K5 restart：new=$NEW_ID old-state=$(state_of "$OLD_ID") $(head -c 200 "$E2E_WORK/restart.err")"
  ID=${NEW_ID:-$OLD_ID}
  x 8 'echo restarted-ok'
  [ "$RC" = 0 ] && [ "$(cat "$O")" = restarted-ok ] && pass "K5 重建出来的沙箱正常工作" || fail "K5 新沙箱 rc=$RC err=[$(cat "$E")]"
  "$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "K2 宿主能收拾：沙箱可以 rm" || fail "K2 rm 失败"
  new_sandbox
  x 8 'echo fresh-sandbox-ok'
  [ "$RC" = 0 ] && [ "$(cat "$O")" = fresh-sandbox-ok ] && pass "K2 daemon 不受影响：新建的沙箱正常工作" || fail "K2 新沙箱 rc=$RC err=[$(cat "$E")]"
fi

x 8 'echo still-alive'
[ "$RC" = 0 ] && [ "$(cat "$O")" = still-alive ] && pass "之后 guest 仍然响应" || fail "之后 guest 不再响应：rc=$RC err=[$(cat "$E")]"
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1 && pass "沙箱已移除" || fail "rm 失败"
e2e_finish
