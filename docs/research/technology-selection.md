# 技术选型、横向对标与取舍

状态：首版选型已确定
日期：2026-10-23

## 1. 评估方法

候选项目按 Desk Box 的真实需求评估，而不是按项目名称中的“Sandbox”“Container”判断。

优先级从高到低为：

1. 面对恶意 Agent、镜像、依赖和 MCP 时的隔离强度。
2. Apple Silicon macOS 与 Windows 11 Pro/Enterprise 的原生可用性。
3. 长期凭据能否始终留在宿主。
4. OCI 镜像与 Dockerfile 兼容性。
5. 最终用户是否需要理解底层基础设施。
6. 特权接口是否足够窄、失败是否可审计且 fail closed。
7. 许可证、供应链、升级与长期维护成本。
8. 在安全门槛通过后的启动速度和资源密度。

镜像格式、构建器、VM、安全容器、guest agent、控制面和凭据代理属于不同层。采用某个项目的一层能力，不代表整体采用该项目。

## 2. 结论矩阵

| 项目或技术 | 底层引擎/实现 | 决策 | 在 Desk Box 中的角色 |
| --- | --- | --- | --- |
| Apple `Virtualization.framework` | Apple 硬件虚拟化、virtio 设备、VZ Socket | **采用** | macOS 强隔离边界 |
| Hyper-V Generation 2 | Type-1 hypervisor、VMBus、VHDX、HVSock | **采用** | Windows 强隔离边界 |
| OCI Image Spec | Manifest、config、filesystem layer | **采用** | 唯一工作负载包格式 |
| BuildKit | LLB DAG、worker、snapshot、cache | **采用，置于 Builder VM** | Dockerfile 构建器 |
| containerd | Content、image、snapshot、task | **采用，置于 guest** | OCI 生命周期 |
| runc | libcontainer、namespace、cgroup、seccomp | **采用，置于 guest** | OCI 进程执行 |
| OpenSandbox `execd` | Go daemon、HTTP/SSE/WebSocket、PTY/files/session | **固定版本小型 fork** | Guest Agent |
| OpenSandbox lifecycle/SDK/MCP | OpenAPI、FastAPI、生成客户端与流式适配 | **参考并裁剪语义** | Desktop contract 参考 |
| OpenSandbox egress/Credential Vault | DNS+nftables、透明 TLS MITM、内存 vault | **只参考策略语义** | Broker binding 参考 |
| Kata Containers | shim v2、virtcontainers、VMM、guest kernel、kata-agent | **只参考架构** | VM-backed 分层模板 |
| Docker Desktop | 共享 Linux VM、containerd/runc、Docker API | **只参考** | 桌面 OCI 可行性证据 |
| E2B | 云控制面、Firecracker、envd、snapshot/storage | **只参考** | Agent 工作区体验对标 |
| Firecracker | Linux/KVM microVM、精简 virtio 设备模型 | **只参考** | 最小 VM 设计对标 |
| gVisor | runsc、Sentry 用户态内核、systrap、Gofer | **未来可选** | Guest 内二级隔离 |
| Wasmer/WASI | Wasm runtime、显式 capability host call | **未来可选** | Wasm-only 插件 |
| WSL2 | 多发行版共享 utility VM kernel | **舍弃强隔离模式** | 最多作为低保障兼容模式 |
| QEMU | 通用设备模型、HVF/WHPX 加速 | **诊断后备** | 原生 API 能力对照 |

## 3. 确定采用的基础组件

### 3.1 Apple `Virtualization.framework`

底层实现：Apple 提供的系统虚拟化框架通过硬件虚拟化运行 VM，为 Linux guest 提供 virtio block、network、entropy、balloon 和 socket 等设备。

选择原因：

- Apple Silicon 上受支持的原生虚拟化 API。
- 相比自带 QEMU，设备面和分发维护面更小。
- 与 macOS 应用签名、entitlement、生命周期和诊断集成更自然。
- 独立 guest kernel 满足强隔离基线。

限制：

- 它不提供 OCI runtime、镜像服务、guest agent 或凭据 Broker。
- macOS adapter 仍需自研。
- 首版以原生 arm64 镜像为基线，不静默模拟 amd64。

### 3.2 Hyper-V Generation 2

底层实现：Hyper-V 是 Windows Type-1 hypervisor；Generation 2 VM 使用 UEFI、VMBus 合成设备、VHDX、checkpoint 和 Hyper-V Socket。

选择原因：

- Windows 11 Pro/Enterprise 原生提供所需能力。
- 每个授权域可以拥有独立 guest kernel、VM identity 和差分磁盘。
- 差分 VHDX 与 checkpoint 适合一次性沙箱和受控恢复。
- Hyper-V Socket 可建立不经过通用网络的宿主/来宾通道。

关键区分：Windows 11 上 HCS LCOW v2 缺少成熟客户端支持，不等于 Hyper-V Gen2 不可用。首版直接管理 Hyper-V VM，不走 LCOW。

### 3.3 OCI Image Spec

底层实现：OCI image 定义 manifest、config 和 filesystem layer，并用 digest 构成内容寻址对象；它不执行进程，也不提供隔离。

选择原因：

- 与 Dockerfile、Registry 和现有开发生态兼容。
- Digest 和 multi-platform index 有利于验证、缓存和 arm64/amd64 选择。
- 格式与 runtime 解耦，产品可以自行施加安全策略。

镜像请求的 privileged、host namespace、host device、任意 mount、runtime socket 和安全策略覆盖全部拒绝。镜像 metadata 是输入，不是权限。

### 3.4 隔离 Builder VM 内的 BuildKit

底层实现：BuildKit 把 Dockerfile/frontend 编译为 LLB 构建 DAG，由 worker 配合 snapshotter、cache 和并行执行完成构建。

选择原因：

- 现代 Dockerfile 兼容和缓存能力成熟。
- `RUN`、安装脚本和 frontend 都是不可信代码，放入独立 VM 后边界清晰。
- 只有按 digest 标识的 OCI artifact 返回宿主。

不在宿主运行的原因：host worker、共享 cache 和 daemon socket 会扩大可信计算基，并可能让 build secret 或状态跨项目泄露。

### 3.5 Guest 内 `containerd + runc`

底层实现：

- `containerd` 管理 content、image、snapshot、task 和进程生命周期。
- `runc/libcontainer` 使用 namespace、cgroup、capability 和 seccomp 按 OCI runtime spec 创建 Linux 进程。

选择原因：

- OCI 兼容成熟，现有镜像和工具可直接工作。
- 即使发生 container escape，攻击者首先仍被限制在外层 VM 中。
- 初期降低自研 OCI executor 的复杂度，后续可依据攻击面再裁剪。

只放 guest 的原因：宿主 container daemon 是高价值特权 API；`runc` 容器共享 kernel，不能隔离不同凭据域；containerd socket 不允许暴露给 workload。

### 3.6 OpenSandbox `execd` 小型 Fork

底层实现：Go 编写的数据面 daemon，通过 HTTP、SSE 和 WebSocket 提供 direct argv、shell、background log、PTY、file、session、signal 和 metrics。

选择它而不是 E2B `envd` 或立即从零自研的原因：

- 功能面最接近桌面 Agent 需求。
- 命令、PTY、文件、进程监管和指标形成较完整契约。
- Apache-2.0 允许维护产品 fork。
- 容易通过私有 transport adapter 放在 VZ Socket/HVSock 后面，不必引入云控制面。

采用边界：

- 固定到已审计 release，禁止生产跟随 `main`。
- 删除 Jupyter、通用 reverse proxy 和未使用高权限 API。
- 文件 API 限制到产品管理目录。
- 增加身份绑定 bootstrap 与短期 per-VM token。
- 保存上游来源、NOTICE、patch series、SBOM 和可重复构建记录。

## 4. 只参考、不整体采用的项目

### 4.1 Kata Containers

底层链路通常为：`containerd -> shim v2 -> virtcontainers -> VMM -> 独立 guest kernel -> kata-agent/vsock -> OCI workload`。

借鉴内容：

- 一台 VM 作为一个 sandbox 边界。
- 宿主 controller 与 guest agent 分层。
- 在独立 guest kernel 内运行 OCI workload。
- 私有 RPC、明确 lifecycle 和可替换 hypervisor 抽象。

不采用 runtime 的原因：

- 主生产路径面向 Linux/KVM、containerd 和 Kubernetes。
- 没有受支持的 VZ 与桌面 Hyper-V backend。
- 移植会长期 fork hypervisor、网络、存储、agent 和生命周期路径。
- Desk Box 需要桌面 UX 和宿主凭据 Broker，而不是 CRI 集成。

结论：采用 Kata-like 思想，舍弃 Kata runtime 本体。

### 4.2 OpenSandbox 控制面、SDK 与 MCP

底层实现：FastAPI lifecycle server 把请求委托给 Docker runtime、Kubernetes workload provider 或外部 FastSandbox；公开 OpenAPI spec，SDK 由生成代码加手写流式适配组成；MCP 暴露 lifecycle、command 和 file 工具。

借鉴内容：

- Lifecycle resource 与结构化状态语义。
- 控制面和 sandbox 数据面分离。
- OpenAPI 生成普通请求，手写 SSE/WebSocket 适配。
- MCP 只做窄工具入口。
- Credential binding 的 host/method/path 精确匹配、write-only readback、歧义拒绝和 fail closed。

不整体采用的原因：

- 本地 backend 直接控制 Docker daemon。
- 集群 backend 依赖 Kubernetes CRD、controller、ingress 和 RuntimeClass。
- FastSandbox 是外部 Kubernetes/Firecracker 平台，不是 VZ/Hyper-V backend。
- Lifecycle spec 仍在演进且包含大量集群/provider 字段，不应成为桌面公开承诺。
- Python server、数据库和集群组件增加权限与部署复杂度，却不解决桌面 VM 生命周期。

结论：采用 `execd` 小型 fork，参考协议/SDK/MCP，舍弃完整 server 与 runtime。

### 4.3 OpenSandbox Egress / Credential Vault

底层实现：egress sidecar 与 workload 共享 network namespace，持有 `NET_ADMIN`，通过 DNS filtering 和 nftables 执行网络策略；Credential Vault 使用透明 TLS MITM、注入 CA 和 sidecar 内存中的 secret，把真实认证信息注入匹配请求。

借鉴内容：

- Default deny。
- Host/method/path 精确 binding。
- Write-only secret response。
- 匹配歧义拒绝、路径混淆保护、失败关闭。

舍弃实现的原因：

- 真实 secret 会进入 sidecar 进程和其信任域。
- 依赖 Linux nftables、`NET_ADMIN`、透明 MITM 与 guest CA。
- Restart、pause/resume 和 sidecar 可用性使秘密生命周期复杂。
- 桌面产品的更强不变量要求长期 secret 始终只在宿主 credential store。

结论：只复用授权语义，由宿主 Broker 重写实现。

### 4.4 Docker Desktop

底层实现：通常以一台共享 Linux VM 承载 containerd/runc、镜像、网络和 Docker daemon，再把广权限 Docker API 暴露给宿主工具。

借鉴内容：它证明了“桌面 Linux VM + OCI 容器”可以拥有成熟 UX。

不作为依赖的原因：

- 共享 VM 不能隔离不同凭据授权域。
- Docker API/socket 权限远超 Desk Box 所需。
- 许可证、安装、升级、VM 拓扑和安全策略不受产品控制。
- 不能假设终端用户已安装 Docker Desktop。

### 4.5 E2B

底层实现：围绕 Linux/KVM Firecracker microVM 构建云控制面、`envd`、网络、存储、template、snapshot 和 SDK。

借鉴内容：

- Agent 友好的命令与文件体验。
- 一次性环境、template 和 warm start 目标。
- `envd` 的执行行为与 API 作为对照测试。

不采用平台和 `envd` 主线的原因：

- 核心价值绑定 Linux/KVM 云基础设施。
- Firecracker 与云调度不映射到 VZ/Hyper-V。
- 在单机桌面引入或重建云存储、调度和恢复链成本过高。
- 当前 `execd` 功能面与选定 contract 更一致。

### 4.6 Firecracker

底层实现：基于 Linux KVM 的 microVM VMM，使用精简 virtio 设备模型降低云节点攻击面并提高密度。

借鉴内容：最小设备面、一次性 rootfs、template 启动和宿主/guest 服务隔离。

不采用原因：只支持 Linux/KVM，没有 VZ 或 Hyper-V backend；在桌面再套 Linux VMM host 会重复原生 hypervisor 并增加分发复杂度。

## 5. 延期或明确舍弃

### 5.1 gVisor：未来二级隔离

底层实现：`runsc` 提供 OCI runtime 接口，Sentry 用户态内核实现大量 Linux syscall，systrap 依赖 Linux process/seccomp，Gofer 代理文件系统。

未来可用于同一 Desk Box VM 内的特定原生不可信子任务，但首版延期，因为：

- 不能替代跨平台外层 VM。
- Syscall 与文件兼容性需要按工作负载验证。
- 增加一套 runtime、升级链和诊断层。
- 首版优先完成 VM、Broker 和跨平台安全验收，收益更高。

### 5.2 Wasmer/WASI：未来 Wasm Profile

底层实现：Wasmer 编译或解释 WebAssembly；WASI 通过显式 capability 向模块开放文件、网络等 host call。

未来适用于审核过且可重新编译的 Wasm-only 插件或 MCP，但不能运行 Claude Code、原生编译器等通用 OCI Linux 工作负载，因此不是主 runtime。

### 5.3 WSL2：舍弃强隔离模式

底层实现：多个 WSL distribution 共享 WSL utility VM 的 Linux kernel，本地用户可以直接进入并改变环境。

它不满足“一授权域一独立 guest kernel”和“产品独占控制面”。未来可作为 Windows Home 的明确低保障兼容模式，但不得继承 `VM-backed Sandbox` 安全声明。

### 5.4 QEMU：仅诊断后备

底层实现：通用软件设备模型，在 macOS 使用 HVF、Windows 使用 WHPX 获得硬件加速。

不作为默认后端的原因：设备模型攻击面、打包、签名、升级和许可证义务高于平台原生框架，与桌面生命周期集成也更弱。只有 POC 证明 VZ/Hyper-V 缺少必要且安全相关能力时才复评。

## 6. 选择结果的后果

收益：

- 安全声明建立在独立 guest kernel 与宿主策略上，可直接测试。
- 获得 OCI/Dockerfile 兼容而不暴露宿主 Docker daemon。
- 长期凭据留在不可信 VM 之外。
- 两个平台共享 contract 与 guest 行为，同时使用受支持的原生 hypervisor。
- 上游项目只通过窄接口进入产品，可信计算基更可控。

成本：

- 需要维护 VZ 与 Hyper-V 两套 adapter 和一致性测试。
- 需要自研安全 OCI 解包、Workspace Sync、Broker、bootstrap 和清理协调。
- Execd fork 需要持续跟踪漏洞、依赖和上游安全修复。
- 每授权域 VM 的资源密度低于共享容器方案。

这些成本直接服务“安全优先、用户友好其次”的产品目标，因此接受；不为复用云端栈而改变桌面威胁模型。
