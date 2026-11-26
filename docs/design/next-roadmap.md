# Desk Box 后续开发计划（M18 起，macOS 单平台）

状态：计划草案，待逐项开立 design 文档。
前置：M0–M17 已完成（VZ VM 沙箱 / 加密控制通道 / exec+PTY+OCI / workspace / broker / namespaces+cgroup / 供应链 / 可复构建 / 幂等发布 / CI / daemon CLI / SwiftUI GUI / 自定义 virtio-gpu 内核 / 按钮级 e2e）。

## 0. 范围决定

- **Windows Hyper-V 移出路线图**：不再投入。`windows/` 与 `docs/design/m2-4-windows-hyperv.md` 保留为历史资产，明确标注 NOT PLANNED。
- 单平台 macOS（Apple Silicon + VZ）。所有安全证据只声称 macOS 已验证部分。

## 1. 排序原则

1. **发布门槛优先**：安全验证矩阵里 `未实现` / `部分已验证` 的不变量决定能否对外说「已验证安全」，优先补齐证据而不是加新功能。
2. **在不增加信任面前提下加深纵深**：guest 内第二道内核防线（seccomp/LSM）可在我们自己的 VM 里验证，成本低、收益直接。
3. **产品化最后**：notarization/DMG/自动更新依赖前面能力稳定，放后段一次做对。

## 2. 阶段清单

| 阶段 | 主题 | 解决的不变量 | 规模 | 关键验收 |
| --- | --- | --- | --- | --- |
| M18 ✅ | guest 内核级纵深：seccomp-bpf + Landlock | INV-06, INV-08 补强 | M | 恶意 syscall/路径逃逸 corpus 被内核拒绝且审计可读；fail-closed（无支撑则拒绝启动强隔离模式） |
| M19 ✅ | 安全证据补全（4 个 corpus） | INV-03, INV-04, INV-05, INV-06 | L | canary 扫描 / 网络绕过 / 文件系统 / 恶意 layer 四套 corpus 全部落成 CI 并出报告 |
| M20 ✅ | 生命周期持久化与不复活 | INV-10 | L | snapshot/suspend/resume + 更新/回滚 + 撤销 + 销毁故障注入全部通过，且不复活权限 |
| M21 ✅ | 资源统计与观测 | INV-08 剩余（资源统计上报） | S | guest 上报 CPU/mem/io → daemon `stats` → GUI Stats 面板；耗尽压力测试 |
| M22 | 产品化发布 v0.2.0 | —（发布面） | M | notarized .app + DMG + 更新检查 + 正式 release assets（repro-check 通过） |
| M23 ✅ | 多凭据域隔离 | INV-02 | L | 已完成：e2e 21/21 + 属性矩阵 11/11 |
| M24 ✅ | daemon 并发化 + 优雅停机 + 协议决策表 | —（可用性/健壮性；修 2 个 sweep 缺陷） | M | 已完成：UT 30 + e2e 31/31，详见 `m24-daemon-concurrency.md` |
| M25 ✅ | e2e 隔离化 + 卫生审计 | —（测试基建） | S | 已完成：`DBX_SUPPORT_ROOT` + 公共 harness + `e2e-all.sh`（11 套件全绿、卫生 clean）；M23 e2e 已在并发 daemon 上复验 21/21，详见 `m25-e2e-isolation.md` |
| M26 ✅ | exec 取消 + 引导失败快速诊断 | INV-08 周边 | M | 已完成：UT 27 + e2e 48/48；拆除类操作 ~40ms 返回（旧 ~39s），512MiB 引导 10s 报因（旧 90s），详见 `m26-boot-diagnosis-and-cancel.md` |
| M27 ✅ | 宿主侧健壮性收尾：CLI fail-closed / daemon 单实例守卫 / 跨进程 sweep 安全 / 销毁 suspended 沙箱删快照（INV-10）/ 锁屏 resume 诊断 | INV-10 + 可用性 | M | 已完成：UT 38 + e2e 54；当时因锁屏未验证的 6 项已在 M28 解锁后复验通过（`e2e-all.sh` 退出码 0） |
| M29 | guest 侧 exec kill 协议 | INV-08 周边 | L | 需重建 guest 资产 + `guestAssetVersion` 变更；客户端断开/显式 cancel 能杀掉 guest 内进程且保留沙箱。**需确认后再做** |
| M28 ✅ | suspend 失败回滚 + GUI 对齐 | INV-10 周边 + 产品面 | M | 已完成：suspend 中途失败回滚到 running（e2e 故障注入 8 项）；GUI 不再删 socket、被拒绝不再显示 daemon 已停、原因码可读呈现（`GUITests` 15）。GUI 界面行为未验证，见 `m28-suspend-rollback-and-gui-alignment.md` §4 手测清单 |
| M30 ✅ | GUI 可自动化验证 | —（产品面） | M | 已完成：GUI 识别 `DBX_SUPPORT_ROOT`、行内操作按状态启用（含 Suspend/Resume）、应用内自检 + 真 GUI 进程 e2e 20/20（菜单 ⌘Q、合成 ⌘Q 退出、daemon 无响应时主线程不卡）。变异检查证实「主线程同步 socket」是 ⌘Q bug 的真实根因，并更正了第一轮的一条错误结论，见 `m30-gui-automation.md` §3 |
| M31 ✅ | sheet 打开时无法退出 + Open Display 崩溃 | —（产品面） | M | 已完成：定位并修复 ⌘Q 的主因（AppKit 在有 sheet 时静默拒绝终止；所有退出请求改走 `AppQuit`）与「Open Display 必崩」（VM 在错误队列上启动）；e2e-gui-app 32/32，见 `m31-display-cmdq.md` |
| M32 ✅ | GUI 操作全链路 | —（产品面） | M | 已完成：操作逻辑移入视图模型；自检 flow 驱动真实 daemon + VM（Run→Exec→Suspend→Resume→Rm）；Exec 支持引号；引导类请求客户端超时 150s。e2e-gui-app 46 通过，见 `m32-gui-operation-flow.md` |
| M33 ✅ | 其余面板纳入验证 + 终端生命周期 | —（产品面 + PTY） | M | 已完成：修复「终端只能打开一次」（宿主从不发送 ptyClose）、suspend 前关闭 guest pty、遗弃会话抢占、hex 解码崩溃、终端输出净化、Stats 切换/失败处理；Terminal/Console/Stats/Workspace 纳入 GUI flow，见 `m33-panels-and-pty-lifecycle.md` |
| M34 ✅ | 签名 / 发布 / 校验类子命令 fail-closed | 供应链（M5/M7） | S | 已完成：15 个子命令迁到声明式解析（拼错的选项不再被静默忽略）、私钥文件 0600；no-VM e2e 53/53 并接入 CI；用旧二进制对照 31 项失败，见 `m34-release-cli-fail-closed.md` |
| M35 ✅ | 宿主侧状态的访问权限不依赖父目录 | INV-03 / INV-10 周边 | M | 已完成：沙箱盘 / 快照 / 密钥 / 明文 VM 状态临时文件 / 日志收紧到仅属主可读且无窗口期；daemon socket 对端身份检查；`umask 000` 下真机 e2e 27 通过（旧二进制 17 项失败），见 `m35-host-state-permissions.md` |
| M36 ✅ | E2E 证据化 + 安全验证矩阵同步 | 全部（证据面） | S | 已完成：`e2e-all.sh` 产出机器可读证据（含未验证的断言），按不变量汇总；矩阵新增 §2.1。当前证据：INV-01/04/06/09 通过，INV-02/03/08/10 不完整（锁屏），见 `m36-e2e-evidence.md` |
| M37 ✅ | workspace 同步的边界（INV-05） | INV-05 / INV-06 / INV-08 | L | 已完成：宿主 TOCTOU 修复；发现并修复 guest 接收端跟随 workload 预置符号链接（guest 内提权到 root）；宿主闸门在 guest 更新前生效；真机 e2e 旧 guest 45 / 补丁版 guest 54。**本机 guest 资产待重建**，见 `m37-workspace-sync-boundary.md` |
| M38 ✅ | 正式构建的 guest 候选：验证、安装与回滚 | INV-06 / INV-08 / INV-09 | M | 已完成：候选用正式脚本构建，全量 E2E 在候选上 0 失败；`install-guest-candidate.sh`（备份 / 自动回滚 / 重签 GPU manifest）；workload 与同步并发的真机用例。**安装到 `macos/guest` 留给用户**，见 `m38-guest-candidate.md` |
| M39 ✅ | exec 的输出：不卡住、不静默截断、退出码原样传递 | INV-08 | M | 已完成：guest 边等边读 + 流式回传（`execOutput` 帧）；宿主汇总并再次执行上限；旧 guest 给出提示；CLI 传递退出码。候选已按本轮源码重建。见 `m39-exec-output.md` |
| M39b | 安装候选（`macos/guest` 与 App bundle 里的那份） | INV-06 / INV-08 | S | 需用户确认：`install-guest-candidate.sh ./guest-candidate`；bundle 需停 daemon 后重新打包 |
| M41 ✅ | 取消在途的 exec（原 M29） | INV-08 | M | 已完成：guest 在 exec 期间读控制通道（`execCancel` 帧；其它帧排队）；daemon `execCancel` 按实际结果下结论；CLI `exec-cancel` 与 Ctrl-C；GUI Cancel。候选已重建。见 `m41-exec-cancel.md` |
| M42 ✅ | broker 入口不能搞垮控制面；exec 的客户端走了就别再跑 | INV-08 | M | 已完成：发现并修复「workload 经 broker socket 杀掉 guest 控制面」（SIGPIPE / 阻塞读 / exec 期间不受理）；daemon 监视 exec 客户端连接；修 M39 的超时提前回归。候选已重建。见 `m42-broker-entry-and-client-disconnect.md` |
| M43 ✅ | guest 控制面死亡的即时发现；`brokerreq` 返回真实结果 | INV-08 | M | 已完成：控制连接意外断开时在途 exec / stats 立刻以 `DBX-GUEST-CONTROL-LOST` 失败；broker 入口等拉取结束再应答（OK / ERR + 原因）。候选已重建。见 `m43-control-loss-and-broker-result.md` |
| M44 ✅ | 证据把环境缺失的跳过计为不完整；终端 `\r` 重绘；其余等待接入控制面丢失 | INV-08（证据质量） | S | 已完成，未改 guest、未碰 resume 路径。见 `m44-evidence-skips-terminal-redraw.md` |
| M45 ✅ | failed 沙箱：立刻可见、带原因、一步重建；生成密钥不覆盖已有私钥 | INV-08 / INV-09 | S | 已完成，未改 guest。见 `m45-failed-sandbox-and-key-overwrite.md` |
| M46 ✅ | 控制面丢失的常驻回归（故障夹具）；workload 不继承 bootstrap 描述符；runtime 数据竞争 | INV-08 | L | 已完成：发现并修复「workload 的 stdin 就是控制通道」与「onQueue 并不在队列上」（daemon 实际崩溃）；崩溃报告纳入卫生审计。候选已重建。见 `m46-control-loss-fixture-fd-hygiene-runtime-race.md` |
| M47 | 安装候选（`macos/guest` 与 App bundle 里的那份） | INV-06 / INV-08 | S | resume 已在两种 guest 上验证（M46 §5.1）；剩下的只是用户确认后执行 `install-guest-candidate.sh ./guest-candidate`，bundle 需停 daemon 后重新打包 |
| M48 ✅ | runtime 的全部状态访问都在队列上；ThreadSanitizer 跑真机套件 | INV-08 | M | 已完成：start / stop / destroy 拆段，`onQueueAsync` 删除；`tsan-e2e.sh` 在 7 个真机套件上 0 竞争报告；修 debug 构建 resume 时的未对齐 load。见 `m48-runtime-serialization-and-tsan.md` |
| M49 ✅ | TSan 覆盖全部真机套件、GUI 进程与单元测试；accept 循环不再空转 | INV-08 | M | 已完成：0 竞争报告；查清并修掉 TSan 下单测偶发失败的真正原因（测试里的重复 close 导致跨用例抢连接）；监听 socket 失效时 daemon 停止而不是空转。见 `m49-tsan-coverage-and-accept-loop.md` |
| M50 ✅ | Manifests 面板与菜单栏弹窗：逻辑移出视图 | —（产品面） | S | 已完成：面板的签名列此前永远是 `-`、不可用的 manifest 也给 Run；弹窗对任何状态都给 stop 且吞掉错误。现在两者都走可测试的模型并进了应用内自检。见 `m50-manifests-panel-and-menubar.md` |
| M51 ✅ | 版本偏差可见化：`doctor`、daemon `info`、GUI 提示条 | INV-08（可运维性） | S | 已完成：daemon 较旧 / guest 资产缺哪些修复，由产品自己报告。见 `m51-version-skew-doctor.md` |
| M52 ✅ | M51 的缺口：Stats 面板显示 guest 发现、旧 daemon 提示的应用内自检、修订号守卫 | INV-08（可运维性） | S | 已完成。见 `m52-skew-in-gui-and-revision-guard.md` |
| M39 | 真实点击与剩余界面 | —（产品面） | M | 评估需要辅助功能授权的真实点击测试（需你确认）；Manifests 面板、菜单栏弹窗；终端对 `\r` 重绘的处理 |
| M22b | 真机公证 | —（发布面） | S | 阻塞于 Developer ID 证书 |

---

## M18 ✅（已完成）：guest 内核级纵深（seccomp-bpf + Landlock）

> 结果：M18a 已交付（Landlock 白名单 + seccomp deny-list，fail-closed），e2e 12/12；M18b（默认 deny + 签名 workload profile）留作后续。详见 `m18-guest-kernel-hardening.md`。

**为什么现在做**：exec 已具备 namespaces + cgroup v2，但 syscall 面与文件系统面仍靠用户态策略。内核级白名单能在 runc/OCI 之外再收一层，且完全在我们自己的 VM 内可验证（无需外部环境）。

- **seccomp**：默认 deny + 按 workload profile 放行；`SCMP_ACT_ERRNO` 而非 kill，便于审计；profile 随 manifest 签名传递，防降级。
- **Landlock**：限制 exec 子进程可写路径到 `/workspace`，只读路径白名单；unprivileged 可用，无需 CAP_SYS_ADMIN。
- **串联**：`no_new_privs` → cgroup → landlock → seccomp → exec；任一环节不可用则 `fail-closed` 拒绝启动（不做静默降级）。
- **验收**：
  - corpus：越权 syscall（`mount`/`ptrace`/`bpf`/`keyctl`/`unshare`）、越界写（`/etc`、`/root`、`/proc/sys`）全部 EPERM/EACCES 且审计记录命中；
  - 现有 exec/PTY/OCI/workspace 用例零回归（e2e 17 + buttons 14 全绿）；
  - 关闭内核选项的负例：guest 启动即拒，不降级。
- **风险**：Debian cloud config 需补 `CONFIG_SECCOMP_FILTER`、`CONFIG_SECURITY_LANDLOCK`；alpine 静态 binary 需 syscall 兼容回归。

## M19 ✅（已完成）：安全证据补全（4 个 corpus）

> 结果：全绿（host 32 断言 + canary 6 + network 5），并修掉 OCI 路径穿越 2 处、补 DNS rebinding 防线。详见 `m19-security-corpora.md`。

四个 corpus 都是「代码已实现、证据不足」，属于发布门槛。

1. **INV-03 canary 扫描**：在 guest 内注入 canary secret，扫描文件系统、进程内存（`/proc/*/mem` 可读区）、COW 盘、日志、serial 输出、daemon 日志，确认零泄漏；出具扫描报告脚本 + CI job。
2. **INV-04 网络绕过 corpus**：DNS rebinding、30x redirect 到私网、`0.0.0.0`/`169.254.169.254`/IPv6 link-local、DoH/QUIC 旁路、超长响应/流式上限；断言 broker 全拒并留审计。含 guest 内「试图直连」负例（默认无网卡）。
3. **INV-05 文件系统 corpus**：TOCTOU（快照期间替换）、Unicode 归一化（NFC/NFD 同名）、大小写不敏感冲突、macOS ADS/资源分支、超长路径、符号链接链；断言 `buildSnapshot` fail-closed。
4. **INV-06 恶意 layer corpus**：真实 OCI bundle 里 `setuid`、whiteout、绝对/相对逃逸路径、解压炸弹（比例与绝对大小双阈值）、`/proc` 挂载、device node；断言策略层拒收 + 解压限额生效。

- **验收**：每套 corpus 一个 `scripts/security-corpus-*.sh` + 结果 JSON 归档；CI 新增 job；`docs/security/security-verification-matrix.md` 状态从「部分已验证」升级到「已验证（macOS）」。

## M20 ✅（已完成）：生命周期持久化与不复活（INV-10）

> 结果：suspend/resume 真机可用，快照密文 + 三道闸，e2e 15/15；故障注入矩阵 6/6。详见 `m20-lifecycle-persistence.md`。

当前矩阵中 `未实现`。

- **快照**：VZ `saveMachineStateTo`/`restoreMachineStateFrom` 接入 daemon（`suspend`/`resume`）；快照加密（复用 X25519+ChaChaPoly 信封），绑定 manifestDigest + guestAssetVersion + boot nonce。
- **更新与回滚**：release channel 的 `minGuestAssetVersionFloor` 生效路径打通；旧 snapshot 在版本/密钥变更后拒绝恢复。
- **撤销不复活**：revoked key 签的 manifest 既不能新建，也不能从快照恢复出 running。
- **销毁**：`rm`/`shutdown`/daemon 崩溃后的孤儿清理（含快照文件、COW、sock、临时私盘）零残留。
- **验收**：故障注入矩阵（create/boot/handshake/run/suspend/resume/stop/destroy 每阶段 kill) + 「撤销后恢复被拒」+ sweep 归零断言。

## M21 ✅（已完成）：资源统计与观测（INV-08 剩余）

> 结果：guest cgroup → daemon `stats` → CLI/GUI，e2e 7/7。详见 `m21-resource-stats.md`。

- guest 侧采集（cgroup v2 `cpu.stat`/`memory.current`/`io.stat`）→ 加密通道上报 → daemon `stats` 端点 → GUI Stats 面板（每沙箱 CPU%/RSS/IO）与趋势。
- 压力用例：CPU 打满、内存逼近 limit（OOM 在 cgroup 内而非全局）、pids 打满、日志洪泛；断言限额有效且宿主不受影响。
- 产出：`dbx-poc stats <id> --json`、GUI Stats tab、INV-08 证据升级。

## M22：产品化发布 v0.2.0

- **签名与公证**：Developer ID + hardened runtime + `notarytool` 公证 + staple；GUI App 与 dbx-poc 一致流程；`build-gui.sh` 增加 `--notarize` 路径。
- **分发**：DMG（含 .app + CLI 符号链接 + 卸载说明）；Login Item 走 SMAppService 正式注册路径（需要 notarized 签名才能免 `requiresApproval` 反复提示）。
- **更新检查**：`channel.json` 拉取 + 版本比较 + 提示（不做静默自动安装，保持 fail-closed）。
- **发布**：tag `v0.2.0` → CI `repro-check` 双跑一致 → assets + `checksums.txt` + SBOM 附件；`verify-channel` 本地复核。
- **验收**：从 DMG 安装到首次 run 的完整手动 checklist（含 GUI 每个按钮，配合已有 `e2e-gui-buttons.sh`）。

## M23 ✅（已完成）：多凭据域隔离（INV-02）

> 结果见 `m23-credential-domains.md`：域一等化，COW/快照/会话/调度四层跨域拒绝，调度决策证据 0600 落盘。

矩阵中 `未实现`，工作量最大，放最后。

- 凭据域（credential domain）作为一等概念：domain → broker 凭据集 + 出口策略集。
- 调度不变量：不同 domain 的沙箱绝不共享 guest kernel（当前每沙箱独立 VM 已天然满足，需要的是**证明与强制**：domain 标记写进 manifest/快照/CowDisk 元数据，跨域复用 COW base 或快照即拒绝）。
- 验收：属性测试（domain × workspace × grant 组合）+ 跨域攻击报告（尝试用 A 域快照恢复出 B 域沙箱被拒）。

## 3. 常驻工程债（穿插进行，不单独开阶段）

> **2026-11 GUI hotfix（Cmd+Q 无法退出）**：根因有三——① GUI 多处在主线程同步调 daemon socket
> （run/stop/rm/exec/wsSync/shutdown/probing，最长 30s 超时，叠加 daemon 串行 queue 背压后主 runloop
> 卡死，⌘Q 事件无法分发）；② `VZVirtualMachineView.capturesSystemKeys=true` 把 ⌘Q 转发进 guest；
> ③ Quit 被放在 `.appSettings` 菜单槽且无快捷键。修复：全部 socket I/O 移到 global queue +
> 主线程回写；`capturesSystemKeys=false`；显式 `.appTermination` + ⌘Q；顺带修 display 会话私盘
> （512MiB 临时副本）泄漏——stop/退出时删除。daemon 侧的队列背压已由 M24 解决。

- GUI display 窗口交互的**人工视觉验证**（本机无屏幕录制权限，需你手动过一遍并记录）。
- ~~daemon 协议层无单元测试~~ → M24a 已补决策表 + serve 测试（`Tests/DaemonTests`）。
- ~~daemon 单进程串行 queue 背压~~ → M24b 已并发化（每沙箱 opQueue + stateQueue 簿记）。
- ~~既有 e2e 脚本共用用户真实状态、留 `/tmp` 日志、`pkill` 用户 daemon~~ → M25 已隔离化。
- ~~跨进程 `sweep` 删除在途快照临时文件~~ → M27 已解决（属主 PID 判定）。
- 锁屏期间 suspend 的沙箱解锁后能否 resume：未验证（见 `m27-host-robustness.md` §5）。
- ~~suspend 失败后沙箱停在 `suspending`~~ → M28 已回滚到 running。
- `consoleTail` 环形缓冲 128KiB 固定；长时运行沙箱的滚动与落盘策略待定。

## 4. 建议执行顺序与节奏

```
M18（内核纵深） → M19（安全证据） → M21（统计，小） → M20（快照/不复活） → M22（发布 v0.2.0） → M23（多域）
```

理由：M18 与 M19 合起来才能把「已验证安全」这句话说出口；M21 小而甜，能给 GUI 增加可见价值；M20 与 M22 有依赖（快照加密与发布密钥链）；M23 最后。

每阶段仍遵循既有工作模式：先 design 文档 → 实现 → 真机回归（`swift test` + `e2e-sandbox-lifecycle.sh` + `e2e-gui-buttons.sh`）→ conventional commit → push main。
