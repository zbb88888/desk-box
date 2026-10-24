# M5：Release 签名链（key 轮换与 revocation）

状态：已完成（rotate/revoke 演示与双路径真机回归均 exit=0）；关联 `docs/design/m1-5-manifest-signing.md`、`docs/security/security-verification-matrix.md` INV-09。

## 进度

- ✅ `ReleaseKeysManifest`（v1 schema、keyID、publicHex、status=active/retired/revoked、notBefore/notAfter、note）+ `usablePublicHex` 决策（fail-closed）；
- ✅ `ManifestSigner.verify(manifest:chain:…)`：revoked/unknown/not-yet-active/expired 都以不同的 Equatable 报错；
- ✅ CLI：`gen-release-key`、`rotate-release-key`（老 active → retired，新 active）、`revoke-release-key`；`validate-assets --release-keys <json>` 支持；
- ✅ build script 自动生成 `guest/release-keys.json` 初项；
- ✅ 演示序列实证据：
  - rotate 云：retired key 主签名仍接受；
  - revoke 云：revoked key 主签名 **拒**（`signature keyID 已 revoked: a7342…`）；
  - unknown keyID 拒、malformed release keys 拒；
- ✅ `ReleaseSigningChainTests` 6 案 + `swift test` 全绿 + 真机回归 exit=0；
- 下一步：release chain 接入发布上下文（多 key 同时声明支持、release 強动 lookup、签署渠道外观）仍是后续。

## 1. 目标

把 M1-5 的 dev 签试点升级成接近发布现实的链：
- **多信赖 key**：`GuestSigningPolicy` 支持多个 trusted key（已预留允许 list），本阶段加入 **key 元数据**（keyID、状态、有效期、来源、对应 asset/floor 指纹）并落地到 `release-keys.json`；
- **Rotation demo**：生成新 key → 更新 release-keys.json → 老 key 设定 `status=retired`（保留窗口以验证已出参 manifest 仍可复验）→ 新 key 开始签名；
- **Revocation**：`status=revoked` 的 key 一律被拒，即使签名有多无法通（fail-closed）；
- **Check-in**：`release-keys.json` 本身在构建与 manifest 生成时被嵌入 host 二进制（`releaseKeys.generated.swift`）并 sha256 到启动的 decision 审计内容；
- 非目标：本阶段不做公开发布 pipeline 与外部形态 key 声明；但要达到能让 release 链由构建系统复核安全检查的断点。

## 2. 实施参考

### 2.1 `release-keys.json` metadata 结构

```json
{
  "schema": "deskbox-release-keys/v1",
  "generatedAtUtc": "2025-01-01T00:00:00Z",
  "keys": [
    {"keyID": "a734261f68c4462d", "publicHex": "...",
     "status": "active", "notBefore": "2025-10-24T00:00:00Z", "notAfter": null,
     "note": "dev workstation; M5 rotation demo"}
  ]
}
```

- `status`: `active|retired|revoked` — `active`/`retired` 接受验证，`revoked` fail-closed 拒收；
- `notBefore`: 最早允许签名时间；`notAfter`: 最晚允许（可选，为旧 key 旋转窗口服务）；
- 构建脚本把 key 该在编译时汇编进 ` Sources/DeskBoxVZ/ReleaseKeysById.generated.swift`。

### 2.2 Host 端
- `Sources/DeskBoxVZ/ReleaseSigningChain.swift`：`ReleaseKeysManifest` + verify()，支持 revoked key 拒收、notBefore/notAfter 时间窗口、多 key 坐保走样例；
- `GuestSigningPolicy.current` 增加 `revokedKeyIDs` 聚合及时间效性；
- `ManifestSigner.verify`：先看是不是 revoked，再看签名人 keyID 是否允许并逻辑。

### 2.3 CLI
- `dbx-poc gen-release-key --output-key <path>`：生成新 key + metadata starter（如 JSON）；
- `dbx-poc rotate-release-key --base <release-keys.json> --new-key <path> --output <out>`：把老 key 设 retired + 写入新 active key；
- `dbx-poc revoke-release-key --base <release-keys.json> --key-id <id> --output <out>`；
- 觓记审计实话。

### 2.4 验证
1. 用 dev key签 manifest → active 接受；
2. revoke 该 key → 拒收（verified by error `revokedKey`）；
3. rotate（new active + old retired）→ 两 key 在窗口内都接受；notAfter 过后 old 拒；
4. unknown keyID → 拒（现状）；
5. `release-keys.json` malformed/missing → fail-closed；
6. `swift test` 新增 `ReleaseSigningChainTests` compliance。

## 3. 安全决策
- 轮样不能 lever 已验证真机签名含义：发布面的 key rotation 就应是 signed re-release，不能通过手改文件绕过验证；
- revocation 是零信任规则：被控 key 一一经入 revoked，后续埚能使用；
- notAfter 是为“让旧 manifest 立刻不行”是另一题：SBOM 携 `signingKeyID` 记录以支持追溯轮转链。
