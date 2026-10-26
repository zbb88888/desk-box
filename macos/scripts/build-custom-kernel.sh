#!/bin/sh
# M14b：构建自定义 Linux arm64 kernel（含 virtio-gpu 驱动）。
# kernel.org cdn -> sha256sums.asc 验证 -> docker arm64 编译 -> output image。
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:?output directory required}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.32}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
export SOURCE_DATE_EPOCH

mkdir -p "$OUT_DIR"
REPRO_STAMP=$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
echo "[build-custom-kernel] SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH  REPRO_STAMP=$REPRO_STAMP  OUT_DIR=$OUT_DIR"

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
# kernel.org sha256sums.asc 同源校验；更严产品形态：GPG verify（接下一步GPG keyring）。
if [ -z "${KERNEL_SHA256:-}" ]; then
    echo "[build-custom-kernel] fetching upstream sha256sums.asc"
    KERNEL_SHA256=$(curl --fail --silent --show-error --location "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc" | grep "  $KERNEL_TARBALL\$" | awk '{print $1}')
fi
[ -z "$KERNEL_SHA256" ] && { echo "no sha256 found for $KERNEL_TARBALL"; exit 1; }

echo "[build-custom-kernel] downloading $KERNEL_URL ..."
curl --fail --silent --show-error --location "$KERNEL_URL" -o "$OUT_DIR/$KERNEL_TARBALL"
echo "$KERNEL_SHA256  $OUT_DIR/$KERNEL_TARBALL" | shasum -a 256 -c - || { echo "sha256 mismatch"; exit 1; }

cp "$ROOT_DIR/scripts/custom-kernel.config" "$OUT_DIR/"

# ---- Debian cloud-arm64 base config（同源签名于 debian repository provenance）
DEBIAN_CFG_NAME="config-6.12.32-cloud-arm64"
if [ ! -s "$OUT_DIR/debian-cloud-arm64-config" ]; then
    echo "[build-custom-kernel] obtaining debian config base ..."
    DEB_URL="https://snapshot.debian.org/archive/debian/20250625T154100Z/pool/main/l/linux-signed-arm64/linux-image-6.12.32-cloud-arm64_6.12.32-1_arm64.deb"
    curl --fail --silent --show-error --location "$DEB_URL" -o "$OUT_DIR/linux-image.deb"
    # 提取 config- 文件（dpkg 或 GNU tar；host 上）：
    docker run --rm --platform linux/arm64 -v "$OUT_DIR:/out" alpine:3.21 sh -c '
        apk add --no-cache tar dpkg >/dev/null 2>&1
        cd /out && mkdir -p deb-out && cd deb-out
        dpkg --extract /out/linux-image.deb . 2>/dev/null || (tar -xf /out/linux-image.deb; tar -xf data.tar* )
        cp boot/config-6.12.32-cloud-arm64 /out/debian-cloud-arm64-config 2>/dev/null || cp "$(find . -path "*/boot/config-*" | head -1)" /out/debian-cloud-arm64-config
        rm -rf /out/deb-out
        ls -la /out/debian-cloud-arm64-config
    '
fi

# Linux source tarball from kernel.org
echo "[build-custom-kernel] unpacking + compiling in docker arm64 (this takes a while) ..."
docker run --rm --platform linux/arm64 \
    -v "$OUT_DIR:/out" \
    -v "$ROOT_DIR/scripts/kernel-build-inner.sh:/inner.sh:ro" \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e KERNEL_VERSION="$KERNEL_VERSION" \
    -e REPRO_STAMP="$REPRO_STAMP" \
    alpine:3.21 sh /inner.sh

if [ ! -s "$OUT_DIR/vmlinuz-virt-gpu" ]; then
    echo "[build-custom-kernel] ERROR: vmlinuz-virt-gpu not produced"
    exit 1
fi
shasum -a 256 "$OUT_DIR/vmlinuz-virt-gpu"
echo "[build-custom-kernel] done"
