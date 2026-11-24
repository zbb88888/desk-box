# M30：GUI 可自动化验证（隔离启动 / 应用内自检 / 行内操作）

状态：已完成。关联 `m28-suspend-rollback-and-gui-alignment.md` §4、`m25-e2e-isolation.md`、`m13-gui-macos.md`。

## 1. 背景

「⌘Q 无法退出」是第一轮报告的 bug，修复后连续多轮没有任何验证：用 System Events 驱动界面需要辅助功能权限，而且会操作用户的桌面。GUI 也不识别 `DBX_SUPPORT_ROOT`，一启动就连到（或拉起）用户真实目录上的 daemon，没法隔离运行。

## 2. 设计

### 2.1 GUI 识别 `DBX_SUPPORT_ROOT`

GUI 目标依赖 `DeskBoxVZ`，socket 路径与 display console 日志改用 `DeskBoxPaths`——与 daemon/CLI 同一个解析点。GUI 拉起的 daemon 继承同一环境变量，所以两边看到的是同一个 socket。非法值同样 `exit 2`，不回落到真实目录。

### 2.2 应用内自检（`GUISelfTest.swift`）

仅当设置 `DBX_GUI_SELFTEST=<报告路径>` 时启用；不设置时没有任何效果，不接受外部输入、不开端口。

- **主线程卡顿采样**：后台线程每 50ms 往主队列投一个探针，记录「投递 → 执行」的最大延迟。
- **主菜单快照**：递归导出 `NSApp.mainMenu`（标题 / 快捷键 / 修饰键 / action / enabled）。
- **合成 ⌘Q**：`DBX_GUI_SELFTEST_QUIT_AFTER=<秒>` 到点后，把一个 ⌘Q keyDown 事件交给 `NSApp.mainMenu.performKeyEquivalent`——与真实按键在「没有视图截获」时走的是同一条 AppKit 路径（菜单项 → action → `terminate` → `applicationShouldTerminate`）。`applicationShouldTerminate` 里落一个标记文件，证明退出经由 terminate 路径而不是崩溃或被杀。

### 2.3 行内操作按状态启用（`SandboxRowActions.swift`）

此前所有按钮对任何状态都可点，suspend/resume 没有入口。现在：

| 状态 | 操作 |
|---|---|
| running | Terminal / Console / Exec / Suspend / Restart / Stop / Rm |
| suspended | Console / Resume / Rm |
| 其它（过渡态、stopped、failed、未知） | Console / Rm |

Console 与 Rm 对任何状态都保留：Rm 是异常状态的唯一出路。

### 2.4 真 GUI 进程 E2E（`scripts/e2e-gui-app.sh`）

把 GUI 二进制装进临时目录里的 `.app`：独立 bundle id（`com.deskbox.gui.e2e.<pid>`）、`LSUIElement`（后台代理：无 Dock 图标、不抢焦点），直接执行其二进制（不经 LaunchServices 注册）。macOS 按 bundle id 在 `~/Library` 下生成的偏好设置等在退出时清除；`e2e-all.sh` 的卫生审计新增 `~/Library` 一项。

## 3. 验证

```
G1 GUI 自动拉起的 daemon 监听在隔离目录，且确实是该 GUI 进程的子进程；日志也在隔离目录
G2 主菜单有且仅有一个 ⌘Q 项：Desk Box > Quit Desk Box
G3 合成 ⌘Q → 经 applicationShouldTerminate 退出，退出码 0；正常运行时主线程最大卡顿 54ms
G4 GUI 退出后 daemon 继续运行且可达（设计如此），可被 CLI 正常 shutdown
G5 daemon 无响应（连得上、不回话）：主线程最大卡顿 55ms；⌘Q 仍即时退出；GUI 没有删除它的 socket
G6 非法 DBX_SUPPORT_ROOT → GUI exit 2
无残留进程；~/Library 下无该 bundle id 的残留
```

`e2e-gui-app.sh` 20/20。单元测试 `GUITests` 23（新增 8：状态 → 操作映射、Rm/Console 永不缺席、请求的线上名、GUI 与 daemon 同一 socket 路径）。`swift test` 共 277 全绿。全量 `e2e-all.sh`：14 个套件 0 失败，卫生四项 clean，退出码 0。

### 变异检查——以及对第一轮结论的更正

| 变异 | 结果 |
|---|---|
| 探活回到主线程（原始实现） | **被杀**：主线程卡顿 1983ms，⌘Q 退出被拖后约 4s |
| Quit 菜单改回原始写法（`CommandGroup(replacing: .appSettings)`，无快捷键） | **存活**：菜单里仍有且仅有一个 `Quit Desk Box ⌘Q → terminate:` |

第二条说明：**原始代码本来就有一个能用的 ⌘Q 菜单项**（SwiftUI 默认提供）。第一轮我把「Quit 放错菜单槽且没有快捷键」列为根因之三，是错的；那处改动无害，但没有修复任何东西。

三个「根因」的实际状态：

1. 主线程同步调 daemon socket —— **已证实**是真实原因，并由 G5 守住。
2. `VZVirtualMachineView.capturesSystemKeys = true` 把 ⌘Q 转发进 guest —— 合理，但**未验证**（需要 Display 窗口获得键盘焦点，见 §4）。
3. Quit 菜单项缺失 —— **不成立**。

## 4. 没有覆盖的

- **真实键盘事件的分发**。合成事件直接交给主菜单，绕过了窗口/视图的事件链。如果某个获得焦点的视图先吃掉 ⌘Q，这个测试发现不了。
- **Display 窗口聚焦时的 ⌘Q**（上面的根因 2）。需要起 display VM 并让 `VZVirtualMachineView` 成为 first responder。
- **任何需要点击的流程**：Run / Exec / Suspend / Resume 按钮、sheet、菜单栏图标。行内操作只测了「状态 → 可用操作 → 请求」这层逻辑。
- `LSUIElement` 的测试 bundle 与正式 app（非代理）在激活行为上不同；菜单结构相同。
- M28 手测清单里的第 4、5、8、9、10 条仍然只能手测；第 1、2、3、6（退出路径）、7（被拒不显示 daemon 已停，逻辑层）已有自动化或单测覆盖。
- 锁屏期间 suspend 的沙箱解锁后能否 resume：仍未验证。
