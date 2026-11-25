# M49：ThreadSanitizer 覆盖到全部真机套件、GUI 进程与单元测试；accept 循环不再空转

状态：已完成。本轮**没有改 guest**（候选不需要重建）。
关联 `m48-runtime-serialization-and-tsan.md`。

## 1. TSan 的覆盖面

M48 只在 7 个真机套件上跑了 TSan，诚实边界里列着没覆盖的部分。本轮补齐：

| 范围 | 结果 |
| --- | --- |
| 真机套件：新增 workspace 同步、broker、exec 输出、凭据域、CLI 与实例锁、状态权限、资源统计、故障注入、GUI 按钮（daemon 侧）——连同 M48 的 7 个共 16 个 | 竞争报告 0 |
| 其中 workspace 同步 / broker / exec 输出 / exec 取消另在**候选 guest** 上各跑一遍（流式输出、真实下载、取消这些只有新 guest 才走到的路径） | 竞争报告 0 |
| **GUI 进程本身**（`e2e-gui-app.sh` 新增 `E2E_GUI_PREBUILT`，换上 TSan 构建的 GUI；它拉起的 daemon 同样是 TSan 构建） | 竞争报告 0（确认过 TSan 运行时在全部 43 个进程里都处于激活状态） |
| **单元测试**（`swift test --sanitize=thread`，433 个用例） | 竞争报告 0——但暴露了 §2 的问题 |

套件自身在 TSan 下的失败全部是时间阈值（逐项看过）。`scripts/tsan-e2e.sh` 现在缺省先跑单元测试，再跑 17 个真机套件（含 GUI）。

## 2. 单元测试在 TSan 下偶发失败——一次错误的诊断，和真正的原因

TSan 下的全量单元测试大约每 3–5 遍失败一次，失败的总是「shutdown 之后 serveLoop 没有返回」这一类（不同用例）。

**我的第一个诊断是错的。** 采样显示 serveLoop 阻塞在 `accept()` 上，而负责唤醒它的处理线程已经结束。我由此推断「唤醒连接连上就关，被内核在 accept 之前丢弃了」，并据此把 accept 循环改成了 poll + 轮询停机标志。但：400 轮「启动 → 停机」的压力测试一次也没丢过唤醒；改完之后偶发失败**仍然出现**。那个推断没有证据，「BSD 内核会丢弃」是我的猜测。

**真正的原因在测试里**（`DaemonInstanceGuardTests.testLiveListenerWithoutLockIsRespected`，M27 时我写的）：同一个描述符先有 `defer { close(fd) }`，后面又显式 `close(fd)`，然后才启动一个新的 daemon。显式关闭之后，新 daemon 的某个描述符（实例锁或**监听 socket**）会复用这个编号；方法结束时 `defer` 再关一次——关掉的是那个 daemon 的描述符。接下来：

- 那个 daemon 的 accept 循环拿着一个失效的编号空转（`accept` 立刻失败 → `continue`）；
- 这个编号随后被**后面用例**的 daemon 的监听 socket 复用，于是那个「僵尸」循环开始和后面用例的 daemon **抢同一个监听 socket 上的连接**——shutdown 请求被僵尸收走并应答成功，真正的 daemon 从没见过它。

第二次采样（改成 poll 之后）看到的正是那个空转的循环，才把线索指回描述符。修掉重复 close 之后：TSan 下全量单元测试连跑 **10 遍 0 失败**（此前约 20–30% 的运行失败）；普通构建下那个测试类从 12.8 秒降到 2.8 秒——它一直在悄悄多等一个 10 秒的超时，只是没有变红。

## 3. 产品侧的改动（accept 循环）

重复 close 是测试的 bug，但它暴露了 daemon 的两个弱点，值得修：

- **监听 socket 失效时以 100% CPU 空转**：`accept` 失败就 `continue`，没有任何出路——既不服务也不退出，还占着实例锁。现在失效的监听 socket（`POLLNVAL`、`EBADF`、`ENOTSOCK`……）是致命错误：记日志、退出循环。描述符耗尽之类的暂时性失败退避 50ms。判定是纯函数（`AcceptLoopPolicy`）。
- **停机依赖一条唤醒连接**：现在循环用 poll（250ms）等待，每轮检查停机标志；唤醒连接保留，只为退出快一点。
- serveLoop 退出时关闭监听 socket 之前先确认它还是个 socket（如果它已经被别处关掉，再关一次会重蹈 §2 的覆辙）。
- 监听 socket 改为非阻塞后，accept 出来的连接要显式改回阻塞（macOS 会继承这个标志），否则发请求稍慢的客户端会被当成「没有数据」断开——有专门的测试。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `swift test` | 433/433（新增 5：`AcceptLoopPolicyTests` 3、停机不依赖唤醒连接、慢客户端在非阻塞监听下仍得到应答） |
| 监听描述符被关掉后 daemon 是否停下来（真实 daemon、真实 close） | 3 秒内退出；旧实现会一直空转 |
| 变异：让 poll 永久阻塞（等价于旧的 accept） | 「停机不依赖唤醒连接」失败；源码已还原 |
| `swift test --sanitize=thread` 连跑 10 遍 | 0 竞争报告、0 失败 |
| `scripts/tsan-e2e.sh`（单元测试 + 17 个真机套件含 GUI） | 竞争报告 0 |
| 全量 `e2e-all.sh`（本机现有 guest，屏幕解锁） | 27 个套件 0 失败，卫生五项 clean，退出码 0（完整通过） |
| 全量 `e2e-all.sh`（候选，屏幕解锁） | 27 个套件 0 失败，卫生五项 clean，退出码 0 |

## 5. 诚实边界

- §2 里那次错误的诊断在代码里留下的痕迹已经改掉：accept 循环的注释现在只陈述两个确实存在的弱点，不再声称「唤醒连接会被内核丢弃」。poll 循环作为健壮性改进保留，但它**不是**那次偶发失败的修复。
- 「连接在 accept 之前被对端关闭」在 macOS 的 unix socket 上到底会不会被丢弃，我没有查证；现在的实现不依赖这个问题的答案。
- 退出时「确认还是个 socket 再关」挡不住「编号已被别人的 socket 复用」的情况；根本的办法是任何地方都不重复 close，本轮只修了发现的那一处，并没有系统地审计所有测试代码里的 `defer close` + 显式 `close` 组合（产品代码里搜过，没有）。
- TSan 的「0 报告」覆盖的是这些套件与用例走到的路径。GUI 的 Display（进程内 VM）路径在 GUI 套件里走到了；真实点击、菜单栏弹窗没有。
- 候选没有在 TSan 下跑全部套件，只跑了 4 个与新 guest 行为相关的。
- `tsan-e2e.sh` 仍然没有接进 `e2e-all.sh`（单元测试 + 17 个套件一遍约 25 分钟）。
- **本机 `macos/guest/` 与 `gui/dist/DeskBox.app` 仍是旧资产 / 旧构建。**
