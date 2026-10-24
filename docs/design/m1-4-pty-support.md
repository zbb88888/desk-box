# M1-4 Guest PTY 支撑（交互式 Agent 用）

状态：开发计划与实现参考（M1-4，进行中）
范围：guest `execd` 真正的 pseudo-TTY 分配、流式 I/O、resize、关闭
父文档：[two-layer-security-model.md](two-layer-security-model.md)、[m1-tls-channel-upgrade.md](m1-tls-channel-upgrade.md)

## 1. 目标与范围

为后续 Claude Code / Codex / shell 交互场景落地真实 PTY：

- guest 侧基于 POSIX `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` 分配 master/slave；
- child 进程以 nobody 身份运行（与 M1-3 hardening 一致）且 slave 必须是通过 `TIOCSCTTY` 拿到的 controlling terminal；
- 裸输出数据通过加密的 `ptyEvent` 帧流式回 host（不再走 stdout buffer 辄止）；
- resize 通过 `TIOCSWINSZ` 落地、信号可通过 close 的确排解除路径。

**不做**：PTY 加密由控制通道的 AEAD 复用（已在 M1-2 落地），不另外实现第 2 层 TLS；不支持 PTY 动态身份/guest shell 的内部命令（这属于后续 M2 的 execd 完整版）。

## 2. 与现有 MVP exec 的关系

M1-3 exec（无 shell、stdout bounded、exit code）依然是标准 exec（`fd0 非 TTY`）的保障路径。PTY 是**独立 channel kind**：将由 `ControlMessageKind` 新值承载（不会替换 exec request/response），其 child 归属和生命周期都由 M1-3 的相同 hardening 函数终于约束。

PTY child 必须跑 install_exec_hardening（nobody/rlimit/no_new_privs），除非 PTY 另有计划专用策略；一个 exec 通道的值是“受限命令输出”；一个 PTY 通道的值是“真实终端”。

## 3. 参考方向与细节实现点

### 3.1 Guest（C guest-bootstrap）

frame 层次：
- 一部分是在现有 VSOCK control framing + AEAD record 基础上的消息； 根据（M1-2）
- 以下为 PTY 消息 msg 的定义（JSON payload）： `{"ptyId":0}`、`"dataHex"`、`"cols"`、`"rows"`、`"exitCode"`、`"type"`；
- 原生讨论：PTY child 与非优化普通 exec child 的输入都是透明 Codebook 内部宿主请求，输入运行方式对白名单 UNC-stream 类型。

POSIX PTY：
- `posix_openpt(O_RDWR|O_NOCTTY)` → `grantpt` → `unlockpt` → `ptsname`；
- child： `setsid()` → open(pts, O_RDWR) → `ioctl(fd, TIOCSCTTY, 0)` → `dup2(0/1/2)` → hardening → exec。
- `/dev/pts` 必须在rootfs init 的 mount 阶段存在，`mount -t devpts devpts /dev/pts`。
- resize：`ioctl(master_fd, TIOCSWINSZ, ...)`.

Event-loop 复用：
- 现有主循环在 control socket 上 block read。PTy 需 poll()（可同时 read VSOCK control 的 帧 + monitoring pty output）。
- 满量 timeout 250ms 轮询 fake，成功失败可通过 `waitpid(..., WNOHANG)` 收 child 状态适最终Similar；

转码：
- JSON 模板同样稳定。数据帧使用 hex 编码：`dataHex`（临时，容易替换 base64 以提高效率）；
- child output 限制为每次 512 字节有界 output 帧。

### 3.2 宿主侧（Swift）

- `ControlMessageKind`：叠加值 `ptyOpen=9`, `ptyInput=10`, `ptyResize=11`, `ptyClose=12`, `ptyEvent=13` （向后兼容原始。
- 以现有的 request/response `requestID` 关联 PTY open 结果；流式 event 使用 `requestID` 关联 PTY open 结果。
- `SandboxRuntime` 上 TBD `SandboxRuntime-ext` `PtyRequest`／`PtyEvent` Codable 结构；保持 sender 模式是必然升级路径（。详述则 msg 中 `new SandboxRuntime` `PTY` 非必要 和设计和协调 OK）；
- `dbx-poc`：launch 验证真实 PTY： `/bin/sh` in tty，输出 `id`/ `tty` 名 (`/dev/pts/*`)，证明真实 controlling terminal。

### 3.3 Cascade ack（安全不变量）

- PTY-open/event 的路径用现有 execd hardening；
- hex 与 JSON 内部文本是零代码 有清晰结构且 JSON 模型达到 stderr 完全主题文本结构，错误输出无压力；
- 通话 requestID/sequence 不能重复 key，记录日志 audit；
- 对 exec-child process 超时 drinGID 每次调用的 child 运行策略都落实到最近结构，包括 entry-point timeout（参考 M1-3）。

## 进度（M1-4，真机验证过，全部 exit=0）

- ✅ 字节层 `ControlMessageKind`：`ptyOpen/ptyInput/ptyResize/ptyClose/ptyEvent` 与共享消息结构就位；
- ✅ Guest PTY：`/dev/pts` 由静态二进制确定的 `mount(2)` 挂载配置（不再依赖 handoff init 的 busybox mount）、`posix_openpt`/`TIOCSCTTY`、`TIOCSWINSZ`、事件流（poll() 复用 VSOCK control + master fd）；
- ✅ Child：PTY child 以 nobody 65534 运行并先经 `install_exec_hardening`；
- ✅ Exec pathos：55 record-encrypted OU plaintext record-mode 都已验证；
- ✅ 输出流： `output` event 有界 512 bytes hex-encode、事件序列在 ControlSequenceGuard 下防玩；
- ✅ Host：`ptyRoundTrip` 公开 API，CLI 提供两个 PTY 验证：
  - `pty[0]=exit0 stdout=DBX_PTY_MARKER | /dev/pts/0 | 65534` （初始 causality + 真 terminal + nobody 身份）
  - `pty[1]=exit0 stdout=hello-pty | DBX_PTY_INPUT=hello-pty`（真实 stdin `read` 回合交互）；

## 4. 实施步骤

1. **设计锚定**：本文档 + 原状扭结定义再Purchase，先 original detail `DetailProgress.md` 以为 `M1` 的 detailprogress 累的更新。
2. **Core**：pty messages 加上 Regressed tests；
3. **Guest**：[devpts mount] + `pty_manager` 的 past-cycle 实现 + event 流配置；
4. **Host**：VZRuntime pty API (open/resize/input/close) / `ptyRoundTrip`；
5. **dbx-poc CLI**：PTY 流运行验证 demo （打印完整翻译互动）；
6. **回归**：默认加密+真机双稳态、检查 infra no-weakening；
7. **Security-matrix 更新**：INV-08 partially finished 差异体现。

## 5. Limitations of current MVP implementation territory

- 仅 `PtyId=0` 单 PTY；
- 无窗口信场 size mismatch CTNG 防 signal；
- 无真正的 noise-only-host-initiated `close` 用绝对 release 令 。

## 6. 参考材料（实现时优先查阅）

- Linux man-pages: `pseudoterminal`, `posix_openpt`, `TIOCSCTTY`, `TIOCSWINSZ`, `poll(2)`；
- POSIXecsocket `socketpair/pty` and openpt symlink 和维护触发 `ptsgrant`/`ptsname 事例`;
- OpenSandbox `execd`（references/）的 PTY 增长需求参考 — 我们保留自身简化版本，不能直接复制其产品代码；
- macOS's own PTY `posixopenpt` usage, Kernel primarily guidance.
