# 开源参考仓库

Desk Box 设计文档中引用的开源项目，统一 clone 到本目录做**只读源码参考**。本目录内容不入库（见 `.gitignore`）。

## 使用纪律

1. 仅用于阅读、对照与 POC；不得把上游代码直接复制进产品仓库。
2. 任何组件从“参考”升级为“采用”，必须先符合[技术选型与取舍](../docs/research/technology-selection.md)的决策，并按[架构](../docs/architecture/desktop-vm-sandbox.md) §9 执行：固定已审计 release、禁止跟随 `main`、保留 license/NOTICE、SBOM、patch series 与可重复构建记录。
3. clone 时固定 tag，不用 `main`：

```bash
cd references
git clone --depth 1 --branch <已评估的 release tag> <仓库地址>
```

4. OpenSandbox 是唯一计划 fork 的上游；fork 仓库另行建立，不放本目录。其仓库地址、LICENSE 与 NOTICE 在 fork 前逐条核对，技术选型文档中对 OpenSandbox 架构的描述以评审记录核实后为准。

## 跨平台参考

| 仓库 | 用途 | 对应的 Desk Box 文档 |
| --- | --- | --- |
| https://github.com/opencontainers/image-spec | OCI manifest/config/layer 与 digest 语义 | 架构 §6.5、技术选型 §3.3 |
| https://github.com/opencontainers/runtime-spec | OCI runtime 配置与进程模型（privileged/namespace/device/capability 的真实归属层） | 架构 §5.2、技术选型 §3.5 |
| https://github.com/containerd/containerd | guest 内 content/image/snapshot/task 生命周期 | 架构 §7.2、技术选型 §3.5 |
| https://github.com/opencontainers/runc | namespace/cgroup/capability/seccomp 的实际应用顺序，`libcontainer` 行为 | 架构 §7.2、双层模型 §6.3 |
| https://github.com/moby/buildkit | LLB DAG、worker、snapshotter、cache 与 build secret 语义 | 架构 §6.6、技术选型 §3.4 |
| https://github.com/kata-containers/kata-containers | VM-backed 分层模板：shim v2、kata-agent/vsock、私有 RPC 边界 | 技术选型 §4.1 |
| https://github.com/firecracker-microvm/firecracker | 最小 virtio 设备面与一次性 rootfs 设计对标 | 技术选型 §4.6 |
| https://github.com/google/gvisor | 未来 guest 二级隔离（runsc/Sentry/systrap/Gofer） | 技术选型 §5.1 |
| https://github.com/wasmerio/wasmer | 未来 Wasm-only plugin profile | 技术选型 §5.2 |
| https://github.com/e2b-dev/infra | Agent 工作区体验（envd、template、snapshot）对标 | 技术选型 §4.5 |
| https://github.com/qemu/qemu | 诊断后备与原生 API 能力对照 | 技术选型 §5.4 |

## Windows 专项

| 仓库 | 用途 | 对应的 Desk Box 文档 |
| --- | --- | --- |
| https://github.com/microsoft/hcsshim | HCS / 计算服务调用面参考（注意：不采用 LCOW 路径） | 技术选型 §3.2、[windows/](../windows/README.md) |
| https://github.com/linuxkit/virtsock | HVSock / vsock 主机与 guest 侧实现参考 | 控制通道设计、[windows/](../windows/README.md) |
| https://github.com/microsoft/WSL2-Linux-Kernel | WSL2 共享 utility kernel 的反向对照（为何不满足一授权域一 kernel） | 技术选型 §5.3 |

## macOS 专项

`Virtualization.framework` 为闭源框架，无源码仓库：

- Apple 文档：https://developer.apple.com/documentation/virtualization
- Apple 示例：在 Apple Developer 文档站检索 “Running Linux in a Virtual Machine”。
- 以[平台能力矩阵](../docs/design/platform-capability-matrix.md) §4 的 POC 清单验证真实行为，文档说法不替代实测。

## 建议阅读入口

- `runc`：`libcontainer` 中 spec 校验、capability 应用、`no_new_privs` 与 seccomp 安装顺序，用于对照双层模型 §6.3 的 guest 强制项。
- `containerd`：task/shim 接口与 snapshotter 抽象，用于评估产品要暴露给 `execd` 的最小面。
- `buildkit`：`RUN`/secret/cache mount 的 worker 执行路径，用于 Builder VM 的秘密绑定与 cache 污染验证。
- `kata-containers`：shim v2 与 kata-agent 的 RPC 面、guest 内最小组件列表，用于对照 Desk Box 私有控制通道设计。
- `hcsshim`：Windows 上 VM 生命周期调用面与权限需求，配合平台矩阵 §5 POC 6（不照搬 LCOW 逻辑）。

## 许可证

各仓库许可证以其中 LICENSE/COPYING 文件为准；上表未逐一标注，fork、复制或静态链接前必须逐仓核对并落到产品的 NOTICE 与 SBOM 流程。
