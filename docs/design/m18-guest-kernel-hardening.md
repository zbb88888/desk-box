# M18：guest 内核级纵深防线（Landlock + seccomp-bpf）

状态：已完成（M18a）；关联 `two-layer-security-model.md`、`m2-2b-isolation-layers.md`、`security-verification-matrix.md`。

## 1. 目标

在执行链上再加一层**内核级**约束，使「uid 65534 + rlimit + namespaces + cgroup」之外还有：

- **路径面**：Landlock 把 exec 子进程的可见文件系统收缩到只读系统目录 + `/workspace`、`/tmp`、`/dev` 可写，越界写入被内核拒绝（不依赖用户态检查）。
- **系统调用面**：seccomp-bpf 拦截危险 syscall 面（`mount`/`ptrace`/`bpf`/`keyctl`/`unshare`/`kexec` 等），返回 `EPERM`，可审计、不静默。

串联顺序（fail-closed，任一步失败即 `_exit(126)`，不降级）：

```
rlimit → setgroups/setgid/setuid(65534) → PR_SET_NO_NEW_PRIVS → PR_SET_DUMPABLE=0
       → landlock_apply() → seccomp_apply() → env 白名单 → chdir → execvp
```

## 2. 关键范围决策（诚实标注）

原计划写的是「默认 deny 白名单」。**本阶段改为两层，M18a 先落 deny-list，M18b 再做默认 deny**：

| | 形态 | 本阶段 |
| --- | --- | --- |
| **M18a（本次）** | seccomp **deny-list**（默认放行 + 危险 syscall 返回 EPERM）+ Landlock FS 白名单 | ✅ 实现 |
| **M18b（后续）** | seccomp **默认拒绝 + 按 workload profile 放行**，profile 随 manifest 签名传递 | ⏳ 待做 |

**理由（不掩饰）**：默认 deny 的 syscall 白名单对任意 workload 极其脆弱——glibc/musl 动态加载、`clone3` vs `clone`、新内核新增 syscall 都会让合法程序直接崩。要把它做正确，必须先有「profile 命名 + 签名 + 版本化 + 每个 profile 的 workload 回归矩阵」，这是一整个阶段的工作量。先落 deny-list 能在**不破坏现有 workload** 的前提下拿到绝大部分纵深收益，并且可立即验证。M18b 再补默认 deny。

Landlock 侧则是真正的白名单语义（handled_access_fs 覆盖写类权限，规则按路径授予），所以路径面在本阶段已达成白名单效果。

## 3. 实现要点

### 3.1 内核配置（custom kernel）

```
CONFIG_SECURITY=y
CONFIG_SECURITY_LANDLOCK=y
CONFIG_LSM="landlock"
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
```

Landlock 需要 `ABI >= 1`（Linux 5.13+）。本仓库自定义内核为 6.12.x，支持 ABI 5/6。若运行在不支持的内核上（如外部替换的 vmlinuz），exec 直接失败——这是有意的 fail-closed，不做静默跳过。

### 3.2 Landlock 规则表

| 路径 | 权限 |
| --- | --- |
| `/workspace` | 全读写（read/write/remove/make/execute/refer/truncate） |
| `/tmp` | 全读写（不含 execute） |
| `/dev` | read + write + read_dir（不给 make_char，避免造设备节点） |
| `/bin` `/sbin` `/usr` `/lib` `/lib64` `/etc` `/proc` | read + read_dir + execute |

`handled_access_fs` 按 ABI 动态扩展：`REFER`(ABI≥2)、`TRUNCATE`(ABI≥3)。

### 3.3 seccomp deny-list（EPERM）

`mount` `umount2` `pivot_root` `chroot` `unshare` `setns` `ptrace` `process_vm_readv` `process_vm_writev` `kcmp` `bpf` `perf_event_open` `userfaultfd` `init_module` `finit_module` `delete_module` `kexec_load` `kexec_file_load` `reboot` `swapon` `swapoff` `sethostname` `setdomainname` `acct` `settimeofday` `clock_settime` `adjtimex` `clock_adjtime` `keyctl` `add_key` `request_key` `open_by_handle_at` `name_to_handle_at` `syslog` `fanotify_init` `lookup_dcookie` `personality`（x86 另加 `iopl` `ioperm`）。

架构校验：`seccomp_data.arch` 不是目标架构 → `KILL_PROCESS`（阻断 x86_64 兼容层绕过）。

## 3.4 实施记录（踩到的三个真问题）

1. **guest 运行时根是 initramfs，不是 ext4**：`deskbox-bootstrap` 在 `switch_root` 之前常驻，所以 `/proc/mounts` 显示 `rootfs / rootfs`。因此 `/workspace` 的 mode 必须在 initrd 里设定（ramfs），只改 ext4 镜像无效——这是 M18 首次验证 `writespace EACCES` 的根因。
2. **`/workspace` 原本是 755 root**：exec 子进程是 uid 65534，DAC 直接拒写。Landlock 放行不等于可写，两层都要对上 → 统一 `1777`（粘滞位），`/tmp`、`/run` 同。
3. **Landlock 回退路径是漏洞**：最初 `/workspace` 不存在时会退化成给 `/` 授予读写，等于没约束。已改为 fail-closed（直接失败，绝不回退）。

另外把 `/bin/hardening-probe` 纳入 MVP exec 允许列表：它是随签名 rootfs 下发的固定自检二进制（只跑预置测例），用于让「内核加固是否生效」可被自动化断言。

## 4. 验收

1. **正例**：`/bin/echo`、`/bin/ash -l`（含 PTY）、`id -u`、workspace 读写、OCI workload 全部照常工作；
2. **负例（越权 syscall）**：`mount`、`ptrace`、`bpf`、`keyctl`、`unshare` 均返回 `EPERM`；
3. **负例（越界写）**：写 `/etc/x`、`/root/x`、`/proc/sys/...` 被拒（Landlock `EACCES`）；
4. **fallback 负例**：不启动 Landlock 的路径不存在——若内核不支持，exec 返回 `exec hardening failed`，不降级；
5. **回归**：`swift test` 全绿、`e2e-sandbox-lifecycle.sh` 17/17、`e2e-gui-buttons.sh` 14/14。

验证脚本：`macos/scripts/e2e-kernel-hardening.sh`（断言每条负例的具体 errno），探针 `macos/scripts/hardening-probe.c`。

**实测结果**（2026-10-28，Apple Silicon + VZ + 自定义 6.12 内核）：

```
[kern] PASS: 正例 writespace 允许 (rc=0)
[kern] PASS: 正例 writetmp 允许 (rc=0)
[kern] PASS: 正例 readbin 允许 (rc=0)
[kern] PASS: 负例 outwrite 被拒 errno=13      # Landlock EACCES（对照组 0777）
[kern] PASS: 负例 outwrite_etc 被拒 errno=13  # Landlock EACCES
[kern] PASS: 负例 mount 被拒 errno=1          # seccomp EPERM
[kern] PASS: 负例 ptrace 被拒 errno=1
[kern] PASS: 负例 unshare 被拒 errno=1
[kern] PASS: 负例 keyctl 被拒 errno=1
[kern] PASS: 负例 bpf 被拒 errno=1
[kern] PASS: 既有 exec workload 未受影响
[kern] PASS: /workspace 读写正常
[kern] 结果：PASS=12 FAIL=0
```

回归：`swift test` 18/18 suites 全绿；`e2e-sandbox-lifecycle.sh` 17/17；`e2e-gui-buttons.sh` 14/14。

内核侧无需重建：既有 M14b 自定义内核已含 `CONFIG_SECCOMP_FILTER=y` / `CONFIG_SECURITY_LANDLOCK=y` / `CONFIG_LSM` 含 landlock（已从 `vmlinuz-virt-gpu` 的 IKCONFIG 实证）。`scripts/custom-kernel.config` 已补显式条目，保证未来重建一致。

## 5. 非目标

- 不做默认 deny syscall 白名单（M18b）。
- 不做 LSM（AppArmor/SELinux）策略——`CONFIG_AUDIT` 关闭，policy 加载链成本高，收益与 seccomp+Landlock 重叠。
- 不限制网络 syscall：沙箱默认无网卡，网络约束由 broker 负责。
