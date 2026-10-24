# M6：CI pipeline（GitHub Actions）

状态：已完成（本次 push 三 job 全部 green）；关联 `docs/design/m2-roadmap.md`、`docs/design/m4-fuzz-hardening.md`、`docs/security/security-verification-matrix.md`。

## 进度

- ✅ `.github/workflows/ci.yml` 三层 job：
  - `fuzz`（ubuntu-latest）：clang -fsanitize 编译 + 运行 harness；
  - `guest-build`（ubuntu-latest）：QEMU binfmt + SKIP_SWIFT_SIGN=1 全面构建 guest assets + 上传 artifact；
  - `macos-build-test`（macos-latest，needs=guest-build）：swift test + cli build + 生成 CI key写 generated policy anchor + make-manifest/sign + validate-assets（signed 接受 + unsigned 预期拒）+ verify-sbom；
- ✅ 修复确保 CI 三部曲：
  - ubuntu QEMU binfmt 使容客 build arm64 alpine 镜像能跑；
  - `dbx-poc/main.swift` 重名 + @main 冲突（在 CI toolchain 下报错，本地 toolchain 宽容）→ 改名 `DBXPOC.swift`；
  - `swift build 津洋 | tail` 需要用 `set -o pipefail`；
  - guest artifact 需含 scripts 源coding + debian-initrd.gz 方能做客 secondary verify。
- ✅ 事实验证：`push` 后 `gh run watch` 一次三 job 全部为 success；
- ✅ docs/CI.md 的 release checklist 段落。

## 1. 目标

把当前“工作站验证一切”的 heavy shotgun 升级成每次 push 自动运行的 **同型 regression**：

- ``swift build` + `swift test`（macos-latest runner + Xcode 16+）；
- fuzz：`scripts/run-fuzz.sh` 半时级运行（Linux container + clang16+ 干净环境）；
- guest build：`scripts/build-alpine-guest.sh` 的全链（GitHub-hosted ubuntu-latest 内置 docker daemon，直接使用不与本地重复）；
- manifest 签名的负人路径作为 CI regression（预期 unsigned manifest 被拒）；
- 文档一致性 lint：`docs/README.md` 含有的 design/adr/report 记录里交叉引用文件全存在；
- 全部起一道 audit log artifact 存为 evidence 。

## 不目标
- 不在 CI 上 e2e 开启 Hypervisor entitlement（需要 codesign 签名 + macOS HW + hypervisor framework 权限）：那些是人工回归（留下流程）；
- 不在 CI 客 build 中一键合环境变量，CI 不做发布：发布渠道东西只由本地 build/release 渠道生成。

## 2. 实施参考

### 2.1 GitHub Actions workflow `.github/workflows/ci.yml`

两个 job + 一个重心样板：

| job | runner | 主要步骤 |
|-----|--------|----------|
| `macos-build-test` | macos-latest | checkout → select xcode → swift test（全部 target；不改白话） |
| `fuzz` | ubuntu-latest | checkout → clang -fsanitize 编译 harness → 运行 |
| `guest-build` | ubuntu-latest | checkout → 安装 docker → ALPINE_VERSION=3.21.3 build-alpine-guest.sh（容器临时关闭 config控制所需 signer）→ validate-assets、verify-sbom |

### 2.2 防回归激励
- `dbx-poc validate-assets guest/manifest.json` 是签名给孩子默认路径 —— 在 CI 里验证 unsigned manifest 被拒（这是持新房的 regression 门）。

### 2.3 evidence 存档
- 每个 job 都 `actions/upload-artifact` 上传：build log、test .xcresult、guest assets 摘要、manifest.json/sbom.json 文件、validate-assets 输出。

## 3. 验证
1. 本地 `act`（可选）审查；以 push 触发 CI 全 green 一次；
2. 防爬子体：提交一个假设预期 fail 的 commit → CI 报案；
3. 增加 docs/CI.md：流程维护、如何看 evidence、发布前 checklist。

## 4. 安全决策
- CI 不持任何秘钥：签名私钥只在本地/经仓库 secret 环境存取。CI 只做 build-syntax/test，不放签名；
- 所有CI 明确记录 `no-manifest-forge` regression 子集；来证明我们的安全保障仍然被 CI 检查。