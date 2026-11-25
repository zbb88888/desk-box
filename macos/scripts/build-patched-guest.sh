#!/usr/bin/env bash
# M37：把**当前源码**的 guest bootstrap 换进一份现有 guest 资产的 initrd，产出一套可启动的「补丁版」资产。
#
#   ./scripts/build-patched-guest.sh <现有 guest 目录> <输出目录>
#
# 用途：在本机验证 scripts/guest-bootstrap.c 的改动，而不重建整套 guest
#（`build-alpine-guest.sh` 需要 Docker，会重新下载内核 / 模块并覆盖目标目录）。
# 这里只重新编译 bootstrap 并把它替换进 initrd；内核与 root 盘原样复用。**不修改** <现有 guest 目录>。
#
# 不需要 Docker，也不需要 root：
#   - 用本机的 aarch64-linux-musl 交叉编译器（`brew install FiloSottile/musl-cross/musl-cross`）；
#   - libsodium 从官方源码包为目标平台静态编译（校验固定的 SHA-256）；
#   - initrd 是 newc 格式的 cpio：直接在归档流里替换那一个文件，不解包（解包需要 root 才能建设备节点）。
#
# 产物是**测试夹具**，不是发布资产：编译器与 libsodium 版本都和正式构建（Alpine 容器）不同，manifest 未签名。
# 输出：<输出目录>/{vmlinuz-virt, initrd-deskbox.img, root-disk.raw, manifest.json}
set -euo pipefail
SRC="$(cd "${1:?usage: build-patched-guest.sh <stock-guest-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?usage: build-patched-guest.sh <stock-guest-dir> <out-dir>}"
OUT="$(cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/dbx-poc}"
CC="${CROSS_CC:-aarch64-linux-musl-gcc}"
SODIUM_VERSION="1.0.20"
SODIUM_SHA256="ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19"
SODIUM_URL="https://download.libsodium.org/libsodium/releases/libsodium-${SODIUM_VERSION}.tar.gz"

command -v "$CC" >/dev/null || { echo "需要交叉编译器 $CC（brew install FiloSottile/musl-cross/musl-cross）" >&2; exit 2; }
for f in vmlinuz-virt initrd-deskbox.img root-disk.raw; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 2; }
done
[ -x "$BIN" ] || { echo "dbx-poc not found: $BIN" >&2; exit 2; }

STAGE="$OUT/.stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

# ---- libsodium（静态，目标平台）----
# M46：编译好的 libsodium 缓存在 .build/（gitignored 的构建目录）里，按「版本 + 源码包摘要 + 编译器」区分。
# 此前每次构建夹具都重新下载、重新编译——一次全量 E2E 要下载好几遍，官方站点一抖动整个套件就被跳过。
# 缓存只在第一次（或换了编译器之后）需要网络。删除 .build/patched-guest-cache 即可强制重建。
CC_ID=$("$CC" --version 2>/dev/null | head -1 | shasum -a 256 | cut -c1-12)
SODIUM_CACHE="${PATCHED_GUEST_SODIUM_CACHE:-$ROOT/.build/patched-guest-cache}/libsodium-$SODIUM_VERSION-${SODIUM_SHA256:0:12}-$CC_ID"
if [ -f "$SODIUM_CACHE/lib/libsodium.a" ] && [ -f "$SODIUM_CACHE/include/sodium.h" ]; then
  SODIUM_PREFIX="$SODIUM_CACHE"
else
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors -o "$STAGE/libsodium.tar.gz" "$SODIUM_URL"
  GOT=$(shasum -a 256 "$STAGE/libsodium.tar.gz" | awk '{print $1}')
  [ "$GOT" = "$SODIUM_SHA256" ] || { echo "libsodium 源码包摘要不符：$GOT（期望 $SODIUM_SHA256）" >&2; exit 1; }
  tar -xzf "$STAGE/libsodium.tar.gz" -C "$STAGE"
  (
    cd "$STAGE"/libsodium-*/
    ./configure --host=aarch64-linux-musl CC="$CC" --disable-shared --enable-static --prefix="$STAGE/sodium" >"$STAGE/sodium-configure.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" install >"$STAGE/sodium-make.log" 2>&1
  ) || { tail -15 "$STAGE"/sodium-*.log >&2; echo "libsodium 构建失败" >&2; exit 1; }
  SODIUM_PREFIX="$STAGE/sodium"
  # 放进缓存（原子：先拷到临时名再 rename；并发构建时后到的那个直接放弃）。只留头文件和静态库。
  mkdir -p "$(dirname "$SODIUM_CACHE")"
  TMP_CACHE="$SODIUM_CACHE.tmp.$$"
  rm -rf "$TMP_CACHE"; mkdir -p "$TMP_CACHE/lib"
  if cp -R "$STAGE/sodium/include" "$TMP_CACHE/include" && cp "$STAGE/sodium/lib/libsodium.a" "$TMP_CACHE/lib/"; then
    mv "$TMP_CACHE" "$SODIUM_CACHE" 2>/dev/null || rm -rf "$TMP_CACHE"
  else
    rm -rf "$TMP_CACHE"
  fi
fi

# ---- bootstrap ----
# 与 build-alpine-guest.sh 相同的选项。警告全部打印出来（不同编译器版本的告警集合不同，所以不用 -Werror）。
# PATCHED_GUEST_CFLAGS：额外的编译选项（M46：-DDBX_TEST_FAULTS 打开仅用于测试的故障注入）。
# shellcheck disable=SC2086
"$CC" -static -O2 -Wall -Wextra ${PATCHED_GUEST_CFLAGS:-} -I"$SODIUM_PREFIX/include" -o "$STAGE/deskbox-bootstrap" \
  "$ROOT/scripts/guest-bootstrap.c" "$SODIUM_PREFIX/lib/libsodium.a" 2>"$STAGE/cc.log" \
  || { cat "$STAGE/cc.log" >&2; echo "bootstrap 编译失败" >&2; exit 1; }
WARNINGS=$(grep -c 'warning:' "$STAGE/cc.log" || true)
[ "$WARNINGS" = 0 ] || { echo "bootstrap 编译有 $WARNINGS 条警告：" >&2; grep -A3 'warning:' "$STAGE/cc.log" | head -40 >&2; }
file "$STAGE/deskbox-bootstrap" | grep -q 'ELF 64-bit.*aarch64.*statically linked' \
  || { file "$STAGE/deskbox-bootstrap" >&2; echo "产物不是静态链接的 aarch64 ELF" >&2; exit 1; }

# ---- 在 cpio 流里替换 sbin/deskbox-bootstrap ----
python3 - "$SRC/initrd-deskbox.img" "$STAGE/deskbox-bootstrap" "$OUT/initrd-deskbox.img" <<'PY'
import gzip, sys

def pad4(n): return (4 - n % 4) % 4

src, new_bin_path, out = sys.argv[1:4]
archive = gzip.open(src, "rb").read()
new_bin = open(new_bin_path, "rb").read()
result = bytearray()
pos = 0
replaced = 0
while True:
    header = archive[pos:pos + 110]
    if len(header) < 110 or header[:6] != b"070701":
        raise SystemExit("不是 newc 格式的 cpio（偏移 %d）" % pos)
    fields = [int(header[6 + i * 8: 14 + i * 8], 16) for i in range(13)]
    ino, mode, uid, gid, nlink, mtime, filesize, devmaj, devmin, rdevmaj, rdevmin, namesize, check = fields
    name_start = pos + 110
    name = archive[name_start:name_start + namesize - 1].decode("utf-8", "replace")
    data_start = name_start + namesize + pad4(110 + namesize)
    data = archive[data_start:data_start + filesize]
    next_pos = data_start + filesize + pad4(filesize)
    if name.lstrip("./") == "sbin/deskbox-bootstrap" and (mode & 0o170000) == 0o100000:
        if nlink != 1:
            raise SystemExit("sbin/deskbox-bootstrap 有 %d 个硬链接，无法就地替换" % nlink)
        data = new_bin
        fields[6] = len(new_bin)
        header = b"070701" + b"".join(b"%08X" % f for f in fields)
        replaced += 1
    result += header + archive[name_start:name_start + namesize] + b"\0" * pad4(110 + namesize)
    result += data + b"\0" * pad4(len(data))
    pos = next_pos
    if name == "TRAILER!!!":
        break
if replaced != 1:
    raise SystemExit("在 initrd 里找到 %d 个 sbin/deskbox-bootstrap（期望 1）" % replaced)
result += b"\0" * ((512 - len(result) % 512) % 512)
with gzip.GzipFile(out, "wb", compresslevel=1, mtime=0) as f:
    f.write(bytes(result))
PY

cp -c "$SRC/vmlinuz-virt" "$OUT/vmlinuz-virt" 2>/dev/null || cp "$SRC/vmlinuz-virt" "$OUT/vmlinuz-virt"
cp -c "$SRC/root-disk.raw" "$OUT/root-disk.raw" 2>/dev/null || cp "$SRC/root-disk.raw" "$OUT/root-disk.raw"
"$BIN" make-manifest --kernel "$OUT/vmlinuz-virt" --initrd "$OUT/initrd-deskbox.img" \
  --root-disk "$OUT/root-disk.raw" --output "$OUT/manifest.unsigned.json" >/dev/null
# PATCHED_GUEST_SIGN_KEY：给出开发签名私钥时签名（GUI 自检走的是不带 --allow-unsigned-manifest 的正常路径）。
if [ -n "${PATCHED_GUEST_SIGN_KEY:-}" ] && [ -f "$PATCHED_GUEST_SIGN_KEY" ]; then
  "$BIN" sign-manifest --manifest "$OUT/manifest.unsigned.json" --key "$PATCHED_GUEST_SIGN_KEY" --output "$OUT/manifest.json" >/dev/null
else
  cp "$OUT/manifest.unsigned.json" "$OUT/manifest.json"
fi
echo "patched guest at $OUT（未签名 manifest：run 时需 --allow-unsigned-manifest）"
