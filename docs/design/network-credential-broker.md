# 网络与凭据 Broker 设计

状态：实施设计草案，关键协议待 POC
日期：2026-10-23

## 1. 目标与约束

Broker 必须同时满足：

- Guest 与 workload 默认不能直接访问外部网络；
- 长期凭据只存在于 macOS Keychain 或 Windows Credential Manager；
- 每次外部访问都绑定用户、工作区、sandbox、Agent、目标和期限；
- DNS、redirect、IPv4/IPv6、代理或策略状态不明确时 fail closed；
- 不通过通用 TLS 中间人假装支持所有 CLI。

关键事实：对于端到端 HTTPS，普通 `CONNECT` 代理看不到加密后的 method、path 和 header，因此不能在不终止 TLS 的情况下向请求注入认证 header。任何声称“透明支持所有 CLI 且真实凭据不进 guest”的实现都必须说明协议适配或 TLS 终止方式。

## 2. 网络拓扑决策

强隔离模式采用两条分离通道：

1. **管理通道**：Controller 与 `execd` 通过 VZ Socket 或 Hyper-V Socket 通信，不使用 guest 普通 IP 网络。
2. **数据出口通道**：Guest 内无直接 NAT 默认路由。受控转发器把明确配置的请求通过宿主/来宾 socket 交给 Broker，由 Broker 完成目标解析、策略判断和上游连接。

```text
workload
   |
   | localhost / Unix socket / configured proxy
   v
受限 guest forwarder
   |
   | VZ Socket / HVSock，带 sandbox 会话身份
   v
Host Broker -> Policy -> DNS -> TLS -> approved upstream
   |
   +-> Credential Provider -> Keychain / Credential Manager
```

Guest 防火墙是纵深防御，不是唯一执行点。平台 adapter 必须证明 guest 没有绕过 Broker 的直连网卡、NAT、桥接或宿主代理路径。若某平台不能强制该属性，强隔离模式不得启用网络。

Guest 内的 DNS 应答路径必须显式归属：客户端自行发起 `getaddrinfo` 时，查询只允许到达 forwarder 内置的受限 DNS responder（由 Broker 策略应答或返回映射地址），否则直接失败；guest 不存在绕过 forwarder 的 DNS 出口。Responder 的具体实现在 POC 中冻结。

## 3. 出口决策流程

每个请求按固定顺序处理：

1. 验证控制会话和 `CredentialGrant` 未过期、未撤销且属于当前 sandbox。
2. 解析规范化 scheme、hostname、有效端口、method 和 path。
3. 使用宿主解析器解析目标，并拒绝 loopback、private、link-local、multicast、unspecified、metadata 和策略禁止地址。
4. 同时授权 hostname 与全部候选 IP；连接后核对实际 peer address。
5. 执行 TLS 校验，不允许用户或 guest 静默关闭证书验证。
6. 仅在协议适配器确认最终目标后读取并注入凭据。
7. 对每次 redirect 从第 2 步重新执行，不继承原决定。
8. 记录不含秘密的决策事件，并应用字节数、速率、次数和时长限制。

DNS pinning 只在一次授权连接内有效；连接池复用必须保持相同授权上下文。DoH、ECH、QUIC 和任意 tunnel 默认不可用，只有专门适配并通过测试后才能开放。

## 4. 凭据模型

### 4.1 凭据分类

- **长期凭据**：API key、refresh token、SSH private key、长期 cookie；不得进入 guest。
- **短期派生凭据**：范围受限、短时有效、可撤销的 access token；只有具体产品场景经过安全评审后才可进入 guest，默认仍不进入。
- **逻辑句柄**：guest 可见的 provider/grant 标识，不包含可用于认证的材料。

Windows 平台约束：Credential Manager 通用凭据 blob 上限为 2560 字节（`CRED_MAX_CREDENTIAL_BLOB_SIZE`），无法容纳 RSA-4096 等较大 PEM 私钥；这类秘密改用 DPAPI 加密文件等等价机制存储，并纳入 Windows POC 验证。

`CredentialGrant` 至少绑定：用户、工作区、sandbox、Agent、provider、scheme、host、端口、method、path、注入方式、签发与过期时间、次数和速率限制。

### 4.2 注入规则

- Broker 只在最终上游连接已通过策略后从 credential store 读取秘密。
- 秘密仅进入对应协议适配器的短生命周期内存，不写入日志、磁盘、crash dump 或通用 cache。
- 多个 grant 同时匹配且权限不同，必须拒绝并要求消除歧义。
- Broker 重启、sandbox suspend、用户锁屏或授权撤销后，活动 grant 默认失效。
- Guest 中要求 `API_KEY` 一类变量的工具只得到假值；假值仅用于通过客户端启动校验，不能在任何上游生效。

## 5. 协议支持矩阵

| 场景 | 首版实现方式 | 长期凭据进入 guest | 状态 |
| --- | --- | --- | --- |
| Claude/Codex 等 HTTP API | 配置受信任 base URL 指向 guest forwarder；宿主适配器重建并发送 HTTPS 请求 | 否 | 待 POC |
| 无认证 HTTP/HTTPS 下载 | 显式 HTTP proxy 或 Broker fetch API；目标仍受策略约束 | 不适用 | 待 POC |
| 通用 HTTPS `CONNECT` | 仅提供目标级联网，不注入凭据，也看不到加密 path/header | 否 | 可支持，但权限粒度较粗 |
| Git HTTPS | 优先宿主侧 Git service 或专用 remote helper；不向 guest credential helper 返回长期 token | 否 | 待 POC |
| Git SSH | 宿主签名代理或受限 Git service；按 host/repository 约束，禁止通用 agent forwarding | 否 | 待 POC |
| npm/pip/cargo 等私有仓库 | 专用包代理，由宿主向已配置 registry 注入认证 | 否 | 按生态逐项 POC |
| MCP | 需要长期凭据的 server 默认运行在宿主，由 MCP Gateway 进行 capability 映射 | 否 | 架构已决策 |
| 任意私有协议 | 不提供透明凭据注入 | 否 | 首版不支持 |

若客户端不支持 base URL、proxy、remote helper 或专用协议适配，则严格模式下应明确报告“不兼容”，不能退化为把长期 secret 写入 guest 环境变量。

## 6. TLS 与代理边界

首版不提供通用透明 TLS MITM。原因是：

- 需要向 guest 安装受信任 CA，扩大高权限面；
- 破坏 certificate pinning 和部分客户端协议；
- 容易把“可观测全部明文”扩大为非必要数据收集；
- 仍不能保证所有非 HTTP 协议正确工作。

专用 HTTP API 适配器由宿主直接建立上游 TLS，guest 只与本地 forwarder 通信。若未来引入 TLS 终止，必须单独 ADR、限定 provider、提供用户可见标识，并完成隐私与 pinning 兼容评审。

## 7. 审计与隐私

允许记录：grant ID、sandbox ID、provider、规范化目标、method、策略结果、reason code、时间、持续时长和字节数。

禁止记录：Authorization、Cookie、请求/响应 body、credential-bearing URL、prompt、模型响应、私钥、token 和其稳定哈希。

用于故障诊断的 payload capture 默认关闭，不能由 guest 开启；如产品未来需要，必须由用户对单次会话显式授权并执行二次脱敏。

## 8. 故障与撤销

- Broker、策略引擎、DNS、credential store 或审计关键路径不可用时拒绝新请求。
- 已建立连接在 grant 撤销后立即关闭；无法确认关闭时终止对应 sandbox 网络通道。
- Broker 不自动重试非幂等请求。
- Suspend 前关闭连接并撤销 session；resume 后重新授权。
- 清理失败必须进入可见的 `Failed` 状态，不得报告权限已撤销。

## 9. POC 验证门槛

1. 证明 guest 无法绕过 Broker 访问互联网、宿主、局域网和 metadata 地址。
2. 使用 canary secret 验证 guest 环境、文件、日志、COW、snapshot 和 packet capture 不含长期凭据。
3. 验证 DNS rebinding、redirect、IPv4/IPv6 编码、代理链、连接池和撤销行为。
4. 分别验证 Claude、Codex、Git HTTPS、Git SSH 和至少一种包管理器；不兼容项必须明确记录。
5. 证明客户端无法通过假 base URL、用户 CA、DoH、QUIC 或 tunnel 绕过目标策略。
6. 对 Broker parser、URL canonicalization 和 provider adapter 进行 fuzzing。

通过 POC 前，本文只定义目标设计，不证明这些客户端已经兼容。
