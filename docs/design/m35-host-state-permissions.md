# M35：宿主侧状态的访问权限不依赖父目录

状态：已完成（resume 相关的 1 项新断言与历史遗留的 8 项因宿主锁屏未验证，见 §6）。
关联 `threat-model.md`、`m20-lifecycle-persistence.md`、`m23-credential-domains.md`、`m25-e2e-isolation.md`。

## 1. 问题

宿主侧的敏感状态——沙箱 COW 盘、加密快照、快照密钥、suspend/resume 期间的**明文 VM 内存状态**临时文件、含 guest 输出的 daemon 日志——此前的保密性完全来自「它们恰好在 `~/Library`（0700）下面」。一旦 `--cow-root` / `DBX_SUPPORT_ROOT` 指到别处，就全靠 umask 了。用改动前的二进制、`umask 000` 实测：

| 对象 | 改动前 |
|---|---|
| daemon 新建的 cow-root / 快照目录 | 0777 |
| 沙箱盘（clone） | **0644**——`clonefile` 继承基础镜像的权限，与 umask 无关；即使默认 umask 也是如此 |
| `registry.json` | 0666 |
| resume 时解密出来的明文 VM 状态临时文件 | 默认权限（0644） |
| 快照密钥 `snapshot.key`、快照 `.snap` | 最终 0600，但「先按默认权限写、再 chmod」，有窗口期 |
| GUI 写的 daemon 日志、display console 日志 | 0644 |

## 2. 原则

1. **我们新建的目录一律 0700；我们写的敏感文件一律 0600。**
2. **没有窗口期**：`SecureFile.write` 先在同目录用 `open(O_EXCL, 0600)` 建临时文件，写完 `fsync` 再 `rename`。目标路径上任何时刻都不会出现权限更宽的同内容文件。与 umask 无关。
3. **不 chmod 用户给的、已存在的顶层目录。** 它不是我们的东西（可能是 `$HOME`）。保护落在我们自己的文件和子目录上。唯一会被收紧的已存在目录是名字由我们决定、内容只属于我们的子目录（`<cow-root>/snapshots`），且仅当它属于当前用户。
4. 权限收紧失败即操作失败（沙箱盘 chmod 失败 → 创建失败并清理），不带着宽权限继续跑。

## 3. 改动

- `DeskBoxVZ/SecureStorage.swift`：`SecureFile.write` / `tighten`、`PrivateDirectory.create` / `ensureOwned`。
- `CowDiskManager`：新建的 cow-root 0700；clone 在 `clonefile` 之后立即 0600（那一刻盘里只有基础镜像的内容，guest 尚未写入）；域标记 0600。
- `SandboxRegistry`：`registry.json` 0600。
- `SnapshotStore`：密钥与快照走 `SecureFile`；加载到一个对组/其他用户可读的旧密钥文件时收紧它。
- `VZRuntime`：suspend 前确保快照目录是 0700（VZ 的保存文件权限由 VZ 决定，所以靠目录保护）；resume 的解密临时文件 0600。
- `SnapshotSweepPolicy`：`SecureFile` 的原子写入临时文件（`.<name>.tmp-<uuid>`）若因崩溃留下，过宽限期后清除。
- GUI：daemon 日志与 display console 日志 0600，已存在的旧日志一并收紧。
- `dbx-poc`：M34 的 `PrivateKeyFile` 改为复用 `SecureFile`（一套实现）。
- daemon socket **对端身份检查**（`DaemonPeerPolicy`，`getpeereid`）：只接受 daemon 自己的用户与 root，取不到身份也拒绝。socket 文件权限（0600，bind 之后、listen 之前收紧；未 listen 的 socket 无法被 connect，没有窗口期）仍是第一道防线，这是与文件权限无关的第二道。

## 4. 验证

单元测试 `SecureStorageTests` 16（多数在 `umask 000` 下执行）：写入 0600 且不留临时文件；覆盖旧的宽权限文件；只把**新建的**各级目录设为 0700、已存在的不动；`tighten` 只收紧不放宽；clone / 域标记 / registry / 快照密钥 / 快照的落盘权限；**用户提供的 0755 目录不被 chmod，但其中的沙箱盘是 0600**；对端身份策略与真实 socketpair 上的 `getpeereid`；daemon socket 在 `umask 000` 下是 0600。`swift test` 共 355 全绿。

真机 `scripts/e2e-state-permissions.sh`：27 通过 / 1 因锁屏跳过。daemon 以 `umask 000` 运行，cow-root 一次由 daemon 新建、一次直接放进已存在的 0755 目录：

```
daemon 新建的 cow-root 与中间目录 0700；用户提供的 0755 目录未被 chmod
沙箱盘 0600（基础镜像是 0644）；域标记 / registry.json / registry.lock 0600
socket / 单实例锁 / 调度证据 0600
suspend 后：快照目录 0700、快照 0600 且为密文、快照密钥 0600、无遗留的明文临时文件
兜底扫描：daemon 产生的所有文件与新建目录都没有任何组/其他用户权限位
```

**对照**：改动前的二进制跑同一套件，17 项失败（目录 0777、registry 0666、沙箱盘 0644…）。

`e2e-gui-app.sh` 新增：GUI 写的 daemon 日志是 0600。全量 `e2e-all.sh`：16 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

## 5. 一次需要更正的记录

M34 那一轮我用旧二进制对 `e2e-release-cli.sh` 做对照时，旧二进制**不认识 `DBX_SUPPORT_ROOT`**；其中 `launch`（带故意拼错的选项，旧解析器会忽略它继续执行）在失败之前对**用户真实的 cow-root** 做了一次 sweep 并重写了 `registry.json`。内容没有实质变化（仍是空列表），没有删除任何东西，但该文件的修改时间变了，而我当时报告的是「与基线一致」——卫生审计只包住 `e2e-all.sh`，那次对照在它之外。

本轮的旧二进制对照全部使用显式的 `--cow-root`，已核实没有触碰真实目录。以后凡是用**不支持隔离的旧二进制**做对照，只能跑显式给出全部路径的命令。

## 6. 诚实边界

- **未验证（宿主锁屏）**：本轮改了 resume 的解密临时文件写入方式，对应的断言「resume 后数据仍在 / 无遗留的解密临时文件」被跳过。加上历史遗留的 8 项，共 9 项。解锁后需重跑 `./scripts/e2e-all.sh` 并得到退出码 0。
- **已存在的文件不会被批量修正**：旧版本留下的 0644 沙箱盘、`registry.json`、日志不会被回头收紧（快照密钥与 GUI 日志例外，它们在被使用时收紧）。默认位置在 `~/Library` 下，本来就受父目录保护。
- cow-root 里的文件名（沙箱 ID）在用户提供的宽权限目录里仍然可被列出。
- VZ 保存文件自身的权限由 Virtualization.framework 决定，保护靠 0700 的快照目录；没有验证该文件本身的 mode。
- 对端身份检查只做了单元测试（策略 + 同用户的真实连接）；「另一个用户连接被拒」需要第二个系统账户，没有做。
- root 被允许连接。
