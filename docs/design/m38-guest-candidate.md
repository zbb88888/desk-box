# M38：正式构建的 guest 候选——验证、安装与回滚

状态：候选已用正式构建脚本构建并通过全量回归；**尚未安装到 `macos/guest/`**（这一步留给你，一条命令，可回滚）。
关联 `m37-workspace-sync-boundary.md`（修复本身）、`m10-reproducible-build.md`。

## 1. 起因

M37 把 guest 的 workspace 接收端修好了，但留下两个缺口：

1. 修复只在「补丁版 guest」上验证过——那是用本机交叉编译器做的测试夹具，编译器和 libsodium 都与正式构建不同；
2. 本机 `macos/guest/` 仍是旧资产，靠宿主闸门（`DBX-WS-RESYNC-UNSAFE`）挡着。

当时卡在本机访问不了 Docker Hub。本轮它恢复可达，于是把这两个缺口关上——但**不直接覆盖** `macos/guest/`：`build-alpine-guest.sh ./guest` 是「边构建边覆盖」，中途失败会留下半新半旧的目录，而且装进去的字节没有被验证过。

## 2. 做法：候选 → 验证 → 安装

```
./scripts/build-alpine-guest.sh ./guest-candidate        # 正式构建脚本，输出到候选目录（约 12 分钟）
MANIFEST=$PWD/guest-candidate/manifest.json ./scripts/e2e-all.sh          # 全量回归跑在候选上
./scripts/install-guest-candidate.sh ./guest-candidate   # 把验证过的那些字节装进 ./guest（带备份）
./scripts/install-guest-candidate.sh --rollback ./guest/.backup-<时间>    # 反悔
```

`install-guest-candidate.sh`：

- 先校验候选（签名 + 全部文件摘要），不通过则什么都不改；
- 旧文件**移动**到 `guest/.backup-<UTC>/`（同卷 rename，不额外占空间），新文件「拷到临时名 → rename」换入；
- guest 目录里有 GPU 内核时，用同一把开发密钥重新生成 `manifest-gpu.json`（它引用的 initrd / root 盘摘要变了——直接覆盖式重建会让它悄悄失效）；
- 装完再校验一遍；任何一步失败（含 Ctrl-C）自动回滚；
- 不碰密钥、`release-keys.json`、GPU 内核、`cows/` 和其它不认识的文件；不停止也不重启任何 daemon。

## 3. 验证

**候选本身**（正式构建：Alpine 容器里的 gcc + libsodium-static，开发密钥签名）：

| 检查 | 结果 |
| --- | --- |
| guest 上报 `workspaceSyncVersion` | 2 |
| `e2e-workspace-sync.sh`（`EXPECT_RECEIVER_VERSION=2`） | 58 通过 |
| `e2e-all.sh` 全部套件以候选为 guest | 0 失败，卫生四项 clean，退出码 3（锁屏，9 项跳过） |
| 含 GUI 的 Open Display（GPU 内核 + 候选的 initrd / root 盘） | 通过 |

也就是说，M37 的 guest 侧修复现在在**正式构建产物**上得到了验证，旧 guest 能跑的东西候选都能跑。

**新增的并发用例 W11**（M37 记录的未覆盖项）：workload 在终端里不停地把目标文件和中间目录在「真实对象」与「指向 `/etc` 的符号链接」之间切换（同步期间跑了约 1.2 万轮），同时宿主连续同步 40 次。`/etc` 下始终没有被写入；其中若干次同步因撞上符号链接被拒（证明竞争确实发生了）；之后 guest 仍然响应。在补丁版、候选两种 guest 上都通过。

**安装脚本** `scripts/e2e-guest-install.sh`（无 VM，合成资产，21 项）：正常安装后 7 个资产与候选逐字节一致、不该碰的文件没被碰、两个 manifest 都通过校验；回滚后目录逐字节回到安装前；候选被篡改 / 未签名 / 缺文件时拒绝且目录完全没动；安装中途失败自动回滚；`--rollback` 只接受 `<guest>/.backup-*`。变异检查：去掉失败时的恢复 → 3 项失败。

**真实尺寸演练**：把候选装进 `macos/guest` 的一份 APFS 克隆（不是真实目录），从克隆启动 VM 跑 workspace 套件（58 通过），`manifest-gpu.json` 通过校验，再回滚，四个关键文件与原件逐字节一致。

## 4. 顺手修的

- `build-alpine-guest.sh` 把开发私钥拷进输出目录时用的是默认权限（0644）；输出目录在 `/tmp` 时等于把私钥放在他人可读的地方。改为 0600。
- **`security-corpus-canary.sh` 会往真实的 `guest/` 目录里写文件**（上一轮注意到 `guest/` 的修改时间在全量 E2E 后变了，本轮查清）：它把 canary 凭据写到「manifest 所在目录」再恢复，中途被 SIGKILL 就会留下，而且那个目录可能正被你自己的 daemon 使用。现在它把 manifest 和资产克隆到本次运行的临时目录再注入；全量 E2E 前后 `guest/` 的修改时间不再变化。卫生审计此前没有覆盖 `guest/` 目录，所以没报。
- `e2e-harness-selftest.sh` 的一项检查偶发失败（M36 引入）：它取「临时目录里第一个 `ev-$RANDOM.json`」做 markdown 检查，偶尔拿到故意弄坏的那份。本轮全量 E2E 撞上一次。改为使用一份明确的未改动证据。
- `e2e-guest-install.sh` 用 `e2e_build_sign` 而不是裸的 `swift build`：重新链接会丢掉代码签名，之后带 `E2E_SKIP_BUILD=1` 跑的 VM 套件会因缺 entitlement 失败（本轮自己踩到了）。`e2e-release-cli.sh` 仍有同样的隐患（它要在没有 guest 资产的 CI 上跑，不能直接换），单独运行它之后请不要带 `E2E_SKIP_BUILD=1`。

## 5. 诚实边界

- **`macos/guest/` 还没有换。** 候选放在 `macos/guest-candidate/`（已加入 .gitignore，约 205MB 实际占用）。在你安装之前，本机行为与 M37 结束时相同：旧 guest + 宿主闸门。
- 候选是**开发资产**：上游输入（Debian 内核 / initrd、Alpine minirootfs）没有固定摘要，签名用的是本机开发密钥。这与此前的 `macos/guest/` 性质相同，不是发布级供应链。
- 候选的内核与本机旧资产的内核不是同一次下载（Debian 的 netboot 镜像会更新）；全量回归在候选上通过，但没有逐项比较两个内核的差异。
- 安装脚本「不重启 daemon」意味着：你正在运行的 GUI daemon 里已有的沙箱继续用旧字节；它之后新建的沙箱读到的是新资产。App bundle（`gui/dist/DeskBox.app`）里如果自带一份 guest 资产，那一份不会被更新——没有检查过它是否自带。
- 安装不是跨文件原子的：两个文件的 rename 之间有一个极短的窗口，此时目录里是新旧混合；这时启动沙箱会因摘要不符被拒绝（fail-closed），不会带着错的资产启动。没有测试这个窗口。
- W11 的竞争是「尽力而为」的：40 次同步里只有一部分撞上符号链接状态；它不能证明没有更窄的窗口，安全性的依据仍是逐级 `O_NOFOLLOW` 的设计。
- 候选是在 `build-alpine-guest.sh` 的私钥权限修改**之前**构建的，它的 SBOM 记录的是当时那份构建脚本的摘要；产物字节不受那一行改动影响。
- guest 侧 exec kill（原 M29）没有做。
- 宿主锁屏：9 项依赖 resume 的断言仍未验证。
