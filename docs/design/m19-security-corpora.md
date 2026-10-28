# M19：安全证据 corpus（INV-03/04/05/06）

状态：已完成；关联 `security-verification-matrix.md`、`next-roadmap.md`。

## 1. 目标

四个 corpus 把「代码已实现但缺证据」的不变量推进到「已验证（macOS）」：

| 编号 | 不变量 | corpus | 断言 |
| --- | --- | --- | --- |
| INV-03 | 长期凭据不进 sandbox | canary 扫描 | guest 内 canary 值零出现（文件/日志/serial/COW/daemon 日志） |
| INV-04 | 出站全经宿主策略 | 网络绕过 | allowlist 外/非 HTTPS/超限/DNS rebinding/redirect/明文 HTTP 全拒 |
| INV-05 | 宿主文件只来自显式工作区 | 文件系统 corpus | 越界路径/symlink/大小写/Unicode/超限 全部 fail-closed |
| INV-06 | OCI metadata 不扩权 | 恶意 layer | privileged/mount 越界/非 nobody/DBX_ env/空 argv 全拒 |

## 2. 设计原则

- **每个 corpus 是一个独立可重跑脚本**（`scripts/security-*.sh`），输出机器可读 JSON 到 `docs/security/evidence/`（`--json` 模式），CI 归档。
- **只断言可证伪的事实**：具体 errno / 具体拒绝原因码，不做「大概被拒了」的模糊判定。
- **负例优先**：先证明「该拒的确实拒了」，再证明「该通的通了」（避免过严导致产品不可用）。
- **诚实边界**：内存转储扫描只覆盖 `/proc/*/mem` 可读区与 `smaps` 关键词，不做完整 core dump 取证；这一点写进证据文件。

## 3. corpus 明细

### 3.1 INV-03 canary 扫描（`security-corpus-canary.sh`）

1. 宿主侧生成唯一 canary 值，写入 `guest/broker-credentials.local`（gitignored）作为 broker 凭据；
2. 起沙箱，执行一次经 broker 的出站请求（凭据只在宿主使用）；
3. 扫描面：
   - guest 文件系统：`grep -r` 全根（排除 /proc /sys）；
   - guest 进程环境：`/proc/*/environ` + `/proc/*/cmdline`；
   - guest 日志与 serial 尾部：daemon `consoleLog`；
   - 宿主 daemon 日志文件 `dbxd-gui.log` / stderr；
   - COW 目录（宿主 APFS 上的 sandbox 盘）。
4. 断言：canary 在 guest 侧与日志中**零出现**（宿主 `broker-credentials.local` 自身除外）。

### 3.2 INV-04 网络绕过（`security-corpus-network.sh`）

对允许/拒绝矩阵逐条打点（用宿主 broker 的 HTTP 客户端路径 + guest 内 `brokerreq`）：

| 用例 | 期望 |
| --- | --- |
| allowlist 内 HTTPS | 允许 |
| allowlist 外域名 | 拒绝（`host-not-allowed`） |
| 明文 `http://` | 拒绝（`scheme-not-https`） |
| `127.0.0.1` / `localhost` / `169.254.169.254` / `[::1]` / `0.0.0.0` | 拒绝（`private-or-loopback`） |
| 响应体超限 | 拒绝（`response-too-large`） |
| 30x 跳到私网 | 拒绝（不跟随到非 allowlist） |
| DNS 解析出私网地址（rebinding 模拟） | 拒绝 |
| guest 内直接 connect 公网 | 失败（无网卡） |

### 3.3 INV-05 文件系统 corpus（`security-corpus-fs.sh`）

针对 `WorkspaceSyncService.buildSnapshot` 与 agent 侧路径校验：

| 用例 | 期望 |
| --- | --- |
| `../` 越界 | 拒绝 |
| 绝对路径 | 拒绝 |
| 符号链接（文件/目录/链式） | 拒绝 |
| 大小写冲突（`A.txt` vs `a.txt`） | 拒绝 |
| Unicode NFC/NFD 同名 | 拒绝 |
| 超长文件名（>255 字节） | 拒绝 |
| 文件数/总量/单文件超限 | 拒绝 |
| 正常嵌套目录 | 允许 |

### 3.4 INV-06 恶意 OCI layer（`security-corpus-oci.sh`）

对 `OciPolicyValidator` + guest 运行时：

| 用例 | 期望 |
| --- | --- |
| `privileged: true` | 拒绝 |
| host mount / 越出 workspace 的 mount | 拒绝 |
| `uid != 65534`（含 0） | 拒绝 |
| `cwd` 越出 `/workspace` | 拒绝 |
| env `DBX_*` / `PATH` / `HOME` | 拒绝 |
| 空 argv | 拒绝 |
| 绝对路径 mount source | 拒绝 |
| 解压炸弹（高压缩比 tar 层） | 拒绝（比值阈值） |
| setuid 位二进制 | 拒绝或执行时无提权（断言 euid 仍 65534） |
| whiteout（`.wh.` 前缀） | 拒绝 |

## 4. 验收

- 四个脚本 `PASS/FAIL` 全绿且可重复运行；
- `docs/security/evidence/*.json` 落盘（含时间戳、commit、内核版本）；
- CI 新增 `security-corpus` job（不依赖真机 VZ 的部分进 CI；需 VZ 的部分本地/专用 runner）；
- 安全矩阵对应行升级到「已验证（macOS）」，并注明剩余边界。

## 4.1 实施结果（2026-10-28，Apple Silicon + VZ）

```
[corpus] inv-05-06-inv-04-host ... ok (32 assertions)
[corpus] inv-03-canary ... ok (PASS=6 FAIL=0)
[corpus] inv-04-network ... ok (PASS=5 FAIL=0)
[corpus] 结果：FAIL=0
```

证据 JSON 落在 `docs/security/evidence/<utc>-<commit>.json`；CI 新增 `security-corpus` job（host-only 部分）。

### corpus 抓到的两个真实漏洞（已修）

1. **OCI `cwd` 路径穿越**：`/workspace/../etc` 通过 `hasPrefix("/workspace/")` 检查，实际解析到 `/etc`。现在 `OciPolicyValidator.isUnderWorkspace` 先拒绝任何含 `..` 组件的路径。
2. **OCI `root.path` 绝对路径**：`root.path = "/etc"` 经 `appendingPathComponent` 后落在 bundle 内，绕过了「必须在 bundle 下」的意图。现在绝对路径与含 `..` 的 `root.path` 直接拒绝。

### 顺带补的两处防线（INV-04 缺口）

3. **DNS rebinding**：`BrokerPolicy.decision` 原来只看 host 字符串。新增 `decision(for:resolvedAddresses:)` + `isPrivateOrLoopback(IPv4/IPv6)`；`BrokerService.fetch` 先解析域名再把地址交给策略，任一解析结果为私网/环回/链路本地/未指定即拒绝（含 IPv4-mapped IPv6 与多 A 记录投毒）。
4. **`/sys` 只读授予**：Landlock 白名单补 `/sys`（只读），使 `ls /sys/class/net` 等诊断可用，同时仍不能写。

## 5. 非目标

- 不做完整内存取证（需 root + core dump，超出 sandbox 语义）。
- 不做真 runc 集成（guest 是 busybox 最小根，runc 需要独立阶段）。
