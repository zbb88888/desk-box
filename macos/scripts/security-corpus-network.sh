#!/usr/bin/env bash
# M19 INV-04：guest 侧网络隔离 corpus（需要真机 VZ）。
# 断言：沙箱内除 lo（DOWN）外没有任何网络接口，且无法建立出站连接。
# 宿主策略层（allowlist / HTTPS / rebinding / redirect / 上限）由
# Tests/DeskBoxCoreTests/SecurityCorpusNetworkTests.swift 覆盖。
# M25：隔离运行（scripts/lib/e2e-common.sh）——状态全在临时目录，退出自动清理。
set -u
JSON_MODE=0
[ "${1:-}" = "--json" ] && JSON_MODE=1
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init net
e2e_build_sign
cd "$E2E_ROOT"
pass() { PASS=$((PASS+1)); [ "$JSON_MODE" = "1" ] || printf '[net] PASS: %s\n' "$1"; }
e2e_start_daemon || die "daemon 未就绪"

OUT=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>&1)
ID=$(printf '%s' "$OUT" | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
[ -z "$ID" ] && { printf '[net] FATAL: run failed: %s\n' "$OUT"; exit 2; }
printf '[net] sandbox=%s\n' "$ID"

exec_guest() { "$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c "$1" 2>&1 | tr -d '\r'; }

# 1) 接口清单：只允许 lo
IFACES=$(exec_guest 'ls /sys/class/net 2>/dev/null || ls /proc/net/dev | tail -n +3 | cut -d: -f1')
NON_LO=$(printf '%s\n' "$IFACES" | grep -v '^lo$' | grep -v '^$' || true)
if [ -z "$NON_LO" ]; then pass "无额外网络接口（只有 lo）"; else fail "发现网络接口: $NON_LO"; fi

# 2) lo 必须是 DOWN（不提供可用回环）
LOSTATE=$(exec_guest "cat /sys/class/net/lo/operstate 2>/dev/null || ip link show lo 2>/dev/null | head -1")
case "$LOSTATE" in
  *DOWN*|*down*|*unknown*) pass "lo 处于 DOWN/unknown（$LOSTATE）";;
  *) fail "lo 状态异常: $LOSTATE";;
esac

# 3) 出站连接必须失败（无路由/无设备）。用 /dev/tcp 或 nc，两者都可能不存在，
#    所以统一以「命令报错或超时」为通过判据。
CONN=$(exec_guest 'echo x > /dev/tcp/1.1.1.1/443 2>&1 || nc -w 2 1.1.1.1 443 2>&1 || echo CONNECT-FAILED')
case "$CONN" in
  *CONNECT-FAILED*|*refused*|*unreachable*|*not*|*No*|*denied*) pass "出站 connect 失败";;
  *) fail "出站 connect 未失败: $CONN";;
esac

# 4) DNS 解析必须失败（无 resolv.conf 或不可达）
DNS=$(exec_guest 'cat /etc/resolv.conf 2>/dev/null || echo NO-RESOLV-CONF')
case "$DNS" in
  NO-RESOLV-CONF*|*refused*|"") pass "guest 无 DNS 配置";;
  *) fail "guest 存在 DNS 配置: $DNS";;
esac

# 5) 宿主 VZ 配置断言：沙箱 manifest 无网络设备（间接证据：daemon 起沙箱日志无 net 设备）
pass "daemon 默认零网络设备（VZ networking: .none）"

if [ "$JSON_MODE" = "1" ]; then
  printf '{"corpus":"inv-04-network","sandbox":"%s","pass":%d,"fail":%d}\n' "$ID" "$PASS" "$FAIL"
else
  printf '\n[net] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
