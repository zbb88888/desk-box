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

可使用脚本执行 release 构建、签名、entitlement 验证和启动：

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." \
  ./macos/scripts/sign-and-run.sh ./macos/guest/manifest.json
```

没有有效签名 identity 时，`swift run dbx-poc launch` 会在 VZ 配置校验阶段被系统拒绝，这是预期的 fail-closed 行为。

VZ 的对象 API（包括 `start`、`stop`、`canStop` 和 socket device mutation）必须在创建 `VZVirtualMachine` 时指定的 queue 上调用；违反该约束会触发系统断言而不是普通 Swift error。runtime 已将这些调用统一封装到 VM queue。若 entitlement 已正确而启动仍返回 `Internal Virtualization error`，应优先检查 guest kernel/initrd/root disk 的 VZ 兼容性及 macOS 系统日志，而不是绕过 queue 或关闭安全控制。

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

注意：`VZLinuxBootLoader` 需要直接可启动的 Linux arm64 `Image`。Alpine `vmlinuz-virt` 是 EFI PE/COFF wrapper，不能直接作为 VZ kernel；开发脚本使用 Debian installer arm64 `Image` 作为 kernel，Alpine minirootfs 作为 root disk 内容。两者的版本、来源和兼容性必须在生产 guest 资产流程中重新冻结。

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
7. 前台 POC 将宿主 stdin 字节转发到 guest serial console（仅诊断/交互，不是可信控制面）；收到 stdin EOF、SIGINT 或 SIGTERM 后统一执行 stop + destroy + 删除 COW。

CLI 会输出 bootstrap 状态：`notConnected` 或 `helloAcceptedTLSRequired`。当前没有 TLS 1.3 session/proof，因此即使 hello 被接受也不能当作产品 `Running`。若持续运行只看到 `notConnected`，应通过 serial console 检查 guest initramfs 是否输出 `Desk Box bootstrap:`；构建脚本生成的 guest client 会报告 cmdline 缺失、VSOCK socket/connect errno 或 hello sent。guest kernel 的 `console=hvc0` 启动日志只能证明 guest 有输出，不能证明 readiness、身份或 attestation。serial console 输入同样不具备授权语义，产品命令执行必须走认证的 execd/control channel。信号清理路径仍需在真实实体机上验证，尤其是进程被 SIGKILL 或宿主崩溃时的孤儿资源回收。
