# 桌面 VM 安全沙箱架构

状态：首版实现基线
日期：2026-10-23

## 1. 最终架构决策

Desk Box 采用 **Kata-like、桌面原生、VM-backed** 架构：

- OCI 镜像是唯一外部工作负载格式，但不是安全边界。
- Apple Silicon macOS 使用 Apple `Virtualization.framework` 启动独立 Linux arm64 VM。
- Windows 11 Pro/Enterprise 使用 Hyper-V Generation 2 启动独立 Linux amd64 VM。
- 默认隔离单位是一台 VM 对应一个工作区和凭据授权域；高保障模式是一台 VM 对应一个 Agent。
- 来宾内使用 `containerd + runc` 提供 OCI 兼容，它们只负责来宾内进程组织。
- 固定上游版本的小型 OpenSandbox `execd` fork 提供命令、PTY、文件、会话和指标 API。
- 长期凭据只保存在 macOS Keychain 或 Windows Credential Manager，由可信宿主 Broker 在通过策略校验的最终上游请求中注入。
- 产品不依赖 Docker Desktop、Kubernetes、WSL2、宿主 Docker daemon 或宿主 `docker.sock`。

这是对 Kata 分层思想的桌面实现，不是移植 Kata Containers。安全声明来自独立 guest kernel 与宿主强制策略，而不是“容器”“沙箱”等名称。

## 2. 目标

1. 在工作负载可能恶意的前提下运行 Claude Code、Codex、dsh、MCP、构建脚本、浏览器和普通开发工具。
2. 阻止工作负载读取宿主秘密、未授权文件、其他工作区或宿主服务 socket。
3. 支持 OCI 镜像与 Dockerfile，但不开放 Docker daemon API。
4. 向最终用户提供“允许访问仓库”“允许调用模型服务”等意图级授权，而不是技术化基础设施配置。
5. 在 macOS 和 Windows 后端之上提供一致的生命周期、执行和审计语义。
6. 让每项安全声明都有可执行验收，并在控制不可用或状态不明确时 fail closed。

## 3. 首版非目标

- 抵御宿主管理员失陷、hypervisor 0-day、固件攻击和硬件侧信道。
- 支持 Windows Home、Intel Mac 或 Linux host 产品化。
- 支持 Docker Compose、Kubernetes、privileged workload、任意设备和宿主 bind mount。
- 兼容完整 Docker API 或 `docker.sock`。
- 提供 Jupyter 或托管 Code Interpreter 平台。
- 自动模拟任意镜像架构。
- 在默认执行链引入 gVisor 或 Wasmer。

## 4. 信任边界

```text
不可信域                                             可信宿主域

OCI 镜像 / Agent / 依赖
        |
        v
+---------------- Sandbox VM ----------------+        +---------------- Host ----------------+
| 独立 Linux guest kernel                    |        | Desktop UI / CLI                     |
|                                             |        |                                      |
| execd fork <-> containerd <-> runc          |<------>| Sandbox Controller                   |
|                       |                     | socket | OCI Image Service                    |
|                       v                     |        | Workspace Sync                       |
|                  OCI workload              |        | Credential + Network Broker          |
|                                             |        | Keychain / Credential Manager        |
| 私有 COW、默认拒绝网络                      |        | Audit Log                             |
+---------------------------------------------+        +--------------------------------------+
```

VM 是首版唯一强安全边界。namespace、cgroup、seccomp、`runc`、`execd` 和 MCP 都只是兼容层或纵深防御，不提升产品保障等级。

Host 与 Guest 使用同一套身份、资源、操作、授权、决策、原因码和审计语义：Host 决策是权限上限，Guest 只能进一步收紧，不能放宽。macOS 与 Windows 通过不同平台机制实现相同契约。完整分层、Guest 内控制和跨边界一致性见[Host 与 Guest 双层统一安全体系](../design/two-layer-security-model.md)。

## 5. 核心内部契约

### 5.1 `SandboxRuntime`

平台无关生命周期接口至少包含：

- `create`
- `start`
- `stop`
- `suspend`
- `resume`
- `destroy`
- `inspect`
- `resolveEndpoint`

状态固定为 `Pending`、`Running`、`Suspending`、`Suspended`、`Resuming`、`Stopping`、`Stopped` 和 `Failed`。每次转换记录稳定 reason code、时间戳和 correlation ID。

### 5.2 `WorkloadSpec`

宿主 OCI Service 把不可信 OCI config 编译为白名单式 `WorkloadSpec`。首版仅允许：

- entrypoint 与参数；
- 受控环境变量；
- 工作目录；
- 声明式服务端口；
- CPU、内存、磁盘和进程数提示。

镜像 `User` 只作为提示处理：默认重写为固定非 root UID；确实需要 guest root 的镜像必须显式拒绝或按产品策略映射到受限 UID，不能由镜像自行决定。镜像 `Volumes` 默认忽略，仅在映射到受控 workspace/volume 描述时保留，不作为隐式数据面授权。

必须拒绝：host namespace、host device、任意 bind mount、额外 capability、privileged、seccomp/LSM 覆盖、BPF/perf/module 管理权限、daemon socket 和 provider-specific 逃生字段。必须明确：OCI image config 本身不含这些字段，它们可能来自运行时输入或 Docker 兼容 API，同样按白名单拒绝。

### 5.3 `CredentialGrant`

凭据能力绑定以下维度：

- 用户、工作区、sandbox 和 Agent 身份；
- scheme、host、有效端口、method 与 path；
- bearer、API header 等注入形态；
- 签发时间、过期时间、可选次数和速率限制。

Grant 只引用逻辑凭据，不承载真实值。

## 6. 宿主组件

### 6.1 Desktop UI 与 CLI

默认交互只展示用户意图：

- 允许本次任务读取或修改选定工作区；
- 允许访问指定仓库；
- 允许调用指定模型或 API 服务；
- 允许本次任务联网；
- 任务结束后保留或销毁环境。

普通用户不需要理解 image entrypoint、sidecar、RuntimeClass、CIDR 或 credential 注入细节。高级镜像选择属于独立开发者入口。

### 6.2 Sandbox Controller

Controller 是宿主策略执行点：

1. 校验请求与用户授权。
2. 生成受限 `WorkloadSpec`。
3. 选择 VZ 或 Hyper-V adapter。
4. 强制 CPU、内存、磁盘、时长、进程、日志和 endpoint 配额。
5. 协调 VM、guest agent、工作区、Broker 与审计生命周期。
6. 在异常退出或宿主重启后回收孤儿 VM、COW、snapshot 和 grant。

不可信 API 字段不得直接透传到 hypervisor。

### 6.3 macOS Adapter

macOS 后端使用 `Virtualization.framework` 启动 Linux arm64 VM。VZ 不验证 Linux boot asset 签名，宿主必须在启动前按 manifest 校验 kernel、initrd 和 root disk 的 digest/signature，并配置：

- 只读基础盘与每 sandbox 独立 COW；VZ 无原生差分盘机制，当前候选是产品宿主侧 APFS `clonefile`，不是 VZ snapshot；实现路径必须经过真实 APFS、空间耗尽、崩溃恢复和 cleanup 失败 POC 后冻结；
- virtio block、entropy、balloon 和 network；
- 仅宿主可达的 VZ Socket 控制通道；
- 启动时固定的内存上限与 vCPU 上限；VZ 无公开 CPU 时间硬配额 API，CPU 强制行为以 POC 实测冻结，不能用宿主调度优先级伪装成硬限额；
- 工作负载不可读的串口诊断；
- 经过生命周期与秘密检查的 suspend/resume。

工作区默认快照式导入、确认（暂存）式导出到 guest 私有盘，不做双向实时同步，不把 `virtiofs` 宿主直挂作为默认数据面。

### 6.4 Windows Adapter

Windows 后端直接管理 Hyper-V Generation 2 Linux VM，并配置：

- 受支持时启用 Secure Boot 的签名启动资产；
- 只读基础 VHDX 与每 sandbox 差分 VHDX；
- 仅宿主可达的 Hyper-V Socket；
- 受产品策略约束的 checkpoint；
- 宿主强制内存、磁盘和生命周期限额；CPU 使用 Hyper-V 原生 reserve/limit/weight 实施，并以 POC 实测冻结。

Windows 11 上缺少成熟的 HCS LCOW v2 客户端路径，不等于 Hyper-V Gen2 不可用。首版直接管理 Hyper-V VM，不依赖 LCOW。

### 6.5 OCI Image Service

OCI 服务执行：

1. Registry 解析与认证。
2. 为 `linux/arm64` 或 `linux/amd64` 选择 manifest。
3. Digest pinning 与可选签名、provenance 策略。
4. 内容寻址 blob cache。
5. 解包前后的总大小、文件数、路径、symlink、hard link、device node、setuid/setgid bit、whiteout（`.wh.`）应用安全和压缩比检查。
6. OCI config 到 `WorkloadSpec` 的策略编译。
7. 感知活动 COW 与 snapshot 引用的垃圾回收。

镜像 metadata 永远是输入，不是权限来源。架构不匹配时明确失败；模拟必须作为单独兼容模式显式开启。

### 6.6 Builder Service

Dockerfile 在独立、短生命周期 Builder VM 中由 BuildKit 执行：

- Builder 拥有独立磁盘、网络策略和身份。
- 默认看不到宿主文件、runtime VM 磁盘和生产 Broker 凭据。
- Build secret 必须显式、短期并绑定单次构建。
- 宿主只按 digest 导入构建产生的 OCI artifact。
- Build cache 复用时仍按不可信输入处理。
- 构建完成后销毁 COW 和临时能力。

### 6.7 Workspace Sync

工作区从用户显式选择的根目录导入到 guest 私有盘，导出修改是独立能力。实现必须防御：

- `..` 和绝对路径穿越；
- symlink 替换与 hard-link 别名；
- 大小写折叠差异；
- Windows alternate data stream；
- TOCTOU race；
- 删除和覆盖宿主未授权内容。

路径校验优先使用 descriptor-relative 或等价 race-safe API，不能只做字符串前缀判断。宿主 home、SSH、云凭据和 Docker 配置目录不隐式导入。

快照、冲突、Git metadata 和导出恢复语义见[工作区导入、同步与导出设计](../design/workspace-sync.md)。

### 6.8 Credential 与 Network Broker

真实凭据按请求从 Keychain 或 Credential Manager 读取。若 CLI 必须看到环境变量才能启动，guest 只能得到空值或假值；宿主代理在最终目标完成解析和授权后才注入真实 header。

出口网络默认拒绝。Broker 必须：

- 阻断 loopback、private、link-local、multicast、unspecified 和 metadata 地址；
- 对每次 redirect 重新授权；
- 同时约束 hostname 和解析后的目标；
- 在 DNS、TLS、proxy 或策略状态不确定时拒绝；
- 对 DoH/ECH 制定显式策略，避免其绕过目标检查；
- 不记录 secret-bearing header、body 或 token。

审计只记录 grant ID、目标、决策、原因、时间、字节数和 correlation ID。

Broker-only 网络拓扑、HTTPS 限制和各类客户端的凭据注入方式见[网络与凭据 Broker 设计](../design/network-credential-broker.md)。

### 6.9 MCP Gateway

可信宿主 MCP Gateway 把少量工具映射到固定 capability，不暴露原始 hypervisor、mount、image 或网络配置：

- 需要长期凭据的 MCP 默认运行在宿主侧。
- 纯计算 MCP 可以作为 guest OCI workload。
- 每次工具调用绑定当前 sandbox 和用户 grant。
- Guest 不能在没有显式用户操作时注册新的宿主能力。

## 7. 来宾组件

### 7.1 最小 Linux Guest

Guest image 只包含 kernel、init、必要 virtio/VMBus driver、`containerd`、`runc`、裁剪后的 `execd`、网络 bootstrap、更新校验和诊断组件。默认没有 SSH server 和通用管理账户。

所有 guest asset 都版本化并签名。宿主在 workload 启动前校验预期 digest 并完成协议协商；不支持或降级版本必须失败关闭。

### 7.2 `containerd + runc`

`containerd` 在 guest 内管理 content、snapshot 和 task 生命周期；`runc` 使用 Linux namespace、cgroup、capability drop、`no_new_privs` 与固定 seccomp policy 创建进程。

Containerd socket 不离开 guest，只允许可信 guest control process 访问；workload container 不获得该 socket。同一 VM 内的所有容器必须属于同一凭据授权域，因为它们共享 guest kernel。

Guest 基线同时启用经验证的 SELinux 或 AppArmor profile、只读基础 rootfs、受控 mount、非 root workload 和默认拒绝网络。eBPF 仅作为可信 Guest 基础设施的可选策略或可观测性机制；workload 禁止 unprivileged BPF，不获得 `CAP_BPF`、`CAP_PERFMON`、`CAP_SYS_ADMIN` 或 `CAP_SYS_MODULE`，且不能访问 `bpffs`。具体规则见[Host 与 Guest 双层统一安全体系](../design/two-layer-security-model.md)。

### 7.3 OpenSandbox `execd` 小型 Fork

首版保留：

- direct argv 与显式 shell 执行；
- foreground SSE 与有界保留的 background log；
- PTY 创建、resize、attach 和断线处理；
- 受限目录内的文件上传、下载、metadata、移动和删除；
- signal、session、process status 与 CPU/内存指标；
- init、signal forwarding 与 orphan reaping。

首版删除或关闭：

- Jupyter 和 Code Interpreter context；
- 到任意 guest port 的通用 reverse proxy；
- 未使用的 isolated-session 模式；
- 无限制全文件系统访问；
- 未认证业务 endpoint。

Execd 流量通过 VZ Socket 或 Hyper-V Socket transport adapter。一次性 bootstrap challenge 绑定 VM identity、sandbox ID、boot nonce、协议版本和预期 guest asset digest；session token 短期、可轮换，不能跨 VM 使用。

握手、临时身份、消息重放防护和启动完整性边界见[控制通道与启动完整性设计](../design/control-channel-security.md)。

## 8. 生命周期

### 8.1 创建与运行

1. UI 把用户意图解析为 `SandboxRequest` 和 capability。
2. Controller 校验策略、配额和平台可用性。
3. OCI Service 解析、验证镜像并生成 `WorkloadSpec`。
4. Platform adapter 创建 COW 并启动 VM。
5. 宿主与 guest 完成带身份绑定的 bootstrap。
6. Guest containerd 通过 runc 启动 workload。
7. Execd 报告经过认证的 readiness 后，Controller 才发布 `Running`。

### 8.2 Suspend 与 Resume

Suspend 前撤销活动网络 grant。由于长期凭据从不进入 guest，snapshot 不应含长期 secret。Snapshot 必须加密并绑定 sandbox identity 与 guest asset 版本。Resume 时重新签发短期 channel credential并重新验证 grant，不恢复已过期 capability。

### 8.3 Destroy

Destroy 顺序固定为：撤销 grant、关闭控制通道、终止 VM、移除 COW 和 snapshot 引用、记录完成。清理失败时保持 `Stopping` 或 `Failed`，不得乐观报告已销毁。

## 9. 版本与上游策略

- Desk Box 自有并版本化 desktop lifecycle contract。
- OpenSandbox spec 只是语义参考，不动态成为产品契约。
- Execd fork 固定到已审计的上游 release，生产环境不跟随 `main`。
- 上游升级必须通过 license、NOTICE、SBOM、依赖漏洞、patch rebase、API diff 和安全回归。
- Guest asset 与宿主应用升级都必须支持签名验证、失败回滚和 downgrade protection。

## 10. 分阶段实施

平台最低版本和 VZ/Hyper-V 能力在实现前按[平台能力与最低版本矩阵](../design/platform-capability-matrix.md)完成 POC 并冻结。

### Phase 1：安全契约与接口冻结

定义 `SandboxRuntime`、`WorkloadSpec`、lifecycle state、`CredentialGrant`、audit event 和拒绝原因；建立跨平台 conformance test 骨架。

### Phase 2：macOS 垂直切片

完成 OCI pull、安全解包、单台 VZ VM、认证 socket、execd command、私有工作区导入和确定性销毁；暂不开放通用网络。

### Phase 3：Broker 与 Dockerfile

实现宿主网络/凭据 Broker 和隔离 BuildKit Builder VM；使用 canary credential 验证 Claude Code、Codex、Git 和包管理器。

### Phase 4：Windows 对齐

实现 Hyper-V Gen2、差分 VHDX、Hyper-V Socket 和等价生命周期；在架构允许时复用同一 guest image 构建链和 contract。

### Phase 5：加固与 UX

完成 suspend/resume、崩溃恢复、更新回滚、capability prompt、审计、并发配额和对抗测试。

## 11. 发布门槛

以下任一测试成功即阻断发布：

- 读取宿主 secret 或未导入的宿主文件；
- 访问其他工作区或 sandbox 控制通道；
- 访问权限范围外的 Docker/containerd socket；
- 访问未授权互联网、私网、loopback、link-local 或 metadata；
- 跨 sandbox identity、重启、过期或撤销重放 capability；
- 通过路径、链接、设备或资源滥用逃逸 OCI 解包；
- 恢复已销毁的 COW、token、build secret 或 snapshot；
- 让 Broker、guest transport 或清理流程 fail open；
- 在未显式切换产品模式时从 VM 静默降级到 WSL2、容器或宿主进程。

只有这些安全门槛通过后才设定性能目标，不为冷启动或密度放宽安全属性。

每项门槛对应的责任组件、自动化测试和证据要求见[安全验证追踪矩阵](../security/security-verification-matrix.md)。
