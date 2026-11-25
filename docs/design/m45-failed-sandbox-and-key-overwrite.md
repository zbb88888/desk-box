# M45：失去控制面的沙箱——立刻可见、说得清原因、一步重建；生成密钥不再悄悄覆盖

状态：已完成。本轮**没有改 guest**（候选不需要重建）。
关联 `m43-control-loss-and-broker-result.md`、`m44-evidence-skips-terminal-redraw.md`、`m34-release-cli.md`。

## 0. 范围说明

宿主仍然锁屏，resume 相关的断言仍无法验证（M42 / M43 各留有一处未经 resume 验证的改动）。本轮改动中有一处与 M43 的控制面丢失判定共用同一个条件（见 §4 的第一条），其余不经过 resume。

## 1. 失去控制面的沙箱

M43 让**在途的请求**在 guest 控制进程死掉时立刻失败。但沙箱本身的状态还是老样子：

- 没有请求在途时，`ps` 和界面**一直显示 running**——直到有人发一条请求撞上去，状态才变成 failed；
- 变成 failed 之后再发请求，得到的是 `DBX-BOOT-PROOF-MISSING: authenticated control session required before exec`——与真正的原因毫无关系；
- 界面上 failed 的那一行只有 Console 和 Rm，用户得自己记住当初的参数重新 Run。

现在：

- 控制连接意外断开（判定条件与 M43 相同：当前连接 + running）时**立刻**标为 failed，并在 daemon 日志里记一行；
- `ps` 的应答多一个 `stateDetail`（`DBX-GUEST-CONTROL-LOST: …`）；CLI 的 `ps` 在有内容时把它作为第 6 列打印，前 5 列位置不变；
- exec / stats / 打开终端 / workspace 同步在入口处先检查：控制面已经没了就直接报 `DBX-GUEST-CONTROL-LOST`；
- GUI：failed 的行是红点，悬停显示原因与出路；操作里多了 **Restart**（移除 + 用同样的参数重建，新的 sandbox id，**沙箱内的数据不保留**——说明文字里写明了这一点）。需要 guest 配合的操作（Terminal、Exec、Suspend、Stop……）一个都不给。

## 2. 生成密钥不再覆盖已有的私钥

`gen-guest-sign-key` / `gen-release-key` 此前直接覆盖 `--output-key` 指向的文件。对着现有的签名私钥再跑一次，旧私钥就此丢失——用它签过的 manifest 无法续签，发布链无法用它轮换——而命令没有任何提示。

现在目标已存在时拒绝（exit 2，`DBX-KEY-EXISTS`），文件原样保留；确认不要旧密钥时加 `--force`。符号链接本身（哪怕悬空）也算「存在」。被拒绝的 `gen-release-key` 不会顺带生成 `release-keys.json`。

仓库里调用这两个命令的地方（`build-alpine-guest.sh`、CI、`e2e-distribution.sh`）都是「文件不存在才生成」或写到全新的目录，不受影响。

## 3. 验证

单元测试（`swift test` 427 全绿，新增 7，改 1）：`SandboxRowActionsTests`（failed 的操作集、状态说明、`stateDetail` 的解码兼容）、`PrivateKeyOverwriteTests`（判定、被拒绝时旧文件与目录原样、`--force`、悬空符号链接、CLI 规格）。

真机——**旧 guest**（只有它能被 workload 杀掉控制面；`e2e-broker-exec.sh` 的旧 guest 分支，11 项，新增 6）：

| 断言 | 结果 |
| --- | --- |
| 控制面一死，不发任何后续请求，`ps` 在 1.5s 内显示 failed | 通过 |
| `ps` 带上原因（`DBX-GUEST-CONTROL-LOST`） | 通过 |
| 随后的 exec / 同步 / 打开终端：立刻失败，原因是 `DBX-GUEST-CONTROL-LOST`（此前是 `DBX-BOOT-PROOF-MISSING`） | 通过（exec 135ms） |
| `restart`：failed 的沙箱被移除，同样的参数重建出一台 running 的新沙箱，并且能正常 exec | 通过 |

`e2e-release-cli.sh`（56 项，新增 3、改 1）：两个命令都拒绝覆盖（exit 2、`DBX-KEY-EXISTS`、内容与权限都没动）；被拒绝时不生成 `release-keys.json`；`--force` 覆盖并把旧的 0644 收紧为 0600。

全量 `e2e-all.sh`（本机现有旧 guest）：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏 9 项；环境缺失 0 项）。
全量 `e2e-all.sh`（候选）：25 个套件 0 失败，卫生四项 clean，退出码 3（锁屏 9 项；环境缺失 0 项）。

## 4. 诚实边界

- **「立刻标为 failed」与 M43 的判定共用同一个条件**：如果那个条件在 resume 时会误判，M43 之后的第一条请求就已经会失败；本轮没有引入新的误判来源，但把后果从「下一条请求失败」提前成了「状态立刻变为 failed」，而 failed 不可逆。resume 仍未在真机上验证——解锁后的那次全量 E2E 现在同时检验 M42、M43、M45 三处。
- 新 guest 上不可信程序已经杀不掉控制进程，所以「立刻 failed / ps 带原因 / restart」只在旧 guest 上有真机证据；候选上这几条路径不会被触发。
- GUI 的红点、悬停说明、Restart 入口只有单元测试（操作集与文案是纯函数）；没有在界面上实际制造一台 failed 的沙箱来点它。daemon 侧 `restart` 对 failed 沙箱的行为是真机验证过的。
- Restart 不保留沙箱内的数据；failed 的沙箱的磁盘在 `rm` 时随之销毁。没有做「先把盘留下来」的选项。
- `--force` 之后旧私钥无法找回；没有做自动备份。
- 宿主锁屏：依赖 resume 的 9 项断言仍未验证。
