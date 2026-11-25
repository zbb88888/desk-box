# M46：控制面丢失的常驻回归；workload 不再继承 bootstrap 的描述符；runtime 状态的数据竞争

状态：宿主侧已完成；guest 侧的修复在补丁版 guest 与正式构建的候选上验证通过。**本机 `macos/guest/` 仍是旧资产**（见 §6）。
关联 `m42-broker-entry-and-client-disconnect.md`、`m43-control-loss-and-broker-result.md`、`m45-failed-sandbox-and-key-overwrite.md`。

## 0. 这一轮是怎么展开的

计划只有一件事：给「guest 控制进程死掉之后宿主的表现」（M43 / M45）补一个常驻的回归测试——此前它只在旧 guest 上（靠一个已经修掉的缺陷触发）和一次性的变异里验证过，候选一旦装上，这些路径就再没有测试了。

写这个测试的过程中，它先后撞出了三个问题，其中两个比原计划重要得多：

1. exec 在途时控制进程退出，宿主过了 **20 秒**才发现 → 原因是 **workload 进程继承了 bootstrap 的全部文件描述符，包括控制通道本身**（§2）；
2. 候选上跑全量回归时 **daemon 崩溃了一次** → 原因是 runtime 的「在队列上执行」**并不在队列上**，沙箱状态被两个线程并行读写（§3）；
3. 几条错误信息答非所问（§4）。

## 1. 带故障注入的测试夹具

`scripts/guest-bootstrap.c` 里用 `#ifdef DBX_TEST_FAULTS` 包了一小段**仅用于测试**的代码：

- `/workspace/.dbx-test-die-idle` 存在 → 主循环下一轮退出（没有请求在途时死亡）；
- `/workspace/.dbx-test-die-exec` 存在 → exec 的等待循环里退出（请求在途时死亡）；
- 经 stats 上报 `"testFaults": true`。

正式构建不定义这个宏，这段代码不存在：重建的候选 initrd 里搜不到那条日志字符串；`e2e-control-loss.sh` 的 N1 用例在正式资产上确认它不上报 `testFaults`、触发文件不起作用。夹具由 `scripts/lib/patched-guest.sh` 的 `faults` 变体构建（`-DDBX_TEST_FAULTS`，有开发密钥时签名——GUI 自检走的是不带 `--allow-unsigned-manifest` 的正常路径），只存在于测试的临时目录里。

## 2. workload 继承了 bootstrap 的文件描述符（guest，真机复现于此前的候选）

exec / pty 的子进程原样继承 bootstrap 打开的一切。bootstrap 启动时 stdin 是关着的，于是 `socket()` 拿到了 0 号——**控制通道就是 workload 的 stdin**：

| 在沙箱里执行 | 结果 |
| --- | --- |
| `wc -c`（任何读 stdin 的命令） | 挂在控制通道上直到 exec 超时；期间到达的宿主帧会被它读走 |
| `echo x >&0` | 垃圾进了控制通道 → 宿主收到坏记录、关闭连接 → **沙箱 failed** |
| `ls -l /proc/self/fd` | `0 -> socket`（控制通道）、`3 -> socket`（broker 监听） |

影响：

- **M42 的结论被推翻了一半**：M42 修掉的是「经 broker 入口杀掉控制面」，而这里是一条更短的路——一行 shell。受影响的仍是它自己的沙箱（INV-08）。
- 记录层是 AEAD 加密的，workload 没有密钥，伪造不了合法的帧，也解不开读到的密文；宿主遇到坏记录是 fail-closed 的。所以这是可用性 / 健壮性问题，不是越权。（`--allow-plaintext` 的明文模式下没有这层保护，workload 可以伪造任意帧；那个模式本来就只用于调试。）
- 这也解释了为什么「控制进程退出」宿主迟迟不知道：连接被还活着的子进程（`sleep 20`）攥着，没有关闭。

修复（`childFdsVersion = 1`）：子进程在加固与 exec 之前关掉 3 号及以上的全部描述符（`close_range`，旧内核回退到循环）；exec 的 stdin 换成 `/dev/null`；控制通道、broker 监听与客户端连接另加 `CLOEXEC` 作为纵深。

## 3. runtime 状态的数据竞争（宿主，实际崩溃）

`VZRuntime.onQueue` 的实现是 `queue.async { Task { operation() } }`。`Task {}` 并不继承 dispatch 队列——操作实际跑在 Swift 并发的全局线程池上，与队列上处理控制通道帧的代码**并行读写同一个 `Record`**。四十多处「在队列上」的状态访问其实都没有互斥。

崩溃报告（全量 E2E 期间，候选）：`EXC_BAD_ACCESS`，栈在 `handleControlFrame` 的 `record.ptyEvents.append`——终端输出帧到达时，另一个线程正在终端轮询里对同一个数组做 filter / removeAll。daemon 一崩，它名下的**所有沙箱一起没了**。

修复：`onQueue` 改为接受同步闭包、直接在队列上执行。只有三处生命周期操作（start / stop / destroy）的闭包内部要 `await`（VZ 的调用自己会回到队列，在队列上等它会死锁），它们改名为 `onQueueAsync` 并保留原来的行为。被调用的辅助函数本来就是「在不在队列上都能用」的写法（`getSpecific` 判断），不会死锁。

压力测试 `scripts/e2e-runtime-race.sh`：两台沙箱的终端不停刷输出，每台 4 个客户端高频轮询，另有 exec 与 stats 并发，20 秒。

| | 结果 |
| --- | --- |
| 修复后 | 3354 次轮询、取回 130MB 终端输出、450 条 exec 逐条正确，daemon 存活，无崩溃报告 |
| 变异（把 `onQueue` 改回 `Task` 版本） | **第 8 次轮询后 daemon 崩溃**，出现崩溃报告；源码已还原 |

也就是说这个崩溃此前在「终端大量输出 + 界面轮询」时很容易触发；之前的 E2E 没撞上只是因为终端用例的输出都很短。

## 4. 答非所问的错误信息

- 沙箱失去控制面之后再 `ws-sync`：报的是 `DBX-WS-RESYNC-UNSAFE`（「guest 资产较旧」）——版本查询失败被当成了旧版本。现在先检查控制面。
- `stats` 的软失败原因是 `The operation couldn’t be completed. (DeskBoxCore.SandboxFailure error 1.)`——GUI 的资源面板显示的就是这句。改为完整的错误描述。

## 5. 验证

单元测试：`swift test` 428 全绿（新增 1：stats 能力字段的解码兼容）。

真机：

| 套件 | 结果 |
| --- | --- |
| `e2e-control-loss.sh`（新，故障夹具，25 项） | 正式资产没有故障开关；空闲死亡后 26ms `ps` 显示 failed 并带原因；exec / stats / ws-sync / 开终端立刻报 `DBX-GUEST-CONTROL-LOST`；`restart` 重建出全新的可用沙箱；**exec 在途时死亡：130ms 内失败**（修 §2 之前是 20 秒）；之后的请求立刻失败、之前排队的照常完成；终端会话中死亡：轮询在它死掉的那一刻报错；failed 的沙箱都能 rm |
| `e2e-exec-output.sh` 新增 H1–H4（新 guest） | exec 与终端里的进程都没有继承任何 socket；stdin 是 `/dev/null`；`wc -c` 134ms 读到 EOF；`echo x >&0` 之后沙箱仍是 running。旧 guest 上复现缺陷，只作为已知缺陷打印 |
| `e2e-gui-app.sh` 新增 G12（故障夹具，9 项） | 界面上：行靠定时刷新变成 failed 并带原因；只剩 Console / Restart / Rm；对它 Exec 显示「沙箱失去响应」；Restart 重建出新沙箱并可 Exec。**这补上了 M45 留下的「GUI 的 failed 流程只有单元测试」** |
| `e2e-runtime-race.sh`（新，6 项） | 见 §3 |
| 全量 `e2e-all.sh`（本机现有旧 guest，**屏幕已解锁**） | **27 个套件 0 失败，卫生五项 clean，退出码 0：整体结论「完整通过，可作为发布证据」**——没有任何因锁屏或环境缺失而跳过的断言。这是这个结论第一次出现 |
| 全量 `e2e-all.sh`（重建后的候选，屏幕已解锁） | 27 个套件 0 失败，卫生五项 clean，退出码 0 |

### 5.1 resume 终于验证了

本轮进行到一半时宿主的屏幕解锁了。此前九轮一直无法验证的 9 项依赖 resume 的断言全部跑到并通过，在旧 guest 和候选上各一遍——包括三条从写出来起就没跑通过的分支（GUI 流程里的「Resume 成功 + 之后 Exec」、「恢复后可以打开新终端」、「resume 后数据仍在 / 没有遗留的解密临时文件」）。

这同时检验了此前四处「未经 resume 验证」的改动：

| 改动 | 落在哪 | 结果 |
| --- | --- | --- |
| M42：guest bootstrap 忽略 SIGPIPE | guest（候选） | 候选上 suspend / resume 各用例通过 |
| M43：控制连接断开是否「意外」的判定 | 宿主 | resume 更换控制连接时没有被误判 |
| M45：意外断开时立刻标为 failed | 宿主 | resume 之后沙箱是 running，不是 failed |
| M46：同步操作真正在队列上执行 | 宿主 | resume 路径上的状态更新没有死锁 |

解锁还暴露了一个只在「有人使用的会话」里出现的测试问题：GUI 自检里用来构造「应用级模态」场景的文件选择面板，在后台应用里弹出约 2 秒后会被系统自行取消（锁屏时不会），到点发退出请求时模态会话已经没了，用例判为「场景无效」。现在面板自行返回后改用一个进程内的模态窗口，报告里记下用的是哪一种。

测试基建的两处改动：

- **卫生审计多了一项「崩溃报告」**：运行期间 `~/Library/Logs/DiagnosticReports` 里新出现 `dbx-poc*` / `DeskBoxGUI*` 即算失败。此前 daemon 崩在一个宽容的断言附近时，没有任何套件会变红。
- **夹具用的 libsodium 编译结果缓存在 `macos/.build/patched-guest-cache/`**（896K，gitignored 的构建目录）。此前每建一次夹具都重新下载编译，一次全量 E2E 下载好几遍，站点一抖动整套就被跳过（本轮就遇到了）。现在只有第一次需要网络，夹具构建从约 25 秒降到 4 秒。

## 6. 诚实边界

- **本机 `macos/guest/` 与 `gui/dist/DeskBox.app` 里自带的那份都没有换**：§2 的缺陷在它们上面仍然存在（沙箱里一行 `echo x >&0` 就能让这台沙箱 failed）。候选已按本轮源码重建。
- §3 的修复改变了四十多处状态访问的执行位置。全量回归（含 resume，见 §5.1）在两种 guest 上通过，没有出现死锁；但「没有死锁」是由这些用例走到的路径证明的，不是穷举。
- start / stop / destroy 三处仍然不在队列上执行，它们与帧处理之间的竞争没有消除（只在生命周期转换时发生，窗口很小）。彻底的做法是把 runtime 改成 actor 或给 Record 加锁，没有做。
- 压力测试证明的是「这个场景不再崩」，不是「没有别的竞争」。没有用 ThreadSanitizer 跑过（VZ 的 entitlement 与 TSan 构建的组合没有尝试）。
- 故障注入代码虽然只在定义了宏时存在，但它在正式的源码文件里。防线是：正式构建脚本不传这个宏；N1 用例在被测资产上做行为与上报两项否定检查。
- 用开发密钥签过名的故障夹具只存在于测试的临时目录，测试结束即删除；它能造成的最坏结果是「沙箱里的程序让自己的沙箱 failed」。
- 明文模式（`--allow-plaintext`）下 §2 的影响没有评估到底；该模式不用于正式场景。
- 崩溃报告的检查依赖系统异步写出报告（等 2 秒）；写得更慢的话会漏到下一次运行才被发现。
- GUI 的「应用级模态」用例在有人使用的会话里验证的是进程内模态窗口，不是系统的文件选择面板（后者在后台应用里会被系统自行取消，无法稳定构造）。
- 「完整通过」的证据对应的是本机现有的旧 guest；候选的那一遍没有单独的证据文件。
