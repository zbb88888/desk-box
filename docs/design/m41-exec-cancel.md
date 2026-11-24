# M41：取消在途的 exec

状态：宿主侧已完成；guest 侧的实现在补丁版 guest 与正式构建的候选上验证通过。**本机 `macos/guest/` 仍是旧资产，在它上面取消不可用**（会如实报告，见 §5）。
关联 `m39-exec-output.md`（本轮复用它的 poll 循环）、`m26-boot-diagnostics-and-cancel.md`（拆除类操作打断 exec）、`m38-guest-candidate.md`。原编号 M29。

## 1. 问题

一条 exec 发出之后，只有三种结局：自己结束、等到超时、或者把整台沙箱拆掉（`stop` / `rm --force`）。在 `dbx-poc exec` 上按 Ctrl-C 只是让客户端退出，命令留在 guest 里继续跑，并且占着这台沙箱的操作队列——之后的 exec、同步、suspend 都得排在它后面等。GUI 的 Exec 面板同样没有办法停下一条跑飞的命令。

原因在 guest：exec 期间 bootstrap 不读控制通道，宿主说什么它都听不到。

## 2. 设计

**guest（`scripts/guest-bootstrap.c`，`execCancelVersion = 1`）**

- M39 的 poll 循环里加入控制通道。exec 期间读到的帧：
  - `execCancel`（帧类型 27）且 requestID 与在途 exec 相同 → 杀掉进程组，立刻应答（exit -3，`cancelled: true`，带着取消之前的输出）；
  - requestID 不符的 `execCancel` → 迟到的取消，丢弃；
  - 其它帧（终端输入、统计请求……）→ 按到达顺序放进等待队列，exec 结束后由主循环照常处理。此前它们只是留在 socket 缓冲区里，效果相同。
- 控制通道断开（宿主不在了）→ 同样杀掉进程组：没有人等这个结果，不该跑到超时。
- 等待队列上限 128 帧；满了就不再读控制通道（帧留在 socket 里，退回到此前的行为）。重连后清空。
- 顺手修了主循环里的一处越界：收到的帧恰好占满 4096 字节缓冲区时，在 payload 之后补 NUL 会写到缓冲区外一个字节（只有宿主能触发）；并且不再信任头部声明的 payload 长度。

**宿主**

- `VZRuntime.cancelExec`：对在途的 exec 发 `execCancel` 帧。
- daemon 新请求 `execCancel`，**不经过**沙箱的操作队列（那条 exec 正占着它）。`ExecTracker` 记录「正在 guest 上执行的那一条」——排队中的 exec 不算在途，不会被命中。
- **结论按实际结果给出，不预测 guest 是否支持**（`ExecCancelVerdict`）：发出取消后等那一条 exec 结束，最多 3 秒。
  - 结束且 guest 报告被取消 → `exec cancelled`
  - 结束但不是被取消的（取消到达前它自己跑完了）→ `exec already finished`
  - 3 秒后仍在跑 → `DBX-EXEC-CANCEL-UNSUPPORTED`（旧 guest 把这个帧当未知类型忽略）
  - 本来就没有在途的 exec → `DBX-EXEC-NOT-RUNNING`
- CLI：
  - `dbx-poc exec-cancel <sandbox-id>`；
  - `dbx-poc exec` 运行期间按 **Ctrl-C**（或 SIGTERM）：另开连接发取消，然后照常等应答——带回已有输出，以 130 退出。取消不可用时打印原因并立刻以 130 退出（即此前的行为，不会陪着命令等到结束）。再按一次直接退出。
- GUI：Exec 旁边多一个 **Cancel**，只在有命令在途时可用；结果显示在下方。

## 3. 行为变化

- 被取消的 exec 退出码是 253（guest 的 -3）；被自己的 Ctrl-C 取消的是 130。
- `dbx-poc exec` 现在接管 SIGINT / SIGTERM。在旧 guest 上，Ctrl-C 之后客户端要过约 3 秒（确认取消没有生效）才退出，而不是立刻。
- GUI：有命令在途时 Exec 按钮不可用（此前可以连点，后一条排队）。

## 4. 验证

单元测试（`swift test` 402 全绿，新增 11）：`ExecCancelTests` 10（`ExecTracker` 的生命周期 / 迟到的 end / 遗忘 / 并发；四种结论；路由的会话与域检查；CLI；退出码）、`ExecOutputTests` +1（取消保留已有输出、线上格式）。

真机 `scripts/e2e-exec-cancel.sh`（按 guest 是否支持自动分支）：

| | 结果 |
| --- | --- |
| **新 guest**（补丁版夹具 21 项；正式构建的候选 20 项） | |
| `exec-cancel` | 约 60ms 返回 `exec cancelled`；那条 exec 随即返回 exit 253，取消之前的输出还在 |
| 进程真的没了 | 心跳文件不再增长 |
| 排队中的 exec | 取消只命中在途的 A；排队的 B 随后正常执行 |
| Ctrl-C | 客户端约 70ms 后以 130 退出，带回已有输出；guest 里的命令被杀 |
| exec 期间到达的其它帧 | 取消之前送入终端的一行输入，exec 结束后照常生效 |
| 输出不停的命令 | 同样约 60ms 取消，带回 1MiB 已有输出 |
| **旧 guest**（本机现有资产，10 项） | |
| `exec-cancel` | 约 3.1s 后报 `DBX-EXEC-CANCEL-UNSUPPORTED`；那条 exec 不受影响，照常跑完 |
| Ctrl-C | 客户端约 3.1s 后以 130 退出并说明原因 |
| 控制通道 | 旧 guest 不认识的取消帧没有破坏它，之后 exec 正常 |
| 两种 guest | 没有在途 exec 时报 `DBX-EXEC-NOT-RUNNING`；之后 guest 响应正常，无残留 cgroup |

**变异检查**：让 guest 丢弃 exec 期间读到的非取消帧 → 「终端输入没有丢」那一项失败；源码已还原。

GUI（应用内自检，`e2e-gui-app.sh` 新增 2 项）：命令在途时 Cancel 可用、结束后不可用；在候选上走「被取消」分支，在旧 guest 上走「显示可读原因、命令照常跑完」分支，两个分支都实际跑到了。

**候选已重建**（`macos/guest-candidate/`，含 M37 / M39 / M41 的 guest 改动）。全量 `e2e-all.sh` 以它为 guest：23 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

全量 `e2e-all.sh`（本机现有旧 guest）：23 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

## 5. 诚实边界

- **本机 `macos/guest/` 没有换**：你现在用到的沙箱上，取消不可用——`exec-cancel` 和 GUI 的 Cancel 会在约 3 秒后如实报告不支持。要用上它需要安装候选：`./scripts/install-guest-candidate.sh ./guest-candidate`（App bundle 里自带的那份 guest 资产另需重新打包）。
- **客户端被强杀（SIGKILL）或连接意外断开时，daemon 不会替它取消**：命令留在 guest 里跑到结束或超时。只有 Ctrl-C / SIGTERM 这条路会触发取消。GUI 的请求读超时（120s）到点同样不会取消。
- 「不支持」的判定是「3 秒内没有结束」。旧 guest 上这是对的；新 guest 上取消是即时的（实测约 60ms），但如果哪天 guest 卡住超过 3 秒，也会被报告成不支持。
- 取消用的是 SIGKILL，没有先发 SIGTERM 给命令收尾的机会。
- 只能取消在途的那一条，不能取消排队中的。
- 以下路径**没有真机测试**：控制通道断开时杀掉在途命令；等待队列满（128 帧）；`exec already finished`（取消与自然结束的竞争，只有单元测试）；主循环的越界修复。
- Ctrl-C 的测试是给客户端进程发 SIGINT，不是在真实终端里按键。
- GUI 的 Cancel 是通过模型层驱动的（应用内自检），不是真实点击。
- 宿主锁屏：9 项依赖 resume 的断言仍未验证。
