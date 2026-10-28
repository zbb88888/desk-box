#!/usr/bin/env bash
# M19：安全证据 corpus 总入口。
#
#   ./scripts/security-corpus.sh            # 全跑（含需要真机 VZ 的 corpus）
#   ./scripts/security-corpus.sh --host-only # 只跑不需要 VM 的部分（CI 用）
#
# 证据写入 docs/security/evidence/<date>-<commit>.json
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HOST_ONLY=0
[ "${1:-}" = "--host-only" ] && HOST_ONLY=1

COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EVIDENCE_DIR="$ROOT/../docs/security/evidence"
mkdir -p "$EVIDENCE_DIR"
OUT="$EVIDENCE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${COMMIT}.json"

TMPLOG=$(mktemp)
TOTAL_FAIL=0
declare -a RESULTS=()

run_host_corpus() {
  local label="$1"
  printf '[corpus] %s ... ' "$label"
  if swift test --filter SecurityCorpus > "$TMPLOG" 2>&1; then
    local passed
    # 取「Selected tests」汇总行之前最大的那次执行数（=真实断言数）
    passed=$(grep -aoE 'Executed [0-9]+ tests, with 0 failures' "$TMPLOG" | grep -oE '[0-9]+' | sort -n | tail -1)
    printf 'ok (%s assertions)\n' "${passed:-?}"
    RESULTS+=("{\"corpus\":\"$label\",\"kind\":\"host\",\"ok\":true,\"assertions\":${passed:-0}}")
  else
    printf 'FAILED\n'
    grep -aE 'error:|failed' "$TMPLOG" | head -10
    RESULTS+=("{\"corpus\":\"$label\",\"kind\":\"host\",\"ok\":false}")
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
}

run_vm_corpus() {
  local label="$1" script="$2"
  printf '[corpus] %s ... ' "$label"
  local log
  log=$(mktemp)
  if "$ROOT/scripts/$script" > "$log" 2>&1; then
    local summary
    summary=$(grep -aoE 'PASS=[0-9]+ FAIL=0' "$log" | tail -1)
    printf 'ok (%s)\n' "${summary:-pass}"
    RESULTS+=("{\"corpus\":\"$label\",\"kind\":\"vm\",\"ok\":true,\"summary\":\"${summary:-pass}\"}")
  else
    printf 'FAILED\n'
    grep -aE 'FAIL' "$log" | head -10
    RESULTS+=("{\"corpus\":\"$label\",\"kind\":\"vm\",\"ok\":false}")
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
  cp "$log" "/tmp/corpus-${label}.log" 2>/dev/null || true
  rm -f "$log"
}

# --- 宿主侧（CI 可跑）：INV-05 文件系统 / INV-06 OCI / INV-04 策略层
run_host_corpus "inv-05-06-inv-04-host"

# --- 真机 VZ：INV-03 canary / INV-04 guest 网络
if [ "$HOST_ONLY" = "0" ]; then
  run_vm_corpus "inv-03-canary" "security-corpus-canary.sh"
  run_vm_corpus "inv-04-network" "security-corpus-network.sh"
fi

{
  printf '{\n  "generatedAtUtc": "%s",\n  "commit": "%s",\n  "platform": "%s",\n  "hostOnly": %s,\n  "results": [\n' \
    "$STAMP" "$COMMIT" "$(uname -sm)" "$([ "$HOST_ONLY" = "1" ] && echo true || echo false)"
  first=1
  for r in "${RESULTS[@]}"; do
    [ "$first" = "1" ] || printf ',\n'
    printf '    %s' "$r"
    first=0
  done
  printf '\n  ],\n  "fail": %d\n}\n' "$TOTAL_FAIL"
} > "$OUT"

printf '\n[corpus] 证据: %s\n' "$OUT"
printf '[corpus] 结果：FAIL=%d\n' "$TOTAL_FAIL"
rm -f "$TMPLOG"
exit "$TOTAL_FAIL"
