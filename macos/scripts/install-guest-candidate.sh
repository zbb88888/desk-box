#!/usr/bin/env bash
# M38：把一套已经验证过的 guest 候选资产安装到 guest 目录（带备份，可回滚）。
#
#   ./scripts/install-guest-candidate.sh <候选目录> [guest 目录=./guest]
#   ./scripts/install-guest-candidate.sh --rollback <备份目录> [guest 目录=./guest]
#
# 候选目录由 `./scripts/build-alpine-guest.sh <候选目录>` 产生（见 docs/design/m38-guest-candidate.md）。
# 安装的正是你验证过的那些字节——不是重新构建一遍。
#
# 做什么：
#   1. 校验候选（validate-assets：签名与全部文件摘要）；不通过则什么都不改；
#   2. 把 guest 目录里将被替换的文件**移动**到 <guest>/.backup-<UTC 时间>/（同卷 rename，不占额外空间）；
#   3. 逐个文件「拷到临时名 → rename」换入（每个文件的替换是原子的；已打开旧文件的 VM 不受影响）；
#   4. 如果 guest 目录里有 GPU 内核（vmlinuz-virt-gpu），用同一把开发密钥重新生成 manifest-gpu.json
#      （它引用的 initrd / root 盘摘要变了）；
#   5. 再次校验安装结果；任何一步失败都自动回滚到备份。
# 不做什么：不碰 dev-sign-key.local、release-keys.json、vmlinuz-virt-gpu、cows/ 以及其它不认识的文件；
#   不停止、不重启任何 daemon（正在运行的沙箱继续用旧字节，新建的沙箱用新资产）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/release/dbx-poc}"
# 候选里会被安装的文件。前三个加 manifest 是必需的，其余有就装。
REQUIRED="vmlinuz-virt initrd-deskbox.img root-disk.raw manifest.json"
OPTIONAL="manifest.unsigned.json sbom.json guest-bootstrap.c brokerreq.c hardening-probe.c kernel-format.txt debian-initrd.gz"

die() { echo "install-guest-candidate: $*" >&2; exit 1; }
[ -x "$BIN" ] || die "找不到 dbx-poc：$BIN（先 swift build -c release --product dbx-poc）"

restore_from() { # <备份目录> <guest 目录>：把备份里的每个文件放回去；备份里没有的「本次新增文件」删掉
  local backup="$1" guest="$2" f
  [ -f "$backup/.installed-files" ] || die "不是一个安装备份目录：$backup"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$backup/$f" ]; then mv -f "$backup/$f" "$guest/$f"; else rm -f "$guest/$f"; fi
  done < "$backup/.installed-files"
  rm -f "$backup/.installed-files"
  rmdir "$backup" 2>/dev/null || true
}

if [ "${1:-}" = "--rollback" ]; then
  BACKUP="$(cd "${2:?usage: --rollback <备份目录> [guest 目录]}" && pwd)"
  GUEST="$(cd "${3:-$ROOT/guest}" && pwd)"
  case "$BACKUP" in "$GUEST"/.backup-*) ;; *) die "备份目录必须是 $GUEST/.backup-*：$BACKUP" ;; esac
  restore_from "$BACKUP" "$GUEST"
  "$BIN" validate-assets "$GUEST/manifest.json" >/dev/null || die "回滚后的 manifest 校验失败（备份本身就不一致？）"
  echo "已回滚到 $BACKUP 中的资产"
  exit 0
fi

CAND="$(cd "${1:?usage: install-guest-candidate.sh <候选目录> [guest 目录]}" && pwd)"
GUEST="$(cd "${2:-$ROOT/guest}" && pwd)"
[ "$CAND" != "$GUEST" ] || die "候选目录和 guest 目录是同一个"
for f in $REQUIRED; do [ -f "$CAND/$f" ] || die "候选缺少 $f"; done
"$BIN" validate-assets "$CAND/manifest.json" >/dev/null || die "候选校验失败（签名或摘要不符），未做任何改动"

BACKUP="$GUEST/.backup-$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "$BACKUP" ] || die "备份目录已存在：$BACKUP"
mkdir "$BACKUP"
: > "$BACKUP/.installed-files"
STAGED=""
rollback() {
  local rc=$?
  trap - EXIT
  # shellcheck disable=SC2086
  for t in $STAGED; do rm -f "$t"; done
  restore_from "$BACKUP" "$GUEST"
  echo "install-guest-candidate: 安装失败，已回滚，guest 目录保持原样" >&2
  exit "${rc:-1}"
}
trap rollback EXIT
trap 'exit 130' INT TERM

install_one() { # <源文件> <目标文件名>
  local src="$1" name="$2" tmp="$GUEST/.incoming-$2.$$"
  STAGED="$STAGED $tmp"
  cp -c "$src" "$tmp" 2>/dev/null || cp "$src" "$tmp"
  printf '%s\n' "$name" >> "$BACKUP/.installed-files"
  [ ! -e "$GUEST/$name" ] || mv "$GUEST/$name" "$BACKUP/$name"
  mv -f "$tmp" "$GUEST/$name"
}

for f in $REQUIRED $OPTIONAL; do
  [ -f "$CAND/$f" ] || continue
  install_one "$CAND/$f" "$f"
done
[ -z "${DBX_INSTALL_FAIL_AFTER_COPY:-}" ] || { echo "（测试钩子：在换入之后、校验之前失败）" >&2; exit 1; }

# GPU manifest：内核不变，但 initrd / root 盘的摘要变了。
if [ -f "$GUEST/vmlinuz-virt-gpu" ]; then
  [ -f "$GUEST/dev-sign-key.local" ] || die "guest 目录有 GPU 内核但没有 dev-sign-key.local，无法重新签 manifest-gpu.json"
  SBOM_ARGS=""
  [ ! -f "$GUEST/sbom.json" ] || SBOM_ARGS="--sbom-digest $(shasum -a 256 "$GUEST/sbom.json" | awk '{print $1}')"
  # shellcheck disable=SC2086
  "$BIN" make-manifest --kernel "$GUEST/vmlinuz-virt-gpu" --initrd "$GUEST/initrd-deskbox.img" \
    --root-disk "$GUEST/root-disk.raw" --asset-version 1 $SBOM_ARGS --output "$BACKUP/.gpu.unsigned.json" >/dev/null
  "$BIN" sign-manifest --manifest "$BACKUP/.gpu.unsigned.json" --key "$GUEST/dev-sign-key.local" \
    --output "$BACKUP/.gpu.json" >/dev/null
  install_one "$BACKUP/.gpu.unsigned.json" manifest-gpu.unsigned.json
  install_one "$BACKUP/.gpu.json" manifest-gpu.json
  rm -f "$BACKUP/.gpu.unsigned.json" "$BACKUP/.gpu.json"
  "$BIN" validate-assets "$GUEST/manifest-gpu.json" >/dev/null || die "安装后的 manifest-gpu.json 校验失败"
fi
"$BIN" validate-assets "$GUEST/manifest.json" >/dev/null || die "安装后的 manifest.json 校验失败"

trap - EXIT
echo "已安装 $CAND → $GUEST"
echo "备份：$BACKUP"
echo "回滚：$0 --rollback $BACKUP $GUEST"
echo "确认没问题后可删除备份：rm -rf $BACKUP"
