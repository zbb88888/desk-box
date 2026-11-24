#!/usr/bin/env bash
# M25：真机 e2e 总入口 + 卫生审计。
#
#   ./scripts/e2e-all.sh                 # 全部套件
#   ./scripts/e2e-all.sh m24 m20         # 只跑名字匹配的套件
#   E2E_ALL_LIST=1 ./scripts/e2e-all.sh  # 只列出套件
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

SUITES=(
  "selftest:e2e-harness-selftest.sh"
  "m12-lifecycle:e2e-sandbox-lifecycle.sh"
  "m24-concurrency:e2e-daemon-concurrency.sh"
  "m26-boot-cancel:e2e-boot-and-cancel.sh"
  "m27-cli-instance:e2e-cli-and-instance.sh"
  "m20-persistence:e2e-lifecycle-persistence.sh"
  "m20b-fault-injection:e2e-fault-injection.sh"
  "m21-stats:e2e-resource-stats.sh"
  "m18-kernel:e2e-kernel-hardening.sh"
  "m23-domains:e2e-credential-domains.sh"
  "m17-gui-buttons:e2e-gui-buttons.sh"
  "m30-gui-app:e2e-gui-app.sh"
  "m19-canary:security-corpus-canary.sh"
  "m19-network:security-corpus-network.sh"
)
if [ "${E2E_ALL_LIST:-0}" = 1 ]; then printf '%s\n' "${SUITES[@]}"; exit 0; fi

AUDIT="$(mktemp -d /tmp/dbx-all.XXXXXX)"
trap 'rm -rf "$AUDIT"' EXIT
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

snapshot "$AUDIT/before"

TOTAL_FAIL=0
LOCK_SKIPS=0
SUMMARY=()
for entry in "${SUITES[@]}"; do
  name="${entry%%:*}"; script="${entry#*:}"
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
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
  n_locked=$(grep -ac 'HOST-LOCKED：' "$AUDIT/$name.out" || true)
  if [ "${n_locked:-0}" -gt 0 ]; then
    LOCK_SKIPS=$((LOCK_SKIPS + n_locked))
    grep -a 'HOST-LOCKED：' "$AUDIT/$name.out" | sed -E 's/ \[HOST-LOCKED.*//; s/^/        未验证 /'
  fi
  SUMMARY+=("$name|$rc|${result:-?}|$secs")
done

snapshot "$AUDIT/after"

# ---- 卫生审计 ----
HYGIENE=0
audit() { # audit <kind> <label>
  if diff "$AUDIT/before.$1" "$AUDIT/after.$1" >"$AUDIT/diff.$1" 2>&1; then
    printf '[all] hygiene %-34s clean\n' "$2"
  else
    printf '[all] hygiene %-34s DIRTY\n' "$2"
    sed 's/^/        /' "$AUDIT/diff.$1" | head -20
    HYGIENE=$((HYGIENE+1))
  fi
}
audit support "用户状态目录（Application Support）"
audit tmp     "/tmp 项目相关条目"
audit library "~/Library 下 deskbox 相关条目"
audit procs   "dbx-poc / GUI 进程集合"

printf '\n[all] 套件失败=%d 卫生问题=%d 因锁屏未验证=%d\n' "$TOTAL_FAIL" "$HYGIENE" "$LOCK_SKIPS"
[ "$TOTAL_FAIL" -eq 0 ] && [ "$HYGIENE" -eq 0 ] || exit 1
if [ "$LOCK_SKIPS" -gt 0 ]; then
  # 没有失败，但覆盖不完整：宿主锁屏期间 Virtualization.framework 无法恢复 VM 状态，
  # 所有依赖 resume 的断言都被跳过。用独立的退出码 3，避免被当成一次完整通过。
  printf '[all] INCOMPLETE：宿主处于锁屏状态，%d 项依赖 resume 的断言未验证。解锁后重跑以获得完整结果。\n' "$LOCK_SKIPS"
  exit 3
fi
exit 0
