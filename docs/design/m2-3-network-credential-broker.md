# M2-3：网络与凭据 Broker（macOS）

状态：M2-3a 已完成（真机双路径 exit=0）；关联 `docs/design/m2-roadmap.md`、`docs/design/network-credential-broker.md`、`docs/security/security-verification-matrix.md` INV-03、INV-04。

## 进度（M2-3a）

- ✅ `BrokerPolicy`：allowlisted hosts + schemes 只允许 HTTPS + maxResponseBytes，JSON 居 as 失败即拒；
- ✅ `CredentialBroker`：token 仅宿主存储（gitignored 、`broker-credentials.local`），注入只针对 allowlisted host；
- ✅ `BrokerService`：policy gate → 凭据注入 → URLSession → 响应限额截取 + sha256 的 `BrokerFetchReport`（audit 交付）；
- ✅ CLI `--broker-preload <url>`：拉取 → synthetic workspace file 推送 → guest sha256 终验；
- ✅ 真机验证：
  - `https://example.com`（白名单）`broker-fetch ok status=200 bytes=577` + `broker-sync ok`；
  - `https://internal.example.com`（白名单外）检出阶段拒：`host 不在 allowlist`；
  - `http://example.com`（scheme 不合）拒：`scheme 不允许`；
  - 默认加密 + `--allow-plaintext` 双路径 exit=0；
- ✅ 单测 5 个（allow/deny/host/scheme/injection/JSON round trip）全过；
- 下一步（M2-3b）：guest 主动请求的在线 broker 通道（guest→host `brokerFetch` 消息 + 独立 vsock port 数据面），并在 M2-3c 合并多凭据域调度。

## 1. 目标与非目标

### 1.1 目标（M2-3a：宿主侧 broker preload 管道）
- 沙箱 **默认零网络**（INV-04 不变）：guest 没有 NIC，不装网络驱动；全部外访只走宿主 broker；
- 凭据 **只放宿主**（INV-03）：明钥 / bearer token 永不出 host 压力面；guest 只能收到响应载荷（最多 64KiB 默认），无法访问凭据本身；
- 出站策略 **fail-closed allowlist**：host 侧 `broker-policy.json`（域名白名单 + 响应上限 + method allowlist）；任何不在列表的 host → 拒绝并审计；
- 实现路径：broker 拉取的内容作被人认可的 **工作区快照 synthetic file**（M2-1 管道）推送给 guest，guest 侧与正常 file 的 sha256 终验方式一致——不引入新的 guest 协议端点；
- 审计链完整：请求 URL / 结果 status / 字节数 / policy 决策侦值进入 stdout 审计与 report struct。

### 1.2 非目标（挂出）
- 非 HTTP 透传（私有 TCP）与 guest→host 在线请求（`brokerFetch` 消息）预留为 M2-3b：本阶段只在宿主侧车门，数据面仍是 host 主动推送；
- 凭据不会在 guest 面存在；可能小型共享 secret（簿论中用来签名 ad-hoc token 的派生）属后续工作；
- 不部署反向代理、不协同其他沙箱转发。

## 2. 实施参考

### 2.1 协议
复用 M2-1 workspace sync：host 把 broker 拉取的结果作为 synthetic file 推送到 `/workspace/inbound/<sha256-prefix>-<basename>`；guest 侧继承现有 ws sync 的 sha256 终验逻辑，无新增协议。

### 2.2 Host 落点

- `Sources/DeskBoxVZ/BrokerPolicy.swift`：
  ```json
  {"allowedHosts":["api.github.com","example.com"], "allowedSchemes":["https"], "maxResponseBytes": 65536}
  ```
  fail-closed 读取（找不到或 JSON 错误均拒绝）；
- `Sources/DeskBoxVZ/CredentialBroker.swift`：
  macos/guest/broker-credentials.local（gitignored），普通环境变量覆盖可注入（dev-only）；`Authorization: Bearer <token>` 头仅对 allowlisted host；
- `Sources/DeskBoxVZ/BrokerService.swift`：URLSession fetch（timeout 15s）、注入凭据、 body 按 policy 限额截取 + 写入沙箱前的 `BrokerFetchReport`；
- `Sources/dbx-poc/main.swift`：`--broker-preload <url>`：拉取 → 合成 synthetic 项推送到 workspace sync（如同时提供 `--workspace` 则合并快照），并在 guest wsAck 后正常完成流程。

### 2.3 Guest
无新增协议（复用 wsBegin/wsPut/wsEnd）；文件权限继承 M2-1，nobody 65534 所有权。

## 3. 验证（出样一步递增）
1. `launch --broker-preload https://example.com`（在 policy 的 allowlist 中）：`broker-fetch ok bytes=<N> status=200` + guest sha256 集合反馈包含文件；
2. 未进白名单域（如 `https://internal.example`）→ 拒绝 launch 阶段失败；
3. HTTP（非 HTTPS）→ 拒绝（禁止明文面）；
4. policy JSON 损坏/缺失 → 拒绝；
5. 默认加密 + `--allow-plaintext` 双路径回归；
6. 单测：policy load/allow/deny、credential 注入是否只允许在白名单 host。

## 4. 安全决策与声明
- **凭据不出宿主**：仅向 URLSession 注入，不进 SNAPSHOT、不进 delegate 日志、不进 guest 文件系统；
- **默认拒网络**：沙箱未注册网络设备；任何 network 面异常都是终态直至审计认可；
- **quota 默认较低可审计的最大字节数**：默认 64KiB，缺省 implicit none；主机考审该打印的 URL + status 作为审计记录；
- **INV-03/04 选项位**：M2-3a 正式在工作站场景成立；引入 TCP 透传、guest→host 请求、多凭据域区别调用的交叉中需要额外裁决。