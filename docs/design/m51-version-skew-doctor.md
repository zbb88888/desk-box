# M51：版本偏差可见化——`dbx-poc doctor`、daemon `info`、GUI 提示条

状态：已完成。没有改 guest（候选不需要重建）。
关联 `m37`–`m46`（guest 侧的各项修复与它们上报的能力字段）、`m45-failed-sandbox-and-key-overwrite.md`。

## 1. 问题

这个项目里同时在跑的有三层：客户端（CLI / GUI）、常驻的 daemon、每台沙箱里的 guest 资产。daemon 可以连续运行几个星期；guest 资产要显式重建。它们落后于代码时，缺的可能是崩溃修复或隔离修复——而此前**没有任何界面会告诉你**。

过去十几轮里，我在每份报告末尾都写着同一段话：「本机的 guest 资产还是旧的」「你正在运行的 daemon 是 10 月的构建，某某修复在它上面不存在」。这类信息应该由产品自己说出来。

## 2. 做法

**daemon：`info` 请求**——返回构建修订号（`BuildRevision.current`，取里程碑编号，每个改动 daemon 行为的里程碑加一）、pid、启动时间、沙箱数。旧 daemon 不认识这个请求，会以固定措辞拒绝（`unknown kind=info`）；客户端据此判断「它比 M51 还旧」。

**guest：不需要新协议**——M37 起每项 guest 侧修复都在 stats 应答里加了一个能力字段（`workspaceSyncVersion`、`execOutputVersion`、`execCancelVersion`、`brokerVersion`、`childFdsVersion`）。`GuestCapabilityReport` 把它们翻译成「这套 guest 缺什么」，分四类：isolation（沙箱里的程序可借此破坏隔离或让沙箱失去响应）、reliability、feature、testOnly（带故障注入的测试夹具）。

**`dbx-poc doctor [--json] [--strict]`**：

```
client     修订 51
daemon     不认识版本查询（早于修订 51）
  ! 正在运行的 daemon 比这个客户端旧（…）。新的修复要重启 daemon 才生效——重启会结束它名下的所有沙箱。
    - 缺少的修复：终端大量输出时 daemon 可能崩溃，名下所有沙箱一起丢失
    - …
sandbox    7DAC0849-…  running
  ! [isolation] 沙箱里的程序的 stdin 就是控制通道：…（M46）
  ! [reliability] exec 的输出被截到 1023 字节；…（M39）
  …
```

缺省只报告（退出码 0）；`--strict` 在 daemon 较旧、或任一沙箱的 guest 有 isolation / reliability 问题时以 3 退出，供脚本使用；daemon 连不上是 2。只对 running 的沙箱查询 guest 能力。

**GUI**：连上 daemon 后问一次 `info`（每次连接只问一次——旧 daemon 会为每个不认识的请求记一行日志，不能每 3 秒问一遍）。修订不一致时在主界面顶部显示一条提示，说明哪边旧、点名最近几项缺少的修复，以及重启 daemon 的代价。

## 3. 验证

单元测试（`swift test` 461 全绿，新增 19）：`VersionSkewTests`（偏差判定、提示文字、缺少的修复随 daemon 修订变化、旧 daemon 措辞的识别、旧 / 当前 / 中间版本 / 测试夹具四类 guest 的发现）、`DoctorTests`（当前 daemon 与 guest；拒绝 `info` 的旧 daemon；旧 guest 与 stats 软失败；其它错误不被误判为旧 daemon；JSON 往返与 CLI 规格；**真实 daemon 应答 `info`**）、`DaemonSkewNoteTests`（GUI 提示的五种情况）。

真机 `scripts/e2e-doctor.sh`（17 项）：

| 场景 | 结果 |
| --- | --- |
| 当前 daemon、没有沙箱 | 同一修订；`--strict` 退出码 0 |
| 旧 guest 的沙箱（本机现有资产） | 列出 6 条：3 项隔离、输出截断、brokerreq 结果、不支持取消；给出处理办法；缺省 0，`--strict` 3 |
| 补丁版 guest（当前源码） | 没有任何发现 |
| `--json` | 可解析，与文本一致 |
| 旧 daemon（一个按旧 daemon 措辞应答的假服务） | 报告它较旧，列出 6 条缺少的修复（含 daemon 崩溃那条），说明重启的代价；`--strict` 3 |
| daemon 连不上 / 不认识的选项 | 退出码 2，没有任何「ok」 |

GUI 应用内自检（`e2e-gui-app.sh` 新增 1 项）：App 查到了它拉起的 daemon 的修订号，与自己相同，没有提示条。

候选 guest 上的 `e2e-doctor.sh`（走「guest 是新资产」那一支）：正式构建的候选没有任何发现，`--strict` 退出码 0。

全量 `e2e-all.sh`（本机现有 guest，屏幕解锁）：28 个套件 0 失败，卫生五项 clean，退出码 0（完整通过）。

## 4. 诚实边界

- **我没有对你正在运行的那个 daemon（pid 1423）跑 `doctor`。** 它是 10 月的构建，带着 M46 修掉的那个数据竞争；多一个并发请求会略微增加它崩溃的机会，而它崩溃会带走你的沙箱。你可以自己决定要不要跑：`macos/.build/release/dbx-poc doctor`。按现有信息，预期输出是「daemon 不认识版本查询」加上各沙箱的 6 条 guest 发现。
- 「旧 daemon」的 E2E 用的是一个假服务（只会应答 `ps`、对其它请求用旧 daemon 的拒绝措辞）。措辞取自旧代码的 `unknown kind=\(kind)`；没有用真正的旧二进制验证（旧二进制不认识 `DBX_SUPPORT_ROOT`，会去动你的真实状态目录）。
- GUI 的「daemon 较旧」提示条只有单元测试（判定与文案）；应用内自检只走到了「修订相同、没有提示条」这一支。提示条的实际渲染没有测试。
- 修订号是手工维护的一个整数：以后的里程碑如果改了 daemon 的行为却忘了加一，偏差就看不出来。「值得点名的修复」列表同样是手工维护的。
- guest 的发现完全依赖 guest 自己上报的能力字段——一个撒谎的 guest 可以声称自己什么都不缺。它不是安全判定，只是给用户的提示；宿主侧真正的闸门（例如 M37 的再次同步限制）不依赖这份报告。
- `doctor` 不检查 App bundle 里自带的 guest 资产，也不检查磁盘上的资产是否比正在运行的沙箱新；它只看「正在运行的」。
- suspended / failed 的沙箱不查询 guest 能力。
