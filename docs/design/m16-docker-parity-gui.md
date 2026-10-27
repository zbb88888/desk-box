# M16：Docker Desktop 型 GUI 对齐（仅 macOS）

状态：已完成；关联 `m13-gui-macos.md`、`m12-sandbox-lifecycle-cli.md`、`m14c-gui-display.md`。

## 1. 范围

将 GUI 对照 Docker Desktop 日常 基础功能对齐（仍为 daemon model，不增加 GUI 独有的特权）：

- **Sandboxes 表**（对近现实容器表）：Sandboxes id/state(colored)/uptime/workspace/actions(stop+R estart+rm+terminal+console)；
- **Manifests 表**（对应 Images）：扫描 manifest 所在目录的 `manifest*.json`，显示 fileName/size/digest/Run button；
- **Console 查看器**：沙箱的 serial 控制台尾部涨不（诊断 only）；
- **Restart**：daemon 新端点（stop+rm并用保留参数重建，新 sandboxId）；
- **KPI 顶栏**：running/total、daemon 状态。

## 2. daemon 新增

- `consoleLog { sandboxId, waitMillis:maxBytes }` → `{ outputHex }`（VZSerialConsole ring buffer，任何东西不utis是 attestation）;
- `restart { sandboxId }` → runOptions（SandboxRunOptions）保留 + stop+force rm + 重建。

## 3. 数据字段（响应）

- SandboxInfo 增 uptimeSeconds（可是 ps 计算）。

## 4. 验证

- `dbx-poc console <sandboxId>` / `dbx-poc restart <sandboxId>` CLI；
- GUI sidebar 导航可视；*, console sheet 每 2s 自动拉防；
- swift test + build + e2e lifecycle（PASS=14）。

## 5. 保守边界

- consoleLog 只读，只反映 serial 输出；非attestation。
- restart 产生新 sandboxId（不承诺Docker点ID保持语义）。
- 与 M13/M14c 的单 display session 关系不变。
