# M12：沙箱生命周期 CLI（run / ps / exec / stop / rm，daemon 模型）

状态：进行中；关联 `docs/design/two-layer-security-model.md`、INV-03/INV-11，`docs/design/m2-roadmap.md`。

## 1. 背景与定义

当前用户级四项操作仅被 `launch` 的一包（create→boot→dispatch→destroy）隐性覆盖：做不到在已有沙箱里再次 exec，也没有独立 stop/rm。本阶段交付私有 daemon 模型 —— `dbx-poc daemon` 常驻，`run/ps/exec/stop/rm` 跨进程直达守护，最终用户完整掌控生命周期。

## 2. 范围

- `dbx-poc daemon [--sock PATH]`：UNIX 域 socket 常驻服务，chmod 600、挂在 `~/Library/Application Support/DeskBox/dbxd.sock`；协议=JSON lines；主循环串行处理请求；
- `dbx-poc run --manifest p [--name n] [--workspace dir] [--oci-bundle b] [--allow-plaintext] [--allow-unsigned-manifest] [--release-keys f] [--memory-mib N] [--cpus N] [--cow-root d]`：
  触发 daemon 建沙箱；返回 sandboxID 与 running 状态；
- `dbx-poc ps`：列出 daemon 表的 live 沙箱（sandboxID/state/uptime…）；同时汇总 registry 条目（orphan 仅报告，不自动销毁）；
- `dbx-poc exec <sandbox-id> [--workload-kind k] [--cmd-json '' | cmd...]`：在已存活沙箱中 dispatch（含 OCI 判定）；
- `dbx-poc stop <sandbox-id>`：graceful stop（VZ stop）+ 后秀清 wreck；
- `dbx-poc rm <sandbox-id> [--force]`：destroy（registry + COW + in-memory handle清理）；running 的沙箱要求 `--force`（等同 stop+rm 一体）；
- 所有 CLI 子命令均可加 `--daemon-sock PATH` 覆盖默认路径。

## 3. 非范围（与 discipline）

- **不做 session daemonize 的公网鉴权**：本地 socket + chmod 600 是边界；
- 不做动态 PTY 交互式 attach（本阶段 exec 仅一次往返）；交互式 PTY 合起来仍可走 `launch --workspace`；
- 不实现 systemd 样式的自动 restart；daemon 不自动重呼 VM。
- 所有现有 fail-closed 默认（encrypted, signed manifest, digest check, policy）一如既向，本轮只是换 orchestration 入口。

## 4. 架构

```
┌──────────── 宿主 dbx-poc (CLI 会话) ─────────┐
│  run/ps/exec/stop/rm → UNIFORM socket JSON    │
└──────────────┬───────────────────────────────┘
               │  ~/Library/.../dbxd.sock
┌────────── 宿主 dbx-poc daemon (常驻) ─────────┐
│  DaemonServer (POSIX socket loop, 串行 queue) │
│  沙箱表: sandboxID→{VZRuntime,handle,record} │
│   VZRuntime(per 沙箱 queue) → machine → vsock│
│  sweeps on start / shutdown                   │
└───────────────────────────────────────────────┘
```

## 5. 验证

1. `daemon` 背景起，`run` 返回 sandboxID；`ps` 显示 running；
2. `exec <id>` 多次——独立 exec ID 兼容 control sequencer；
3. `exec` 两次同 id 互不干扰（VZ 控制会话无状态顺序号重置语义未被买回）；

- control 通道 sequencer 以单次 session 范围管理，daemon 每 sandboxID 自有追溯；
4. `stop <id>` 后 `ps` 无（或 stopped→removed 立即沉在 rm 后）；
5. `rm --force <id>` 结束并清 COW；registry 监察 sync 与 sweep pending 为零；
6. daemon crash / `--shutdown` 走 `sweep` 策略——daemon 记录 PID，重启时 `sweep` 提供 orphan 检测；
7. 恶意入参：不存在 sandbox / rm running (无 --force) / exec invalid mode / run 未签名 manifest（默认拒）——4 类均 fail-closed；
8. `swift test` 绿 + 双路真机（加密与 `exec` tunnel 打印） exit 0。

## 6. 危险点 / Mitigation

- ****VZ queue 纪律**：daemon 在单进程多实例中处理请求，但 VZRuntime 建模以多实例 per-Sandbox 覆盖；要么 daemon 多线程没有在串行 queue 中；要么 accept loop 主 thread 起处理请求 async（DispatchQueue concurrent）。
- daemon 死亡后的 orphan VM：VZ VM 属宿主进程，daemon 终止即 VM 终止；随后 sweeps 的 on-start 与 CLI `sweep` 子命令提供 orphan 评测。
- `run` 请求中的 manifest 路径必须本地严格欲誉，一切请求走统一 `makeSandboxCreateRequest`（INV-11 评审足迹保留）。

## 7. 进度同步

- [x] 计划文档
- [ ] 协定 + DaemonServer + CLI
- [ ] 真机双路径验证 + docs progress + 提交
## 进度（已验证）

- ✅ 计划文档
- ✅ DaemonServer（POSIX socket，JSON lines，串行 queue，chmod 600）
- ✅ CLI `daemon`/`run`/`ps`/`exec`/`stop`/`rm`/`shutdown`（全部真机通）
- ✅ Boot 流白名单：encrypted+signed default；`--allow-plaintext`/`--allow-unsigned-manifest` 仍要求显式 override；
- ✅ stop 保留 session；rm 失败防御：`rm` 运行态不带 --force 拒；destroys COW+registry+内存 state；
- ✅ graceful `shutdown` destroy 所有活跃沙箱；CLI `sweep` 仍属于安全持续路径；
- ✅ 并发：`run`两个沙箱互不影响，各自 control channel 独立；
- ✅ 验证流程：两次 `exec` 同 ID 互不影响；多次 run/ps/rm 循环无崩溃；
- ✅ `swift test` 全绿。
