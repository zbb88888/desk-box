# M39：exec 的输出——不再卡住、不再静默截断、退出码原样传递

状态：宿主侧已完成；guest 侧的修复在补丁版 guest 与正式构建的候选上验证通过。**本机 `macos/guest/` 仍是旧资产**（见 §6）。
关联 `m38-guest-candidate.md`（候选的安装）、`m26-boot-diagnostics-and-cancel.md`。

## 1. 起因

本轮原打算做 guest 侧的 exec kill（原 M29）。读 guest 的 exec 实现时发现它「等子进程退出 → 再读管道」，于是先在真机上试了几条命令（旧 guest）：

| 命令 | 实际结果 |
| --- | --- |
| `seq 1 600`（2.3KB） | exit 0，但 stdout 只有 **1023 字节**，没有任何提示 |
| `seq 1 40000`（229KB） | 等满超时后失败：`DBX-BOOT-PROOF-MISMATCH: exec response timeout` |
| `sh -c 'exit 5'` | CLI 退出码是 **2**，stderr 多一行 `dbx-poc: exit code 5` |

也就是说 `cat` 一个稍大的文件、`ls -R`、编译输出——日常用法——要么被悄悄截断，要么卡住后报一个与输出毫无关系的错误。这比 exec kill 更该先修，于是本轮改做这个。

## 2. 原因

1. **管道死锁**：guest 在子进程退出之前不读管道。输出超过管道容量（64KB）时子进程卡在 `write` 上，直到超时被杀。
2. **固定 1023 字节**：`EXEC_MAX_OUTPUT = 1024`，超出部分直接丢弃且不标记。整个结果必须放进一个 4096 字节的帧。
3. **两边同时超时**：超时由 guest 执行并应答（exit -2，「exec timed out」），但宿主在同一时刻放弃等待，于是用户看到的是宿主的通道错误而不是 guest 的结论。
4. **退出码**：CLI 把任何非零的 guest 退出码都变成 exit 2（与自身的用法错误相同）。
5. 顺带：转义后的输出放不进一帧时，guest 把越界的长度交给发送，发送失败且不应答（只影响旧宿主 + 新 guest 的单帧模式，一并修了）。

## 3. 修复

**guest（`scripts/guest-bootstrap.c`，exec 输出版本 2）**

- 边等边读：`poll` 两路管道，同时检查子进程与超时。输出再多也不会卡住子进程。
- 请求带 `"streamOutput":true` 时，输出按 512 字节一块通过新的帧类型 `execOutput`（26）流式回传，最终应答里带 `chunked / stdoutBytes / stderrBytes / stdoutTruncated / stderrTruncated / timedOut / streamError`。
- 每一路有上限（请求里的 `maxOutputBytes`，guest 侧硬上限 4MiB）。超出的部分**读掉并丢弃**（不读会卡住子进程），并标记截断。
- 不带该字段的请求（旧宿主）仍得到单帧应答，但死锁同样修掉了，截断也有了标记。
- 经 stats 上报 `execOutputVersion = 2`。

**宿主**

- `VZRuntime.executeCollectingOutput`：请求流式输出，用 `ExecOutputAssembler`（纯逻辑）汇总。宿主不信任 guest 的自我约束：上限由宿主再执行一遍；收到的字节数与 guest 报告的不符、块无法解析、guest 报告发送失败，都标记为「输出不完整」。只接受 requestID 与在途 exec 相同的块。
- 默认上限每路 1MiB。
- 等待应答的时间 = 命令超时 + 5 秒宽限，让 guest 的结论先到。
- **旧 guest 的提示**（宿主改不了 guest 的行为，但可以不再沉默）：某一路输出的长度达到 1023 字节时提示「输出可能被截断」；超时时提示「旧 guest 上输出超过 64KB 会卡住」。
- CLI：提示打到 stderr（`dbx-poc: 注意：…`）；**guest 的退出码原样作为进程退出码**（-2 超时 → 254，-1 未能启动 → 255）。
- GUI 的 Exec 面板：提示显示在输出**之前**（输出很长时放在末尾会被滚出视野）。

## 4. 行为变化（可能影响脚本）

- `dbx-poc exec` 的退出码：此前 guest 命令非零一律是 2；现在是 guest 的退出码。CLI 自身的错误仍是 2。
- stderr 不再有 `dbx-poc: exit code N` 那一行；guest 的 stderr 已经以换行结尾时不再多补一个空行。
- 超时的 exec 现在比以前多等最多 5 秒才会以通道错误失败（正常情况下 guest 会在超时时刻应答，不会用到这段宽限）。

## 5. 验证

单元测试（`swift test` 391 全绿，新增 21）：`ExecOutputTests` 16（按流重组、guest 报告的截断、宿主自己的上限、字节数不符、坏块、超时保留部分输出、无效 UTF-8、旧 guest 的三种提示、线上格式、argv 无法夹带流式标记）、`ExecOutputTextTests` 2、`ExecExitStatusTests` 3。

真机 `scripts/e2e-exec-output.sh`（自动识别 guest 版本）：

| | 旧 guest（本机现有资产）11 项 | 新 guest（补丁版夹具 22 项；正式构建的候选 21 项） |
| --- | --- | --- |
| 小输出、退出码传递、用法错误仍是 2 | 通过 | 通过 |
| 2.3KB | 仍截到 1023 字节，**但有提示** | 完整，逐字节一致 |
| 229KB | 报告为命令超时（exit 254）+ 原因提示，不再是 `DBX-BOOT-PROOF-MISMATCH` | 完整，逐字节一致，约 160ms |
| 1.5MB（超过上限） | — | 正好保留 1048576 字节，提示截断，命令跑完，退出码 3 保留，约 330ms |
| stdout + stderr 同时各 100KB+ | — | 两路都完整 |
| 含 NUL / 非 UTF-8 | — | 请求成功 |
| 超时 3s，之前有输出 | — | 约 2.9s 返回，超时前的两路输出都在，exit 254 |
| 后台子进程拿着管道 | — | 89ms 返回 |
| 之后 guest 响应、无残留 cgroup | 通过 | 通过 |

guest 侧修复的对照就是这张表：同一套脚本，旧 guest 复现、新 guest 不复现。

**候选已重建**：`macos/guest-candidate/` 现在是用本轮源码、正式构建脚本重新构建的（含 M37 与 M39 的 guest 修复）。全量 `e2e-all.sh` 以它为 guest：21 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

全量 `e2e-all.sh`（本机现有旧 guest）：21 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

`e2e-all.sh` 里两个 `*-patched` 套件现在共用一份补丁版 guest（`scripts/lib/patched-guest.sh`，按 bootstrap 源码摘要判断能否复用），不再各构建一次。

## 6. 诚实边界

- **本机 `macos/guest/` 没有换**，所以你日常用到的仍是旧行为：1023 字节截断（现在有提示）、超过 64KB 卡到超时（现在报告为超时并提示原因）。完整的修复要安装候选：`./scripts/install-guest-candidate.sh ./guest-candidate`。
- `gui/dist/DeskBox.app/Contents/Resources/guest/` 里**自带一份 guest 资产**（上一轮说「没有检查」，本轮确认存在）。安装脚本不会更新它；它由 `build-gui.sh` 打包时拷入，而那个脚本会覆盖你正在运行的 bundle，所以没有动。
- 旧 guest 的「可能被截断」是推断：输出恰好 1023 字节而且确实完整时也会提示。
- 输出是**整体返回**的（命令结束后一次交给客户端），不是实时流；上限固定为每路 1MiB，没有做成命令行选项。stdout 与 stderr 之间的先后顺序不保留。
- 新 guest 的**单帧模式**（旧宿主 + 新 guest）以及「应答放不进一帧」的保护没有真机测试——当前宿主总是请求流式输出。`launch` 子命令走的仍是不带流式的 `execute`。
- 「输出不完整」的几条判定（字节数不符、坏块、guest 发送失败）只有单元测试，真机上没有触发过。
- GUI Exec 面板的提示只验证了文本渲染（单元测试）；应用内自检没有新增「大输出」场景。
- **exec kill 仍然没有做**：在途的 exec 只能等它结束、超时，或通过 `rm --force` / `stop` 拆掉整个沙箱。
- 宿主锁屏：9 项依赖 resume 的断言仍未验证。
