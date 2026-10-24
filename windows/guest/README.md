# Desk Box Windows guest agent（M2-4a skeleton）

状态：骨架（UNVERIFIED 待 Windows 真机注入）；参考实现：`macos/scripts/guest-bootstrap.c`。

## 交付内容要求
- 与 macOS guest-bootstrap.c 保持同样的通讯语义：X25519 ephemeral + HKDF-SHA256 + ChaChaPoly AEAD record channel；
- 在 Hyper-V Linux VM 内作为 PID1 / systemd service 运行（硬化场景推荐前者，与 macOS 一致）；
- 支持 bootstrap hello → 加密 record channel → exec / ws sync / brokerFetch 等同一消息语义；
- 无 NIC 的默认零网络策略（与 macOS 安全模型一致）；
- 验证门槛：Windows 真机演示（boot/exec/destroy + broker 组合）并在安全验证矩阵对应项提供现场 PDF。