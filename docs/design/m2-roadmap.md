# M2 路线：workspace sync、containerd/runc、Broker、Windows 后段

状态：进行中（M2-1 为首个切片）；关联 `docs/architecture/desktop-vm-sandbox.md` §3、
`docs/security/security-verification-matrix.md`（INV-04/05/06/09）。

## 目标

将 macOS 平台侧从“沙箱基座”（M0/M1）推向生产级运行时所需的数据面与调度能力，同时启用 Windows 平台首次联通。
全部能力遵守不动量不变量：VM 硬隔离（M0）、fail-closed（M1）、默认加密控制通道（M1-2）、最小授权（M1-5）。

## 子阶段

| 阶段 | 范围 | 关键交付物 | 关联 INV |
|------|------|------------|----------|
| **M2-1 Workspace Sync (macOS)** | 将显式授权的 workspace 类型集安全推送到 guest（path allowlist、symlink 压缩、大小限额、index-manifest + 行人鉴证） | `WorkspaceSyncService`、CLI `--workspace`、guest 接收器 + 实现报告 | INV-05 |
| **M2-2 containerd/runc 多 workload** | guest 内使用 containerd/runc 运行 OCI bundle；善熟 workload 走 sandbox 是独立 container 单位 | image puller、runc bundle 生成器、cgroup v2 资源划分完成者（完成 INV-08 剩余部分） | INV-06, INV-08 |
| **M2-3 Network/Credential Broker** | 无网卡默认下的网络面上限：全部外访通过宿主 Broker + 凭据强隔离只限虚空走 | Broker proxy、bearer/cookie 映射表、grant-scoped 凭据代护 | INV-03, INV-04 |
| **M2-4 Windows 后段** | Hyper-V backend 首次联通（boot/exec/destroy 可控） | `DeskBoxHyperV` adapter、HVSock、guest agent（复用 Linux contract 的 Windows 版本） | INV-01, INV-07 |

## 可靠进展审计点

每个子阶段都要：
1. 优先写 design doc 及实施（如本文档目录对应 `m2-N-*` 设计）；
2. 单元测试 + 双双路径（默认加密 / `--allow-plaintext`）真机验证 exit=0；
3. 更新 `docs/security/security-verification-matrix.md` 对应 INV 状态；
4. conventional commit + push origin/main。

## 范围外（公开声明）

- SBOM/发布签名链：M2-1 交付后介入调度器前的三步建设；
- 多平台调度策略控制面高可用；当前严格单宿主机开发工作站；
- macOS guest (Virtualization.framework 的 macOS guest) 不在此阶段为能。
