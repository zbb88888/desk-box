# Desk Box

Desktop security sandbox for running AI coding agents and untrusted development workloads.

Desk Box uses OCI images as the workload format and dedicated Linux virtual machines as the strong isolation boundary: Apple `Virtualization.framework` on Apple Silicon macOS and Hyper-V Generation 2 on Windows 11 Pro/Enterprise.

## Design

- [Design document index](docs/README.md)
- [Desktop VM sandbox architecture](docs/architecture/desktop-vm-sandbox.md)
- [Technology selection and trade-offs](docs/research/technology-selection.md)
- [Threat model and security invariants](docs/security/threat-model.md)
- [Best-practice assessment](docs/research/best-practice-assessment.md)
- [ADR-0001: Desktop VM sandbox baseline](docs/adr/0001-desktop-vm-sandbox-baseline.md)

Implementation follows the accepted architecture decision. Security claims are considered verified only after the cross-platform release gates in the threat model pass.
