#!/usr/bin/env bash
# M22：分发面 e2e（打包 / 签名 / DMG / 版本 / 更新检查 / 公证 fail-closed）。
#
# 覆盖本地可验证部分；真机公证（需 Developer ID Application 证书）不在此脚本内，
# 见 scripts/notarize.sh 与 docs/design/m22-distribution-notarization.md §6。
set -u
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.0}"
BIN=./.build/release/dbx-poc
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[dist] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[dist] FAIL: %s\n' "$1"; }

WORK=$(mktemp -d)
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 1) 打包 ----------
echo '[dist] 打包（VERSION='"$VERSION"'）…'
if VERSION="$VERSION" ./scripts/package-app.sh > "$WORK/package.log" 2>&1; then
  pass "package-app.sh 成功"
else
  fail "package-app.sh 失败: $(tail -3 "$WORK/package.log" | tr '\n' ' ')"
  exit 1
fi

APP=gui/dist/DeskBox.app
DMG=$(ls gui/dist/DeskBox-"$VERSION"*.dmg 2>/dev/null | head -1)
[ -d "$APP" ] && pass "DeskBox.app 存在" || fail "DeskBox.app 缺失"
[ -n "$DMG" ] && pass "DMG 存在（$(basename "$DMG")）" || fail "DMG 缺失"

# ---------- 2) 自包含布局 ----------
for f in Contents/MacOS/DeskBoxGUI Contents/MacOS/dbx-poc \
         Contents/Resources/guest/vmlinuz-virt \
         Contents/Resources/guest/initrd-deskbox.img \
         Contents/Resources/guest/root-disk.raw \
         Contents/Resources/guest/manifest.json \
         Contents/Resources/guest/sbom.json; do
  [ -e "$APP/$f" ] && pass "包含 $f" || fail "缺少 $f"
done

# ---------- 3) 版本注入 ----------
GOT_VER=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
[ "$GOT_VER" = "$VERSION" ] && pass "Info.plist 版本 = $VERSION" || fail "Info.plist 版本 = $GOT_VER"
GOT_BUILD=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)
case "$GOT_BUILD" in ''|*[!0-9]*) fail "CFBundleVersion 非数字: $GOT_BUILD";; *) pass "CFBundleVersion = $GOT_BUILD（单调数字）";; esac
HELPER_VER=$("$APP/Contents/MacOS/dbx-poc" version 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)
[ "$HELPER_VER" = "$VERSION" ] && pass "helper 版本一致（$HELPER_VER）" || fail "helper 版本 = $HELPER_VER"

# ---------- 4) 签名 / hardened runtime ----------
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  pass "codesign --verify --deep --strict"
else
  fail "签名校验失败"
fi
DETAIL="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
grep -q 'flags=.*runtime' <<< "$DETAIL" && pass "hardened runtime 已启用" || fail "缺 hardened runtime"

# helper 与 app 必须同一签名 scope（同一 Team/identity）
APP_AUTH=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
HELPER_AUTH=$(codesign -dv --verbose=4 "$APP/Contents/MacOS/dbx-poc" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [ "$APP_AUTH" = "$HELPER_AUTH" ]; then
  pass "helper 与 app 同一签名身份"
else
  fail "签名身份不一致（app=$APP_AUTH helper=$HELPER_AUTH）"
fi

# ---------- 5) DMG 内容一致性 ----------
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
if hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet 2>/dev/null; then
  pass "DMG 可挂载"
  [ -d "$MOUNT/DeskBox.app" ] && pass "DMG 内含 DeskBox.app" || fail "DMG 缺 app"
  [ -L "$MOUNT/Applications" ] && pass "DMG 含 /Applications 链接" || fail "DMG 缺 Applications 链接"
  [ "$(defaults read "$MOUNT/DeskBox.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" = "$VERSION" ] \
    && pass "DMG 内版本 = $VERSION" || fail "DMG 内版本不符"
  for f in vmlinuz-virt initrd-deskbox.img root-disk.raw; do
    a=$(shasum -a 256 "$MOUNT/DeskBox.app/Contents/Resources/guest/$f" | awk '{print $1}')
    b=$(shasum -a 256 "guest/$f" | awk '{print $1}')
    [ "$a" = "$b" ] && pass "DMG 内 $f 校验和一致" || fail "DMG 内 $f 校验和不一致"
  done
  hdiutil detach "$MOUNT" -quiet 2>/dev/null
  MOUNT=""
else
  fail "DMG 挂载失败"
fi

# ---------- 6) SHA256SUMS ----------
[ -f gui/dist/SHA256SUMS ] && pass "SHA256SUMS 已生成" || fail "缺 SHA256SUMS"
if [ -f gui/dist/SHA256SUMS ] && [ -n "$DMG" ]; then
  ( cd gui/dist && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) \
    && pass "SHA256SUMS 校验通过" || fail "SHA256SUMS 校验失败"
fi

# ---------- 7) 公证 fail-closed ----------
./scripts/notarize.sh --preflight > "$WORK/notarize-fail.log" 2>&1
RC=$?
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "$RC" = "0" ] && pass "公证前置检查通过（凭据已提供）" || fail "凭据齐全但 preflight 失败"
else
  [ "$RC" != "0" ] && pass "缺凭据时公证 preflight fail-closed（exit=$RC）" || fail "缺凭据却通过 preflight"
fi
./scripts/notarize.sh --allow-skip --preflight > /dev/null 2>&1
[ "$?" = "0" ] && pass "--allow-skip 显式放行" || fail "--allow-skip 未放行"

REQUIRE_NOTARIZATION=1 ./scripts/package-app.sh > "$WORK/require.log" 2>&1
RC=$?
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  : # 有 Developer ID 时该路径会真正打包，跳过该断言
else
  [ "$RC" != "0" ] && pass "REQUIRE_NOTARIZATION=1 缺证书时拒绝产出（exit=$RC）" \
                    || fail "REQUIRE_NOTARIZATION=1 却产出了 dev 包"
  grep -q 'FATAL' "$WORK/require.log" && pass "拒绝原因明确（FATAL: 未找到 Developer ID）" || fail "拒绝原因不明确"
fi

# ---------- 8) 更新检查（真实 channel：真 key + 真签名 + 真 publish） ----------
CH="$WORK/channel"
mkdir -p "$CH"
cp guest/sbom.json "$CH/"
cp guest/vmlinuz-virt guest/initrd-deskbox.img guest/root-disk.raw "$CH/"
# release key 既用于签 manifest（publish 要求 signature keyID 是 active release key），
# 也构成 channel 的信任根。
"$BIN" gen-release-key --output-key "$CH/release-key.local" >/dev/null 2>&1
SBOM_SHA=$(shasum -a 256 "$CH/sbom.json" | awk '{print $1}')
"$BIN" make-manifest --kernel "$CH/vmlinuz-virt" --initrd "$CH/initrd-deskbox.img" \
  --root-disk "$CH/root-disk.raw" --sbom-digest "$SBOM_SHA" \
  --output "$CH/manifest.unsigned.json" >/dev/null 2>&1
"$BIN" sign-manifest --manifest "$CH/manifest.unsigned.json" --key "$CH/release-key.local" \
  --output "$CH/manifest.json" >/dev/null 2>&1
if "$BIN" publish --channel "$CH" --manifest "$CH/manifest.json" --sbom "$CH/sbom.json" \
     --release-keys "$CH/release-keys.json" --release-tag "v$VERSION" --min-version-floor 1 \
     > "$WORK/publish.log" 2>&1; then
  pass "publish 产出真实 channel.json"
else
  fail "publish 失败: $(tail -2 "$WORK/publish.log" | tr '\n' ' ')"
fi
CHANNEL="$CH/channel.json"

OUT=$("$BIN" check-update --channel "$CHANNEL" --current-version "$VERSION" --json 2>&1)
echo "$OUT" | grep -q 'up-to-date' && pass "同版本 → up-to-date" || fail "同版本判定错误: $(echo "$OUT" | tr '\n' ' ' | cut -c1-160)"

OUT=$("$BIN" check-update --channel "$CHANNEL" --current-version "0.1.0" --json 2>&1)
echo "$OUT" | grep -q 'available' && pass "低版本 → available" || fail "低版本判定错误"

"$BIN" check-update --channel "$CHANNEL" --current-version "9.9.9" --json > "$WORK/rollback.json" 2>&1
RC=$?
[ "$RC" = "3" ] && pass "回滚拒绝退出码 3" || fail "回滚退出码 = $RC"
grep -q 'update-rollback-refused' "$WORK/rollback.json" && pass "回滚拒绝原因码正确" || fail "回滚原因码缺失"

# 篡改 channel → 拒绝
cp "$CHANNEL" "$CH/channel.bak"
python3 - "$CHANNEL" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["manifest"]["manifestDigest"] = "0" * 64
json.dump(d, open(p, "w"))
PY
"$BIN" check-update --channel "$CHANNEL" --current-version "$VERSION" --json > "$WORK/tamper.json" 2>&1
RC=$?
[ "$RC" = "3" ] && pass "篡改 channel 被拒（exit=3）" || fail "篡改 channel 未被拒（exit=$RC）"
grep -qi 'digest' "$WORK/tamper.json" && pass "篡改拒绝原因含 digest 不匹配" || fail "篡改原因不明确"
cp "$CH/channel.bak" "$CHANNEL"

# 撤销全部 key → 拒绝
python3 - "$CHANNEL" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for k in d.get("keys", []):
    k["status"] = "revoked"
json.dump(d, open(p, "w"))
PY
"$BIN" check-update --channel "$CHANNEL" --current-version "$VERSION" --json > "$WORK/revoked.json" 2>&1
RC=$?
[ "$RC" = "3" ] && pass "全 revoked key 被拒" || fail "revoked key 未被拒（exit=$RC）"
grep -q 'no-usable-release-key' "$WORK/revoked.json" && pass "revoked 原因码正确" || fail "revoked 原因码缺失"

# 远程 channel（用 file:// 之外的真实 URL 不做，避免网络依赖）——改为验证「URL 不存在」
"$BIN" check-update --channel "$WORK/no-such.json" --current-version "$VERSION" --json > /dev/null 2>&1
[ "$?" = "3" ] && pass "channel 不存在 → 拒绝（exit=3）" || fail "缺失 channel 未拒绝"

printf '\n[dist] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
