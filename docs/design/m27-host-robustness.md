# M27：宿主侧健壮性收尾

状态：已完成。本轮结束时有 6 项依赖 resume 的断言因宿主锁屏未验证（见 §5/§7）；**M28 期间会话解锁后已全量复验通过**（`e2e-all.sh` 退出码 0）。
关联 `m24-daemon-concurrency.md` §5、`m26-boot-diagnosis-and-cancel.md` §5、`m20-lifecycle-persistence.md`。

## 0. 范围说明

原计划的 M27 是「guest 侧 exec kill 协议」。评估后推迟为 M29：它需要重建 guest 资产（Docker + 联网下载内核/模块）、协议与 `guestAssetVersion` 变更，并会替换所有套件依赖的本地 `macos/guest`。同时确认了没有正确性缺陷逼着现在做——guest 已自行执行 exec 超时并杀掉进程组。

本阶段改做宿主侧已知的 fail-open / 误删问题。

## 1. CLI 参数解析 fail-closed（`CLIArgs.swift` / `DaemonCLI.swift`）

原先各子命令手写 `try? optionString(...)`，出错即回落默认值：

| 现象 | 后果 |
|---|---|
| `--daemon-sock` 缺值/空值 → 用默认 socket | 脚本里 `$SOCK` 为空时，`shutdown` 关掉的是**用户真实的 daemon** |
| `--memory-mib 4G` 被忽略 | 静默用 2048 |
| 未知选项被忽略 | `rm ID --froce` 变成非 force |
| `exec` 在 `--` 之后仍解析选项 | guest 命令行里的 `--timeout`/`--env`/`--domain` 被吃掉 |
| 选项写在位置参数之前 | `exec --timeout 5 <id>` 把 `--timeout` 当成沙箱 id |
| `--env` 不含 `=` | 静默丢弃 |
| `stop`/`rm`/`stats`/`console`/`restart` 接受 `--domain` 却不发送 | 声明形同虚设 |

改为声明式规格（`DaemonCLISpecs`，13 个子命令）+ 纯函数解析：带值选项必须有非空值且值不能是另一个已知选项；`--opt=value` 等价；非 repeatable 选项重复报错；未知选项报错；位置无关；`--` 之后一个字节都不解析；整数严格校验范围。「命令行 → `DaemonRequest`」是纯函数，可直接单测。

未覆盖：`launch` / `verify-*` / `publish` / `check-update` / `domains` 等非 daemon 子命令仍用旧的 `optionString`（其中多数是 `try` 而非 `try?`）。

### 顺带：`rm` 比对声明的域

`rm` 是唯一不比对 `--domain` 的会话级操作（M23 规则：声明了就必须一致）。现在决策表与 effect 层都比对。未声明域的 `rm` 行为不变。

## 2. daemon 单实例守卫（`DaemonInstanceGuard.swift`）

`serveLoop` 原先无条件 `unlink(sock)` 再 `bind`：第二个 daemon 会抢走正在运行的 daemon 的 socket，旧 daemon 连同它的 VM 变成不可达的孤儿。

两道检查：

1. `<sock>.lock` 上 `flock(LOCK_EX|LOCK_NB)`，持有到退出——新版本之间无竞争互斥；
2. 对现有 socket `connect` 探活——识别**不持锁的旧版本 daemon**。能连上就拒绝（`DBX-DAEMON-ALREADY-RUNNING`），连不上才当作崩溃残留清掉。

锁文件常驻（与 `registry.lock` 同理）。

## 3. 跨进程 sweep 不再误删在途快照临时文件（`SnapshotSweepPolicy.swift`）

M24 用进程内登记表挡住了同进程的并发 sweep，但另一个进程（`dbx-poc sweep`、同一 cow-root 上的另一个 daemon）仍会删掉在途的 `tmp-*.vzstate`。

临时文件名带属主 PID：`tmp-p<pid>-<uuid>.vzstate` / `tmp-restore-p<pid>-<uuid>.vzstate`。

| 文件 | 判定 |
|---|---|
| 属主进程活着 | 保留（在途） |
| 属主已死 | 删除（崩溃残留） |
| 旧格式（无 PID） | 10 分钟宽限期后删除（给仍在运行的旧版本 daemon 留窗口） |
| 任何临时文件超过 24h | 删除（防 PID 复用导致永久残留） |
| `<id>.snap` | 按 registry 存活判定（不变） |

PID 解析拒绝 0 / 负数 / 溢出（`kill(0,…)`、`kill(-1,…)` 语义完全不同）。进程内登记表 `InFlightSnapshotFiles` 已删除（被属主 PID 判定完全覆盖）。

## 4. 本轮暴露并修复的既有缺陷：销毁 suspended 沙箱不删快照（INV-10）

`VZRuntime.destroy` 删 COW 盘与 registry 项，但从不删 `<id>.snap`。对 suspended 沙箱执行 `rm` 或 daemon `shutdown` 后，其加密 VM 状态仍留在磁盘上，直到之后某次 `run` 触发的 sweep 才被顺带清掉。M20 文档里「rm 后零残留」只在「先 resume 再 rm」时成立——而此前所有测试恰好都这么做。

它是因为宿主锁屏（resume 走不通，沙箱停在 suspended）才第一次被测试走到。现在 `destroy` 一并删除快照（删除失败则销毁失败并留审计）；`e2e-lifecycle-persistence` 与 `e2e-daemon-concurrency` 新增「对 suspended 沙箱直接 rm / shutdown → 零残留」，不论是否锁屏都会执行。

## 5. 宿主锁屏与 resume

### 观察到的事实

本轮中途（18:13 显示器关闭、会话锁屏之后）所有 resume 开始失败：

```
Error Domain=VZErrorDomain Code=12 "The virtual machine failed to restore with error “permission denied”."
```

排查顺序：先怀疑本轮改动 → 把临时文件名改回旧格式（两处分别、再一起）仍失败 → 旁路单实例守卫仍失败 → 用 **app bundle 里 10 月 28 日构建的旧二进制**跑同样的 suspend/resume 也失败 → 查到 `CGSSessionScreenIsLocked = true`。锁屏之前同一份代码的 resume 全部通过。suspend（保存）不受影响。

结论的强度：本轮是强相关 + 旧二进制复现；M28 期间会话解锁后，同一份代码的 resume 全部通过——已闭环。

### 做了什么

- **诊断**（`ResumeDiagnostics.swift`）：VZ restore 错误 + 会话锁屏 → `DBX-RESUME-HOST-LOCKED`，说明解锁后重试、沙箱仍为 suspended、快照保留，并附原始错误。未锁屏/无法判断时用 `DBX-RESUME-VZ-RESTORE-FAILED`，不把原因推给锁屏。只改写消息，不改变行为。
- **harness**：`e2e_screen_locked` / `skip_locked` / `expect_locked_resume`。锁屏时依赖 resume 的断言被明确标记为未验证，同时改为断言锁屏下应有的行为（原因码、仍为 suspended、快照保留）。
- **`e2e-all.sh` 退出码 3**：无失败但因锁屏有断言未验证——不让一次不完整的运行被当成完整通过。

### 尚未回答的问题

- **锁屏期间 suspend 的沙箱，解锁后能否 resume？** 未验证。若不能，「锁屏时 suspend」就等于丢状态，届时应在 suspend 侧拦截或警告。
- 这是 Virtualization.framework 的通用行为，还是与本机配置有关，未做对照。

## 6. 验证

单元测试（`Tests/DaemonTests`，本轮新增 38，共 100）：`CLIArgsTests` 16、`SnapshotSweepPolicyTests` 9（含经 `VZRuntime.sweepOrphans` 的真实目录集成）、`DaemonInstanceGuardTests` 6（含 6 路并发启动只活 1 个、不持锁的监听者被尊重、stale socket 被接管）、`ResumeDiagnosticsTests` 6、决策表 +1。`swift test` 共 248 个全绿。

真机 e2e `scripts/e2e-cli-and-instance.sh` **56 通过 / 1 因锁屏跳过**。关键设计：在隔离目录的**默认 socket 路径**上起一个「受害者」daemon，fail-open 的 `--daemon-sock` 会直接打到它身上。

```
--daemon-sock 缺值 / 空值 / 未加引号的空变量：全部被拒，默认路径上的 daemon 存活
被拒的 run 未到达 daemon、未创建沙箱；一连串被拒命令后沙箱仍 running
exec --timeout 20 <id>（选项前置）与 --opt=value 正常
`--` 之后 `--timeout 5 --env A=B --domain other --daemon-sock /evil -- --force` 原样到达 guest
--env 到达 guest；guest 拒绝 DBX_ 前缀与 PATH
rm / stop / stats 带错误 --domain 被拒
第二个 daemon 25ms 内以 DBX-DAEMON-ALREADY-RUNNING 退出；socket inode 不变；原 daemon 的 VM 仍可 exec
跨进程 sweep：活属主的在途文件保留，死属主 / 旧格式过期的删除
CLI sweep 持续并发下 suspend 成功且快照落盘
kill -9 后新 daemon 接管 stale socket，不复活旧沙箱
```

**变异检查**（均在限时内被杀）：

- sweep 改回「`tmp-*` 一律删除」→ 6 项失败；并发 sweep 下 `suspend` 报「文件不存在」，沙箱卡在 `suspending`——证明这个洞是真实可触发的。
- 旁路单实例守卫 → 11 项失败（第二个 daemon 接管 socket，原 daemon 不可达）。首次做这个变异时测试直接**挂死**（被接管的 daemon 一直在服务），已把该步骤改为限时 3s。
- 快照泄漏：修复前 `m20` / `m24` 各失败 1 项，修复后通过。

全量 `scripts/e2e-all.sh`：13 个套件 0 失败，卫生审计三项 clean，**退出码 3**（6 项因锁屏未验证）：

```
m24  B resume 后 exec 正常
m27  CLI sweep 持续并发下 3 轮 suspend/resume
m20  原始快照可恢复 / 恢复后数据仍在、权限未复活 / 二次 suspend/resume
m23  同域恢复成功
```

## 7. 诚实边界

- 上面 6 项**本轮没有验证**。它们在锁屏之前（M26 的全量回归）是通过的，但那之后本轮改了 suspend/resume 相关代码（临时文件命名、`destroy` 删快照、resume 错误改写），这些改动对「resume 成功路径」的影响只有代码审查，没有真机证据。**解锁后需要重跑 `./scripts/e2e-all.sh` 并得到退出码 0。**
- 「对正在运行的测试脚本 `kill -9`」无法清理：本轮我的两条一次性命令因超时被杀，各留下一个 `/tmp/dbx-*` 目录（其中一次还把变异后的源码留在了工作区），均已手工恢复/删除。套件自身的清理不受影响。
- ~~变异检查暴露：suspend 失败后沙箱会停在 `suspending`~~：M28 已修（回滚到 running）。
- CLI 加固只覆盖 daemon 生命周期子命令。
- ~~GUI 的 `clearStaleSocket` 会在探活失败时删 socket 文件~~：M28 已删除该逻辑并加了回归测试。
