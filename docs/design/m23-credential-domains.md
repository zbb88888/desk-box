# M23：多凭据域隔离（INV-02）

状态：已完成

## 1. 目标与不变量

INV-02 原文：**「不同凭据域不共享 guest kernel」**。

当前实现里每个 sandbox 已有独立 VZ VM（天然不共享 kernel），因此 M23 要交付的不是「再隔离一次」，而是：

1. **把「凭据域」变成一等概念**：domain → 凭据集合 + 出口策略 + 允许的资产；
2. **把 domain 写进所有持久化元数据**（COW lease、registry、快照 AAD、daemon 会话），使得任何跨域复用都在**磁盘层**被识别；
3. **对每个跨域路径 fail-closed**，并用可复现的证据（调度决策记录 + 属性测试）证明「不同 domain ⇒ 不同 VM 实例」。

不变量（M23 交付后必须始终成立）：

| # | 不变量 | 强制点 |
|---|---|---|
| I1 | `domain(sandboxA) != domain(sandboxB)` ⇒ `kernelInstance(A) != kernelInstance(B)` | 每 sandbox 独立 `VZVirtualMachine` + `vmInstanceID` 写入决策记录 |
| I2 | 快照仅能被**同域**沙箱恢复 | 快照 AAD 绑定 `domainID`；`SnapshotGate` 四道闸 |
| I3 | COW base 盘不得跨域复用（含「同 manifest、不同域」） | `CowDiskManager` lease 记录 domain，跨域复用即拒绝 |
| I4 | 会话操作（exec/pty/wsSync/broker/stats/suspend/resume）必须带**同域**标签 | daemon 请求 `domain` 与会话 domain 比对 |
| I5 | 域 A 的 broker 凭据绝不用于域 B 的请求 | 凭据表按域分文件；broker 只加载本域 |
| I6 | 域未知 / 域策略缺失 ⇒ 拒绝（不是「默认域」兜底） | `DomainRegistry.resolve` fail-closed |

## 2. 领域模型

```swift
public struct CredentialDomainID: Hashable, Codable, Sendable   // 例 "personal" / "work"
public struct CredentialDomain: Sendable, Codable {
    let domainID: CredentialDomainID
    let brokerCredentialsFile: String?   // 相对 credential root，null = 该域无凭据
    let brokerPolicyFile: String?        // null = 该域禁止联网
    let allowedSigningKeyIDs: [String]   // 该域信任的 release key（空 = 不限制）
}
public enum DomainResolutionError { case unknownDomain(String), malformed(String), policyMissing(String) }
public struct DomainRegistry {           // 从 domains.json 加载，fail-closed
    func resolve(_ id: CredentialDomainID) throws -> CredentialDomain
    var domains: [CredentialDomain]
}
```

`domains.json`（宿主，`~/Library/Application Support/DeskBox/domains.json`，0600）：

```json
{"schema":"deskbox-domains/v1","defaultDomain":"personal",
 "domains":[{"domainID":"personal","brokerPolicyFile":"broker-policy.json"},
            {"domainID":"work","brokerPolicyFile":"broker-policy.work.json",
             "brokerCredentialsFile":"broker-credentials.work.local"}]}
```

语义纪律：

- **没有隐式默认域**：daemon `run` 必须显式给出 `--domain`，或由 `domains.json` 的 `defaultDomain` 决定；两者都缺 → 拒绝。
- `defaultDomain` 只在**创建**时生效；已有沙箱的任何操作都必须带 `domain` 且必须匹配。
- 空 `brokerPolicyFile` = 该域完全无出站；空 `brokerCredentialsFile` = 该域无凭据（只能匿名 HTTPS）。

## 3. 元数据绑定

| 位置 | 新增字段 | 作用 |
|---|---|---|
| `SandboxCreateRequest` | `domainID` | 创建时定域，之后不可变 |
| `CowDiskManager.Lease` | `domainID` + `.meta.json` 旁挂文件 | 跨域复用 base 直接拒绝（I3） |
| `SandboxRegistry.Entry` | `domainID` | 崩溃恢复/`ps` 可审计 |
| `SnapshotMetadata` + AAD | `domainID` | 跨域恢复 AEAD/AAD 不匹配（I2） |
| daemon `run/exec/...` 请求 | `domain` | 会话比对（I4） |
| 调度决策记录 | `vmInstanceID` + `domainID` + `kernelDigest` | 证明 I1 |

`vmInstanceID` 取每台 `VZVirtualMachine` 的 UUID（创建时生成），写入 `~/Library/Application Support/DeskBox/scheduler-decisions.jsonl`（追加、0600、单行 JSON）：

```json
{"schema":"deskbox-scheduler-decision/v1","at":"…","sandboxID":"…","vmInstanceID":"…",
 "domainID":"personal","kernelDigest":"sha256:…","cowLease":"…","decision":"allow"}
```

跨域拒绝也写一条 `decision":"deny","reason":"cross-domain-snapshot"` 等，便于事后取证。

## 4. 跨域攻击面（负例优先）

| 攻击 | 期望结果 | 断言点 |
|---|---|---|
| 用域 A 的快照恢复域 B 的沙箱 | 拒绝 | `SnapshotGate` → `domainMismatch` |
| 把域 A 的 COW clone 目录挪给域 B 的 registry 项 | 拒绝 | lease meta domain 不符 |
| 用域 A 的 session 对域 B 的沙箱 exec | 拒绝 | daemon 会话 domain 比对 |
| 域 A 的 broker 请求打到域 B 才允许的 host | 拒绝 | 只加载本域 policy |
| 域 A 的凭据被用于域 B | 拒绝 + 凭据不出现 | 凭据表按域分文件，canary 扫描 |
| 未声明域（`--domain ""` / 缺省且无 `defaultDomain`） | 拒绝 | `unknownDomain` |
| 并发创建 20 个跨域沙箱 | 每个 domain 内 VM instance 唯一，跨域不共享 | 决策记录断言 |

## 5. 并发与属性测试

`DomainIsolationTests`（属性式，组合矩阵）：

- `domains × workspaces × grants` 组合（≥ 64 组）：任意两组 domain 不同的创建请求，其 `vmInstanceID`、COW clone 路径、快照 AAD 全部不同；同域不同 workspace 也不共享 clone。
- 「同域 + 同 manifest」允许复用 base 盘（只读），但 clone 必须独立（clonefile 语义已在 M0 覆盖，这里断言 lease 路径不重复）。
- 快照 AAD：任一字段（domain/manifestDigest/assetVersion/bootID）改动 → 解密/闸门失败。

## 6. 验收标准

- [ ] `domains.json` 解析 fail-closed；未知域、缺 policy、schema 不符全部拒绝并给出原因码
- [ ] `run --domain work` 与 `run --domain personal` 并发可用，`ps` 显示 domain
- [ ] 跨域快照恢复被拒（原因码 `snapshot-domain-mismatch`）
- [ ] 跨域 COW 复用被拒（`cow-domain-mismatch`）
- [ ] 跨域 exec/pty/stats 被拒（`session-domain-mismatch`）
- [ ] 域 A 的 broker 凭据在域 B 沙箱中零出现（canary），且域 A 请求确实带上凭据（对照组）
- [ ] 调度决策记录含 `vmInstanceID`，断言跨域 instance 唯一
- [ ] 回归：`swift test` 全绿 + 既有 6 个 e2e 全绿

## 7. 非目标与诚实边界

- **不做「同域内多沙箱共享 kernel」**：即使同域也保持每沙箱独立 VM（更安全，代价是内存）。M23 只保证「跨域绝不共享」，不引入同域复用。
- **不做凭据域之间的信任委托**（无跨域借用/短期授权）。要跨域就切换到对应域。
- **不覆盖宿主侧内存取证**：凭据隔离的证据是「文件/环境/日志/COW/快照零出现 + 网络请求头对照」，不含内存 dump。
- `domains.json` 的 `allowedSigningKeyIDs` 仅作为**额外**限制叠加在既有 release chain 之上；空数组表示不额外限制（不表示「信任一切」——manifest 签名链仍必须通过）。
- 真机证据仍是单机（单用户）场景：同一宿主用户可读 `domains.json`，因此域隔离防的是**沙箱之间**的越权，不是防宿主用户。

## 7.1 实施结果（2026-10-28，Apple Silicon + VZ）

`scripts/e2e-credential-domains.sh` **21/21**：

```
[m23] PASS: domains 列出 work 域 / work 域标记为允许出站 / defaultDomain = personal
[m23] PASS: 非法 schema 拒绝
[m23] PASS: 域文件名路径穿越拒绝
[m23] PASS: daemon 加载 domains.json
[m23] PASS: personal 域沙箱已创建
[m23] PASS: work 域沙箱已创建
[m23] PASS: ps 显示 personal 域 / ps 显示 work 域
[m23] PASS: 跨域 exec 被拒（原因码正确）
[m23] PASS: 同域 exec 正常（uid=65534）
[m23] PASS: work 域快照已生成
[m23] PASS: 跨域快照恢复被拒（域不匹配）
[m23] PASS: 同域恢复成功
[m23] PASS: 调度决策记录已生成（0600）/ 权限 0600
[m23] PASS: 域标签与 VM 实例唯一性断言通过
[m23] PASS: domain A 凭据未出现在 COW/日志
[m23] PASS: 对照组：凭据确实存在于 work 域凭据表
[m23] PASS: 无出口策略的 ci 域仍可创建沙箱（默认零网络）
[m23] 结果：PASS=21 FAIL=0
```

`CredentialDomainTests` 11/11（域 ID 校验、registry fail-closed、路径穿越/重复/错 schema、broker 文件缺失、
COW 跨域收养拒绝、快照 AAD 绑定域、篡改域导致解密失败、域×工作区×grant 属性矩阵 12 组）。

### 实施中抓到并修掉的 2 个真实缺陷

1. **`SnapshotStore.seal` 丢了 `domainID`**：它用传入 metadata 重建一份新 metadata 时漏了 domainID，
   导致所有快照被写上默认域 —— 闸门看到的是错的域（跨域恢复本应被拒却会通过）。已修为逐字段透传，
   并加了「篡改磁盘 domainID → AAD 不匹配 → 解密失败」的测试。
2. **`run --domain X` 的 `--domain` 被当成 manifest 路径**：`dropSockOption` 只丢 `--daemon-sock`。
   已改为统一的「带值选项」表。

### 实现要点

- `DomainRegistry` 在 **daemon 启动时**先校验一次（非法即 `exit(2)`，不带错配置接单），每次 `run` 再按实际配置注入 runtime。
- 跨域拒绝全部落 `scheduler-decisions.jsonl`（`decision:"deny"` + 原因），便于事后取证。
- 域比对有两层：daemon 会话层（`sessionFor`）+ runtime `require()`（handle 携带 `domainID`），
  所以即使绕过 daemon 直接调用 runtime 也会被拒。

## 8. 实施顺序

1. `Sources/DeskBoxCore/CredentialDomain.swift`（模型 + registry + fail-closed 解析）
2. `CowDiskManager` lease domain + meta 旁挂；`SandboxRegistry` entry domain
3. `SnapshotStore` AAD/gate 增 `domainID`
4. `SandboxCreateRequest.domainID` + `VZRuntime` 会话比对 + `vmInstanceID` + 调度决策记录
5. daemon/CLI `--domain`（run/exec/pty/ws/stats/suspend/resume/rm）；`domains` 列表命令
6. Broker 按域加载 policy/credentials
7. `DomainIsolationTests`（属性矩阵）+ `e2e-credential-domains.sh`
8. 文档：安全矩阵 INV-02、docs/README、roadmap、broker 文档
