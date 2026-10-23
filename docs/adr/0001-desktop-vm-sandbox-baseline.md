# ADR-0001: Desktop VM Sandbox Baseline

- Status: Accepted
- Date: 2026-10-23
- Decision owners: Desk Box maintainers

## Context

Desk Box must run AI coding agents, arbitrary repositories, dependencies, Dockerfile build steps, and MCP tools that may be malicious. Security is the primary goal; the product must also remain usable by people who should not need to configure container or cluster infrastructure.

The target platforms are Apple Silicon macOS and Windows 11 Pro/Enterprise. The product must support OCI images and Dockerfiles while keeping long-lived credentials outside the sandbox.

No single reviewed project supplies all of these requirements across both desktop platforms:

- Kata Containers provides the right VM-backed layering but targets Linux/KVM and cluster/containerd environments.
- Firecracker and E2B target Linux/KVM cloud hosts.
- Docker Desktop uses a broad Docker API and commonly a shared Linux VM.
- OpenSandbox provides useful protocols and data-plane components, but its runtimes are Docker, Kubernetes, and an external FastSandbox integration.
- WSL2 does not provide a separately managed guest kernel per authorization domain.

## Decision

Desk Box will implement a Kata-like architecture using native desktop hypervisors:

- Apple `Virtualization.framework` on Apple Silicon macOS;
- Hyper-V Generation 2 on Windows 11 Pro/Enterprise;
- one VM per workspace and credential authorization domain by default;
- one VM per agent in high-assurance mode;
- OCI Image Spec as the workload package format;
- BuildKit in a separate short-lived builder VM;
- containerd and runc inside the sandbox VM;
- a pinned, minimal OpenSandbox execd fork as the guest execution API;
- a Desk Box-owned, versioned desktop lifecycle contract;
- a trusted host credential/network broker backed by Keychain or Credential Manager;
- no host Docker daemon, Kubernetes, host bind mounts, or reusable guest credentials.

The VM is the only strong isolation boundary in the first release. Container and Wasm technologies may provide defense in depth but do not alter the product assurance level.

## Alternatives considered

### Adopt Kata Containers directly

Rejected because there is no supported VZ or desktop Hyper-V backend. A port would include hypervisor, networking, storage, guest-agent, and lifecycle changes in a large permanent security-sensitive fork.

### Adopt OpenSandbox completely

Rejected because its control plane delegates to Docker, Kubernetes, or external FastSandbox infrastructure. These do not implement the required desktop VM boundary. Execd and selected contract semantics are adopted separately.

### Adopt E2B and Firecracker

Rejected because Firecracker requires Linux/KVM and E2B's orchestration, storage, and snapshot architecture is cloud oriented. Its behavior remains useful for benchmarking.

### Depend on Docker Desktop

Rejected because availability and licensing cannot be assumed, the daemon API is overpowered, and a shared VM does not isolate credential domains.

### Use WSL2 on Windows

Rejected for strong mode because WSL distributions share the utility VM kernel and remain user-controlled. It may be revisited only as a separately labelled lower-assurance mode.

### Use QEMU on both platforms

Rejected as the default because native APIs reduce device-model, packaging, signing, and update burden. QEMU remains a diagnostic fallback if a required native capability is missing.

### Use gVisor or Wasmer as the primary runtime

Rejected because gVisor is Linux-specific secondary syscall isolation and Wasmer cannot run general OCI Linux workloads. Both may become optional profiles after the baseline is complete.

## Consequences

Positive:

- Security claims map to an independent guest kernel and host-enforced policy.
- OCI and Dockerfile compatibility do not require a host daemon.
- Long-lived credentials remain outside hostile code and VM snapshots.
- The product can present intent-oriented permissions.
- Upstream code enters through narrow, auditable boundaries.

Negative:

- Two platform adapters and parity tests are required.
- VM startup and memory cost exceed a shared-container design.
- Desk Box owns secure OCI extraction, workspace synchronization, authenticated guest bootstrap, broker policy, and cleanup reconciliation.
- The execd fork requires continuous upstream and vulnerability maintenance.

## Constraints

- No silent fallback from VM-backed mode to containers, WSL2, or host execution.
- No cross-authorization-domain VM sharing.
- No long-lived secret in guest environment, files, logs, memory snapshots, or sidecars.
- No opaque extension field may bypass `WorkloadSpec` or `CredentialGrant` validation.
- Security conformance failures block release regardless of performance targets.

## Validation

The decision is reconsidered if a proof-of-concept shows that VZ or direct Hyper-V cannot provide a required isolation, storage, lifecycle, or private-channel capability. Any replacement must preserve the threat model and pass the same cross-platform security suite.

Implementation evidence is tracked through the threat-model release gates and architecture delivery phases.
