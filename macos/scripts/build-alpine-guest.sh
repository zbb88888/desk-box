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
DEBIAN_INITRD_URL="https://deb.debian.org/debian/dists/bookworm/main/installer-arm64/current/images/netboot/debian-installer/arm64/initrd.gz"
MINIROOT_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"

mkdir -p "$OUT_DIR"
cp "$(dirname "$0")/guest-bootstrap.c" "$OUT_DIR/guest-bootstrap.c"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required to build the ext4 image" >&2; exit 1; }

echo "Downloading Alpine rootfs and direct-boot Linux arm64 kernel..."
curl --fail --location --retry 3 --output "$OUT_DIR/vmlinuz-virt" "$KERNEL_URL"
curl --fail --location --retry 3 --output "$OUT_DIR/debian-initrd.gz" "$DEBIAN_INITRD_URL"
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
    apk add --no-cache e2fsprogs curl gcc musl-dev linux-headers busybox-static dpkg libsodium-dev libsodium-static >/dev/null
    # The Debian installer initrd is intentionally small and does not contain
    # virtio-blk/VSOCK transport modules. Fetch the matching Debian module set
    # for the direct kernel used by VZ; the host never trusts guest claims.
    mkdir -p /tmp/deb-modules
    curl --fail --location --retry 3 -o /tmp/linux-image.deb \
      https://deb.debian.org/debian/pool/main/l/linux-signed-arm64/linux-image-6.1.0-50-arm64_6.1.176-1_arm64.deb
    dpkg-deb -x /tmp/linux-image.deb /tmp/deb-modules
    gcc -static -O2 -Wall -Wextra -o /tmp/deskbox-bootstrap /out/guest-bootstrap.c /usr/lib/libsodium.a
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
if [ ! -e /run/deskbox-bootstrap-ok ]; then
  /sbin/deskbox-bootstrap >/dev/console 2>&1 || true
fi
printf "Desk Box guest init ready\\n" > /dev/console 2>/dev/null || true
# Do not keep init on a serial shell; the diagnostic bootstrap is complete.
# A production execd replaces this loop.
exec /bin/busybox sh -c "while :; do /bin/busybox sleep 3600; done"
EOF
    chmod 0755 /tmp/rootfs/sbin/init
    truncate -s "${ROOT_SIZE_MB}M" /out/root-disk.raw
    mke2fs -q -t ext4 -F -d /tmp/rootfs /out/root-disk.raw

    rm -rf /tmp/initrd
    mkdir -p /tmp/initrd
    gzip -dc /out/debian-initrd.gz | (cd /tmp/initrd && cpio -id --quiet)
    mkdir -p /tmp/initrd/bin /tmp/initrd/dev /tmp/initrd/proc /tmp/initrd/sys /tmp/initrd/newroot
    # Keep the early boot path independent of devtmpfs/udev. VZ exposes the
    # virtio block device as vda and the primary console as hvc0.
    rm -f /tmp/initrd/dev/console /tmp/initrd/dev/hvc0 /tmp/initrd/dev/ttyS0 /tmp/initrd/dev/vda
    mknod -m 0600 /tmp/initrd/dev/console c 5 1
    mknod -m 0600 /tmp/initrd/dev/hvc0 c 229 0
    mknod -m 0600 /tmp/initrd/dev/ttyS0 c 4 64
    mknod -m 0600 /tmp/initrd/dev/vda b 252 0
    cp /bin/busybox.static /tmp/initrd/bin/busybox
    # Alpine busybox is dynamically linked against musl; include its loader
    # and runtime libraries in the initramfs or /init will fail before console.
    mkdir -p /tmp/initrd/lib /tmp/initrd/usr/lib
    cp -a /tmp/rootfs/lib/* /tmp/initrd/lib/ 2>/dev/null || true
    cp -a /tmp/rootfs/usr/lib/* /tmp/initrd/usr/lib/ 2>/dev/null || true
    mkdir -p /tmp/initrd/lib/modules
    cp -a /tmp/deb-modules/lib/modules/* /tmp/initrd/lib/modules/
    depmod -b /tmp/initrd 6.1.0-50-arm64
    mkdir -p /tmp/initrd/sbin
    cp /tmp/deskbox-bootstrap /tmp/initrd/sbin/deskbox-bootstrap
    chmod 0755 /tmp/initrd/bin/busybox
    rm -f /tmp/initrd/bin/mount /tmp/initrd/bin/switch_root
    ln -s busybox /tmp/initrd/bin/mount
    ln -s busybox /tmp/initrd/bin/switch_root
    cat > /tmp/initrd/init <<EOF
#!/bin/busybox sh
# Emit to the kernel console before any mounts; this distinguishes kernel boot
# from an initramfs execution failure.
printf "Desk Box init entered\\n" > /dev/console 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true
# The Debian direct kernel keeps several VZ devices as modules. Load them before
# probing /dev so virtio-console, virtio-blk and AF_VSOCK are available.
for m in virtio virtio_ring virtio_pci virtio_mmio virtio_console virtio_blk vsock vmw_vsock_virtio_transport vmw_vsock_virtio_transport_common; do
  /bin/busybox modprobe "\$m" 2>/dev/null || true
done
# Keep console usable even when the guest kernel lacks devtmpfs auto-population.
[ -e /dev/console ] || /bin/busybox mknod -m 0600 /dev/console c 5 1 || true
[ -e /dev/ttyS0 ] || /bin/busybox mknod -m 0600 /dev/ttyS0 c 4 64 || true
[ -e /dev/hvc0 ] || /bin/busybox mknod -m 0600 /dev/hvc0 c 229 0 || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
for c in /dev/console /dev/ttyS0 /dev/hvc0; do
  printf "Desk Box initramfs ready\\n" > "\$c" 2>/dev/null || true
done
/sbin/deskbox-bootstrap >/dev/console 2>&1 || true
printf "Desk Box bootstrap completed\\n" > /dev/console 2>/dev/null || true
# Give uevents a bounded opportunity to create VZ devices after module load.
for i in 1 2 3 4 5; do
  [ -e /dev/vda ] && break
  /bin/busybox sleep 1
done
while ! mount -t ext4 -o rw /dev/vda /newroot; do
  printf "Desk Box waiting for /dev/vda\\n" > /dev/console 2>/dev/null || true
  /bin/busybox sleep 1
done
exec /bin/busybox switch_root /newroot /sbin/init
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
