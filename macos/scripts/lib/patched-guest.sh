# 供 e2e-*-patched.sh source：准备一套「当前源码的 guest bootstrap」的补丁版 guest（测试夹具）。
#
#   patched_guest_prepare <tag> [variant]
#                                 → 成功后设置 PATCHED_MANIFEST；不可用时打印 SKIP 结果并 exit 0；
#                                   guest 源码编译失败时打印 FAIL 结果并 exit 1。
#   variant（M46）：缺省是普通夹具；`faults` = 用 -DDBX_TEST_FAULTS 编译（带仅用于测试的故障注入），
#                   并用本机开发密钥签名（有的话）。两种夹具各自缓存。
#
# 构建约 30 秒。e2e-all.sh 通过 E2E_PATCHED_GUEST_DIR 让同一次运行里的多个套件共用一份；
# 单独运行时构建在自己的临时目录里，退出即删。
# 不修改 guest/ 下的现有资产。需要 aarch64-linux-musl 交叉编译器与网络（libsodium 源码包）。

patched_guest_prepare() {
  local tag="$1" variant="${2:-}" root dir own=0
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  _pg_skip() { printf '[%s] SKIP: 补丁版 guest 套件未运行：%s\n\n[%s] 结果：PASS=0 FAIL=0 SKIP=1\n' "$tag" "$1" "$tag"; exit 0; }

  command -v "${CROSS_CC:-aarch64-linux-musl-gcc}" >/dev/null 2>&1 || _pg_skip "没有 aarch64-linux-musl 交叉编译器"
  [ -f "$root/guest/initrd-deskbox.img" ] || _pg_skip "guest/ 下没有现成的 guest 资产可供打补丁"
  [ -x "$root/.build/release/dbx-poc" ] || _pg_skip "dbx-poc 尚未构建"

  if [ -n "${E2E_PATCHED_GUEST_DIR:-}" ]; then
    dir="$E2E_PATCHED_GUEST_DIR${variant:+-$variant}"
  else
    dir="$(mktemp -d /tmp/dbx-pgfix.XXXXXX)"; own=1
    PATCHED_GUEST_OWNED_DIR="$dir"
    trap 'rm -rf "$PATCHED_GUEST_OWNED_DIR"' EXIT
  fi
  # 复用条件：上一次构建完成（有 manifest）且用的是同一份 bootstrap 源码。
  local want; want="$(shasum -a 256 "$root/scripts/guest-bootstrap.c" | awk '{print $1}')"
  if [ -f "$dir/manifest.json" ] && [ "$(cat "$dir/.bootstrap-sha" 2>/dev/null)" = "$want" ]; then
    printf '[%s] 复用已构建的补丁版 guest\n' "$tag"
  else
    mkdir -p "$dir"
    local cflags="" signkey=""
    if [ "$variant" = faults ]; then
      cflags="-DDBX_TEST_FAULTS"
      [ -f "$root/guest/dev-sign-key.local" ] && signkey="$root/guest/dev-sign-key.local"
    fi
    if ! PATCHED_GUEST_CFLAGS="$cflags" PATCHED_GUEST_SIGN_KEY="$signkey" \
         "$root/scripts/build-patched-guest.sh" "$root/guest" "$dir" >"$dir/build.log" 2>&1; then
      # 编译错误不是「环境缺工具」：那是 guest 源码坏了，必须失败。
      if grep -q 'bootstrap 编译失败\|不是静态链接\|在 initrd 里找到' "$dir/build.log"; then
        printf '[%s] FAIL: 补丁版 guest 构建失败（guest 源码问题）：\n' "$tag"; tail -20 "$dir/build.log"
        printf '\n[%s] 结果：PASS=0 FAIL=1 SKIP=0\n' "$tag"; exit 1
      fi
      _pg_skip "构建环境不可用：$(tail -2 "$dir/build.log" | tr '\n' ' ')"
    fi
    printf '%s\n' "$want" > "$dir/.bootstrap-sha"
    printf '[%s] 补丁版 guest 已构建（%s 条编译警告）\n' "$tag" "$(grep -c 'warning:' "$dir/build.log" || true)"
  fi
  : "$own"
  PATCHED_MANIFEST="$dir/manifest.json"
}
