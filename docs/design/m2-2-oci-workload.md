# M2-2：OCI workload 语义与策略门禁（macOS）

状态：本阶段（M2-2a：语义层）已完成，真机双路径 exit=0；关联 `docs/design/m2-roadmap.md`、`docs/security/security-verification-matrix.md` INV-06、INV-08。

## 进度（M2-2a）

- ✅ `OciRuntimeSpec` 模型 + `OciPolicyValidator`（DeskBoxVZ）fail-closed 拒收：cwd 越界 / uid!=nobody / privileged / mount 越出 workspace / env DBX_ / root 越出 bundle / 空 argv；
- ✅ Guest exec /cwd/env 受限语义（白名单 + nobody 65534 + PATH/HOME/USER 保留）；静态 C 多段解析 + hard fail → exit 125；
- ✅ `VZRuntime.execute` 准入：`argv[0]` 仅允许 `/bin/echo|/bin/sh|/workspace/*`；cwd 必为 workspace；
- ✅ CLI `--oci-bundle`：解析 config → policy validate → workspace sync → OCI argv/env/cwd 执行；
- ✅ 真机双路径（默认加密 / `--allow-plaintext`）：`oci-exec=0 stdout=OCI_MARKER uid=65534 cwd=/workspace x=hello-oci`；
- ✅ 单测：11 个 OCI policy 负正案全过；
- 下一步（M2-2b）：真实 runc 集成、image puller/cgroups v2、OCI bundle 的 lifecycle（状态转移面）。

## 1. 目标与非目标

### 1.1 目标
- 支持用户以标准 `config.json`（OCI Runtime Spec 用得最多的子集）描述任务：argv/env/cwd + rootfs（`oci.root.path`，经 M2-1 同步落位 `/workspace`）；
- 实施 **WorkloadSpec Compiler/Policy**（INV-06）：解析时即 fail-closed 拒绝可扩权字段（privileged/devices/host paths/host network/超出 workspace 的 mount source、DBX_ 前缀环境变量、runAsUser 非 nobody 等）。这些案例正是 INV-06 的直拒证伪点。
- guest execd 接受 **受限 cwd/env**（M1-3 的 blanket reject 收起：cwd 必须以 `/workspace` 为前缀、env 键名白名单格式 + DBX_ 前缀禁止 + PATH/HOME/USER 固值、其他实参进强制池）；
- 子阶段目标是**语义层闸**（编译器 + policy）：真实 runc/containerd 集成属 M2-3（见 §1.2）。

### 1.2 非目标（挂出与下一阶段声明）
- 不在本阶段将 containerd/runc 二进制打包进 guest（rootfs 扩张、musl/glibc 兼容、cgroups v2 写入端点都要稳定）——但本阶段的 policy 决策与 bundle 编译格式就是 containerd 日后的边界，不会重复裁决；
- 不做 image 拉取（网络分发 channel 由 M2-3 Broker 提供）；
- 文件系统隔离仍是 workspace 快照推送（M2-1 已交付）；后续如评估 virtiofs，需要单独审查；

## 2. 实施参考

### 2.1 config.json 允许子集（DeskBoxCore `OciRuntimeSpec`）

```json
{
  "ociVersion": "1.x",
  "root": {"path": "rootfs", "readonly": false},
  "process": {
    "args": ["/bin/sh", "-c", "..."],
    "cwd": "/workspace",
    "env": ["K=V"]
  },
  "mounts": [],            // 仅允许空集或 workspace 内部 subdir
  "linux": {"namespaces":[]} // 接受但一律不授予 host 侧任何扩权（namespaces 字段仅透明记录，不影响执行环境）
}
```

禁面（任一出现即 reject，报错 `DBX-PLATFORM-ASSET-DIGEST-MISMATCH` （现有门） + 信息区分）：
- `process.user.uid != 0`（guest exec child 经 M1-3 硬熃被过 nobody；非 0 拒绝执行却转换后拒绝模式）；
- `process.env` 含 `DBX_*` 前缀（密封带 DBX_NONCE/BOOT/MANIFEST/sessionID 的更高级别是 worker 混沌态）；
- `process.env` 含空格/NULL/字节溢出；
- `process.cwd` 不以 `/workspace` 为前缀；
- 附带 `privileged`、`hostPaths`、`mounts` 可 writing 出 workspace、capabilities、seccomp 解除、network 属性等。

### 2.2 Guest exec 协议提拕（ControlRequest）

新增字段（可选的 fail-closed 子集）：

```json
{ "kind":"exec", "argv":[...], "timeoutSeconds":N,
  "cwd":"/workspace/dir", "env":{"K":"V"} }
```

guest install_exec_hardening 现改为：
- 白名单：cwd 必以 `/workspace` 为前缀（否则 reject）；env 键名 `^[A-Z_][A-Z0-9_]*$`、禁 `DBX_*`，值限制 ≤ 256 bytes；否则 `_exit(125)`；
- 默认 PATH/HOME=/workspace/USER=sandbox 不可覆盖；
- 其他 M1-3 全保障仍保留（nobody 65534、rlimit、no_new_privs）。

### 2.3 落点

- `Sources/DeskBoxCore/OciRuntimeSpec.swift`：模型 + 解析；
- `Sources/DeskBoxVZ/OciPolicyValidator.swift`：fail-closed validator → 返回 `ResolvedWorkload { argv, cwd, env, rootfs }`；
- `Sources/DeskBoxCore/ControlProtocol.swift`：ControlRequest 增加 `cwd`/`env`；
- `scripts/guest-bootstrap.c`：exec hardening 的新口径；
- `Sources/dbx-poc/main.swift`：`--oci-bundle <dir>`；解析 + validate + workspace-push rootfs + ptyRoundTrip 执行（以 PTY 做交互/观察），并输出 `ws-verify ok` 节点；
- `Tests/DeskBoxCoreTests/OciPolicyTests.swift`：正负案。

### 2.4 验证（脚本的黑盒一步递增）

1. 有效 bundle（`rootfs/` 含 `busybox` 二进制 + 脚本）→ `--oci-bundle` 跑完并输出 marker；
2. conjunctive 非法示例：privileged、cwd=/etc、env DBX_*、mount to /proc —— 各自单独触发 reject；
3. 默认加密 + `--allow-plaintext` 双路径回归 + `swift test`；
4. `security-verification-matrix.md` INV-06 更新（M2-2a 部分已验证，containerd/runc 侧写后续明细）。

## 5. 安全决策

- **fail-closed 是唯一解释路径**：OCI 扩权语义由 host 编译时的政策 struct 拒绝，不依赖于 guest 在运行时识别恶意 config；
- **env 是凭据侧面**：DBX_* 前缀是未来 broker/握手 key 名字空间；此阶段就禁；
- **真实 runc 化是退化**：本阶段阉黎的“process 节”之后 containerd 集成时仍复用同一个 ResolvedWorkload 契约，裁决不重做。