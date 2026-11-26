# M52：把 M51 的三个缺口补上——GUI 里的 guest 发现、旧 daemon 提示的真机验证、修订号守卫

状态：已完成。没有改 guest，也没有改 daemon 的行为（`BuildRevision.current` 仍是 51）。
关联 `m51-version-skew-doctor.md`。

## 1. 背景

M51 的「诚实边界」里留了三条：

1. GUI 的「daemon 较旧」提示条只有单元测试，应用内自检只走到「修订相同」那一支；
2. guest 资产缺什么只有 CLI（`doctor`）会说，GUI 用户看不到；
3. 修订号是手工维护的，改了 daemon 却忘了加一就看不出偏差。

## 2. 做法

**Stats 面板显示 guest 发现**。GUI 的线上类型 `SandboxStats` 此前不解码能力字段。现在解码，并在 Stats 面板里列出这台沙箱的 guest 资产缺什么（与 `doctor` 共用 `GuestCapabilityReport`；为此把判定的输入从线上类型里拆成 `GuestCapabilities`）。
- 采样软失败（guest 没应答）不下结论，也不推翻上一次的结论——没有能力字段不等于旧 guest；
- 切换沙箱时清空。

**旧 daemon 场景的应用内自检**（`DBX_GUI_SELFTEST_SCENARIO=skew`，`e2e-gui-app.sh` G13）。socket 上放一个按旧 daemon 措辞应答的假服务（`scripts/lib/fake-old-daemon.py`，`e2e-doctor.sh` 也改用它），App 不自动拉起 daemon。验证：
- 主界面的模型给出「daemon 较旧」提示，点名 daemon 崩溃那项修复；
- 两轮定时刷新后提示仍在；这段时间 `info` **只发了 1 次**（假服务记录每个请求）；
- App 没有向这个不是它拉起的 daemon 发 `ps` / `info` 以外的任何请求，退出时也没有 `shutdown`；
- 提示显示时 ⌘Q 正常退出。

**修订号守卫**（`DoctorTests.testRequestKindsArePinnedToTheBuildRevision`）。把「daemon 认识哪些请求」钉在修订号上：请求集合变了而修订号没动，测试失败并说明该改什么。

## 3. 验证

- `swift test` 467 全绿（新增 6）。
- `e2e-gui-app.sh` 76 项（新增 6）：G10 里 Stats 给出的发现与「再次同步是否被挡」的实际表现交叉核对（旧 guest：6 条且含 workspace-receiver、同步被挡；候选：无发现、同步放行）；G13 五项。
- `e2e-doctor.sh` 17 项（改用共享夹具后）。
- 全量 `e2e-all.sh` 与候选上的 GUI 套件：见证据文件与提交说明。

## 4. 诚实边界

- 提示条与 Stats 面板里那一块的**实际渲染**仍然没有测试：自检驱动的是它们绑定的模型字段（`daemonSkewNote`、`guestFindings`），与此前所有 GUI 用例同一层级。
- 「旧 daemon」仍是假服务，不是真正的旧二进制（原因同 M51）。
- 修订号守卫只能发现协议层面的变化（请求种类的增删）。行为变了而请求集合没变——M46 的崩溃修复就是这种——它发现不了，仍然靠人记得加一。
- 本轮新增的断言当时没有做变异检查；「只问一次」那一条已在 M53 补做（去掉守卫后 G13 失败）。
- guest 发现只在 Stats 面板里（要选中沙箱才看到），沙箱列表的行上没有标记。
- 仍未对你正在运行的 daemon（pid 1423）做任何请求。
