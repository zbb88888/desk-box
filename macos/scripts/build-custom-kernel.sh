#!/bin/sh
# M14b：构建自定义 Linux arm64 kernel（含 virtio-gpu 驱动）。
# 主打自身客并星际代电阻：kernel.org cdn -> docker arm64 交叉编译 -> output image。
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:?output directory required}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.38}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
export SOURCE_DATE_EPOCH

mkdir -p "$OUT_DIR"
REPRO_STAMP=$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
echo "[build-custom-kernel] SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH  REPRO_STAMP=$REPRO_STAMP  OUT_DIR=$OUT_DIR"

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
# kernel.org sha256sums.asc 同源校验；更严尽入核实：可阶 GPG verify（计划下M-next step）。
if [ -z "${KERNEL_SHA256:-}" ]; then
    echo "[build-custom-kernel] fetching upstream sha256sums.asc"
    KERNEL_SHA256=$(curl --fail --silent --show-error --location "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc" | grep "  $KERNEL_TARBALL\$" | awk '{print $1}')
fi
[ -z "$KERNEL_SHA256" ] && { echo "no sha256 found for $KERNEL_TARBALL"; exit 1; }

echo "[build-custom-kernel] downloading $KERNEL_URL ..."
curl --fail --silent --show-error --location "$KERNEL_URL" -o "$OUT_DIR/$KERNEL_TARBALL"
echo "$KERNEL_SHA256  $OUT_DIR/$KERNEL_TARBALL" | shasum -a 256 -c - || { echo "sha256 mismatch"; exit 1; }

cp "$ROOT_DIR/scripts/custom-kernel.config" "$OUT_DIR/"

echo "[build-custom-kernel] unpacking + compiling in docker arm64 (this takes a while) ..."
docker run --rm --platform linux/arm64 \
    -v "$OUT_DIR:/out" \
    -v "$OUT_DIR/custom-kernel.config:/out/custom-kernel.config:ro" \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e KERNEL_VERSION="$KERNEL_VERSION" \
    -e REPRO_STAMP="$REPRO_STAMP" \
    alpine:3.21 sh << "EOFK"
    set -eu
    apk add --no-cache build-base bc bison flex openssl-dev perl xz tar ncurses-dev tar >/dev/null
    # kernel 源码含大小写冲突路径（include/dt-bindings/INPUT vs input）；
    # case-insensitive APFS volume mount 无法解压。放到容器 desired fs 内再拷回输出。
    mkdir -p /tmp/work && cd /tmp/work
    rm -rf "linux-$KERNEL_VERSION"
    KERNEL_TARBALL="linux-$KERNEL_VERSION.tar.xz"
    tar -xf /out/"$KERNEL_TARBALL"
    cd "linux-$KERNEL_VERSION"
    cp /out/custom-kernel.config .config
    make olddefconfig
    # M10 决定的 deterministic build（source_time_epoch 驱动）。
    JOBS=$(nproc)
    KBUILD_BUILD_TIMESTAMP="$REPRO_STAMP" KBUILD_BUILD_USER="deskbox" KBUILD_BUILD_HOST="deskbox" \
        make -j"$JOBS" Image 2>&1 | tail -8
    cp arch/arm64/boot/Image /out/vmlinuz-virt-gpu
    echo "custom kernel built: /out/vmlinuz-virt-gpu"
EOFK

if [ ! -s "$OUT_DIR/vmlinuz-virt-gpu" ]; then
    echo "[build-custom-kernel] ERROR: vmlinuz-virt-gpu not produced"
    exit 1
fi
shasum -a 256 "$OUT_DIR/vmlinuz-virt-gpu"
echo "[build-custom-kernel] done"
