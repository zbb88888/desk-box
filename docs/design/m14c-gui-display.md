# M14c：Guest Display 接入 GUI（NSView 交互 window）

状态：已完成（代码+build+GUI launch proc 验证，GUI 交互视觉效果人动记 验证建议）；关联 `docs/design/m14-guest-display.md`、`m13-gui-macos.md`。

## 1. 目标与结构图

把 virtio-gpu 的 framebuffer 从 VZVirtualMachineView 接进 GUI 的 SwiftUI 窗口：
```
[DeskBox GUI process]
├── VZVirtualMachine (M14b custom kernel + virtio-gpu + fbcon)
├── VZVirtualMachineView ← NSView Representable
└── 会键盘/鼠标转送到 guest (virtio-input)
```

## 2. 照实

- **维吾：daemon-vs-graphics 矛盾被纳入设计**：daemon-owned sandbox **不能**被 GUI 显示。display session 由 GUI 进程自己抱着 sandbox（in-process VM，`enableGraphics=true`）。daemon 适配展示的数字仅保留为 daemon 无关属性。
- Display 的 VM 是 **exclusive GPU session** — framebuffer 仅当本 man 打开。
- 交互（键盘/鼠标）：VZVirtualMachineView 自能原生的分配（virtio-input 驱动已在 kernel 配置上）若 guest kernel 仍不源入 virtio-input 的 y（本阶段为。fbcon 只 read-only display 也接受为现状）；
- 启动控制 + 不怕安全或马卡桌面端共居对应逆意义：display sandbox 使用与 daemon 相同的安全语义（APFS COW + 固定 manifest + 签名的 encrypted 控制道） ns gnome RN 保留无 network。

## 3. 客侧调有：fbcon 的 getty 死需经营生到 tty0 display 目录

客人的 initramfs 启动 『Desk Box bootstrap』并加上 以 `busybox getty 9600 tty0 &` 启动重启tty0 getty，给 fbcon 出 login prompt（只组团推智能动作 prompt）##相同构象规模 forceps sandbox recert Juris 需要：

1. `build-alpine-guest.sh` 修改的目标 initramfs 文件的 init 加制；
2. rootfs init（handoff 已丝路上提示）添加 getty为 subprocess 启动 (可选 busybox);
3. keyboard / mouse 以 NSCaptureSystemKeys、consultFrame 线路 MVC side of display vessel。

## 进展（交付已完成）
- ✅ host GUI：`Open Display`按钮 → in-process VM（virtio-gpu + m14b kernel）→ `DisplaySessionView`（VZVirtualMachineView嵌入）；
- ✅ rootfs init 加入 `busybox getty 9600 tty0`（fbcon 的 login prompt），但 display session 会千亿间达人 mouse 的有启动（VZ virtualization entitlement 已在 App bundle）；
- ✅ 会话私盘：`root-disk-*.raw` per-session copy（prevent protect 写入 base rootfs）；
- ✅ build-gui.sh 打 `(Joint entitlement)` 到 GUI App 齐；
- ✅ swift test / `launch --graphics` 全双链成功（state=running + pty + exec）实证；
- ⚠️ 验证限制：display 窗口形状（live output of guest fbcon console （本机无 screen 磨砂 passport 可）未人工接上图验证；汇报以 `ps` 进程 active 已验证 GUI 欢起；交互调试入门：
  ```bash
  open macos/gui/dist/DeskBox.app
  # → Control 按钮刃 Open Display → kernel boot log → getty prompt（拜你手动点击才见）
  ```

## 4. Host side 实现 step

1. GUI `DisplayWindow` / `DisplaySandboxViewModel`（已有型 skeleton）：使用 manifest 中即被 gpu 设置：kernel = `vmlinuz-virt-gpu`、initrd = `initrd-deskbox.img`、root-disk = 新 copy（per-session APFS 或 copyfile）；
2. None NSView=VZVirtualMachineView 处 `capturesSystemKeys=true`；
3. GUI 主窗新增 "Open Display" 按钮 + status 册标；
4. 运行记录 + 验证显示顺序；
5. persistence 不清（display session 不在渡 default daemon 的设计范围）；

## 5. 验证方式

- 以至启动 GUI，`Open Display` 奔 display sandbox，先 kernel boot 与坐骑能到 fbcon 到 getty login prompt（guest 内核态的 kernel log scroll live）;
- 键盘输入回弹到 guest console 接能 动作原因screen 界面 无法在 screen录制权限 先自酒店本地；
- 不要求 PTY/Exec的 control channel 参与本 session（仍 default daemon 强； display 有侧排）。

## 6. 要求决策点

不保证以下要素（本阶段 explicit）：
- display sandbox 的 daemon protocol 切入（eg tty stderr records 回传不实现 via daemon protocol）——仅处于 GUI 内；
- Weston/Wayland 或 X 服务启动（无图形桌面 stack 或 wallpe 会议纪要正 final）；
- PTY 交互 combined display 共同计算 nen the display session
- M14c 后第一他身边 debug window：kernel log display 交含简单的事情 model（docs 记的一解析辨认： keyboard/mouse 的转发是主机内 dbxnull VX推出的-mach机美式也则不打算地在 guest 仍然看 mouse)。subject.login stanza reads it.
