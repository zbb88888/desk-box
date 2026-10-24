# M1-2 控制通道 TLS 1.3 双向认证升级

状态：开发计划（M1-2，待实现）
范围：macOS 宿主 + Linux guest 的控制通道加密与身份认证升级
父文档：[control-channel-security.md](control-channel-security.md)、[two-layer-security-model.md](two-layer-security-model.md)

## 1. 目标与范围

将当前"hello/ack 基于 boot 绑定"的**明文 VSOCK 控制通道**升级为 **TLS 1.3 双向认证**会话：

- 密钥/证书在每次 boot 临时生成（ephemeral），不做长期 PKI；
- 会话凭证与 `BootContext`（sandboxID/bootID/bootNonce/manifestDigest/protocolMajor）强制绑定；
- handshake 完成后，exec/readiness 等敏感帧才能生效；
- TLS 任何失败 fail closed，不会回退明文。

### 明确不做

| 项 | 原因 |
|----|------|
| CA 层次 / 公网 PKI / OCSP / CRL | 每 boot ephemeral 已满足威胁模型 |
| Session resumption / 0-RTT | 复用引入跨 session 重放面 |
| TLS 1.2 及以下 | 统一 TLS 1.3-only |
| 证书轮换 / rekey | M1-2 单会话生存期 = 单次 boot |

## 2. 与现有 MVP 的关系

M0/M1-1 已有能力不丢：

- `BootstrapHello`/`HelloAck` 仍然是**握手前的 boot 绑定证明**（发现配置错误/串线）；
- `LifecycleMachine.running` 仍然要 `BootstrapProof`，但 proof 的 `sessionID` 必须来自 **TLS 会话指纹**，不能只是 HelloAck 里自造 UUID；
- 新状态：`bootstrap=tlsAuthenticated`（M1-2 完成后是 `running` 的必要条件）。

过渡策略（兼容期）：

- `VZRuntime` 增加 `ControlSecurityPolicy.requiresTLSUpgrade`，**默认 false**（MVP 行为不变）；
- 为 true 时，exec 前必须有已建立的 TLS session；TLS 未实现的路径直接 fail fast（不会静默降级）。

质量约束：M1-2 完整落地后，**feature 默认改为 true**；生成 release 构建必须 true。

## 3. 具体实现参考方向

### 3.1 宿主侧（Swift / macOS API）

~~首选：`Security.framework` 的 `SSLCreateContext` + 自定义 I/O 回调~~

**决策修正（M1-2 开发期实测）**：`Security.framework` 的旧 SecureTransport **不支持 TLS 1.3**——`SSLSetProtocolVersionMin(.tlsProtocol13)` 在运行时被拒绝（见 M1-2a 切片中复现的 `handshake error … -9830`）。TLS 1.3 在 Apple 平台上的官方实现位于 **Network.framework**。

宿主侧正确实现路径（点击进入代码的桥接方案）：

1. 在进程内创建 `NWListener`，监听 **本机 Unix domain socket**（`~/.deskbox/tls-bridge-<uuid>.sock` 还临时路径，以 kSecScopeLocal 限定）；
2. `NWConnection` 在 `newConnectionHandler` 中作为 **TLS 1.3 服务端** accept（`NWParameters(secProtocolOptions:)` 应用 `sec_protocol_options_set_min/max_tls_protocol_version(.TLSv13)` + 证书）；
3. 进程内启动一个 *byte pump*：`VZVirtioSocketConnection.fileDescriptor` ⇄ 该 NWConnection 的 raw transport（recv/send HPack-like record forwarding）；
4. TLS record 密钥材料在进程内部产生，不经网络 —— VSOCK/pipe 仅承载密文 vs 明文的进出；
5. 完成 handshake 之后派生 sessionID（见公式 §3.3）；
6. 失败即不能成立 TLS 会话 → fail closed。

风险权衡：本方案在宿主内引入了 Unix 域桥接 socket（文件系统路径），但仅限宿主本机访问；比原 `SSLCreateContext`（因不支持 TLS 1.3 已被排除）更贴近 Apple 推荐 API。如果桥泵太复杂，第二候选方案是 `swift-crypto` 的 handshake 板独立在 DeskBoxCore 里实现 （工作量大，不推荐首发）。

凭据绑定：
- host cert 的 DER 计算 SHA-256，作为 helloAck payload 的一部分传给 guest；
- 或者 host cert fingerprint 通过 kernel cmdline `dbx.hostfp=`（更直接，不需要额外往返）。
- **M1-2b（落地）**：用 `swift-crypto` 进程内生成每 boot ephemeral 证书。

### 3.2 Guest 侧（C / 静态库）

候选 TLS 库对比（都在 Docker linux/arm64 构建）：

| 库 | 体积 | 评估 |
|----|------|------|
| OpenSSL 1.1/3 static | +约 4–8MB | 生态最稳，TLS 1.3 成熟；但接入成本高 |
| mbedTLS | +约 200–400KB | 体积小、API 直接；能满足 TLS 1.3 + EC 证书 |
| wolfSSL | +约 300–600KB | 商业友好、嵌入式场景成熟 |

**推荐：mbedTLS**（首次切片），理由：
- 体积适合 initramfs（当前 ~40MB，不会炸到 >50MB）；
- 在 guest 上生成每 boot ephemeral EC P-256 自签证书步骤少；
- 指纹直接是 `mbedtls_sha256(der)`；
- 失败情况简单 fail。

构建接入点：`macos/scripts/build-alpine-guest.sh` 里 `apk add mbedtls-dev mbedtls-utils openssl-libs-static`（或源码编译 mbedtls，把 `.a` 复制进来），`guest-bootstrap.c` 增加 `#include <mbedtls/ssl.h>`。

Guest 流程：
1. hello 之前握手或 helloAck 后升级（设计选择：**hello 完成后立即升级，`HelloAck` 仍明文但带 host cert fingerprint**）；
2. 生成 ephemeral key + 自签证书（`mbedtls_entropy`、`mbedtls_pk`、`mbedtls_x509_crt_self_signed`）；
3. 验证 host 证书 fingerprint == 我们刚在 helloAck 里读到的值；
4. handshake 完成 → 派生 session key；
5. 后续 `send_frame`/`recv frame` 全部走 TLS record。

### 3.3 会话凭证绑定（sessionID 的新定义）

```
sessionID = SHA-256(
  "deskbox-m1-tls-v1" ||
  hostCertP256Fp || guestCertP256Fp ||
  sandboxID.raw || bootID.raw || bootNonce || manifestDigest || protocolMajor
)
```

`BootstrapProof.sessionID = sessionID`，即只有 handshake 完成才能产生合法 proof 材料。VZ host 端只需在 `handleControlFrame` 验证的 hello + TLS session established 之后才能转入 `running`。

### 3.4 状态机变化

```
pending → bootstrap=notConnected
        → bootstrap=helloAcceptedTLSRequired      (Hello 绑定通过, HelloAck 带 host cert fp)
        → bootstrap=tlsAuthenticating             (新)
        → bootstrap=tlsAuthenticated              (新; handshake 完成, sessionID 已派生)
        → LifecycleMachine.running                (proof.sessionID == tls sessionID)
失败任何一步 → failed → stop/destroy
```

### 3.5 代码落点

| 文件 | 待增内容 |
|------|----------|
| `DeskBoxCore/ControlProtocol.swift` | 新增消息/状态枚举、reason code、session 描述结构 |
| `DeskBoxCore/SandboxRuntime.swift` | `BootstrapState` 增加 `tlsAuthenticating/tlsAuthenticated`；`ControlSecurityPolicy` 描述 |
| `DeskBoxVZ/SecureSession.swift`（新） | `SSLCreateContext` 封装，fd read/write 回调，handshake/sessionID/verify |
| `DeskBoxVZ/VZRuntime.swift` | `installControlListener` 后 TLS upgrade；send/receive 走 TLS；与 record/BootstrapProof 绑定 |
| `macos/scripts/guest-bootstrap.c` | mbedTLS 静态库接入，证书生成、handshake、TLS record IO |
| `macos/scripts/build-alpine-guest.sh` |  mbedtls-dev/openssl-libs-static + 编译开关 |
| `macos/Tests/...` | TLS config 或 policy 层单测 + 编解码测试 + fail-closed 测试 |
| `dbx-poc/main.swift` | `--tls` flag 打开 requiresTLSUpgrade + 断言可执行 |

## 4. 实施步骤（按顺序，各自带验证门）

1. **设计锚定**：本文档 + `ControlSecurityPolicy` + reason codes + `BootstrapState` 扩展 + fail-closed 语义代码化（默认允许旧行为，显式开启新行为）。验收：`swift test` 全绿；
2. **Host TLS 开发态**：`SecureSession` 抽象 + 开发态静态证书注入、SSLHandshake 流程、SSLSetProtocolVersion TLS13；验收：单测挡住 escalate；
3. **构建链**：`build-alpine-guest.sh` 增加 mbedtls（或 OpenSSL-static）依赖，静态 guest bootstrap 编译成功；验收：`ldd` 无关、二进制 < 12MB；
4. **Guest TLS**：证书生成 + 客户端握手 + host fingerprint 校验；验收：与上面发现（handshake 完整跑通）；
5. **通道切换**：`send_frame`/`readAvailable` 通过已建立 TLS session 的 record 读写；welcome in `updateSocket`；验收 CLI + real regression；
6. **绑定 proof**：sessionID = SHA256(tls record) 计算并写 `BootstrapProof`；验收 `bootstrap=tlsAuthenticated`；
7. **默认开启**：`requiresTLSUpgrade = true`，回归 M0 全部场景不漏；
8. **文档与 horizon**：security-verification-matrix 补 TLS 证据条目。

## 5. 验收标准（release 级）

- host/guest handshake 必须协商且仅 `TLS 1.3`；尝试 TLS1.2 → fail；
- host 证书 fingerprint != 传入 guest 期望 → guest fail；
- guest 证书不一致 → host fail；
- 旧 boot 的证书重放 → fail（bootNonce/sandboxID 混入 sessionID）；
- `authenticated` 之前 exec → deny，reason `DBX-BOOT-TLS-REQUIRED`；
- `sweepOrphans` 不受影响（TLS 失败时只需 stop/destroy）；
- 真机连续 3 次回归 exit 0，exec 两次独立结果正确（已有回归行为不得回归）。

## 6. 风险与回退

| 风险 | 缓解 |
|------|------|
| ✅ 已发生：`SSLCreateContext` 不支持 TLS 1.3（实际复现 `handshake error … -9830`） | 转向 Network.framework 的 Unix bridge（§3.1 修正） |
| Guest 静态 TLS 库带体积膨胀 | 选 mbedtls；若 >12MB，裁剪 x509/CA/theme |
| Signing/notarization 对 SSL 代码路径影响 | 需要 entitlements 现有，`libssl` 静态链接不增加 entitlement；在 signing step 校验 `codesign --verify` |
| 双明文明 hello 后的 race（第 2 次 hello vs TLS） | listener 已独占首个连接；二次连接被丢弃，TLS 升级仅在首连接上进行 |

## 7. 参考材料（实现时优先查阅）

- `Security/SecureTransport.h`：`SSLCreateContext`、`SSLSetIOFuncs`、`SSLHandshake`、`SSLGetPeerCertificate`、`SSLSetProtocolVersion`；
- Network.framework 定制 transport 备选：`NWProtocolFramer`、`NWConnection`（必要时迁移）；
- mbedTLS：`mbedtls_ssl_conf_authmode(MBEDTLS_SSL_VERIFY_REQUIRED)`、`mbedtls_x509_crt_write_self_signed`；
- Swift 侧生成自签证书：`swift-crypto` / 编译 `x509_cert_gen.c` 用系统 OpenSSL（静态，调试期保留 phase 路线）；
- OpenSandbox `execd`（参考代码在 `references/`，仅看架构不复制产品代码），特别是终端/控制通道分离；
- macOS APFS/registry 已完成的孤儿回收参考（`SandboxRegistry`），TLS session 信息与 registry 交叉绑定暂不涉及（M1-3 边界）。
