# 工作区导入、同步与导出设计

状态：实施设计草案
日期：2026-10-23

## 1. 安全目标

Workspace Sync 允许用户把明确选择的宿主目录作为任务输入，并把确认后的结果写回宿主。它不得让 guest 获得宿主目录的持续访问权，也不得因为路径、链接、竞态或 Git metadata 把权限扩大到授权根之外。

首版采用**快照式导入、暂存式导出**，不提供双向实时同步。Guest 工作区位于私有 COW 中，宿主目录不是 live mount。

## 2. 权限模型

工作区能力分为：

- `read-import`：读取授权根并建立输入快照；
- `write-export`：生成和确认普通文件变更集；
- `delete-export`：允许删除宿主文件，独立于写权限；
- `git-export`：允许通过受控 Git 流程导出 commit/ref；
- `continuous-refresh`：重新导入宿主新状态，首版默认关闭。

每项能力绑定规范化的宿主根、sandbox、用户、期限和最大数据量。选择父目录不自动授权其挂载点、重解析目标或随后替换进来的外部对象。

## 3. 导入流程

1. UI 通过平台文件选择器获取用户选择的根目录。
2. Host Sync Service 打开根目录句柄，并记录平台对象身份、权限和文件系统属性。
3. 使用 descriptor-relative 或平台等价 API 遍历；不以字符串前缀作为边界判断。
4. 拒绝或安全转换 symlink、hard link、junction、reparse point、device、FIFO、socket、ADS 和其他特殊对象。
5. 对文件数、单文件大小、总大小、深度和读取时间执行配额。
6. 将普通文件复制到宿主暂存区或直接流入 guest 私有盘，同时计算内容摘要。
7. 生成不可变 import manifest，记录相对路径、类型、大小、时间、权限和摘要。
8. 完整验证后以原子目录切换向 guest 发布工作区。

导入期间遇到对象被替换、身份变化或读取不一致时，该对象失败；无法安全确定影响范围时整个导入失败。

## 4. 路径与名称规则

- Guest 路径必须是规范 UTF-8 相对路径，禁止空路径、绝对路径、`..` 和 NUL。
- Windows 保留名、尾随点/空格、ADS、大小写冲突和 Unicode 归一化冲突必须在导入时报告。
- macOS 大小写与 Unicode 语义必须通过真实文件系统测试，不能只比较字符串。
- 同一底层文件被多个 hard link 引用时默认复制为独立普通文件，避免别名写入。
- Symlink 默认不跟随。首版可把指向工作区内普通文件的链接保留为 metadata，但导出前必须重新验证；实现不确定时直接拒绝。
- 文件权限映射采用固定白名单；setuid、setgid、ACL、xattr 和 quarantine metadata 不透明透传。

## 5. Guest 内语义

- Guest 可以修改私有副本，包括创建链接和特殊文件；这些对象不因此获得导出资格。
- `execd` 文件 API 只能访问 sandbox workspace 根和产品指定临时目录。
- Workload 不能看到宿主原始绝对路径、文件描述符或 Sync Service endpoint。
- Inotify 等事件仅反映 guest 私有副本，不代表宿主实时变化。

## 6. 变更集生成

任务结束或用户请求导出时：

1. 扫描 guest 工作区并与 import manifest 比较。
2. 对新增、修改、删除和类型变化生成规范化 changeset。
3. 再次应用路径、对象类型、数量和大小限制。
4. 特殊文件、越界链接、大小写冲突和不支持 metadata 标记为不可导出。
5. 在宿主隔离暂存区物化普通文件，不直接覆盖目标。
6. UI 展示文件级摘要；敏感内容预览遵循本地隐私策略。

Changeset 本身按 sandbox/session 签名或进行完整性绑定，防止另一个 VM 替换暂存内容。

## 7. 冲突与原子性

导出前将宿主当前对象与 import manifest 比较：

- 宿主未变化：允许应用对应变更。
- 宿主和 guest 修改不同文件：可合并到同一 changeset。
- 同一文件两边均变化：标记冲突，默认不覆盖。
- 宿主对象身份或类型变化：标记冲突。
- 删除操作：必须具有 `delete-export`，且宿主对象仍与导入基线匹配。

单文件写入采用同目录临时文件、flush、权限设置和原子 rename。跨文件系统不存在通用的整棵目录原子提交，因此 changeset 使用 journal：先暂存、再逐项应用、记录完成状态，失败后向用户报告部分结果并支持幂等恢复。不得声称整个多文件导出天然原子。

## 8. Git 工作区

直接把不可信 `.git` 修改写回宿主可能通过 hooks、config、filters、attributes 或 credential helper 影响用户之后在宿主执行 Git，因此使用专门规则：

- 普通源码导入可以携带构建和状态所需的 Git 数据，但不得携带宿主 credential helper socket 或秘密。
- Guest 对 `.git/config`、hooks 和本地执行配置的修改不进入普通文件 changeset。
- 源码修改按普通变更导出。
- Commit、object 和 ref 通过 `git-export` 专用流程导出，例如受控 bundle/pack 校验和用户确认，而不是原样覆盖宿主 `.git`。
- 导入的 submodule、worktree、alternates 和 LFS 配置必须消除宿主绝对路径与外部引用。
- 宿主执行任何由 guest 产生的 hook、filter 或 helper 前必须再次显式授权；首版默认拒绝。

具体 Git transport 仍需 POC，以确认 Claude Code、Codex 和常见命令的兼容性。

## 9. 敏感文件与默认排除

宿主 home、SSH、云凭据、Keychain、Credential Manager、浏览器 profile、Docker config、daemon socket 和系统目录永不因选择上层目录而隐式导入。

产品可以提供默认排除规则，但安全边界必须由对象身份与授权根强制，而不是依赖 `.gitignore`。用户显式选择疑似秘密文件时应提示风险；若用户确认，其内容属于用户主动提供给 workload，不再满足“guest 不接触该文件内容”的假设。

## 10. 清理与恢复

- 导入暂存区、changeset、journal 和未确认导出数据设置有界保留期。
- Destroy 顺序为：停止新同步、封存 changeset、按用户选择保留或删除未导出结果、删除 guest COW、删除暂存区、记录完成。
- Crash recovery 根据 journal 判断操作是未开始、部分完成还是完成，不能仅凭目录存在推断成功。
- 清理失败保持 `Stopping` 或 `Failed`，并提供不泄露内容的修复入口。

## 11. 验证门槛

1. 覆盖 `..`、绝对路径、symlink race、hard link、junction、reparse point、ADS、大小写和 Unicode 冲突。
2. 在导入和导出每个文件操作之间进行并发替换，证明不能越过授权根。
3. 验证特殊文件、权限、xattr、超大/超多文件和磁盘耗尽均 fail closed。
4. 验证宿主与 guest 双边修改、删除和部分提交恢复。
5. 证明 `.git` 修改不能在宿主植入 hook、helper、filter 或外部 object path。
6. Destroy 和宿主崩溃后不能恢复未授权暂存数据。
7. 在 macOS 与 Windows 的目标文件系统上分别运行同一 corpus。
