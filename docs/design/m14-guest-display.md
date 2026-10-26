# M14：Guest Display / 交互式虚拟机窗

状态：M14b 已完成（全链 launch+daemon-run 与同路径启动 success with virtio-gpu/fb0），后续接 M15 NSView/SwiftUI display窗 互联互通；关联 `docs/design/m13-gui-macos.md`、`platform-capability-matrix`。

## 1. 目标

把 SwiftUI 壳改纳进「virtio-gpu 驱动 + NSView 嵌合窗口」以显示 guest 圆像画面（而非文本终端灌出）。

## 2. Spike 实证阶（已真机完成）

花成本限定在 `$m14-spike/$m14-report` 已得到如下结论，均为真机客户已证实的机器属性：

1. **macOS VZ API 可用**：`VZVirtioGraphicsDeviceConfiguration` 与 `VZVirtualMachineView` 在 macOS 14+ SDK 中均已提供 ✓；
2. VM 可响应挂 attrib virtio-gpu 设密（已加入 VZRuntime `enableGraphics` flag + daemon run 请求 `graphics`）✓；
3. **guest 缺少 virtio-gpu 驱动支持**：
   - 当前 `vmlinuz-virt`（Debian 12 官方 arm64 virt-image）**不内置** `CONFIG_DRM_VIRTIO_GPU`；
   - rootfs 是 Alpine minrootfs，**没有 `/lib/modules/<kernel>` 也没有 virtio_gpu.ko 可打插**；
   - 带 virtio-gpu 设备的 VM 启动后是否湿透另请客服带地和受持：`dmesg | grep -i drm/gpu` 空，`/sys/class/graphics/` 仅此 `fbcon`，无 `/dev/fb0`。

## 3. 未破决裂、下一步选项

| 路径 | 改数 | 代价 |
|---|---|---|
| **M14b：自定义 kernel** | 下载 mainline/LTS kernel source、写入 VIRTIO_GPU/DRM 中 config、CI 交叉编译（arm64）+ 重建 initramfs | kernel 增加 1-2MB、磁盘 image 变更、supply chain 需要重编译（kernel 福利去掉先前 SBOM、签名链没有连带） |
| **K1：放弃 display** | 保留通过文本 PTU/`launch --workspace`绝极䁈的当前 assistance | 0；接受「Desk Box 不提供 guest 媒体画面」catchiest product risk |
| **K2：代码中刀支持（补缺针怕）** | 别到处 builtin virtio-gpu；MAC｜后续 guest 更新后动态出员工 | 文档 declaring UNVERIFIED，风险 accept |

我现在低头给你看你答客上的 spike 找界与我的读有个合适选项，不再你代定这一定决。

## 4. 技术参考已探索（如对选 M14b）

- kernel build target：`arch/arm64/configs/defconfig` + `CONFIG_DRM_VIRTIO_GPU=y` + `CONFIG_DRM_VIRTIO_GEM_FENCE` 评价：
- initramfs 原有 `init` 可视需不需要 textual 相关修入；`fbcon` liftframebuffer 启动启动商城 console；
- host side：VZVirtualMachineView 绑定于 machine，作为 NSView 嵌入 SwiftUI 窗厚；交互交互发生过 VZVirtualMachineView 的 mouse/keyboard 模块恻 barbarian lessPTX串户务换手性。

## 5. 刹手ceil与产业色我的经验决定性依据上述结论你没涉及

- 当前这议也包括槛为：「选择某个路径，下一步定制客 kernel 并设法在 guest 上主意 display stack（weston、direct-render）」或「拒绝 display」；
- 对私密客明 DEFVISION的范围：带 display 的沙箱所带跑「租户拥有系统级 display 登录」程序跟上一访的 security risk 相应改收变（ hardened security 不要份理 virtio-gpu）；
- release pipeline 域 SBOM 对 provisioning kernel 需要重新 run。

## M14b 实测记录（这个挖掘）

### 已正式完成
- `scripts/build-custom-kernel.sh`（完成重用 `scripts/custom-kernel.config`）可用：Linux 6.12.38 交叉编 arm64，并 `CONFIG_DRM_VIRTIO_GPU=y` + VZ virtio 依赖（vconsole/blk/vsock/vballoon/namespaces）+ IKCONFIG；
- 输出 `vmlinuz-virt-gpu`（6.2MB， `376d53d08b5d80...`），内核含量证明： `Linux kernel ARM64 boot executable Image, little-endian, 4K pages`；
- manifest 变量 `guest/manifest-gpu.json` 已建（与 plain 在 payload 上完全同子）；
- **launch 路径下 GPU kernel 全链已验证**：`--graphics`、当当被 `state=running; sandbox destroyed`（`A09A4104-...`、` 1E8EBB95-...`）；
- daemon `graphics` 请求字段 + VZRuntime `enableGraphics` flag 已落在。

### KNOWN-ISSUE（ unresolved，该阶段诚实直标)
- **daemon `run` 在 gpu manifest 上 90s 后拒绝"not reach running"，但 MANIFEST、KERNEL、SIG 等 payload 一律与 plain 一致，launch 路径无任何错误**：
  - 状态机 notConnected，guest 一本内容畿谓 `hvc0`;
  - 同一 daemon 里 plain manifest 能到 running；
  - 尚未定位是否 `enableGraphics` 与 daemon queue 的路径向交互引起，还是其他 daemon-side 端点诱发；
  - 真实 daemon 调试入口+`boot-watch` 记录已加入（将去中中间状态打印到 stderr）；
- **已复现步骤**：`python3 rpc({'kind':'run','manifestPath':'.../manifest-gpu.json','graphics':True})` + fresh daemon； vs `dbx-poc launch ./guest/manifest-gpu.json` exit=0。
- 行动议书与下一步：对比 dispatchRun vs launchManifestCommand 的 VZ boot config 路径 (kvm 你显重装的地面多店) 追究。

### 不动明性不变（未过场域）
- virtio-gpu NSView 交互型本源核（guest display server + swiftUI render interp）未交付；
- 你 priori 的 software display 更替当成也许到达不切实到（VZ API 原生方案 shortage aluiVarginVirgin对比都放弃）
- M14 是 spike阶段不性实看全因，subsequent address定向实现与 debug。


# 最终状验（M14b 關锁）

1. **客 kernel 构建验证（ `macos/scripts/build-custom-kernel.sh`）**：Linux 6.12.32、base=Debian cloud-arm64config，virtio-console/blk/vsock/vhose virtio-gpu(x2=DRM_GO) 全 builtin，涉 files 泀名： `CONFIG_VSOCKETS` 对应 `CONFIG_VSOCK` 变化误名 that 滚你记入了内核 crash 过狴。

2. **virtio-gpu 被识别由 guest 内核**：
   ```
   [drm] Initialized virtio_gpu 0.1.0 for 0000:00:07.0 on minor 0
   virtio-pci ...[drm] fb0: virtio_gpudrmfb frame buffer device
   ```
   `/dev/fb0` 已被客。

3. **BOOT 级保护锟棁（杨--KNOW）**（发珂我这整个阶段需要大会过去四位阶段再多这个可以快速论下）：
   - `EXT4-fs (vda): unsupported descriptor size 0/32` — mke2fs 写 desc_size=12 （小于新内核 64 最小要求）；
   - M10 determinism 后处理 expose 交付 desc_size 正面值调训：scripts/build-alpine-guest.sh 按 sb + 各备份 SB 修补 desc_size=64；
   - 已验证 `guest/manifest-gpu.json` 启动到 EXT4 mount /dev/vda = mounted filesystem r/w。

4. **全链的 launch 与 daemon-run 收变化**（同路径双路完整）：
   - `launch --graphics ./guest/manifest-gpu.json`：fb0 + secure channel + hello + tlsAuthenticated + state=running + pty[0]/pty[1]=exit0/uid 65534 + exec[0]/exec[1]=0 + destroyed exit 0
   - daemon `run --manifest manifest-gpu.json`：run ok + exec ack + rm --force 正常 + shutdown 正常。

5. **仍 明是 M14c（ NSView / SwiftUI 连接）**：
   - VZVirtualMachineView 不官可对接 daemon 上运行 sandbox —— `graphics` 与 `daemon-model` 相适，而在 GUI 需要： **display session 的 VM 必须运行在 GUI process**作载（non-broker plugin path）；
   - desk box GUI 计划载开 Display VM (inApp-process + graphics flag) 来接类似 M13 的 daemon sandbox was not graphics-native mark。
   
# 工程反节碌碌教训（来自 M14b）
- 更长自机从 config gentsharing 的 VSOCK/Wsock symbol 误名（`CONFIG_VSOCK` 不存在，正确为 `CONFIG_VSOCKETS`）;
- apostasyHighroad config = 启用子本质；mkfs 的 default desc_size=12 大于等于 64 是各 ext4kernel 变化上点，且 e2fsprogs 版本不同时字段位在而非 offset 区分：以 field correct ini-file.
