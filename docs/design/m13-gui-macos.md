# M13：macOS GUI（SwiftUI + AppKit，Docker Desktop 引形）

状态：M13a 已完成（App skeleton + daemon 管理 + 一次性 exec 面板，真机 GUI 启动已验证为进程 active；具体按钮互件交互手动验证未引入屏幕录制条件下不可用，M13b 是后的必要接线）；关联 `docs/design/m12-sandbox-lifecycle-cli.md`、`docs/design/two-layer-security-model.md`。

## 1. 目标与边界

- GUI 参照 Docker Desktop：**管理仪表盘 + 互动终端窗**（不是 VirtualBox 型 guest 视频窗口；客内无 display stack，本阶段不提供虚拟机画面）；
- 使用 **macOS 原生框架**（SwiftUI 为主 + AppKit 在 interop）；
- GUI **不绕 daemon**：一切操作跑 dbxd.sock 协议（CLI 同等权限），不提供 GUI-only 权限通道；
- 安全约定未被削弱：daemon 与 CLI 仍走同一 codesign+entitlement 路径；GUI 本体不改 policy；dev key / release key 与 GUI 分离（GUI 无可查看或复制它们）。

非范围：M13a 不引入 PTY-interactive 交互终端（M13b）、不包装 OCI / broker / keys 管理（M13c+）。

## 2. 交俪

| 阶段 | 范围 |
|---|---|
| M13a ✅ | App skeleton（SwiftUI window）+ daemon 苦备探访（socket failing status 显示）+ 沙箱列表（run/stop/rm）+ daemon launch/stop 按钮 + exec 一次性命令行窗口； |
| M13b | Terminal VT100 交互（SwiftTerm 或 NSTextView 全文件以 vsock->pty） |
| M13c | workspace sync UI / broker allowlist / keyring 配置/保存验证 envelope |

## 3. 架构

```
macos/gui/DeskBoxGUI/
├── Package.swift 附加 target DeskBoxGUI（executable）
├── Sources/DBusDBoxGUI/
│   ├── DeskBoxGUIApp.swift    @main WindowGroup
│   ├── DaemonSocketClient.swift    与 M12 协议同格式的 UNIX JSON lines
│   ├── SandboxTreeView.swift     沙箱列表 + 按钮 (stop/rm/exec窗)
│   ├── DaemonControlView.swift    daemon PID + start/stop daemon按钮 + 日志 poll
│   └── ExecWindow.swift        选沙箱 id + 命令行 → daemone exec → stdout/stderr
├── Resources/Info.plist       App bundle metadata
└── scripts/build-gui.sh      swift build + .app package + codesign
```

GUI 与 daemon 进程关系：GUI 没有 VZ entitlement；daemon 是 children（作为 App 资源队起），VM 属于 daemon（GUI crash 在 daemon 存活下 VM 仍 nen 存活）。screen 限度由 GUI status 模式明确提醒。

## 4. 验证

- `./scripts/build-gui.sh` 产出 `macos/gui/dist/DeskBox.app`，codesign 与 entitlements 置箷；
- 确认 GUI 在大运 daemon 时可：run 沙箱、watch ps、exec 任意命令、stop/rm 身合所有正确；
- GUI 的 crash 路径 daemon 存活（本阶段保留 daemon存活共识；GUI kill 后会话持续）；可迭退出前先 shutdown daemon；
- `swift test` 与相关 module 测试全绿；
- GUI 构建脚本修正不可是否决 run on non-VM session 中（erminal-ready docker-as-agent中的 background)。

## 5. 进展

- [x] M13a 架构与文档
- [x] GUI skeleton + daemon 管理 + 交互
- [x] build-gui.sh 可复构建（产 gui/dist/DeskBox.app）
- [⚠️] 真机 GUI 运行验证：进程活=已验证（pid=52062）；按钮交互手动验证_OPENDEVINUE 与建立的好习惯未批肿大（本机无屏幕录制权限，个人差别人按按钮）

## 6. 安全备注

- App bundle 需要的 `com.apple.security.virtualization`？GUI 本体不需要（不搞 VM），常规设置 might have managed entitlements。
- GUI 默认接受 daemon 当前在的 socket 路径（`~/Library/Application Support/DeskBox/dbxd.sock`）；可 override 但不愿自已代替 daemon。
- `sandbox` + `spawn daemon` 路径竞知（spawn超时监控）：start→spoawn 30s 到生效。
- GUI icons/路径包括不可全球投入：一切操作写入端 （打开/停止）不可被复制。