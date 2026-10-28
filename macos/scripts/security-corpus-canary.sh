#!/usr/bin/env bash
# M19 INV-03：canary 凭据扫描 corpus（需要真机 VZ）。
#
# 目标：证明「长期凭据只留在宿主，不进入 sandbox 与日志」。
# 做法：把唯一 canary 值写进宿主凭据文件 → 起沙箱 → 扫 guest 文件系统/进程环境/
#       serial 控制台/宿主 daemon 日志 → 断言零出现（宿主凭据文件本身除外）。
#
# 用法：scripts/security-corpus-canary.sh [--json]
set -u

BIN="${BIN:-./.build/release/dbx-poc}"
SOCK="${SOCK:-/tmp/dbx-corpus-canary.sock}"  # 独立 socket：避免与 GUI 自启 daemon 抢同一路径
MANIFEST="${MANIFEST:-$PWD/guest/manifest.json}"
CRED_FILE="${CRED_FILE:-$PWD/guest/broker-credentials.local}"
DAEMON_LOG="${DAEMON_LOG:-$HOME/Library/Application Support/DeskBox/dbxd-gui.log}"
JSON_MODE=0
[ "${1:-}" = "--json" ] && JSON_MODE=1

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); [ "$JSON_MODE" = "1" ] || printf '[canary] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[canary] FAIL: %s\n' "$1"; }

CANARY="DBXCANARY$(date +%s)$RANDOM"
BACKUP=""
if [ -f "$CRED_FILE" ]; then BACKUP=$(mktemp); cp "$CRED_FILE" "$BACKUP"; fi
cleanup() {
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then cp "$BACKUP" "$CRED_FILE"; rm -f "$BACKUP"; else rm -f "$CRED_FILE"; fi
  [ -n "${ID:-}" ] && "$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1
  [ "${OWN_DAEMON:-0}" = "1" ] && "$BIN" shutdown --daemon-sock "$SOCK" >/dev/null 2>&1
  true
}
trap cleanup EXIT

# 1) 注入 canary 到宿主凭据表
printf '{"api.example.com":"Bearer %s"}\n' "$CANARY" > "$CRED_FILE"
printf '[canary] canary=%s...注入宿主凭据文件\n' "${CANARY:0:18}"

# 2) daemon
OWN_DAEMON=0
if ! "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1; then
  rm -f "$SOCK"
  "$BIN" daemon --daemon-sock "$SOCK" > /tmp/canary-daemon.log 2>&1 &
  OWN_DAEMON=1
  for _ in $(seq 1 40); do
    "$BIN" ps --daemon-sock "$SOCK" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi

# 3) 起沙箱并跑一次会触碰凭据的 workload
OUT=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" 2>&1)
ID=$(printf '%s' "$OUT" | sed -n 's/.*sandboxId=\([A-F0-9-]*\).*/\1/p')
if [ -z "$ID" ]; then
  printf '[canary] FATAL: run failed: %s\n' "$OUT"
  exit 2
fi
printf '[canary] sandbox=%s\n' "$ID"

# 让 guest 尝试读取任何可能存在的凭据（应当什么都找不到）
"$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c \
  'env; cat /proc/self/environ 2>/dev/null | tr "\0" "\n"; echo; echo wsmark > /workspace/canary-probe' \
  > /tmp/canary-guest-env.txt 2>&1 || true

# 4) 扫描面
SCAN_TMP=$(mktemp -d)

# 4a) guest 文件系统（排除伪文件系统）
FS_HITS=$("$BIN" exec --daemon-sock "$SOCK" "$ID" -- /bin/sh -c \
  "grep -rl -a '$CANARY' / --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev 2>/dev/null | head -5" 2>/dev/null | tr -d '\r')
if [ -z "$FS_HITS" ]; then pass "guest 文件系统无 canary"; else fail "guest 文件系统出现 canary: $FS_HITS"; fi

# 4b) guest 进程环境与命令行
ENV_HITS=$(cat /tmp/canary-guest-env.txt 2>/dev/null | grep -c "$CANARY" || true)
if [ "$ENV_HITS" = "0" ]; then pass "guest 进程环境/命令行无 canary"; else fail "guest 环境出现 canary（$ENV_HITS 处）"; fi

# 4c) serial 控制台（daemon consoleLog）
"$BIN" console --daemon-sock "$SOCK" "$ID" > "${SCAN_TMP}/console.txt" 2>/dev/null || true
if grep -qa "$CANARY" "${SCAN_TMP}/console.txt" 2>/dev/null; then
  fail "serial 控制台出现 canary"
else
  pass "serial 控制台无 canary"
fi

# 4d) 宿主 daemon 日志
LOG_TARGETS=("$DAEMON_LOG" /tmp/canary-daemon.log)
HIT_LOG=""
for target in "${LOG_TARGETS[@]}"; do
  [ -f "$target" ] || continue
  if grep -qa "$CANARY" "$target" 2>/dev/null; then HIT_LOG="$target"; fi
done
if [ -z "$HIT_LOG" ]; then pass "宿主 daemon 日志无 canary"; else fail "宿主日志出现 canary: $HIT_LOG"; fi

# 4e) APFS COW 盘（宿主侧沙箱盘内容）
COW_ROOT="${COW_ROOT:-$HOME/Library/Application Support/DeskBox/cows}"
COW_HIT=""
if [ -d "$COW_ROOT" ]; then
  COW_HIT=$(grep -rla "$CANARY" "$COW_ROOT" 2>/dev/null | head -3)
fi
if [ -z "$COW_HIT" ]; then pass "COW 盘无 canary"; else fail "COW 盘出现 canary: $COW_HIT"; fi

# 4f) 正向对照：宿主凭据文件里确实有 canary（否则上面全是假阳性）
if grep -qa "$CANARY" "$CRED_FILE" 2>/dev/null; then
  pass "宿主凭据文件持有 canary（对照组有效）"
else
  fail "宿主凭据文件缺失 canary（扫描无效）"
fi

rm -rf "$SCAN_TMP"

if [ "$JSON_MODE" = "1" ]; then
  printf '{"corpus":"inv-03-canary","canaryPrefix":"%s","sandbox":"%s","pass":%d,"fail":%d}\n' \
    "${CANARY:0:8}" "$ID" "$PASS" "$FAIL"
else
  printf '\n[canary] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
fi
exit "$FAIL"
