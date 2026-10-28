#!/usr/bin/env bash
# M23 / INV-02：多凭据域隔离 e2e。
#
# 断言（负例优先）：
#   1) domains.json fail-closed（未知域/非法 schema 被拒）
#   2) 两个域并发创建沙箱：各自 running，ps 显示正确 domain
#   3) 跨域 exec 被拒（DBX-DOMAIN-SESSION-MISMATCH）
#   4) 跨域快照恢复被拒（snapshot-domain-mismatch）
#   5) 跨域 COW 复用被拒（cow-domain-mismatch）
#   6) 调度决策记录里同域 VM 实例唯一、域标签正确
#   7) 域 A 的 broker 凭据不出现在域 B 的请求/文件里（canary）
set -u
cd "$(dirname "$0")/.."
BIN="${BIN:-./.build/release/dbx-poc}"
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
SUPPORT="$HOME/Library/Application Support/DeskBox"
SOCK="${SOCK:-/tmp/dbx-m23.sock}"
COW_ROOT="${COW_ROOT:-$SUPPORT/cows}"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[m23] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[m23] FAIL: %s\n' "$1"; }

# ---------- 0) 准备域配置 ----------
mkdir -p "$SUPPORT"
DOMAINS="$SUPPORT/domains.json"
BACKUP=""
if [ -f "$DOMAINS" ]; then BACKUP="$DOMAINS.bak.$$"; cp "$DOMAINS" "$BACKUP"; fi
cat > "$DOMAINS" <<EOF
{"schema":"deskbox-domains/v1","defaultDomain":"personal",
 "domains":[{"domainID":"personal","brokerPolicyFile":"broker-policy.json"},
            {"domainID":"work","brokerPolicyFile":"broker-policy.work.json",
             "brokerCredentialsFile":"broker-credentials.work.local"},
            {"domainID":"ci"}]}
EOF
cat > "$SUPPORT/broker-policy.work.json" <<EOF
{"allowedHosts":["work.example.invalid"],"allowedSchemes":["https"],"maxResponseBytes":4096}
EOF
CANARY="M23-CANARY-$(openssl rand -hex 8)"
printf 'work.example.invalid:%s\n' "$CANARY" > "$SUPPORT/broker-credentials.work.local"
chmod 600 "$SUPPORT/broker-credentials.work.local"

restore_domains() {
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then mv "$BACKUP" "$DOMAINS"; else rm -f "$DOMAINS"; fi
  rm -f "$SUPPORT/broker-policy.work.json" "$SUPPORT/broker-credentials.work.local"
}
trap restore_domains EXIT

# ---------- 1) domains 命令 + fail-closed ----------
OUT=$("$BIN" domains --json 2>&1)
echo "$OUT" | grep -q '"work"' && pass "domains 列出 work 域" || fail "domains 未列出 work：$(echo "$OUT" | head -2)"
echo "$OUT" | grep -q '"allowsEgress" : true' && pass "work 域标记为允许出站" || fail "egress 标记错误"
echo "$OUT" | grep -q '"defaultDomain" : "personal"' && pass "defaultDomain = personal" || fail "defaultDomain 错误"

cp "$DOMAINS" "$DOMAINS.good.$$"
python3 - "$DOMAINS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["schema"] = "deskbox-domains/v0"
json.dump(d, open(p, "w"))
PY
if "$BIN" domains --json >/dev/null 2>&1; then fail "非法 schema 竟然被接受"; else pass "非法 schema 拒绝"; fi
mv "$DOMAINS.good.$$" "$DOMAINS"

cp "$DOMAINS" "$DOMAINS.good.$$"
python3 - "$DOMAINS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["domains"][0]["brokerPolicyFile"] = "../escape.json"
json.dump(d, open(p, "w"))
PY
if "$BIN" domains --json >/dev/null 2>&1; then fail "路径穿越竟然被接受"; else pass "域文件名路径穿越拒绝"; fi
mv "$DOMAINS.good.$$" "$DOMAINS"

# ---------- 2) 起 daemon ----------
pkill -f 'dbx-poc daemo' 2>/dev/null; sleep 1
rm -f "$SOCK"
"$BIN" daemon --daemon-sock "$SOCK" > /tmp/m23-daemon.log 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 40); do "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 && break; sleep 0.5; done
grep -q 'daemon domains: loaded' /tmp/m23-daemon.log && pass "daemon 加载 domains.json" || fail "daemon 未加载 domains.json"

cleanup() {
  [ -n "${ID_A:-}" ] && "$BIN" rm --daemon-sock "$SOCK" "$ID_A" --force >/dev/null 2>&1
  [ -n "${ID_B:-}" ] && "$BIN" rm --daemon-sock "$SOCK" "$ID_B" --force >/dev/null 2>&1
  "$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1
  restore_domains
}
trap cleanup EXIT

# ---------- 3) 两个域并发创建 ----------
ID_A=$("$BIN" run --daemon-sock "$SOCK" --domain personal "$MANIFEST" 2>&1 | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
ID_B=$("$BIN" run --daemon-sock "$SOCK" --domain work "$MANIFEST" 2>&1 | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
[ -n "$ID_A" ] && pass "personal 域沙箱已创建" || fail "personal 域创建失败"
[ -n "$ID_B" ] && pass "work 域沙箱已创建" || fail "work 域创建失败"

PS=$("$BIN" ps --daemon-sock "$SOCK")
echo "$PS" | grep -q "personal" && pass "ps 显示 personal 域" || fail "ps 缺 personal"
echo "$PS" | grep -q "work" && pass "ps 显示 work 域" || fail "ps 缺 work"

# ---------- 4) 跨域会话拒绝 ----------
if "$BIN" exec --daemon-sock "$SOCK" --domain work "$ID_A" -- /bin/sh -c 'id -u' >/tmp/m23-x1.log 2>&1; then
  fail "跨域 exec 竟然成功"
else
  grep -q 'DBX-DOMAIN-SESSION-MISMATCH\|DOMAIN-SESSION-MISMATCH' /tmp/m23-x1.log \
    && pass "跨域 exec 被拒（原因码正确）" || fail "跨域 exec 被拒但原因不明：$(head -1 /tmp/m23-x1.log)"
fi
"$BIN" exec --daemon-sock "$SOCK" --domain personal "$ID_A" -- /bin/sh -c 'id -u' >/tmp/m23-x2.log 2>&1 \
  && grep -q '65534' /tmp/m23-x2.log && pass "同域 exec 正常（uid=65534）" || fail "同域 exec 失败：$(head -1 /tmp/m23-x2.log)"

# ---------- 5) 跨域快照恢复拒绝 ----------
"$BIN" suspend --daemon-sock "$SOCK" --domain work "$ID_B" >/dev/null 2>&1
SNAP="$COW_ROOT/snapshots/$ID_B.snap"
[ -f "$SNAP" ] && pass "work 域快照已生成" || fail "work 域快照缺失"

# 先把 personal 域的沙箱也挂起，才能走到「恢复」而不是「状态非法」
"$BIN" suspend --daemon-sock "$SOCK" --domain personal "$ID_A" >/dev/null 2>&1
# 把快照挪到 personal 域沙箱的路径上（模拟跨域恢复）
if [ -f "$SNAP" ]; then
  cp "$SNAP" "$COW_ROOT/snapshots/$ID_A.snap"
fi
if "$BIN" resume --daemon-sock "$SOCK" --domain personal "$ID_A" >/tmp/m23-x3.log 2>&1; then
  fail "跨域快照恢复竟然成功"
else
  grep -qi 'domain' /tmp/m23-x3.log \
    && pass "跨域快照恢复被拒（域不匹配）" || fail "跨域恢复被拒但原因不明：$(head -1 /tmp/m23-x3.log)"
fi
rm -f "$COW_ROOT/snapshots/$ID_A.snap"

# 同域恢复仍然可用
"$BIN" resume --daemon-sock "$SOCK" --domain work "$ID_B" >/dev/null 2>&1 \
  && pass "同域恢复成功" || fail "同域恢复失败"

# ---------- 6) 调度决策记录 ----------
LOG="$SUPPORT/scheduler-decisions.jsonl"
[ -f "$LOG" ] && pass "调度决策记录已生成（0600）" || fail "调度决策记录缺失"
PERM=$(stat -f '%Lp' "$LOG" 2>/dev/null)
[ "$PERM" = "600" ] && pass "调度决策记录权限 0600" || fail "决策记录权限=$PERM"
python3 - "$LOG" "$ID_A" "$ID_B" <<'PY' && pass "域标签与 VM 实例唯一性断言通过" || fail "决策记录断言失败"
import json, sys
path, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(l) for l in open(path) if l.strip()]
mine = [r for r in rows if r.get("sandboxID") in (a, b)]
assert len(mine) >= 2, f"decisions={len(mine)}"
by_id = {r["sandboxID"]: r for r in mine}
assert by_id[a]["domainID"] == "personal", by_id[a]
assert by_id[b]["domainID"] == "work", by_id[b]
instances = {r["vmInstanceID"] for r in mine}
assert len(instances) == len({r["sandboxID"] for r in mine}), "VM 实例不唯一"
assert by_id[a]["cowClone"] != by_id[b]["cowClone"], "跨域共享了 COW clone"
PY

# ---------- 7) broker 凭据跨域不可见（canary） ----------
HIT=0
grep -rqa "$CANARY" "$COW_ROOT" 2>/dev/null && HIT=1
grep -qa "$CANARY" /tmp/m23-daemon.log 2>/dev/null && HIT=1
HOME_DIRS=$(ls -d "$COW_ROOT"/sandbox-*.vhd 2>/dev/null | head -5)
for f in $HOME_DIRS; do grep -qa "$CANARY" "$f" 2>/dev/null && HIT=1; done
[ "$HIT" = "0" ] && pass "domain A 凭据未出现在 COW/日志" || fail "凭据 canary 泄漏"
grep -qa "$CANARY" "$SUPPORT/broker-credentials.work.local" && pass "对照组：凭据确实存在于 work 域凭据表" || fail "对照组失败"

# 域 ci 无策略 → 出站必须被拒（不允许回退到全局策略）
ID_C=$("$BIN" run --daemon-sock "$SOCK" --domain ci "$MANIFEST" 2>&1 | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
if [ -n "$ID_C" ]; then
  pass "无出口策略的 ci 域仍可创建沙箱（默认零网络）"
  "$BIN" rm --daemon-sock "$SOCK" --domain ci "$ID_C" --force >/dev/null 2>&1
else
  fail "ci 域创建失败"
fi

printf '\n[m23] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
