# M25：E2E 隔离化与卫生审计

状态：已完成；关联 `m24-daemon-concurrency.md` §5、`next-roadmap.md`。

## 1. 问题

M12–M23 的真机 e2e 脚本都直接使用用户的真实状态：

- 默认 cow-root / `snapshot.key` / `scheduler-decisions.jsonl` 都在 `~/Library/Application Support/DeskBox`；
- `e2e-credential-domains.sh` 改写真实 `domains.json`，并 `pkill -f 'dbx-poc daemo'`（会杀掉用户正在用的 GUI daemon）；
- `e2e-gui-buttons.sh` 默认对着用户的 daemon 跑，最后把它 `shutdown`；
- daemon 日志、中间文件散落在 `/tmp`，`e2e-fault-injection.sh` 没有 trap（中断即留下 daemon）。

结果是：有用户 daemon 在跑时部分套件不能安全运行，且每次回归都要手工清理。

## 2. 设计

### 2.1 `DBX_SUPPORT_ROOT`（`Sources/DeskBoxVZ/DeskBoxPaths.swift`）

宿主侧状态根目录的**唯一解析点**：`supportRoot` / `cowRoot` / `snapshotKeyURL` / `daemonSocketURL`。原先散落在 7 处的 `applicationSupportDirectory` 全部收口。

- 未设置（或空串）→ 默认目录，行为不变；
- 设置 → 必须是绝对路径、不含 `..`、若已存在必须是目录；**非法即 `exit 2`**，不静默回落默认目录（否则「以为在隔离目录、其实在动真实状态」）；
- 不是提权面：能设置 daemon 环境变量的主体本来就能以同一用户身份直接读写这些文件。GUI 不读取该变量。

### 2.2 公共 harness（`scripts/lib/e2e-common.sh`）

`e2e_init <tag>` 建 `mktemp -d /tmp/dbx-<tag>.XXXXXX`，其下：`support/`（= `DBX_SUPPORT_ROOT`）、`d.sock`、日志与全部中间文件。`EXIT/INT/TERM` 统一走 `e2e_cleanup`：

1. 对登记过的 socket 逐个 `shutdown`，等登记过的 PID 退出，超时 `kill -9`（**只杀自己登记的 PID，不 pkill**）；
2. 回收后台 job；调用可选钩子 `e2e_extra_cleanup`（还原目录外状态，如 canary 用例改写的仓库内凭据文件）；
3. 失败时打印各日志尾部；删除目录；
4. **自检**：目录仍在或仍有进程引用它 → 以退出码 97 失败（即便用例全过）。

`E2E_KEEP=1` 保留现场；`E2E_SKIP_BUILD=1` 复用已构建的二进制。

### 2.3 套件改造

10 个脚本全部迁到 harness（M26 新增的 `e2e-boot-and-cancel` 同样基于它）：`e2e-sandbox-lifecycle` / `e2e-daemon-concurrency` / `e2e-lifecycle-persistence` / `e2e-fault-injection` / `e2e-resource-stats` / `e2e-kernel-hardening` / `e2e-credential-domains` / `e2e-gui-buttons` / `security-corpus-canary` / `security-corpus-network`。

顺带收紧的断言：

- fault-injection：首轮 sweep 必须**正好发现 1 个**孤儿（0 意味着用例失效而不是「干净」），并新增 cow-root 全量残留检查（clone / 域标记 / 快照）；
- canary：新增两条对照——被扫描的 cow-root 里确实有本沙箱的盘、daemon 日志非空（否则「无 canary」是空扫）；扫描范围扩大到整个隔离 support-root；
- lifecycle：shutdown 后断言 daemon 退出、socket 清除、cow-root 零残留（替代原来的 `sleep 2`）。

行为变化（需要知道）：

- `e2e-gui-buttons.sh` 默认改为对**私有** daemon 跑，「GUI 进程在」变成 SKIP。旧行为需显式 `E2E_GUI_LIVE=1`（会停掉用户的 daemon）。
- `security-corpus.sh` 支持 `EVIDENCE_DIR` 覆盖；不再把子套件日志拷到 `/tmp/corpus-*.log`。
- 各脚本不再接受外部 `SOCK=`（复用已有 daemon 的用法取消：隔离与复用互斥）。

### 2.4 总入口与卫生审计（`scripts/e2e-all.sh`）

构建签名一次 → 逐个跑套件 → 对比运行前后的：用户状态目录（文件清单 + 大小 + mtime）、`/tmp` 项目相关条目、`dbx-poc` 进程集合。任何差异都使整轮失败。

## 3. 验证

```
[all] selftest               ok   PASS=27 FAIL=0
[all] m12-lifecycle          ok   PASS=20 FAIL=0
[all] m24-concurrency        ok   PASS=34 FAIL=0
[all] m20-persistence        ok   PASS=16 FAIL=0
[all] m20b-fault-injection   ok   PASS=6  FAIL=0
[all] m21-stats              ok   PASS=7  FAIL=0
[all] m18-kernel             ok   PASS=12 FAIL=0
[all] m23-domains            ok   PASS=21 FAIL=0      ← 首次在并发 daemon（M24）上复验
[all] m17-gui-buttons        ok   PASS=13 FAIL=0 SKIP=1
[all] m19-canary             ok   PASS=6  FAIL=0
[all] m19-network            ok   PASS=5  FAIL=0
[all] hygiene 用户状态目录 / /tmp / 进程集合   clean ×3
```

全程有一个用户 GUI daemon 在运行，未受影响。

- **harness 自测**（`e2e-harness-selftest.sh`，27 项，不起 VM）：正常结束 / 中途 `exit 3` / SIGTERM / SIGINT / daemon 先被 `kill -9` / 钩子还原 / `E2E_KEEP` / 隔离生效（CLI 默认 socket 跟随覆盖）/ 非法覆盖值 `exit 2`。
- **变异检查**：把 cleanup 里的 `rm -rf` 去掉 → 自测失败（含 harness 自身的 97）。去掉「停 daemon」一段 → 自测仍通过，因为后台 job 回收与「引用临时目录的进程」自检两道兜底仍会杀掉 daemon（结果等价，不是漏洞）。
- **审计负例**：运行期间在 `/tmp` 植入一个 `dbx-*` 文件 → `e2e-all.sh` 报 DIRTY 并以非零退出。
- 单元测试：`DeskBoxPathsTests` 5 个；`swift test` 共 183 个全绿。

## 4. 诚实边界

- 信号清理要等当前前台命令返回（shell 语义）：`run` 引导期间 Ctrl-C，清理最多延后到该次 `run` 结束。
- `kill -9` 测试脚本本身无法清理（任何 trap 都拦不住）；残留目录形如 `/tmp/dbx-<tag>.*`，可整体删除。
- 卫生审计只看本项目相关的 `/tmp` 名字模式，且用户在审计期间使用 GUI 会被报告为差异（如实报告，需人工判断）。
- `e2e-distribution.sh` 未纳入（打包/DMG，自带临时目录，耗时长）；`E2E_GUI_LIVE=1` 模式本轮未运行（需要打开 GUI）。
- CI 仍只跑 `swift test` 与 `security-corpus.sh --host-only`；真机套件需要 VZ entitlement，不在 CI 上跑。
