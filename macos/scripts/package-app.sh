#!/usr/bin/env bash
# M22：组装可分发的 DeskBox.app + DMG。
#
# 用法：
#   ./scripts/package-app.sh                          # 版本取自 git describe
#   VERSION=0.2.0 BUILD=42 ./scripts/package-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: X (TEAM)" REQUIRE_NOTARIZATION=1 ./scripts/package-app.sh
#
# 输出：
#   gui/dist/DeskBox.app
#   gui/dist/DeskBox-<version>[-dev].dmg
#   gui/dist/SHA256SUMS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 版本解析 ----------
TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "${VERSION:-}" ]; then
  :
elif [ -n "$TAG" ]; then
  VERSION="${TAG#v}"
else
  VERSION="0.0.0-dev"
fi
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
GIT_COMMIT="${GIT_COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
GUEST_ASSET_VERSION="${GUEST_ASSET_VERSION:-1}"
mkdir -p gui/dist

echo "[package] version=$VERSION build=$BUILD commit=$GIT_COMMIT"

# ---------- 身份选择（fail-closed，见设计文档 §4.1） ----------
DEVELOPER_ID="${DEVELOPER_ID_APPLICATION:-}"
if [ -z "$DEVELOPER_ID" ]; then
  DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
APPLE_DEV="${APPLE_DEVELOPMENT_IDENTITY:-}"
if [ -z "$APPLE_DEV" ]; then
  APPLE_DEV="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
fi

if [ -n "$DEVELOPER_ID" ]; then
  IDENTITY="$DEVELOPER_ID"; CHANNEL="release"
elif [ -n "$APPLE_DEV" ]; then
  IDENTITY="$APPLE_DEV"; CHANNEL="dev"
else
  IDENTITY="-"; CHANNEL="dev"
fi
SUFFIX=""
[ "$CHANNEL" = "dev" ] && SUFFIX="-dev"

if [ "${REQUIRE_NOTARIZATION:-0}" = "1" ] && [ "$CHANNEL" != "release" ]; then
  echo "[package] FATAL: REQUIRE_NOTARIZATION=1 但未找到 Developer ID Application 证书。" >&2
  echo "[package] 正式发布必须用 Developer ID 签名并公证；拒绝产出 ad-hoc/'Apple Development' 版本。" >&2
  exit 2
fi
echo "[package] identity=$IDENTITY channel=$CHANNEL"

# ---------- 版本信息注入 ----------
cat > Sources/dbx-poc/GeneratedVersion.swift <<EOF
import Foundation

/// M22：构建期注入的版本信息（由 scripts/package-app.sh 生成，勿手工编辑）。
public enum DeskBoxVersion {
    public static let semver: String = "$VERSION"
    public static let build: String = "$BUILD"
    public static let bundleIdentifier: String = "com.deskbox.gui"
    public static let gitCommit: String = "$GIT_COMMIT"
    public static let guestAssetVersion: Int = $GUEST_ASSET_VERSION

    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
EOF

# ---------- 构建 ----------
echo "[package] swift build (release)"
swift build -c release --product DeskBoxGUI 2>&1 | tail -2
swift build -c release --product dbx-poc 2>&1 | tail -2

# ---------- 组装 ----------
APP="$ROOT/gui/dist/DeskBox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/guest"
cp "$ROOT/.build/release/DeskBoxGUI" "$APP/Contents/MacOS/DeskBoxGUI"
cp "$ROOT/.build/release/dbx-poc" "$APP/Contents/MacOS/dbx-poc"

for asset in vmlinuz-virt initrd-deskbox.img root-disk.raw; do
  if [ ! -f "$ROOT/guest/$asset" ]; then
    echo "[package] FATAL: 缺少 guest 资产 $ROOT/guest/$asset（先跑 build-alpine-guest.sh）" >&2
    exit 2
  fi
  cp "$ROOT/guest/$asset" "$APP/Contents/Resources/guest/$asset"
done
for meta in manifest.json sbom.json; do
  [ -f "$ROOT/guest/$meta" ] && cp "$ROOT/guest/$meta" "$APP/Contents/Resources/guest/$meta"
done
# 内置一份 channel.json，让 GUI/CLI 可离线做更新检查（指向自身版本，因而恒为 up-to-date）。
if [ -f "$ROOT/guest/release-keys.json" ]; then
  cp "$ROOT/guest/release-keys.json" "$APP/Contents/Resources/guest/release-keys.json"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.deskbox.gui</string>
    <key>CFBundleName</key><string>DeskBox</string>
    <key>CFBundleDisplayName</key><string>Desk Box</string>
    <key>CFBundleExecutable</key><string>DeskBoxGUI</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Desk Box $VERSION ($GIT_COMMIT)</string>
    <key>DeskBoxGitCommit</key><string>$GIT_COMMIT</string>
    <key>DeskBoxGuestAssetVersion</key><integer>$GUEST_ASSET_VERSION</integer>
    <key>DeskBoxReleaseChannel</key><string>$CHANNEL</string>
</dict>
</plist>
EOF

# ---------- 签名（由内向外：先 helper，再 app；hardened runtime） ----------
ENTITLEMENTS="$ROOT/Resources/DeskBox.entitlements"
SIGN_FLAGS=(--force --options runtime --timestamp --entitlements "$ENTITLEMENTS")
[ "$IDENTITY" = "-" ] && SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS")

echo "[package] codesign + hardened runtime"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/dbx-poc"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# 注意：不能用 `codesign ... | grep -q`——grep 提前退出会让 codesign 吃 SIGPIPE，
# 在 pipefail 下被误判为「没有 hardened runtime」。
CS_DV="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if ! grep -q 'flags=.*runtime' <<< "$CS_DV"; then
  echo "[package] FATAL: 未启用 hardened runtime（公证会直接拒绝）" >&2
  exit 2
fi

# ---------- DMG ----------
DMG_NAME="DeskBox-$VERSION$SUFFIX.dmg"
DMG="$ROOT/gui/dist/$DMG_NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/DeskBox.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<EOF
Desk Box $VERSION (build $BUILD, commit $GIT_COMMIT, channel: $CHANNEL)

安装：把 DeskBox.app 拖到 Applications。
首次启动会要求「虚拟化」权限（com.apple.security.virtualization）。

EOF
if [ "$CHANNEL" = "dev" ]; then
cat >> "$STAGE/README.txt" <<EOF
注意：此构建未使用 Developer ID 签名、未公证（dev 通道）。
在其他机器上首次打开需要「右键 → 打开」，或 xattr -d com.apple.quarantine。
EOF
fi

rm -f "$DMG"
# hdiutil 用「已分配块」估算镜像大小，而 root-disk.raw 是 512MiB 稀疏文件（实际占 9MB）。
# 不显式给 -size 会在拷贝时溢出成 "设备上无剩余空间"。这里按逻辑大小 + 25% 余量。
STAGE_MB=$(python3 - "$STAGE" <<'PY'
import os, sys
total = 0
for root, _dirs, files in os.walk(sys.argv[1]):
    for name in files:
        p = os.path.join(root, name)
        if os.path.islink(p):
            continue
        try:
            total += os.stat(p).st_size
        except OSError:
            pass
print(int(total / (1024 * 1024) * 1.25) + 64)
PY
)
echo "[package] hdiutil size=${STAGE_MB}m（逻辑内容，非稀疏分配）"
hdiutil create -volname "Desk Box $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  -size "${STAGE_MB}m" "$DMG" >/dev/null
if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" 2>&1 | tail -1 || true
fi

# ---------- 校验和 ----------
( cd "$ROOT/gui/dist" && shasum -a 256 "$DMG_NAME" > SHA256SUMS )

cat <<EOF

[package] 完成
  app:  $APP
  dmg:  $DMG ($(du -h "$DMG" | awk '{print $1}'))
  sums: $ROOT/gui/dist/SHA256SUMS
  identity: $IDENTITY
  channel:  $CHANNEL$([ "$CHANNEL" = "dev" ] && echo "（未公证，见 README.txt）")

下一步（需要 Developer ID + notarytool 凭据）：
  NOTARY_PROFILE=dbx ./scripts/notarize.sh "$DMG"
EOF
