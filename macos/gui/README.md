# Desk Box GUI（M13a）

基于 macOS 原生 SwiftUI 的沙箱管理面板（Docker Desktop 管理面板样式，非 VirtualBox 型 guest 视频窗口）。

## 构建

```bash
cd macos
./scripts/build-gui.sh
# 结果：gui/dist/DeskBox.app
```

## 启动 daemon（GUI 需要 dbx-poc 作为后端）

```bash
# 1) 构建 & 签名 release CLI binary（backend）
swift build -c release --product dbx-poc
codesign --force --sign "$CODESIGN_IDENTITY" --entitlements Resources/DeskBox.entitlements --timestamp .build/release/dbx-poc

# 2) GUI 启动（按面板里的 Start Daemon 按钮会 spawn `dbx-poc daemon`）
open gui/dist/DeskBox.app
```

## M13a 功能

- daemon 状态指示（绿点 = connected，橙 = off）
- daemon start / shutdown 按钮（spawn `dbx-poc daemon`，日志实时上卷）
- 沙箱列表（id / state / bootedAtUtc），并 per-row stop / rm --force / 选择 exec
- On-demand run from manifest path
- 一次性 exec（输入 sandbox-id + 命令行；输出 stdout/stderr 显示于面板下）
- daemon 日志窗（最近 500 行）

安全与运营原则：
- GUI 不绕 daemon；全部操作走 `~/Library/Application Support/DeskBox/dbxd.sock`（chmod 600 JSON lines）
- GUI 本身无 entitlement（不虚拟化，VM 属 daemon）；它们进程上的父子关系对虚拟机域约束保持空余
- 请求二进制路径可配置；**仍需要释放其他 release+sign 的 dbx-poc**
- GUI 二维码签名 key/release key/凭证管理在 M13c 才带发

## 非范围

- M13b（交互 VT terminal + pty stream）
- M13c（workspace D&D / broker allowlist UI / key signing UI）
- 手动验证中局 lineman 运行的 mouse click功能（无屏幕录()));
- MANUAL pen：在 user 速道率中 open GUI 用 btn 按钮点击作用必须手动验证。