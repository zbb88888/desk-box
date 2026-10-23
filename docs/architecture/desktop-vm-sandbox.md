# Desktop VM Sandbox Architecture

Status: Proposed baseline
Date: 2026-10-23

## 1. Executive decision

Desk Box uses OCI images as the workload format and a dedicated Linux virtual machine as the security boundary.

- macOS on Apple Silicon uses Apple `Virtualization.framework`.
- Windows 11 Pro/Enterprise uses a Hyper-V Generation 2 Linux VM.
- The default isolation unit is one VM per workspace and credential authorization domain.
- High-assurance mode uses one VM per agent.
- The guest uses `containerd` and `runc` for OCI compatibility. They are not treated as the host security boundary.
- A pinned, minimal fork of OpenSandbox `execd` provides command, PTY, file, session, and metrics APIs.
- Long-lived credentials remain in macOS Keychain or Windows Credential Manager. A trusted host broker injects credentials only into approved outbound requests.
- Docker Desktop, Kubernetes, WSL2, and a host Docker daemon are not product dependencies.

This is a Kata-like architecture, not a port of Kata Containers. It preserves the useful split between host controller, VM, guest agent, and OCI workload while using the native desktop hypervisor on each platform.

## 2. Goals

1. Run Claude Code, Codex, dsh, MCP servers, build scripts, browsers, and ordinary development tools when the workload may be malicious.
2. Prevent the workload from reading host files, long-lived credentials, other workspaces, or host service sockets.
3. Support OCI images and Dockerfiles without exposing a Docker daemon API.
4. Present user-oriented permissions instead of Kubernetes, networking, or container-runtime configuration.
5. Keep macOS and Windows behavior consistent behind a common lifecycle and execution contract.
6. Make every security claim testable and fail closed when a required control is unavailable.

## 3. Non-goals for the first release

- Protecting against a compromised host administrator, hypervisor zero-day, firmware attack, or hardware side channel.
- Windows Home, Intel Mac, or Linux host productization.
- Docker Compose, Kubernetes, privileged workloads, arbitrary devices, or host bind mounts.
- Full Docker API or `docker.sock` compatibility.
- Jupyter or a hosted code-interpreter platform.
- Transparent support for every Linux image architecture through emulation.
- gVisor or Wasmer in the default execution path.

## 4. Trust boundaries

```text
Untrusted                                             Trusted

OCI image / agent / dependency
        |
        v
+---------------- Sandbox VM ----------------+        +---------------- Host ----------------+
| independent Linux guest kernel             |        | Desktop UI / CLI                     |
|                                             |        |                                      |
| execd fork <-> containerd <-> runc          |<------>| Sandbox Controller                   |
|                       |                     | socket | OCI Image Service                    |
|                       v                     |        | Workspace Sync                       |
|                  OCI workload              |        | Credential + Network Broker          |
|                                             |        | Keychain / Credential Manager        |
| private COW disk, default-deny network      |        | Audit log                            |
+---------------------------------------------+        +--------------------------------------+
```

The VM boundary supplies the product's strong isolation claim. Namespaces, cgroups, seccomp, `runc`, `execd`, and MCP are defense-in-depth or compatibility components and do not upgrade the security level.

## 5. Host components

### 5.1 Desktop UI and CLI

The UI exposes intent-level actions:

- Allow this task to read or modify a selected workspace.
- Allow access to a selected repository.
- Allow calls to a named model or API service.
- Allow internet access for this task.
- Keep or discard the sandbox after completion.

It does not require users to configure images, entrypoints, sidecars, RuntimeClass, CIDRs, or credentials manually. Advanced image selection remains available behind a separate developer surface.

### 5.2 Sandbox Controller

The controller owns a versioned `SandboxRuntime` interface:

- `create`
- `start`
- `stop`
- `suspend`
- `resume`
- `destroy`
- `inspect`
- `resolveEndpoint`

It enforces CPU, memory, disk, runtime duration, process, and endpoint limits before invoking a platform adapter. Provider-specific settings never pass directly from an untrusted API request into VZ or Hyper-V.

Sandbox state is explicit: `Pending`, `Running`, `Suspending`, `Suspended`, `Resuming`, `Stopping`, `Stopped`, and `Failed`. Every transition records a stable reason code and timestamp.

### 5.3 Platform adapters

#### macOS adapter

The macOS adapter uses `Virtualization.framework` to start a signed Linux arm64 kernel, initrd, and root disk. It provides:

- read-only base disk plus per-sandbox copy-on-write storage;
- virtio block, entropy, memory balloon, and network devices;
- VZ socket for the private control channel;
- host-enforced CPU and memory configuration;
- serial diagnostics unavailable to the workload;
- suspend/resume only after state and secret handling pass validation.

Host directories are copied or synchronized into the private guest disk. `virtiofs` is not the default workspace data path because a live host mount expands the authority available to a compromised guest.

#### Windows adapter

The Windows adapter directly manages a Hyper-V Generation 2 Linux VM through supported Hyper-V management interfaces. It provides:

- signed Generation 2 boot assets and Secure Boot where the selected Linux template supports it;
- read-only base VHDX plus a per-sandbox differencing VHDX;
- Hyper-V Socket for the private control channel;
- checkpoints only under the product's secret and lifecycle policy;
- host-enforced processor, memory, disk, and lifetime limits.

This design does not depend on HCS LCOW v2. LCOW client availability and direct Hyper-V VM management are separate questions; Windows 11 Pro/Enterprise can provide the latter.

### 5.4 OCI Image Service

The host image service performs:

1. Registry resolution and authentication.
2. Manifest-list selection for `linux/arm64` or `linux/amd64`.
3. Digest pinning and optional signature/provenance policy.
4. Content-addressed blob caching.
5. Size, file-count, path, symlink, hard-link, device-node, and decompression-ratio checks.
6. Translation from OCI config into a restricted internal `WorkloadSpec`.
7. Garbage collection that understands active COW and snapshot references.

`WorkloadSpec` is allowlist based. It carries entrypoint, arguments, controlled environment, working directory, declared service ports, and resource hints. It cannot request host namespaces, host devices, arbitrary mounts, additional capabilities, policy replacement, or runtime sockets.

### 5.5 Builder Service

Dockerfiles are built by BuildKit inside a short-lived builder VM with its own disk, network policy, and identity.

- The builder cannot access runtime VM disks, host workspaces unless explicitly imported, or production broker credentials.
- Build secrets are explicit, short lived, and scoped to one build operation.
- The host imports only the resulting OCI artifacts by digest.
- Build cache is content addressed and treated as untrusted input when reused.
- Builder destruction removes its COW disk and transient capabilities.

### 5.6 Workspace Sync

Workspace access is explicit and path scoped. The default flow imports selected files into a private guest volume and exports approved changes after policy checks.

Path handling uses descriptor-relative operations where available and defends against traversal, symlink replacement, hard-link aliasing, case-folding differences, alternate data streams, and time-of-check/time-of-use races. Host home directories, SSH configuration, cloud credential directories, and Docker configuration are never imported implicitly.

### 5.7 Credential and Network Broker

Long-lived secrets are fetched on demand from Keychain or Credential Manager. A `CredentialGrant` binds a secret use to:

- workspace and sandbox identity;
- agent identity;
- scheme, host, port, method, and path;
- injection type, such as bearer or named API header;
- issuance and expiry time;
- optional request count or rate limit.

The guest receives an empty or fake value if a tool requires an environment variable to start. The trusted host proxy inserts the real credential only after resolving and validating the final destination.

Outbound traffic is default deny. The broker blocks loopback, private, link-local, multicast, and cloud metadata destinations; revalidates every redirect; pins authorization to the resolved request rather than only the original hostname; and rejects a request when DNS, TLS, proxy, or policy state is ambiguous. DoH and ECH require an explicit product policy because they can prevent destination inspection.

The broker never logs secret-bearing headers or bodies. Audit records store the grant identifier, destination, decision, timing, and byte counts.

### 5.8 MCP Gateway

The trusted host MCP gateway maps a small set of tools to desktop capabilities. It does not expose raw hypervisor, image, mount, or network configuration.

- MCP servers requiring long-lived credentials run on the host side of the broker.
- Pure computation MCP servers may run as guest OCI workloads.
- Each tool invocation is bound to the current sandbox and user grant.
- A guest cannot register new host capabilities without an explicit user action.

## 6. Guest components

### 6.1 Minimal Linux image

The guest image contains only the kernel, init, required virtio/VMBus drivers, `containerd`, `runc`, the forked `execd`, networking bootstrap, update verification, and diagnostics required by the host controller. There is no SSH server and no general management account.

Guest assets are versioned and signed. Host and guest negotiate a protocol version before workload startup. Unsupported or downgraded versions fail closed.

### 6.2 containerd and runc

`containerd` manages content, snapshots, and task lifecycle inside the guest. `runc` creates workload processes with Linux namespaces, cgroups, capability dropping, `no_new_privs`, and a fixed seccomp policy.

The containerd socket remains inside the guest and is reachable only by the trusted guest control process. Workload containers do not receive it. Containers sharing one VM must belong to the same credential authorization domain because they share the guest kernel.

### 6.3 Execd fork

The initial fork keeps:

- direct argv and explicit shell command execution;
- foreground SSE and background execution with bounded log retention;
- PTY creation, resize, attach, and disconnect handling;
- scoped file upload, download, metadata, move, and removal;
- signals, sessions, process status, and CPU/memory metrics;
- init behavior, signal forwarding, and orphan reaping.

The initial fork removes or disables:

- Jupyter and code-interpreter contexts;
- arbitrary reverse proxying to all guest ports;
- unused isolated-session modes;
- unrestricted whole-filesystem access;
- unauthenticated business endpoints.

The host transports execd traffic over VZ Socket or Hyper-V Socket. Bootstrap uses a one-time challenge tied to the VM identity, sandbox ID, boot nonce, protocol version, and expected guest asset digest. Session tokens are short lived, rotatable, and unusable across VMs.

## 7. Lifecycle flows

### 7.1 Create and run

1. UI resolves user intent into a `SandboxRequest` and capabilities.
2. Controller validates limits and selects the platform adapter.
3. OCI Service resolves and validates the requested image.
4. Adapter creates COW storage and starts the VM.
5. Host and guest complete authenticated bootstrap.
6. Guest containerd starts the restricted `WorkloadSpec` through runc.
7. Execd reports readiness; only then does the controller publish `Running`.

### 7.2 Suspend and resume

Before suspend, the controller revokes active network grants and ensures no long-lived secret exists in guest memory by construction. Platform snapshots are encrypted and bound to the sandbox identity and guest asset version. Resume creates new short-lived channel credentials and revalidates all grants; it never restores an expired capability.

### 7.3 Destroy

Destroy revokes grants first, stops control channels, terminates the VM, removes COW and snapshot references, and records completion only after cleanup succeeds. Failure remains visible as `Failed` or `Stopping`; it is not reported as destroyed optimistically.

## 8. Versioning and upstream policy

- The desktop lifecycle contract is owned and versioned by Desk Box.
- OpenSandbox specifications are semantic references, not dynamically consumed contracts.
- The execd fork is pinned to an audited upstream release.
- Upgrades require license review, dependency and SBOM comparison, patch rebase, API diff, and security regression tests.
- No component follows an upstream `main` branch in production.

## 9. Delivery phases

### Phase 1: contracts and threat model

Freeze `SandboxRuntime`, `WorkloadSpec`, lifecycle resources, `CredentialGrant`, audit events, state transitions, and security rejection cases.

### Phase 2: macOS vertical slice

Implement OCI pull, one VZ VM, authenticated socket transport, execd command execution, private workspace import, and deterministic destroy. No general network access.

### Phase 3: broker and Dockerfile builds

Add the host network/credential broker and an isolated BuildKit builder VM. Validate Claude Code, Codex, Git, and package-manager workflows with canary credentials.

### Phase 4: Windows parity

Implement Hyper-V Gen2, differencing VHDX, Hyper-V Socket, equivalent lifecycle behavior, and the same guest image/contract where architecture permits.

### Phase 5: hardening and UX

Complete suspend/resume, crash recovery, update rollback, capability prompts, auditing, concurrency limits, and adversarial testing.

## 10. Release gates

A release is blocked if any test can:

- read a host secret or non-imported host file;
- access another workspace or sandbox control channel;
- reach a Docker/containerd socket outside its allowed guest scope;
- reach an unauthorized internet, private, loopback, link-local, or metadata destination;
- reuse a capability across sandbox identity, reboot, expiry, or revocation;
- escape safe OCI extraction through path, link, device, or resource abuse;
- recover destroyed COW, token, build secret, or snapshot data;
- cause the broker or guest transport to fail open.

Performance targets are set only after these gates pass. Security properties are not relaxed to meet startup or density goals.
