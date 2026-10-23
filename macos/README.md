# Desk Box macOS 端开发指导

状态：Phase 1 前的目录基线
对应后端：Apple `Virtualization.framework`（VZ），Apple Silicon arm64

## 范围

本目录承载 macOS 宿主侧实现：

- VZ Adapter（VM 生命周期、COW、VZ Socket、网络、suspend/resume）；
- Sandbox Controller 的 macOS 部分；
- Workspace Sync 的 APFS 侧；
- Credential/Network Broker 的 Keychain 侧与 MCP Gateway 的平台集成。

Guest Linux 镜像构建链与 `execd` fork 为跨平台共享，不放本目录。

设计契约（先读）：

- [总体架构](../docs/architecture/desktop-vm-sandbox.md) §6.3
- [平台能力矩阵](../docs/design/platform-capability-matrix.md) §4（macOS POC 清单）
- [控制通道与启动完整性](../docs/design/control-channel-security.md)
- [安全验证追踪矩阵](../docs/security/security-verification-matrix.md)

## 开发前置条件

- Apple Silicon Mac；最低系统版本在完成平台矩阵 §4 POC 前不冻结。
- 最新稳定 Xcode 与命令行工具。
- 发布构建需要 `com.apple.security.virtualization` entitlement、有效签名与 notarization；entitlement 或能力缺失时必须明确失败，不得降级（平台矩阵 §2）。
- 语言与工程结构在 Phase 1 `SandboxRuntime` 接口冻结时决定；在此之前本目录不预建代码骨架。

## POC 顺序（对应平台矩阵 §4，全部在真机执行）

1. 用发布签名与目标 entitlement 启动最小 arm64 Linux guest。
2. 验证 VZ Socket 只连接对应 VM，覆盖并发 VM 串线测试（→ 控制通道设计 §3–5）。
3. 验证基础盘只读、每 sandbox 可写 COW clone 独立且可确定性删除。当前候选实现是宿主 APFS `clonefile`；它不是 VZ 原生 snapshot，必须在真实 APFS、空间耗尽、崩溃恢复和删除失败场景验证，结论需回写架构 §6.3。
4. 验证无网卡与受控网卡两种模式下均无绕过 Broker 的出口（→ Broker 设计 §9 POC 1）。
5. 测量 vCPU 与固定内存上限在宿主压力下的强制行为。VZ 无公开 CPU 时间硬配额 API，本项结论决定不变量 8 在 macOS 侧的可承诺表述。
6. 验证 `CowDiskManager` 在 APFS 上的 clone、写时复制独立性、空间耗尽、同 sandbox 重复创建、并发创建和 cleanup 失败行为。
7. 验证 app crash、强杀、系统重启后的 VM/COW/endpoint 枚举与回收。
8. 验证 suspend/resume API、最低系统版本、snapshot 中会话材料失效；失败则首版禁用该功能。
9. 验证系统升级与应用回滚不加载低于安全最低版本的 guest asset。

## 可启动 POC

`Sources/dbx-poc` 提供前台 `launch` 入口，完整流程、manifest 格式、签名 entitlement 和当前限制见 [Resources/README.md](Resources/README.md)。

```bash
cd macos
swift run dbx-poc capcheck
swift run dbx-poc validate-assets ./guest/manifest.json
swift run dbx-poc launch ./guest/manifest.json --cow-root "$HOME/Library/Application Support/DeskBox/cows"
```

启动 POC 必须使用已签名的 `com.apple.security.virtualization` entitlement，并在真实 Apple Silicon Mac 上执行。没有 guest bootstrap proof 时，输出只能是 `pending-bootstrap`，不能宣称产品状态为 `Running`。

## 验收门槛

macOS 侧发布前必须通过[安全验证追踪矩阵](../docs/security/security-verification-matrix.md)中 INV-01/03/05/07/08/10 的 macOS 证据项，以及架构 §11 的发布门槛；模拟器结果不构成发布证据（矩阵 §4）。

## 参考源码

开源参考仓库 clone 到 `../references/`（只读、不入库），清单见 [references/README.md](../references/README.md)。VZ 本身闭源，以 Apple 官方文档与实际 POC 为准。
