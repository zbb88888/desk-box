# M3：客供应链与可重构建（SBOM + 固定输入 + release 签名录）

状态：本轮交付位部分完成（真机验证供给到出件闭环，exit=0）；关联 `docs/design/m1-5-manifest-signing.md`、`docs/security/security-verification-matrix.md` INV-09。

## 进度

- ✅ 下载锁定 + digest 记录：kernel/debian-initrd 下载后立即 sha256，记 SBOM；
- ✅ `guest/sbom.json` 由 build script 自动生成：inputs（来源 URL + 按需 file 路径）+ outputs（客资产 digest）+ toolchain；
- ✅ `GuestSbom`/`GuestSbomVerifier`（DeskBoxVZ）：本地重算 fail-closed；
- ✅ `sbomDigest` 加入 Guest signing payload（M1-5 一致覆盖）；
- ✅ `dbx-poc verify-sbom <sbom.json>` 新命令；并 `make-manifest --sbom-digest`；
- ✅ 验证：全链当成 build → sign → verify-sbom → validate-assets → 客启动都通过；篡改 input sha256 拒读；
- ✅ `swift test` 新增 `GuestSbomTests` 3 案；
- 下一步（M3+）：bit-for-bit 确定性 reproducibility评估、release 签名链于 M5 接入的数据面。

## 1. 目标

把当前“开发者工作站自行构建+签名”升级为接近“可外部复核”的供应链：

- **输入固定**：所有下载客 kernel/Debian initrd/minirootfs/libsodium 都以已知 sha256 验证；不匹配则拒绝产出（不可现场另换）；
- **可追溯**：`guest/sbom.json` 记录每一项资产内容 digest、源 URL、脚本版本、工具链 version、manifest 签名 keyID；
- **可复核**：`dbx-poc verify-sbom` 本地重新计算 digest 并与 sbom 比对，任何差异判错（而不是装证决心做“报卷给/计”）；
- **可验证**：M1-5 的 manifest 签名覆盖面加 `sbomDigest` 字段；release 把 manifest 与 sbom 同时签名（同一 dev key 在 M3 阶段先闭塞使用，正式发布链另议）。

## 非目标
- 不做远程 release 渠道分发、不做 SLSA 框架层面接入（本阶段目标是工作站可复核）；
- 不引入 bit-for-bit 确定性 reproducibility（相关的 debian installer 本身依赖因地制宜；本阶段固定内容 digest + 版本记录）。

## 2. 实施参考

### 2.1 SBOM 结构（guest/sbom.json）

```json
{
  "schema": "deskbox-guest-sbom/v1",
  "builtAtUtc": "<ISO-8601>",
  "builtBy": "macos/scripts/build-alpine-guest.sh",
  "assetVersion": 1,
  "inputs": [
    {"name":"kernel/debian/linux-6.1.0-50-arm64","url":"...","sha256":"..."},
    {"name":"debian-installer-initrd","url":"...","sha256":"..."},
    {"name":"alpine-minirootfs-3.21.3-aarch64","url":"...","sha256":"..."},
    {"name":"guest-bootstrap.c","path":"scripts/guest-bootstrap.c","sha256":"..."},
    {"name":"brokerreq.c","path":"scripts/brokerreq.c","sha256":"..."},
    {"name":"build-alpine-guest.sh","path":"scripts/build-alpine-guest.sh","sha256":"..."}
  ],
  "outputs": [
    {"name":"vmlinuz-virt","sha256":"..."},
    {"name":"initrd-deskbox.img","sha256":"..."},
    {"name":"root-disk.raw","sha256":"..."}
  ],
  "toolchain": {"gcc":"<alpine musl gcc version>", "libsodium":"<pkg version>"},
  "signingKeyID":"<keyID օf dev key>"
}
```

### 2.2 宿主机落点
- `scripts/build-alpine-guest.sh`：
  - 增加 `verify_download <file> <sha256>`（curl 后立即 sha256 核对，不一致拒绝）；
  - 收集 outputs sha256 → 生成 `guest/sbom.json`；补 dev key 的 keyID 一起写入；
- `Sources/DeskBoxVZ/GuestSbom.swift`：解析 + verify（本地文件重算）；
- CLI `verify-sbom <sbom.json> [--allow-unsigned-manifest]`：digest 检查；校验 sbom 与 manifest 的一致性（如已有）；
- `make-manifest`：可带 `--sbom <path>`，写入 manifestDigest 之外叠 `(sbomDigest)` 独立字段；
- `GuestAssetValidator`：在 dev 工作站上如 manifest 带 sbomDigest 则同 sbom.json 校验一致性。

### 2.3 验证
1. 全链从淘出 build→sign→verify-sbom 一致；
2. 篡改任意 input sha256/输出 sha256 → verify-sbom 拒；
3. 已建内 guest/ 不参数——build script 重新运行时 sbom.json 更新；
4. manifest 在签名到期内都与 sbom.json 一同走人；
5. `swift test` 新增 sbom 单测 compliance。

## 4. 安全决策
- SBOM 是 supply-chain 意义的透明件：避免“只信有签名的 digest 而不知这些 digest 出自哪里”的盲目信任；
- 本地 dev key 与 release key 分离是 M3 的第一准则，不淡化衔接；
- 本阶段不宣称对外公开可信的发布签名 —— 真机复核前仍属 dev chain。