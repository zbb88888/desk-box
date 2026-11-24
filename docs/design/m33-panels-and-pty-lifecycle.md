# M33：其余面板纳入验证；终端（PTY）生命周期

状态：已完成（宿主全程锁屏：8 项依赖 resume 的断言被跳过，见 §5）。
关联 `m32-gui-operation-flow.md`、`m1-4-pty-support.md`、`m21-resource-stats.md`、`m2-1-workspace-sync.md`。

## 1. 范围

把 Terminal / Console / Stats / Workspace 同步从「视图里的内联逻辑」变成可测试的模型，并纳入 GUI 自检的 flow（真实 daemon + 真实 VM）。过程中发现并修复了下面这些问题。

## 2. 发现并修复的问题

### 2.1 终端只能打开一次（daemon，宿主侧）

**现象**：关掉 Terminal 再打开，`ptyOpen` 等 10 秒后以 `DBX-BOOT-PROOF-MISMATCH: ptyOpen timeout` 失败。之后该沙箱的终端永久不可用。

**原因**：协议里一直有 `ptyClose`（kind 12），guest 也实现了（SIGKILL shell + exit 事件），但**宿主从不发送**。daemon 的 `ptyClose` 只是把会话从自己的表里删掉（注释写着「客端进程不可控制关闭」）；guest 里的 shell 照常运行，而 guest 同一时刻只支持一个 pty。

**修复**（不需要改 guest）：

- `VZRuntime.ptyCloseSession`：发送 `ptyClose`，等待 guest 的 exit 事件（最多 2s），清掉遗留事件；
- `ptyOpenSession` 打开前丢弃上一会话遗留的事件（否则新会话第一次 poll 就读到旧的 exit）；
- daemon `ptyClose` 真正关闭，并返回 `state=closed`（看到 exit）或 `detached`（沙箱已不在）；
- **suspend 之前**先在 guest 里关掉该沙箱的 pty：此前 shell 被一起冻进快照，resume 之后同样占着唯一的槽位；
- **被遗弃的会话**（客户端没关就消失，超过 5s 没有任何 poll / input）不再阻止新的 `ptyOpen`：先在 guest 里关掉它再开新的。否则一次 GUI 崩溃就会让终端永久打不开。还活着的会话仍然互斥。

修到一半时 GUI flow 又抓到一个只在**异步**时序下出现的问题：关闭过程中的「清理遗留事件」循环与紧接着的 `ptyOpen` 并发，把新会话的输出吃掉（最长 2s）。顺序执行的协议测试发现不了它。现在 close 与 open 在同一个串行队列上。

### 2.2 hex 解码越界（GUI）

Console 与 Terminal 各有一份手写解码循环，奇数长度的输入会在 `hex.index(i, offsetBy: 2)` 越界 trap——一条畸形响应就能让 GUI 崩溃。统一为 `HexCoding.decode`，非法输入返回 nil。

### 2.3 终端输出净化（GUI）

原 `sanitize` 的问题：把 `[` 自己当成 CSI 的终止字节（`ESC[0;32m` 会在屏幕上留下 `0;32m`）；按 poll 分块无状态处理，转义序列或多字节字符恰好被切开时漏出乱码；不处理 OSC；退格不生效；输出无上限增长。

新的 `TerminalTextFilter` 是有状态的：CSI / OSC / DCS 等字符串序列 / 两字节转义 / 字符集选择、8-bit C1 形式、跨块的 UTF-8、退格（不跨行）、丢弃其余控制字符、总量上限 20 万字符。它不是终端仿真器（没有光标寻址和颜色），目标是可读的滚动输出，并且不让 guest 控制的字节把界面搞乱。Console 复用同一套规则。

### 2.4 Stats（GUI）

- 切换沙箱不重置 CPU 基线：切换后的第一个 CPU% 是用「另一个沙箱的计数器」算出来的；
- 旧选择的迟到响应会覆盖新选择的数据；
- 采样失败被静默忽略：沙箱没了以后界面永远停在最后一组数字上；
- 计数器回退（guest 重启）时报 0%。

`StatsModel` + `CPUPercentCalculator`：切换即重置、带代号丢弃迟到响应、失败时清掉旧数字并显示可读原因、计数器回退时重新建立基线而不是伪造 0%。选中的沙箱被移除后回到未选择状态。

### 2.5 其它

- Console 加载失败不再静默（此前面板停在「…」）。
- Workspace 同步（Settings 按钮与拖放区）共用 `WorkspaceSync`：本地前置检查（空 id / 不是目录 / 不存在）+ 可读错误。
- PTY 轮询不再叠加：上一次 poll 没回来就不发下一次。

## 3. 验证

单元测试：`GUITests` 70（新增 27：hex、净化器含「在每一个字节位置切开」与伪随机字节流不变量、CPU 计算、StatsModel 含迟到响应、workspace 前置检查、PTY poll 处理）；`DaemonTests` 102（新增 2：遗弃会话不阻止重开、判定阈值）。`swift test` 共 326 全绿。

真机：

```
e2e-gui-buttons（daemon 协议层）18：
  已有活会话时第二个 ptyOpen 被拒
  ptyClose 在 guest 内真正关闭（state=closed）
  关闭后再次打开可用
  关闭与重开并发时新终端的输出不丢
  被遗弃的会话（6s 不 poll）不再阻止新终端，旧会话 id 失效

e2e-gui-app G10（GUI 模型层，53 通过）新增：
  Terminal：打开 → 输入 → 输出 → 关闭 → 再次打开；输出里没有转义/控制字符
  Console：guest serial 可读
  Stats：两次采样后有内存与 CPU%；沙箱不存在时错误可见、旧数字清空
  Workspace：宿主文件出现在 guest 的 /workspace；把文件当目录在本地被拒

e2e-lifecycle-persistence：suspend 时有一个开着的终端 → suspend 成功
e2e-harness-selftest 33：新增 e2e_resume 的结果分类 6 例（用桩替身，不依赖 VM 与锁屏状态）
```

全量 `e2e-all.sh`：14 个套件 0 失败，卫生四项 clean，退出码 3（锁屏，8 项跳过）。

## 4. 关于 harness 的 resume 分类

M31 把「遇到 resume」从预测改成了按结果分类，但「成功」分支一直没法在锁屏状态下跑。本轮用桩替身直接验证了 `e2e_resume` 的全部三种结果与锁屏不变量（含不变量被破坏时计为失败），这部分不再依赖解锁。**各套件在「成功」之后的断言仍然需要真的 resume。**

## 5. 诚实边界

- **宿主全程锁屏**，以下 8 项未验证，解锁后需重跑 `./scripts/e2e-all.sh` 并得到退出码 0：
  - 本轮新增、从未跑通过的：`m20`「恢复后可以打开新终端」——它是 §2.1 中「suspend 前关闭 guest pty」这一修复的**唯一**真机证据；
  - M32 新增、从未跑通过的：GUI flow「Resume 成功 + 之后 exec 正常」；
  - 其余 6 项对应的 resume 代码自上次未锁屏全量通过以来没有改动——但本轮改了 `dispatchSuspend`（先关 pty 再 suspend），「suspend 成功」已验证，「之后能 resume」没有。
- flow 驱动的是模型，不是点击；Terminal 视图的输入框、Console 的自动刷新、Stats 的下拉与折线图、拖放手势都没有被执行。
- 遗弃判定是纯粹基于时间的（5s 无 poll）：一个被 `SIGSTOP` 的客户端恢复后会发现自己的会话已被别人抢占。
- `TerminalTextFilter` 丢弃 `\r`：依赖回车重绘同一行的程序（进度条）会把每次重绘都追加成新内容。
- `ptyClose` 用 SIGKILL：shell 里的前台任务没有机会清理。
- Manifests 面板、菜单栏弹窗未纳入。
