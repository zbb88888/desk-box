# 控制通道与启动完整性设计

状态：实施设计草案，握手协议待安全评审
日期：2026-10-23

## 1. 范围

本文定义宿主 Controller 与 guest `execd` 之间的身份、机密性、完整性、版本协商和重放防护，并说明启动完整性能够证明什么、不能证明什么。

VZ Socket 和 Hyper-V Socket 提供 VM 定向 transport，但 transport 可达性不等于应用层认证，更不等于远程证明。控制协议必须在其上建立独立、绑定具体 VM 实例的认证会话。

## 2. 威胁模型

需要防御：

- 其他 sandbox 连接错误 endpoint；
- 旧 VM、旧 snapshot 或旧 token 重放；
- 恶意 workload 访问 guest agent 的控制 socket 或密钥；
- 协议降级、消息篡改、乱序和跨会话重放；
- 未完成 asset 校验的 guest 被标记为 `Running`；
- Controller 或 guest 重启后复用旧授权。

不承诺：在 guest kernel 已完全失陷后区分真实 `execd` 与同 VM 内攻击者。此时外层 VM 仍是宿主边界，Controller 必须可撤销权限并销毁 VM。

## 3. 启动前验证

宿主在启动 VM 前必须：

1. 验证应用内置或下载的 guest manifest 签名。
2. 按 manifest 校验 kernel、initrd、root disk、`execd` 和策略 bundle 的 digest。
3. 检查版本未低于本机记录的安全最低版本，防止 downgrade。
4. 为本次 boot 生成唯一 sandbox ID、boot ID、nonce 和短期会话材料。
5. 只向选定 VM 实例配置专属 VZ Socket/HVSock endpoint。

只读基础盘和 digest 校验证明“启动输入符合预期”，不能证明运行期间 guest 未被攻破。若平台未来提供可用的测量启动或 attestation，应通过新 ADR 接入，不在首版中虚构该能力。

## 4. 每次启动身份材料

推荐使用标准 TLS 1.3 双向认证，而不是自定义密码学：

- Controller 为单次 boot 创建临时 CA 或等价的 pinned trust root。
- Host 与 guest 各获得仅对该 boot 有效的临时证书和私钥。
- Guest 私钥通过受限 bootstrap 介质交给 init/`execd`，workload container 不可见。
- 证书 SAN 或扩展绑定 sandbox ID、boot ID、角色、协议主版本和 guest manifest digest。
- 私钥只驻留内存；销毁、stop、suspend 和异常恢复时作废。

Bootstrap 介质对 guest root 可见是已知边界：guest root 失陷意味着该 VM 会话失陷，但材料不能用于其他 VM、其他 boot 或宿主服务。

## 5. 握手流程

```text
Controller                                     guest init / execd
    | 创建 VM 与专属 endpoint                         |
    |------------------------------------------------>|
    | transport 建连，平台返回目标 VM 上下文           |
    |<===============================================>|
    | TLS 1.3 mutual authentication                   |
    |<----------------------------------------------->|
    | ClientHello: 支持版本、随机 challenge            |
    |------------------------------------------------>|
    | ServerHello: boot/sandbox/manifest 绑定与签名证明 |
    |<------------------------------------------------|
    | 协商 capability、上限和 session ID               |
    |<----------------------------------------------->|
    | readiness + guest health                         |
    |<------------------------------------------------|
```

Controller 只有在以下条件全部满足后发布 `Running`：

- Transport endpoint 属于刚启动的 VM 实例；
- 双向证书链、有效期、角色和所有绑定字段正确；
- boot nonce 尚未使用；
- 协议主版本兼容，安全功能没有被降级；
- guest 报告的 manifest digest 与宿主预期一致；
- readiness 检查通过且未超时。

Guest 自报 digest 不是独立 attestation，只用于发现配置错误和协议串线；可信依据仍是宿主启动前校验和 VM 边界。

## 6. 消息层要求

即使 TLS 已提供传输保护，应用消息仍需包含：

- session ID；
- 单调递增 sequence number；
- request ID 与 correlation ID；
- deadline；
- operation 与所需 capability；
- 有界 payload 长度和流量窗口。

重复、倒序、跨 session、超时或未知 operation 一律拒绝。流式 SSE/WebSocket 语义应封装在认证通道中，不能另开未认证 TCP endpoint。

所有 destructive operation 必须幂等；`destroy`、`revoke` 和 `stop` 在响应丢失后可以安全重试。协议 parser 应使用有边界的结构化编码和生成式 schema，不接受动态对象反序列化。

## 7. 授权分层

通道认证只说明“连接属于哪个 VM 会话”，不自动授予所有操作：

- Controller 到 guest：按 session capability 限制 command、file、signal、metrics 等方法。
- Guest 到宿主：默认没有反向调用权限；网络、凭据、工作区导出和 MCP 分别校验独立 grant。
- Workload 不能直接访问 agent endpoint、bootstrap 介质或 session key。
- `execd` 不持有 hypervisor、宿主文件系统或 credential store 权限。

## 8. Suspend、Resume 与 Snapshot

- Suspend 前关闭控制会话并销毁 TLS session ticket 和网络 grant。
- Snapshot 不得包含仍可在宿主接受的有效私钥或 token。
- Resume 生成新 boot epoch 和临时证书，执行完整握手；旧 sequence 与 session ID 全部失效。
- Snapshot 必须加密，并绑定 sandbox ID、用户、guest manifest 版本和宿主策略版本。
- 任何绑定不匹配均拒绝恢复，不能自动回退到较弱验证。

若目标平台无法保证 snapshot 中会话材料失效，首版应禁用 suspend/resume，而不是降低不变量。

## 9. 密钥与日志处理

- 临时私钥优先存放不可交换的进程内存，并关闭对应 core dump。
- 不在命令行、环境变量、普通日志或 crash report 中传递密钥。
- 日志只记录证书指纹、boot/session ID、版本、结果和 reason code；不记录私钥、完整证书扩展中的敏感 payload 或明文业务数据。
- 每次应用退出和崩溃恢复都扫描并清理孤儿 endpoint 与会话材料。

## 10. 版本与降级策略

协议使用独立主版本和次版本：

- 主版本不兼容时拒绝启动。
- 次版本通过显式 capability negotiation；安全必需 capability 缺失时拒绝。
- Host 和 guest 都维护最低安全版本，取两者更严格值。
- 不允许 guest 请求关闭认证、完整性、审计或资源上限。

## 11. 验证门槛

1. 跨 VM endpoint 串线、旧 token、旧 snapshot 和旧 boot nonce 全部被拒绝。
2. 篡改证书绑定、manifest digest、角色或协议版本时握手失败。
3. Workload container 无法读取 bootstrap 介质、agent socket 或临时私钥。
4. 重放、乱序、超大消息、慢速流和 parser fuzz 不导致越权或资源失控。
5. Suspend/resume 后旧会话不可恢复。
6. Guest agent 崩溃、宿主崩溃和半开连接均进入可恢复且 fail-closed 的状态。
7. 密码学设计与实现经过独立安全评审。

通过这些测试前，文档只能声称“计划使用身份绑定的认证通道”，不能声称已具备远程证明或已验证启动完整性。
