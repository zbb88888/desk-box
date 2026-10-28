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

- GUI display 窗口交互的**人工视觉验证**（本机无屏幕录制权限，需你手动过一遍并记录）。
- `swift test` 中 18 个 suite 的覆盖盲区：daemon 协议层（`SandboxDaemon`）尚无单元测试，只有 e2e；建议补 `Dispatch` 决策表测试。
- daemon 单进程串行 queue 的**背压**：run 期间 30–50s 阻塞整个 queue（hotfix 绕过了 GUI 误判，但 `ps` 也被阻塞）。建议：VM 生命周期操作移出 queue（每沙箱 actor）+ queue 只做状态簿记。
- `consoleTail` 环形缓冲 128KiB 固定；长时运行沙箱的滚动与落盘策略待定。

## 4. 建议执行顺序与节奏

```
M18（内核纵深） → M19（安全证据） → M21（统计，小） → M20（快照/不复活） → M22（发布 v0.2.0） → M23（多域）
```

理由：M18 与 M19 合起来才能把「已验证安全」这句话说出口；M21 小而甜，能给 GUI 增加可见价值；M20 与 M22 有依赖（快照加密与发布密钥链）；M23 最后。

每阶段仍遵循既有工作模式：先 design 文档 → 实现 → 真机回归（`swift test` + `e2e-sandbox-lifecycle.sh` + `e2e-gui-buttons.sh`）→ conventional commit → push main。
