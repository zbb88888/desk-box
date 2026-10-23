# Threat Model and Security Invariants

Status: Required release contract
Date: 2026-10-23

## 1. Protected assets

Desk Box protects:

- macOS Keychain and Windows Credential Manager entries;
- host files outside explicitly imported workspace paths;
- other workspaces and sandbox disks;
- SSH, Git, cloud, registry, model-provider, and MCP credentials;
- host services, sockets, local applications, loopback endpoints, and metadata services;
- product update keys, guest image signing keys, audit integrity, and policy configuration;
- user identity and capability grants;
- availability of the host within configured resource limits.

## 2. Adversaries

The following are untrusted and may cooperate:

- the agent running in the sandbox;
- OCI images and their entrypoints;
- source repositories, generated code, tests, and build scripts;
- package-manager dependencies and post-install scripts;
- MCP servers and tool responses;
- browser content, prompt injection, and downloaded artifacts;
- Dockerfiles and BuildKit frontend/build steps;
- a previously compromised or stale sandbox disk or snapshot.

The adversary may obtain root inside the guest and may deliberately exercise kernel, runtime, parser, protocol, resource-exhaustion, and confused-deputy paths.

## 3. Out-of-scope adversaries

The first release does not claim protection against:

- a compromised host administrator or the user intentionally disabling controls;
- a hypervisor, host kernel, firmware, or hardware zero-day;
- physical attacks against an unlocked machine;
- hardware side channels between host workloads;
- malicious code signed by the Desk Box release authority.

Out of scope does not mean ignored: supported OS versions, signed updates, minimum hardware requirements, and incident response reduce these risks, but they are not sandbox guarantees.

## 4. Security invariants

### I-1: Independent kernel boundary

Every strong-mode sandbox runs in a dedicated VM assigned to one workspace and credential authorization domain. Distinct domains never rely only on containers sharing one guest kernel.

Evidence:

- platform VM inventory and identity tests;
- cross-VM memory, disk, socket, and endpoint denial tests;
- configuration tests proving no fallback to WSL2 or host processes.

### I-2: No ambient host filesystem authority

The guest cannot browse or mount host files. Only explicitly selected workspace content crosses through Workspace Sync. Host home, credential, SSH, cloud, and Docker directories are excluded by policy.

Evidence:

- malicious path, symlink, hard-link, alternate stream, case-folding, and race tests;
- host canary files placed inside and outside approved roots;
- verification that default VM configuration contains no shared host filesystem.

### I-3: No host daemon or device authority

The guest and workload cannot access host Docker/containerd sockets, hypervisor control APIs, arbitrary devices, or management endpoints. Guest containerd is private to trusted guest control processes.

Evidence:

- socket and device enumeration from guest root;
- blocked attempts to create privileged containers or extra mounts;
- host firewall and endpoint inventory tests.

### I-4: Long-lived credentials never enter the guest

Long-lived secrets remain in Keychain or Credential Manager. They are absent from guest environment variables, command arguments, files, process memory under normal operation, logs, snapshots, and crash dumps.

Evidence:

- unique canary credentials and scans of all guest storage and diagnostic artifacts;
- request capture proving insertion occurs in the host proxy;
- suspend/resume, crash, retry, and broker-restart tests.

### I-5: Capabilities are narrow, short-lived, and identity-bound

Every privileged operation is authorized for a specific user, workspace, sandbox, agent, action, and expiry. A grant cannot be replayed across VM identity, boot nonce, protocol version, restart, or revocation.

Evidence:

- cross-sandbox and stale-token replay suites;
- clock-skew and concurrent-use tests;
- audit correlation from grant creation through use and revocation.

### I-6: Network is default deny

A sandbox without explicit network grants cannot reach the internet, host, local network, loopback services, link-local services, or cloud metadata. Redirects and re-resolution never widen an existing grant.

Evidence:

- IPv4/IPv6, DNS rebinding, direct-IP, alternate-port, redirect, proxy, DoH, ECH, and metadata test matrices;
- broker and resolver failure injection;
- proof that a failed policy component blocks rather than forwards.

### I-7: OCI input has no policy authority

Image configuration cannot request host namespaces, privileged execution, devices, arbitrary mounts, additional capabilities, daemon sockets, or replacement security profiles. Unsafe filesystem layers are rejected before use.

Evidence:

- adversarial manifests and configs;
- path traversal, absolute path, symlink, hard-link, device-node, sparse-file, decompression-bomb, and quota tests;
- comparison of resulting `WorkloadSpec` against an allowlist.

### I-8: Resource limits are enforced outside the workload

CPU, memory, disk, VM count, process count, runtime duration, log volume, and network volume have host-enforced ceilings. Guest root cannot raise them.

Evidence:

- CPU, memory, fork, disk, log, and network exhaustion tests;
- host responsiveness and cleanup assertions;
- policy mutation attempts from guest root.

### I-9: Lifecycle and cleanup are fail closed

A sandbox is not marked ready before authenticated guest readiness. It is not marked destroyed before capabilities are revoked and storage cleanup completes. Ambiguous state remains visible and cannot silently regain authority.

Evidence:

- process kill and host reboot at every lifecycle transition;
- disk-full, permission, and timeout fault injection;
- orphaned VM, COW, snapshot, and token reconciliation tests.

### I-10: Guest and update provenance is verifiable

Kernel, initrd, base disk, execd, runtime components, and product updates are versioned, signed, and measured against expected digests before authority is granted.

Evidence:

- tampered asset and rollback tests;
- signature, digest, SBOM, and patch inventory validation;
- update interruption and recovery tests.

## 5. Principal attack paths and controls

| Attack path | Primary controls | Residual risk |
| --- | --- | --- |
| Container escape | Dedicated outer VM; minimal guest; fixed runtime policy | Guest compromise; hypervisor attack remains possible |
| Malicious workspace reads host files | Copy/sync data plane; no default host mount; race-safe paths | Explicitly authorized files are visible |
| Prompt injection steals API key | Host credential broker; exact request binding; no guest secret | Authorized upstream receives the credential as intended |
| SSRF reaches host or metadata | Default deny; destination classification; redirect revalidation | New protocol forms require continuous testing |
| Image layer escapes extraction | Descriptor-relative extraction; limits; device rejection | Parser/runtime defects remain possible |
| Stolen control token crosses sandboxes | VM identity, boot nonce, short TTL, rotation | Host controller compromise is out of scope |
| Malicious Dockerfile compromises host | Separate builder VM; explicit imports and secrets | Build output itself remains untrusted |
| Snapshot recovers expired authority | Revoke before suspend; no guest long-lived secret; fresh resume tokens | Guest application state may contain user-provided sensitive data |
| Guest DoS affects host | Host VM quotas and concurrency limits | Hypervisor and storage contention require capacity planning |
| Compromised upstream dependency | Pinning, SBOM, signature/provenance checks, security regressions | Supply-chain review cannot eliminate all malicious updates |

## 6. Credential-broker rules

1. A grant identifies one logical credential without exposing its value.
2. Matching uses normalized scheme, host, effective port, method, and path.
3. Wildcards are narrow and explicit; public-suffix-wide grants are prohibited.
4. Every redirect is treated as a new authorization decision.
5. Resolution rejects loopback, private, link-local, multicast, unspecified, and metadata destinations unless a separate product feature explicitly owns them.
6. HTTP authentication is disabled by default; production credential injection requires authenticated TLS to an approved upstream.
7. Proxy or policy uncertainty denies the request.
8. Secret-bearing data is redacted before logs, metrics, traces, and errors.
9. Revocation affects new requests immediately and closes reusable connections when required.
10. The broker reads the current value from the OS credential store at use time and does not persist a shadow copy.

## 7. Workspace-sync rules

1. Access starts from an explicit user-selected root.
2. Paths are normalized for the host platform and checked using filesystem identity, not string prefix alone.
3. Traversal and links are resolved without escaping the selected root.
4. Export is a separate capability from import.
5. Deletes, executable-bit changes, and large/binary outputs can require stronger confirmation policies.
6. Sync logs identify paths and outcomes but never file contents by default.
7. Conflict handling never overwrites host data silently.

## 8. Logging and privacy

Audit events include actor, sandbox, workspace, capability, operation, destination or normalized path, decision, reason code, timestamp, and correlation ID.

Logs must not include:

- secret values or authorization headers;
- raw environment blocks;
- full request bodies by default;
- arbitrary file contents;
- session tokens, bootstrap challenges, or encryption keys.

Debug modes cannot disable redaction or network policy. Sensitive diagnostics require an explicit user export flow.

## 9. Release-blocking security tests

A release fails if any test demonstrates:

- host or cross-workspace data disclosure;
- long-lived secret material in guest artifacts;
- unauthorized host, private, metadata, or internet connectivity;
- successful token replay across VM, boot, expiry, or revocation;
- host daemon/device access;
- unsafe OCI extraction;
- resource-limit bypass that makes the host unusable;
- optimistic cleanup reporting while authority or recoverable data remains;
- fallback from VM mode to a weaker boundary without an explicit product mode change.

These tests run on both Apple Silicon macOS and Windows 11 Pro/Enterprise. Passing on one platform cannot waive failure on the other.
