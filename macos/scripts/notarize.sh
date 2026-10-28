#!/usr/bin/env bash
# M22：公证 + 钉票（notarytool / stapler / spctl）。
#
# 用法：
#   ./scripts/notarize.sh --preflight                  # 只检查前置条件
#   NOTARY_PROFILE=dbx ./scripts/notarize.sh <file>    # 提交公证 + staple + 验证
#   ./scripts/notarize.sh --allow-skip <file>          # 缺凭据时只打印跳过原因（不失败）
#
# fail-closed：缺 Developer ID 签名或 notarytool 凭据时默认退出非零，
# 除非显式 --allow-skip。CI 正式 tag 用 REQUIRE_NOTARIZATION=1 强制执行。
set -euo pipefail

ALLOW_SKIP=0
PREFLIGHT_ONLY=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --allow-skip) ALLOW_SKIP=1 ;;
    --preflight) PREFLIGHT_ONLY=1 ;;
    -*) echo "[notarize] 未知参数: $arg" >&2; exit 2 ;;
    *) TARGET="$arg" ;;
  esac
done

fail_or_skip() {
  local msg="$1"
  if [ "$ALLOW_SKIP" = "1" ]; then
    echo "[notarize] SKIP: $msg"
    exit 0
  fi
  echo "[notarize] FATAL: $msg" >&2
  exit 2
}

# ---- 1) Developer ID 签名身份 ----
DEVID="${DEVELOPER_ID_APPLICATION:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[ -z "$DEVID" ] && fail_or_skip "未找到 Developer ID Application 证书（正式分发必需）"
echo "[notarize] identity: $DEVID"

# ---- 2) notarytool 凭据 ----
PROFILE="${NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  fail_or_skip "未设置 NOTARY_PROFILE（先执行 xcrun notarytool store-credentials <profile>）"
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  fail_or_skip "notarytool 凭据不可用（profile=$PROFILE）"
fi
echo "[notarize] notary profile: $PROFILE"

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  echo "[notarize] preflight OK（签名身份与公证凭据均可用）"
  exit 0
fi

[ -z "$TARGET" ] && { echo "[notarize] 用法: notarize.sh [--preflight|--allow-skip] <app|dmg>" >&2; exit 2; }
[ ! -e "$TARGET" ] && { echo "[notarize] 目标不存在: $TARGET" >&2; exit 2; }

# ---- 3) 提交前校验签名 ----
echo "[notarize] 校验签名：$TARGET"
codesign --verify --deep --strict --verbose=2 "$TARGET" 2>&1 | tail -2
CS_DV="$(codesign -dv --verbose=4 "$TARGET" 2>&1 || true)"
if ! grep -q 'flags=.*runtime' <<< "$CS_DV"; then
  echo "[notarize] FATAL: 缺 hardened runtime，公证必然失败" >&2
  exit 2
fi

# ---- 4) 提交 + 等待 ----
TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT
echo "[notarize] 提交并等待结果（可能需要数分钟）"
xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait --output-format json > "$TMP_JSON"

STATUS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$TMP_JSON" 2>/dev/null || echo "")"
SUBMISSION_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$TMP_JSON" 2>/dev/null || echo "")"
echo "[notarize] submission=$SUBMISSION_ID status=$STATUS"

if [ "$STATUS" != "Accepted" ]; then
  echo "[notarize] 公证失败，拉取日志：" >&2
  [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>&1 | tail -40 >&2
  exit 3
fi

# ---- 5) staple + 验证 ----
echo "[notarize] staple"
xcrun stapler staple "$TARGET" 2>&1 | tail -2
xcrun stapler validate "$TARGET" 2>&1 | tail -1

# ---- 6) Gatekeeper 断言 ----
echo "[notarize] spctl 校验"
case "$TARGET" in
  *.dmg) spctl -a -vvv -t open --context context:primary-signature "$TARGET" 2>&1 | tail -3 ;;
  *)     spctl -a -vvv -t exec "$TARGET" 2>&1 | tail -3 ;;
esac

echo "[notarize] 完成：$TARGET 已公证并钉票"
