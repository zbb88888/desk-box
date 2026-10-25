# M9：发布 bundle 与用户操作文档

状态：已完成（GitHub Release bundle 本机 shasum/verify-channel/verify-sbom 全部上线）；关联 `docs/design/m6-ci-pipeline.md`、`m7-release-channel.md`、`m8-ci-release-pipeline.md`、`docs/security/security-verification-matrix.md` INV-09。

## 1. 目标

让运行使用者可以一键拉下已发布的「客资产 + manifest + sbom + channel.json」：

- `guest-bundle-<tag>.tar.gz`：vmlinuz-virt、initrd-deskbox.img、root-disk.raw、manifest.json、sbom.json、channel.json、release-keys.json；
- `checksums.txt`：包含 bundle、manifest、sbom、channel.json 四项的 sha256（ `verify-channel` / `verify-sbom`）；
- README 增加 quick-start：一次拉 CI/Release URL + verify + canal关闭的 scaffold launch（dbx-poc launch --broker-guest-url 的 演示）；
- 不目标：不引入下载 manager 或自动更新器——本阶段是发布面与文档的耦合。

## 进度

- ✅ CI：publish job 在 GitHub Release 提供 `guest-bundle-<tag>.tar.gz`（客资产 + manifest + sbom + channel.json + 发布 key 记录 + 附属的 guest 客户端所需文件列表）
  和 `checksums.txt`；
- ✅ README quick-start：下载 → shasum -c → 解包 → verify-channel → verify-sbom → 触发表雍望；
- ✅ 踩坑记录：
  - actions/upload-artifact 的 common-ancestor 剥离规律：加入 `macos/scripts/...` 工件把共父从 `macos/guest` 推到 `macos`，artifact 下载路径应随之调到 `macos/`；
  - sbom normalize：publish 时把 `build-alpine-guest.sh` 监命 bundle 内容排（进 bundle 到时一份放到 `guest/`）；
  - 验证解析顺序调整优先 `file`（bundle 内同目录文件，不借 repo 结构）；
- ✅ 本端到端验证：`gh release download` → `shasum -c` → `tar` → `verify-channel` → `verify-sbom` 起起返回 OK。

## 2. 实施参考

### 2.1 CI 调整（.github/workflows/release.yml）
- 在 publish 步骤背加入 bundle 生成：
```sh
cd /tmp/dbx-channel
mkdir -p bundle
cp manifest.json sbom.json channel.json release-keys.json bundle/ 2>/dev/null || true
# 加入客资产：
cp ../../macos/guest/vmlinuz-virt ../../macos/guest/initrd-deskbox.img ../../macos/guest/root-disk.raw bundle/
tar -czf guest-bundle-<tag>.tar.gz -C bundle .
shasum -a 256 guest-bundle-<tag>.tar.gz manifest.json sbom.json channel.json >> checksums.txt
```
- release assets：把 `guest-bundle-<tag>.tar.gz` 也上传；`channel.json` 仍上传（单独下载验证用）；

### 2.2 README 发布区
- 说明 quick-start：（a）下载 bundle + checksums；（b）shasum -c checksums.txt；（c）解bundle；（d）`dbx-poc verify-channel ./channel.json` （e）`./scripts/sign-and-run.sh ./manifest.json --workspace /tmp/dbx-ws --broker-guest-url https://example.com`。

## 3. 验证
1. push tag → release workflow → GitHub Release assets 带 `guest-bundle-<tag>.tar.gz` + `checksums.txt`；
2. 本机下载验证：解bundle、shasum -c、verify-channel 通过；
3. 高压低门：在 release 下载后 fast verify-channel 作为最终核验。

## 4. 安全决策
- bundle 中内容都是公开可验证的（manifest 签名 + sbom digest + channel.json），凭据不进入发布渠道；
- 下游验证也先从 release URL 拉 tag；上传动作是发布者的声明；用户下载后本机 verify-sbom/verify-channel 才是决定性的验证点。