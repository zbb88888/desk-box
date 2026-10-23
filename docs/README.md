# Desk Box Design Documents

These documents define the initial architecture baseline for Desk Box.

## Start here

1. [Desktop VM sandbox architecture](architecture/desktop-vm-sandbox.md) describes the implementation topology, trust boundaries, host and guest components, lifecycle, and delivery phases.
2. [Technology selection](research/technology-selection.md) compares the reviewed projects, explains their underlying engines, and records what is adopted, referenced, deferred, or rejected.
3. [Threat model](security/threat-model.md) defines adversaries, protected assets, security invariants, controls, and release-blocking tests.
4. [Best-practice assessment](research/best-practice-assessment.md) explains why the architecture fits established practices, where it intentionally differs from cloud designs, and what evidence is still required.
5. [ADR-0001](adr/0001-desktop-vm-sandbox-baseline.md) is the concise accepted decision record.

## Decision in one paragraph

Desk Box uses OCI images as the workload format and dedicated Linux VMs as the strong isolation boundary: Apple `Virtualization.framework` on Apple Silicon macOS and Hyper-V Generation 2 on Windows 11 Pro/Enterprise. The guest runs `containerd`, `runc`, and a pinned minimal OpenSandbox `execd` fork. A trusted host broker owns lifecycle, workspace synchronization, outbound policy, and long-lived credentials. Docker Desktop, Kubernetes, WSL2, and a host Docker daemon are not required.

## Document status

The architecture and ADR are accepted as the implementation baseline. Security properties remain claims to validate until the cross-platform release gates in the threat model pass.
