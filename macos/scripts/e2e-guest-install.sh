#!/usr/bin/env bash
# M38：install-guest-candidate.sh 的端到端测试（不需要 VM；用小的合成资产，几秒跑完）。
#
#   I1  正常安装：guest 目录里的资产 = 候选的字节；旧文件进了备份；不认识的文件 / 密钥 / cows 不被碰；
#       manifest.json 与重新生成的 manifest-gpu.json 都通过校验；没有残留的临时文件
#   I2  回滚：guest 目录逐字节回到安装前；备份目录消失
#   I3  候选被篡改 / 未签名 / 缺文件：拒绝，guest 目录完全没动（连备份目录都不留）
#   I4  安装中途失败：自动回滚，guest 目录逐字节回到安装前
#   I5  --rollback 只接受 <guest>/.backup-* 下的目录
#
# 资源纪律：scripts/lib/e2e-common.sh（全部文件在临时目录，退出自动清理）。绝不触碰真实的 guest/ 目录
#（只读取其中的开发签名密钥，拷一份 0600 的副本到临时目录）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init gi
DEVKEY="$E2E_ROOT/guest/dev-sign-key.local"
if [ ! -f "$DEVKEY" ] || [ ! -f "$E2E_ROOT/guest/manifest.json" ]; then
  skip "没有本机 guest 资产 / 开发签名密钥（guest/dev-sign-key.local），无法构造可通过校验的候选"
  e2e_finish; exit $?
fi
# 用 e2e_build_sign 而不是裸的 swift build：重新链接会丢掉签名，之后带 E2E_SKIP_BUILD=1 跑的
# VM 套件会因缺 virtualization entitlement 而失败（这个脚本自己不需要签名）。
e2e_build_sign
cd "$E2E_ROOT"
INSTALL="$E2E_ROOT/scripts/install-guest-candidate.sh"
REAL_BEFORE=$(ls -la "$E2E_ROOT/guest" | shasum | awk '{print $1}')

# tree_sum <目录>：目录下全部文件（含隐藏）的相对路径 + 内容摘要 + 权限 → 一个摘要
tree_sum() { ( cd "$1" && find . -type f -o -type d | LC_ALL=C sort | while IFS= read -r p; do
    if [ -f "$p" ]; then printf '%s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(shasum -a 256 "$p" | awk '{print $1}')"; else printf '%s dir\n' "$p"; fi
  done | shasum -a 256 | awk '{print $1}' ); }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
# make_assets <目录> <标记>：一套合成资产 + 用开发密钥签名的 manifest
make_assets() {
  local dir="$1" tag="$2"; mkdir -p "$dir"
  printf 'kernel-%s\n' "$tag" > "$dir/vmlinuz-virt"
  printf 'initrd-%s\n' "$tag" > "$dir/initrd-deskbox.img"
  printf 'rootdisk-%s\n' "$tag" > "$dir/root-disk.raw"
  printf '{"sbom":"%s"}\n' "$tag" > "$dir/sbom.json"
  printf '/* bootstrap %s */\n' "$tag" > "$dir/guest-bootstrap.c"
  "$BIN" make-manifest --kernel "$dir/vmlinuz-virt" --initrd "$dir/initrd-deskbox.img" --root-disk "$dir/root-disk.raw" \
    --asset-version 1 --sbom-digest "$(sha "$dir/sbom.json")" --output "$dir/manifest.unsigned.json" >/dev/null || die "make-manifest 失败"
  "$BIN" sign-manifest --manifest "$dir/manifest.unsigned.json" --key "$E2E_WORK/key" --output "$dir/manifest.json" >/dev/null || die "sign-manifest 失败"
}
( umask 077; cp "$DEVKEY" "$E2E_WORK/key" )

G="$E2E_WORK/guest"; make_assets "$G" old
printf 'gpu-kernel\n' > "$G/vmlinuz-virt-gpu"
"$BIN" make-manifest --kernel "$G/vmlinuz-virt-gpu" --initrd "$G/initrd-deskbox.img" --root-disk "$G/root-disk.raw" --output "$G/manifest-gpu.unsigned.json" >/dev/null
"$BIN" sign-manifest --manifest "$G/manifest-gpu.unsigned.json" --key "$E2E_WORK/key" --output "$G/manifest-gpu.json" >/dev/null
( umask 077; cp "$E2E_WORK/key" "$G/dev-sign-key.local" )
printf 'mine\n' > "$G/keep-me.txt"; printf '{}\n' > "$G/release-keys.json"; mkdir -p "$G/cows"; printf 'cow\n' > "$G/cows/a.vhd"
"$BIN" validate-assets "$G/manifest.json" >/dev/null 2>&1 || {
  # 本机二进制不信任这把密钥（例如 CI 用的是另一把）：这不是被测脚本的问题。
  skip "本机构建的 dbx-poc 不信任 guest/dev-sign-key.local 对应的公钥，无法构造可通过校验的候选"
  e2e_finish; exit $?
}
C="$E2E_WORK/cand"; make_assets "$C" new
ORIG=$(tree_sum "$G")

# ---------- I3：坏候选，什么都不改 ----------
refuse() { # <描述> <候选目录> <期望子串>
  "$INSTALL" "$2" "$G" >"$E2E_WORK/out" 2>&1 && RC=0 || RC=$?
  [ "$RC" != 0 ] && grep -qF -- "$3" "$E2E_WORK/out" && pass "I3 $1：被拒绝" || fail "I3 $1：rc=$RC $(head -c 200 "$E2E_WORK/out")"
  [ "$(tree_sum "$G")" = "$ORIG" ] && pass "I3 $1：guest 目录完全没动（没有备份目录、没有临时文件）" || fail "I3 $1：guest 目录被改动：$(ls -a "$G" | tr '\n' ' ')"
}
T="$E2E_WORK/cand-tampered"; cp -R "$C" "$T"; printf 'evil\n' >> "$T/initrd-deskbox.img"
refuse "签名之后被篡改的 initrd" "$T" "候选校验失败"
U="$E2E_WORK/cand-unsigned"; cp -R "$C" "$U"; cp "$U/manifest.unsigned.json" "$U/manifest.json"
refuse "未签名的 manifest" "$U" "候选校验失败"
M="$E2E_WORK/cand-missing"; cp -R "$C" "$M"; rm "$M/root-disk.raw"
refuse "缺少 root 盘" "$M" "候选缺少 root-disk.raw"
refuse "候选目录就是 guest 目录" "$G" "同一个"

# ---------- I4：中途失败 → 自动回滚 ----------
DBX_INSTALL_FAIL_AFTER_COPY=1 "$INSTALL" "$C" "$G" >"$E2E_WORK/out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q '已回滚' "$E2E_WORK/out" && pass "I4 换入之后失败：脚本报告失败并回滚" || fail "I4 rc=$RC $(cat "$E2E_WORK/out")"
[ "$(tree_sum "$G")" = "$ORIG" ] && pass "I4 guest 目录逐字节回到安装前（没有备份目录、没有临时文件）" || fail "I4 guest 目录与安装前不同：$(ls -a "$G" | tr '\n' ' ')"

# ---------- I1：正常安装 ----------
"$INSTALL" "$C" "$G" >"$E2E_WORK/out" 2>&1 && pass "I1 安装成功" || fail "I1 安装失败：$(cat "$E2E_WORK/out")"
BK=$(sed -n 's/^备份：//p' "$E2E_WORK/out")
SAME=1; for f in vmlinuz-virt initrd-deskbox.img root-disk.raw manifest.json manifest.unsigned.json sbom.json guest-bootstrap.c; do
  [ "$(sha "$G/$f")" = "$(sha "$C/$f")" ] || { SAME=0; log "不一致：$f"; }
done
[ "$SAME" = 1 ] && pass "I1 guest 目录里的 7 个资产文件与候选逐字节一致" || fail "I1 安装结果与候选不一致"
[ -d "$BK" ] && [ "$(cat "$BK/initrd-deskbox.img")" = initrd-old ] && [ "$(cat "$BK/manifest.json" | shasum)" != "$(cat "$G/manifest.json" | shasum)" ] \
  && pass "I1 旧资产在备份目录里（$(basename "$BK")）" || fail "I1 备份目录不对：$BK"
[ "$(cat "$G/keep-me.txt")" = mine ] && [ "$(cat "$G/cows/a.vhd")" = cow ] && [ "$(cat "$G/vmlinuz-virt-gpu")" = gpu-kernel ] \
  && [ "$(sha "$G/dev-sign-key.local")" = "$(sha "$E2E_WORK/key")" ] && [ "$(stat -f %Lp "$G/dev-sign-key.local")" = 600 ] \
  && pass "I1 不认识的文件 / cows / GPU 内核 / 签名密钥都没被碰" || fail "I1 不该碰的文件被改动了"
"$BIN" validate-assets "$G/manifest.json" >/dev/null 2>&1 && pass "I1 安装后的 manifest.json 通过校验" || fail "I1 manifest.json 校验失败"
"$BIN" validate-assets "$G/manifest-gpu.json" >/dev/null 2>&1 && grep -q "$(sha "$G/initrd-deskbox.img")" "$G/manifest-gpu.json" \
  && pass "I1 manifest-gpu.json 已按新的 initrd / root 盘重新生成并通过校验" || fail "I1 manifest-gpu.json 没有更新或校验失败"
[ -z "$(ls -a "$G" | grep '^\.incoming-')" ] && pass "I1 没有残留的 .incoming-* 临时文件" || fail "I1 残留临时文件"

# ---------- I5：--rollback 的目录限制 ----------
"$INSTALL" --rollback "$C" "$G" >"$E2E_WORK/out" 2>&1 && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q '备份目录必须是' "$E2E_WORK/out" && [ "$(cat "$G/initrd-deskbox.img")" = initrd-new ] \
  && pass "I5 --rollback 拒绝不在 <guest>/.backup-* 下的目录，guest 未变" || fail "I5 rc=$RC $(cat "$E2E_WORK/out")"

# ---------- I2：回滚 ----------
"$INSTALL" --rollback "$BK" "$G" >"$E2E_WORK/out" 2>&1 && pass "I2 回滚成功" || fail "I2 回滚失败：$(cat "$E2E_WORK/out")"
[ "$(tree_sum "$G")" = "$ORIG" ] && pass "I2 guest 目录逐字节回到安装前（含 manifest-gpu.json；备份目录已消失）" || fail "I2 回滚后与安装前不同：$(ls -a "$G" | tr '\n' ' ')"

[ "$(ls -la "$E2E_ROOT/guest" | shasum | awk '{print $1}')" = "$REAL_BEFORE" ] && pass "真实的 guest/ 目录全程没有被碰" || fail "真实的 guest/ 目录发生了变化"
e2e_finish
