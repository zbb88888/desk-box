# M8：CI 上的发布管道（GitHub Releases + channel.json）

状态：进行中；关联 `docs/design/m6-ci-pipeline.md`、`docs/design/m7-release-channel.md`、`docs/security/security-verification-matrix.md` INV-09。

## 1. 目标

每次向仓库打 `v*-alpha*` tag 时，CI 自动跑全部发布流动并生成一个 GitHub release：

- `guest-build`（ubuntu-latest）重建 guest assets（与 M6 同型）；
- `publish`（macos-latest，needs=guest-build）：
  - 下载 artifact；
  - 用 CI 临时代替 key（仅在 CI job 内生成（不入仓库）） 写入 generated DevSigningPublicKey 虽改写然后以仓库代码签名 manifest；
  - 创建 `release/channel.json`（M7 同 schema，releaseTag = tag name）；
  - 全回归：validate-assets signed OK + unsigned 预期 fail + verify-sbom OK；
  - 用 `actions/softprops-action-gh-release` 上传 release assets（manifest.json、sbom.json、channel.json、checksums）；
- 文档 README 增加 CI badge 与 releaseQuickUsage。

非目标：不做正式发布到 consumable registry（Homebrew/Notary/Mdublikaci等）。Alpha 线路是开发分支演代的 release staging。

## 2. 实施参考

- `.github/workflows/release.yml`（新 workflow；template 从 M6 的 CI 段抽出）：
  - `guest-build` only不一签名（SKIP_SWIFT_SIGN=1，与 M6 一致）；
  - `publish` 与 M6 同技术栈（生成 key、写 generated policy anchor、swift rebuild、make-manifest/sign、validate + verify-sbom）；
  - `softprops/action-gh-release@v2` 上传 `macos/guest/manifest.json`、`macos/guest/sbom.json`、`/tmp/dbx-channel/channel.json`；
  - release job 不影响主分支 CI（M6 的 workflow）仍处于 green 状态。

## 3. 验证
1. 本地对 tag 进行 push 前 `release.yml` 这部分都会在同一 push 时运行 CI（按 tag 发布）；
2. push tag `v0.1.0-alpha.1` → 应观察到 GitHub Releases 里有该 tag + assets（manifest/sbom/channel.json）；
3. `verify-channel` param `channel.json` → 通过；签证 keyID 会在 channel.keys 石出；
4. `actions/softprops-action-gh-release` 的 output artifact 在 release 上上传同处理。

## 4. 安全决策
- 发布决定性环节微就复用 M5/M7 的同一批 key 逻辑：CI 里持有私有 key 永不入库；key在 job 结束时就丢；
- Alpha channel 的目的：让发布路径可重复、可审。：每次 push tag 都是一份工业级信道等价证明。