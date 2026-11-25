# M48：runtime 的全部状态访问都在队列上；用 ThreadSanitizer 跑真机套件

状态：已完成。本轮**没有改 guest**（候选不需要重建）。
关联 `m46-control-loss-fixture-fd-hygiene-runtime-race.md`（§3 与 §6 的遗留项）。

## 1. 收尾 M46 留下的三处

M46 把 `VZRuntime.onQueue` 改成真正在串行队列上执行，但 start / stop / destroy 三个操作的闭包内部要 `await`（等 VZ 启动 / 停机），当时保留了「不在队列上」的旧实现（`onQueueAsync`），并在诚实边界里记了一笔。

现在这三个操作拆成「队列上检查并取出要操作的 VM → 等 VZ 完成（它自己回到队列）→ 队列上落状态」几段，`onQueueAsync` 删除。`onQueue` 是访问 Record 的唯一入口，闭包是同步的——**编译器不允许在里面 `await`**，以后不会再有人不小心把一段状态访问写到队列之外。

语义上的一点变化：两段之间别的操作可以插进来（比如 start 等待期间来了 destroy）。后一段重新按句柄取 Record，取不到就报「沙箱不存在」。

## 2. ThreadSanitizer

M46 的结论「这个场景不再崩」是靠压力测试得出的，诚实边界里写着没有用 TSan 跑过。本轮试了，可行：`swift build --sanitize=thread` 的二进制签上 virtualization entitlement 后可以正常起 VM。

`scripts/tsan-e2e.sh`：构建到 `.build/tsan`（gitignored）、签名、用 `BIN=… E2E_SKIP_BUILD=1` 让现有套件改用它，TSan 报告写到临时目录后汇总。判定只看 TSan 报告——TSan 下慢很多，套件里带时间阈值的断言会失败，那些只作参考。

**先确认它真的能发现问题**：把 `onQueue` 改回 M46 之前的实现，跑压力套件——TSan 报出 6 条（4 条 Swift access race、2 条 data race），栈正是 M46 崩溃的位置（`ptyPollSession` 的闭包对 `handleControlFrame`）。源码已还原。

**修复后的结果**（7 个套件：生命周期、daemon 并发、引导与取消、suspend / resume 持久化、exec 取消、终端压力、控制面丢失）：

```
合计竞争报告：0
```

套件自身在 TSan 下的失败共 4 项，逐项看过，全部是时间阈值（TSan 构建的 CLI 自身启动就要约 2 秒）：压力套件的吞吐量下限、Ctrl-C 的 4.5s 上限、控制面丢失后 exec 的 1.5s / 2s 上限。

## 3. TSan 顺带撞出的：debug 构建的 daemon 一 resume 就崩

第一次用 TSan 二进制跑 suspend / resume 用例时，daemon 崩了两次——不是竞争，是 `SnapshotStore.parseEnvelope` 里的

```swift
lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
```

`load(as:)` 要求指针按类型对齐，而 4 字节的 `Data` 用内联存储，不保证 4 字节对齐。未对齐的 load 是未定义行为：release 构建里碰巧能用；debug 构建有检查，直接 trap。是否撞上取决于栈布局——单元测试（debug）里一直碰巧对齐，TSan 构建里稳定不对齐。改为 `loadUnaligned(as:)`。全仓库只有这一处 `load(as:)`。

影响：用 debug 构建跑 daemon（`swift run dbx-poc daemon`）时 resume 可能崩溃并带走所有沙箱。release 构建（打包、E2E 用的都是它）不受影响。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `swift test` | 428/428 |
| `scripts/tsan-e2e.sh`（7 个真机套件，含 suspend / resume） | 竞争报告 0；先用变异确认过 TSan 能报出 M46 的那个竞争 |
| 全量 `e2e-all.sh`（本机现有 guest，屏幕解锁） | 27 个套件 0 失败，卫生五项 clean，退出码 0（完整通过） |
| 全量 `e2e-all.sh`（候选） | 27 个套件 0 失败，退出码 0 |

## 5. 诚实边界

- **本机 `macos/guest/` 与 `gui/dist/DeskBox.app` 仍是旧资产 / 旧构建**：你正在运行的那个 daemon（10 月的构建）里，M46 修掉的崩溃仍然存在。
- TSan 的「0 报告」只覆盖这 7 个套件走到的路径，而且只覆盖 `dbx-poc`（CLI 与 daemon）。GUI 进程没有用 TSan 跑过；broker 拉取、workspace 同步、GUI 的 Display 路径不在这 7 个套件里。
- `tsan-e2e.sh` 没有接进 `e2e-all.sh`（一遍约 6 分钟，且套件自身的结果在 TSan 下不可信）；需要时手动跑。
- start / stop / destroy 拆段之后，「两段之间插进别的操作」的时序没有专门的测试；现有的并发套件（并行 run / rm / shutdown）在其上通过。
- §3 的修复没有专门的单元测试：未对齐与否取决于栈布局，无法在测试里稳定构造；回归保护来自 TSan 套件里的 resume 用例（debug 构建，能稳定触发）。
- daemon 里除 runtime 之外的状态（会话表、pty 表）由各自的队列 / 锁保护，本轮没有改动；TSan 在上述套件里没有报出它们的问题。
