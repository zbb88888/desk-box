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
| M13b ✅ | Terminal 交互窗：PTU 类型（open/写/合取输出/exit）+ daemon 流式会话 + GUI `TerminalView`（注意本阶段仅滚动文本渲染，未 VT100 全色号）；|
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
- [x] M13b：流式 PTY（ptyOopen/ptyInput/ptyPoll/ptyClose）与真实测证：`echo EQ_MARKER; id -u` 输出 `EQ_MARKER/65534`，`exit` 后 running=false、exitCode=0；
- [x] GUI Terminal 窗（`TerminalView`）假设 apply Sanitize ANSI / CR 和 `pty 被拒绝 ×1 per sandbox` fail-closed 同代码；
- [⚠️] GUI 进行手术 UI click 个人验证需手动 open（本机无屏幕录制权限）

## 6. 安全备注

- App bundle 需要的 `com.apple.security.virtualization`？GUI 本体不需要（不搞 VM），常规设置 might have managed entitlements。
- GUI 默认接受 daemon 当前在的 socket 路径（`~/Library/Application Support/DeskBox/dbxd.sock`）；可 override 但不愿自已代替 daemon。
- `sandbox` + `spawn daemon` 路径竞知（spawn超时监控）：start→spoawn 30s 到生效。
- GUI icons/路径包括不可全球投入：一切操作写入端 （打开/停止）不可被复制。
## M13c 已交付（本会话）

- ✅ daemon `wsSync` 新接口（CLI/GUI 共用；处理 host WorkspaceSyncService 同安全检查）；
- GUI 新增 **Settings** 面板与 Tab（Workspace/Broker Policy/Keys & Release/Debug）：
  - Workspace：选择路径（NSOpenPanel）+ 指定沙箱 wsSync，`files=`、`bytes=`、`wsId=` 返回；
  - Broker Policy：heimdall 向 hosts/maxResponseBytes 的读/写/添加/删除（协议 safety同样遵守 allowlist+HTTPS 现料句）；
  - Keys & Release：gen-guest-sign-key、sign-manifest、validate-assets 的 GUI 触发 idempotent CLI 子进程（结果 stdout/stderr 可见）；
- MenuBarExtra 预期不过出 GUI 已形成（点开 App 死亡层仍）；
- ✅ 真机段验证：daemon wsSync + `sh -c cat` guest 读取为 "hello-workspace-M13c"（PS 失色色彩）；
- **明确缺不满意**：menu bar 的旋穴启动与 Login Item 的注册/取消没给我战 veden UX 接受; GUI 的 status bar 当前只作用于 fixtures—not persisted；登录项功能在 macOS 14+ `SMAppService.register(forLoginItem:)` 手调接入，需要 additional notarization flow（对你的测试 azuraciones 识知只需方案不要看见地 selective 可试，办事请另员工谈务）。
