#!/usr/bin/env bash
set -euo pipefail

# Build a minimal, network-disabled Alpine arm64 guest for the VZ launch POC.
# This is a development asset builder, not a signed production supply-chain
# pipeline. Pin and review ALPINE_VERSION, then record SHA-256/provenance before
# using the result outside a local POC.

ALPINE_VERSION="${ALPINE_VERSION:-3.21.3}"
OUT_DIR="${1:-$(pwd)/guest}"
ROOT_SIZE_MB="${ROOT_SIZE_MB:-512}"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/aarch64/netboot"
# VZLinuxBootLoader requires a raw Linux arm64 Image, not Alpine's EFI wrapper.
KERNEL_URL="https://deb.debian.org/debian/dists/bookworm/main/installer-arm64/current/images/netboot/debian-installer/arm64/linux"
MINIROOT_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"

mkdir -p "$OUT_DIR"
cp "$(dirname "$0")/guest-bootstrap.c" "$OUT_DIR/guest-bootstrap.c"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required to build the ext4 image" >&2; exit 1; }

echo "Downloading Alpine rootfs and direct-boot Linux arm64 kernel..."
curl --fail --location --retry 3 --output "$OUT_DIR/vmlinuz-virt" "$KERNEL_URL"
curl --fail --location --retry 3 --output "$OUT_DIR/initramfs-virt" "$BASE_URL/initramfs-virt"
file "$OUT_DIR/vmlinuz-virt" | tee "$OUT_DIR/kernel-format.txt"
if ! file "$OUT_DIR/vmlinuz-virt" | grep -q 'Linux kernel ARM64 boot executable'; then
  echo "kernel is not a direct Linux arm64 Image; refusing to continue" >&2
  exit 1
fi

# The initramfs expects /dev/vda as root. mke2fs -d populates an ext4 image
# without requiring a privileged mount inside Docker.
echo "Building ${ROOT_SIZE_MB} MiB ext4 root disk..."
docker run --rm \
  --platform linux/arm64 \
  -e ALPINE_VERSION="$ALPINE_VERSION" \
  -e ROOT_SIZE_MB="$ROOT_SIZE_MB" \
  -e MINIROOT_URL="$MINIROOT_URL" \
  -v "$OUT_DIR:/out" \
  "alpine:${ALPINE_VERSION%.*}" \
  sh -eu -c '
    apk add --no-cache e2fsprogs curl gcc musl-dev linux-headers >/dev/null
    gcc -static -O2 -Wall -Wextra -o /tmp/deskbox-bootstrap /out/guest-bootstrap.c
    rm -rf /tmp/rootfs
    mkdir -p /tmp/rootfs
    curl --fail --location --retry 3 "$MINIROOT_URL" | tar -xz -C /tmp/rootfs
    mkdir -p /tmp/rootfs/root /tmp/rootfs/workspace /tmp/rootfs/run
    install -m 0755 /tmp/deskbox-bootstrap /tmp/rootfs/sbin/deskbox-bootstrap
    cat > /tmp/rootfs/etc/motd <<EOF
Desk Box Alpine guest POC
Network is intentionally disabled by the host VZ configuration.
EOF
    # Make initramfs hand off to the root filesystem and keep a diagnostic shell
    # available on the serial console. No network service is enabled.
    if [ -e /tmp/rootfs/sbin/init ]; then mv /tmp/rootfs/sbin/init /tmp/rootfs/sbin/init.real; fi
    cat > /tmp/rootfs/sbin/init <<EOF
#!/bin/sh
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true
mkdir -p /run /workspace
/sbin/deskbox-bootstrap >/dev/null 2>&1 || true
printf "Desk Box guest init ready\\n"
if [ -x /sbin/init.real ]; then exec /sbin/init.real; fi
exec /bin/sh
EOF
    chmod 0755 /tmp/rootfs/sbin/init
    truncate -s "${ROOT_SIZE_MB}M" /out/root-disk.raw
    mke2fs -q -t ext4 -F -d /tmp/rootfs /out/root-disk.raw

    rm -rf /tmp/initrd
    mkdir -p /tmp/initrd/bin /tmp/initrd/dev /tmp/initrd/proc /tmp/initrd/sys /tmp/initrd/newroot
    cp /tmp/rootfs/bin/busybox /tmp/initrd/bin/busybox
    ln -s busybox /tmp/initrd/bin/mount
    ln -s busybox /tmp/initrd/bin/switch_root
    cat > /tmp/initrd/init <<EOF
#!/bin/busybox sh
mount -t devtmpfs dev /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
until mount -t ext4 -o rw /dev/vda /newroot; do sleep 1; done
exec /bin/switch_root /newroot /sbin/init
EOF
    chmod 0755 /tmp/initrd/init
    (cd /tmp/initrd && find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > /out/initrd-deskbox.img)
  '

cd "$(dirname "$0")/.."
swift run dbx-poc make-manifest \
  --kernel "$OUT_DIR/vmlinuz-virt" \
  --initrd "$OUT_DIR/initrd-deskbox.img" \
  --root-disk "$OUT_DIR/root-disk.raw" \
  --output "$OUT_DIR/manifest.json"

cat <<EOF
Guest POC assets created in: $OUT_DIR

Next:
  swift run dbx-poc validate-assets "$OUT_DIR/manifest.json"
  swift run dbx-poc launch "$OUT_DIR/manifest.json" \\
    --cow-root "${HOME}/Library/Application Support/DeskBox/cows"

This asset set is unsigned development input. Review and pin upstream
checksums/signatures before any security claim or release use.
EOF
