# M26：引导失败快速诊断与在途操作取消

状态：已完成（M26a/b）；关联 `m24-daemon-concurrency.md` §5、`m25-e2e-isolation.md`。

## 1. 问题

M24 遗留的两条：

- **引导失败要干等 90s**，且只报 `bootstrap did not reach running within 90s`。典型场景：`--memory-mib 512`。
- **同沙箱的长 exec 会卡住拆除**：VM 操作按沙箱串行，`rm --force` / `stop` / `shutdown` 要等在途 exec 跑完（最长到其 timeout）。

## 2. M26a：引导失败诊断

### 2.1 先看事实（决定了设计）

对本项目的 Alpine guest 实测：

| 场景 | console 输出 |
|---|---|
| 内存 512MiB | **零字节** |
| initrd 被截断 / 换成垃圾 | **零字节** |
| 换用自定义 GPU 内核 + 垃圾 initrd | **零字节** |
| 健康引导 | 首字节约 1.0–1.2s（4 台并行引导时亦然） |

原因：virtio console 驱动在 initramfs 里，initramfs 没解出来就一行都打不出。所以**靠匹配 console 里的 panic 文本诊断不了早期引导失败**——最初的方案在动机场景上是无效的。

内存下限二分：560MiB 不可引导，568MiB 可引导（重复稳定）。最初假设的「tmpfs 上限 50% RAM ⇒ 需要 2×解包尺寸 ≈ 643MiB」被实测否定（576MiB 就能引导），没有采用。

### 2.2 机制（`BootDiagnostics.swift`，纯函数）

`waitForRunning` 在首次引导时按顺序判定：

1. **VM 已 failed/stopped**（VZ 报告）→ 立即失败 `DBX-BOOT-FAILED(vm-<state>)`。
2. **console 出现已知失败特征**（OOM / 根挂载失败 / init 失败 / panic；根因优先于泛化 panic）→ 立即失败 `DBX-BOOT-FAILED(<kind>)`。
3. **静默看门狗**：`DBX_BOOT_SILENCE_SECONDS`（默认 10，范围 2…120）内 console 一个字节都没有 → `DBX-BOOT-FAILED(no-console-output)`。
4. 超时（`DBX_BOOT_TIMEOUT_SECONDS`，默认 90，范围 5…600）→ `DBX-BOOT-TIMEOUT`，附最后几行 console。

**内存估算只是提示，不是闸门**：`kernel + initrd(压缩) + initrd(解包, 读 gzip ISIZE) + 128MiB`，本 guest 得 576MiB（实测下限 568）。只有一个 guest 的数据点，不足以支撑「低于 X 就拒绝」；它只用于在静默失败时把话说清楚：

```
DBX-BOOT-FAILED(no-console-output): guest 在 console 就绪前已停止运行 | 10s 内无任何输出；
内存 512MiB 低于该 guest 的估算下限约 576MiB（initrd 解包后 322MiB），请调大 --memory-mib
```

内存不低于估算、或 initrd 不是单成员 gzip（无法估算）时，消息改为指向 kernel/initrd 损坏或不匹配，不归咎于内存。

### 2.3 安全性

- console 由 guest 控制。它只能让**正在引导的这台沙箱更早失败**（guest 伪造 panic = 拒绝自己的服务），永远不能让引导成功：readiness 仍只认已认证的 bootstrap 握手。
- 进入错误消息前净化：去 ANSI 序列与 C0/C1 控制字符、限长——不让 guest 往宿主终端/日志注入转义序列。
- `resume` 不看 console（缓冲里留着上一段运行期间 guest 自己写的内容），只保留 VM 状态判定。
- 诊断发生在 manifest 校验**之后**：未签名 manifest 仍在引导前被拒。
- 环境变量旋钮越界/非法一律回落默认值。

## 3. M26b：在途操作取消（`OpCancellation.swift`）

每个 `SandboxSession` 一个取消令牌。拆除类操作在排进 `opQueue` **之前**先 `cancel(reason:)`：

- 在途的 guest 操作跑在 `runBlocking` 建的 Swift Task 里；令牌持有该 Task 的取消句柄，取消后 `VZRuntime` 轮询中的 `Task.sleep` 抛 `CancellationError`，操作以 `DBX-OP-CANCELLED: <op> aborted (<reason>)` 返回，opQueue 腾空；
- 已排队未开始的 guest 操作在入口看到标记，直接拒绝；
- 「先 cancel、后登记 Task」的竞争窗由 `register` 在登记时补触发消除。

| 操作 | 行为 |
|---|---|
| `rm --force` | 取消（`sandbox is being removed`） |
| `rm`（非 force） | **不取消**：对 running 沙箱本来就会被拒，不能让一次注定失败的 rm 打断 exec |
| `stop` | 取消（`sandbox is being stopped`），完成后只解除**自己置的**标记（期间被 `rm --force`/shutdown 接管则保留） |
| `shutdown` | 先统一取消所有沙箱，再逐个销毁（`daemon is shutting down`） |
| `suspend` | 不取消，仍等在途操作结束 |
| `resume` 的引导等待 | 可被取消 |

取消只发生在宿主侧：guest 内的进程不单独杀，它随 VM 一起消失。因此**不提供**「取消一次 exec 但保留沙箱」。

## 4. 验证

单元测试（`Tests/DaemonTests`，新增 27）：

- `BootDiagnosticsTests` 17：内核字面消息分类、根因优先、健康引导日志不误报（取自本 guest 真实 console）、净化（ANSI / C0 / C1 / 限长）、静默判定三种措辞、估算与实测校准、gzip ISIZE 的可信性判断、旋钮范围。
- `OpCancellationTests` 10：原因码、幂等、cancel/register 竞争（200 轮）、`reset(ifReason:)` 不抹掉接管者、`runBlocking` 被及时打断（<2s，而不是睡满 30s）。

`swift test` 共 210 个全绿。

真机 e2e `scripts/e2e-boot-and-cancel.sh` **48/48**：

```
512MiB：10.6s 失败（旧 90s），no-console-output，点明「内存 512MiB 低于估算下限 576MiB」
572MiB（低于估算）仍可引导 → 估算不是闸门
垃圾 initrd + 2048MiB：10.5s 失败，不归咎于内存
引导失败后 ps 为空、cow-root 零残留；健康引导首字节 1.0s，无误报
长 exec 在途：rm --force 39ms / stop 36ms / shutdown 42ms（旧行为均 ≈39s）
被取消的 exec：DBX-OP-CANCELLED + 对应原因，且没有产出结果
非 force rm 被拒时 exec 不受影响并正常完成；邻居沙箱 exec 不受影响
在途 + 排队的 exec 一并取消；shutdown 后零残留
DBX_BOOT_TIMEOUT_SECONDS=6 生效
```

**防空跑**：首轮我把 `--timeout` 写在了沙箱 id 之前，CLI 把它当成 id，长 exec 根本没启动——此时「rm 39ms 返回」之类的计时断言照样通过，是输出断言把问题暴露出来的。修正后为每个长 exec 加了「客户端此刻仍在运行」的对照断言。

**变异检查**：去掉三处 `cancel(...)` 调用 → e2e 11 项失败（`rm --force`/`stop`/`shutdown` 各约 39s，`never` 被打印）。

全量回归 `scripts/e2e-all.sh`：12 个套件全绿，卫生审计三项 clean。

## 5. 诚实边界

- **console 特征分类没有真机证据**：在本机现有的 kernel/initrd 组合下，我构造不出「console 已就绪之后才 panic」的引导，所以规则只用内核源码里的字面消息做了单测；`vm-failed/stopped` 快速失败分支同样没有被 e2e 触发过。真正在真机上验证过的是静默看门狗。
- **内存估算只校准过一个 guest**；换 guest（不同压缩算法、内置 initramfs、多成员 gzip）时可能给不出估算（此时如实说「无法估算」），也可能偏差更大。
- 静默阈值 10s 相对实测首字节 ~1s 有约 8 倍余量，但在极端宿主负载下仍可能误判；可用 `DBX_BOOT_SILENCE_SECONDS` 放宽。
- A2（572MiB 可引导）紧贴实测下限 568MiB，4 次运行均通过，但它是对具体镜像敏感的断言：guest 镜像变大后需要重新校准。
- `suspend` 仍会等在途 exec；exec 客户端断开（Ctrl-C）不会取消 guest 内的命令——那需要 guest 侧的 kill 协议。
- ~~CLI `exec` 把 id 之前的 `--timeout` 误当作沙箱 id~~：M27 已修（声明式解析，位置无关）。
