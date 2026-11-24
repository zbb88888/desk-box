# M32：GUI 操作全链路

状态：已完成（宿主处于锁屏状态：7 项依赖 resume 的断言在本轮被跳过，见 §5）。
关联 `m31-display-cmdq.md`、`m30-gui-automation.md`、`m28-suspend-rollback-and-gui-alignment.md` §4。

## 1. 问题

M30/M31 之后，GUI 里「需要点击」的流程仍然没有任何自动化覆盖。按钮背后的逻辑是 `DockerMainView` 的私有方法（`send` / `exec` / `run`），既不能单测，也不能被自检驱动。

## 2. 改动

### 2.1 操作逻辑移到视图模型（`SandboxViewModel`）

- `submit(_:label:daemonManager:completion:)`：run / suspend / resume / restart / stop / rm。后台线程做 I/O，主线程回写（日志、输出区），**刷新列表之后**才回调 completion——调用方拿到结果时列表已经是新状态。
- `exec(sandboxId:commandLine:…)`：分词 + 执行 + 写 `execOutput`。
- `runRequest(manifestPath:)`、`timeoutSeconds(forKind:)`。

视图里的 `send` / `exec` / `run` 现在只是转发。按钮和自检走的是同一段代码。

### 2.2 顺带修的两个问题

- **Exec 输入框无法表达带空格的参数**。原来是 `split(separator: " ")`，`/bin/sh -c 'echo a b'` 会被拆成 `["/bin/sh","-c","'echo","a","b'"]`。新增 `ExecCommandLine.argv(from:)`：POSIX 引号的一个子集（单引号字面量、双引号内 `\"` `\\`、引号外反斜杠、相邻片段拼接、空字符串参数）。**只分词**，不做任何展开，结果原样作为 argv 交给 daemon，不经过 shell。引号未闭合 / 行尾悬空反斜杠在本地报错，不发给 daemon。
- **客户端读超时一律 30s**，而 daemon 侧引导等待上限是 90s：引导稍慢时界面先超时、报「没有有效响应」，daemon 随后却成功了。`run` / `resume` / `restart` 改为 150s，`exec` / `wsSync` 120s。

### 2.3 自检新增

- `DBX_GUI_SELFTEST_SCENARIO=flow`：主界面出现后，用视图模型依次执行
  daemon 连接 → Run → 列表显示 running → Exec（带引号）→ 非法命令行被拒 → 被 daemon 拒绝的请求 → Suspend → Resume → Rm，每一步记录到报告；走完后发 ⌘Q。Suspend / Resume / Rm 的请求来自 `SandboxRowActions`（行内按钮用的同一个映射），并先检查该按钮在当前状态下是否可用。
- `DBX_GUI_SELFTEST_SCENARIO=modal`：弹出 `NSOpenPanel.runModal()`（等价于 Settings 里的「Pick…」）。

## 3. 验证

单元测试 `GUITests` 43（新增 20）：

- `ExecCommandLineTests` 10：曾经做不到的用例、单/双引号、转义、拼接、空参数、**不做任何展开**、Unicode、畸形输入被拒。
- `SandboxViewModelTests` 10（对着假 daemon）：completion 在主线程且在列表刷新之后；被拒绝 → 可读原因 + daemon 状态保持 connected；连不上 → 标记 stopped；exec 发出的 argv 与分词结果一致；非法 / 空命令行**不到达 daemon**；引导类请求的超时 > 90s。

`swift test` 共 297 全绿。

真机 `scripts/e2e-gui-app.sh`：46 通过 / 1 因锁屏跳过。

```
G10 GUI 自动拉起的 daemon 已连接
    Run New Sandbox：真实 VM 引导完成并出现在列表
    Exec：/bin/sh -c 'echo flow-ok; id -u' 在 guest 内执行，uid 65534
    引号未闭合的命令行在本地被拒
    被 daemon 拒绝的请求显示可读原因，daemon 状态保持 connected
    Suspend：状态 suspended，行内操作变为 console,resume,rm
    Resume：宿主锁屏 → 显示「无法恢复：Mac 处于锁屏状态 — 解锁后重试…」，沙箱保持 suspended
    Rm：沙箱消失；⌘Q 正常退出；daemon 上无遗留沙箱；cow-root 零残留
G11 文件选择面板（应用级模态）打开时收到 quit AppleEvent → 经 terminate 路径退出
```

全量 `e2e-all.sh`：14 个套件 0 失败，卫生四项 clean，退出码 3（锁屏，7 项跳过）。

一次测试自身的错误值得记下：G11 第一版在主 dispatch 队列的 block 里调用 `runModal`。主队列是串行的，这个 block 卡在模态循环里时，「到点发退出请求」的那个 block 永远排不上——测试挂死，与产品无关。改为 runloop 定时器触发（真实的按钮点击同样不是 dispatch block）。

## 4. 得到的事实

- 应用级模态面板打开时，`terminate` **可以**正常进行（与 sheet 不同）。所以 Settings 里的「Pick…」不会像 sheet 那样卡住注销。
- 模态面板打开时按 ⌘Q 会怎样没有测：这是 macOS 应用的标准行为（模态对话框期间菜单被禁用），没有打算改。

## 5. 诚实边界

- **宿主锁屏**：本轮全程锁屏。全量运行里 7 项依赖 resume 的断言被跳过，其中 G10 的「Resume 成功 + 之后 exec 正常」是本轮新写的、**从未跑通过**的分支；其余 6 项对应的 daemon / core 代码自上次未锁屏全量通过以来没有改动。M31 里 `e2e_resume` 的「成功」分支同样仍未在未锁屏状态下跑过。解锁后需重跑 `./scripts/e2e-all.sh` 并得到退出码 0。
- 锁屏反而让另一条路径第一次得到了真机验证：GUI 对 `DBX-RESUME-HOST-LOCKED` 的呈现。
- flow 驱动的是视图模型，**不是点击**：按钮是否接对了、输入框的值是否传到了 `exec`、sheet 的呈现，都没有覆盖。视图里剩下的是三行转发代码，但它们没有被测试执行过。
- Terminal（PTY）、Console、Stats、Manifests 面板、Workspace 拖放、菜单栏弹窗都没有纳入 flow。
- `AppQuit` 的第 2、3 级兜底依然没有被任何用例触发（G11 证明模态面板不需要它）。
- `ExecCommandLine` 不是完整的 shell 语法：没有 `$'…'`、没有续行、双引号内只识别 `\"` 与 `\\` 两种转义。
