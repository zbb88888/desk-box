# M34：签名 / 发布 / 校验类子命令 fail-closed

状态：已完成（本轮改动不涉及 VM / resume；宿主仍处于锁屏，历史遗留的 8 项 resume 断言见 §5）。
关联 `m27-host-robustness.md` §1、`m5-release-signing-chain.md`、`m7-release-channel.md`、`m22-distribution-notarization.md`。

## 1. 问题

M27 只把 daemon 生命周期子命令迁到了声明式解析。签名 / 发布 / 校验 / 直启这一组（15 个子命令）仍在用手写的 `optionString`：缺值会报错，但

- **未知选项被静默忽略**；
- 值可以是另一个选项（`--manifest --key …` 把 `--key` 当成路径）；
- 整数不校验（`--asset-version -1`、`--min-version-floor -1` 都被接受）；
- `check-update` 在没有 `--channel` 时取「第一个不以 `--` 开头的参数」，那可能是别的选项的值。

对供应链相关的命令，静默忽略一个拼错的选项会直接放宽安全门槛或写错文件。用改动前的二进制实测：

| 命令 | 实际发生的事 |
|---|---|
| `publish … --min-version-flor 5` | 发布成功，`channel.json` 被重写，防回滚下限变回默认的 **1** |
| `sign-manifest … --asset-versoin 7` | 用旧版本号签名并产出文件 |
| `rotate-release-key --base K --new-key N --ouput out.json` | **原地覆盖 `K`** |
| `revoke-release-key --base K --key-id X --ouput out.json` | 同上 |
| `make-manifest … --sbom-digset <sha>` | manifest 里没有 SBOM 绑定 |
| `check-update --current-version 9.9.9` | 把 `9.9.9` 当成 channel 路径 |
| `gen-guest-sign-key` / `gen-release-key` | 私钥文件权限 **0644**（umask 000 下 0666） |

## 2. 改动

- `ReleaseCLISpecs`：15 个子命令的声明式规格（`capcheck` `version` `verify-sbom` `validate-assets` `make-manifest` `gen-guest-sign-key` `sign-manifest` `gen-release-key` `rotate-release-key` `revoke-release-key` `publish` `verify-channel` `domains` `check-update` `launch`），复用 M27 的 `CLIArgs.parse`。手写的 `optionString` / `optionInt` / `optionURL` 已删除，`dbx-poc` 里不再有第二套解析。
- `CLISpec` 新增可省略的位置参数（`check-update` 的 channel 既可用 `--channel` 也可作为位置参数，二者只能取其一）。
- 版本号类整数限定在 `0…Int32.max`；`launch` 的 `--memory-mib` / `--cpus` 与 `run` 同范围。
- `PrivateKeyFile.write`：私钥先写到同目录的 0600 临时文件再 rename 覆盖目标——目标路径上不会出现「内容已是私钥、权限还没收紧」的窗口；覆盖旧的 0644 文件后也是 0600；不受 umask 影响；失败不留临时文件。
- 退出码语义不变：参数错误 exit 2；`check-update` 的拒绝（回滚 / 篡改 / 撤销）仍是 exit 3。

**兼容性**：盘点了 `.github/workflows` 与 `macos/scripts` 里对这些子命令的全部调用，用到的选项都在规格内。`sign-and-run.sh` 把用户参数透传给 `launch`，所以以前拼错也能跑的命令现在会报错——这是本次改动的目的。

## 3. 验证

单元测试 `ReleaseCLITests` 13：上表每一条拼写错误都有对应用例；值不能是另一个选项 / 空串；整数范围；`check-update` 的 channel 解析（含回归）；规格自洽（usage 列出每个选项、子命令名不重复）；私钥 0600（新建 / 覆盖 0644 / umask 0 / 失败不留临时文件）。`swift test` 共 339 全绿。

端到端 `scripts/e2e-release-cli.sh` **53/53**（不需要 VM，约 1 秒）：

```
R1 私钥 0600（含覆盖旧 0644、umask 000）；release-keys.json 不含私钥材料；无临时文件
R2 make-manifest → sign-manifest → validate-assets → publish → verify-channel → check-update 正向链路
R3 防回滚下限拼对时被执行：floor(5) > assetVersion(3) → publish 被拒，channel.json 不变
N* 20 个拼错 / 缺值 / 非法值用例：exit 2，且没有副作用（不产出文件、已有文件 sha 不变）
K* 轮换 / 撤销：--output 指向新文件时 --base 不变；用已退役 key 签名的 manifest 无法发布
```

**对照实验**：用改动前的二进制（app bundle 里 10 月 28 日的构建）跑同一套件，**31 项失败**，逐条对应 §1 的表。

CI：`macos-build-test` 新增一步运行该套件。它是真机 e2e 里第一个（也是目前唯一一个）能在 CI runner 上跑的。

全量 `e2e-all.sh`：15 个套件 0 失败，卫生四项 clean，退出码 3（锁屏）。

## 4. 需要你知道的

- **已存在的私钥文件不会被自动修正。** 例如本机的 `macos/guest/dev-sign-key.local` 仍是 0644。新生成（或重新生成）的才是 0600。手动收紧：`chmod 600 macos/guest/dev-sign-key.local`。
- 以前拼错选项也能「成功」的调用现在会以 exit 2 失败并指出是哪个选项。

## 5. 诚实边界

- `launch` 只验证了解析（未知选项 / 非法整数在触碰 Virtualization 之前被拒）；没有用新解析真正启动一台 VM（`launch` 是早期 POC 入口，日常路径是 daemon 的 `run`）。
- 没有对「值看起来像路径但写错了」这类语义错误做任何检查；fail-closed 只覆盖语法层面。
- `gen-*-key` 仍会覆盖已存在的密钥文件而不提示。
- **宿主仍处于锁屏**：M31–M33 遗留的 8 项依赖 resume 的断言在本轮全量运行里依然被跳过（退出码 3）。本轮没有改动任何与 VM / suspend / resume 相关的代码。解锁后需重跑 `./scripts/e2e-all.sh` 并得到退出码 0。
