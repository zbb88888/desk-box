# M50：Manifests 面板与菜单栏弹窗——逻辑移出视图、修掉两处一直存在的问题

状态：已完成。只改了 GUI；没有改 daemon、runtime 与 guest。
关联 `m30-gui-actions-and-selftest.md`（按状态启用的行内操作）、`m32-gui-viewmodel-and-flow.md`（逻辑进视图模型）。

## 1. 起因

M30 / M32 把主列表的按钮逻辑移进了可测试的模型，但 Manifests 面板和菜单栏弹窗一直留在原样：逻辑写在视图里，应用内自检也没有覆盖（路线图上的 M40 遗留项）。把它们移出来的时候，读代码就看到了两处问题。

## 2. 问题

**Manifests 面板**

- **Digest 一列永远是 `-`**。代码读的是 `signature.payloadDigest` / `payloadSha256`，而 manifest 的签名里只有 `alg` / `keyID` / `sig`。这一列从写出来起就没有显示过任何东西。
- 目录里任何 `manifest*.json` 都列出来并给一个可点的 Run——包括不是合法 JSON 的、引用的资产文件已经不在的。点下去只会得到一条 daemon 的拒绝。

**菜单栏弹窗**

- 对**任何状态**的沙箱都显示 stop 和 rm。对 suspended / failed / stopped 的沙箱点 stop，daemon 会拒绝。
- 请求直接写 socket，**错误被吞掉**（`try?`）：被拒绝时界面上什么都不发生，日志里也没有。这是 M32 之前主列表的写法，当时漏改了这里。

## 3. 改动

- `ManifestCatalog`（纯逻辑）：扫描目录，每个 manifest 给出文件名、内核、签名密钥的 keyID、资产版本与状态——`signed` / `unsigned` / `missing: <缺的资产>` / `unreadable: <原因>`。读不了和缺资产的行 Run 不可点；未签名的照样可点（是否放行是 daemon 的策略）。`*.unsigned.json` 是签名前的中间产物，不列出。资产名里带路径分隔符的一律算缺失。只读 1MiB 以内的文件。
- 面板的列改为 Name / Kernel / SizeKB / Key / Status / Run。
- `MenuBarSandboxActions`：与主列表共用 `SandboxRowActions` 的按状态规则，只保留弹窗里放得下的操作（stop / resume / restart / rm）。请求经 `SandboxViewModel.submit` 发出——错误会被显示和记录，完成后刷新列表。

GUI 没有做签名验证：`signed` 只表示「带有签名」，验签仍然只在 daemon 里。

## 4. 验证

单元测试（`swift test` 442 全绿，新增 9）：`ManifestCatalogTests`——文件名过滤；已签名且资产齐全；未签名；缺资产（点名缺哪几个）；资产名带路径分隔符；四种读不了的文件；排序、跳过中间产物、目录不存在；菜单栏操作随状态变化；弹窗里不出现需要面板的操作、非 running 状态不出现 stop。

应用内自检（真机，`e2e-gui-app.sh` 69 项，新增 2）：

- Manifests 面板的数据：对着真实的 guest 目录扫描，当前使用的 manifest 被识别为可运行并显示了签名密钥（`4 listed; manifest.json key=d75fa8c9ad434947 kernel=vmlinuz-virt`）；
- 菜单栏弹窗：running 时提供 restart / stop / rm，经它 Stop 之后状态变为 stopped、只剩 rm；锁屏时沙箱停在 suspended，弹窗里是 resume / rm、没有 stop（两个分支分别在解锁 / 锁屏的宿主上走到）。

全量 `e2e-all.sh`（本机现有 guest）与（候选）：见提交说明与证据文件。

顺带：M49 留下的「没有系统审计重复 close」——对全部产品与测试代码扫了一遍「同一个函数里既有 `defer { close(x) }` 又有显式 `close(x)`」的组合，只有 M49 已经修掉的那一处（现在由 `fd = -1` 保护）。

## 5. 诚实边界

- 自检驱动的是模型层：它证明「面板和弹窗用到的数据与规则是对的」，不是「按钮确实画出来了、点得到」。真实点击仍然没有测试（需要辅助功能授权）。
- 菜单栏弹窗本身（`MenuBarExtra`）在自检里没有被打开过；它用的是和测试同一份 `MenuBarSandboxActions` 与同一个提交入口。
- 弹窗和主列表的 Rm 都是一次点击、强制移除、没有确认——这是原有的设计，本轮没有改。
- Manifests 面板的 `signed` 不代表签名有效；用不受信任的密钥签的 manifest 同样显示 `signed`，Run 时才会被 daemon 拒绝。
- 对「重复 close」的扫描是一次性的文本匹配，没有做成持续运行的检查。
- **本机 `macos/guest/` 与 `gui/dist/DeskBox.app` 仍是旧资产 / 旧构建**：你正在用的那个 App 里，Manifests 面板的 Digest 列仍然是 `-`，菜单栏弹窗仍然是旧行为。
