# M37：workspace 同步的边界（INV-05）

状态：宿主侧已完成并验证；guest 侧的修复已写入源码并在补丁版 guest 上验证，**但本机 `macos/guest/` 下的现有资产尚未重建**（见 §6）。
关联 `m2-1-workspace-sync.md`、`../security/threat-model.md`（INV-05 / INV-06 / INV-08）、`m36-e2e-evidence.md`。

## 1. 起因

M36 的证据显示 INV-05（宿主文件仅来自显式工作区授权）在 `e2e-all.sh` 里**未覆盖**：此前只有宿主侧文件系统语料的单元测试，没有一条真机测试验证过「宿主目录 → guest 的 /workspace」这条数据通路。补这条证据的过程中发现了三个问题，其中一个是 guest 内第二道隔离的越权。

## 2. 发现的问题

### 2.1 宿主：快照校验与推送之间的 TOCTOU（已修复）

`buildSnapshot` 对每个文件做了校验（不是符号链接、在限额内、算了 SHA-256），但 `pushWorkspace` 随后**按路径重新读取** `Data(contentsOf:)`——跟随符号链接、不检查大小、也不与快照里的摘要比对。校验之后把文件换成指向别处的符号链接，就能把任意宿主文件送进 guest。这正是矩阵为 INV-05 列出的「TOCTOU、并发替换」。

修复：每个文件只读一次。`secureRead` 从 workspace root 的目录描述符出发**逐级 `openat(O_NOFOLLOW)`**，在同一个描述符上完成类型检查（必须是普通文件；`O_NONBLOCK` 防止 FIFO 挂住）、大小检查（读到 EOF，不信任 `st_size`）与读取；摘要由读到的字节计算；推送只用这份字节。上限仍是 64MiB。

### 2.2 guest：workload 预置的符号链接会被 root 跟随（越过 guest 内第二道隔离）

guest 的 workspace 接收端以 **root** 身份执行 `open("/workspace/<rel>", O_WRONLY|O_CREAT)`，然后 `fchown(fd, 65534)`。`/workspace` 对沙箱内的 workload（uid 65534）可写。真机复现（旧 guest）：

| workload 的预置 | 下一次同步之后 |
| --- | --- |
| `/workspace/x` → `/etc/target`（符号链接直接放在粘滞位的 `/workspace`） | 被内核的 `protected_symlinks` 挡住，同步失败 |
| `mkdir /workspace/sub`；`/workspace/sub/x` → `/etc/target` | **`/etc/target` 被 root 创建**，内容是宿主文件，属主 65534 |
| `mkdir /workspace/a`；`/workspace/a/b` → `/etc` | **`/etc/<文件名>` 被 root 创建** |

对照：workload 自己 `touch /etc/x` 是 `Permission denied`。

影响：workspace 按定义就是不可信代码。恶意仓库只要带一个与某个系统二进制同名的文件，再让 workload 预置一个符号链接，下一次同步就会让 root 用仓库里的内容覆盖那个二进制（init 循环会周期性地以 root 执行 `/bin/busybox`）——从 uid 65534 + Landlock + seccomp 升到 **guest 内的 root**。VM 边界（INV-01）不受影响；受影响的是 guest 内的第二道防线（INV-06 / INV-08）。

同一模式还出现在 broker 下载（`/workspace/inbound/<name>`，由 workload 自己触发，且带 `O_TRUNC`）。

### 2.3 guest：文件变短后重新同步，旧内容的尾巴残留

接收端打开文件时不截断。宿主文件从 `AAAAAAAAAAAAAAAAAAAA` 改成 `BB` 后重新同步，guest 里是 `BB` + 旧内容的后半段。

### 2.4 宿主：exec 白名单可用 `..` 绕过（已修复）

`argv[0]` / `cwd` 的判断是 `hasPrefix("/workspace/")`：`/workspace/../bin/busybox` 被当成 workspace 内的可执行文件，`--cwd /workspace/../etc` 在 `/etc` 下执行。由于 `/bin/sh` 本来就在白名单里，这不构成越权，但策略表达的意图可以被绕过。改为规范路径判断（`ExecPathPolicy`）。

## 3. 修复

**guest（`scripts/guest-bootstrap.c`）**

- `ws_open_beneath`：从 `/workspace` 的描述符出发逐级 `openat(O_NOFOLLOW|O_DIRECTORY)`；最终对象必须是普通文件且只有一个硬链接；`O_NONBLOCK`；确认对象可信之后才截断。任何一级不满足都失败，该文件计为未收到，`wsEnd` 时计数不符，同步以失败报告给宿主。
- 文件首块（offset 0）截断旧内容。
- broker 下载路径改用同一个函数。
- 经 stats 应答上报 `workspaceSyncVersion = 2`（旧 guest 没有这个字段）。没有改动 hello 握手的线上格式。

**宿主闸门（`WorkspaceResyncPolicy`）——在 guest 更新之前就生效**

- workload 还没运行过（没有 exec / pty）：任何 guest 版本都可以同步；
- workload 运行过：只有 guest 上报的接收端版本 ≥ 2 才允许；查询失败按旧版本处理；
- 否则以 `DBX-WS-RESYNC-UNSAFE` 拒绝，除非调用方显式接受风险（请求字段 `allowUnsafeResync`，CLI `ws-sync --allow-unsafe-resync`），放行会在 daemon 日志里留痕。

新增 CLI 子命令 `dbx-poc ws-sync <sandbox-id> <目录>`（此前只能直接写 socket）。GUI 没有放行入口，被拒时显示可读原因。

**行为变化**：用旧 guest 资产时，「运行过程序之后再点 Sync」会被拒绝。正常顺序（先同步、再运行）不受影响。

## 4. 验证

单元测试（`swift test` 共 370 全绿，新增 15）：

- `WorkspaceSnapshotRaceTests` 5：快照携带它所哈希的字节；快照之后把文件换成符号链接不改变将被推送的内容；每一级的符号链接、`..`、FIFO（不挂住）、超限都被拒；**并发性质测试**——另一个线程不停地把文件与中间目录在「真实对象」与「指向秘密的符号链接」之间切换，3 秒内的每一次快照要么抛错、要么只含 workspace 自己的内容，从未包含秘密（且确实既有成功也有被拒，证明撞上了竞争窗口）。
- `ExecPathPolicyTests` 4、`WorkspaceResyncPolicyTests` 6。

真机 `scripts/e2e-workspace-sync.sh`（自动识别 guest 的接收端版本）：

| | 旧 guest（本机现有资产） | 补丁版 guest（当前源码的 bootstrap） |
| --- | --- | --- |
| 结果 | 45 通过 | 54 通过 |
| 宿主侧 W1–W7、W10 | 通过 | 通过 |
| 再次同步闸门 | workload 运行前允许；运行后以 `DBX-WS-RESYNC-UNSAFE` 拒绝且 guest 未被改动；显式放行后可用并留痕 | workload 运行后直接允许 |
| W8 文件变短 | （显式放行后）复现缺陷，仅作为信息打印 | 内容正好是新内容 |
| W9 预置符号链接 ×3 | （显式放行后）`/etc/…` 被 root 创建，仅作为信息打印 | 都没有写到 /workspace 之外，同步以失败报告 |
| W9 预置 FIFO | — | 同步失败，186ms，guest 之后仍响应 |
| 清掉预置物后正常同步 | — | 通过（修复没有误伤正常路径） |

宿主侧覆盖：嵌套目录 / 空文件 / 带空格与非 ASCII 文件名 / 300KB 二进制逐字节一致；隐藏文件（`.env` `.git` `.ssh`）不进入 guest；五种符号链接、三种超限、FIFO 均被拒且 guest 无部分同步；guest 的修改不回流；guest 没有任何共享文件系统挂载。

**变异检查**：关掉宿主闸门 → 旧 guest 上的 G2 失败。guest 侧修复的对照就是「旧 guest 复现 / 补丁版 guest 不复现」。

补丁版 guest 的构建（`scripts/build-patched-guest.sh`）：不需要 Docker 和 root——用本机的 `aarch64-linux-musl` 交叉编译器，libsodium 从官方源码包静态编译（校验固定的 SHA-256），在 cpio 归档流里替换那一个文件。约 27 秒。`e2e-workspace-sync-patched.sh` 把它接进 `e2e-all.sh`；缺工具或没网时整个套件 SKIP 并说明原因，但 guest 源码编译失败会算作失败。

全量 `e2e-all.sh`：18 个套件 0 失败，卫生四项 clean，退出码 3（宿主锁屏）。

## 5. 走过的弯路

- 最初打算用 Docker 重建 initrd，本机访问不了 Docker Hub，改为交叉编译 + cpio 流内替换。
- 第一版 FIFO 用例是空跑：guest 的 busybox 没有 `mkfifo` 命令，FIFO 根本没建出来，「同步成功」是真的成功。改用 `mknod … p` 并加了「FIFO 确实存在」的对照。
- 路径规范化用了 Foundation 的 `resolvingSymlinksInPath`，它在 macOS 上把 `/private/tmp` **还原**成 `/tmp`，方向相反；改用 `realpath(3)`。

## 6. 诚实边界

- **本机的 `macos/guest/` 资产没有重建，仍然是旧接收端。** 修复通过两条路生效：CI 的 `guest-build` 每次从源码构建（所以发布资产会带上修复）；本机需要运行 `./scripts/build-alpine-guest.sh ./guest`（需要 Docker 且能访问 Docker Hub，本机当前访问不了）。在那之前，本机靠宿主闸门保护：默认路径拒绝不安全的再次同步。
- **补丁版 guest 是测试夹具，不是发布资产**：编译器（musl-cross gcc 14）与 libsodium（1.0.20 源码构建）都和正式构建（Alpine 容器）不同。它证明的是源码改动的逻辑，不是正式产物的字节。正式构建的编译只由 CI 的 `guest-build` 验证，CI 不启动 VM。
- **显式放行（`--allow-unsafe-resync`）之后，旧 guest 上的缺陷完全可达。**
- broker 下载路径的同类修复**没有真机测试**（需要配置 broker 策略与可达的上游）。
- 同步不是镜像：宿主侧删除的文件不会从 guest 消失（两种 guest 都如此）；同步失败时已写入的部分文件不回滚。
- 宿主闸门把 exec / pty 都算作「运行过 workload」，不区分命令是否真的动过 /workspace。
- 没有覆盖 workload 与同步**并发**的情况（pty 里的进程在同步进行时改动 /workspace）；新接收端的逐级 `O_NOFOLLOW` 在设计上对此成立，但没有针对性的测试。
- 宿主锁屏：历史遗留的 9 项依赖 resume 的断言仍未验证。本轮没有改动 suspend / resume。
