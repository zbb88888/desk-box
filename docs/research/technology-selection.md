# Technology Selection and Trade-off Analysis

Status: Accepted for initial implementation
Date: 2026-10-23

## 1. Evaluation method

Candidates are evaluated against the actual product requirements rather than their project labels.

Criteria, in priority order:

1. Isolation strength against a malicious agent, image, dependency, or MCP server.
2. Native availability on Apple Silicon macOS and Windows 11 Pro/Enterprise.
3. Ability to keep long-lived host credentials outside the sandbox.
4. OCI and Dockerfile compatibility.
5. User experience suitable for a desktop product.
6. Auditable failure behavior and narrow privileged interfaces.
7. Maintenance, licensing, supply-chain, and upstream stability cost.
8. Startup time and resource density, after security gates pass.

A project can be adopted for one layer without being adopted as the product foundation. Image format, orchestration, guest API, process isolation, and VM isolation are separate decisions.

## 2. Decision summary

| Project or technology | Underlying engine | Decision | Product role |
| --- | --- | --- | --- |
| Apple Virtualization.framework | Apple hardware virtualization and virtio devices | Adopt | macOS VM boundary |
| Hyper-V Generation 2 | Type-1 hypervisor, VMBus, VHDX, HVSock | Adopt | Windows VM boundary |
| OCI Image Spec | Manifest, config, and filesystem layers | Adopt | Workload package format |
| BuildKit | LLB graph, workers, snapshots, cache | Adopt in builder VM | Dockerfile builder |
| containerd | Content, snapshots, images, tasks | Adopt in guest | OCI lifecycle |
| runc | libcontainer, namespaces, cgroups, seccomp | Adopt in guest | OCI process execution |
| OpenSandbox execd | Go execution daemon with HTTP/SSE/WebSocket APIs | Adopt as pinned fork | Guest command/file/PTY API |
| OpenSandbox lifecycle/SDK/MCP | OpenAPI, FastAPI, generated and handwritten clients | Reference and adapt | Contract semantics |
| OpenSandbox egress/Credential Vault | DNS+nftables sidecar, TLS MITM, in-memory vault | Reference only | Policy semantics |
| Kata Containers | shim v2, virtcontainers, hypervisor, guest kernel, kata-agent | Architecture reference | Layering model |
| Docker Desktop | Shared Linux VM plus Docker/containerd stack | Reference only | Desktop feasibility evidence |
| E2B | Cloud orchestration, Firecracker, envd, snapshots | Reference only | Agent-workspace behavior |
| Firecracker | Linux KVM microVM VMM | Reference only | Minimal VM design |
| gVisor | runsc, Sentry user-space kernel, systrap, Gofer | Future optional profile | Guest secondary isolation |
| Wasmer/WASI | Wasm runtime and capability-oriented host calls | Future optional profile | Wasm-only plugins |
| WSL2 | Shared utility VM Linux kernel | Reject as strong mode | Possible low-assurance compatibility |
| QEMU | Software device model with HVF/WHPX acceleration | Diagnostic fallback | Portability comparison |

## 3. Adopted foundations

### 3.1 Apple Virtualization.framework

`Virtualization.framework` configures and runs hardware-assisted virtual machines through platform APIs. Linux guests use virtio devices for storage, entropy, memory management, networking, and host/guest sockets.

Why selected:

- It is the supported Apple-native virtualization API on Apple Silicon.
- Its device surface is narrower and operationally simpler than shipping a general QEMU stack.
- Application signing, entitlements, lifecycle, and updates align with a desktop application.
- It supports an independent guest kernel, satisfying the primary isolation requirement.

Costs and limits:

- macOS implementation is platform-specific.
- It does not supply an OCI runtime, image service, guest agent, or credential broker.
- Cross-architecture execution should not be silently emulated; native arm64 images are the baseline.

### 3.2 Hyper-V Generation 2

Hyper-V is Windows' type-1 hypervisor. Generation 2 VMs use UEFI, VMBus devices, VHDX storage, checkpoints, and Hyper-V Socket communication.

Why selected:

- Windows 11 Pro/Enterprise provides the required virtualization capability.
- Direct VM management gives each authorization domain a distinct guest kernel and disk.
- Differencing VHDX and checkpoints map naturally to disposable sandbox storage.
- Hyper-V Socket provides a private host/guest control path.

Important distinction:

The limited Windows client story for newer HCS LCOW v2 integration does not make Hyper-V Gen2 unavailable. Desk Box manages Hyper-V VMs directly and does not depend on LCOW for the first release.

Costs and limits:

- Requires Pro/Enterprise and enabled virtualization features.
- Platform management code differs from macOS.
- Snapshot and update behavior must be validated independently from VZ.

### 3.3 OCI Image Spec

OCI images describe a manifest, configuration, and filesystem layers. They do not define a security boundary.

Why selected:

- Broad compatibility with Dockerfiles, registries, and existing developer tooling.
- Content-addressed digests and multi-platform indexes support verification and caching.
- Runtime-neutral packaging allows Desk Box to own its security policy.

Desk Box rejects image requests for privileged execution, host namespaces, host devices, arbitrary mounts, runtime sockets, and policy replacement. Image metadata is input, not authority.

### 3.4 BuildKit in an isolated builder VM

BuildKit converts Dockerfiles and frontends into an LLB build graph executed by workers with snapshot and cache management.

Why selected:

- Best compatibility with modern Dockerfile behavior and build caching.
- A dedicated builder VM contains malicious `RUN` steps and build tools.
- The resulting boundary is understandable: only OCI artifacts cross back to the host.

Why not run BuildKit on the host:

- Dockerfile build steps execute arbitrary code.
- Host-side workers and sockets create an unnecessarily large trusted surface.
- Build secrets, caches, and workspaces could otherwise cross authorization domains.

### 3.5 containerd and runc inside the guest

Containerd manages image content, snapshots, and tasks. Runc/libcontainer realizes OCI process specifications using Linux namespaces, cgroups, capability controls, and seccomp.

Why selected:

- Mature OCI compatibility and a clear replacement path if the implementation is later reduced.
- They run behind the VM boundary, so a container escape remains inside the sandbox VM.
- Existing images and developer tools behave as expected.

Why guest-only:

- A host container daemon would become a high-value privileged API.
- Runc containers share a kernel and cannot separate distinct credential authorization domains by themselves.
- The containerd socket remains inaccessible to workload containers and the host UI.

### 3.6 OpenSandbox execd fork

Execd is a Go daemon implementing command execution, background logs, PTY, files, sessions, and metrics through HTTP, SSE, and WebSocket interfaces.

Why selected over E2B envd or immediate greenfield development:

- Its capability surface most closely matches the required desktop-agent workflows.
- Direct argv and shell execution, PTY, file operations, process supervision, and metrics are already coherent.
- Apache-2.0 permits a maintained product fork.
- Its protocol is easier to place behind a private transport adapter than adopting an entire cloud control plane.

Required fork boundaries:

- Pin an audited upstream release; never track `main` in production.
- Remove Jupyter, generic reverse proxy, and unused high-authority APIs.
- Scope filesystem operations to product-managed roots.
- Require authenticated bootstrap and short-lived per-VM tokens.
- Maintain an upstream provenance file, patch series, SBOM, and reproducible build.

## 4. Projects used as references

### 4.1 Kata Containers

Kata's typical path is containerd shim v2 to `virtcontainers`, a VMM, an independent Linux guest, and `kata-agent` over vsock. It demonstrates the correct separation between container-manager semantics and a VM security boundary.

What is retained:

- One VM as the sandbox boundary.
- Host controller versus guest agent separation.
- OCI workloads inside an independent guest kernel.
- Private host/guest RPC and explicit lifecycle state.

Why the runtime is not adopted:

- Its main production environment is Linux/KVM and Kubernetes/containerd.
- It does not provide supported VZ and desktop Hyper-V backends.
- Porting hypervisor, storage, networking, and lifecycle assumptions would create a large permanent fork.
- Desk Box needs desktop UX and host credential brokering rather than CRI integration.

### 4.2 OpenSandbox control plane, SDKs, and MCP

OpenSandbox provides a FastAPI lifecycle server, Docker and Kubernetes runtime services, an external FastSandbox path, OpenAPI specifications, SDKs, CLI, MCP, execd, and egress components.

What is retained:

- Lifecycle resource semantics and structured status.
- The split between control plane and in-sandbox execution plane.
- OpenAPI-driven client generation plus handwritten streaming adapters.
- MCP tools as a thin capability surface.
- Credential binding semantics: exact host/method/path matching, write-only responses, ambiguity rejection, and fail-closed handling.

Why the full platform is not adopted:

- The local runtime controls a Docker daemon; the cluster runtime assumes Kubernetes resources.
- FastSandbox is an external Kubernetes/Firecracker platform, not a VZ or desktop Hyper-V backend.
- The lifecycle specification is still evolving and includes cluster/provider concepts that should not become desktop API commitments.
- The Python server, databases, CRDs, ingress, and operators add privileges and deployment complexity without solving native desktop VM lifecycle.

### 4.3 Docker Desktop

Docker Desktop commonly runs Linux containers in a shared Linux VM and exposes a broad Docker API.

What it proves:

- A desktop product can package Linux virtualization, image management, networking, and container execution.
- OCI developer workflows can be usable on macOS and Windows.

Why it is not a dependency:

- A shared VM is not an isolation boundary between credential domains.
- A Docker daemon API and socket expose far more authority than Desk Box requires.
- Product licensing, updates, VM topology, and security policy would be outside Desk Box control.
- Docker Desktop availability cannot be assumed for end users.

### 4.4 E2B

E2B combines a cloud control plane, Firecracker microVMs, environment daemon, storage/snapshot infrastructure, and SDK-facing sandbox APIs.

What is retained:

- Agent-friendly execution and file workflows.
- Fast disposable environment expectations.
- Snapshot and warm-start scenarios to benchmark.
- `envd` as a behavior and compatibility comparison.

Why E2B/envd is not the primary implementation:

- Its strongest value is tied to a Linux/KVM cloud architecture.
- Firecracker and cloud orchestration do not map to VZ or Hyper-V.
- Adopting the complete path would require recreating or embedding infrastructure not needed on one desktop.
- Execd currently matches the selected contract and OpenAPI ecosystem more closely.

### 4.5 Firecracker

Firecracker is a Linux/KVM VMM with a deliberately small device model for high-density microVMs.

What is retained:

- Minimal device surface.
- Disposable root disks and template-based startup.
- Strict separation of host services from guest workloads.

Why it is not adopted:

- It requires Linux/KVM and does not provide VZ or Hyper-V backends.
- Running a Linux VMM host layer on desktop would duplicate the native hypervisor and complicate distribution.

## 5. Deferred and rejected options

### 5.1 gVisor: deferred secondary isolation

GVisor's `runsc` presents OCI runtime behavior while its Sentry user-space kernel implements many Linux syscalls. Systrap relies on Linux process and seccomp mechanisms; Gofer mediates filesystem access.

Potential future use: selected native Linux tasks inside an existing Desk Box VM.

Why deferred:

- It does not replace the cross-platform outer VM.
- Syscall and filesystem compatibility require workload-specific testing.
- It adds another runtime, update stream, and diagnostic layer.
- The first release gains more security value by completing the host broker and VM isolation tests.

### 5.2 Wasmer/WASI: deferred Wasm profile

Wasmer runs WebAssembly modules; WASI exposes selected host capabilities rather than a general Linux process environment.

Potential future use: reviewed and recompiled Wasm-only plugins or MCP tools.

Why deferred:

- It cannot run arbitrary OCI Linux applications such as Claude Code or native toolchains.
- It introduces a separate packaging and compatibility model.
- Its capability model is valuable only after the core plugin product surface is defined.

### 5.3 WSL2: rejected as strong isolation

WSL distributions share the WSL utility VM kernel, and the local user can enter and alter the environment. It does not provide one independently controlled guest kernel per authorization domain.

It may later support a clearly labelled lower-assurance Windows Home mode, but it cannot inherit the `VM-backed Sandbox` claim.

### 5.4 QEMU: diagnostic fallback

QEMU can use HVF on macOS and WHPX on Windows, giving a more uniform VMM interface.

Why it is not the default:

- Larger device-model attack and maintenance surface.
- Additional packaging, signing, update, and license obligations.
- Weaker integration with native desktop lifecycle and diagnostics.

It is reconsidered only if a required and security-relevant VZ or Hyper-V capability is proven unavailable.

## 6. Decision consequences

Benefits:

- The security claim is based on a concrete, independently testable guest-kernel boundary.
- OCI compatibility does not require a host Docker daemon.
- Host credentials remain outside the untrusted VM.
- macOS and Windows share contracts and guest behavior while using supported native hypervisors.
- Upstream projects are reused at narrow, auditable interfaces.

Costs:

- Two host platform adapters must be implemented and maintained.
- Desk Box owns image verification, workspace synchronization, broker policy, and secure bootstrap.
- The execd fork requires an upstream patch and vulnerability-management process.
- VM density is lower than a shared-container-only design.

These costs are accepted because they directly implement the primary security and user-experience requirements rather than optimizing a cloud deployment model that the product does not have.
