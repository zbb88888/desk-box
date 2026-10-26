#!/bin/sh
name=kernel-build-inner
echo "[inner] start"

set -eu

for try_i in 1 2 3 4 5 6 7 8 9 10; do
    apk add --no-cache build-base bc bison flex openssl-dev openssl perl xz tar bash > /out/apk.log 2>&1 && { echo "[inner] apk ok"; break; }
    echo "[inner] apk retry $try_i"; tail -2 /out/apk.log 2>/dev/null || true; sleep 15
done

mkdir -p /tmp/work && cd /tmp/work
rm -rf "linux-$KERNEL_VERSION"
KERNEL_TARBALL="linux-$KERNEL_VERSION.tar.xz"
tar -xf "/out/$KERNEL_TARBALL"
cd "linux-$KERNEL_VERSION"

cp /out/debian-cloud-arm64-config .config
bash scripts/config --disable SECURITY_SELINUX || true
bash scripts/config --disable AUDIT || true
# VZ 弃客 stern 必须 builtin（Alpine initramfs 不可调用 module）
for K in VIRTIO_BLK VIRTIO_VSOCKETS VSOCK VIRTIO_PCI DEVTMPFS_DEVTMPFS_MOUNT DEVTMPFS_MOUNT DRM_VIRTIO_GPU DRM_VIRTIO_GPU_KMS HVC_DRIVER FRAMEBUFFER_CONSOLE FB_DRM; do
    bash scripts/config --enable "$K" 2>/dev/null || true
done
cat /out/custom-kernel.config >> .config

echo "[inner] union config summary:"
grep -E "^CONFIG_(VIRTIO_CONSOLE|VIRTIO_BLK|VSOCK|VIRTIO_VSOCKETS|HVC_DRIVER|DRM=|DRM_VIRTIO_GPU|PCI=|EFI=|DEVTMPFS_MOUNT)=" .config | head -14 || true

# 先去除库里可用性这些 symbol 当时 angel 会变体，随后 pov光其 =y
for K in VIRTIO_VSOCKETS VSOCKETS VSOCK VIRTIO_BLK VIRTIO_CONSOLE DRM_VIRTIO_GPU DRM_VIRTIO_GPU_KMS HVC_DRIVER DRM_FBDEV_EMULATION DRM_VMWGFX; do
    grep -vE "^CONFIG_${K}=" .config > .config.tmp && mv .config.tmp .config
done
cat >> .config << 'EOFY'
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_VIRTIO_GPU_KMS=y
CONFIG_HVC_DRIVER=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_VMWGFX=n
EOFY
echo "[inner] post-sed config:"
grep -E "^CONFIG_(VIRTIO_VSOCKETS|VSOCK|VIRTIO_BLK|VIRTIO_CONSOLE|DRM_VIRTIO_GPU|HVC_DRIVER)=" .config | head -8
make olddefconfig

JOBS=$(nproc)
echo "[inner] compiling with jobs=$JOBS ..."
KBUILD_BUILD_TIMESTAMP="$REPRO_STAMP" KBUILD_BUILD_USER="deskbox" KBUILD_BUILD_HOST="deskbox" \
    make -j"$JOBS" Image > /out/kernel-make.log 2>&1 || {
        echo "[inner] BUILD FAILED -- tail kernel-make.log:"
        tail -60 /out/kernel-make.log
        exit 1
    }
tail -10 /out/kernel-make.log

echo "[inner] Image summary:"
ls -la arch/arm64/boot/Image
cp arch/arm64/boot/Image /out/vmlinuz-virt-gpu
echo "[inner] copied to /out/vmlinuz-virt-gpu"
