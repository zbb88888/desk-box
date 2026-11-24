# M42：guest 内的 broker 入口不能搞垮控制面；exec 的客户端走了就别再跑

状态：宿主侧已完成；guest 侧的修复在补丁版 guest 与正式构建的候选上验证通过。**本机 `macos/guest/` 仍是旧资产，§2.1 的缺陷在它上面仍然存在**（见 §6）。
关联 `m41-exec-cancel.md`、`m2-3-broker.md`、`../security/threat-model.md`（INV-08）。

## 1. 起因

M41 留了两个待确认的问题：客户端被强杀时 daemon 不会替它取消 exec；exec 期间 guest 的 bootstrap 不受理 broker 的请求入口，「不知道是否构成死锁」。本轮先在真机上试了后者——结果比预想的严重。

## 2. 发现的问题

### 2.1 guest：workload 可以杀掉自己沙箱的控制面（旧 guest，真机复现）

```
dbx-poc exec <id> --timeout 5 -- /bin/sh -c 'brokerreq https://example.com/x'
→ 卡满 5 秒，exit 254
dbx-poc exec <id> -- /bin/echo hi
→ DBX-BOOT-PROOF-MISMATCH: VZ control socket closed before write；沙箱 state=failed
```

原因有两层：

1. **exec 期间 bootstrap 不受理 broker 入口**（`/run/deskbox-broker.sock`）。`brokerreq` 连上、发出请求后等应答，而应答要等 exec 结束——互相等，直到 exec 超时把它杀掉。
2. exec 结束后 bootstrap 才去 accept 那条连接，读到请求，向**已经不存在的对端**回写 `OK` → **SIGPIPE 杀掉了 bootstrap**。控制通道随之关闭，宿主把沙箱标为 failed。

第 2 层不依赖 exec：任何「连上 broker socket、发一行请求、不等应答就关闭」的程序都能触发（在终端里是一个很窄的竞争窗口，在 exec 里是必然的）。此外入口对每个连接做的是**阻塞读**：连上之后什么都不发的客户端会让 bootstrap 一直卡在 `recv` 上，宿主的所有请求都得不到应答。

影响：沙箱内的不可信程序可以让这台沙箱对宿主失去响应或进入 failed。受影响的是它自己的沙箱（其它沙箱、daemon 不受影响，`rm` 仍可清理），属于 INV-08（宿主对沙箱的控制）而不是越权。

### 2.2 宿主：客户端走了，命令照跑

`dbx-poc exec` 被 `kill -9`、连接断开、GUI 的读超时到点之后，命令仍在 guest 里跑并占着这台沙箱的操作队列；**排队中**、还没开始的 exec 在客户端走了之后轮到它时也照样执行——执行一条没人要结果的命令。

### 2.3 M39 引入的回归：exec 超时最多提前 1 秒

M39 重写等待循环时只比较了整秒（`now.tv_sec - started.tv_sec`），跨过整秒边界时会提前判超时。本轮全量回归里「超时 3s」的用例在 2.4s 返回，被已有断言抓到。改为按纳秒比较，并把那条断言的下限从 2.5s 收紧到 2.95s。

## 3. 修复

**guest（`scripts/guest-bootstrap.c`，`brokerVersion = 2`）**

- broker 的状态与处理函数提到文件作用域，主循环与 exec 的等待循环共用：exec 期间同样受理请求入口；宿主回传的数据帧当场落盘（不排队）——exec 里的程序请求下载后，文件在同一条 exec 期间到达。
- bootstrap 忽略 SIGPIPE（写失败返回 EPIPE，由各处已有的错误处理接手）；向 broker 客户端回写用 `MSG_NOSIGNAL`。**exec / pty 的子进程恢复默认行为**（不继承「忽略」）。
- 每个 broker 客户端连接有 200ms 的收发超时。

**宿主**

- `ClientDisconnectWatcher`：处理 exec 请求期间监视客户端连接。读到 EOF 时要区分「真的走了」和「半关闭」（发完请求就关闭写端、仍在等应答，例如 `nc`）：往回写一个空格——对端完全关闭则 EPIPE；半关闭则写成功，而 JSON 应答之前的空白不影响解析。
- 客户端走了之后（`ExecAbandonment`）：还在排队的 exec 轮到时不执行（`DBX-EXEC-CLIENT-GONE`，记入 daemon 日志）；已经在 guest 上的请求取消（复用 M41；旧 guest 会忽略，命令跑到结束或超时——与此前相同）。
- broker 拉取失败（被策略拒绝、上游非 2xx……）此前在宿主一侧没有任何痕迹（原因只回给 guest，而 guest 的 `brokerreq` 早已返回 OK）。现在记一行 daemon 日志，只含主机名，不含完整 URL。

## 4. 验证

单元测试（`swift test` 411 全绿，新增 9）：`ClientDisconnectWatcherTests`——完全关闭只触发一次；半关闭不触发且随后的应答仍可解析；安静的连接不触发、stop 在一个轮询周期内返回；客户端多发的数据不算断开；`ExecAbandonment` 的两种时序与并发竞争（要么不执行、要么拿到令牌去取消，不会两头落空）。

真机 `scripts/e2e-broker-exec.sh`（新增；按 guest 的 `brokerVersion` 自动分支）：

| | 结果 |
| --- | --- |
| **新 guest**（补丁版夹具 13 项；正式构建的候选 12 项） | |
| exec 里调用 `brokerreq` | 134ms 返回；之后沙箱 state=running；被拒绝的请求在宿主日志留痕 |
| 20 个「发完请求不等应答就关闭」的客户端 | 控制面仍在 |
| 连上却什么都不发的客户端（挂 6 秒） | 这期间宿主的 5 条 exec 都在 1.5s 内应答 |
| workload 的 SIGPIPE | `seq 1 200000 \| head -n 1` 安静结束；新进程的 SigIgn 位图里没有 SIGPIPE |
| 真实下载（`https://example.com/`） | 文件在同一条 exec 期间到达并可读，约 1.5s |
| **旧 guest**（本机现有资产，4 项） | |
| exec 里调用 `brokerreq` | 复现 §2.1（卡到超时，随后沙箱 failed）——只作为已知缺陷打印，不计入 PASS |
| 宿主的收拾 | 那台沙箱可以 `rm`；daemon 与新建的沙箱不受影响 |

`scripts/e2e-exec-cancel.sh` 新增（两种 guest 都跑）：排队中的 exec 在客户端被 `kill -9` 后没有执行；半关闭的客户端不被当成断开、应答完整；在途 exec 的客户端被 `kill -9` 后 daemon 发现并请求取消——新 guest 上命令被杀、下一条 exec 148ms 返回，旧 guest 上命令照旧跑到超时。

**变异检查**（3 个，全部被抓到，源码已还原）：去掉 broker 连接的接收超时 → 「不说话的客户端」一项失败；恢复 SIGPIPE 默认行为 → 「提前关闭的客户端」之后控制面死亡，7 项失败；让被放弃的排队 exec 照常执行 → 2 项失败。

**候选已重建**（`macos/guest-candidate/`，含 M37 / M39 / M41 / M42 的 guest 改动）。全量 `e2e-all.sh` 以它为 guest：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

全量 `e2e-all.sh`（本机现有旧 guest）：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

## 5. 过程中的失误

- 候选的第一次 Docker 构建失败（Docker Hub 又一次不可达，exit 125），我没有先检查构建结果就对着一个没有 manifest 的目录跑了全量回归——20 个套件立刻失败。没有造成残留；之后的命令改为构建失败即停。
- §2.3 的回归是我在 M39 引入的，当时的断言下限（2.5s）太松，没有稳定抓到它。

## 6. 诚实边界

- **本机 `macos/guest/` 没有换，`gui/dist/DeskBox.app` 里自带的那份也没有换**：在它们上面，沙箱里的任何程序都可以用 §2.1 的办法让这台沙箱 failed。宿主无法替旧 guest 修这个问题。安装候选：`./scripts/install-guest-candidate.sh ./guest-candidate`。
- **忽略 SIGPIPE 改变了控制通道写失败时的行为**（此前 bootstrap 被杀，现在走重连逻辑）。suspend / resume 之后的重连正好经过这条路，而宿主锁屏，**resume 相关的 9 项断言本轮仍然没有验证**——这是本轮改动里我最没有把握的一处。
- `brokerreq` 仍然是「请求已受理」就返回 0：下载被拒绝或失败时，guest 里只会留下一个空文件，程序无从得知原因（现在宿主日志里有）。让 guest 侧拿到结果需要改 broker 的应答协议，没有做。
- 真实下载那一项依赖宿主能访问 `https://example.com/`，访问不了时 SKIP。
- guest 的控制面在 exec 中途死掉时，宿主要等到「命令超时 + 5 秒」才报错，而不是立刻发现（变异检查时观察到的）。
- 客户端断开的检测只用于 exec（不包括 `run`、`ws-sync`）；轮询间隔 100ms。半关闭的客户端会在应答前多收到一个空格——不容忍前导空白的客户端会受影响（项目自带的客户端都不半关闭）。
- GUI 的读超时（120s）到点后现在也会触发取消，但没有专门的测试。
- 「提前关闭的客户端」与「不说话的客户端」两项需要交叉编译器构建辅助程序，没有时 SKIP。
