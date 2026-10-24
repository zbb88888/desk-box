# M7：Release 发布渠道骨架

状态：已完成（publish/verify-channel 与 tamper 拒收全过）；关联 `docs/design/m1-5-manifest-signing.md`、`m5-release-signing-chain.md`、`docs/security/security-verification-matrix.md` INV-09。

## 1. 目标

把当前“本地工作站建产证的 manifest/sbom 留在 `macos/guest/`”推进到 **可分发的 release channel 骨架**：
- `release/channel.json`（仓库自带或发布站托管）描述：
  - schema 版本、生成时间、所有当前可用 key 的 metadata（M5 的 `ReleaseKeysManifest`）；
  - 最新 guest manifest 的 `assetVersion` 与相对路径（artifact-link）；
  - **发布窗口（publish floor）**：`minGuestAssetVersionFloor`——任何 assetVersion 低于此 floor 的 manifest 即使签名有效也被拒（远端最小版本防降级）；
- CLI：
  - `dbx-poc publish --channel <dir> [--release-tag <tag>]`：作统一 pipeline 检查链（manifest 签名 verified → sbom 一致 → release-keys 任一 active）→ 复制进 channel 根 → 更新 channel.json；
  - `dbx-poc verify-channel <channel.json>`：下游 loader 复验 channel 的一致性与 signature 覆盖；
- 本阶段不做公开 HTTP/OTA distribution；先在仓库/单站点目录交接，基本允随后在 CI publish 到说选网址不动打通。
随后更新 docs/CI.md 的 release checklist。

## 2. 实施参考

### 2.1 channel.json schema

```json
{
  "schema": "deskbox-release-channel/v1",
  "generatedAtUtc": "…",
  "releaseTag": "v0.1.0-alpha.1",
  "minGuestAssetVersionFloor": 1,
  "keys": [ <ReleaseKeysManifest.Key 结构> ],
  "manifest": {
    "files": {"manifest.urlish":"./manifest.json", "sbom.urlish":"./sbom.json"},
    "assetVersion": 1,
    "manifestDigest": "<manifest.json sha256>",
    "sbomDigest": "<sbom.json sha256>"
  }
}
```

- `minGuestAssetVersionFloor` 是本渠道认可的最小 guestAssetVersion；同级别的要求必须是有效签名且典藏信源不可局部价降级；；
- `manifest.files` 使用 URL 相对名（`./manifest.json`、`./sbom.json`）。

### 2.2 host 侧
- `Sources/DeskBoxVZ/ReleaseChannel.swift`：load/verify/validate manifest-digest（manifest/sbom 同 channel.json 里记的两项一致）、validate minGuestAssetVersionFloor、validate release-keys 与 manifest.signature.keyID 一致；
- CLI `publish`：  - publish 流程 fail-closed：任一步出错即 reject，不部分提交；

### 2.3 验证
1. publish 成功 → channel.json verification 披露出一致；
2. 篡改 channel.json 里 sha / min version → verify-channel 拒；
3. 使用云 agent 用 channel.json + channel 根里的 manifest.json 加载并验证——都不信本地 manifest；
4.【防爬】在 publish 时若 manifest 签名 keyID 不在 active key 列表 → 拒；
5. `swift test` 新增 `ReleaseChannelTests`。

## 进度

- ✅ `ReleaseChannelManifest`（v1）+ `ReleaseChannelVerifier`（fail-closed：manifest/sbom digest 覆盖一致性、minGuestAssetVersionFloor、signature keyID 必须挂在发布渠道的 keys 列表中）；
- ✅ CLI：`dbx-poc publish --channel <dir> --manifest --sbom --release-keys [--release-tag] [--min-version-floor]`；`dbx-poc verify-channel <channel.json>`；
- ✅ 本机端到端演示：publish → verify-channel 成功 + 篡改 digest → verify-channel 拒；
- ✅ `ReleaseChannelTests` 4 案全过；
- 下一步（M8+）：channel.json 挂在 release 分站/CI 在 publish 完结时调起渠道交割，公工发布管道（released channel）在平 目标仅。

## 3. 安全决策
- 发布渠道是 supply-chain 信任面向外用户证明的断面：verified 方访问 channel 的读者只需关于 key manifest 的验证即可；无需本地原始 build；
- 入口 / 检验原则：发布后所有 load/verify 只基于 channel.json 中公开的内容，不包含 private key；
- 把 minGuestAssetVersionFloor 当作“远端鲁棒防降级”的推出：Host 在接收 genuine channel 时，真实的 minimum  Verification 不能再回降至此。