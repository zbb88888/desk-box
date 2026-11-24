# M28：suspend 失败回滚与 GUI 对齐

状态：已完成（GUI 部分只验证了不依赖界面的逻辑，界面行为见 §4 手测清单）。
关联 `m27-host-robustness.md`、`m20-lifecycle-persistence.md`、`m13-gui-macos.md`、`m17-menubar-polish.md`。

## 0. M27 遗留项收口

M27 结束时宿主处于锁屏状态，6 项依赖 resume 的断言未验证。本轮中途会话解锁（19:03），随即全量重跑：
`e2e-all.sh` **退出码 0，因锁屏未验证 = 0**。这同时把锁屏假设闭环了：同一份代码，锁屏时 resume 失败、解锁后通过。

仍未回答：**锁屏期间 suspend 的沙箱，解锁后能否 resume**（需要一个跨越「锁屏 → 解锁」的沙箱，本轮没有构造）。

## 1. suspend 失败回滚（`VZRuntime.suspend`）

### 问题

`suspend` 先把状态置为 `suspending`，随后 pause → 保存 VM 状态 → 读回 → 加密落盘。其中任何一步失败都直接上抛：VM 停在 paused、状态停在 `suspending`。此时 exec（要求 running）、resume（要求 suspended）、再次 suspend（要求 running）全部被拒，只剩 `rm`。M27 的变异检查里实际观察到了这个状态。

### 修复

失败后回滚：

1. VM 若已 paused → `resume`；
2. 状态 `suspending → running`，registry 写回 running，留审计（`DBX-LIFECYCLE-SUSPEND-ABORTED`）；
3. 回滚不了（VM 拉不起来 / 没有可用 proof）→ `forceFail`（`DBX-LIFECYCLE-SUSPEND-FAILED`），让用户看到 `failed` 而不是一个假的 `suspending`。

只回滚「仍在 suspending」的情况：已走到 `suspended`（快照已落盘、仅收尾的 registry 写入失败）不回滚——那时再拉起 VM 会让磁盘上的快照与运行态分叉。

保存阶段的临时文件 `defer` 提前到保存之前登记，保存中途失败的半截文件也会删除。

### 状态机契约变更（`DeskBoxCore`）

新增一条边 `suspending → running`。它**不放宽**「进入 running 必须带与当前 boot 绑定的 proof」：回滚复用的是同一 boot、同一会话的已接受 proof；无 proof 或 proof 属于别的 boot 一律被拒。`suspended → running` 仍然非法（已落盘的快照必须经 `resuming`）。新增原因码 `DBX-LIFECYCLE-SUSPEND-ABORTED` / `DBX-LIFECYCLE-SUSPEND-FAILED`。Windows 端若日后恢复，需要同步这条边。

## 2. GUI 与 daemon 对齐

### 2.1 GUI 不再删除 socket 文件

`DaemonProcessManager.refresh()` 每 3s 探活；旧逻辑（M17 hotfix）在「探活失败且 GUI 不持有 daemon 进程」时 `unlink` socket。探活失败不等于 daemon 已死（2s 读超时、daemon 由别处启动且正忙）。删掉活 daemon 的 socket 会让它连同 VM 变成孤儿；M27 起 daemon 有单实例守卫，GUI 随后拉起的新 daemon 还会被拒绝，结果是**一个可达的 daemon 都没有**。真正的 stale socket 由 daemon 启动时探活后自行接管，GUI 不需要、也不应该碰这个文件。`clearStaleSocket` 已删除。

### 2.2 被拒绝 ≠ daemon 已停

旧逻辑把任何请求失败都当作 daemon 停了（`status = .stopped`），于是一次被拒绝的 `run`（比如内存不足）会让界面显示 daemon 已停并触发自动重启逻辑。现在只有连接失败才置 stopped（`DaemonClientError.indicatesDaemonUnreachable`）；被拒绝说明 daemon 活着；超时/响应不完整不下结论，交给周期探活。

### 2.3 原因码呈现（`DaemonErrorPresenter.swift`）

把 `DBX-BOOT-FAILED(…)` / `DBX-BOOT-TIMEOUT` / `DBX-OP-CANCELLED` / `DBX-RESUME-HOST-LOCKED` / `DBX-LIFECYCLE-SUSPEND-*` / `DBX-DAEMON-ALREADY-RUNNING` / `DBX-DOMAIN-SESSION-MISMATCH` 等翻译成标题 + 处置提示 + 严重级别，未知错误原样展示。细节文本可能含 guest 控制的 console 片段，展示前去 ANSI / C0 / C1 控制字符并限长。接入点：exec 输出区、操作日志、列表刷新错误。

### 2.4 可测试性

新增 `Tests/GUITests`（`@testable import DeskBoxGUI`），GUI 模块里不依赖界面的逻辑从此有单测。

## 3. 验证

单元测试（共 269，全绿）：

- `ConformanceTests/SuspendRollbackContractTests` 6：回滚回到 running、仍需 proof、拒绝别的 boot 的 proof、`suspended` 不能直跳 running、不可恢复时经 failed 收敛、原因码稳定。
- `GUITests` 15：原因码映射（文本取自真机输出）、未知码仍可见、净化与限长、「只有连接失败才算 daemon 不在」；`DaemonProcessManager` 对着假 daemon：**正忙的 daemon 的 socket 不被删除**、stale socket 不被触碰、应答的 daemon 显示 connected；客户端把 `ok:false` 解码为 rejected 而非不可达、请求恰好一行 JSON。
- 变异检查：把「探活失败就删 socket」加回去 → 3 个断言失败。

真机 e2e（`e2e-lifecycle-persistence.sh`，26/26，新增 8 项故障注入）：

```
保存失败（快照目录不可写；此时 VM 已被 pause）：
    suspend 以 DBX-LIFECYCLE-SUSPEND-ABORTED 失败 → 状态回到 running → exec 可用且数据仍在 → 快照目录无残留
落盘失败（快照路径被一个目录占住；保存成功、加密落盘失败）：
    同上；占位目录原样保留，无临时文件残留
两次中止之后：正常 suspend / 篡改拒绝 / resume / 二次 suspend-resume / rm 全部通过
```

全量 `e2e-all.sh`：13 个套件 0 失败，卫生审计三项 clean，退出码 0（会话未锁屏，无跳过）。

harness 小改：清理前先 `chmod -R u+rwX`，故障注入用例即便没来得及还原目录权限，临时目录也能删干净。

## 4. GUI 手测清单

> M30 更新：第 1、2、3 条与第 6 条的退出路径已由 `scripts/e2e-gui-app.sh` 自动覆盖（合成 ⌘Q，非真实按键）；第 4、5、8、9、10 条仍需手测。

以下行为**没有自动化验证**，也没有人工验证过——包括最初报告的 Cmd+Q。构建：`cd macos && ./scripts/build-gui.sh`（会覆盖 `gui/dist/DeskBox.app`；若有 daemon 正从该 bundle 运行，先停掉它）。

| # | 步骤 | 期望 |
|---|---|---|
| 1 | 启动 App，主窗口聚焦，按 ⌘Q | App 立即退出 |
| 2 | 应用菜单 | 有「Quit Desk Box  ⌘Q」 |
| 3 | 点 Run New Sandbox 后**立刻**按 ⌘Q（daemon 正在引导 VM） | 立即退出，不转圈 |
| 4 | Open Display，点进 guest 画面使其获得键盘焦点，按 ⌘Q | App 退出（⌘Q 不被转发进 guest） |
| 5 | Open Display 后退出 App；`ls $TMPDIR/deskbox-display-root-*` | 无残留 |
| 6 | 菜单栏图标 → Quit | 退出 |
| 7 | manifest 填一个内存不足的配置或损坏的 manifest，Run | 日志/输出区显示「沙箱引导失败…」而非原始英文；顶部 daemon 状态**仍为 connected** |
| 8 | 对运行中的沙箱 Exec `sleep 30`，期间点 Rm | Rm 立即完成；输出区显示「操作已取消」 |
| 9 | 终端里 `dbx-poc daemon`（不带参数）先起一个 daemon，再开 GUI | GUI 显示 connected 并能操作；该 daemon 的 socket 不消失 |
| 10 | GUI 运行中 `kill -STOP <daemon pid>` 10 秒后 `kill -CONT` | 期间显示 stopped；恢复后回到 connected；socket 文件始终存在 |

## 5. 诚实边界

- GUI 的界面行为（§4 全部 10 条）未验证；单测只覆盖了客户端、进程管理与错误呈现的逻辑层。
- 回滚里「VM resume 失败 → forceFail」分支没有被 e2e 触发过（构造不出 pause 成功而 resume 失败）；pause 自身失败的分支同理。只有契约单测。
- 「落盘成功但收尾 registry 写入失败」时沙箱停在 suspended 且 suspend 报错——调用方看到的是失败，但沙箱实际已挂起。未改。
- ~~GUI 没有 suspend/resume 入口~~：M30 已加（按状态启用）。
- ~~GUI 不识别 `DBX_SUPPORT_ROOT`~~：M30 已支持。
