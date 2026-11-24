#!/usr/bin/env bash
# M37：用**当前源码**的 guest bootstrap 跑 workspace 同步套件（验证 guest 侧的修复）。
#
# 先用 build-patched-guest.sh 在临时目录里构建一套补丁版 guest（只替换 initrd 里的 bootstrap），
# 再对它运行 e2e-workspace-sync.sh。不修改 guest/ 下的现有资产。
#
# 构建需要 aarch64-linux-musl 交叉编译器与网络（下载 libsodium 源码包）。任何一项不可用时
# 整个套件 SKIP 并说明原因（退出码 0）——它不该因为本机缺工具而变红，但 SKIP 会如实显示。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FIX="$(mktemp -d /tmp/dbx-pgfix.XXXXXX)"
trap 'rm -rf "$FIX"' EXIT

skip_suite() { printf '[wsp] SKIP: 补丁版 guest 套件未运行：%s\n\n[wsp] 结果：PASS=0 FAIL=0 SKIP=1\n' "$1"; exit 0; }

command -v "${CROSS_CC:-aarch64-linux-musl-gcc}" >/dev/null 2>&1 || skip_suite "没有 aarch64-linux-musl 交叉编译器"
[ -f "$ROOT/guest/initrd-deskbox.img" ] || skip_suite "guest/ 下没有现成的 guest 资产可供打补丁"
[ -x "$ROOT/.build/release/dbx-poc" ] || ( swift build -c release --product dbx-poc >/dev/null 2>&1 ) || skip_suite "dbx-poc 构建失败"

if ! ./scripts/build-patched-guest.sh "$ROOT/guest" "$FIX" >"$FIX/build.log" 2>&1; then
  # 编译错误不是「环境缺工具」：那是 guest 源码坏了，必须失败。
  if grep -q 'bootstrap 编译失败\|不是静态链接\|在 initrd 里找到' "$FIX/build.log"; then
    printf '[wsp] FAIL: 补丁版 guest 构建失败（guest 源码问题）：\n'; tail -20 "$FIX/build.log"
    printf '\n[wsp] 结果：PASS=0 FAIL=1 SKIP=0\n'; exit 1
  fi
  skip_suite "构建环境不可用：$(tail -2 "$FIX/build.log" | tr '\n' ' ')"
fi
printf '[wsp] 补丁版 guest 已构建：%s\n' "$(grep -c 'warning:' "$FIX/build.log" || true) 条编译警告"

MANIFEST="$FIX/manifest.json" RUN_FLAGS=--allow-unsigned-manifest EXPECT_RECEIVER_VERSION=2 ./scripts/e2e-workspace-sync.sh
RC=$?
# 这个套件存在的意义就是验证新接收端：如果它跑到的还是旧接收端，说明补丁没有生效。
exit $RC
