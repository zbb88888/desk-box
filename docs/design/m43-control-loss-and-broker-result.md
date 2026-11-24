# M43：guest 控制面死亡的即时发现；`brokerreq` 返回真实结果

状态：宿主侧已完成；guest 侧的改动在补丁版 guest 与正式构建的候选上验证通过。**本机 `macos/guest/` 仍是旧资产**（见 §5）。
关联 `m42-broker-entry-and-client-disconnect.md`（本轮是它 §6 里两条遗留项的落实）。

## 1. 两个问题

**(a) guest 的控制进程死了，宿主要等到超时才知道。** M42 的变异检查里观察到：guest 的 bootstrap 在一条 exec 中途被杀，宿主仍然等满「命令超时 + 5 秒」（那次是 20 秒）才报一个含糊的 `exec response timeout`。控制连接的读端其实立刻就收到了 EOF，只是那个事件只被写进了审计记录，没有人据此行动。

**(b) `brokerreq` 的退出码不反映结果。** guest 的 broker 入口「受理即答 OK」：请求被策略拒绝、上游 404、宿主拉取失败时，`brokerreq` 照样返回 0，`/workspace/inbound/` 里留下一个空文件，guest 里的程序无从得知发生了什么（M42 才让宿主日志里有了痕迹）。顺带还有一个静默丢失：同时在途的请求超过 4 个时，第 5 个同样被答 OK，而数据无处可写。

## 2. 修复

**(a) 宿主（`ControlLossPolicy`、`VZRuntime`）**

- 控制连接读到 EOF 时判断它是否「意外」：出事的必须是**当前**这条连接，且沙箱处于 running。stop / destroy / resume 会先把连接置空再处理，旧连接随后报出的 EOF 不算；非 running 状态下连接的生灭归生命周期管。
- 意外断开时记下原因；等待 exec / stats 应答的循环每一轮检查，命中就立刻失败：`DBX-GUEST-CONTROL-LOST`，并把沙箱标为 failed。新连接建立（resume 之后的重连）时清空。
- GUI 对这个原因码有可读的说明。

**(b) guest（`scripts/guest-bootstrap.c`，`brokerVersion = 3`；`scripts/brokerreq.c`）**

- 请求方的连接保持到宿主的 `brokerEnd` 到达，应答带真实结果：`OK <HTTP 状态码> <字节数>` 或 `ERR <原因>`。
- 先打开目标文件、占住槽位，再向宿主发请求；打不开目标或槽位用完时立刻答 `ERR`（此前答 OK）。
- 宿主超过 180 秒没有结果的请求会被回收（不永久占槽位）；控制通道重连时，在途的请求以 `ERR control channel reset` 结束。
- `brokerreq` 客户端：成功时打印 `saved <字节数> bytes (HTTP <状态码>)` 并返回 0；失败时把原因打到 stderr 并返回 8；120 秒等不到应答返回 7。新旧两边互相兼容：旧客户端配新 bootstrap 只是不打印结果行；新客户端配旧 bootstrap 时 0 仍只表示「已受理」。

## 3. 行为变化

- `brokerreq` 现在**阻塞到下载结束**才返回（此前立刻返回）。依赖「立刻返回再自己轮询文件」的脚本仍然能用，只是轮询变得多余。
- 被拒绝或失败的请求返回 8 而不是 0。
- guest 控制面死亡后，在途的 exec / stats 立刻以 `DBX-GUEST-CONTROL-LOST` 失败，沙箱进入 failed（此前要等超时，且状态要到下一次写才变）。

## 4. 验证

单元测试（`swift test` 414 全绿，新增 3）：`ControlLossPolicyTests`——只有「当前连接 + running」算意外；其余所有生命周期状态都不算；消息带原因码、操作名与细节。

真机 `scripts/e2e-broker-exec.sh`：

| | 结果 |
| --- | --- |
| **新 guest**（补丁版夹具 15 项；正式构建的候选 15 项） | |
| 被策略拒绝的主机 | `brokerreq` 134ms 返回，退出码 8，stderr：「host 不在 allowlist」 |
| 真实下载 `https://example.com/` | `brokerreq` 返回 0 的那一刻文件已完整（577 字节，与宿主直接 curl 的大小一致），不需要轮询 |
| 上游 404 | 退出码 8，stderr 含状态码 |
| 新版客户端（仅候选） | 打印 `saved 577 bytes (HTTP 200)` |
| M42 的各项 | 提前关闭的客户端 ×20、不说话的客户端、SIGPIPE 不继承——仍然通过 |
| **旧 guest**（本机现有资产，5 项） | |
| 控制面被杀之后 | 随后的 exec 149ms 内失败并说明原因 |

**(a) 的「在途」路径是用变异验证的**（不在套件里）：把 guest 改回「SIGPIPE 默认行为」重建补丁版——这样 guest 的控制进程会在一条 exec **执行期间**被杀。结果：那条 exec 在 **129ms** 内以 `DBX-GUEST-CONTROL-LOST` 失败（M42 时同一场景是 20 秒后的 `exec response timeout`）。源码已还原。

**候选已重建**（`macos/guest-candidate/`，含 M37 / M39 / M41 / M42 / M43 的 guest 改动，以及新的 `brokerreq` 客户端）。全量 `e2e-all.sh` 以它为 guest：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

全量 `e2e-all.sh`（本机现有旧 guest）：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

## 5. 诚实边界

- **本机 `macos/guest/` 与 `gui/dist/DeskBox.app` 里自带的那份都没有换**：在它们上面 `brokerreq` 仍然是「受理即返回 0」，M42 §2.1 的缺陷也仍然存在。
- **(a) 改动了控制连接断开时的处理，而 resume 正好会更换控制连接。** 设计上旧连接的 EOF 被「是否当前连接」的判断挡在外面，单元测试覆盖了这个判定函数——但判定的**输入**（resume 时确实先置空、再收到 EOF）只能在真机 resume 上验证，而宿主锁屏，**依赖 resume 的 9 项断言本轮仍未验证**。加上 M42 的 SIGPIPE 改动，现在有两处未经 resume 验证的改动落在同一条路径上。
- (a) 的在途路径没有常驻的自动化测试：新 guest 上没有办法让不可信程序杀掉控制进程（这正是 M42 修掉的），只能靠变异重现。旧 guest 上的用例覆盖的是「死后下一条请求」。
- 只有 exec 与 stats 的等待循环接入了即时失败；workspace 同步、终端相关的等待仍然靠各自的超时。
- 失败的下载仍会在 `/workspace/inbound/` 留下一个空文件（按路径删除需要以 root 身份穿过 workload 可写的目录，没有做）。
- `ERR` 的原因文本来自宿主的错误描述，原样（压成一行）交给 guest 里的程序——里面有被拒绝的主机名这类信息，没有凭据。
- 同时在途的 broker 请求上限仍是 4；现在第 5 个会得到明确的 `ERR busy`，但这条路径没有测试。180 秒回收、控制通道重连时的 `ERR` 同样没有测试。
- 真实下载两项依赖宿主能访问 `https://example.com/`，访问不了时 SKIP。
