# Desk Box Windows 端开发指导

状态：Phase 1 前的目录基线
对应后端：Hyper-V Generation 2，Windows 11 Pro/Enterprise amd64

## 范围

本目录承载 Windows 宿主侧实现：

- Hyper-V Adapter（VM 生命周期、differencing VHDX、HVSock、vSwitch/Firewall、checkpoint）；
- Sandbox Controller 的 Windows 部分；
- Workspace Sync 的 NTFS/ADS/reparse point 侧；
- Credential/Network Broker 的 Credential Manager/DPAPI 侧与 MCP Gateway 的平台集成。

Guest Linux 镜像构建链与 `execd` fork 为跨平台共享，不放本目录。首版直接管理 Hyper-V VM，不走 HCS LCOW，也不依赖 WSL2、Docker Desktop 或宿主 `docker.sock`。

设计契约（先读）：

- [总体架构](../docs/architecture/desktop-vm-sandbox.md) §6.4
- [平台能力矩阵](../docs/design/platform-capability-matrix.md) §5（Windows POC 清单）
- [网络与凭据 Broker](../docs/design/network-credential-broker.md) §4.1（Credential Manager 2560 字节约束与 DPAPI 对策）
- [安全验证追踪矩阵](../docs/security/security-verification-matrix.md)

## 开发前置条件

- Windows 11 Pro/Enterprise；Windows Home 明确不支持（平台矩阵 §2）。
- 启用 Hyper-V 功能需要管理员并可重启；装机或首启时必须给出可理解的失败原因，不得静默降级。
- 最新 Visual Studio 或 Windows SDK；service 组件签名、安装与权限边界在 Phase 1 决定，参照平台矩阵 §5 POC 6 的最小权限结论。
- 语言与工程结构在 Phase 1 `SandboxRuntime` 接口冻结时决定；在此之前本目录不预建代码骨架。

## POC 顺序（对应平台矩阵 §5，全部在真机执行）

1. 在干净 Windows 11 Pro 与 Enterprise 上启用并检测 Hyper-V，不依赖 WSL2 或 Docker Desktop。
2. 验证 Gen2 Linux guest、UEFI 与适用 Secure Boot 模板；自编译 kernel 的密钥/MOK 流程必须记录，不支持的组合明确禁用。
3. 验证 HVSock service ID 与具体 VM identity 绑定，覆盖并发 VM 串线测试（→ 控制通道设计 §3–5）。
4. 验证基础 VHDX、differencing VHDX 父链、配额与异常删除恢复。
5. 验证 vSwitch/NAT/Windows Firewall 不产生绕过 Broker 的出口（→ Broker 设计 §9 POC 1）。
6. 明确普通用户、提升进程和 Windows service 的最小权限边界。
7. 验证 Credential Manager 2560 字节 blob 约束下各类长期凭据（含 RSA 私钥）的存储方案，如 DPAPI 加密文件。
8. 验证 checkpoint/save/restore 的实际语义和旧 session 失效；不满足则首版关闭。
9. 验证服务崩溃、系统重启、休眠和更新后的 VM/VHDX 清理。

## 验收门槛

Windows 侧发布前必须通过[安全验证追踪矩阵](../docs/security/security-verification-matrix.md)中 INV-01/03/05/07/08/10 的 Windows 证据项，以及架构 §11 的发布门槛；macOS 结论不能替 Windows 背书（矩阵 §6）。

## 参考源码

开源参考仓库 clone 到 `../references/`（只读、不入库），清单见 [references/README.md](../references/README.md)。重点：microsoft/hcsshim（VM 管理调用面，不照搬 LCOW）与 linuxkit/virtsock（HVSock）。
