#!/bin/sh
# 构建 DeskBoxGUI SwiftUI App（M13a）。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product DeskBoxGUI 2>&1 | tail -3

APP_ROOT="$ROOT/gui/dist/DeskBox.app"
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS"
mkdir -p "$APP_ROOT/Contents/Resources"
cp "$ROOT/.build/release/DeskBoxGUI" "$APP_ROOT/Contents/MacOS/DeskBoxGUI"
cp "$ROOT/gui/DeskBoxGUI/Resources/Info.plist" "$APP_ROOT/Contents/Info.plist"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development: 1220582684@qq.com (9LM4RS5GL6)}"
# M14c：GUI 自己也启动 display VM（with virtual machine）——需要同 entitlement。
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT/Resources/DeskBox.entitlements" --timestamp "$APP_ROOT" 2>&1 | tail -1

cat <<EOF

Desk Box GUI packaged at: $APP_ROOT
Launch:  open "$APP_ROOT"

NOTE: 需要 dbx-poc release binary（$ROOT/.build/release/dbx-poc）以管理 daemon。
Build + sign dbx-poc（若未做）:
  cd $ROOT && swift build -c release --product dbx-poc && \
    codesign --force --sign "$CODESIGN_IDENTITY" --entitlements Resources/DeskBox.entitlements --timestamp .build/release/dbx-poc
EOF
