# 安全验证追踪矩阵

状态：测试计划基线，证据待实现
日期：2026-10-23

## 1. 使用方式

本矩阵把威胁模型中的十项安全不变量映射到责任组件、自动化验收和发布证据。状态只能使用：

- `未实现`：控制尚未实现；
- `已实现待验证`：代码存在，但证据不完整；
- `已验证`：指定平台、版本和构建的测试通过并保留证据；
- `阻断`：测试失败或证据过期，禁止发布。

文档评审、单元测试数量和所采用项目的声誉都不能替代“已验证”证据。任何关键控制变更都会使关联证据过期。

## 2. 追踪矩阵

| ID | 安全不变量 | 主要责任组件 | 最低自动化验收 | 必需证据 | 责任角色 | 初始状态 |
| --- | --- | --- | --- | --- | --- | --- |
| INV-01 | 强隔离任务始终位于独立 VM | Controller、VZ/HV Adapter | 后端识别、禁用/故障注入、禁止静默降级 | 两平台实体机日志、运行时 backend attestation | 平台负责人 | 未实现 |
| INV-02 | 不同凭据域不共享 guest kernel | Scheduler、Controller | 并发创建、身份/工作区/grant 组合属性测试 | 调度决策记录、跨域攻击报告 | 控制面负责人 | 未实现 |
| INV-03 | 长期真实凭据不进入 sandbox | Credential Broker、日志、snapshot | Canary secret 扫描环境、文件、内存转储、COW、日志、snapshot | 扫描报告与人工取证记录 | 身份安全负责人 | 未实现 |
| INV-04 | 所有外部访问经过宿主策略 | Network Broker、Platform Adapter | 互联网/私网/loopback/link-local/metadata、DNS rebinding、redirect、DoH/QUIC 绕过 | 网络 corpus 结果、packet capture 摘要 | 网络安全负责人 | 未实现 |
| INV-05 | 宿主文件仅来自显式工作区授权 | Workspace Sync | 路径、链接、ADS、大小写、Unicode、TOCTOU、并发替换 | 两平台文件系统 corpus 结果 | 数据面负责人 | 未实现 |
| INV-06 | OCI metadata 不能扩权 | OCI Service、WorkloadSpec Compiler、Guest Policy | 恶意 config/layer、privileged/device/mount/capability/BPF 拒绝、setuid/whiteout/路径与链接滥用、解压炸弹 | Parser fuzz、BPF 越权测试与拒绝审计 | OCI 负责人 | 未实现 |
| INV-07 | 控制通道绑定具体 VM 身份 | Controller、`execd`、VZ Socket/HVSock Adapter | 串线、证书篡改、旧 nonce/token/snapshot、版本降级 | 协议测试和独立密码学评审 | 控制通道负责人 | **M1-2 已验证（macOS VZ）**——Hello/Ack boot 绑定 + X25519 ephemeral + HKDF-SHA256 + ChaChaPoly AEAD 加密 record channel；`bootstrap=tlsAuthenticated` → `running`；旧 boot 材料无法产生合法 `sessionID`；`--allow-plaintext` 仅在显式开发模式下。 |
| INV-08 | 资源和生命周期由宿主强制 | Controller、Platform Adapter、guest cgroup | CPU/内存/磁盘/PID/日志耗尽、卡死关机、崩溃恢复 | 压力测试与孤儿资源清单 | Runtime 负责人 | **M1-3 部分**（guest exec exec hardening：nobody 65534、rlimit 256MB/CPU/进程禁/文件 64KiB/env-cwd 白名单、timeout kill 进程组；net 默认无网络；HOST cgroup v2/CPU 时间配额仍未实现 — M1-4），决定相位不变量8 后可发布表述融合。 |
| INV-09 | 构建域与运行域隔离 | Builder Service、Artifact Import | Build secret canary、cache 跨构建、runtime 磁盘读取、产物篡改 | Builder 销毁和 artifact provenance | 构建供应链负责人 | 未实现 |
| INV-10 | 更新、持久化和销毁不复活权限 | Updater、Snapshot、Controller | 签名失败、降级、旧 snapshot、撤销后恢复、清理失败 | 更新/回滚/销毁故障注入报告 | 发布安全负责人 | 未实现 |

## 3. 跨组件发布套件

除矩阵中的专项测试外，每个候选 release 必须执行：

1. **Contract suite**：同一 `SandboxRuntime` 用例分别运行在 VZ 和 Hyper-V。
2. **恶意 workload suite**：以 guest 普通用户、container root 和模拟 guest root 三种权限执行。
3. **故障注入 suite**：在 create、boot、handshake、run、suspend、resume、stop 和 destroy 各阶段终止宿主或 guest 组件。
4. **供应链 suite**：验证 app、guest asset、OCI artifact、`execd` fork 的签名、digest、SBOM 和最低安全版本。
5. **隐私 suite**：扫描遥测、普通日志、诊断包和 crash report 是否包含禁止数据。
6. **兼容 suite**：Claude Code、Codex、dsh、Git 和受支持包管理器执行实际任务，同时验证权限未扩大。
7. **UX 安全 suite**：验证授权提示、拒绝、撤销、超时和低保障模式标识不会误导用户。

## 4. 测试隔离级别

| 测试层级 | 运行位置 | 用途 | 是否可作为发布安全证据 |
| --- | --- | --- | --- |
| 单元/属性测试 | 普通 CI | Parser、策略和状态机逻辑 | 仅部分 |
| 模拟 adapter 测试 | 普通 CI | 生命周期故障与跨平台 contract | 仅部分 |
| Guest 集成测试 | 嵌套或专用 runner | `execd`、containerd、runc、策略 | 仅部分 |
| 实体平台 E2E | 受控 Apple Silicon / Windows 设备 | 真实 hypervisor、网络、磁盘、恢复 | 是，必需 |
| 对抗与 fuzz | 隔离实验环境 | 越权、逃逸面、parser 和协议 | 是，必需 |
| 独立安全评估 | 外部或独立团队 | 设计与实现盲点 | 是，发布前必需 |

模拟器、mock 或嵌套虚拟化通过，不能替代目标硬件上的 VZ/Hyper-V 结果。

## 5. 证据记录格式

每次测试证据至少包含：

- 不变量 ID、测试 ID 和稳定名称；
- Git commit、构建 digest、guest manifest digest 与策略版本；
- OS 版本、补丁级别、硬件型号和 hypervisor 配置；
- 前置条件、执行命令或自动化入口；
- 起止时间、退出码、断言和脱敏日志位置；
- 创建的资源、逆序清理结果和孤儿检查；
- 失败原因、关联 issue、责任人与复验日期。

证据应签名或存入不可静默覆盖的 CI artifact。含敏感信息的原始日志必须加密并设置最短保留期。

## 6. 发布规则

- 十项不变量任一不是 `已验证`，不得发布强隔离模式。
- 任一测试出现 fail open、跨域访问、长期凭据泄露或清理后权限复活，状态立即设为 `阻断`。
- 高危漏洞修复会使受影响证据失效，必须重跑相关专项与跨组件套件。
- 平台系统升级、guest kernel/runtime 升级、Broker 协议变化和 `execd` rebase 必须触发影响分析。
- Windows 与 macOS 分别判定；一个平台通过不能替另一个平台背书。
- 性能回归不能通过关闭安全控制解决。

## 7. 文档到证据的追踪

- Host、VM 边界、Guest 或跨边界责任变化：更新[双层统一安全体系](../design/two-layer-security-model.md)并标记受影响不变量。
- 架构组件或边界变化：更新总体架构并标记受影响不变量。
- 安全目标变化：先更新威胁模型，再更新本矩阵。
- 技术替换或保障等级变化：新增 ADR。
- 平台 API 结论：记录在平台能力矩阵并附 POC 证据。
- Broker、控制通道和 Workspace Sync 结论：更新对应详细设计与测试 ID。

在自动化框架建立前，本矩阵所有条目保持 `未实现`；不能因为文档写明控制措施而提前改为 `已验证`。
