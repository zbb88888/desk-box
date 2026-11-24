# M24：daemon 并发化与优雅停机

状态：已完成（M24a/b/c）；关联 `m12-sandbox-lifecycle-cli.md`、`m20-lifecycle-persistence.md`、`m23-credential-domains.md`、`next-roadmap.md` §3。

## 1. 背景

M12 的 daemon 在 `accept` 后用一个串行 queue `sync` 处理每个连接。后果：

- `run` 引导期间（数秒到 90s 超时）`ps`/`exec`/`shutdown` 全部排队 —— GUI 每 3s 的刷新被卡住，是「Cmd+Q 无法退出」的上游根因（GUI 侧已在前一个 hotfix 里异步化，只是掩盖症状）。
- 一个**连上却不发请求**的本地客户端就能卡死整个 daemon（旧实现连读超时都没有）。
- 协议分发层（路由 / 缺参 / 域比对）只有真机 e2e 覆盖，没有单元测试。

## 2. 设计

### M24a：决策表（`Sources/dbx-poc/DaemonDecision.swift`）

纯函数 `DaemonDecision.validate(request, state) -> DaemonRoute`，输入是 `DaemonStateSnapshot`（sandboxId→域、ptySessionId→sandboxId、draining）。只判定「路由 + 必备参数 + 会话存在 + M23 域前置比对 + draining」，不碰 VZ / 文件系统。

- effect 层（`dispatch*`）**保留自己的 guard**：validate 与执行之间状态可能变化（TOCTOU），决策表是前置拒绝，不是唯一防线；`VZRuntime.require` 的域校验同样保留。
- 错误文案与 M12–M23 兼容（e2e 脚本 grep 依赖，如 `DBX-DOMAIN-SESSION-MISMATCH`）。
- 域拒绝优先于缺参拒绝：跨域请求不能靠「缺参」报错探测沙箱。

### M24b：并发模型

| 层 | 机制 | 保护对象 |
|---|---|---|
| 连接 | `handlerQueue`（concurrent），每连接一个 handler；请求读取 10s 超时 | 队头阻塞 / 半开连接 |
| 簿记 | `stateQueue`（serial，只做字典读写，从不在其中做 VM 操作） | `sessions` / `ptySessions` / `draining` |
| VM 操作 | 每沙箱 `SandboxSession.opQueue`（serial） | exec / stats / wsSync / suspend / resume / stop / rm / destroy |
| VZ | `VZRuntime` 自己的 queue（未改） | VZ `dispatch_assert_queue` 纪律 |

- **exec 必须按沙箱串行**：`VZRuntime.execute` 用单槽 `pendingExecRequestID` 匹配响应，同沙箱并发会错配。
- **pty 读写不进 opQueue**：pty 事件有独立缓冲，流式终端必须能与长 exec 并行。
- `rm` 在 opQueue 内二次确认会话仍在 → 并发 `rm` 恰好一个成功；`rm` 时一并回收该沙箱的 pty 会话（此前残留到下一次 poll）。
- `ptyOpen` 的「查重 → 打开 → 登记」在 opQueue 内完成，同沙箱并发只成功一个。

串行 daemon 以前「顺带」保护了三处跨沙箱共享状态，并发化后必须显式处理：

1. **`registry.json` read-modify-write**（每沙箱一个 `VZRuntime`/`SandboxRegistry` 实例）→ `flock` 独占锁（`registry.lock`，跨线程 + 跨进程，CLI `sweep` 同样受保护）；临时文件名带 UUID。
2. **sweep 无条件删除 `snapshots/tmp-*`** → 进程内在途登记表 `InFlightSnapshotFiles`，suspend/resume 的临时文件不再被并发 `run` 的 sweep 当孤儿删掉。
3. **`scheduler-decisions.jsonl` 的 seek+write** → `O_APPEND` 原子追加。

### M24c：优雅停机

`shutdown`：置 `draining`（此后除 shutdown 外全部拒收）→ 等在途 `run` 归零（boot-watch 轮询看到 draining 即中止并自行 destroy；会话登记与 draining 判定在同一临界区，停机后不会再长出新会话）→ 逐沙箱在其 opQueue 内 destroy → 写回 ack → 唤醒 accept 循环 → 有界等待（5s）在途 handler → `unlink` socket。

`serveLoop()` 可返回（`serve()` 包一层 `exit(0)`），daemon 因此可以在单测进程内起停。

## 3. 顺带修掉的两个既有缺陷（均由新测试发现）

1. **`SandboxRegistry.processIsAlive` 读脏 `errno`**：`kill(pid,0)` 成功时不清 `errno`，旧代码不看返回值 → 本线程上一次失败调用留下的 `errno` 会让**活着的**沙箱被判成孤儿，`sweep` 随即删除它的 COW 盘。串行时代靠运气不常触发；并发 daemon 下每次 `run` 的 sweep 都可能误删别的运行中沙箱。现以返回值为准。
2. **崩溃清理泄漏 M23 域标记**：`sweep` 只删 clone，不删并排的 `sandbox-<id>.vhd.domain`；每次 daemon 崩溃在 cow-root 留一个孤儿 sidecar。现随 clone 一并删除。

## 4. 验证

单元测试 `Tests/DaemonTests`（30 个，不起 VM）：

- 决策表 15：路由线上名锁定、每个 kind 的缺参/未知沙箱、9 个会话级操作的跨域拒绝、pty 单会话与孤儿会话可关闭、draining。
- serve 9（真 UNIX socket）：socket 0600、拒绝文案、畸形 JSON 后存活、**卡住的客户端不阻塞 `ps`**、64 路并发、shutdown 后 `serveLoop` 返回且 socket 已 unlink、卡住的客户端不拖死停机。
- registry 6：48 实例并发 upsert 不丢、upsert/sweep/destroy 混合一致、脏 errno 回归 ×2、sidecar 回归、无临时文件残留。

真机 e2e `scripts/e2e-daemon-concurrency.sh` **31/31**（连续 3 轮）：

```
引导期间 ps 应答 23 次，最大延迟 30ms（旧实现：0 次，全程阻塞）
并行 run B/C 成功；registry.json 3 项
3×(sleep 3) 跨沙箱并行 exec 3084ms（串行 ≥ 9000ms），输出不串台
A 长 exec 期间：B exec 95ms / ps 28ms
同沙箱 4 路并发 exec 响应不错配
suspend 与并发 run：快照未被误删，resume 后 exec 正常，无 tmp-* 残留
并发 rm 同一沙箱：恰好一个成功
引导中途 shutdown：ack、run 被 draining 中止、进程退出、socket 清除、registry/clone/快照全空
kill -9 后 sweep：cow-root 零残留（含 sidecar）
```

回归：`swift test` 178 个全绿；`e2e-sandbox-lifecycle` 17/17、`e2e-lifecycle-persistence` 15/15、`e2e-fault-injection` 6/6、`e2e-resource-stats` 7/7、`e2e-kernel-hardening` 12/12、`e2e-gui-buttons` 13/14（唯一失败项是前置条件「GUI 进程在」，本轮未开 GUI，针对私有 daemon 运行）。

### 测试资源纪律

- `e2e-daemon-concurrency.sh`：sock / cow-root / 快照 / 日志 / 调度证据全部落在一个 `mktemp -d` 目录，`trap EXIT INT TERM` 负责「shutdown → 兜底 kill → 删目录」，失败路径同样执行；不读写 `~/Library/Application Support/DeskBox`，可与正在运行的 GUI daemon 并存。
- `DaemonTests`：每用例独立 `/tmp/dbxt-*` 目录 + 注入 `supportRoot`，`addTeardownBlock` 停机并断言目录已删。

## 5. 诚实边界

- **T6（suspend × 并发 sweep）是时序相关的**：测试让两者同时发生并验证结果正确，但不能保证每轮都恰好撞上「sweep 扫描时 tmp 文件存在」的窗口；该不变量的确定性证据是代码审查 + `InFlightSnapshotFiles` 的实现，不是这条 e2e。
- ~~`InFlightSnapshotFiles` 只在进程内有效~~：M27 改为属主 PID 判定，跨进程成立，登记表已删除。
- ~~`e2e-credential-domains.sh` 未运行~~：M25 隔离化后已在并发 daemon 上复验，21/21。
- ~~既有 e2e 脚本使用默认 cow-root 并在 `/tmp` 留日志~~：M25 已全部迁到公共 harness。
- ~~同沙箱的长 exec 会让 `rm --force` / `shutdown` 等到 exec 超时~~：M26b 已解决。
- ~~`--memory-mib 512` 表现为 90s 超时~~：M26a 已解决（10s 内给出原因）。
- `registry.lock` 会常驻 cow-root（设计如此）。

## 6. 后续

见 `next-roadmap.md`：M25（e2e 隔离化：`DBX_SUPPORT_ROOT` + 统一 harness）、M26（exec 取消与引导失败快速诊断）、M22b（真机公证，等证书）。
