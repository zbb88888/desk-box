# Desk Box

[![CI](https://github.com/zbb88888/desk-box/actions/workflows/ci.yml/badge.svg)](https://github.com/zbb88888/desk-box/actions/workflows/ci.yml)
[![Release](https://github.com/zbb88888/desk-box/actions/workflows/release.yml/badge.svg)](https://github.com/zbb88888/desk-box/actions/workflows/release.yml)

用于运行 AI 编程 Agent 和不可信开发工作负载的桌面安全沙箱。

## 发布 quick-start

1. 在 [Releases](https://github.com/zbb88888/desk-box/releases) 中选择 tag（`v*-alpha*`）。
2. 下载 `guest-bundle-<tag>.tar.gz` 与 `checksums.txt`，先按 checksums 复核：`shasum -a 256 -c checksums.txt`。
3. 解包：`tar -xzf guest-bundle-<tag>.tar.gz -C /tmp/dbx-release`（发布的 channel.json/manifest.json/sbom.json/客资产都会在同目录）。
4. 本地验证：`cd macos && swift build && ./.build/debug/dbx-poc verify-channel /tmp/dbx-release/channel.json`（随后可再跑 `verify-sbom`）。
5. 运行演示：`./scripts/sign-and-run.sh /tmp/dbx-release/manifest.json --workspace /tmp/dbx-ws --broker-guest-url https://example.com`（需 CODESIGN_IDENTITY 环境变量且本机启用了 macOS hypervisor entitlement）。

如果你不使用发布 bundle，也可以克隆后按 [M6 CI 流程](docs/design/m6-ci-pipeline.md) 自行 build guest。

Desk Box 使用 OCI 镜像作为工作负载格式，以独立 Linux 虚拟机作为强隔离边界：Apple Silicon macOS 使用 Apple `Virtualization.framework`，Windows 11 Pro/Enterprise 使用 Hyper-V Generation 2。

## 设计文档

- [设计文档索引](docs/README.md)
- [桌面 VM 沙箱架构](docs/architecture/desktop-vm-sandbox.md)
- [技术选型与取舍](docs/research/technology-selection.md)
- [威胁模型与安全不变量](docs/security/threat-model.md)
- [最佳实践论证](docs/research/best-practice-assessment.md)
- [ADR-0001：桌面 VM 沙箱基线](docs/adr/0001-desktop-vm-sandbox-baseline.md)

## 开发落地

- [macOS 端开发指导](macos/README.md)
- [Windows 端开发指导](windows/README.md)
- [开源参考仓库](references/README.md)：clone 开源仓库到 `references/` 对照源码阅读，不入库。

实现以已接受的架构决策为准。只有通过威胁模型定义的跨平台发布门槛后，相关安全声明才视为已验证。
