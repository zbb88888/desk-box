# Desk Box 设计文档

本目录记录 Desk Box 的首版架构基线、技术选型、安全契约和决策依据。

## 阅读顺序

1. [桌面 VM 沙箱架构](architecture/desktop-vm-sandbox.md)：描述实现拓扑、信任边界、宿主与来宾组件、生命周期和交付阶段。
2. [技术选型与取舍](research/technology-selection.md)：横向比较参考项目，解释其底层引擎以及采用、借鉴、延期或舍弃的原因。
3. [威胁模型与安全不变量](security/threat-model.md)：定义攻击者、受保护资产、安全不变量、控制措施和阻断发布的测试。
4. [最佳实践论证](research/best-practice-assessment.md)：说明该架构为何符合桌面沙箱最佳实践、为何不照搬云端方案，以及仍需哪些证据。
5. [ADR-0001](adr/0001-desktop-vm-sandbox-baseline.md)：简明记录已接受的架构决策。

## 一句话决策

Desk Box 使用 OCI 镜像作为工作负载格式，以独立 Linux VM 作为强隔离边界：Apple Silicon macOS 使用 Apple `Virtualization.framework`，Windows 11 Pro/Enterprise 使用 Hyper-V Generation 2。来宾内运行 `containerd`、`runc` 和固定版本的小型 OpenSandbox `execd` fork；可信宿主 Broker 负责生命周期、工作区同步、出口策略和长期凭据。产品不依赖 Docker Desktop、Kubernetes、WSL2 或宿主 Docker daemon。

## 文档状态

架构方案和 ADR 已作为实现基线接受。安全属性在威胁模型定义的跨平台发布门槛全部通过前，只能称为“按设计满足”，不能称为“已验证安全”。
