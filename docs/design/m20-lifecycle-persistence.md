# M20：生命周期持久化与「不复活权限」（INV-10）

状态：已完成（M20a + M20b）；关联 `security-verification-matrix.md`（INV-10）、`m5-release-signing-chain.md`、`m7-release-channel.md`、`next-roadmap.md`。

## 1. 目标

INV-10 是矩阵中最后一个 `未实现`：**更新、持久化和销毁不得复活权限**。本阶段交付：

1. **快照（suspend/resume）**：VZ `saveMachineStateTo` / `restoreMachineStateFrom` 接入 daemon；
2. **快照加密信封**：磁盘上的快照必须是 AEAD 密文，且 AAD 绑定 `sandboxID + manifestDigest + guestAssetVersion + keyID + bootID`；
3. **旧快照拒绝恢复**：`guestAssetVersion` 低于当前 floor、或 `manifestDigest` 不匹配、或签名 key 已 revoked → 恢复失败（fail-closed）；
4. **销毁零残留**：`rm` / `shutdown` / daemon 崩溃后，COW、快照、socket、临时私盘全部清理；
5. **故障注入矩阵**：在 create/boot/handshake/run/suspend/resume/stop/destroy 每个阶段杀进程，验证不留可复活状态。

## 2. 设计决策

### 2.1 快照密钥从哪来

guest 的会话密钥在 suspend 后已不存在（VM 已冻结/关闭）。所以不能用 X25519 会话密钥。方案：

- 宿主本地 **snapshot key**：32 字节随机，存 `~/Library/Application Support/DeskBox/snapshot.key`（0600）；
- 每个快照用 `ChaChaPoly` + 每文件随机 nonce，AAD = 规范化 metadata JSON；
- 好处：机密性（磁盘上是密文）+ 完整性/绑定（改 metadata 或换文件都解不开）；
- 局限（诚实标注）：同一宿主同一用户可解开自己所有快照——这是「本机用户级」机密性，不是抵抗宿主管理员的方案。真正的跨机迁移需要 guest 参与重新协商密钥，属未来工作。

### 2.2 快照文件布局

```
magic  "DBXSNAP1"        8 bytes
metaLen uint32 BE        4 bytes
metaJSON                 metaLen bytes   (也是 AEAD 的 AAD)
nonce                    12 bytes
ciphertext+tag           rest            (ChaChaPoly sealed box)
```

`metaJSON` 字段（canonical，键排序固定）：

```json
{"schema":"deskbox-snapshot/v1","sandboxID":"...","bootID":"...","manifestDigest":"sha256:...",
 "guestAssetVersion":1,"keyID":"...","createdAtUtc":"...","hostBuild":"<os version>",
 "payloadSha256":"<密文 sha256，便于审计>"}
```

### 2.3 「不复活权限」的三道闸

恢复前依次检查，任一失败即拒绝（且**不删除**快照——保留取证，但标记为 unusable）：

| 闸 | 检查 | 拒绝原因 |
| --- | --- | --- |
| 1 | `meta.manifestDigest` == 恢复所用 manifest 的 `manifestDigest` | `snapshotManifestMismatch` |
| 2 | `meta.guestAssetVersion` >= 当前 `minGuestAssetVersionFloor` 且 == 当前资产版本 | `snapshotAssetVersionStale` |
| 3 | `meta.keyID` 在 release-keys.json 中不是 `revoked`（未知 key 也拒） | `snapshotKeyRevoked` |

另外 VZ 自身会拒绝：不同 macOS 版本、不同硬件、被截断的文件（`VZErrorRestore`）。我们不依赖它，但不掩盖它。

### 2.4 suspend 语义

- `machine.pause()` → `saveMachineStateTo(tmp)` → 加密写入快照路径 → 删除 tmp → 销毁 VZ machine 对象（保持 COW 盘）→ lifecycle `.suspended`；
- **不**删除 COW：resume 需要同一块盘；
- `ps` 里状态为 `suspended`，可执行 `resume` 或 `rm`。

### 2.5 resume 语义

- 用**记录的原始 configuration** 重建 `VZVirtualMachine`（store 里保存 create 时的 request + cow lease）；
- 解密快照到 tmp → `restoreMachineStateFrom(tmp)` → `machine.resume()`（恢复后处于 paused）→ 重新握手（guest 侧 bootstrap 仍在 sleep 中被冻结，恢复后继续会话；若会话已死则走完整 bootstrap）→ lifecycle `.running`。

## 3. 实施拆分

- **M20a（本阶段）**：SnapshotStore（信封 + 三道闸）、VZRuntime.suspend/resume、daemon `suspend|resume`、CLI、单测 + 真机 e2e。
- **M20b（后续）**：故障注入矩阵 + 销毁残留断言 + 恢复后权限不复活的行为测试（恢复后 exec 仍无人提权）。

## 4. 验收

1. `suspend` 后快照文件是密文（`strings` 找不到 guest 内容）；
2. `resume` 后 `exec id -u` 仍为 65534，且 workspace 文件仍在（状态确实恢复了）；
3. 篡改 `metaJSON` → 解密失败（AEAD）；
4. 改 `manifestDigest` / 降低 `guestAssetVersion` / revoked key → 恢复被拒且原因码正确；
5. `rm` 后快照文件不存在，`sweep` 归零；
6. 回归：`swift test` / 4 个 e2e / corpus 全绿。

## 4.1 实施结果（2026-10-28，Apple Silicon + VZ，macOS 14+ API）

```
[m20] PASS: 前置 exec 正常（uid=65534）
[m20] PASS: suspend 成功
[m20] PASS: ps 显示 suspended
[m20] PASS: 快照文件已生成
[m20] PASS: 快照为密文（无明文标记）
[m20] PASS: 快照权限 0600
[m20] PASS: 篡改快照被拒（AEAD 完整性）
[m20] PASS: 原始快照可恢复
[m20] PASS: 恢复后状态 running
[m20] PASS: 恢复后状态保持且 uid 仍 65534（权限未复活）
[m20] PASS: 二次 suspend 成功
[m20] PASS: 二次 resume 成功
[m20] PASS: rm 后快照已删除
[m20] PASS: rm 后 ps 为空
[m20] PASS: 未知沙箱 suspend 拒绝
[m20] 结果：PASS=15 FAIL=0
```

实测快照约 124–130 MiB（VM 内存镜像），`0600`，`strings`/`grep` 找不到 guest 明文标记。

### 实施中踩到并修掉的四个真实问题

1. **VZ API 必须在 VM 自己的 queue 上调用**：`pause`/`saveMachineStateTo`/`restoreMachineStateFrom` 内部有 `dispatch_assert_queue`，从 Swift concurrency 线程调用会直接 `SIGTRAP`（EXC_BREAKPOINT）。已统一走 `vzOperation` 桥接（`queue.async` 内发起，completion 里 resume continuation）。
2. **restore 要求目标 machine 处于 stopped**：不能复用已暂停的实例，必须用同一 `VZVirtualMachineConfiguration` 重建一台；因此 `Record` 现在保存 `configuration`。
3. **restore 会重置 vsock 连接**：宿主的 control socket 变为死句柄，guest 侧的 `poll` 只会拿到 `POLLHUP`。原先 guest 只处理 `POLLIN`，会永久 poll 死 fd 而永不重连。已修：guest 处理 `POLLHUP/POLLERR/POLLNVAL` 后重连并重发 hello（同一 boot/nonce）。
4. **状态机顺序**：原实现先转 `.resuming` 再验闸，导致「篡改快照被拒」之后沙箱卡在 `.resuming` 无法重试。现在闸门与解密全部在状态变更之前完成，任何失败都保持 `.suspended`（可重试、可 `rm`）。

### 与设计文档的差异（诚实标注）

- §2.5 写的是「resume 后沿用同一会话」。实测不成立：VZ restore 重置 vsock，**必须重新握手**。因此 resume 后拿到的是**新 proof**（同一 bootID/nonce 绑定未变），而不是复用旧 proof。daemon 的 `resume` 会等待 `running` 才返回（与 `run` 共用 `waitForRunning`）。
- PTY 会话不跨 suspend/resume：suspend 时主动丢弃活动 pty 表项。

## 4.2 M20b 故障注入矩阵（INV-10 收尾）

`scripts/e2e-fault-injection.sh`：在 run / exec / suspend 三个阶段 `kill -9` daemon，断言：

```
[inject] PASS: after-run: 崩溃后 sweep 收敛（首轮发现 1，次轮 0，快照 0）
[inject] PASS: after-run: 重启后不复活旧沙箱
[inject] PASS: after-exec: 崩溃后 sweep 收敛（首轮发现 1，次轮 0，快照 0）
[inject] PASS: after-exec: 重启后不复活旧沙箱
[inject] PASS: after-suspend: 崩溃后 sweep 收敛（首轮发现 1，次轮 0，快照 0）
[inject] PASS: after-suspend: 重启后不复活旧沙箱
[inject] 结果：PASS=6 FAIL=0
```

### M20b 修掉的两个真实缺口

1. **快照文件不参与 sweep**：`SandboxRegistry.sweep()` 只清理 COW clone，崩溃后会留下 `.snap` 文件——而有快照就能 restore，这正是 INV-10 要阻断的「复活」路径。现在 `VZRuntime.sweepOrphans()` 额外调用 `removeOrphanSnapshots(keeping:)`，删除无活跃注册项的快照与崩溃残留的 `tmp-*.vzstate`。
2. **CLI `sweep` 绕过 runtime**：原先直接 `SandboxRegistry(root:).sweep()`，因此永远不清快照。已改为经 `VZRuntime.sweepOrphans()`。

## 5. 非目标

- 跨机迁移快照（需要 guest 参与的重协商）。
- 增量快照 / 快照压缩。
- 「快照恢复后仍保持原 PTY 会话」——恢复后 PTY 会话不保证存活，文档写明。
