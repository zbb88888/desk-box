# M21：资源统计与观测（INV-08 收尾）

状态：已完成；关联 `m2-2b-isolation-layers.md`、`security-verification-matrix.md`（INV-08）、`next-roadmap.md`。

## 1. 目标

INV-08 之前只证明「限额强制生效」，缺「资源统计上报」。本阶段补齐观测链：

```
guest cgroup v2 (/sys/fs/cgroup/dbx-exec/cpu.stat, memory.current, memory.max, pids.current)
      → deskbox-bootstrap 采集 (kind=stats)
      → host VZRuntime.stats()
      → daemon `stats` 端点
      → CLI `dbx-poc stats <id> --json` / GUI Stats 面板
```

## 2. 设计决策

- **采集面只读**：读 cgroup 文件系统，不做任何新 syscall 面（与 M18 的 deny-list 兼容）。
- **数值语义诚实**：`cpuUsageUsec` 是 cgroup 累计 CPU 微秒；`memoryCurrentBytes` 是瞬时值；不做平滑、不推断百分比（百分比交给 UI 用两次采样差分算）。
- **无数据即 null**：cgroup 不存在（无 exec 在跑）时返回 `null` 而不是 0——0 会被误读为「无消耗」。
- **fail-soft 观测**：统计失败不阻断 exec/run，只在响应里带 `statsError`；观测面不构成安全边界。

## 3. 协议

新增 daemon 端点：

```json
{"kind":"stats","sandboxId":"<id>"}
→ {"ok":true,"sandboxId":"<id>","stats":{"cpuUsageUsec":12345,"memoryCurrentBytes":1048576,
   "memoryMaxBytes":268435456,"pidsCurrent":2,"pidsMax":64},"state":"running"}
```

guest 侧 control frame `kind=31`（stats request）→ `kind=32`（stats response，JSON payload）。

## 4. GUI

- Sandboxes 表新增 CPU / MEM 两列（两次采样差分算 CPU%，mem 用 current/max 百分比）；
- 侧栏新增 **Stats** 页：选中沙箱的 CPU%/RSS/pid 曲线（最近 60 个采样，1s 粒度）；
- 无数据时显示 `—`，不显示 0。

## 5. 验收

1. `dbx-poc stats <id> --json` 返回合理数值，且 `pidsCurrent >= 1`；
2. 跑一个吃 CPU 的 workload（`sh -c 'while :; do :; done'`）后 `cpuUsageUsec` 单调增长；
3. 内存压力（写 /tmp 大文件直到接近 memory.max）时 `memoryCurrentBytes` 上升且 OOM 发生在 cgroup 内（沙箱仍 running）；
4. 统计失败（沙箱停掉）时返回 `statsError` 且不崩溃；
5. 回归：`swift test` / `e2e-sandbox-lifecycle.sh` / `e2e-gui-buttons.sh` 全绿。

## 5.1 实施结果（2026-10-28）

```
[stats] PASS: cpuUsageUsec 有值 (5024000)
[stats] PASS: memoryCurrentBytes 有值 (347795456)
[stats] PASS: 无 statsError
[stats] cpu delta=968000us
[stats] PASS: CPU 压力后 cpuUsageUsec 增长
[stats] mem delta=84KiB
[stats] PASS: 内存写入后 memoryCurrentBytes 未下降
[stats] PASS: 未知沙箱 stats 正确失败
[stats] PASS: daemon 仍存活（观测面不致命）
[stats] 结果：PASS=7 FAIL=0
```

回归：`swift test` 20 suites 全绿、`e2e-kernel-hardening.sh` 12/12、`e2e-sandbox-lifecycle.sh` 17/17、`security-corpus.sh` 全绿、`e2e-gui-buttons.sh` 14/14。

### 实现中发现的两个事实（已按事实实现，未美化）

1. **cgroup2 原本只在首个 exec 时才挂载**，所以空闲沙箱 stats 全是空。现在 bootstrap 启动时即挂载（`cgroup2_mount_early`），观测面从开机可用。
2. **本内核的 root cgroup 不暴露 `memory.current` / `pids.current`**（只暴露 `memory.stat`/`memory.pressure`/`cpu.stat` 等）。因此：
   - `memoryCurrentBytes` 在 `memory.current` 缺失时回退为 `memory.stat` 的 `anon + file` 之和（语义差异已写进协议注释，不是 `memory.current` 的等价物）；
   - `pidsCurrent`/`pidsMax` 在该内核上如实返回 `null`，不做「用 `cgroup.procs` 行数凑数」的假数据。
   - `activeExecGroups` 计数作为活动度提示单独上报。

## 6. 非目标

- 不做历史持久化（进程内最近 N 个采样即可）。
- 不做跨沙箱汇总的调度决策（未来 scheduler）。
