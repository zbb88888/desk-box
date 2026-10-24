#!/usr/bin/env bash
set -euo pipefail

# Generate and import a development-only EC P-256 TLS identity for the M1-2
# TLS upgrade slice. Per-boot ephemeral identities (M1-2b) will replace this.
#
# The generated pkcs12 is imported into the *login* keychain so .p12 handling
# stays on Apple's code path; the runtime looks it up by label. It is dev
# material: short validity, clearly named, never used in release builds.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Resources/tls-dev"
LABEL="deskbox-dev-tls"
DAYS="${DAYS:-30}"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [[ ! -f host.key || ! -f host.crt ]]; then
  openssl req -x509 -new -nodes \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout host.key -out host.crt \
    -days "$DAYS" -subj "/CN=$LABEL" >/dev/null 2>&1
  openssl pkcs12 -export -out host.p12 \
    -inkey host.key -in host.crt -passout pass:deskbox-dev >/dev/null 2>&1
fi

# Remove prior instances silently; ignore-absence for fresh machines.
security delete-certificate -t -z "$(security find-certificate -a -c "$LABEL" | awk '/SHA-256 hash/{print $NF; exit}')" >/dev/null 2>&1 || true
security import host.p12 -k "$(security login-keychain)" -P deskbox-dev -T /System/Library/Frameworks/Virtualization.framework >/dev/null 2>&1 || true

# Fingerprint emitted for guest pinning (kernel cmdline / manifests later).
FP=$(openssl x509 -in host.crt -outform der 2>/dev/null | shasum -a 256 | awk '{print $1}')
echo "$FP" > host-fingerprint.txt
echo "dev TLS identity ready (label=$LABEL, fingerprint=$FP)"
