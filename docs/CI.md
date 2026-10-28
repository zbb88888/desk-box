# CI / release 流程说明（M6）

## Jobs 总监督
- `macos-build-test`（macos-latest）：checkout → select Xcode 16.x → `swift test`（全部 target）；output log 上传 artifact；
- `fuzz`（ubuntu-latest）：clang -fsanitize=address,undefined 编译 guest C harness → `scripts/run-fuzz.sh`；任何 ASAN/UBSAN 污点即非零退出（halt_on_error=1）；
- `guest-build`（ubuntu-latest）：构建 guest assets + `validate-assets`（signed 与预期 unsigned 拒收双跑）+ `verify-sbom`；**预期 fail regression**：unsigned manifest 若被接受 → CI 红；

## evidence
每个 job 上传运作 artifact（`Actions → 该 run → Artifacts`）， manifests/SBOM/test logs 都在。

## release checklist（M6+）
1. `gh act ...` / 本地 `swift test` 全绿后 push；
2. CI live 后复核 guest evidence（manifest.json、sbom.json）；
3. 走 `dbx-poc validate-assets --release-keys ./guest/release-keys.json` 隧道；
4. 需要 release 签名链后执行按 M5 的 rotate/revoke 操作并更新 `guest/release-keys.json`；
5. Windows phase（后续架需显示在分支演示层）。
## M22 分发/公证流水线

`release.yml` 新增 `app` job（在 `publish` 之后）：

| 步骤 | 作用 | 缺 secrets 时 |
|---|---|---|
| Import Developer ID certificate | 导入 `MACOS_DEVELOPER_ID_P12_BASE64` | 警告，继续 |
| Store notarytool credentials | 用 Apple ID + Team ID + app-specific password 建 `dbx-ci` profile | **正式 tag 直接失败** |
| Package app + DMG | `scripts/package-app.sh`（版本来自 tag） | `REQUIRE_NOTARIZATION=1` 时拒绝产出 ad-hoc 包 |
| Notarize + staple | `scripts/notarize.sh`（仅正式 tag） | — |
| Verify distribution | `scripts/e2e-distribution.sh`（39 断言） | — |

需要的 secrets：

- `MACOS_DEVELOPER_ID_P12_BASE64` / `MACOS_DEVELOPER_ID_P12_PASSWORD` — Developer ID Application 证书
- `MACOS_NOTARY_APPLE_ID` / `MACOS_NOTARY_TEAM_ID` / `MACOS_NOTARY_APP_PASSWORD` — 公证凭据

语义：**alpha tag → dev 通道（未公证，DMG 带 `-dev` 后缀）；正式 tag → 必须公证，否则 job 失败**。
这是防止「以为发了公证版其实是 ad-hoc」的唯一可靠闸门。

### 手动触发（dev DMG 出口）

tag 推送路径永远 fail-closed；若确实需要一份未公证的 dev DMG（例如证书尚未就绪），用：

```bash
gh workflow run Release -f release_tag=v0.2.0 -f allow_unsigned_dev_dmg=true
```

产物名为 `DeskBox-<ver>-dev.dmg`，README 内明确标注「未公证」，不会与正式版混淆。
