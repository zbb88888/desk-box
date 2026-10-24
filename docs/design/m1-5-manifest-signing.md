# M1-5：Guest Manifest 签名与防降级保护

状态：计划（对除未覆盖能力分支，见文末）；关联 `docs/architecture/desktop-vm-sandbox.md` §3.2、
`docs/design/control-channel-security.md` §3、`docs/security/security-verification-matrix.md` INV-05。

## 1. 目标与范围

- **信任根**：宿主编译内嵌的 guest-release **公钥允许列表**（`GuestSigningPolicy`），不引入 X.509 PKI；
- **签名对象**：guest manifest 的内容性字段（独立路径），即
  `{"fileDigests":{...},"guestAssetVersion":N,"kernelCommandLine":"..."}` 的 **canon JCS-style JSON**（sorted keys）；
- **算法**：Ed25519（CryptoKit `Curve25519.Signing`）；签名应以 base64 进 manifest；`keyID` = 公钥 hex 前 16 位（用于轮转/审计）；
- **防降级**：
  - manifest 内含 `guestAssetVersion` 单调增；
  - 宿主策略内置 `minimumGuestAssetVersion`（每次 guest 安全修复发布时抬升）；
  - 签名认证者是通过任一 trusted key；若签名有效但 `guestAssetVersion < minimumGuestAssetVersion` → **fail-closed 拒绝**（DBX-PLATFORM-ASSET-DIGEST-MISMATCH + 区别消息）；
- **默认严格**：未签名/签名不匹配/受证书完全路径替换均被拒；唯一逃生口是 CLI `--allow-unsigned-manifest`（与 `--allow-plaintext` 同级别的显式开发降级，启动审计打印警告）。

### 1.1 非目标
- 不引入 Apple Developer ID/官方代码签名分发（Swift 代码签名仍由本项目的 codesign 脚本保障）；
- 不引入网络分发渠道与 OTA；签名 key 管理的第一步是**本地生成开发密钥 + 仓库 gitignore**；
- SBOM/guest 账本在 M2 接入（本子项目先区分可信签名与递过程中的完整可重构建）。

## 进度（M1-5，真机所有门均已验证）

- ✅ `ManifestSignature`/`ManifestSigningPayload`（DeskBoxCore）+ canonical sorted-keys payload；
- ✅ `GuestSigningPolicy.current` 内嵌 trust anchor；当前发布钥列表为空，dev key 在
  `Sources/DeskBoxVZ/DevSigningPublicKey.generated.swift`（gitignored,由构建脚本生成）；
- ✅ `ManifestSigner.{generateKeypairHex,publicKeyHex,sign,verify}`（CryptoKit Ed25519）；
- ✅ `GuestAssetValidator.validate` 集成签名校验 + 防降级，fall-closed；
- ✅ `VZRuntime(allowUnsignedManifest:)` + CLI `--allow-unsigned-manifest`；
- ✅ CLI `gen-guest-sign-key`/`sign-manifest`；`build-alpine-guest.sh` 自动链：make-manifest → sign-manifest；
- ✅ 对照实验：未签名拒/坏签名拒/错误 keyID 拒/版本降级拒/帮助默认启动走加密 + PTY + exec 面上全通过；
- ✅ `swift test` 40/41 pass（含 6 个新 `ManifestSigningTests`）；
- ✅ 文档 + `docs/security/security-verification-matrix.md` INV-09 状态更新。

## 2. 实施参考

### 2.1 Wire 格式

manifest JSON 新增可选字段：

```json
{
  "kernelURL": "file:///...",
  "initrdURL": "file:///...",
  "rootDiskURL": "file:///...",
  "kernelCommandLine": "console=hvc0 root=/dev/vda rw init=/init",
  "guestAssetVersion": 1,
  "manifestDigest": "...",
  "fileDigests": {"/abs/path":"sha256hex", ...},
  "signature": {
    "alg": "ed25519",
    "keyID": "a1b2c3d4e5f60718",
    "sig": "<base64 Ed25519>"
  }
}
```

签名覆盖值（canonical JSON，sorted keys 定序）：

```json
{"fileDigests":{"…":"…"},"guestAssetVersion":1,"kernelCommandLine":"…"}
```

- 不包含 kernelURL/initrdURL/rootDiskURL：URL 是可运输性局限于本机的细节；签署时 `fileDigests` 使用绝对路径键（loadManifest 解析后），同一批 assets 跨机器重莶必须从 `build-alpine-guest.sh` 走 make-manifest→sign-manifest 重新生成；
- 不包含 manifestDigest（它本身是 fileDigests 集合的派生属性），避免双签名；
- 路径本身为严审内容（`GuestAssetValidator` digest 匹配 + `cowRoot` §M1-1 的 paths 限制仍互补）。

### 2.2 验证流程（fail-closed）

```
loadManifest(raw)
  ├── JSON schema 必填字段
  ├── if signature == nil:
  │     if allowUnsigned: 警告审计（DBX-PLATFORM-ASSET-DIGEST-MISMATCH 消息: unsigned-manifest-allowed 开发模式）
  │     else: reject
  ├── signature.alg == "ed25519"（否则拒绝）
  ├── signature.keyID 的开头 != 某个 trusted key → reject（不计算签名，纯 deny）
  ├── Curve25519.Signing.PublicKey(rawRepresentation: hex(keyID-fullByKeyID))
  │    (full key 由 trusted list 提供；keyID 只用于选 key)
  ├── verify(sig, canonicalPayload) → false → reject
  ├── guestAssetVersion >= policy.minimumGuestAssetVersion → 否则 reject（降级）
  ├── 现有 digest/file-coverage/kernelCommandLine 检查
  └── accept
```

验证只须至多两轮（通常一轮）：对允许列表中所有 keyID-prefix 匹配项依次验证；策略规模小（≤4 keys）性能可忽略。

## 3. 落点

- `macos/Sources/DeskBoxCore/ManifestSigning.swift`：`ManifestSignature`、`ManifestSigningPayload`；
- `macos/Sources/DeskBoxVZ/GuestSigningPolicy.swift`：trusted keys + minimum version + `generateKeypair()`、`sign()`、`verify()`（CryptoKit）；
- `macos/Sources/DeskBoxVZ/GuestAssetValidator.swift`：改 `validate(_:minimumAssetVersion:allowUnsigned:)`；
- `macos/Sources/DeskBoxVZ/VZRuntime.swift`：传递 `--allow-unsigned-manifest`；
- `macos/Sources/dbx-poc/main.swift`：
  - `gen-guest-sign-key --output-key <path>`（私有 32-byte hex w/ "private:" 前缀印出，公钥 hex 于是打印）；
  - `sign-manifest --manifest <in> --key <path> --output <out> [--asset-version N]`（许可外部覆盖版本）；
  - `launch`/`validate-assets` 接受 `--allow-unsigned-manifest`；
- `macos/scripts/build-alpine-guest.sh`：`./guest/dev-sign-key.local`（gitignore 已覆盖 `guest/`）缺失时自动生成，make-manifest 后持续签署；
- `macos/Tests/DeskBoxCoreTests`：单元覆盖。

## 4. 出样验证（证伪）

1. 干净构建 + 自动签署 → `launch` 正常通过并进入 secret channel/PTY/exec/destroy；
2. 手工篡改 assets digest 中一个字节 → `launch` 在 `GuestAssetValidator` 处拒绝（meet DBX-PLATFORM-ASSET-DIGEST-MISMATCH）；
3. 用错 key 重新签署或篡改 `keyID`/`sig` → 拒绝；
4. `guestAssetVersion` < policy minimum → 拒绝（单元 + 改 manifest 后 `validate-assets` 实测）；
5. `--allow-plaintext` 发布面验证了已验证的交互安全性不被引入；新一轮默认加密启动照常。

## 5. 安全决策

- **不能区分 guest 身份**：只允许列表内 key 可签名；签名 key 的任何泄漏都被视为需要轮转的绝对事件，而不是可调优配置；
- **拒绝未签名 manifest 是发布默认**；`--allow-unsigned-manifest` 仅在显式 CLI 开关下存在，并且审计链必须可观察到（打印与 InMemoryAuditSink 决策记录）；
- **回滚比升级慢一个相位**：攻击者可控 manifest 时只能破坏可用性，不能只拿到旧漏洞 guest 的执行面；
- sbom/guest 账本 / securitytracker 依赖二进制**原始原始数据**（manifest digest）而交易原始数据链是否睡眠也依赖于密钥轮转的审计裁决。

## 6. 不含范围（公开声明）

宿主 Swift 侧签名可信度依赖信任的不会以选择强固化（受保护 keychain/TPM）；不在当前阶段声明 supply-chain 可证明。Windows phase 接受 Linux guest 依赖。
