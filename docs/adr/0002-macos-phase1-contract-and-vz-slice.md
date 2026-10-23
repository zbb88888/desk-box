# ADR-0002：macOS Phase 1 契约与 VZ 垂直切片

状态：已实现骨架，POC/产品能力未验证
日期：2026-10-24

## 背景

ADR-0001 要求先冻结跨平台生命周期、安全语义和验证契约，再实现 macOS VZ backend。平台矩阵明确要求 VZ 的 entitlement、COW、控制通道、网络隔离、资源限制、崩溃恢复和 suspend/resume 在真实 Apple Silicon 设备上逐项 POC。

## 决策

在 `macos/` 建立 Swift Package：

- `DeskBoxCore`：跨平台契约语义，包括身份、reason code、decision、审计、boot proof、生命周期状态机、`WorkloadSpec` 编译器、`CredentialGrant` 解析器和 `SandboxRuntime` 接口。
- `DeskBoxVZ`：`Virtualization.framework` 能力探针、guest asset digest 校验、APFS `clonefile` per-sandbox COW 磁盘和 VZ configuration/runtime。
- `dbx-poc`：`capcheck` 和 `validate-assets` 命令，用于平台 POC 前置检查。
- `Tests/DeskBoxCoreTests`：契约级单测。
- `Tests/ConformanceTests`：未来由 VZ 与 Hyper-V adapter 共享的 contract suite 起点。

实现原则：

1. `Running` 必须由与当前 sandbox/boot/nonce/manifest 绑定的 `BootstrapProof` 确认；不能由 guest 自报状态直接发布。
2. OCI config 只编译为白名单 `WorkloadSpec`；root、危险环境变量和未授权 volume 不得扩权。
3. grant 在目标、主体、期限和注入形态不明确时 fail closed；多条不等价 grant 同时匹配时拒绝。
4. VZ 首个切片不提供网络卡，默认没有普通 guest 出口。
5. VZ 使用产品自建 APFS `clonefile` 作为 per-sandbox COW 候选实现；它不是 VZ 原生 snapshot，必须通过真实 APFS/磁盘压力和恢复 POC 后才能作为发布能力。
6. COW 创建、VZ 启动或 COW 清理任一失败都 fail closed，不得回退到基础盘或报告已销毁。
7. suspend/resume 在真实 POC 完成前明确关闭。

## 未完成与发布阻断项

以下不是本 ADR 的已验证能力：

- `com.apple.security.virtualization` entitlement、发布签名和 notarization；
- macOS COW 的 APFS/clonefile 方案尚未通过真实磁盘、空间耗尽、崩溃恢复和删除 POC；
- VZ Socket 上的 TLS 1.3 双向握手和 execd bootstrap；
- Workspace Sync、Keychain/Credential Broker、guest image/containerd/execd；
- Host CPU/内存/磁盘/生命周期强制；
- suspend/resume、snapshot、崩溃恢复、孤儿资源回收；
- 真实 kernel/VM escape、恶意 OCI corpus、网络绕过和秘密取证测试。

因此当前代码只能称为“Phase 1 契约 + VZ COW 候选实现”，不能称为已验证安全或可发布沙箱。

## 验证

```bash
cd macos
swift test
swift run dbx-poc capcheck
```

实体设备 POC 证据仍必须按 `docs/design/platform-capability-matrix.md` §4 和 `docs/security/security-verification-matrix.md` 记录。
