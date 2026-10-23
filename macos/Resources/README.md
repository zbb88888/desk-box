# macOS 运行资源

## Entitlement

`DeskBox.entitlements` 是调用 `Virtualization.framework` 的最小 entitlement 模板：

```xml
<com.apple.security.virtualization>true</com.apple.security.virtualization>
```

SwiftPM 的 debug executable 不会自动使用此文件。真实启动前必须使用发布签名重新签名 `dbx-poc` 或宿主 app：

```bash
codesign --force --deep --sign "Developer ID Application: ..." \
  --entitlements macos/Resources/DeskBox.entitlements \
  macos/.build/release/dbx-poc
codesign --display --entitlements :- macos/.build/release/dbx-poc
```

不要把 ad-hoc 签名或未验证 entitlement 当作发布证据。最终使用的签名、Team ID、notarization 和系统版本必须写入平台能力矩阵 §4 的 POC 证据。

## Guest asset manifest

可以使用 CLI 根据已有 Linux guest 文件自动生成 manifest 和 SHA-256：

```bash
swift run dbx-poc make-manifest \
  --kernel ./guest/vmlinuz-arm64 \
  --initrd ./guest/initrd.img \
  --root-disk ./guest/root-disk.vhd \
  --output ./guest/manifest.json
```

`dbx-poc launch` 接受 JSON manifest。路径可相对 manifest 文件；`fileDigests` 使用同样的路径并在读取时解析为绝对路径：

```json
{
  "kernelURL": "vmlinuz-arm64",
  "initrdURL": "initrd.img",
  "rootDiskURL": "root-disk.vhd",
  "kernelCommandLine": "console=hvc0 root=/dev/vda rw init=/sbin/init",
  "guestAssetVersion": 1,
  "manifestDigest": "replace-with-signed-manifest-digest",
  "fileDigests": {
    "vmlinuz-arm64": "64-hex-sha256",
    "initrd.img": "64-hex-sha256",
    "root-disk.vhd": "64-hex-sha256"
  }
}
```

当前实现只校验文件 digest，不校验 manifest 的签名。签名 manifest、更新签名和 downgrade protection 是发布阻断项。

## 启动

```bash
cd macos
swift build -c release
swift run dbx-poc capcheck
swift run dbx-poc validate-assets ./guest/manifest.json
swift run dbx-poc launch ./guest/manifest.json --cow-root "$HOME/Library/Application Support/DeskBox/cows"
```

`launch` 是前台 POC：

1. 校验 guest asset；
2. 创建 per-sandbox APFS COW clone；
3. 创建不带普通网卡、带 virtio socket control port 的 VZ Linux VM；
4. 启动 VM，并把 guest `console=hvc0` 输出转发到宿主 stderr；console 仅用于诊断；
5. 接收 guest control frame；合法的 boot-bound hello 会返回 `requiresTLS=true`，未完成 TLS/bootstrap 的 frame 只记审计并拒绝，不改变生命周期；
6. 输出 `sandboxID`、`bootID` 和 `BootContext`；
7. 等待 EOF，然后 stop + destroy + 删除 COW。

当前没有 guest `execd` bootstrap 客户端，因此输出状态是 `pending-bootstrap`，不能当作产品 `Running`。guest kernel 的 `console=hvc0` 启动日志只能证明 guest 有输出，不能证明 readiness、身份或 attestation。通过 Ctrl-C 结束时，终止信号是否经过正常 Swift 清理路径必须在真实 POC 中验证；优先使用 stdin EOF 做确定性清理测试。
