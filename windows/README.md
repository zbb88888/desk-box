# Desk Box — Windows（Hyper-V）

状态：骨架 + 合约锁定（M2-4a）。**UNVERIFIED（尚未于真机验证）**：当前主要开发工作站为 Apple Silicon macOS，
真机验证需在任意 Windows 11 Pro/Enterprise 或 Windows Server 宿主机执行（见 §3 出样脚本）。

## 子阶段

- **M2-4a（本轮）**：共享 wire/行为合约 macOS 侧锁定（`macos/Tests/ConformanceTests/WireContractLockTests.swift`），
  Windows 侧 minimal skeleton（C# net8.0 + HCS/HVSock）准备；不作为已交付验证；
- **M2-4b**：Windows guest agent（Linux VM 内 .NET 服务）+ 启动/连接/Atl验证 + 凭据不入 sandbox 宿主；
- **M2-4c**：全验证（boot/exec/destroy + broker + INV-01/07 在 Windows 复核）并把共享合约编入日常回归。

## 目录

- `host/DeskBoxHyperV/`：Windows 宿主机适配骨架（HCS/PowerShell + HVSock + wire codecs）；
- `guest/`：Windows guest agent 骨架（与 `macos/scripts/guest-bootstrap.c` 的通讯语义保持一致）。

## 构建前提
- .NET SDK 8.0+（Windows）；Hyper-V / HCS role enabled；允许创建 VM；
- macOS 侧协议的 wire 帧/字段名由 lock 单测体内（WireContractLockTests）；
- 默认交付以 macOS 为主；当 Windows phase 上线时按同一批 conformance 样本证据接入。