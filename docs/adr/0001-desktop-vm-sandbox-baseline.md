# ADR 0001：采用桌面原生 VM 沙箱基线

状态：已接受
日期：2026-10-23

## 背景

Desk Box 需要在 Apple Silicon macOS 和 Windows 11 Pro/Enterprise 上运行可能恶意的 Claude Code、Codex、dsh、MCP、OCI 镜像和 Dockerfile。产品优先保护宿主凭据、文件、其他工作区和网络边界，同时需要让普通用户以工作区和服务授权表达意图，而不是配置容器与网络基础设施。

候选方案覆盖宿主容器、Docker Desktop、OpenSandbox、Kata Containers、E2B/Firecracker、gVisor、Wasmer/WASI、WSL2、QEMU 与平台原生 VM。它们处于不同抽象层，不能作为同类完整产品直接比较。

## 决策

采用 Kata-like、桌面原生、VM-backed 架构：

- macOS 使用 Apple `Virtualization.framework`；
- Windows 使用 Hyper-V Generation 2；
- 默认一台 VM 对应一个工作区和凭据授权域，高保障模式一台 VM 对应一个 Agent；
- OCI image 是唯一外部工作负载格式，但不作为安全边界；
- Dockerfile 由独立 Builder VM 内的 BuildKit 构建；
- Guest 内使用 `containerd + runc` 执行 OCI workload；
- 固定上游版本的小型 OpenSandbox `execd` fork 提供命令、PTY、文件、会话与指标；
- 宿主 Controller 自有 lifecycle contract、策略和审计；
- 工作区默认快照式导入、确认式导出到 guest 私有盘，不做双向实时同步；
- 长期凭据只保存在 macOS Keychain 或 Windows Credential Manager，由宿主 Broker 在已授权最终请求中注入；
- 网络默认拒绝，MCP 只暴露窄 capability；
- 产品不依赖 Docker Desktop、Kubernetes、WSL2、宿主 Docker daemon 或 `docker.sock`。

## 原因

1. 恶意原生工作负载需要独立 guest kernel，单独的容器边界不够。
2. VZ 与 Hyper-V 是目标平台受支持的原生强隔离机制，攻击面和产品集成优于默认携带通用 QEMU。
3. OCI 与 BuildKit 提供必要生态兼容，但其 metadata 与执行不能决定宿主权限。
4. `containerd + runc` 放在 VM 内可以复用成熟 OCI 行为，同时把 container escape 限制在 guest。
5. OpenSandbox `execd` 的数据面功能接近需求，但完整控制面、Docker/Kubernetes backend 和 guest-side Credential Vault 不符合本产品边界。
6. 宿主 Broker 是让长期秘密不进入不可信 VM 的直接实现。
7. Kata 的分层是合适参考，但移植其 Linux/KVM/Kubernetes runtime 会形成高成本长期 fork。

## 后果

正面后果：

- 安全声明建立在独立 VM 和宿主强制策略上。
- OCI 与 Dockerfile 可用，但不暴露高权限宿主 daemon。
- Guest 或 container 失陷后不应直接获得长期凭据。
- macOS 与 Windows 可以共享产品契约与 guest 行为。
- 用户只需理解任务、工作区和服务授权。

负面后果：

- 必须维护 VZ 与 Hyper-V 两套 adapter 及一致性测试。
- 必须实现安全 OCI 解包、Workspace Sync、Broker、bootstrap、snapshot 与 crash cleanup。
- Execd fork 带来持续漏洞跟踪、许可证、SBOM 和 rebase 责任。
- 一授权域一 VM 的资源占用高于共享容器。
- 宿主 Broker 的网络与协议正确性成为高风险组件。

## 明确拒绝的方案

- **宿主 Docker 或共享容器作为强边界**：共享 kernel，daemon socket 权限过大。
- **Docker Desktop 作为产品依赖**：共享 VM、外部安装与策略不可控。
- **OpenSandbox 全栈直接采用**：现有 backend 面向 Docker/Kubernetes，Credential Vault 让真实 secret 进入 guest 信任域。
- **Kata Containers runtime 直接移植**：目标后端与桌面产品模型不匹配。
- **E2B/Firecracker 作为本地 runtime**：依赖 Linux/KVM 与云控制面。
- **WSL2 作为强隔离边界**：共享 utility VM kernel，不是一授权域一 guest kernel。
- **gVisor 或 Wasm 作为首版主 runtime**：不能替代目标平台上的通用 Linux VM 边界。
- **QEMU 作为默认统一 backend**：设备面、打包和维护成本高于原生 API。

## 延期决策

- 是否为部分 workload 增加 gVisor 二级隔离。
- 是否提供 Wasm-only MCP/plugin profile。
- 是否提供 Windows Home 的低保障 WSL2 兼容模式。
- 是否在明确兼容模式中支持跨架构模拟。
- 是否在证据证明安全收益后引入 warm pool 或更激进 snapshot 恢复。

这些选项不能静默改变当前保障等级。

## 验证条件

本 ADR 只有在以下条件满足后才能转化为发布安全声明：

- 威胁模型十项安全不变量全部有通过的自动化验收；
- macOS 与 Windows backend 分别通过 contract 和对抗测试；
- Canary secret 无法从 guest、日志、COW、snapshot 或构建缓存恢复；
- 网络、路径、控制通道、更新和清理在故障时 fail closed；
- 供应链签名、SBOM、provenance、漏洞响应和 downgrade protection 就绪；
- 独立安全评估的高危问题全部关闭。

## 相关文档

- [总体架构](../architecture/desktop-vm-sandbox.md)
- [技术选型与横向对标](../research/technology-selection.md)
- [威胁模型](../security/threat-model.md)
- [最佳实践符合性评估](../research/best-practice-assessment.md)
