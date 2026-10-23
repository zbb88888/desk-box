# 威胁模型与安全不变量

状态：首版安全契约
日期：2026-10-23

## 1. 范围

本文定义 Desk Box 在首版中必须兑现的安全属性、信任边界、主要攻击路径和发布阻断条件。它约束实现与测试，不宣称当前代码已经通过验证。

受保护资产包括：

- 宿主长期凭据、会话和 credential store；
- 未经用户授权的宿主文件、目录、设备和服务；
- 其他工作区、sandbox、Agent 与用户数据；
- 宿主 hypervisor、Controller、Broker 和更新链；
- OCI artifact、guest asset、审计记录和 capability 完整性；
- 用户对工作区、网络和凭据授权的真实意图。

## 2. 对手模型

假设以下对象可能恶意或已失陷：

- OCI 镜像、Dockerfile、构建脚本和安装脚本；
- Claude Code、Codex、dsh、MCP server、插件和依赖；
- 仓库源码、模型生成代码、prompt 内容和下载文件；
- guest 内 workload 进程，以及成功逃逸 `runc` 容器后的 guest root；
- Registry 返回的数据和网络响应；
- 已获取旧 token、旧 snapshot 或被撤销 capability 的攻击者。

首版不承诺抵御：

- 宿主管理员或宿主内核已失陷；
- 未修复的 hypervisor、固件或硬件漏洞；
- 微架构侧信道；
- 用户明确授权后服务端对数据的合法接收；
- 用户主动把秘密写入工作区或命令输入。

这些排除项必须在产品文档中清楚展示，不能隐藏在“安全沙箱”营销语言之后。

## 3. 信任假设

可信计算基包括：

- macOS/Windows、Virtualization.framework/Hyper-V 与平台 credential store；
- Desk Box UI、Controller、平台 adapter、OCI Service、Workspace Sync 和 Broker；
- 签名的 guest kernel、init、`containerd`、`runc` 和 `execd` fork；
- 更新签名、release metadata 和策略配置。

OCI workload 不可信。Guest kernel 是宿主边界的一部分，但不能接触长期凭据。Guest 内 container isolation 只提供纵深防御。

## 4. 十项安全不变量

### 不变量 1：强隔离任务始终位于独立 VM 边界

强隔离模式只能使用 VZ 或 Hyper-V Gen2 VM，不能静默降级到宿主进程、共享宿主容器、WSL2 distribution 或其他较弱模式。

证据：平台 conformance test、运行时 attestation、状态与审计记录、降级故障注入。

### 不变量 2：不同凭据授权域不共享 guest kernel

默认一台 VM 对应一个工作区和凭据授权域；高保障任务一台 VM 对应一个 Agent。共享 VM 内不得放置互不信任的授权域。

证据：调度约束、身份绑定测试、并发跨域攻击测试。

### 不变量 3：长期真实凭据永不进入 sandbox

Key、token、cookie、SSH private key 和云凭据只保存在宿主 credential store 与 Broker 内存。Guest 环境变量、文件、日志、snapshot 和 core dump 不含真实长期凭据。

证据：canary secret 扫描、snapshot/COW/日志取证、Broker 内存生命周期测试。

### 不变量 4：所有外部访问必须经过宿主强制策略

Guest 默认无任意出口。DNS、redirect、proxy、IPv4/IPv6、private/link-local/loopback/metadata、DoH/ECH 等路径必须被 Broker 明确允许或拒绝；策略不确定时拒绝。

证据：网络矩阵、DNS rebinding、redirect、地址编码、代理和 Broker 故障测试。

### 不变量 5：宿主文件访问只能来自显式工作区授权

工作区必须复制或安全同步到 guest 私有盘。禁止默认直挂宿主 home、credential 目录、Docker config、SSH 目录、socket 或设备。导入与导出分别授权。

证据：路径穿越、symlink/hard-link、大小写、ADS、TOCTOU 和并发替换测试。

### 不变量 6：OCI metadata 不能授予额外权限

Image config 与 Dockerfile 只能影响白名单 `WorkloadSpec`。Privileged、host namespace、host device、任意 mount、额外 capability、daemon socket 和安全策略覆盖必须被拒绝。

证据：恶意 config corpus、schema/property test、拒绝原因审计。

### 不变量 7：宿主与 guest 控制通道必须绑定具体 VM 身份

VZ Socket/HVSock 连接需验证 sandbox ID、VM identity、boot nonce、协议版本和 guest asset digest。Session token 短期、可轮换，不能跨 VM、重启或过期后重放。

证据：重放、串线、伪造 guest、版本降级和恢复旧 snapshot 测试。

### 不变量 8：资源和生命周期由宿主强制

CPU、内存、磁盘、进程数、日志、执行时长和并发数必须由宿主与 guest 双层限制。Workload 不能阻止 revoke、stop 或 destroy；清理失败不能报告成功。

证据：资源耗尽、fork bomb、日志洪泛、卡死关机、宿主崩溃恢复测试。

### 不变量 9：构建与运行域隔离

Dockerfile 只在短生命周期 Builder VM 中执行。Builder 不读取 runtime VM 磁盘、宿主工作区以外文件或生产 Broker 凭据；只返回按 digest 标识的 OCI artifact。

证据：build secret canary、cache 污染、跨构建读取和 artifact 验证测试。

### 不变量 10：更新、持久化与销毁不复活旧权限

Guest asset、应用和策略更新必须验证签名并防降级。Suspend/resume、snapshot、COW、cache 和 crash recovery 不得恢复过期 grant、旧 token、build secret 或已销毁数据。

证据：升级/回滚故障注入、旧 snapshot 恢复、卸载后磁盘扫描和孤儿资源回收测试。

## 5. 主要攻击路径与控制

| 攻击路径 | 首要控制 | 纵深控制 | 失败行为 |
| --- | --- | --- | --- |
| Workload 利用 Linux kernel/container runtime | 外层独立 VM | seccomp、capability drop、cgroup | 仍限制在 VM；终止并记录 |
| Workload 利用 hypervisor/device model | 最小设备面、及时更新 | 一授权域一 VM、无宿主 secret | 阻断 release；撤销所有 grant |
| 恶意 OCI layer 路径穿越或解压炸弹 | 宿主安全解包与配额 | 独立 cache、digest 校验 | 拒绝镜像 |
| 读取宿主文件或 socket | 私有工作区复制、无任意 mount | race-safe 路径 API | 拒绝操作 |
| 凭据从环境、文件、日志泄露 | 宿主 Broker 最终注入 | 短期 grant、日志脱敏 | 不发送请求并告警 |
| SSRF 到宿主、局域网或 metadata | 默认拒绝 Broker | DNS/redirect/IP 再校验 | fail closed |
| Guest 冒充或跨 VM 控制通道串线 | 身份绑定 bootstrap | 短期 session token | 关闭通道和 VM |
| MCP 工具越权 | 宿主 capability gateway | 每次调用绑定 sandbox/grant | 拒绝并审计 |
| Builder 污染 runtime | 独立 Builder VM | artifact digest 与 provenance | 丢弃产物和 builder |
| Snapshot 重放旧权限 | Resume 重新授权 | 加密、身份与版本绑定 | 拒绝恢复 |
| 资源耗尽影响宿主 | 宿主 VM 配额 | guest cgroup、日志上限 | 强制终止 |
| 更新供应链投毒 | 签名、digest、SBOM | rollback/downgrade policy | 保持旧可信版本 |

## 6. 凭据规则

1. 用户授权对象是“允许此任务调用某服务”，不是“把 token 交给 VM”。
2. `CredentialGrant` 必须同时绑定用户、工作区、sandbox、Agent、scheme、host、端口、method、path 与期限。
3. 真实凭据只在请求发送前读取，在宿主内按 provider 规则注入。
4. Redirect 到新目标时重新授权，不能继承原请求决定。
5. Hostname 与解析后地址都必须通过策略，防 DNS rebinding。
6. 相同请求匹配多个互不等价 grant 时拒绝，不能随意选一个。
7. Guest 只得到空值、假值或逻辑 credential handle，不得到真实长期值。
8. 审计不得记录认证 header、secret-bearing query/body 或 token 派生值。
9. Grant 撤销、过期、Broker 重启和 suspend 后默认失效，恢复需重新验证。

## 7. 工作区规则

- 用户必须显式选择导入根目录。
- 导入目标是 guest 私有文件系统；默认不使用宿主 live mount。
- 导出修改需单独确认目标和变更集。
- 路径授权以打开后的对象身份和根目录约束为准，不能只依赖字符串 canonicalization。
- Symlink、hard link、junction、reparse point、ADS、case collision 和特殊文件必须拒绝或标准化为普通安全对象。
- `.git` 是否导入由产品策略明确决定；宿主 Git credential helper 和 socket 不随之导入。
- 销毁时删除 guest COW、临时同步区和未确认导出数据。

## 8. 可观测性与隐私

安全事件至少包含：sandbox ID、workload digest、grant ID、操作类型、策略结果、稳定 reason code、时间和 correlation ID。日志默认有界并设置保留期。

以下内容禁止进入普通遥测：命令 stdin、完整文件内容、prompt、模型响应、Authorization/Cookie header、token、私钥和 credential-bearing URL。诊断包需要用户显式同意并再次脱敏。

## 9. 发布阻断条件

以下任一情况成立，不得宣称或发布强隔离模式：

- 任一十项不变量缺少自动化验收或验收失败；
- 控制失效时存在 fail open 路径；
- 长期凭据可在 guest 文件、环境、日志、COW 或 snapshot 中恢复；
- Workload 可接触宿主 daemon socket、未授权文件、其他工作区或其他 sandbox；
- 未授权私网、loopback、link-local、metadata 或互联网可达；
- Token 或 capability 可跨 VM、重启、用户、工作区、撤销或过期后重放；
- Builder 与 runtime 共享可写状态或生产凭据；
- Guest/host 更新不能验证签名、阻止降级或安全回滚；
- 清理失败仍对用户报告资源已销毁；
- 产品静默切换到较弱 isolation backend。

设计审查通过只说明方案合理，不等于实现已安全。只有实现、对抗测试、供应链证据和独立安全评估全部满足门槛后，才能提升安全声明。

十项不变量到责任组件、测试用例和发布证据的映射见[安全验证追踪矩阵](security-verification-matrix.md)。
