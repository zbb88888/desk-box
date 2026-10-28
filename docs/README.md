# Desk Box 设计文档

本目录记录 Desk Box 的首版架构基线、技术选型、安全契约和决策依据。

## 阅读顺序

1. [桌面 VM 沙箱架构](architecture/desktop-vm-sandbox.md)：描述实现拓扑、信任边界、宿主与来宾组件、生命周期和交付阶段。
2. [技术选型与取舍](research/technology-selection.md)：横向比较参考项目，解释其底层引擎以及采用、借鉴、延期或舍弃的原因。
3. [威胁模型与安全不变量](security/threat-model.md)：定义攻击者、受保护资产、安全不变量、控制措施和阻断发布的测试。
4. [最佳实践论证](research/best-practice-assessment.md)：说明该架构为何符合桌面沙箱最佳实践、为何不照搬云端方案，以及仍需哪些证据。
5. [ADR-0001](adr/0001-desktop-vm-sandbox-baseline.md)：简明记录已接受的架构决策。
6. [ADR-0002](adr/0002-macos-phase1-contract-and-vz-slice.md)：macOS Phase 1 契约与 VZ 垂直切片实现状态。

## 实施级设计

- [Host 与 Guest 双层统一安全体系](design/two-layer-security-model.md)：定义两层共用的身份、授权、资源、决策与审计语义，以及 Host、VM 边界、Guest 和跨边界协议的责任。
- [网络与凭据 Broker](design/network-credential-broker.md)：定义 Broker-only 出口拓扑、凭据边界、协议兼容矩阵和 POC 门槛。
- [控制通道与启动完整性](design/control-channel-security.md)：定义宿主/来宾身份绑定、握手、重放防护、版本和 snapshot 规则。
- [M1-2 控制通道 TLS 1.3 双向认证升级](design/m1-tls-channel-upgrade.md)：控制通道加密升级计划（ephemeral 密钥协商、session 绑定、libsodium guest、默认开启加密、fail-closed）。
- [M1-4 Guest PTY 支撑](design/m1-4-pty-support.md)：交互式 Agent 场景所需的 pseudo-TTY 分配、流式 I/O、resize 与关闭的设计与实现参考。
- [M1-5 Guest Manifest 签名与防降级](design/m1-5-manifest-signing.md)：Ed25519 信任根、canonical payload、显式允许列表与 `guestAssetVersion` 单调最低版本（fail-closed）。
- [M2 路线](design/m2-roadmap.md)：workspace sync → containerd/runc → Broker → Windows 后段的推进计划与审核要求。
- [M2-1 Workspace Sync](design/m2-1-workspace-sync.md)：显式授权 workspace 快照经加密 channel 推送，路径/符号链接/限额 fail-closed 与 guest 侧 SHA-256 终验。
- [M2-2 OCI workload 语义与策略门禁](design/m2-2-oci-workload.md)：OCI config.json 白名单子集、扩权字段 fail-closed 拒收、guest exec 受限 env/cwd 实施。
- [M2-3 网络与凭据 Broker](design/m2-3-network-credential-broker.md)：默认零网络下的宿主 broker、outbound policy allowlist、凭据不进 worker 与审计决策链。
- [M2-3b guest→host 在线 broker 通行](design/m2-3b-broker-online-channel.md)：guest 工作负载经 AF_UNIX + 加密 record channel 请求宿主 broker，响应落位 inbound-only。
- [M2-2b namespaces + cgroup v2](design/m2-2b-isolation-layers.md)：exec 子进程 kernel namespace 隔离 + cgroup v2 cpu/memory/pids 限额，fail-closed 拒绝降级。
- [M2-4 Windows Hyper-V](design/m2-4-windows-hyperv.md)：Windows phase 计划与共享合约锁定；真机验证在 Windows 宿主机进行，标注 UNVERIFIED 的环节不宣称达成。
- [M3 供应链与可重构建](design/m3-supply-chain.md)：pinned inputs + guest SBOM + release 签名；manifest 连同 sbom 一起掌握，verify-sbom 本地复核 fail-closed。
- [M4 fuzz 与 parser 强化](design/m4-fuzz-hardening.md)：ControlFrame/JSON/OCI/guest C 解析面的 ASAN+UBSAN 与 corpus 回归。
- [M5 Release 签名链](design/m5-release-signing-chain.md)：release-keys.json + key rotation/revocation，revoked 立即拒收。
- [M6 CI pipeline](design/m6-ci-pipeline.md)：GitHub Actions：swift test + fuzz + guest build + 负人 regression + evidence。
- [M7 Release 发布渠道骨架](design/m7-release-channel.md)：channel.json + 多 key 声明 + minGuestAssetVersionFloor + publish/verify-channel CLI。
- [M8 CI 发布管道](design/m8-ci-release-pipeline.md)：GitHub Actions 上 tag 触发 M7 发布 pipeline 生成 release assets。
- [M9 发布 bundle](design/m9-release-bundle.md)：guest-bundle-<tag>.tar.gz + checksums.txt + README quick-start。
- [M10 可复构建](design/m10-reproducible-build.md)：SOURCE_DATE_EPOCH 驱动 bit-for-bit 可复构建 + CI 双跑一致性。
- [M11 幂等发布管道](design/m11-idempotent-release.md)：commit+key 固定时 build→sign→publish 输出 byte-identical。
- [M12 沙箱生命周期 CLI](design/m12-sandbox-lifecycle-cli.md)：daemon 模型的 run/ps/exec/stop/rm。
- [M13 macOS GUI](design/m13-gui-macos.md)：SwiftUI + AppKit 的 Docker Desktop 型管理面板。
- [M14 Guest Display](design/m14-guest-display.md)：virtio-gpu spike 实证结论与自定义 kernel 决策点。
- [M14c GUI Display](design/m14c-gui-display.md)：virtio-gpu framebuffer → NSView 串 SwiftUI 窗口。
- [M15 GUI Polish](design/m15-gui-polish.md)：drag-drop workspace / Login Item / terminal interactivity。
- [M16 Docker Parity GUI](design/m16-docker-parity-gui.md)：sandboxes表/restart/consoleLog/manifests面板/sidebar导航。
- [M17 Menubar Polish](design/m17-menubar-polish.md)：菜单栏沙箱动作、@AppStorage 偏好、daemon autostart。
- [M18 Guest 内核纵深](design/m18-guest-kernel-hardening.md)：Landlock 路径白名单 + seccomp-bpf deny-list，fail-closed 串联 exec 硬化。
- [M19 安全证据 corpus](design/m19-security-corpora.md)：INV-03/04/05/06 四套 corpus + 证据 JSON + CI job。
- [M20 生命周期持久化](design/m20-lifecycle-persistence.md)：VZ suspend/resume + 快照 AEAD 信封 + 「不复活权限」三道闸。
- [M21 资源统计](design/m21-resource-stats.md)：guest cgroup v2 → daemon `stats` → CLI/GUI Stats 面板（CPU%/内存/PIDs）。
- [后续开发计划（M18 起）](design/next-roadmap.md)：M18 guest 内核纵深 → M19 安全证据 corpus → M21 统计 → M20 快照/不复活 → M22 发布 v0.2.0 → M23 多凭据域。
- [平台能力矩阵](design/platform-capability-matrix.md)：列出 VZ 与 Hyper-V 必须在真实目标系统验证的能力和版本冻结产物。
- [工作区同步](design/workspace-sync.md)：定义快照式导入、暂存式导出、冲突、Git 和路径安全语义。
- [安全验证追踪矩阵](security/security-verification-matrix.md)：把十项安全不变量映射到组件、测试、证据和责任角色。

## 开发落地

- [macOS 端开发指导](../macos/README.md)：VZ adapter 范围、前置条件与 POC 顺序。
- [Windows 端开发指导](../windows/README.md)：Hyper-V Gen2 adapter 范围、前置条件与 POC 顺序。
- [开源参考仓库](../references/README.md)：设计文档引用的开源项目本地 clone 到 `references/`，只读对照，不入库。

## 一句话决策

Desk Box 使用 OCI 镜像作为工作负载格式，以独立 Linux VM 作为强隔离边界：Apple Silicon macOS 使用 Apple `Virtualization.framework`，Windows 11 Pro/Enterprise 使用 Hyper-V Generation 2。来宾内运行 `containerd`、`runc` 和固定版本的小型 OpenSandbox `execd` fork；可信宿主 Broker 负责生命周期、工作区同步、出口策略和长期凭据。产品不依赖 Docker Desktop、Kubernetes、WSL2 或宿主 Docker daemon。

## 文档状态

架构方案和 ADR 已作为实现基线接受。安全属性在威胁模型定义的跨平台发布门槛全部通过前，只能称为“按设计满足”，不能称为“已验证安全”。
