# Desk Box

用于运行 AI 编程 Agent 和不可信开发工作负载的桌面安全沙箱。

Desk Box 使用 OCI 镜像作为工作负载格式，以独立 Linux 虚拟机作为强隔离边界：Apple Silicon macOS 使用 Apple `Virtualization.framework`，Windows 11 Pro/Enterprise 使用 Hyper-V Generation 2。

## 设计文档

- [设计文档索引](docs/README.md)
- [桌面 VM 沙箱架构](docs/architecture/desktop-vm-sandbox.md)
- [技术选型与取舍](docs/research/technology-selection.md)
- [威胁模型与安全不变量](docs/security/threat-model.md)
- [最佳实践论证](docs/research/best-practice-assessment.md)
- [ADR-0001：桌面 VM 沙箱基线](docs/adr/0001-desktop-vm-sandbox-baseline.md)

实现以已接受的架构决策为准。只有通过威胁模型定义的跨平台发布门槛后，相关安全声明才视为已验证。
