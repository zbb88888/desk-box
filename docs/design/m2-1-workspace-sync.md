# M2-1：Workspace Sync（显式授权 workspace 推送，macOS）

状态：已完成（真机双路径验证 exit=0）；关联 `docs/design/m2-roadmap.md`、`docs/security/security-verification-matrix.md` INV-05。

## 进度

- ✅ 协议：`wsBegin/wsPut/wsEnd/wsAck`（ControlMessageKind 14-17），与 exec/PTY 共享加密 record channel；
- ✅ Host：`WorkspaceSyncService.buildSnapshot`（路径只允许 root 以下常规文件、拒绝 symlink、拒趋辖/总大小/总个数限额、per-file SHA-256 的 manifest）；`VZRuntime.pushWorkspace`；
- ✅ Guest：`ws_session` 状态机、路径深度/相对性检查、pwrite 落位 + fsync、wsAck 反馈；
- ✅ CLI：`launch --workspace <dir>` + guest 侧 `busybox sha256sum` 集合反馈 （`ws-verify ok`）；
- ✅ 验证：签署 manifest 默认加密 + `--allow-plaintext` 双路径 exit=0；guest sha256 与 host snapshot 一致；
- ✅ 证伪：symlink 拒收、文件品度不超过、总字节不超过、root 不存在拒 — 都由 `WorkspaceSyncTests` 五个单测限御；
- ✅ 关键修复记录：`ws_emit_ack` 的序号从预增改为后增（host 序列守卫不接受 OOO 帧）；Swift JSONEncoder 默认 `\/` 转义在 `ws_extract_string` 中反转义。

## 1. 目标与非目标

### 1.1 目标
- host 用户通过 `dbx-poc launch ... --workspace <dir>` 显式授权一个 workspace 目录；
- guest 端在 VM 启动、secret channel `tlsAuthenticated` 后，通过 **加密 control channel** 收到 workspace 快照全部授权文件并落位 `/workspace`；
- host 在发送前按 policy fail-closed 验证：只允许 root 之下的常规文件、拒绝逃出 root 的 symlink/路径、总大小与文件数限额、生成可审计的 per-file SHA-256 清单；
- guest 端写完后对每个文件做 SHA-256 终验；任何不一致都视为无法信任并销毁整个 sandbox（fail-closed）。

### 1.2 非目标
- 不引入 virtiofs/9p/guest-kernel 侧架拼网目录（快照推送本身更安全，无需新增 guest 内核模块与文件系统 attack surface）；
- 不做 watch/增量同步（M2-1 只在启动时做一次推送）；
- 文件 mode/属主统一 enforce：0644/0755、owner=nobody(65534)，不传属主机策；
- 不做特殊例外：sync 什么由 host 发送清单决定，guest 不做内置白名单（早期发布最大化为笙垠安全）。

## 2. 设计

### 2.1 协议（加密 control channel，ControlMessageKind）

```
WsBegin = 14  { "wsId": string, "fileCount": Int, "totalBytes": UInt64 }         // requestID 绑定
WsPut   = 15  { "path": string(rel, no abs/".."), "offset": UInt64, "mode": UInt32, "dataHex": hex ≤ 512 byte }
WsEnd   = 16  { "wsId": string }
WsAck   = 17  { "wsId": string, "ok": Bool, "error": string? }                    // 最后一笔 cmolder WsEnd 的回应
```

- 消息顺序经由已有 `ControlSequenceGuard` 检测，每条 WsPut 在独立 AEAD record 中传输；
- 采用 host 主动推送 + guest 仅 WsAck 的半双工语义；与 exec/PTY 在相同 record channel 上多路复用但参考 ID 独立。

### 2.2 Host 实现 — `WorkspaceSyncService`（DeskBoxVZ）

- 输入：`workspaceRoot: URL`、`WorkspaceSyncPolicy { maxFiles: 4096, maxTotalBytes: 64MiB, maxFileBytes: 16MiB, allowReadWOnly: Bool }`；
- `buildSnapshot()`：
  - `FileManager.enumerator` 遍历 root；**拒绝** 任何符号链接（出现在失败报告中）、拒绝越出 root 的路径；
  - 绝对路径必须 `hasPrefix(root.path + "/")` 且不含 `".."`；
  - 超限额/非常规项 → 整体结束该次同步（fail-closed，不做“静默跳过”）；
  - 生成 `WorkspaceManifest { files: [{path, mode, bytes, sha256}] }`；
- `push(snapshot, to handle, via VZRuntime)`：以 ≤512 bytes 区块流式发送 WsPut；发送后收集 WsAck；
- 接入点：`launch` CLI `--workspace <dir>`；secret channel 成立后先推送 workspace 再运行演示 exec/PTY。

### 2.3 Guest 实现 — `guest-bootstrap.c`

- `kind == 14/15/16` 处理：
  - WsBegin：初始化 `ws_session={wsId, fileCount, totalBytes, receivedFiles, receivedBytes}`；旧 session 未完毕 → 关闭并报废；
  - WsPut：位置验证（拒绝 abs/`..`/NUL、要求空 ws dir 内部）、open64() 后 `pwrite(off, data)` + fsync periodic；计数元累计；
  - WsEnd：终资限额比较（receivedFiles/Bytes == declared）→ WsAck ok；否则 WsAck{ok=false,error}；
- guest 侧一切写入最终不属 root（写完后 chown nobody:nogroup，mode 0644/0755）；
- guest console 输出每文件的可审计记录（index、path、sha256、bytes）。

### 2.4 失败路径（全部 fail-closed）
| 故障 | 处理 |
|------|------|
| host 构建快照发现 symlink//root-escape | snapshot 构建 reject （launch 失败） |
| 传输中途断线 | record channel 底层报 channelLost，本次同步视为失败，不启动后续业务 |
| WsPut 格式错/顺序错 | guest 丢弃 + WsEnd 时 `ok=false` |
| 最终 sha256 不一致 / fileCount 不符 | WsAck error；host 上面拒绝按未同步启动后续业务 |

## 3. 出样验证（脚本的黑盒一步递增）

1. `launch --workspace <tmpdir>`：guest 上 `sha256sum /workspace/...` == host；
2. 超出 maxFileBytes → launch 前构建拒绝；
3. workspace 内含 symlink → 拒绝；
4. guest 发送后 helper 审计文件数量 + 总字节与清单一致；
5. stdout 列出 per-file sha256 供人工拍案验证。

## 4. 不确定性与禁忌
- 大 workspace 场景未来可评估 virtiofs，Arrangement 但须先经过独立审查（KEXT/guest-kernel 提权面）；
- INV-03 边界：workspace 中不应包含原始凭据；本阶段不做扫描器，但显式声明该责任在调用方（后来由 Broker+secret policy 补充）。
