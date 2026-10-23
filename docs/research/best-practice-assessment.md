# 最佳实践符合性评估

状态：设计阶段评估
日期：2026-10-23

## 1. 结论摘要

Desk Box 的首版方案符合高风险本地 Agent 沙箱的主流安全工程原则：以独立 VM kernel 作为主边界、最小化宿主接口、默认拒绝网络、让长期凭据留在宿主、隔离构建、固定并审计上游版本、为每项声明定义可执行门槛。

但“符合最佳实践”不等于“实现已经安全”。当前结论只针对架构与控制设计。产品必须在实现后提供测试、取证、供应链和独立评估证据，才能宣称达到目标保障等级。

## 2. 判断标准

本评估使用以下原则：

- **边界与威胁匹配**：恶意原生代码不应只由共享宿主 kernel 的容器隔离。
- **最小权限**：Guest、Agent、MCP 和镜像只能获得任务所需 capability。
- **秘密最小暴露**：长期凭据不进入低信任域。
- **默认拒绝与 fail closed**：网络、文件、身份或策略状态不明确时拒绝。
- **机制与策略分离**：OCI、runtime 和 hypervisor 提供机制，宿主 Controller 决定权限。
- **隔离域一致**：共享 kernel 的工作负载必须属于同一授权域。
- **供应链可追踪**：二进制、guest asset、fork 和镜像以版本、digest、SBOM 和签名约束。
- **声明可验证**：每个安全承诺都有正向、负向和故障注入测试。
- **用户意图优先**：授权界面表达工作区、服务和任务，不要求用户配置底层网络或 runtime。

## 3. 符合项

### 3.1 VM 作为主安全边界

对可执行任意原生代码、编译器、依赖安装脚本和 Agent 的场景，使用独立 guest kernel 比只依赖 namespace/seccomp 更符合风险等级。VZ 与 Hyper-V 是对应平台受支持的原生 hypervisor，避免为了统一 API 引入更大的跨平台设备模型。

Kata Containers 也采用 VM-backed sandbox 思路；Desk Box 借鉴这一边界，但直接实现桌面 adapter，避免强行移植 Linux/Kubernetes runtime。

评估：**符合**。待验证项是设备配置、身份绑定、更新和逃逸测试。

### 3.2 OCI 只作为包格式

OCI image 方便生态兼容，但 image config 不被视为权限。把它编译为白名单 `WorkloadSpec`，拒绝 privileged、host namespace、device、任意 mount 和策略覆盖，符合“不可信声明不能扩权”的原则。

评估：**符合**。待验证项是恶意 layer/config corpus 和安全解包属性测试。

### 3.3 长期凭据留在宿主

相比把 secret 注入环境变量、volume 或 guest sidecar，宿主 Broker 在最终请求发送前注入真实认证信息，显著缩小 VM 失陷后的凭据泄露范围。Grant 同时绑定身份、目标、method、path 与期限，符合 capability-based access。

这比 OpenSandbox Credential Vault 的透明 guest-side MITM 更强，但实现 DNS、redirect、TLS、DoH/ECH 和 provider protocol 时也更复杂。

评估：**设计上优于常见 secret injection**。在 canary secret、内存生命周期和协议兼容测试完成前不能宣称已验证。

### 3.4 工作区复制而非默认直挂

将显式选择的工作区复制到 guest 私有盘，避免 guest 持续拥有宿主目录的 live authority。导入和导出分权，也减少 Agent 误删或路径逃逸影响宿主的机会。

代价是同步冲突、性能和大仓库体验，但这与安全优先排序一致。

评估：**符合**。必须使用 race-safe 文件 API，并覆盖 symlink、hard link、ADS、大小写和 TOCTOU。

### 3.5 隔离 Dockerfile 构建

Dockerfile 的 `RUN` 与 frontend 本质上是代码执行。把 BuildKit 放入短生命周期 Builder VM，并与 runtime、宿主和生产凭据隔离，符合将构建视为不可信 workload 的供应链实践。

评估：**符合**。必须验证 cache 与 secret 不跨构建泄露，产物按 digest 导入。

### 3.6 Guest 内纵深防御

`containerd + runc` 提供生态兼容和 namespace/cgroup/seccomp 等第二层控制，但文档没有把它误称为宿主边界。按授权域划分 VM，避免依赖 guest container 隔离不同秘密域。

评估：**符合**。应持续最小化 containerd plugin、runc capability 和可见 socket。

### 3.7 窄控制通道与身份绑定

VZ Socket/HVSock 避免把管理端口暴露到普通网络。Bootstrap 绑定 VM identity、sandbox ID、boot nonce、协议版本和 asset digest，可防止连接串线、旧快照重放和 guest 冒充。

评估：**符合零信任通道原则**。协议需经过密码学设计审查和对抗测试。

### 3.8 上游裁剪与固定版本

选择固定 release 的小型 `execd` fork，而不是动态依赖 `main` 或引入整个 OpenSandbox server/Kubernetes 栈，符合最小可信计算基和变更控制原则。保留来源、NOTICE、patch series、SBOM 和可重复构建记录是必要条件。

评估：**方向正确**。Fork 不是一次性复制，必须有漏洞响应和定期 rebase 责任人。

### 3.9 用户意图级授权

普通用户只回答“允许访问哪个工作区、仓库、服务，以及多久”，不接触 CIDR、mount、runtime class 或 credential 注入细节。复杂策略由安全默认值和高级入口承载。

评估：**符合可用安全原则**。Prompt fatigue、授权混淆和撤销可见性仍需可用性测试。

## 4. 需要特别约束的折中

### 4.1 一工作区一 VM，而非永远一 Agent 一 VM

默认按工作区与凭据授权域共享 VM，资源成本较低，但同域 Agent 可相互影响。只有当它们的用户、工作区、凭据和信任级别一致时才成立；否则必须升级为一 Agent 一 VM。

这是明确的风险分层，不应包装成完全等价隔离。

### 4.2 自研 Broker

宿主 Broker 是方案最关键也最容易出错的组件。它必须正确处理地址标准化、DNS rebinding、redirect、IPv4/IPv6、代理、TLS、DoH/ECH、流式请求和 provider-specific auth。

最佳实践不是“自研一定更安全”，而是当前长期 secret 不进 guest 的不变量要求宿主强制。必须通过协议约束、较小 provider 集合、第三方评审和持续 fuzzing 控制风险。

### 4.3 平台双实现

VZ 与 Hyper-V 的生命周期和 snapshot 语义不同。共享接口能统一产品契约，却不能假设行为天然一致。每个平台必须分别测试，并通过 contract suite 证明关键安全属性等价。

### 4.4 Execd Fork

Fork 能裁剪攻击面，也会承担补丁迁移风险。只有在接口确实比从零实现更成熟、且团队能持续维护时才合理。首版必须设置代码量、依赖数、endpoint 数和高权限调用的上限，并定期重新评估自研替代成本。

## 5. 与常见替代方案比较

| 方案 | 主要优势 | 不满足首版基线的原因 |
| --- | --- | --- |
| 宿主 Docker/共享容器 | 成熟、快、密度高 | 共享宿主或共享 VM kernel，daemon socket 权限过大 |
| Docker Desktop 依赖 | UX 与 OCI 生态成熟 | 外部依赖、共享 VM、拓扑和策略不可控 |
| WSL2 distribution | Windows 开发体验好 | 多发行版共享 kernel，本地用户可进入，不是一授权域一 VM |
| Kata runtime 原样移植 | 成熟 VM-container 分层 | 核心路径面向 Linux/KVM/Kubernetes，桌面后端需长期大 fork |
| Firecracker/E2B | 云端 microVM 与 Agent 体验成熟 | 依赖 Linux/KVM 与云控制面，不适配 VZ/Hyper-V |
| OpenSandbox 全栈 | API、SDK、execd、Kubernetes 集成较全 | backend 与 Credential Vault 不符合桌面边界和宿主 secret 不变量 |
| gVisor 单独使用 | Syscall 拦截强、容器兼容较好 | 仍依赖 Linux host 机制，不能替代跨平台 VM |
| Wasm/WASI | Capability 模型窄、启动快 | 不能承载通用 Linux Agent 与原生工具链 |
| QEMU 统一后端 | 跨平台、功能全面 | 设备面、分发和维护成本高于原生 hypervisor |

## 6. 尚未证明的事项

在实现和测试完成前，以下陈述都不能作为事实发布：

- VM 逃逸不可行；
- 长期凭据绝不会泄露；
- macOS 与 Windows 的安全属性完全等价；
- Snapshot、crash recovery 和更新不会复活旧权限；
- 所有 OCI 镜像或 Dockerfile 都兼容；
- Broker 能透明支持所有模型服务、Git 和包管理器；
- 性能足以支持目标并发；
- Execd fork 比最小自研 agent 的总风险更低。

## 7. 达到“已验证最佳实践”所需证据

1. 威胁模型中的十项不变量全部映射到自动化测试与责任组件。
2. VZ 和 Hyper-V 分别完成逃逸面、控制通道、磁盘、snapshot 和清理评审。
3. OCI parser/unpacker、Workspace Sync 与 Broker 完成 fuzzing 和恶意 corpus 测试。
4. 使用 canary secret 证明环境、文件、日志、COW、snapshot 和 crash dump 不含长期凭据。
5. 完成 SBOM、签名、provenance、可重复构建、漏洞响应和 downgrade protection。
6. 完成外部渗透测试和架构评审，并关闭高危问题。
7. 验证安全控制故障时全部 fail closed。
8. 验证 UI 授权不会诱导用户授予超出任务所需的权限。
9. 发布声明与已通过的保障级别一致，不把参考项目的安全声誉转借给本产品。

## 8. 最终判断

该方案是当前约束下合理且偏保守的首版基线：它没有把 OCI、`runc`、OpenSandbox 或 MCP 当成隔离边界，也没有为了快速兼容把长期凭据放入 VM。最大工程风险集中在宿主 Broker、跨平台生命周期一致性和安全文件同步，这三项应获得最高测试与评审预算。

因此结论是：**设计符合最佳实践方向，但产品安全性仍是待验证命题。** 是否可发布由威胁模型中的可执行门槛决定，而不是由所选项目的品牌、架构图或文档评审决定。
