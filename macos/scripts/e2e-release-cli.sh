#!/usr/bin/env bash
# M34：签名 / 发布 / 校验类子命令的端到端测试（不需要 VM、不起 daemon，几秒跑完）。
#
#   R1  密钥生成：私钥文件 0600（含覆盖旧的 0644 文件）；公开的 release-keys.json 不受影响
#   R2  make-manifest → sign-manifest → validate-assets → publish → verify-channel → check-update 正向链路
#   R3  防回滚下限：拼对时被执行（floor > assetVersion 时 publish 被拒）
#   N*  拼错的选项 / 缺值 / 非法整数：一律 exit 2，并且**没有副作用**
#       （不产出文件、不改动已有文件；此前会静默忽略并继续执行）
#   K*  密钥轮换 / 撤销：--output 指向新文件时 --base 不被改动；用已退役的 key 签名的 manifest 无法发布
#
# 资源纪律：scripts/lib/e2e-common.sh（全部文件在临时目录，退出自动清理）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init rel
# 不需要 guest manifest，也不需要签名（不触碰 Virtualization）；只要有可执行文件。
if [ "${E2E_SKIP_BUILD:-0}" != 1 ]; then
  ( cd "$E2E_ROOT" && swift build -c release --product dbx-poc >/dev/null 2>&1 ) || die "swift build failed"
  e2e_sign_if_needed
fi
[ -x "$BIN" ] || die "dbx-poc 不存在：$BIN"
cd "$E2E_ROOT"

W="$E2E_WORK/rel"; mkdir -p "$W/assets" "$W/channel"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
mode() { stat -f '%Lp' "$1" 2>/dev/null; }
# reject <描述> <期望子串> -- <命令...>：必须 exit 2 且 stderr 含子串。
reject() {
  local what="$1" needle="$2"; shift 3
  "$@" >"$E2E_WORK/rej.out" 2>&1; local rc=$?
  if [ "$rc" = 2 ] && grep -qF -- "$needle" "$E2E_WORK/rej.out"; then pass "$what"
  else fail "$what：rc=$rc（期望 2）$(head -c 200 "$E2E_WORK/rej.out")"; fi
}
unchanged() { # <描述> <文件> <之前的 sha>
  [ "$(sha "$2")" = "$3" ] && pass "$1" || fail "$1：文件被改动了"
}

# 假资产（内容随意；本测试只关心签名 / 摘要 / 版本链路）。
head -c 4096 /dev/urandom > "$W/assets/vmlinuz"
head -c 8192 /dev/urandom > "$W/assets/initrd.img"
head -c 16384 /dev/urandom > "$W/assets/root.raw"
printf '{"schema":"deskbox-sbom/test","note":"e2e"}\n' > "$W/assets/sbom.json"
SBOM_SHA=$(sha "$W/assets/sbom.json")

# ================= R1：密钥 =================
"$BIN" gen-release-key --output-key "$W/channel/release-key.local" >"$E2E_WORK/k1.out" 2>&1 || fail "gen-release-key 失败：$(cat "$E2E_WORK/k1.out")"
[ "$(mode "$W/channel/release-key.local")" = 600 ] && pass "R1 release 私钥权限 0600" || fail "R1 release 私钥权限=$(mode "$W/channel/release-key.local")"
grep -q '^private:' "$W/channel/release-key.local" && pass "R1 私钥文件内容格式正确" || fail "R1 私钥文件内容异常"
[ -f "$W/channel/release-keys.json" ] && ! grep -q 'private' "$W/channel/release-keys.json" \
  && pass "R1 release-keys.json 已生成且不含私钥材料" || fail "R1 release-keys.json 异常"
"$BIN" gen-guest-sign-key --output-key "$W/guest-sign.local" >/dev/null 2>&1
[ "$(mode "$W/guest-sign.local")" = 600 ] && pass "R1 guest 签名私钥权限 0600" || fail "R1 guest 私钥权限=$(mode "$W/guest-sign.local")"
# 覆盖一个旧版本留下的 0644 私钥：结果必须是 0600。
printf 'private:old\n' > "$W/legacy.local"; chmod 644 "$W/legacy.local"
"$BIN" gen-guest-sign-key --output-key "$W/legacy.local" >/dev/null 2>&1
[ "$(mode "$W/legacy.local")" = 600 ] && ! grep -q 'private:old' "$W/legacy.local" \
  && pass "R1 覆盖旧的 0644 私钥后权限收紧为 0600" || fail "R1 覆盖后权限=$(mode "$W/legacy.local")"
( umask 000; "$BIN" gen-guest-sign-key --output-key "$W/umask.local" >/dev/null 2>&1 )
[ "$(mode "$W/umask.local")" = 600 ] && pass "R1 umask 000 下私钥仍是 0600" || fail "R1 umask 000 下权限=$(mode "$W/umask.local")"
LEFT=$(ls -A "$W" "$W/channel" | grep -c '\.tmp-' || true)
[ "$LEFT" = 0 ] && pass "R1 没有遗留临时私钥文件" || fail "R1 遗留 $LEFT 个临时文件"

# ================= R2：正向链路 =================
"$BIN" make-manifest --kernel "$W/assets/vmlinuz" --initrd "$W/assets/initrd.img" --root-disk "$W/assets/root.raw" \
  --asset-version 3 --sbom-digest "$SBOM_SHA" --output "$W/assets/manifest.unsigned.json" >"$E2E_WORK/mm.out" 2>&1 \
  && pass "R2 make-manifest" || fail "R2 make-manifest：$(cat "$E2E_WORK/mm.out")"
python3 - "$W/assets/manifest.unsigned.json" "$SBOM_SHA" <<'PY' && pass "R2 manifest 记录了 assetVersion=3 与 sbomDigest" || fail "R2 manifest 内容不符"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["guestAssetVersion"] == 3 and d["sbomDigest"] == sys.argv[2] and d.get("signature") is None
PY
"$BIN" sign-manifest --manifest "$W/assets/manifest.unsigned.json" --key "$W/channel/release-key.local" \
  --output "$W/assets/manifest.json" >"$E2E_WORK/sm.out" 2>&1 && pass "R2 sign-manifest" || fail "R2 sign-manifest：$(cat "$E2E_WORK/sm.out")"
"$BIN" validate-assets "$W/assets/manifest.json" --release-keys "$W/channel/release-keys.json" >"$E2E_WORK/va.out" 2>&1 \
  && pass "R2 validate-assets（对 release-keys 链校验）" || fail "R2 validate-assets：$(cat "$E2E_WORK/va.out")"
# 选项在位置参数之前同样可用。
"$BIN" validate-assets --release-keys "$W/channel/release-keys.json" "$W/assets/manifest.json" >/dev/null 2>&1 \
  && pass "R2 validate-assets：选项位置无关" || fail "R2 选项前置失败"
"$BIN" publish --channel "$W/channel" --manifest "$W/assets/manifest.json" --sbom "$W/assets/sbom.json" \
  --release-keys "$W/channel/release-keys.json" --release-tag v1.2.3 --min-version-floor 2 >"$E2E_WORK/pub.out" 2>&1 \
  && pass "R2 publish" || fail "R2 publish：$(cat "$E2E_WORK/pub.out")"
CHANNEL="$W/channel/channel.json"
python3 - "$CHANNEL" <<'PY' && pass "R2 channel.json：releaseTag=v1.2.3，minGuestAssetVersionFloor=2，assetVersion=3" || fail "R2 channel.json 内容不符"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["releaseTag"] == "v1.2.3" and d["minGuestAssetVersionFloor"] == 2 and d["manifest"]["assetVersion"] == 3
PY
"$BIN" verify-channel "$CHANNEL" >"$E2E_WORK/vc.out" 2>&1 && pass "R2 verify-channel" || fail "R2 verify-channel：$(cat "$E2E_WORK/vc.out")"
OUT=$("$BIN" check-update --channel "$CHANNEL" --current-version 1.2.3 --json 2>&1)
echo "$OUT" | grep -q 'up-to-date' && pass "R2 check-update：同版本 → up-to-date" || fail "R2 check-update：$OUT"
OUT=$("$BIN" check-update "$CHANNEL" --current-version 1.0.0 --json 2>&1)
echo "$OUT" | grep -q 'available' && pass "R2 check-update：channel 作为位置参数；低版本 → available" || fail "R2 check-update 位置参数：$OUT"
"$BIN" check-update --channel "$CHANNEL" --current-version 9.9.9 --json >/dev/null 2>&1; RC=$?
[ "$RC" = 3 ] && pass "R2 check-update：回滚被拒（exit 3，与参数错误的 exit 2 区分）" || fail "R2 回滚退出码=$RC"

# ================= R3：防回滚下限拼对时被执行 =================
CH_SHA=$(sha "$CHANNEL")
"$BIN" publish --channel "$W/channel" --manifest "$W/assets/manifest.json" --sbom "$W/assets/sbom.json" \
  --release-keys "$W/channel/release-keys.json" --min-version-floor 5 >"$E2E_WORK/floor.out" 2>&1; RC=$?
[ "$RC" != 0 ] && grep -q 'floor' "$E2E_WORK/floor.out" && pass "R3 floor(5) > assetVersion(3)：publish 被拒" || fail "R3 floor 未生效：rc=$RC $(cat "$E2E_WORK/floor.out")"
unchanged "R3 被拒的 publish 没有改动 channel.json" "$CHANNEL" "$CH_SHA"

# ================= N：拼错 / 缺值 / 非法值 → exit 2 且无副作用 =================
PUB=( "$BIN" publish --channel "$W/channel" --manifest "$W/assets/manifest.json" --sbom "$W/assets/sbom.json" --release-keys "$W/channel/release-keys.json" )
# 此前：--min-version-flor 被忽略，floor 悄悄变回 1，并且**重写** channel.json。
reject "N1 publish --min-version-flor（拼错）被拒" "unknown option '--min-version-flor'" -- "${PUB[@]}" --min-version-flor 5
unchanged "N1 channel.json 未被重写（floor 仍是 2）" "$CHANNEL" "$CH_SHA"
reject "N2 publish --min-version-floor abc 被拒" "invalid value for --min-version-floor" -- "${PUB[@]}" --min-version-floor abc
reject "N2 publish --min-version-floor -1 被拒" "invalid value for --min-version-floor" -- "${PUB[@]}" --min-version-floor -1
unchanged "N2 channel.json 未被重写" "$CHANNEL" "$CH_SHA"

reject "N3 sign-manifest --asset-versoin（拼错）被拒" "unknown option '--asset-versoin'" -- \
  "$BIN" sign-manifest --manifest "$W/assets/manifest.unsigned.json" --key "$W/channel/release-key.local" --output "$W/assets/should-not-exist.json" --asset-versoin 7
[ ! -e "$W/assets/should-not-exist.json" ] && pass "N3 被拒的 sign-manifest 没有产出文件" || fail "N3 产出了签名文件"
reject "N3 sign-manifest：--manifest 的值是另一个选项" "missing value for --manifest" -- \
  "$BIN" sign-manifest --manifest --key "$W/channel/release-key.local" --output "$W/assets/should-not-exist.json"

reject "N4 make-manifest --sbom-digset（拼错）被拒" "unknown option '--sbom-digset'" -- \
  "$BIN" make-manifest --kernel "$W/assets/vmlinuz" --root-disk "$W/assets/root.raw" --output "$W/assets/nope.json" --sbom-digset "$SBOM_SHA"
reject "N4 make-manifest --asset-version -1 被拒" "invalid value for --asset-version" -- \
  "$BIN" make-manifest --kernel "$W/assets/vmlinuz" --root-disk "$W/assets/root.raw" --output "$W/assets/nope.json" --asset-version -1
[ ! -e "$W/assets/nope.json" ] && pass "N4 被拒的 make-manifest 没有产出文件" || fail "N4 产出了 manifest"

# 此前：没有 --channel 时把「第一个不以 -- 开头的参数」当成 channel——这里是 --current-version 的值。
reject "N5 check-update 只给 --current-version：不把它的值当成 channel 路径" "channel path required" -- "$BIN" check-update --current-version 9.9.9
reject "N5 check-update --current-versoin（拼错）被拒" "unknown option '--current-versoin'" -- "$BIN" check-update --channel "$CHANNEL" --current-versoin 0.1.0
reject "N5 check-update 同时给 --channel 与位置参数被拒" "already given via --channel" -- "$BIN" check-update --channel "$CHANNEL" "$CHANNEL"

reject "N6 validate-assets --release-key（拼错）被拒（否则会退回无链校验）" "unknown option '--release-key'" -- \
  "$BIN" validate-assets "$W/assets/manifest.json" --release-key "$W/channel/release-keys.json"
reject "N6 verify-channel 多余参数被拒" "unexpected argument" -- "$BIN" verify-channel "$CHANNEL" extra
reject "N6 version 不接受参数" "unknown option" -- "$BIN" version --json
t0=$(now_ms)
reject "N7 launch 未知选项被拒" "unknown option '--memroy-mib'" -- "$BIN" launch "$W/assets/manifest.json" --memroy-mib 512
[ $(( $(now_ms) - t0 )) -lt 2000 ] && pass "N7 launch 在解析阶段即被拒（未触碰 Virtualization）" || fail "N7 launch 拒绝过慢"
reject "N7 launch --cpus 0 被拒" "invalid value for --cpus" -- "$BIN" launch "$W/assets/manifest.json" --cpus 0
reject "N8 gen-release-key 缺值被拒" "missing value for --output-key" -- "$BIN" gen-release-key --output-key
reject "N8 未知子命令被拒" "unknown command" -- "$BIN" publsh

# ================= K：轮换 / 撤销 =================
KEYS="$W/channel/release-keys.json"; KEYS_SHA=$(sha "$KEYS")
"$BIN" gen-guest-sign-key --output-key "$W/new-release-key.local" >/dev/null 2>&1
# 此前：--ouput 被忽略 → 原地覆盖 --base。
reject "K1 rotate-release-key --ouput（拼错）被拒" "unknown option '--ouput'" -- \
  "$BIN" rotate-release-key --base "$KEYS" --new-key "$W/new-release-key.local" --ouput "$W/rotated.json"
unchanged "K1 --base 没有被原地覆盖" "$KEYS" "$KEYS_SHA"
"$BIN" rotate-release-key --base "$KEYS" --new-key "$W/new-release-key.local" --output "$W/rotated.json" >"$E2E_WORK/rot.out" 2>&1 \
  && pass "K2 rotate-release-key --output 到新文件" || fail "K2 rotate：$(cat "$E2E_WORK/rot.out")"
unchanged "K2 --output 指向新文件时 --base 不变" "$KEYS" "$KEYS_SHA"
python3 - "$W/rotated.json" <<'PY' && pass "K2 轮换后：旧 key retired，新 key active" || fail "K2 轮换结果不符"
import json, sys
keys = json.load(open(sys.argv[1]))["keys"]
assert [k["status"] for k in keys] == ["retired", "active"], keys
PY
# 用已退役的 key 签名的 manifest 不能再发布。
"$BIN" publish --channel "$W/channel2" --manifest "$W/assets/manifest.json" --sbom "$W/assets/sbom.json" \
  --release-keys "$W/rotated.json" >"$E2E_WORK/retired.out" 2>&1; RC=$?
[ "$RC" != 0 ] && grep -q 'active key' "$E2E_WORK/retired.out" && [ ! -e "$W/channel2/channel.json" ] \
  && pass "K3 用已退役 key 签名的 manifest 无法发布，且没有产出 channel.json" || fail "K3 退役 key 仍可发布：rc=$RC $(cat "$E2E_WORK/retired.out")"
OLD_ID=$(python3 -c "import json;print(json.load(open('$KEYS'))['keys'][0]['keyID'])")
ROT_SHA=$(sha "$W/rotated.json")
reject "K4 revoke-release-key --ouput（拼错）被拒" "unknown option '--ouput'" -- \
  "$BIN" revoke-release-key --base "$W/rotated.json" --key-id "$OLD_ID" --ouput "$W/revoked.json"
unchanged "K4 --base 没有被原地覆盖" "$W/rotated.json" "$ROT_SHA"
"$BIN" revoke-release-key --base "$W/rotated.json" --key-id "$OLD_ID" --output "$W/revoked.json" >/dev/null 2>&1 \
  && python3 -c "import json;k=json.load(open('$W/revoked.json'))['keys'];assert k[0]['status']=='revoked' and k[1]['status']=='active'" \
  && pass "K5 revoke-release-key：指定 key 变为 revoked" || fail "K5 revoke 结果不符"
unchanged "K5 --output 指向新文件时 --base 不变" "$W/rotated.json" "$ROT_SHA"

# 全程不应产生任何 daemon / VM。
[ -z "$(pgrep -f "$E2E_WORK" | tr '\n' ' ')" ] && pass "没有遗留进程" || fail "遗留进程：$(pgrep -fl "$E2E_WORK")"

e2e_finish
