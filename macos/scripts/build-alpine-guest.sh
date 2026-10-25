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
cp "$(dirname "$0")/brokerreq.c" "$OUT_DIR/brokerreq.c"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required to build the ext4 image" >&2; exit 1; }

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# M10：SOURCE_DATE_EPOCH 统一起点。可选（默认取 HEAD 提交时间戳）。
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || echo 1700000000)
fi
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
# M10：所有发布的内置时间戳都与源 commit 同步。
NOW_UTC=$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

echo "Downloading Alpine rootfs and direct-boot Linux arm64 kernel..."
curl --fail --location --retry 3 --output "$OUT_DIR/vmlinuz-virt" "$KERNEL_URL"
curl --fail --location --retry 3 --output "$OUT_DIR/debian-initrd.gz" "$DEBIAN_INITRD_URL"
# 复构一致：下载文件的 mtime 以 SOURCE_DATE_EPOCH 为准（— BSD/GNU touch 均支持 -t [[CC]YY]MMDDhhmm[.ss]）。
TS_FMT=$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)
touch -t "$TS_FMT" "$OUT_DIR/vmlinuz-virt" "$OUT_DIR/debian-initrd.gz"
KERNEL_SHA256=$(sha256_file "$OUT_DIR/vmlinuz-virt")
DEBIAN_INITRD_SHA256=$(sha256_file "$OUT_DIR/debian-initrd.gz")
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
  -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  -e TS_TOUCH="$TS_FMT" \
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
    # 顺手装个 brokerreq 小客户端（M2-3b：guest 进程通过 AF_UNIX 请求宿主 broker）
    gcc -static -O2 -Wall -Wextra -o /tmp/brokerreq /out/brokerreq.c
    install -m 0755 /tmp/deskbox-bootstrap /tmp/rootfs/sbin/deskbox-bootstrap
    install -m 0755 /tmp/brokerreq /tmp/rootfs/bin/brokerreq
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
mkdir -p /run /workspace
mount -t devtmpfs dev /dev 2>/dev/null && printf "DBXDEV devtmpfs-ok\\n" > /dev/console 2>/dev/null || printf "DBXDEV devtmpfs-fail\\n" > /dev/console 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null && printf "DBXDEV devpts-ok\\n" > /dev/console 2>/dev/null || printf "DBXDEV devpts-fail\\n" > /dev/console 2>/dev/null || true
[ -e /dev/ptmx ] && printf "DBXDEV ptmx-ok\\n" > /dev/console 2>/dev/null || printf "DBXDEV ptmx-missing\\n" > /dev/console 2>/dev/null || true
if [ ! -e /run/deskbox-bootstrap-ok ]; then
  /sbin/deskbox-bootstrap >/dev/console 2>&1 || true
fi
printf "Desk Box guest init ready\\n" > /dev/console 2>/dev/null || true
# Do not keep init on a serial shell; the diagnostic bootstrap is complete.
# A production execd replaces this loop.
exec /bin/busybox sh -c "while :; do /bin/busybox sleep 3600; done"
EOF
    chmod 0755 /tmp/rootfs/sbin/init
    # M10：ext4 / timestamp deterministic：mtime 归一 + fixed UUID + hash_seed 统一。
    find /tmp/rootfs -exec touch -h -t "$TS_TOUCH" {} +
    truncate -s "${ROOT_SIZE_MB}M" /out/root-disk.raw
    # e2fsprogs deterministic variant：无 journal + 无 metadata_csum + test_fs。
    mke2fs -q -t ext4 -F -d /tmp/rootfs \
      -O ^has_journal,^metadata_csum \
      -E test_fs \
      -U 00000000-0000-0000-0000-000000000000 \
      /out/root-disk.raw
    # 确定性后处理（e2fsprogs journal-salt 与 few-byte timestamps）：
    # 1) superblock 随机盐区/jnl_blocks (1248..1315, 无 journal 下无意义)；
    # 2) s_mtime/s_wtime/lastcheck 等时间戳字段 (1068..1079)。
    dd if=/dev/zero of=/out/root-disk.raw bs=1 seek=1248 count=68 conv=notrunc status=none
    dd if=/dev/zero of=/out/root-disk.raw bs=1 seek=1068 count=12 conv=notrunc status=none
    # 备份 superblock 清零：4KiB block / 512MB 磁盘时备份位于 group = 1 & 3 (sparse_super)：
    for blk in 32768 98304; do
      start=$((blk * 4096))
      dd if=/dev/zero of=/out/root-disk.raw bs=1 seek=$((start + 224)) count=68 conv=notrunc status=none 2>/dev/null || true
      dd if=/dev/zero of=/out/root-disk.raw bs=1 seek=$((start + 44)) count=12 conv=notrunc status=none 2>/dev/null || true
    done

    rm -rf /tmp/initrd
    mkdir -p /tmp/initrd
    gzip -dc /out/debian-initrd.gz | (cd /tmp/initrd && cpio -id --quiet)
    mkdir -p /tmp/initrd/bin /tmp/initrd/dev /tmp/initrd/proc /tmp/initrd/sys /tmp/initrd/newroot /tmp/initrd/workspace
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
    mkdir -p /tmp/initrd/sbin /tmp/initrd/bin
    cp /tmp/deskbox-bootstrap /tmp/initrd/sbin/deskbox-bootstrap
    cp /tmp/brokerreq /tmp/initrd/bin/brokerreq
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
    # M10 deterministic：initrd 的 mtime 也归一（gzip -n 无 mtime = 但 cpio header 里仍有）。
    find /tmp/initrd -exec touch -h -t "$TS_TOUCH" {} +
    (cd /tmp/initrd && find . -print | LC_ALL=C sort | cpio -o -H newc 2>/dev/null | gzip -n9 > /out/initrd-deskbox.img)
  '

cd "$(dirname "$0")/.."
SBOM_ONLY="${SKIP_SWIFT_SIGN:-0}"
if [ "$SBOM_ONLY" != "1" ]; then
  # 开发密钥淡离仓库：在 guest/（gitignored）下只生成一次；发布链必须使用正式 key。
  if [ ! -f "$OUT_DIR/dev-sign-key.local" ]; then
    swift run dbx-poc gen-guest-sign-key --output-key "$OUT_DIR/dev-sign-key.local" >/dev/null
  fi
  # 将 dev key 对应公钥汇编进 DeskBoxVZ（gitignored 生成文件），使每次构建的可信列表与本地签名一致。
  DEV_PRIV=$(sed 's/private://' "$OUT_DIR/dev-sign-key.local" | tr -d '[:space:]')
  DEV_PUB=$(swift -e 'import CryptoKit; import Foundation; let hex = CommandLine.arguments[1]; var data = Data(); var i = hex.startIndex; while i < hex.endIndex { data.append(UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!); i = hex.index(i, offsetBy: 2) }; let k = try Curve25519.Signing.PrivateKey(rawRepresentation: data); print(k.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())' "$DEV_PRIV")
  cat > Sources/DeskBoxVZ/DevSigningPublicKey.generated.swift <<EOGEN
// GENERATED by scripts/build-alpine-guest.sh — do not edit, gitignored.
enum DevSigningPublicKey { static let value: String? = "${DEV_PUB}" }
EOGEN
  KEY_ID=${DEV_PUB:0:16}
  if [ ! -f "$OUT_DIR/release-keys.json" ]; then
    cat > "$OUT_DIR/release-keys.json" <<EORK
{
  "schema": "deskbox-release-keys/v1",
  "generatedAtUtc": "$NOW_UTC",
  "keys": [
    {"keyID":"$KEY_ID","publicHex":"$DEV_PUB","status":"active",
     "notBefore":"$NOW_UTC","notAfter":null,
     "note":"dev workstation key; M5 rotation demo base"}
  ]
}
EORK
  fi
fi
# SBOM：客资产 digest 与输入供给同步 env，manifest 签名覆盖 sbomDigest。
VMLINUZ_SHA=$(sha256_file "$OUT_DIR/vmlinuz-virt")
INITRD_SHA=$(sha256_file "$OUT_DIR/initrd-deskbox.img")
ROOTFS_SHA=$(sha256_file "$OUT_DIR/root-disk.raw")
GUEST_SRC_SHA=$(sha256_file "$OUT_DIR/guest-bootstrap.c")
BROKERREQ_SRC_SHA=$(sha256_file "$OUT_DIR/brokerreq.c")
BUILD_SCRIPT_SHA=$(sha256_file "scripts/build-alpine-guest.sh")
cat > "$OUT_DIR/sbom.json" <<EOSBOM
{
  "schema": "deskbox-guest-sbom/v1",
  "builtAtUtc": "$NOW_UTC",
  "assetVersion": 1,
  "inputs": [
    {"name":"debian/linux-arm64-kernel","url":"$KERNEL_URL","file":"vmlinuz-virt","sha256":"$KERNEL_SHA256"},
    {"name":"debian/initrd.gz","url":"$DEBIAN_INITRD_URL","file":"debian-initrd.gz","sha256":"$DEBIAN_INITRD_SHA256"},
    {"name":"alpine/minirootfs-$ALPINE_VERSION","url":"$MINIROOT_URL"},
    {"name":"scripts/guest-bootstrap.c","path":"scripts/guest-bootstrap.c","file":"guest-bootstrap.c","sha256":"$GUEST_SRC_SHA"},
    {"name":"scripts/brokerreq.c","path":"scripts/brokerreq.c","file":"brokerreq.c","sha256":"$BROKERREQ_SRC_SHA"},
    {"name":"scripts/build-alpine-guest.sh","path":"scripts/build-alpine-guest.sh","file":"build-alpine-guest.sh","sha256":"$BUILD_SCRIPT_SHA"}
  ],
  "outputs": [
    {"name":"vmlinuz-virt","sha256":"$VMLINUZ_SHA"},
    {"name":"initrd-deskbox.img","sha256":"$INITRD_SHA"},
    {"name":"root-disk.raw","sha256":"$ROOTFS_SHA"}
  ]
}
EOSBOM
SBOM_SHA=$(sha256_file "$OUT_DIR/sbom.json")
if [ "$SBOM_ONLY" != "1" ]; then
  swift run dbx-poc make-manifest \
    --kernel "$OUT_DIR/vmlinuz-virt" \
    --initrd "$OUT_DIR/initrd-deskbox.img" \
    --root-disk "$OUT_DIR/root-disk.raw" \
    --asset-version 1 \
    --sbom-digest "$SBOM_SHA" \
    --output "$OUT_DIR/manifest.unsigned.json"
  swift run dbx-poc sign-manifest \
    --manifest "$OUT_DIR/manifest.unsigned.json" \
    --key "$OUT_DIR/dev-sign-key.local" \
    --output "$OUT_DIR/manifest.json"
fi

cat <<EOF
Guest POC assets created in: $OUT_DIR

Next:
  swift run dbx-poc validate-assets "$OUT_DIR/manifest.json"
  swift run dbx-poc launch "$OUT_DIR/manifest.json" \\
    --cow-root "${HOME}/Library/Application Support/DeskBox/cows"

This asset set is unsigned development input. Review and pin upstream
checksums/signatures before any security claim or release use.
EOF
