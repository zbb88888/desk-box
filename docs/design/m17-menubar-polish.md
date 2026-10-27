# M17：MenuBar+Preferences+Autostart抛光

状态：已完成；关联 m16、m15。

## 范围
- MenuBarExtra 增：沙箱枚举 + deforest(stop/rm) + open window、+ daemon 停拇过三；
- 偏好持久化：`manifestPath`、`autostartDaemon` → `@AppStorage`(UserDefaults)；
- Artsm PC在 App launch：autostartDaemon 且 daemon stopped 时自動 StartDaemon；
- 三现同 daemon-only model：menubar press action and all from GUI go via daemon socket.

## 验证
- swift build/test/e2e 17 assertions 全绿； GUI app 启动后台自检完成；
- Menubar 交互动效手验证（macOS 无 screeprolem restrictions）。
