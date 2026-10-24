# M2-2b：guest 工作负载的 namespaces + cgroup v2 第二道锤难

状态：已完成（真机双路径 exit=0）；前置 M2-2a；关联 `docs/design/m2-roadmap.md`、`docs/security/security-verification-matrix.md` INV-08。

## 进度

- ✅ Guest 每个 exec 子进程改走 `clone(CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWPID)` + 独立 child stack；
- ✅ 每 exec 创建 `/sys/fs/cgroup/dbx-exec-<n>`：`cpu.max=50000 100000`、`memory.max=256MiB`、`pids.max=64`，均 write 检查 fail-closed；
- ✅ clone 后父进程写入 `cgroup.procs`（写不动 → SIGKILL 收死后拒绝，不做“尽力认为”带病进行）；
- ✅ 组合复用：M2-2a OCI 执行、M1-3 rlimits/nobody/no_new_privs 同步适用；
- ✅ 验证：默认加密 + `--allow-plaintext` 双路径，OCI/broker-guest/exec/pty 组合于同一 launch 同发 exit=0；
- ✅ 关键点：cgroup2 必须 mount（我们 static guest 二进制完成），并由顶层 `cgroup.subtree_control` 开启 `+cpu +memory +pids`（子组才有对应文件）；
- 下一步（M2-4）：Windows Hyper-V 首次联通；runc 二进制集成仍是未来可选硬化，不影响安全决策。

## 1. 目标与非目标

### 1.1 目标
- guest 每个 exec/PTY 子进程增加两道硬保障：
  - **kernel namespace 隔离**：`CLONE_NEWPID`（子进程看不到宿主进程表）+ `CLONE_NEWNS`（mount 名字空间私有）+ `CLONE_NEWIPC`、`CLONE_NEWUTS`；
  - **cgroup v2 限额**：为每个 sandbox 创建 `/sys/fs/cgroup/dbx-<sandboxID>/` 子组，写入 `cpu.max` / `memory.max` / `pids.max` / `io.max`（作为冗余于 M1-3 rlimit 的 kernel-enforced 补充）；
- 验证 INV-08 的“资源与生命周期由宿主强制”部分完整闭环；
- OCI bundle 执行路径与 exec/PTY 共用同一硬化路径，无差异复用；

### 1.2 非目标
- 不在本阶段引入 runc 二进制打进 guest（rootfs 线扩张、musl 动静态链接等）；如果本阶段 kernel primitives 被验证，runc 集成是多带量工作但属于工程化升级而非安全决策变更；
- 不做 seccomp/LSM（AppArmor/SELinux 强制）；最小期是偶发不引入面；
- cgroup v2 写入面以 fail-closed：若 guest 不支持 cgroup v2 → hard-fail；（不允许静默降级为软 rlimit-on）

## 2. 实施参考

### 2.1 Guest 端（guest-bootstrap.c）
- `install_exec_hardening` 新增安装顺序：
  1. `unshare(CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC)`；
  2. 建立 cgroup v2：`/sys/fs/cgroup/dbx-workload-<pid>` (mkdir + write cpu.max/memory.max/pids.max/io.max)；
  3. `unshare(CLONE_NEWPID)` 后强制 `fork()` 单独 pid ns 再 exec；
  4. 子进程退出后父级销毁该 cgroup 目录；
- cgroup 文件若不存在 → fail（不给予部分降级）；
- PTY 路径用同一函数（由 `pty_spawn` 改为统一“hardening+exec”函数）。

### 2.2 宿主侧
- `DockerKernelConfig`：guest manifest 校验项增加 `cgroup2 must be mountable`（假内 kernel 支持）；
- 检查不必要生产部署上的 host Linux kernel ≥ 4.15（cgroup v2 标准）；
- cgroup 额外读取：destroy 阶段清除 cgroup 目录（fail-soft）。

### 2.3 CLI 演示扩展
- 增加 `--perf-cgroup` 伪例：跑一个 busybox 进程的 cpu spin `while :; do : ; done` 用 cpu.max=50000 触发 limit；现在在 cgroup 上限下应远低於 50%；文件系统 north 甸菇；
- `--verify-namespaces`：exec 显示 `/proc/self/ns/*` 的 inode 号，证明是新 namespace。

## 3. 验证（出样一步递增）
1. 两次 exec 各自得到独立 pid ns（`kill -9 1` 不越出沙箱）；
2. memory.max 强制小于需求时，子进程被 OOM kill 但不因伤家长；
3. cpu.max=50000（50% 限额）下 spin loop 明显低于 100%；
4. 默认加密 + `--allow-plaintext` 双路径；
5. `swift test` 及 cgroup 单元验证。

## 5. 安全决策
- **kernel-enforced 是底线**：rlimit（M1-3）是 syscall 层加速；本阶段加再加层 CSP cgroup 实现兜底 OS 决定，而不是自已决订；
- **fail-closed**：任一步失败（mkdir/write/unshare）→ 拒绝 exec，不静默降级；
- **不宣告 LSM/seccomp**：这些是更严的约束盒子，需站外面审核；本阶段是 INV-08 的 cgroup/资源侧。