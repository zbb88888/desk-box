# M2-4：Windows Hyper-V 首次联通

状态：进行中（打开阶段：协议契约锁定 + Windows 侧可编译骨架；真机 E2E 验证在 Windows 宿主机完成）；关联 `docs/design/m2-roadmap.md`、`docs/architecture/desktop-vm-sandbox.md`、`docs/security/security-verification-matrix.md` INV-01、INV-07。

## 1. 现实约束声明（先正名）

- 当前开发工作站是 Apple Silicon macOS，**Hyper-V 仅可在 Windows 宿主机（Windows 11 Pro/Enterprise 或 Windows Server + VT 挂靠）验证**；
- 不可真机验证的部分一律标注 **UNVERIFIED（Windows）** 并附带给出出样回归清单；
- 交付原则是：macOS 侧可编译的逻辑全部与 Windows 侧共用；Windows 侧代码量可能少但走编译 + 真机出样流程，不凭信念封闭。

## 2. 子阶段

| 阶段 | 范围 | 验证节点 |
|------|------|----------|
| **M2-4a（本轮）** | 共享合约锁定：wire protocol/camelCase 字段名/sequence 语义、record channel nonce 派生、SandboxError 语义；macOS 侧 conformance 测试扩展 `WireContractLockTests`；Windows 侧 C# skeleton（`windows/host/DeskBoxHyperV/`）+ guest 骨架声明 | `swift test` conformance green；Windows build/出样属 M2-4b/c |
| **M2-4b** | Windows guest agent（C#/Rust）在 Hyper-V Linux VM 中对接 HVSock | Windows 宿主机演示 boot/exec/destroy（样例日志决策不变量项） |
| **M2-4c** | 双向打通：Windows host 启用 Hyper-V、DeskBoxHyperV adapter 、负载执行 + broker 组合 | conformance 全套 + INV-01/07 复验 |

## 3. 实施参考

### 3.1 复用 macOS 已锻造的钱包合约
- `SandboxCreateRequest/Spec`、`BootstrapHello/Ack`、`ControlMessageKind` 语义不动；windows 侧实现必须通过 macOS `Tests/ConformanceTests` 相同的样例回归；
- 本阶段在 macOS 侧增加 **contract lock** 单测：样例帧中字段名（camelCase）、字节序、sequence 语义、record channel nonce 派生——防止 Windows 实现侧的字段跳架、字节序或重放语义误差。

### 3.2 Hyper-V adapter 必须面
- VM 资源：HCS（Host Compute Service）API 或 Hyper-V PowerShell module；
- 控制面：HVSock（`AF_VSOCK` on Windows）；与 macOS VZ 的语义保持一致；
- 隔离面：不含元的契约不变量 1/2/4；隔离保证以 Hyper-V 资源界限文档为准。

### 3.3 Windows guest agent
- 与 guest-bootstrap.c 的 C 型态参考相同：X25519+HKDF+ChaChaPoly record channel语义一致；名字空间策略保持同样审切：PT通/audit 记录/admin 须严薄的许可车门。

## 4. 出样验证（Windows 真机上偿通令）
1. HCS/PowerShell 创建隔离度同型的 VM；
2. HVSock 通道连通（host/guest 双向 frame）；
3. bootstrap hello → 加密 record channel → `bootstrap=tlsAuthenticated`；
4. exec + workspace sync + OCI/policy 全组合；
5. stop/destroy 干净，会话与渠道相关 decision 有审计记录；
6. INV-01（硬隔离）与 INV-07（控制通道密钥绑定）在真机复核；

## 5. 安全决策
- 真实性验证一律在 Windows 宿主机执行，不在 Apple 工作站宣称达成；
- 平台差异点（guest agent 用户权限模型、HVSock 行为、Hyper-V 隔离面）以真机验证后的裁决为准；
- 若 Windows phase 落后，macOS 侧不会因等待而开放降级的实证出据。