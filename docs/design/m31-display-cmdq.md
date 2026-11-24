# M31：sheet 打开时无法退出、Open Display 崩溃

状态：已完成（本轮结束时宿主再次锁屏，6 项依赖 resume 的断言在最后一次全量运行中被跳过，见 §6）。
关联 `m30-gui-automation.md`、`m28-suspend-rollback-and-gui-alignment.md` §4、`m14c-gui-display.md`。

## 1. 起因

M30 之后还剩一条没验证的 ⌘Q 嫌疑：Display 窗口里的 `VZVirtualMachineView` 把 ⌘Q 吃掉。为了验证它，自检新增了 Display 场景——结果先后撞出了两个真正的 bug，嫌疑本身反而没坐实。

## 2. Bug 一：点「Open Display」必崩

`DisplaySandboxViewModel.start` 在后台队列 `deskbox.gui.displayvm` 上创建 `VZVirtualMachine(configuration:)` 并调用 `start`。这个初始化方法把 VM 绑定到**主队列**，而 Virtualization.framework 要求对 VM 的操作发生在它所属的队列上——`dispatch_assert_queue` 直接 SIGTRAP：

```
EXC_BREAKPOINT  queue: deskbox.gui.displayvm
  _dispatch_assert_queue_fail
  -[VZVirtualMachine _startInternal:saveFileURL:completionHandler:]
  closure #3 in DisplaySandboxViewModel.start(...)
```

这条路径此前只有 M14c 文档里的「手验证」。修复：配置的构建与校验留在后台队列，VM 的创建与 `start` 放到主队列；启动失败时清掉会话私盘。

## 3. Bug 二：任何 sheet 打开时都退不出

崩溃修掉、guest 画面拿到键盘焦点之后，⌘Q 依然无效。逐步排除：

| 假设 | 结果 |
|---|---|
| VM 视图吃掉了 ⌘Q | 否：`window.performKeyEquivalent` 返回 false，事件到了菜单 |
| 自定义的 SwiftUI Quit 按钮在有 sheet 时被禁用 | 否：换回系统默认的 `terminate:` 菜单项，现象不变 |
| Quit 菜单项被禁用 | 否：校验后 `isEnabled == true`，action 确实触发 |
| **`NSApp.terminate(nil)` 本身不生效** | **是**：直接调用也立即返回，`applicationShouldTerminate` 从未被调用 |

结论：**AppKit 在任一窗口挂着 sheet 时拒绝终止，而且是静默的。** 这个 GUI 的 Display / Terminal / Console / Settings 全部以 sheet 呈现，所以只要开着其中任何一个，⌘Q、应用菜单的 Quit、菜单栏图标的 Quit、Dock 的 Quit、注销/关机发来的退出事件全部无效。这比此前任何一条「根因」都更贴合最初的报告。

### 修复（`AppQuit.swift`）

所有退出请求走 `AppQuit.quit()`，三级逐级兜底：

1. 广播 `dismissSheetsRequest`，由视图清掉各 sheet 的呈现状态（SwiftUI 自己收起）。这是唯一能让 AppKit 重新允许终止的方式——实测只在 AppKit 层 `endSheet` 不够：SwiftUI 的绑定仍为 true，`terminate` 照样返回。
2. 1 秒后仍有 sheet：AppKit 层 `endSheet` 强行收起。
3. `terminate` 仍然返回：执行与 `applicationShouldTerminate` 相同的清理后 `exit(0)`。退出不允许静默失败。

接入点：应用菜单 Quit（⌘Q）、菜单栏 Quit、quit AppleEvent（Dock 的 Quit / 注销 / `NSRunningApplication.terminate()`——默认处理同样是 `terminate`，同样会被 sheet 卡住，并且会卡住系统注销）。

## 4. ⌘Q 各条「根因」的最终状态

| 说法 | 提出于 | 状态 |
|---|---|---|
| 有 sheet 时 AppKit 拒绝终止 | M31 | **已证实，主因**。变异（退回直接 `terminate`）→ G7/G8/G9 全部失败，App 一直活着 |
| 主线程同步调 daemon socket | 第一轮 | **已证实**（M30）：卡顿约 2s，⌘Q 被拖延但最终生效 |
| Open Display 崩溃 | M31 | **已证实**（另一个 bug，不是 ⌘Q 的原因） |
| `capturesSystemKeys = true` 把 ⌘Q 转发进 guest | 第一轮 | **未证实**。变异成 `true` 后，「guest 画面聚焦时 ⌘Q 能退出」仍然通过——在合成事件这条路径上它不拦截 ⌘Q。真实键盘事件下是否不同，不知道。保持 `false` |
| Quit 菜单项缺失/没有快捷键 | 第一轮 | **不成立**（M30 已更正） |

## 5. 测试

自检新增：`DBX_GUI_SELFTEST_SCENARIO=display|sheet`（通过通知让主界面打开 Display / Settings，与点击按钮走同一段代码）、`DBX_GUI_SELFTEST_QUIT_VIA=appleevent`（给自己发 quit AppleEvent）。⌘Q 的投递更贴近 AppKit 的真实顺序：先交给目标窗口的 `performKeyEquivalent`（会走视图层级，first responder 有机会消费），没人消费才交给主菜单；报告里区分「被窗口吃掉」与「菜单处理」。退出标记文件记录退出方式（`terminate` / `forced`）。

`scripts/e2e-gui-app.sh` **32/32**：

```
G7 Open Display 不崩溃：display VM running，guest 画面是 first responder，Display sheet 打开
   ⌘Q → 经 terminate 路径退出（rc=0）；退出后会话私盘已清除
G8 Settings sheet 打开时 ⌘Q → 经 terminate 路径退出
G9 sheet 打开时收到 quit AppleEvent → 经 terminate 路径退出
全程没有产生 GUI 崩溃报告（新增断言）
```

修复过程中的一次中间状态值得记下：只做 AppKit 层 `endSheet` 时，App 确实退出了，但走的是第 3 级兜底（`forced`）——断言要求的是正常的 terminate 路径，所以失败，进而发现必须由 SwiftUI 收起 sheet。

harness 改动：

- 套件遇到 resume 不再**预测**（探测锁屏标志），而是**按结果分类**（`e2e_resume`：成功 / `DBX-RESUME-HOST-LOCKED` / 其它失败）。起因是一次真实的边界误报：全量运行中途会话恰好锁屏，锁屏标志已置位但 VZ 仍然恢复成功，「锁屏 ⇒ resume 失败」的三条断言全挂。
- GUI 套件追踪 `$TMPDIR` 下的 display 会话私盘与 `~/Library/Logs/DiagnosticReports` 里的崩溃报告：新增即失败，私盘残留会被删除并标 LEAK。

## 6. 诚实边界

- **本轮最后一次全量运行时宿主处于锁屏状态**：`e2e-all.sh` 0 失败、卫生 clean、退出码 3，6 项依赖 resume 的断言被跳过。本轮没有改动 daemon / core 代码（只改了 GUI 与测试脚本），这 6 项对应的产品代码与上一次未锁屏的全量通过时相同；但 **`e2e_resume` 的「成功」分支是本轮新写的，尚未在未锁屏状态下跑过**。解锁后需重跑一次并得到退出码 0。
- 合成事件不是真实按键：没有经过窗口服务器与 `NSApplication.sendEvent` 的完整分发；`capturesSystemKeys` 若在更底层截获按键，这里测不到。
- 兜底的第 2、3 级（AppKit `endSheet`、`exit(0)`）在最终实现里没有被任何用例触发（第 1 级已经够用）。第 3 级在修复的中间状态被实际走到过一次。
- 只有 `DockerMainView` 响应 `dismissSheetsRequest`。以后在别处新增 sheet 而不响应该通知，会退回到第 2/3 级兜底。
- 文件选择面板（`NSOpenPanel.runModal`，Settings 里的 Pick…）是应用级模态，打开时的退出行为没有测。
- Run / Exec / Suspend / Resume 等需要点击的流程仍未自动化（M32）。
