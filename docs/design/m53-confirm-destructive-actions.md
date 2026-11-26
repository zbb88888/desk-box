# M53：不可撤销的操作先确认

状态：已完成。只改了 GUI（没有改 daemon / guest，`BuildRevision.current` 仍是 51）。

## 1. 问题

GUI 里 Rm / Restart / Stop / Shutdown Daemon 都是一点即执行：

- Rm 紧挨着 Stop，是一个强制移除——点错一次，沙箱连同里面的数据就没了；
- Restart 实际是「移除 + 用同样的参数重建」，数据同样不保留，按钮名字看不出来；
- Stop 之后的沙箱不能再启动，只能移除；
- Shutdown Daemon 会结束名下所有沙箱（suspended 的也不能再恢复）。

菜单栏弹窗里同样如此。

## 2. 做法

- `ActionConfirmation`（纯函数）：Rm / Restart / Stop 返回一个提示（标题带沙箱 id 前 8 位，正文说清楚会失去什么，确认按钮写的是要做的事而不是「OK」）；Suspend / Resume / Terminal / Console / Exec 不打断。Shutdown Daemon 只在名下有沙箱时确认。
- `SandboxViewModel.request(_:sandboxId:)` 是行内操作的统一入口：需要确认的只登记到 `pendingConfirmation`，**不发请求**；`confirmPending` 执行登记的那一个并立刻清掉，`cancelPending` 丢弃。
- 主窗口用一个 `.alert` 绑定 `pendingConfirmation`。菜单栏弹窗里点需要确认的操作时，把主窗口带到前面由它弹出确认（弹窗失去焦点就会关闭，放不住对话框）。
- Rm 按钮与其它按钮之间加了一点间距。

## 3. 验证

- 单元测试 `ActionConfirmationTests`（5 条）：哪些操作要确认；提示说了会失去什么；Shutdown 的规则；模型在确认之前不发请求、确认只执行一次。`swift test` 472 全绿。
- 应用内自检（`e2e-gui-app.sh` G10 新增 4 项，共 80）：对一台真实沙箱走 Rm 的入口 → 进入等待确认；等过一轮定时刷新，沙箱状态不变；**主窗口上真的挂着一个对话框**（`attachedSheet`）；取消后沙箱还在；再点一次并确认，沙箱被移除。
- 变异检查（一次跑两个变异体，均被杀死，随后还原）：把 `.alert` 的绑定改成恒 false → 「对话框挂在主窗口上」失败；去掉 M52 的「版本只问一次」守卫 → G13 失败（info 请求 4 次）。这也补上了 M52 文档里欠的那次变异检查。
- 全量 `e2e-all.sh`：见证据文件。

## 4. 诚实边界

- 没有测试「点对话框里的按钮」本身：自检调用的是按钮绑定的 `confirmPending` / `cancelPending`。对话框存在是验证了的，按钮的文字与角色（destructive / cancel）没有。
- 菜单栏弹窗 → 主窗口弹确认这条路没有测试（弹窗本身从未被自动化打开过）。主窗口已关闭时，确认对话框要等主窗口重新出现才看得到。
- 确认对话框显示时按 ⌘Q 没有专门测试（M31 的 sheet 处理是通用的，G5 覆盖的是 Settings sheet）。
- Restart / Stop / Shutdown 的确认只有单元测试与规则核对，没有在真机流程里走一遍。
- CLI 不受影响：`dbx-poc rm` 等仍然直接执行（脚本需要）。
- 过程失误：变异检查后我用 `git checkout` 还原两个文件，把这两个文件里尚未提交的 M53 改动一并还原掉了；随后重新应用并重跑了单元测试与全量 E2E。以后变异检查前先提交或用反向替换还原。
