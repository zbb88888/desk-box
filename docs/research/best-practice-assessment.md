# Best-Practice Assessment

Status: Architecture assurance argument
Date: 2026-10-23

## 1. Conclusion

The selected architecture is the best-practice fit for the stated desktop threat model, not a claim that it is universally optimal.

It follows established security principles by using a hardware-backed VM as the boundary for malicious native code, separating build and runtime trust domains, keeping long-lived credentials in the host credential store, using default-deny capabilities, minimizing privileged APIs, pinning upstream components, and defining release-blocking adversarial tests.

It deliberately does not copy common cloud-sandbox designs when their assumptions conflict with a desktop product. Kubernetes, Firecracker, a shared Docker VM, and sidecar-held credentials solve different deployment problems.

## 2. Best-practice criteria

### 2.1 The boundary matches the attacker

Principle: an attacker with arbitrary native-code execution and guest root should not share the host kernel or another credential domain's kernel.

Assessment: satisfied.

Desk Box uses a dedicated Linux VM per authorization domain. Container isolation remains inside the VM and is not advertised as the host boundary. This is consistent with the isolation model used by VM-backed container systems while avoiding a Linux/KVM-only implementation.

Alternative rejected: plain runc, hardened containers, or WSL2 as the strong mode. These share a kernel at the relevant boundary and cannot support the same claim.

### 2.2 Least privilege and capability orientation

Principle: grant only the authority required for a specific operation and bind it to identity, scope, and time.

Assessment: satisfied by design, pending implementation evidence.

`WorkloadSpec` is allowlist based. `CredentialGrant` binds a credential use to workspace, sandbox, agent, destination, operation, and expiry. MCP tools map to fixed capabilities rather than exposing raw runtime APIs.

Implementation requirement: there must be no provider-specific escape hatch or opaque extension that bypasses these types.

### 2.3 Secrets remain outside the untrusted domain

Principle: do not solve secret exfiltration by placing a reusable secret beside hostile code and attempting to hide it.

Assessment: stronger than the referenced OpenSandbox sidecar model.

Long-lived credentials remain in Keychain or Credential Manager and are inserted by the host broker into an approved outbound request. The guest receives no reusable secret. This reduces exposure through environment inspection, process memory, files, logs, snapshots, and prompt injection.

Limitation: the approved upstream necessarily receives the credential. Exact destination and request binding, redirect revalidation, TLS validation, rotation, and upstream account scoping remain essential.

### 2.4 Default deny and fail closed

Principle: absence, ambiguity, or failure of a security decision must not produce ambient access.

Assessment: satisfied in the architecture contract.

- No network grant means no outbound network.
- Failed destination classification denies the request.
- Failed guest authentication prevents readiness.
- Failed cleanup remains visible and does not report success.
- Unsupported protocol versions reject instead of downgrading.
- Missing runtime enforcement prevents workload startup.

Implementation requirement: fault-injection tests must prove these behaviors rather than relying on configuration review.

### 2.5 Separate build from runtime

Principle: build scripts execute arbitrary code and should not inherit production authority.

Assessment: satisfied.

BuildKit runs in a distinct short-lived VM with separate COW storage, network grants, and build-scoped secrets. Runtime VM disks and production broker capabilities are not mounted into the builder.

Alternative rejected: host BuildKit or a shared privileged Docker daemon. Both expand the trusted computing base and create cross-project state.

### 2.6 Minimize and mediate host interfaces

Principle: the host/guest interface should be narrow, authenticated, versioned, and policy enforcing.

Assessment: satisfied in the design.

The product exposes lifecycle, execution, scoped file transfer, endpoint resolution, and brokered outbound requests. It does not expose hypervisor management, Docker APIs, containerd sockets, arbitrary host mounts, or device passthrough.

The control channel is private to VZ Socket or Hyper-V Socket and binds VM identity, sandbox ID, boot nonce, version, and short-lived token.

### 2.7 Prefer supported native platform primitives

Principle: use platform-supported security mechanisms when they meet requirements; avoid maintaining unnecessary virtualization forks.

Assessment: satisfied.

VZ and Hyper-V are supported native hypervisors. Kata and Firecracker inform the layering, but porting their Linux/KVM assumptions to two desktop hypervisors would create a large security-sensitive fork. QEMU remains a fallback only if a required native capability is absent.

Trade-off: platform adapters are different implementations and require parity tests.

### 2.8 Supply-chain control

Principle: know exactly what privileged code is shipped, where it came from, and how it is updated.

Assessment: defined, not yet evidenced.

Required controls:

- pinned releases and digests;
- license and NOTICE retention;
- SBOM and dependency vulnerability review;
- signed guest assets and updates;
- reproducible or independently verifiable builds where practical;
- documented execd fork patches;
- no production dependency on upstream `main` branches;
- rollback and downgrade protection.

### 2.9 Secure-by-default user experience

Principle: users should not need infrastructure expertise to obtain the safe configuration.

Assessment: satisfied in product design.

The default creates a VM, private workspace copy, no internet, no host mounts, no reusable credentials, and bounded resources. Prompts describe user intent rather than CIDRs, capabilities, sidecars, or RuntimeClass.

Advanced controls must not silently weaken the product's `Sandbox` label. Lower-assurance modes require distinct naming and explicit consent.

### 2.10 Verifiable claims

Principle: architecture claims require executable evidence.

Assessment: strong planned evidence.

Each security invariant has corresponding cross-platform tests. Canary secrets, path races, network rebinding, token replay, VM lifecycle faults, malicious OCI layers, and resource exhaustion are release gates.

Performance is measured only after the security gates pass, preventing startup-time targets from silently removing controls.

## 3. Comparison with common alternatives

| Alternative | Attractive property | Why it is not best practice for this product |
| --- | --- | --- |
| Shared Docker VM | Mature UX and high density | Shares the VM kernel across authorization domains and exposes a broad daemon API |
| Plain containers | Fast startup and low memory | Host-kernel attack surface is the principal boundary for malicious native code |
| WSL2 | Available Windows Linux environment | Shared utility VM and user-controlled distribution do not support independently managed sandbox identity |
| Kata runtime port | Existing VM-container integration | Unsupported VZ/desktop Hyper-V path would create a major long-lived fork |
| Firecracker everywhere | Small cloud microVM VMM | Linux/KVM only; adding another host layer defeats native desktop integration |
| OpenSandbox full stack | APIs, SDKs, execd, egress | Docker/Kubernetes control plane does not provide desktop VM lifecycle and adds unnecessary privileges |
| Credential sidecar with MITM | Existing tools work with fake keys | Secret exists beside the workload trust domain; CA, nftables, restart, and snapshot semantics add complexity |
| Wasm-only runtime | Excellent capability model | Cannot run general OCI Linux tools and agents required by the product |

## 4. Areas where the design is intentionally conservative

- Per-domain VMs use more memory than one shared VM.
- Workspaces are copied or synchronized instead of live-mounted by default.
- General network access is denied instead of monitored best effort.
- Docker compatibility stops at images and Dockerfiles, not the daemon API.
- The project owns a small execd fork instead of importing an entire control plane.
- Cross-architecture emulation is explicit rather than automatic.

These choices are appropriate because safety is the first product priority and user friendliness is the second. The UI should absorb the complexity rather than weakening the boundary.

## 5. Residual risks

The architecture cannot eliminate:

- VZ, Hyper-V, host-kernel, firmware, or hardware vulnerabilities;
- malicious behavior by an authorized upstream service;
- sensitive user data intentionally imported into the workspace;
- data embedded by applications in their own guest state;
- supply-chain compromise signed by a trusted publisher;
- resource contention below hypervisor accounting granularity;
- implementation errors in the host broker or platform adapters.

Mitigations include supported OS minimums, rapid guest and dependency updates, narrow broker code, signed assets, defense-in-depth guest policy, audit logs, fuzzing, fault injection, and an incident-response process.

## 6. Evidence required before calling the implementation best practice

Architecture review alone is insufficient. The label is justified only after:

1. VZ and Hyper-V security invariants pass the same conformance suite.
2. Canary secrets are absent from guest environment, disk, logs, snapshots, and crash artifacts.
3. Network bypass tests cover IPv4, IPv6, DNS rebinding, redirects, direct IP, proxies, DoH/ECH policy, private ranges, and metadata endpoints.
4. OCI extraction is fuzzed and tested against traversal, links, devices, quotas, and decompression abuse.
5. Host/guest bootstrap resists replay, downgrade, cross-VM use, restart, and clock manipulation.
6. Destroy and crash recovery prove there are no recoverable COW disks, snapshots, grants, or orphaned VMs.
7. Execd fork scope, patch history, dependency inventory, and update process are documented and reproducible.
8. Independent review covers the host broker, workspace path handling, and platform adapters.

Until those checks pass, the design should be described as following best practices, not as a verified secure implementation.
