# M36：E2E 证据化与安全验证矩阵同步

状态：已完成。当前证据的结论是**不完整**（宿主锁屏，9 项断言未验证）——这正是本阶段要让它可见、可追溯的东西。
关联 `../security/security-verification-matrix.md` §1 / §2.1 / §5 / §6、`m25-e2e-isolation.md`。

## 1. 问题

安全验证矩阵对证据有明确要求（§5：commit、OS 版本、执行入口、退出码、清理与孤儿检查），并规定「任何关键控制变更都会使关联证据过期」（§1）。但：

- `e2e-all.sh` 的结果只打印在终端。连续多轮「因锁屏有若干断言未验证」这个状态，只存在于对话记录里。
- 矩阵上次更新停在 M23。此后 M24–M35 改动了大量关键控制，并修复了数个直接关系到 INV-10 / INV-03 / INV-08 的问题，矩阵里「M20 已验证」之类的结论描述的已经不是当前代码。

## 2. 设计

### 2.1 证据文件（`deskbox-e2e-evidence/v1`）

`E2E_EVIDENCE_DIR=<目录> ./scripts/e2e-all.sh` 在运行结束时写出一份 JSON：

- `commit`、`commitDirty` / `dirtyFiles`、`partial`（是否只跑了部分套件）；
- `host`：macOS 版本、build、机型、架构；`hostSessionLocked`（开始 / 结束时）；
- `binarySha256`、`guestManifestSha256`；
- `suites[]`：名字、脚本、它支撑的不变量、退出码、PASS/FAIL/SKIP 计数、耗时，以及 **`lockSkipped`——逐条列出没有被验证的断言**；
- `hygiene`：四项卫生审计的结果；
- 派生字段 `verdict`、`invariants`、`releaseBlockers`（便于直接阅读；校验时会由明细重新计算并比对）。

每个套件在 `e2e-all.sh` 的 `SUITES` 表里声明它为哪些不变量提供证据。

### 2.2 结论规则（`scripts/e2e-evidence.py`）

| 层级 | 规则 |
| --- | --- |
| 套件 | 退出码非 0 或 FAIL>0 → 失败；有 `lockSkipped` → 不完整；否则通过 |
| 不变量 | 取其全部相关套件里最糟的状态；没有相关套件 → 未覆盖 |
| 整次运行 | 任一套件失败或卫生审计不干净 → `failed`；否则有跳过 → `incomplete`；否则 `complete` |
| 能否作为发布证据 | `complete`，且工作区干净、不是部分运行、至少有一个套件 |

`check` 的退出码：0 可作为发布证据 / 3 无失败但不完整 / 1 失败或证据无效。记录的 `verdict` 若与明细不符（被手改），判为无效。

归属是**套件级**的：一个套件里只要有断言被跳过，它支撑的所有不变量都记为不完整，即使被跳过的断言与其中某个不变量无关。这会多报，不会少报。

### 2.3 矩阵同步

`security-verification-matrix.md` 新增 §2.1：表格是 `summarize --markdown` 的原样输出（不是手写结论），附重新生成的方法、读法，以及自 M23 以来影响证据的变更清单。§2 的历史结论保留原文。

## 3. 验证

- `e2e-harness-selftest.sh` 新增 14 个合成证据用例：通过 / 不完整 / 失败 / 同一不变量取最糟 / 退出码 0 但有 FAIL 计数 / 卫生不干净 / 工作区有未提交改动 / 部分运行 / 空套件 / 不提供证据的套件失败 / **手改的 verdict 被判无效** / 未知不变量 / schema 不符 / markdown 输出。自测共 47 项。
- 真实运行：先提交工具（commit `8213149`），再在干净工作区生成证据
  `docs/security/evidence/e2e-20261124T161558Z-8213149.json`：16 个套件 0 失败、卫生四项 clean、`verdict = incomplete`、`check` 退出码 3。
- `swift test` 355 全绿（本阶段没有改动 Swift 代码）。

## 4. 当前证据说了什么

| 不变量 | e2e 结果 |
| --- | --- |
| INV-01、INV-04、INV-06、INV-09 | 通过 |
| INV-02、INV-03、INV-08、INV-10 | 不完整（共 9 项依赖 resume 的断言因宿主锁屏未验证） |
| INV-05、INV-07 | `e2e-all.sh` 未覆盖（证据来自 `swift test` 与 `security-corpus.sh`） |

按矩阵 §6，在得到一份 `check` 退出码为 0 的证据之前，INV-02 / INV-03 / INV-08 / INV-10 应按 `已实现待验证` 对待。

## 5. 诚实边界

- 这份证据**不是**矩阵意义上的「已验证」：单平台、没有独立评估、没有签名或防篡改存储（§5 要求「签名或存入不可静默覆盖的 CI artifact」；这里只是仓库里的一个 JSON，`check` 能发现结论与明细不一致，但发现不了明细本身被改）。
- 套件 → 不变量的映射是我按各套件实际断言的内容标注的，没有逐条断言级别的追踪；INV-07 没有专门的 e2e 套件（每个套件都依赖已认证的控制通道才能跑通，但那不是针对性的证据）。
- 「不完整」目前只有一个来源（宿主锁屏）。其它原因的跳过（例如缺少 GPU 内核时 Display 场景被跳过）不会进入 `lockSkipped`，因而不会让结论变成不完整。
- 证据文件每次运行新增一个，不会自动清理旧文件。
- **要得到一份完整的证据**：解锁后在干净的工作区执行 `cd macos && E2E_EVIDENCE_DIR=../docs/security/evidence ./scripts/e2e-all.sh`，然后用新文件更新矩阵 §2.1。
