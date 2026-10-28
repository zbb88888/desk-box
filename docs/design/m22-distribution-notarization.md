# M22：产品化分发（签名 / 公证 / DMG / 更新检查 / v0.2.0）

状态：M22a 已完成（本地可验证部分）；M22b（真机公证）留待 Developer ID Application 证书

## 1. 目标

把「能跑的技术演示」变成「能交付给别人的桌面应用」：

1. **可分发的 .app**：自包含（GUI + `dbx-poc` helper + guest 资产），版本号来自 git tag，Info.plist 自动生成。
2. **DMG 交付物**：`DeskBox-<version>.dmg`，含 `/Applications` 快捷方式与 SHA-256 清单。
3. **Hardened Runtime + Developer ID 签名 + notarytool 公证 + stapler 钉票**：Gatekeeper 首次打开无需「右键 → 打开」，Login Item 不再要求 `requiresApproval`。
4. **更新检查**：`dbx-poc check-update` 复用 M7 release channel（Ed25519 签名 + digest 覆盖 + 版本 floor），拒绝降级/回滚/未签名 channel。
5. **CI**：tag 推送产出 DMG + 公证（需 secrets），**缺 secrets 时 release job fail-closed**（不能静默产出未公证的「正式版」）。

## 2. 非目标

- **不做自动静默安装更新**（不做 Sparkle 式后台替换）。M22 只做「检查 + 告知 + 指向下载页」，替换由用户手动完成。理由：静默自我替换会引入「更新器即新攻击面」和「旧版本可被降级」两类风险，需要独立的 INV-10 更新链路设计与回滚矩阵，属 M22c。
- 不做 App Store 分发（VZ entitlement + 沙箱沙箱语义冲突）。
- 不做 Windows/Linux 分发（已移出路线图）。

## 3. 产物布局

```
DeskBox.app/Contents/
  Info.plist                     # CFBundleShortVersionString=<semver>，CFBundleVersion=<build>
  MacOS/DeskBoxGUI               # GUI 主程序
  MacOS/dbx-poc                  # helper（daemon/CLI），同一 Team 签名
  Resources/guest/               # 内置 guest 资产：vmlinuz-virt, initrd-deskbox.img, root-disk.raw
  Resources/guest/manifest.json  # 已签名 manifest（assetVersion）
  Resources/guest/sbom.json
  Resources/guest/channel.json   # release channel（更新检查用）
```

`dbx-poc` 必须位于 `Contents/MacOS/`（而不是 `Contents/Resources/`），因为 GUI 通过 `Bundle.main.bundleURL/Contents/MacOS/dbx-poc` 解析（M17 已确定的 bundle 相对解析）且 helper 在 `MacOS/` 下才能被 `codesign --deep` 正确纳入同一个 scope。

## 4. 签名与公证流水线

```
swift build -c release (GUI + dbx-poc)
  → assemble DeskBox.app（Info.plist 生成、guest 资产拷入）
  → codesign --options runtime --entitlements … （先 helper 后 app，由内向外）
  → codesign --verify --deep --strict
  → hdiutil create -format UDZO  →  DeskBox-<ver>.dmg
  → codesign --sign "$DMG_IDENTITY" DeskBox-<ver>.dmg     （签名 DMG 本身，可选但推荐）
  → xcrun notarytool submit --wait --keychain-profile "$PROFILE"
  → xcrun stapler staple DeskBox.app && stapler staple DeskBox-<ver>.dmg
  → spctl -a -vvv -t open --context context:primary-signature DeskBox-<ver>.dmg
```

### 4.1 身份选择（fail-closed）

| 环境 | 身份 | 公证 | 产物后缀 |
|---|---|---|---|
| `DEVELOPER_ID_APPLICATION` 存在且 `NOTARY_PROFILE` 可用 | Developer ID Application | ✅ | 无（正式） |
| 仅 `Apple Development`（本机现状） | Apple Development | ❌ 明确跳过 | `-dev` |
| 无证书 | ad-hoc (`-`) | ❌ | `-dev` |

`REQUIRE_NOTARIZATION=1`（CI 正式 tag 默认开启）时，缺身份/缺公证凭据 → **立即失败**，不产出 DMG。这条是防止「以为发了公证版，其实是 ad-hoc」的唯一可靠闸门。

### 4.2 entitlements

沿用 `Resources/DeskBox.entitlements`（`com.apple.security.virtualization`）。Hardened Runtime 与 VZ 兼容；不申请 `allow-jit`/`allow-unsigned-executable-memory`（我们的代码不需要 JIT，申请了反而扩大攻击面）。

## 5. 更新检查语义（INV-10 延伸：不复活旧版本）

`dbx-poc check-update --channel <path|URL> --current-version <semver> [--json]`

判定顺序（全部 fail-closed）：

1. **channel 完整性**：`ReleaseChannelVerifier.verify`（manifestDigest / sbomDigest / assetVersion floor）。
2. **channel 密钥有效性**：`channel.keys` 中至少要有一把 `status=active` 且 `notBefore ≤ now ≤ notAfter(or null)`；全部 revoked/expired → 拒绝。
3. **版本比较**：解析 `channel.releaseTag`（`vMAJOR.MINOR.PATCH[-pre]`）与 `--current-version`。
   - `channel < current` → `rollback`（**拒绝**，ERR `update-rollback-refused`）。
   - `channel == current` → `up-to-date`。
   - `channel > current` → `available`，附带 `releaseTag` + `manifestDigest` + `downloadHint`。
4. **资产版本 floor**：`channel.manifest.assetVersion < minGuestAssetVersionFloor` → 拒绝（防止降级 guest）。

输出 JSON schema `deskbox-update-check/v1`：

```json
{"schema":"deskbox-update-check/v1","decision":"available|up-to-date|rollback","currentVersion":"0.2.0","remoteVersion":"0.2.1","releaseTag":"v0.2.1","manifestDigest":"…","assetVersion":2,"reason":null}
```

拒绝时 `decision=rollback` 且 `reason` 为具体原因码，进程退出码非零。

## 6. 验收标准

本地可验证（M22a，无 Developer ID）：

- [ ] `scripts/package-app.sh` 产出 `gui/dist/DeskBox.app`，`Contents/MacOS/dbx-poc` 与 `Resources/guest/manifest.json` 齐全
- [ ] Info.plist `CFBundleShortVersionString` == 传入版本，`CFBundleVersion` 单调（build 号）
- [ ] `codesign --verify --deep --strict` 通过；`codesign -dv` 显示 `flags=…runtime`
- [ ] `dbx-poc` helper 与 GUI 签名 scope 一致（同一 identity）
- [ ] `hdiutil attach` 挂载 DMG 后 app 可启动，且 `Resources/guest` 校验和与源一致
- [ ] `check-update` 四种决策各有正例/负例；未签名 channel、revoked key、rollback 全部拒绝
- [ ] `scripts/notarize.sh --preflight` 在缺 Developer ID 时**失败**（fail-closed），在 `--allow-skip` 时明确打印跳过原因
- [ ] CI `release.yml` 新增 app job，缺 secrets 且 `REQUIRE_NOTARIZATION=1` 时失败

真机公证（M22b，需 Developer ID 证书）：

- [ ] `notarytool submit` 返回 `Accepted`，`stapler validate` 通过
- [ ] `spctl -a -t open` 通过；首次双击无 Gatekeeper 拦截
- [ ] Login Item 注册不再 `requiresApproval`

## 6.1 实施结果（2026-10-28）

`scripts/e2e-distribution.sh` **39/39**：

```
[dist] PASS: package-app.sh 成功
[dist] PASS: 包含 Contents/MacOS/dbx-poc（helper 与 GUI 同 scope）
[dist] PASS: Info.plist 版本 = 0.2.0 / CFBundleVersion = 171（单调数字）
[dist] PASS: helper 版本一致（0.2.0）
[dist] PASS: codesign --verify --deep --strict
[dist] PASS: hardened runtime 已启用
[dist] PASS: helper 与 app 同一签名身份
[dist] PASS: DMG 可挂载 / 含 /Applications 链接 / 内版本一致 / 三项资产校验和一致
[dist] PASS: SHA256SUMS 已生成并校验通过
[dist] PASS: 缺凭据时公证 preflight fail-closed（exit=2）
[dist] PASS: REQUIRE_NOTARIZATION=1 缺证书时拒绝产出（exit=2）
[dist] PASS: publish 产出真实 channel.json
[dist] PASS: 同版本 → up-to-date / 低版本 → available
[dist] PASS: 回滚拒绝退出码 3 + 原因码 update-rollback-refused
[dist] PASS: 篡改 channel 被拒（manifestDigestMismatch）
[dist] PASS: 全 revoked key 被拒（no-usable-release-key）
[dist] PASS: channel 不存在 → 拒绝（exit=3）
[dist] 结果：PASS=39 FAIL=0
```

`UpdateCheckerTests` 11/11（semver precedence、预发布排序、回滚拒绝、篡改、撤销/过期 key、结构化 refusal）。

### 实施中踩到并修掉的三个真实问题

1. **hdiutil 按「已分配块」估算镜像大小**：`root-disk.raw` 是 512 MiB **稀疏**文件（只占 9 MB），hdiutil 建出 ~140 MB 镜像后拷贝 512 MiB 逻辑内容 → `设备上无剩余空间`。修：按逻辑大小求和 + 25% 余量显式 `-size`。
2. **`codesign -dv … | grep -q` 在 `pipefail` 下误判**：grep 提前退出 → codesign 吃 SIGPIPE → 管道失败 → 被当成「没有 hardened runtime」。修：先捕获输出再 grep。
3. **`gen-release-key --output-key X` 的 release-keys.json 落在 `dirname(X)/release-keys.json`**，`X` 本身是**私钥**；`publish --release-keys X` 会因读到 `private:…` 而 JSON 解析失败。另外 manifest 必须用 **release key** 签名（publish 要求 signature keyID 在 active release key 里），不能用独立的 guest 签名 key。

### 顺带修复的两处 CI 真实失败

1. **`repro-check`（root-disk.raw 不可复现）**：mke2fs 的时钟字段 + 备份 superblock 的随机 `hash_seed`。详见 `m10-reproducible-build.md` §9。修复后四资产双跑 `REPRO-OK`。
2. **`security-corpus`（工具链不匹配）**：`macos-14` runner 自带 Swift 5.10，而 `Package.swift` 要求 tools 6.0 → 改 `macos-15`。

### GUI 侧变化

- 新增 `BundlePaths.swift`：helper 解析顺序改为「`Contents/MacOS/dbx-poc`（分发包）→ `.build/release/dbx-poc`（开发包）」，与 M17 的 bundle 相对解析兼容。
- Settings 新增 **About** 面板：版本 / build / commit / release channel / guest asset version + 「Check for Updates」（调 `dbx-poc check-update --json`，只告知不替换）。

## 7. 风险与诚实边界

- **本机无 Developer ID Application 证书**，也无 notarytool 凭据 → M22b 的公证链路**未真机验证**，只验证了脚本的 fail-closed 行为与 DMG/签名/版本/更新检查的本地部分。
- 未公证的 build 在别的机器上打开会被 Gatekeeper 拦（需右键打开）；`-dev` 后缀用来显式区分。
- `check-update` 只做**告知**，不下载不替换；「更新下载本身」的完整性与原子替换属 M22c。
- GitHub Release 的 `checksums.txt` 覆盖 manifest/sbom/channel/bundle，但不覆盖 DMG 内的 app（DMG 由 `shasum` 单独列出）。

## 8. 实施顺序

1. `scripts/package-app.sh`（组装 + 签名 + DMG + 校验）
2. `Sources/DeskBoxVZ/UpdateChecker.swift` + CLI `check-update` / `version`
3. `scripts/notarize.sh`（preflight / submit / staple / spctl）
4. `Tests/DeskBoxCoreTests/UpdateCheckerTests.swift`
5. `scripts/e2e-distribution.sh`
6. `.github/workflows/release.yml` app job + `docs/CI.md`
7. GUI：About/版本显示 + 「检查更新」按钮
8. docs 索引 / roadmap / README / security matrix 更新

## 8.1 CI 状态（修复后）

`main` 的 CI 六个 job 全绿：

```
✓ fuzz               15s
✓ repro-check        14m37s   ← 修复后首次通过（此前 root-disk.raw 不可复现）
✓ guest-build        6m59s
✓ security-corpus    55s      ← macos-15（Swift 6）+ 修掉两处 actor 隔离编译错误
✓ macos-build-test   1m33s
✓ idempotent-release 1m12s
```

期间 CI 抓到两个本地没暴露的真实问题（apple silicon 本地 Xcode 版本较旧，诊断更宽松）：
`DeskBoxGUIApp.send()` 与 `SettingsPanel` 里三个 helper 在 `Sendable` 闭包中捕获 MainActor 隔离属性。
已改为先取局部值 + `Task { @MainActor in … }` 回主线程更新。

## 9. v0.2.0 实际发布记录（诚实状态）

`v0.2.0` tag 已推送并触发 `release.yml`：

| job | 结果 | 说明 |
|---|---|---|
| `guest-build` | ✅ | guest 资产构建（QEMU arm64） |
| `publish` | ✅ | manifest 签名 + SBOM + channel.json + `guest-bundle-v0.2.0.tar.gz` 已上传到 GitHub Release |
| `app` | ❌（**预期**） | 在 `Store notarytool credentials` 步骤失败：仓库未配置 `MACOS_NOTARY_*` secrets |

这是设计上的 fail-closed：**没有公证凭据就不产出发行版 DMG**，而不是静默产出 ad-hoc 包冒充正式版。

因此当前 release 页面上**只有 guest bundle，没有 DMG**。要补齐 DMG 有两条路：

1. **正式路（推荐）**：配置 `MACOS_DEVELOPER_ID_P12_BASE64` / `MACOS_DEVELOPER_ID_P12_PASSWORD` /
   `MACOS_NOTARY_APPLE_ID` / `MACOS_NOTARY_TEAM_ID` / `MACOS_NOTARY_APP_PASSWORD`，
   然后 `gh workflow run Release -f release_tag=v0.2.0`（`allow_unsigned_dev_dmg=false`）→ 产出公证 DMG。
2. **dev 路**：`gh workflow run Release -f release_tag=v0.2.0 -f allow_unsigned_dev_dmg=true`
   → 产出 `DeskBox-0.2.0-dev.dmg`（ad-hoc/Apple Development 签名、未公证，README 内已标注）。

本地已验证过的等价位（`./scripts/package-app.sh` + `./scripts/e2e-distribution.sh` 39/39）：
`DeskBox-0.2.0-dev.dmg`，130 MB，含 helper + 三项 guest 资产，hardened runtime，`SHA256SUMS` 通过。
