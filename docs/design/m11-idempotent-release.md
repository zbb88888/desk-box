# M11：幂等发布管道

状态：已完成（CI 全绿，idempotent-release job 过关）；关联 `docs/design/m10-reproducible-build.md`、`m5-release-signing-chain.md`、`m7-release-channel.md`、`m9-release-bundle.md`、`docs/security/security-verification-matrix.md` INV-09。

## 1. 目标

把各阶段已经落地的确定性能力串成一条 **idempotent release path**：固定 commit + 固定 key：全管道（build → sbom → manifest → sign → channel）必须输出字节一致的产物。

- `sbom.json`：M10 已 deterministic（builtAtUtc 由 SOURCE_DATE_EPOCH 决定）；
- `manifest.unsigned.json` / `manifest.json`：Ed25519 签名 deterministic；生成时间戳统一使用 `SOURCE_DATE_EPOCH`；
- `channel.json`：`dbx-poc publish` 的 generatedAtUtc 由 `SOURCE_DATE_EPOCH` 决定（通过环境变量注入）；
- `checksums.txt` 由之前的 artifact digest 串联；只要上游 deterministic，最终也 deterministic；
- (`guest-bundle-<tag>.tar.gz` 不算本阶段 deterministic：tar header mtime 了 但两段 sha256 entry 也稳于 tag；tag 与本 commit 属固定 commit/pass 合）。

非目标：不引入多 keychain / 正式 release key 管理子流程；

## 2. 实施参考

### 2.1 修改点
- `macos/Sources/dbx-poc/DBXPOC.swift` `publishReleaseChannel`：
  - 尊重 `SOURCE_DATE_EPOCH`（SEC_EPOCH 提供压为何通用我们平时 beat 证两岸复构）；
  - 用同一 `date -u -r` 机制生成 generatedAtUtc；
- `macos/scripts/build-alpine-guest.sh`：
  - manifest 生成过程中所有时间戳一致来自 `NOW_UTC`（M10 完成）；
- CI `repro-check` 扩展：
  - 用测试用固定 key（写入 .github/workflows 仓库 secrets 或假份自动生成 ✅本阶段）；
  - 两轮在 commit 同一 SHA 下完整跑 build→sign→publish；
  - 对比 sbom/manifest/channel 一致性；不一致熄火。

### 2.2 CI 具体步骤
```yaml
- name: Generate idempotent key + build #1
  run: |
    ./.build/debug/dbx-poc gen-guest-sign-key --output-key /tmp/ci-sign-key.local
    # 随后生成 bundle 一致
- name: Re-run with same key #2
- name: Compare outputs (byte-identical)
```

## 3. 验证
1. 两轮 build→sign→publish 完全字节相等；
2. 改 commit 后输出不一致（说明产指叛 tag/commit 依赖出入）；
3. 第三遍第三轮事后与第二轮 byte-identical；

## 4. 安全决策
- 幂等发布是发布工作水平模型：：绝对不要出现“同一 tag 被不同内容覆盖”的局面；本阶段让这信念变成了可验证 fact（tag push 多一次，内容必须相对）；
- 临时测试用 key 仅用于 CI 不认建模。

# 进展
- ✅ build 里所有的 timestamp 以 `SOURCE_DATE_EPOCH`(=commit) 驱动（M10）；
- ✅ `publish` 以 SOURCE_DATE_EPOCH 为索的 generatedAtUtc 一致性；
- ✅ **关键发现**：Apple CryptoKit `Curve25519.Signing` Ed25519 为 hedged/非 deterministic（同 key+同 payload 两次签名不同）；
- ✅ 幂等定义终稿：payload（fileDigests+guestAssetVersion+kernelCommandLine+sbomDigest+manifest URLs/sign-keyID + channel）byte-identical，**签名只保证同 key 可验证**，sig bytes 不纳入幂等断言；
- ✅ payload-canonical manifestDigest（`ManifestSigner.payloadDigestHex`）落入 channel.json 与 `ReleaseChannelVerifier` 验证锚点；
- ✅ Manifest URLs / fileDigests 都私人 basename（可跨 build/download 目录迁移）;
- ✅ 本机双跑：payloads byte-equivalent / keyID match / channel & sbom strict-equal；
- ✅ CI job `idempotent-release`（双人 commit 反复行+下载产物) 全部失败缸已实现。
