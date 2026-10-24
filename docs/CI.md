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