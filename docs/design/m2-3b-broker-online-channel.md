# M2-3b：guest→host 在线 broker 请求通道

状态：已完成（真机双路径 exit=0）；前置 M2-3a；关联 `docs/design/m2-roadmap.md`、INV-03/INV-04。

## 进度

- ✅ 协议：`brokerFetch(21)/brokerData(22)/brokerEnd(23)`，走加密 record channel；
- ✅ Guest：`/run/deskbox-broker.sock` AF_UNIX listener（0666）、URL 格式校验（≤480 bytes、http 前缀）、
  savePath 由 `/workspace/inbound/` 为前缀 + basename(url) sanitize、请求并并渐变 in-place fd；
- ✅ `brokerreq` 静态成员（musl static）加入 initramfs 与 rootfs `/bin/`；
- ✅ Host：`VZRuntime` handleControlFrame kind==21 → `BrokerService` policy/凭据/fetch → 分块回传（512B hex/record）+ end；
- ✅ CLI `--broker-guest-url` 演示+轮询验证（exit=0 才断言非空）；
- ✅ 验证：
  - 默认加密／`--allow-plaintext` 双路径：`broker-guest outbound=https://example.com exit=0 stdout=sha256=25ddf2c883…`（与 M2-3a host preload 摘要一致）；
  - 白名单外 `internal.example.com`：exit=1，file 未写入（savePath 为空，-s 检查为假）；
- ✅ 关键修复记录：
  - guest `parse_argv` 原来按第一个 `]` 定数组去结尾，`[ -s ...]` 会截断 argv —— 已改为 quote-aware 扫描；
  - PTY 输出与 exit 事件竞态 —— ptyRoundTrip 增加了退出后一次 drain 周期；

## 1. 目标

打通从 **guest 工作负载**到宿主 broker 的单向请求通道：
- guest exec/PTY 子进程通过 guest 内 AF_UNIX socket（`/run/deskbox-broker.sock`）向 deskbox-bootstrap 投递请求；
- deskbox-bootstrap 将请求作为控制面消息（加密 record channel）送给宿主；
- 宿主 broker 校验 policy + 注入凭据 + 拉取 URL；
- 响应体分块回传给 guest 并作文件落位 **INBOUND-ONLY** 目录（/workspace/inbound），guest 进程被通至 success；
- 整个过程不改蛋 INV-03（凭据仍只在于 host）、INV-04（沙箱默认零网络设备）。

## 2. 实施参考

### 2.1 消息层（ControlMessageKind）
```
brokerFetch    = 21  // guest → host { "reqId": UInt32, "url": string, "savePath": "/workspace/inbound/..." }
brokerData     = 22  // host → guest { "reqId": UInt32, "offset": UInt64, "dataHex": hex ≤ 512B }
brokerEnd      = 23  // guest receive：{ "reqId": UInt32, "status": UInt16, "bytes": UInt64, "ok": Bool, "error": string? }
```

- 每个 brokerFetch 独立 reqId；guest 允许多个 in-flight（本阶段实质是 host 串行处理也可接受，但保持消息 id 逻辑）；
- 审核节点一起：fetch 前 policy（M2-3a fail-closed）；response 限额（M2-3a 部分已验证）。

### 2.2 Guest 端新增（guest-bootstrap.c）
- AF_UNIX socket 创建：`/run/deskbox-broker.sock`，mode 0666（相关 EX=child 以来允许）；
- `poll()` 多重路由加入第 3 个 fd：broker socket 接受连接 → 读取单 line "GET <url> <savePath>"（限制 url ≤ 512 bytes）；
- 请求理：经 vsock（kind 21）加密发送 → host 响应经 kind 22/23 回写`/workspace/inbound/<savePath>`；
- brokerEnd.ok → 该 conn 回复 "OK"<cr>；否则 "ERR <text>"。

### 2.3 Host 端
- `Sources/DeskBoxVZ/VZRuntime.swift`：`record.brokerNextReqId`、handleControlFrame kind==21 → async 调用 `BrokerService` → 发送 kind 22 分块（≤512B hex）+ kind 23；
- `VZRuntime.openBrokerChannel(...)`：不需要（信合控通道多路复用，如 M2-1 决讯的 pattern）。

### 2.4 CLI 演示
`launch --broker-via-guest https://example.com`：
1. running 后发送 PTY `"/bin/sh -c 'printf \"GET https://example.com inbound/x.html\\n\" | nc -U /run/deskbox-broker.sock; busybox sha256sum /workspace/inbound/x.html'"`；
2. 验证 PTY 输出包含期望 sha256（例：example.com 是公开页面，host 名察回来的 sha256 对齐）。但该 page 是恒定的（固定内容），可供出样验证。

## 3. 验证
- 允许名域：PTY 请求后 sha256 一致（与 `--broker-preload` 产生的 host 摘要一致）；
- 白名单外：brokerEnd ok=false + 返回 ERR；
- 恶意 URL size 超过限制：broker 侧拒绝；
- 默认加密 + `--allow-plaintext` 双路径；
- 单测：主机侧请求解析、savePath sanitize、host policy fail。

## 4. 安全决策
- guest 内 access broker 的 interface 是 UNIX socket——如不允许任意 guest 进程都来请求，就会受 INV-04 完整约束问题；本阶段限制 broker UNIX socket 只接受 `/workspace` 上下文进程连接（socket 层 mode 0666 由 setuid nobody 的 exec 受体约束），，生产部署可再加各类凭据域鉴权标签；
- savePath 必须落在 `/workspace/inbound/` 之下；不允许 `..` 遍历；
- 凭据留宿主（与 M2-3a 一致）；guest 内所有 broker 请求都等待 CPU 限额之下、超时上限。