#!/usr/bin/env bash
# M25：真机 e2e 总入口 + 卫生审计。
#
#   ./scripts/e2e-all.sh                 # 全部套件
#   ./scripts/e2e-all.sh m24 m20         # 只跑名字匹配的套件
#   E2E_ALL_LIST=1 ./scripts/e2e-all.sh  # 只列出套件
#   E2E_EVIDENCE_DIR=<目录> ./scripts/e2e-all.sh   # 另外写一份机器可读的证据文件（M36）
#
# 做三件事：
#   1) 构建并签名一次 dbx-poc（各套件 E2E_SKIP_BUILD=1 复用）；
#   2) 逐个跑套件，汇总 PASS/FAIL/耗时；
#   退出码：0 = 全部通过；1 = 有失败或卫生问题；3 = 无失败但因宿主锁屏有断言未验证（不完整）。
#   3) **卫生审计**：运行前后对比
#        - 用户真实状态目录 ~/Library/Application Support/DeskBox（文件清单 + 大小 + mtime）
#        - /tmp 下与本项目相关的条目
#        - ~/Library 下与 deskbox 相关的偏好设置 / 缓存条目（GUI 套件用临时 bundle id）
#        - dbx-poc / GUI 进程集合
#      任何差异都算失败——「测试全绿但留了垃圾 / 动了用户状态」不算通过。
#
# 注意：审计期间如果你同时在用 GUI（用户自己的 daemon 会写日志/建沙箱），会被如实报告为差异。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 每项：名字:脚本:它为哪些安全不变量提供证据（docs/security/threat-model.md 的 INV 编号；可为空）。
SUITES=(
  "selftest:e2e-harness-selftest.sh:"
  "m34-release-cli:e2e-release-cli.sh:INV-09,INV-10"
  "m12-lifecycle:e2e-sandbox-lifecycle.sh:INV-01,INV-08"
  "m24-concurrency:e2e-daemon-concurrency.sh:INV-08,INV-10"
  "m26-boot-cancel:e2e-boot-and-cancel.sh:INV-08"
  "m27-cli-instance:e2e-cli-and-instance.sh:INV-02,INV-08,INV-10"
  "m38-guest-install:e2e-guest-install.sh:INV-09"
  "m35-permissions:e2e-state-permissions.sh:INV-03,INV-10"
  "m37-workspace:e2e-workspace-sync.sh:INV-05,INV-08"
  "m37-workspace-patched:e2e-workspace-sync-patched.sh:INV-05,INV-08"
  "m39-exec-output:e2e-exec-output.sh:INV-08"
  "m39-exec-output-patched:e2e-exec-output-patched.sh:INV-08"
  "m41-exec-cancel:e2e-exec-cancel.sh:INV-08"
  "m41-exec-cancel-patched:e2e-exec-cancel-patched.sh:INV-08"
  "m42-broker-exec:e2e-broker-exec.sh:INV-08"
  "m42-broker-exec-patched:e2e-broker-exec-patched.sh:INV-08"
  "m46-control-loss:e2e-control-loss.sh:INV-08"
  "m46-runtime-race:e2e-runtime-race.sh:INV-08"
  "m51-doctor:e2e-doctor.sh:INV-08"
  "m20-persistence:e2e-lifecycle-persistence.sh:INV-10"
  "m20b-fault-injection:e2e-fault-injection.sh:INV-08,INV-10"
  "m21-stats:e2e-resource-stats.sh:INV-08"
  "m18-kernel:e2e-kernel-hardening.sh:INV-06,INV-08"
  "m23-domains:e2e-credential-domains.sh:INV-02"
  "m17-gui-buttons:e2e-gui-buttons.sh:INV-08"
  "m30-gui-app:e2e-gui-app.sh:"
  "m19-canary:security-corpus-canary.sh:INV-03"
  "m19-network:security-corpus-network.sh:INV-04"
)
if [ "${E2E_ALL_LIST:-0}" = 1 ]; then printf '%s\n' "${SUITES[@]}"; exit 0; fi

AUDIT="$(mktemp -d /tmp/dbx-all.XXXXXX)"
trap 'rm -rf "$AUDIT"' EXIT
# 补丁版 guest（当前源码的 bootstrap）在一次运行里只构建一次，*-patched 套件共用。
export E2E_PATCHED_GUEST_DIR="$AUDIT/patched-guest"
USER_SUPPORT="$HOME/Library/Application Support/DeskBox"
TMP_PATTERN='dbx|deskbox|inject-|m2[0-9]-|stats-daemon|kern-|btn-|canary|corpus'

snapshot() { # snapshot <prefix>
  if [ -d "$USER_SUPPORT" ]; then
    # socket 的 mtime 不稳定且无内容，排除；其余记录 路径|大小|mtime。
    find "$USER_SUPPORT" ! -type s -exec stat -f '%N|%z|%m' {} + 2>/dev/null | sort > "$1.support"
  else
    echo "(absent)" > "$1.support"
  fi
  ls -a /tmp | grep -iE "$TMP_PATTERN" | grep -v "^$(basename "$AUDIT")\$" | sort > "$1.tmp"
  # GUI 套件会以临时 bundle id 运行；macOS 按 bundle id 在 ~/Library 下落的文件也算残留。
  { ls "$HOME/Library/Preferences" 2>/dev/null | grep -i 'deskbox'
    ls "$HOME/Library/Saved Application State" "$HOME/Library/Caches" "$HOME/Library/HTTPStorages" 2>/dev/null | grep -i 'deskbox'
  } | sort > "$1.library"
  pgrep -f 'dbx-poc|DeskBoxGUI' | sort > "$1.procs"
  # M46：被测进程的崩溃报告。套件全绿不代表没有崩溃（daemon 崩在一个「失败也算通过」的断言附近时
  # 不会有任何套件变红）；这里把「运行期间新出现的崩溃报告」直接算作失败。
  ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -E '^(dbx-poc|DeskBoxGUI|DeskBoxE2E)' | sort > "$1.crashes"
}

# ---- 构建 + 签名一次 ----
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
printf '[all] build + sign dbx-poc ...\n'
swift build -c release --product dbx-poc >"$AUDIT/build.log" 2>&1 || { tail -20 "$AUDIT/build.log"; echo '[all] FATAL: build failed'; exit 2; }
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements Resources/DeskBox.entitlements --timestamp .build/release/dbx-poc >/dev/null 2>&1 \
  || { echo '[all] FATAL: codesign failed'; exit 2; }
export E2E_SKIP_BUILD=1
# 套件必须自己建隔离目录；显式清掉可能从外层继承的覆盖，避免全部套件共用一个目录。
unset DBX_SUPPORT_ROOT SOCK COW_ROOT

host_locked() {
  python3 - <<'PY'
import plistlib, subprocess
try:
    d = plistlib.loads(subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True).stdout)
    print("true" if any(u.get("CGSSessionScreenIsLocked") for u in d.get("IOConsoleUsers", []) if u.get("kCGSSessionOnConsoleKey")) else "false")
except Exception:
    print("false")
PY
}
LOCKED_AT_START=$(host_locked)
: > "$AUDIT/suites.tsv"; : > "$AUDIT/hygiene.tsv"

snapshot "$AUDIT/before"

TOTAL_FAIL=0
LOCK_SKIPS=0
ENV_SKIPS=0
SUMMARY=()
for entry in "${SUITES[@]}"; do
  name="${entry%%:*}"; rest="${entry#*:}"; script="${rest%%:*}"; invs="${rest#*:}"
  if [ $# -gt 0 ]; then
    match=0; for want in "$@"; do case "$name" in *"$want"*) match=1;; esac; done
    [ "$match" = 1 ] || continue
  fi
  printf '[all] %-22s ... ' "$name"
  start=$(date +%s)
  "./scripts/$script" >"$AUDIT/$name.out" 2>&1; rc=$?
  secs=$(( $(date +%s) - start ))
  result=$(grep -aoE 'PASS=[0-9]+ FAIL=[0-9]+( SKIP=[0-9]+)?' "$AUDIT/$name.out" | tail -1)
  if [ "$rc" = 0 ]; then
    printf 'ok   %-28s %3ds\n' "${result:-?}" "$secs"
  else
    printf 'FAIL %-28s %3ds (exit=%d)\n' "${result:-?}" "$secs" "$rc"
    grep -aE 'FAIL:|FATAL|LEAK' "$AUDIT/$name.out" | head -12 | sed 's/^/        /'
    # M55：失败的断言逐条写进证据文件——偶发失败事后还能看到是哪一条（此前只留下计数）。
    grep -aE 'FAIL:|FATAL|LEAK' "$AUDIT/$name.out" | head -40 | sed -E 's/^\[[^]]*\] //' | cut -c1-600 > "$AUDIT/$name.failures"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
  n_locked=$(grep -ac 'HOST-LOCKED：' "$AUDIT/$name.out" || true)
  if [ "${n_locked:-0}" -gt 0 ]; then
    LOCK_SKIPS=$((LOCK_SKIPS + n_locked))
    grep -a 'HOST-LOCKED：' "$AUDIT/$name.out" | sed -E 's/ \[HOST-LOCKED.*//; s/^/        未验证 /'
    # 证据文件里逐条记录「没有被验证的断言」。
    grep -a 'HOST-LOCKED：' "$AUDIT/$name.out" | sed -E 's/ \[HOST-LOCKED.*//; s/^\[[^]]*\] SKIP: //' > "$AUDIT/$name.locked"
  fi
  # M44：其余的跳过——标了 NOT-APPLICABLE 的不影响结论；没标的一律按「环境缺失」计入不完整。
  grep -a ' SKIP: ' "$AUDIT/$name.out" | grep -av 'HOST-LOCKED：' | grep -a 'NOT-APPLICABLE：' \
    | sed -E 's/^\[[^]]*\] SKIP: //' > "$AUDIT/$name.na" || true
  grep -a ' SKIP: ' "$AUDIT/$name.out" | grep -av 'HOST-LOCKED：' | grep -av 'NOT-APPLICABLE：' \
    | sed -E 's/^\[[^]]*\] SKIP: //' > "$AUDIT/$name.envskip" || true
  n_env=$(wc -l < "$AUDIT/$name.envskip" | tr -d ' ')
  if [ "${n_env:-0}" -gt 0 ]; then
    ENV_SKIPS=$((ENV_SKIPS + n_env))
    sed 's/^/        未验证（环境） /' "$AUDIT/$name.envskip"
  fi
  num() { printf '%s' "$result" | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$script" "$invs" "$rc" \
    "$(num PASS || true)" "$(num FAIL || true)" "$(num SKIP || true)" "$secs" \
    | awk -F'\t' 'BEGIN{OFS="\t"} {for(i=5;i<=7;i++) if($i=="") $i=0; print}' >> "$AUDIT/suites.tsv"
  SUMMARY+=("$name|$rc|${result:-?}|$secs")
done

sleep 2      # 崩溃报告由系统异步写出，给它一点时间
snapshot "$AUDIT/after"

# ---- 卫生审计 ----
HYGIENE=0
audit() { # audit <kind> <label>
  if diff "$AUDIT/before.$1" "$AUDIT/after.$1" >"$AUDIT/diff.$1" 2>&1; then
    printf '[all] hygiene %-34s clean\n' "$2"
    printf '%s\tclean\n' "$1" >> "$AUDIT/hygiene.tsv"
  else
    printf '%s\tdirty\n' "$1" >> "$AUDIT/hygiene.tsv"
    printf '[all] hygiene %-34s DIRTY\n' "$2"
    sed 's/^/        /' "$AUDIT/diff.$1" | head -20
    HYGIENE=$((HYGIENE+1))
  fi
}
audit support "用户状态目录（Application Support）"
audit tmp     "/tmp 项目相关条目"
audit library "~/Library 下 deskbox 相关条目"
audit procs   "dbx-poc / GUI 进程集合"
audit crashes "被测进程的崩溃报告（~/Library/Logs/DiagnosticReports）"

# ---- 证据文件（M36）----
# 设置 E2E_EVIDENCE_DIR 时，把这次运行写成一份机器可读的证据：commit、宿主版本、每个套件的结果、
# 卫生审计、以及**没有被验证的断言**。按不变量的汇总见 scripts/e2e-evidence.py summarize。
if [ -n "${E2E_EVIDENCE_DIR:-}" ]; then
  COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  DIRTY_N=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  {
    printf 'generatedAtUtc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'commit\t%s\n' "$COMMIT"
    printf 'commitDirty\t%s\n' "$([ "$DIRTY_N" = 0 ] && echo false || echo true)"
    printf 'dirtyFiles\t%s\n' "$DIRTY_N"
    printf 'partial\t%s\n' "$([ $# -gt 0 ] && echo true || echo false)"
    printf 'osVersion\t%s\n' "$(sw_vers -productVersion 2>/dev/null)"
    printf 'osBuild\t%s\n' "$(sw_vers -buildVersion 2>/dev/null)"
    printf 'model\t%s\n' "$(sysctl -n hw.model 2>/dev/null)"
    printf 'arch\t%s\n' "$(uname -m)"
    printf 'lockedAtStart\t%s\n' "$LOCKED_AT_START"
    printf 'lockedAtEnd\t%s\n' "$(host_locked)"
    printf 'binarySha256\t%s\n' "$(shasum -a 256 .build/release/dbx-poc 2>/dev/null | awk '{print $1}')"
    printf 'guestManifestSha256\t%s\n' "$(shasum -a 256 guest/manifest.json 2>/dev/null | awk '{print $1}')"
  } > "$AUDIT/meta.tsv"
  mkdir -p "$E2E_EVIDENCE_DIR"
  EVIDENCE="$E2E_EVIDENCE_DIR/e2e-$STAMP-$COMMIT.json"
  if python3 "$ROOT/scripts/e2e-evidence.py" build "$AUDIT" "$EVIDENCE"; then
    printf '\n[all] 证据：%s\n' "$EVIDENCE"
    python3 "$ROOT/scripts/e2e-evidence.py" summarize "$EVIDENCE" | sed 's/^/[all]   /'
  else
    printf '[all] WARN: 证据文件生成失败\n' >&2
  fi
fi

printf '\n[all] 套件失败=%d 卫生问题=%d 因锁屏未验证=%d 因环境缺失未验证=%d\n' "$TOTAL_FAIL" "$HYGIENE" "$LOCK_SKIPS" "$ENV_SKIPS"
[ "$TOTAL_FAIL" -eq 0 ] && [ "$HYGIENE" -eq 0 ] || exit 1
if [ "$ENV_SKIPS" -gt 0 ]; then
  # M44：缺工具 / 没网络 / 缺资产导致的跳过同样是「没有验证」，不能算一次完整通过。
  printf '[all] INCOMPLETE：%d 项断言因环境缺失（缺工具、没网络、缺资产）未验证，见上面的「未验证（环境）」。\n' "$ENV_SKIPS"
fi
if [ "$LOCK_SKIPS" -gt 0 ]; then
  # 没有失败，但覆盖不完整：宿主锁屏期间 Virtualization.framework 无法恢复 VM 状态，
  # 所有依赖 resume 的断言都被跳过。用独立的退出码 3，避免被当成一次完整通过。
  printf '[all] INCOMPLETE：宿主处于锁屏状态，%d 项依赖 resume 的断言未验证。解锁后重跑以获得完整结果。\n' "$LOCK_SKIPS"
  exit 3
fi
[ "$ENV_SKIPS" -eq 0 ] || exit 3
exit 0
