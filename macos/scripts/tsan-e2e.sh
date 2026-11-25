#!/usr/bin/env bash
# M48：用 ThreadSanitizer 构建的 dbx-poc 跑真机套件，报告数据竞争。
#
#   ./scripts/tsan-e2e.sh [套件脚本...]        # 缺省跑下面 DEFAULT_SUITES 里的那几套
#
# 做法：`swift build --sanitize=thread` 构建到 .build/tsan（gitignored），签上 virtualization entitlement，
# 用 BIN=… E2E_SKIP_BUILD=1 让各套件改用这个二进制。TSan 的报告写到临时目录，结束时汇总。
#
# 判定只看 TSan 报告：套件自己的 PASS / FAIL 仅供参考——TSan 下慢 5–15 倍，带时间阈值的断言会失败。
# 退出码：0 = 没有任何竞争报告；1 = 有；2 = 构建 / 签名失败。
#
# 只覆盖 dbx-poc（CLI 与 daemon），不含 GUI 进程。发现的是「这次运行走到的路径」上的竞争。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEFAULT_SUITES="e2e-sandbox-lifecycle.sh e2e-daemon-concurrency.sh e2e-boot-and-cancel.sh e2e-lifecycle-persistence.sh e2e-exec-cancel.sh e2e-runtime-race.sh e2e-control-loss.sh"
SUITES="${*:-$DEFAULT_SUITES}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
TSAN_BIN="$ROOT/.build/tsan/debug/dbx-poc"

echo "[tsan] 构建（--sanitize=thread）…"
swift build -c debug --sanitize=thread --product dbx-poc --build-path "$ROOT/.build/tsan" >/dev/null 2>&1 || { echo "[tsan] 构建失败" >&2; exit 2; }
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT/Resources/DeskBox.entitlements" "$TSAN_BIN" >/dev/null 2>&1 \
  || { echo "[tsan] 签名失败" >&2; exit 2; }

LOGS="$(mktemp -d /tmp/dbx-tsan.XXXXXX)"
trap 'rm -rf "$LOGS"' EXIT
TOTAL=0
for suite in $SUITES; do
  name="${suite%.sh}"
  mkdir -p "$LOGS/$name"
  start=$(date +%s)
  # 压力套件缩短时间：TSan 下每个操作都慢得多，目的不是吞吐量。
  BIN="$TSAN_BIN" E2E_SKIP_BUILD=1 RACE_SECONDS="${RACE_SECONDS:-8}" \
    TSAN_OPTIONS="halt_on_error=0 report_signal_unsafe=0 log_path=$LOGS/$name/tsan" \
    "./scripts/$suite" >"$LOGS/$name/suite.out" 2>&1
  rc=$?
  result=$(grep -aoE 'PASS=[0-9]+ FAIL=[0-9]+( SKIP=[0-9]+)?' "$LOGS/$name/suite.out" | tail -1)
  n=$(cat "$LOGS/$name"/tsan.* 2>/dev/null | grep -c 'WARNING: ThreadSanitizer' || true)
  TOTAL=$((TOTAL + n))
  printf '[tsan] %-34s 竞争报告=%-3s （套件自身：%s，exit=%d，%ds）\n' "$name" "$n" "${result:-?}" "$rc" "$(( $(date +%s) - start ))"
  if [ "$n" -gt 0 ]; then
    # 每类报告的「种类 + 最靠上的两帧项目代码」，去重计数。
    cat "$LOGS/$name"/tsan.* | awk '
      /WARNING: ThreadSanitizer/ { kind=$0; sub(/ \(pid=[0-9]+\)/, "", kind); sub(/.*ThreadSanitizer: /, "", kind); frames=0; next }
      /^ +#[0-9]+ / && /\.swift:[0-9]+/ && frames < 2 { f=$0; sub(/^ +#[0-9]+ /, "", f); sub(/ \(dbx-poc.*$/, "", f); line[frames]=f; frames++; if (frames==2) print kind " | " line[0] " | " line[1] }
    ' | sed -E 's/0x[0-9a-f]+//g' | sort | uniq -c | sort -rn | head -12 | sed 's/^/        /'
  fi
done
echo "[tsan] 合计竞争报告：$TOTAL"
[ "$TOTAL" -eq 0 ]
