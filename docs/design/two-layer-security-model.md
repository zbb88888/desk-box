# Host 与 Guest 双层统一安全体系

状态：实施设计基线
日期：2026-10-23

## 1. 目标

Desk Box 在 macOS Host、Windows Host 和 Linux Guest 上使用同一套安全语义，但由各层不同机制执行：

- **Host 层**掌握用户身份、长期凭据、宿主文件、外部网络、VM 生命周期和最终授权，是权威策略执行层。
- **VM 边界**以独立 guest kernel 隔离不可信 workload 与 Host，是首版唯一强安全边界。
- **Guest 层**使用 Linux、`containerd`、`runc`、namespace、cgroup、seccomp 和最小 `execd` 实施工作负载内的最小权限与纵深防御。
- **跨边界协议**把同一身份、授权、资源和审计上下文绑定到具体 VM boot，防止两层语义在传递中失真。

macOS 与 Windows 的底层 API 不同，但必须实现相同安全契约；Guest 的 arm64 与 amd64 构建不同，但必须实施相同策略。统一的是语义、状态和验收，不是平台机制或二进制。

## 2. 完备性的准确含义

双层体系只有在以下四部分共同存在时，才构成设计上的完整安全闭环：

1. Host 层控制宿主资源和最终授权。
2. VM 边界阻止 Guest 失陷直接成为 Host 失陷。
3. Guest 层限制 workload、降低攻击面并控制资源滥用。
4. 跨边界身份、策略、审计、更新和销毁保证两层状态一致。

因此，“Host 安全 + Guest 安全”不能脱离 VM 边界和跨边界控制单独宣称完备。本文所称“完整”表示责任和控制路径没有有意遗漏，不表示实现已经安全；只有安全验证矩阵全部通过后，才能称为已验证。

```text
硬件虚拟化
└── Host OS 安全机制
    └── Hypervisor / VM 强隔离边界
        └── Linux Guest 安全机制
            └── containerd + runc 容器隔离
                └── 不可信 Agent / workload
```

外层失陷不会由内层控制自动补救：Host OS 或 hypervisor 失陷超出 Guest 能力；容器逃逸可能控制整个 Guest，但仍需突破 VM 边界才能直接进入 Host。

## 3. 统一安全语义

两层共同使用以下对象：

| 对象 | 含义 | 权威来源 |
| --- | --- | --- |
| `Principal` | 用户、Agent、sandbox、workload 或宿主服务身份 | Host Controller |
| `Resource` | 工作区、文件、网络目标、凭据、镜像、MCP 工具或计算资源 | Host 资源目录与策略 |
| `Action` | read、write、execute、connect、invoke、build、snapshot、destroy 等操作 | 版本化策略 schema |
| `Scope` | 工作区根、host/path/method、镜像 digest、VM boot、时间和配额范围 | 用户授权与 Host 策略 |
| `Grant` | 对 Principal 在 Scope 内执行 Action 的短期能力 | Host Policy Engine |
| `Decision` | allow、deny 或 error；状态不确定时只能 deny/error | 每层策略执行点 |
| `Reason` | 稳定、可审计且不含秘密的决策原因 | 共享 reason code registry |
| `Evidence` | 证明控制被正确执行的测试与发布记录 | 验证系统 |

任何请求都必须能够表示为：

```text
Principal 对 Resource 执行 Action
    + Scope
    + 当前 VM boot/session
    + Grant
    -> Decision + Reason + Audit Event
```

Guest 不自行创造 Host capability。Guest 中的 UID、container ID、process ID 只有在绑定到 Host 签发的 sandbox、boot 和 workload identity 后才具有授权意义。

## 4. 决策优先级

统一规则为：**Host 决策是权限上限，Guest 只能进一步收紧，不能放宽。**

```text
有效权限 = Host Grant ∩ Guest Policy ∩ 当前生命周期状态 ∩ 资源配额
```

- Host 拒绝时，Guest 无权覆盖。
- Host 允许但 Guest 策略拒绝时，操作仍然拒绝。
- 任一策略版本、身份、时间、通道或审计状态不明确时 fail closed。
- OCI metadata、命令参数和 MCP payload 都是不可信输入，不能改变策略优先级。
- Debug、恢复和兼容模式不能绕过该交集模型。

Host 与 Guest 使用同一 action、reason code 和资源命名 schema。平台 adapter 可以补充平台原因，但不能改变公共决策含义。

## 5. Host 层安全体系

### 5.1 身份与授权

Host 认证本地用户，创建 sandbox、Agent、workload 和 boot identity，并签发短期 grant。macOS Keychain 与 Windows Credential Manager 只是不同的秘密存储实现，不改变凭据授权语义。

用户授权表达任务意图：允许访问哪个工作区、调用哪个服务、使用哪个工具以及持续多久。平台 entitlement、Windows service privilege 等实现细节不暴露为普通用户权限选项。

### 5.2 VM 与生命周期

Controller 通过统一 `SandboxRuntime` 状态机执行 create、start、suspend、resume、stop 和 destroy。VZ Adapter 与 Hyper-V Adapter 分别实现相同前置条件、后置条件和失败语义。

Host 强制 VM 级 CPU、内存、磁盘、执行时长和并发限制。Guest 失联、策略失配或清理失败时，Host 必须仍能撤销 grant、关闭通道并终止 VM。

### 5.3 宿主资源

只有 Host 可以：

- 从用户选择的目录导入或向宿主导出工作区；
- 读取长期凭据并完成最终上游认证；
- 解析并连接外部网络目标；
- 导入、验证和解包 OCI artifact；
- 创建、持久化或销毁 COW 与 snapshot；
- 调用需要宿主权限的 MCP 工具；
- 安装和更新应用、guest asset 与策略。

Guest 通过窄协议请求能力，不获得原始宿主文件描述符、credential store、hypervisor API、daemon socket 或通用网络权限。

### 5.4 平台差异封装

| 统一语义 | macOS 实现 | Windows 实现 |
| --- | --- | --- |
| VM 强边界 | `Virtualization.framework` | Hyper-V Generation 2 |
| 私有控制通道 | VZ Socket | Hyper-V Socket |
| 私有写层 | VZ block/COW 方案 | Differencing VHDX |
| 宿主凭据 | Keychain | Credential Manager；超大私钥以 DPAPI 加密文件等价机制存储 |
| 网络强制 | macOS 网络机制与 Broker | vSwitch/Firewall 与 Broker |
| 文件对象约束 | APFS 与 macOS 文件 API | NTFS、ADS、reparse point 与 Windows API |
| 安装权限 | 签名、notarization、entitlement/helper | Authenticode、service/helper privilege |
| 持久化恢复 | VZ 支持能力加产品加密 | Hyper-V save/checkpoint 加产品加密 |

平台能力不满足统一语义时，应关闭对应功能或整个强隔离模式，不能用较弱机制伪装成功。

## 6. Guest 层安全体系

### 6.1 最小可信基

Guest image 只包含：签名 kernel、init、必要 driver、`containerd`、`runc`、裁剪后的 `execd`、网络 forwarder、策略 bundle、更新校验和诊断组件。

默认移除 SSH server、通用登录账户、编译工具、包管理 daemon、远程管理服务和未使用 kernel module。Guest asset 由 Host 在启动前按签名 manifest 和 digest 校验，并受最低安全版本约束。

### 6.2 身份分层

Guest 至少区分：

- `guest-init`：启动、挂载、策略加载和子进程回收；
- `execd`：只拥有命令、文件、PTY、signal 和指标所需权限；
- `containerd/runc`：只允许受信任 guest control process 调用；
- `workload`：默认非 root UID，无 runtime socket、agent socket 和 bootstrap material；
- `diagnostic`：默认关闭，启用时仍不能读取业务秘密或扩大 workload 权限。

不得以“都在同一 VM 内”为由让 workload 获得 guest root。即使 guest root 失陷不会直接等于 Host 失陷，减少 guest root 能力仍可降低攻击 guest kernel、控制通道和同域数据的机会。

### 6.3 进程与 OCI 执行

`WorkloadSpec` 是 Guest 执行的唯一输入契约。Guest 必须再次校验 Host 下发内容，至少强制：

- 独立 PID、mount、IPC、UTS 与 network namespace；
- 固定 capability allowlist，默认 drop 全部后按需增加；
- `no_new_privs` 与固定 seccomp policy；
- 禁止 privileged、host namespace、host device、runtime socket 和 workload 自行加载 BPF 程序；
- 只读基础 rootfs，写入仅允许 workspace、受控 volume 和有界临时目录；
- 固定工作目录、环境变量白名单和有界 argv/env 大小；
- PID、CPU、内存、磁盘、文件描述符和日志限制；
- init、signal forwarding、orphan reaping 和确定性退出码。

Host 校验与 Guest 重复校验是有意的纵深防御，但 Guest 校验不能把 Host 拒绝的字段重新解释为允许。

### 6.4 Linux 安全基线与 eBPF 定位

Guest 容器隔离由 Linux kernel 的多项原生机制共同实施，不以 eBPF 作为单一或主要隔离边界：

| 机制 | 首版用途 | 强制要求 |
| --- | --- | --- |
| Namespace | 隔离 PID、mount、network、IPC、UTS 和用户视图 | 每个 workload 独立，禁止 host namespace |
| cgroup v2 | 限制 CPU、内存、PID 和 I/O | 由可信 runtime 创建，workload 不可修改父级 |
| Capability | 移除传统 root 的细分内核权限 | 默认全部 drop，按固定 allowlist 增加 |
| `no_new_privs` | 阻止 exec 获得额外权限 | 所有 workload 强制启用 |
| Seccomp | 限制可调用的 syscall | 固定 allowlist/profile，不接受 OCI 自定义覆盖 |
| LSM | 对进程、文件和内核对象施加额外策略 | Guest 必须启用经验证的 SELinux 或 AppArmor profile；Landlock 只能补充，不能代替系统级 LSM |
| Mount/rootfs | 限制可见文件与写入位置 | 基础 rootfs 只读，只开放受控 workspace、volume 和 tmpfs |
| Network namespace/firewall | 限制本地网络面与 Broker 路径 | 默认拒绝，不允许 workload 管理路由、DNS 或 firewall |

Seccomp 使用 BPF 过滤模型，不等于向 workload 开放通用 eBPF。部分 cgroup 或设备控制也可能由 runtime 在内核中使用 BPF 实现；这属于可信 Guest 基础设施的实现细节，不改变授权语义。

eBPF 在首版中的定位是**可选补充控制与可观测性能力**：可用于 BPF LSM、cgroup BPF、tc/XDP 网络策略或运行时 tracing，但不能替代 namespace、cgroup、capability、seccomp、LSM 或 VM 边界。首版不自研以 eBPF 为核心的 sandbox。

Guest 必须实施以下 BPF 权限规则：

- 禁止 unprivileged BPF，并通过内核配置或 `kernel.unprivileged_bpf_disabled` 在启动时验证；
- workload 不获得 `CAP_BPF`、`CAP_PERFMON`、`CAP_SYS_ADMIN`、`CAP_SYS_MODULE` 或等价权限；
- seccomp profile 拒绝 workload 的 `bpf` syscall，workload 不可访问或挂载 `bpffs`；
- 只有可信 `guest-init` 或专用最小策略加载器可以加载经版本固定和完整性验证的 BPF 程序；
- BPF map、program 和 pin 生命周期绑定当前 boot，不能从旧 snapshot 恢复为有效策略；
- eBPF 事件只能输出受控安全 metadata，不采集凭据、prompt、模型响应或文件内容；
- eBPF、kernel 或 verifier 兼容性不确定时关闭该可选能力，不能放宽基础策略。

是否启用 BPF LSM、cgroup BPF 或 tracing 必须按目标 guest kernel 版本分别 POC，并纳入 guest manifest、SBOM、更新和回归测试。

### 6.5 Guest 文件系统

- 基础系统盘只读；每个 sandbox 使用独立 COW。
- Workspace 是从 Host 导入的私有副本，不是宿主 live mount。
- `execd` 文件 API 限制在 workspace 和指定临时目录，并使用 descriptor-relative 或等价安全路径处理。
- `/proc`、`/sys`、cgroup、device、kernel log 和 runtime state 按最小需要挂载或屏蔽。
- 禁止 workload 访问 guest agent 配置、bootstrap material、containerd socket 和其他 container rootfs。
- Symlink、hard link、device node、特殊文件和配额在 Guest 内再次检查；导出仍由 Host 独立验证。

### 6.6 Guest 网络

Guest 默认无可绕过 Broker 的直连出口。Workload 只能访问：

- 当前 sandbox 内明确声明的本地服务；
- 受限 guest forwarder；
- 由 Host grant 允许的 MCP 或网络能力。

Guest firewall、namespace 和代理配置提供纵深防御；Host Broker 与平台网络强制才是最终授权点。Workload 不得自行增加路由、加载网络管理 capability、启动 tunnel 或修改 DNS 以绕过 Broker。

### 6.7 Guest 凭据

Guest 不保存长期真实凭据。环境变量中的兼容占位值、逻辑 credential handle 和短期通道身份都不能用于其他 sandbox、其他 boot 或直接向上游认证。

若未来允许某类短期派生凭据进入 Guest，必须有独立 ADR，并限定 provider、scope、期限、撤销和 snapshot 行为；不能改变长期凭据只在 Host 的默认不变量。

### 6.8 资源与拒绝服务防护

Guest 通过 cgroup v2、rlimit、filesystem quota 和日志窗口执行 workload 级限制；Host 同时执行 VM 级限制。两层配额使用同一资源名称和单位，实际生效值取更严格者。

Guest OOM、fork bomb、磁盘写满、日志洪泛或卡死不能阻止 Host 强制 stop/destroy。Host 资源压力也不能自动取消安全限制以换取可用性。

### 6.9 Guest 审计

Guest 为 command、file、process、policy deny、resource kill 和 agent lifecycle 生成结构化事件，并包含 sandbox、boot、session、workload、request 和 correlation ID。

Guest 日志经有界通道发送到 Host；通道不可用时本地有界缓存，缓存写满后丢弃非安全关键诊断或停止相关操作，不能无限占盘。日志禁止包含长期凭据、完整 prompt、模型响应、文件内容和认证 header。

### 6.10 Guest 更新与恢复

Guest 不自助在线更新。Host 获取、验证并原子切换签名 guest asset；Guest 只验证当前 manifest 和最低版本。更新失败保持旧可信版本，不从 workload 网络下载替代组件。

Suspend 前关闭 grant 与控制会话。Resume 重新绑定 boot epoch、临时身份和策略版本。旧 snapshot 不能恢复旧 token、网络连接或已撤销权限。

## 7. 跨边界一致性

### 7.1 身份绑定

所有跨边界请求绑定：

```text
user -> workspace -> sandbox -> VM instance -> boot -> session -> workload -> request
```

任一层级不匹配都拒绝。PID、端口或可复用 VM 名称不能单独作为身份。

### 7.2 策略下发

Host 下发版本化、签名或会话完整性保护的 policy bundle，包含：

- `WorkloadSpec`；
- Guest capability 和 seccomp profile ID；
- 文件根与 volume 描述；
- 网络/MCP 逻辑 grant 引用；
- 资源限制；
- 审计级别与 reason code 版本；
- 过期时间和 Host policy digest。

Guest 仅接受当前 boot 会话、兼容 schema 和未过期 bundle。局部策略缓存不能跨 boot 自动复用。

### 7.3 决策与审计关联

Host 和 Guest 对同一请求共享 correlation ID，但分别记录各自执行点的 decision。验证系统应能回答：

- 用户授权了什么；
- Host 编译了什么 grant；
- Guest 对哪个 workload 执行了什么限制；
- 最终是否访问宿主资源或外部服务；
- 在何处、因何 reason code 被拒绝；
- 生命周期结束后哪些资源已撤销和销毁。

审计完整不等于收集业务内容。默认只记录安全 metadata。

### 7.4 生命周期收敛

Host 状态是产品对外状态来源，Guest 状态是输入证据。Guest 报告 `Stopped` 不足以证明 VM、COW 或 grant 已销毁；只有 Host 完成逆序回收后才能发布终态。

Host 与 Guest 状态冲突、消息丢失或超时时进入 `Failed`/`Stopping` 并收紧权限，不得乐观恢复为 `Running`。

## 8. 控制覆盖矩阵

| 安全目标 | Host 主控制 | VM 边界 | Guest 纵深控制 | 跨边界保证 |
| --- | --- | --- | --- | --- |
| 隔离不可信代码 | 一授权域一 VM、生命周期 | 独立 guest kernel | namespace、seccomp、capability | VM/boot 身份绑定 |
| 保护宿主文件 | Workspace Sync、导出授权 | 无宿主 live mount | 私有 workspace、路径限制 | Manifest 与 changeset 完整性 |
| 保护长期凭据 | Credential store、Broker | Secret 不进入 VM | 禁止 secret 文件/环境 | Grant 引用而非真实值 |
| 控制网络 | Broker、DNS/TLS/目标策略 | 无直连出口 | namespace、forwarder、firewall | 每请求 grant 与 correlation ID |
| 控制资源 | VM 配额与强制终止 | VM 资源边界 | cgroup、rlimit、quota | 同名配额取更严格值 |
| 控制 OCI 权限 | 镜像校验、编译 `WorkloadSpec` | Guest 隔离 Host | Guest 二次校验、runc policy | Policy digest 与 schema version |
| 保护控制面 | Controller 与平台权限 | 私有 VZ Socket/HVSock | Agent socket 与 workload 隔离 | 双向认证、nonce、sequence |
| 安全恢复销毁 | 撤销、回收、更新回滚 | VM/COW 生命周期 | 停进程、清缓存 | 新 boot epoch、旧会话失效 |
| 可审计 | Host 决策与资源结果 | Sandbox/VM identity | Guest 执行事件 | Correlation ID 与稳定 reason |

矩阵中每个安全目标都必须同时说明主控制、纵深控制和跨边界保证；缺少任一列即视为设计缺口。

## 9. 失败规则

- **Host 控制失败**：拒绝新能力，撤销活动 grant；必要时停止 VM。
- **VM 边界不可用**：强隔离模式不可启动，不降级到宿主进程或容器。
- **Guest 控制失败**：不启动 workload，或由 Host 终止 sandbox。
- **跨边界身份/策略不一致**：关闭会话并进入 `Failed`。
- **审计关键事件无法记录**：高风险操作拒绝；普通诊断可以按有界策略降级。
- **平台能力不同**：允许功能差异，不允许安全不变量差异。

兼容性错误应明确呈现为“不支持”，不能通过扩大权限解决。

## 10. 验证要求

### 10.1 统一语义测试

同一套 contract test 在 macOS/VZ 和 Windows/Hyper-V 上验证：

- 相同请求获得相同 allow/deny 语义和 reason code；
- 两层策略交集正确，Guest 不能扩大 Host grant；
- 身份、策略版本、期限或生命周期状态不匹配时均拒绝；
- 审计事件可以按 correlation ID 重建完整控制路径；
- 一个平台缺少能力时明确禁用，而不是静默降级。

### 10.2 Guest 专项测试

- Workload 无法访问 agent/containerd socket、bootstrap material、其他 rootfs 或宿主资源。
- Privileged、额外 capability、host namespace/device/mount 和 seccomp 覆盖全部拒绝。
- Seccomp、cgroup、quota、只读 rootfs、文件根和网络路径按策略实际生效。
- Workload 无法调用 `bpf`、访问 `bpffs` 或取得 BPF/perf/module 管理权限；关闭 eBPF 可选能力不影响基础隔离。
- 启用的 BPF 程序、map、事件字段和生命周期与 guest manifest、当前 boot 和隐私策略一致。
- Guest root 失陷场景不能读取长期 Host 凭据、直接访问宿主文件或绕过 Broker。
- 旧 policy、旧 session、旧 snapshot 和旧 boot identity 不能重放。
- 资源耗尽、agent crash 和 Guest kernel panic 后 Host 能确定性撤销与回收。

### 10.3 Host 专项测试

- VZ 与 Hyper-V adapter 分别满足相同生命周期后置条件。
- Keychain/Credential Manager、APFS/NTFS 和平台网络机制的差异不会改变授权结果。
- Host crash、系统重启、升级和回滚不复活旧 grant、COW 或 snapshot。
- 平台 helper/service 只拥有完成对应控制所需的最小宿主权限。

## 11. 设计结论

Desk Box 的安全体系不是“Host 安全机制”与“Guest 容器机制”的简单相加，而是：

```text
统一安全语义
    |
    +-- Host 权威授权与宿主资源控制
    +-- VM 独立 kernel 强边界
    +-- Guest 工作负载最小权限与纵深防御
    +-- 跨边界身份、策略、审计、更新与销毁一致性
```

这套模型允许 macOS 与 Windows 使用不同底层机制，同时给最终用户、Agent 和验证系统呈现同一安全语义。其设计覆盖面可以称为完整安全体系；其实现只有在两个平台的 Host 控制、VM 边界、Guest 控制和跨边界验证全部通过后，才能称为已验证安全。
