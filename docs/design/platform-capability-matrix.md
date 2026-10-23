# 平台能力与最低版本矩阵

状态：POC 验证计划，最低版本尚未冻结
日期：2026-10-23

## 1. 目的

本文把抽象架构映射到 Apple Silicon macOS 与 Windows 11 Pro/Enterprise 的实际平台能力。任何能力只有在目标最低版本、发布构建和真实硬件上通过 POC 后，才能从“候选”改为“已验证”。

当前不直接写死最低系统小版本，避免把 API 文档存在误当成产品可用。版本冻结是 Phase 1/2 的发布物。

## 2. 目标平台

| 平台 | 候选范围 | 架构 | 强隔离后端 | 当前状态 |
| --- | --- | --- | --- | --- |
| macOS | 支持 Apple `Virtualization.framework` 所需能力的受支持版本 | Apple Silicon arm64 | VZ | 待 POC 后冻结最低版本 |
| Windows | Windows 11 Pro/Enterprise，启用 Hyper-V | amd64 | Hyper-V Generation 2 | 待 POC 后冻结最低版本 |
| Windows Home | 不在强隔离首版范围 | amd64 | 无承诺 | 明确不支持 |
| Intel Mac | 不在首版范围 | amd64 | 无承诺 | 明确不支持 |
| Linux host | 不在桌面首版范围 | 未定 | 无承诺 | 明确不支持 |

产品必须在安装或首次启动时执行能力探测，并给出用户可理解的失败原因；不得静默切换到容器、WSL2 或宿主进程。

## 3. 能力矩阵

| 能力 | macOS / VZ 验证点 | Windows / Hyper-V 验证点 | 不满足时的行为 |
| --- | --- | --- | --- |
| 硬件虚拟化可用 | VZ entitlement、设备支持、资源创建 | Hyper-V feature、固件虚拟化、服务状态 | 禁用强隔离模式 |
| Linux guest 启动 | arm64 kernel/initrd/root disk | Gen2 UEFI、amd64 kernel/VHDX | 阻止创建 |
| 启动资产完整性 | 应用签名、manifest/digest、只读基础盘 | manifest/digest、Secure Boot 模板兼容性 | 阻止启动 |
| 私有宿主/来宾通道 | VZ Socket endpoint 与 VM 实例绑定 | HVSock service/VM ID 绑定 | 阻止启动 |
| 每 sandbox COW | 基础盘只读、独立可写 overlay 的实现与回收 | differencing VHDX 父链、合并与回收 | 不复用基础盘写层 |
| CPU/内存限制 | vCPU 与固定内存上限的强制效果实测；VZ 无公开 CPU 时间硬配额 API，需验证宿主调度兜底是否满足不变量 8 | Hyper-V reserve/limit/weight 与动态内存策略 | 拒绝超配或终止 |
| 磁盘与日志配额 | COW 最大值、宿主空间保留 | VHDX 上限、宿主空间保留 | fail closed |
| 无直连网络 | VM 网卡缺省状态、Broker-only 数据路径 | vSwitch/NAT/Firewall 缺省状态 | 禁用网络或强隔离模式 |
| Suspend/resume | API 可用性、内存状态与会话失效 | save/checkpoint 类型及会话失效 | 首版关闭该功能 |
| Snapshot 加密与绑定 | 产品层加密、版本/身份 metadata | 产品层加密、checkpoint/VHDX metadata | 禁止持久化 snapshot |
| 崩溃恢复 | App/系统重启后的 VM、COW、endpoint 枚举 | 服务/系统重启后的 VM、VHDX、HVSock 枚举 | 保持 `Failed` 并回收 |
| 非管理员运行 | entitlement 与 helper 权限边界 | 管理 API 所需权限、受限 helper/service | 安装时明确授权 |
| 更新与回滚 | 签名 app/guest asset、原子切换 | 签名 app/service/guest asset、原子切换 | 保持旧可信版本 |
| 诊断隔离 | serial/log 对 workload 不可见 | console/log 对 workload 不可见 | 禁用敏感诊断 |

## 4. macOS POC 清单

1. 用发布签名与目标 entitlement 启动最小 arm64 Linux guest。
2. 验证 VZ Socket 只能连接对应 VM，并覆盖并发 VM 串线测试。
3. 证明基础盘保持只读、每 sandbox 写层独立且可确定性删除。
4. 验证无网卡和受控网卡两种模式下都不存在未授权出口。
5. 测量 CPU、内存、磁盘和宿主压力时的强制限制行为。
6. 验证 app crash、强杀和系统重启后的孤儿资源发现与回收。
7. 验证 suspend/resume API、版本要求和 snapshot 中会话材料失效；失败则首版禁用。
8. 验证系统升级与应用回滚不会加载低于安全最低版本的 guest asset。

## 5. Windows POC 清单

1. 在干净 Windows 11 Pro 与 Enterprise 上启用并检测 Hyper-V，不依赖 WSL2 或 Docker Desktop。
2. 验证 Gen2 Linux guest、UEFI 与适用 Secure Boot 模板；不支持的组合必须明确记录。
3. 验证 HVSock service ID 与具体 VM identity 绑定，并覆盖并发 VM 串线测试。
4. 验证基础 VHDX、differencing VHDX 父链、配额与异常删除恢复。
5. 验证 vSwitch/NAT/Windows Firewall 不产生绕过 Broker 的出口。
6. 明确普通用户、提升进程和 Windows service 的最小权限边界。
7. 验证 Credential Manager 2560 字节 blob 约束下各类长期凭据（含 RSA 私钥）的存储方案，如 DPAPI 加密文件。
8. 验证 checkpoint/save/restore 的实际语义和旧 session 失效；不满足则首版关闭。
9. 验证服务崩溃、系统重启、休眠和更新后的 VM/VHDX 清理。

## 6. 版本冻结产物

POC 完成后必须记录：

- 最低及已测试系统版本和补丁级别；
- 设备、API 与 entitlement/feature 依赖；
- 通过、失败和禁用的能力；
- POC 代码、自动化命令、原始日志和硬件信息；
- 已知 vendor bug 与规避方式；
- 每个平台对应的性能基线；
- 升级或提高最低版本的决策流程。

版本冻结后，CI 只能证明构建和模拟行为；真实 hypervisor 回归必须在受控实体设备上运行。

## 7. 发布判定

- 表中安全必需能力存在任一“未验证”或“失败”，对应平台不得发布强隔离模式。
- Suspend、snapshot、跨架构模拟等可选能力失败时可以关闭功能，但不能改变基本安全边界。
- macOS 与 Windows 可以拥有不同功能集合，但必须满足相同十项安全不变量。
- 所有自动降级都视为发布阻断；用户主动选择低保障模式时必须显示不同名称与保障说明。
