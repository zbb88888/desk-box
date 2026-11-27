#!/usr/bin/env bash
# M25：e2e harness 自测——证明 scripts/lib/e2e-common.sh 在**失败路径**上也能清干净。
# 不起 VM（只起 daemon），几秒跑完。
#
#   C1 正常结束                     → 目录删除、daemon 退出
#   C2 中途 exit 3（daemon 在跑）    → 同上，且退出码保持 3
#   C3 SIGTERM                      → 同上，退出码 143
#   C4 SIGINT                       → 同上，退出码 130
#   C5 daemon 先被 kill -9（stale sock）→ 同上
#   C6 e2e_extra_cleanup 钩子        → 目录外状态被还原
#   C7 E2E_KEEP=1                   → 目录保留（自测自己删）
#   C8 DBX_SUPPORT_ROOT 生效         → daemon 的 socket/状态只出现在隔离目录
#   C9 非法 DBX_SUPPORT_ROOT         → exit 2（fail-closed），不回落默认目录
#   C10 e2e_resume 的结果分类         → ok / locked（并检查锁屏不变量）/ failed，用桩验证
#   C11 证据文件的结论逻辑            → 通过 / 不完整 / 失败 / 无效（含被手改的结论），用合成证据验证
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/e2e-common.sh"
BIN="${BIN:-$ROOT/.build/release/dbx-poc}"
[ -x "$BIN" ] || { echo "[selftest] FATAL: 先构建 dbx-poc（swift build -c release --product dbx-poc）"; exit 2; }
export BIN E2E_SKIP_BUILD=1

SCRATCH="$(mktemp -d /tmp/dbx-selftest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '[selftest] PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '[selftest] FAIL: %s\n' "$1" >&2; }

# 子脚本：以 $0=scripts/<name> 运行，使 harness 能定位仓库根。
# 子脚本把自己的 E2E_WORK 与 daemon PID 写到 $INFO，供父进程事后核查。
child() { # child <name> <body>   （后台运行由调用方决定）
  INFO="$SCRATCH/$1.info" LIB="$LIB" /bin/sh -c '
    . "$LIB"
    e2e_init "st-'"$1"'"
    e2e_start_daemon || die "daemon 未就绪"
    printf "%s\n%s\n" "$E2E_WORK" "$DAEMON_PID" > "$INFO"
    '"$2"'
  ' "$ROOT/scripts/selftest-$1"
}

# verify <name> <expected-exit> <actual-exit>
verify() {
  local name="$1" want="$2" got="$3"
  local work pid
  work=$(sed -n 1p "$SCRATCH/$name.info" 2>/dev/null)
  pid=$(sed -n 2p "$SCRATCH/$name.info" 2>/dev/null)
  if [ -z "$work" ] || [ -z "$pid" ]; then fail "$name: 子脚本未写出 info（未真正启动）"; return; fi
  [ "$got" = "$want" ] && pass "$name: 退出码 $got" || fail "$name: 退出码 $got（期望 $want）"
  [ ! -e "$work" ] && pass "$name: 临时目录已删除" || { fail "$name: 临时目录残留 $work"; rm -rf "$work"; }
  if kill -0 "$pid" 2>/dev/null; then fail "$name: daemon($pid) 仍存活"; kill -9 "$pid" 2>/dev/null
  else pass "$name: daemon 已退出"; fi
}

# C1
child ok 'exit 0' >/dev/null 2>&1; verify ok 0 $?

# C2
child midexit 'exit 3' >/dev/null 2>&1; verify midexit 3 $?

# C3 / C4：子脚本空转，等它写出 info 后发信号。
for spec in "term TERM 143" "int INT 130"; do
  set -- $spec
  # 作业控制关闭时后台进程默认忽略 SIGINT；用 `trap - INT` 在子 shell 里恢复不了被忽略的信号，
  # 所以经由 perl 重置信号处置后再 exec。
  INFO="$SCRATCH/$1.info" LIB="$LIB" perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' /bin/sh -c '
    . "$LIB"
    e2e_init "st-'"$1"'"
    e2e_start_daemon || die "daemon 未就绪"
    printf "%s\n%s\n" "$E2E_WORK" "$DAEMON_PID" > "$INFO"
    while :; do sleep 0.1; done
  ' "$ROOT/scripts/selftest-$1" >/dev/null 2>&1 &
  cpid=$!
  for _ in $(seq 1 100); do [ -s "$SCRATCH/$1.info" ] && break; sleep 0.1; done
  kill -"$2" "$cpid" 2>/dev/null
  wait "$cpid"; verify "$1" "$3" $?
done

# C5
child crashed 'e2e_kill9 "$DAEMON_PID"; [ -S "$SOCK" ] || exit 9; exit 0' >/dev/null 2>&1; verify crashed 0 $?

# C6：钩子还原目录外状态
OUTSIDE="$SCRATCH/outside.txt"; echo original > "$OUTSIDE"
OUTSIDE="$OUTSIDE" child hook '
  e2e_extra_cleanup() { echo original > "$OUTSIDE"; }
  echo MUTATED > "$OUTSIDE"
  exit 4' >/dev/null 2>&1; verify hook 4 $?
[ "$(cat "$OUTSIDE")" = original ] && pass "hook: e2e_extra_cleanup 在失败路径上还原了目录外状态" || fail "hook: 目录外状态未还原"

# C7
E2E_KEEP=1 child keep 'exit 0' >/dev/null 2>&1; rc=$?
kwork=$(sed -n 1p "$SCRATCH/keep.info"); kpid=$(sed -n 2p "$SCRATCH/keep.info")
[ "$rc" = 0 ] && [ -d "$kwork" ] && pass "keep: E2E_KEEP=1 保留目录" || fail "keep: 目录未保留（rc=$rc）"
kill -0 "$kpid" 2>/dev/null && { fail "keep: daemon 仍存活"; kill -9 "$kpid"; } || pass "keep: daemon 仍被停掉"
case "$kwork" in /tmp/dbx-st-keep.*) rm -rf "$kwork";; esac

# C8：隔离生效
child iso '
  [ -S "$SOCK" ] || exit 11
  "$BIN" ps >/dev/null 2>&1 && exit 12          # 默认 sock = $DBX_SUPPORT_ROOT/dbxd.sock，不存在 → 必须连不上
  "$BIN" sweep >/dev/null 2>&1 || exit 13
  [ -f "$COW_ROOT/registry.lock" ] || exit 14   # sweep 落在隔离 cow-root
  exit 0' >/dev/null 2>&1; rc=$?
verify iso 0 $rc
case $rc in 12) fail "iso: CLI 默认 socket 没有跟随 DBX_SUPPORT_ROOT（连到了别的 daemon）";; esac

# C9：fail-closed
DBX_SUPPORT_ROOT="relative/path" "$BIN" ps >/dev/null 2>"$SCRATCH/bad.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'DBX_SUPPORT_ROOT' "$SCRATCH/bad.err" && pass "非法 DBX_SUPPORT_ROOT → exit 2" || fail "非法 DBX_SUPPORT_ROOT rc=$rc"
DBX_SUPPORT_ROOT="/tmp/../etc" "$BIN" ps >/dev/null 2>&1; [ $? = 2 ] && pass "含 .. 的 DBX_SUPPORT_ROOT → exit 2" || fail ".. 未被拒绝"

# C10：e2e_resume 按**结果**分类（用桩替身，不需要 VM，也不受宿主是否锁屏影响）。
#   桩 dbx-poc：`resume` 的行为由 STUB_RESUME 决定；`ps` 输出由 STUB_STATE 决定。
STUB="$SCRATCH/stub-dbx"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
case "$1" in
  resume)
    case "$STUB_RESUME" in
      ok)     echo "resume ok sandboxId=SB state=running"; exit 0 ;;
      locked) echo "dbx-poc: request rejected (kind=resume): DBX-RESUME-HOST-LOCKED: Virtualization.framework 拒绝恢复 VM 状态" >&2; exit 2 ;;
      *)      echo "dbx-poc: request rejected (kind=resume): 快照解密/完整性校验失败" >&2; exit 2 ;;
    esac ;;
  ps) printf 'SB\t%s\t2026-01-01T00:00:00Z\t/m.json\tdefault\n' "$STUB_STATE" ;;
esac
STUBEOF
chmod +x "$STUB"
# classify <STUB_RESUME> <STUB_STATE> <有无快照 yes|no> → 输出 "RESUME_OUTCOME PASS FAIL"
classify() {
  STUB_RESUME="$1" STUB_STATE="$2" HAVE_SNAP="$3" LIB="$LIB" STUB="$STUB" W="$SCRATCH/resume-$1-$2-$3" /bin/sh -c '
    . "$LIB" >/dev/null 2>&1
    BIN="$STUB"; E2E_WORK="$W"; COW_ROOT="$W/cows"; mkdir -p "$COW_ROOT/snapshots"
    [ "$HAVE_SNAP" = yes ] && : > "$COW_ROOT/snapshots/SB.snap"
    export STUB_RESUME STUB_STATE
    e2e_resume /nonexistent.sock SB >/dev/null 2>&1
    printf "%s %s %s\n" "$RESUME_OUTCOME" "$PASS" "$FAIL"
  ' "$ROOT/scripts/selftest-resume"
}
expect_classify() { # <描述> <期望输出> <参数...>
  local what="$1" want="$2"; shift 2
  local got; got=$(classify "$@")
  [ "$got" = "$want" ] && pass "e2e_resume：$what → $got" || fail "e2e_resume：$what → 「$got」（期望「$want」）"
}
expect_classify "resume 成功"                                  "ok 0 0"      ok     running   no
expect_classify "锁屏且状态/快照都在（3 条锁屏不变量成立）"      "locked 3 0"  locked suspended yes
expect_classify "锁屏但沙箱不是 suspended（不变量被破坏）"       "locked 2 1"  locked running   yes
expect_classify "锁屏但快照丢失（不变量被破坏）"                "locked 2 1"  locked suspended no
expect_classify "其它失败（不得被当成锁屏）"                    "failed 0 0"  broken suspended yes
# 即便宿主此刻锁屏，resume 成功也必须归为 ok（上一版按锁屏标志预测，会在边界上误报）。
expect_classify "resume 成功（与宿主锁屏状态无关）"              "ok 0 0"      ok     suspended yes

# C11：证据文件的结论逻辑（scripts/e2e-evidence.py）。用合成的证据文件，不跑任何套件。
EVPY="$ROOT/scripts/e2e-evidence.py"
# mkev <文件> <python 表达式：对基准证据 e 的修改>
mkev() {
  python3 - "$1" "$2" <<'PY'
import json, sys
e = {
  "schema": "deskbox-e2e-evidence/v1", "generatedAtUtc": "2026-01-01T00:00:00Z", "commit": "abc1234",
  "commitDirty": False, "dirtyFiles": 0, "partial": False,
  "host": {"osVersion": "27.0", "osBuild": "X", "model": "Mac", "arch": "arm64"},
  "suites": [
    {"name": "life", "script": "a.sh", "invariants": ["INV-01", "INV-08"], "exitCode": 0, "pass": 5, "fail": 0, "skip": 0, "seconds": 1, "lockSkipped": []},
    {"name": "persist", "script": "b.sh", "invariants": ["INV-10"], "exitCode": 0, "pass": 5, "fail": 0, "skip": 0, "seconds": 1, "lockSkipped": []},
    {"name": "sweep", "script": "c.sh", "invariants": ["INV-08", "INV-10"], "exitCode": 0, "pass": 5, "fail": 0, "skip": 0, "seconds": 1, "lockSkipped": []},
    {"name": "infra", "script": "d.sh", "invariants": [], "exitCode": 0, "pass": 5, "fail": 0, "skip": 0, "seconds": 1, "lockSkipped": []},
  ],
  "hygiene": {"support": "clean", "tmp": "clean", "library": "clean", "procs": "clean"},
}
exec(sys.argv[2])
json.dump(e, open(sys.argv[1], "w"))
PY
}
# ev_expect <描述> <修改> <期望 check 退出码> <summarize 输出里必须出现的若干片段...>
ev_expect() {
  local what="$1" mutate="$2" want_rc="$3"; shift 3
  local f="$SCRATCH/ev-$RANDOM.json"
  mkev "$f" "$mutate"
  python3 "$EVPY" check "$f" >"$SCRATCH/ev.check" 2>&1; local rc=$?
  python3 "$EVPY" summarize "$f" >"$SCRATCH/ev.sum" 2>&1
  local ok=1 needle
  [ "$rc" = "$want_rc" ] || ok=0
  for needle in "$@"; do grep -qF -- "$needle" "$SCRATCH/ev.sum" "$SCRATCH/ev.check" || ok=0; done
  [ "$ok" = 1 ] && pass "证据：$what（check=$rc）" \
    || fail "证据：$what → check=$rc（期望 $want_rc）；$(tr '\n' '|' < "$SCRATCH/ev.sum" | cut -c1-400) $(tr '\n' '|' < "$SCRATCH/ev.check")"
}
ev_expect "全部通过 → 可作为发布证据" "pass" 0 \
  "INV-01  通过" "INV-08  通过" "INV-10  通过" "INV-02  未覆盖" "整体结论：完整通过" "可作为发布证据"
ev_expect "有断言因锁屏未验证 → 该不变量不完整，整体不完整" \
  "e['suites'][1]['lockSkipped'] = ['原始快照可恢复']" 3 \
  "INV-10  不完整" "未验证: persist: 原始快照可恢复" "INV-01  通过" "整体结论：无失败但不完整" "1 项断言因宿主锁屏未验证"
# M44：环境缺失的跳过同样算不完整；标成「不适用」的不算。
ev_expect "有断言因环境缺失未验证 → 该不变量不完整，整体不完整" \
  "e['suites'][0]['envSkipped'] = ['需要交叉编译器']; e['suites'][0]['skip'] = 1" 3 \
  "INV-01  不完整" "未验证: life: [环境] 需要交叉编译器" "INV-10  通过" "整体结论：无失败但不完整" "1 项断言因环境缺失未验证"
ev_expect "标为「不适用」的跳过不影响结论" \
  "e['suites'][0]['notApplicable'] = ['隔离模式不检查 GUI']; e['suites'][0]['skip'] = 1" 0 \
  "INV-01  通过" "整体结论：完整通过" "可作为发布证据"
ev_expect "SKIP 计数多于有明细的条数 → 差额按未说明原因计入不完整" \
  "e['suites'][1]['notApplicable'] = ['a']; e['suites'][1]['skip'] = 3" 3 \
  "INV-10  不完整" "2 项跳过没有说明原因" "整体结论：无失败但不完整"
ev_expect "锁屏与环境缺失同时存在 → 两个原因都列出" \
  "e['suites'][1]['lockSkipped'] = ['x']; e['suites'][0]['envSkipped'] = ['y']; e['suites'][1]['skip'] = 1; e['suites'][0]['skip'] = 1" 3 \
  "1 项断言因宿主锁屏未验证" "1 项断言因环境缺失未验证"
ev_expect "旧证据文件（没有新字段、SKIP>0）不被追溯改判" \
  "e['suites'][0]['skip'] = 2" 0 "整体结论：完整通过"
ev_expect "套件失败 → 该不变量失败，整体失败" \
  "e['suites'][0]['exitCode'] = 1; e['suites'][0]['fail'] = 2" 1 \
  "INV-01  失败" "INV-08  失败" "INV-10  通过" "整体结论：失败"
ev_expect "同一不变量既有失败又有跳过 → 取最糟的（失败）" \
  "e['suites'][1]['lockSkipped'] = ['x']; e['suites'][2]['exitCode'] = 1" 1 "INV-10  失败" "INV-08  失败"
ev_expect "退出码 0 但有 FAIL 计数 → 仍算失败" "e['suites'][1]['fail'] = 1" 1 "INV-10  失败"
ev_expect "卫生审计不干净 → 整体失败（即便套件全过）" "e['hygiene']['tmp'] = 'dirty'" 1 "整体结论：失败" "INV-10  通过"
ev_expect "工作区有未提交改动 → 不能作为发布证据" "e['commitDirty'] = True; e['dirtyFiles'] = 3" 3 \
  "整体结论：完整通过" "工作区有未提交的改动（3 个文件）"
ev_expect "只跑了部分套件 → 不能作为发布证据" "e['partial'] = True" 3 "只运行了部分套件"
ev_expect "没有任何套件 → 不能作为发布证据" "e['suites'] = []" 3 "没有任何套件结果" "INV-01  未覆盖"
ev_expect "不提供不变量证据的套件失败 → 整体仍失败" "e['suites'][3]['exitCode'] = 2" 1 "整体结论：失败" "INV-01  通过"
# 篡改：把结论手改成 complete，但明细里有失败。
ev_expect "手改的 verdict 与明细不符 → 证据无效" \
  "e['suites'][0]['exitCode'] = 1; e['verdict'] = 'complete'" 1 "记录的 verdict=complete 与明细不符"
ev_expect "引用未知不变量 → 证据无效" "e['suites'][0]['invariants'] = ['INV-99']" 1 "未知不变量 INV-99"
ev_expect "schema 不符 → 证据无效" "e['schema'] = 'something/else'" 1 "schema 不是"
# 用一份明确的、未改动的证据（此前取「目录里第一个 ev-$RANDOM.json」，偶尔会拿到上面故意弄坏的那份）。
mkev "$SCRATCH/ev-markdown.json" "pass"
python3 "$EVPY" summarize --markdown "$SCRATCH/ev-markdown.json" | grep -q '^| INV-01 |' \
  && pass "证据：summarize --markdown 输出表格" || fail "证据：markdown 输出异常"

# M55：build 把失败的断言逐条写进证据（偶发失败事后还能看到是哪一条）。
AUD="$SCRATCH/audit-build"; mkdir -p "$AUD"
printf 'generatedAtUtc\t2026-01-01T00:00:00Z\ncommit\tabc1234\n' > "$AUD/meta.tsv"
printf 'demo\te2e-demo.sh\tINV-08\t1\t3\t2\t0\t9\n' > "$AUD/suites.tsv"
printf 'G1 第一条失败\nG2 第二条失败\n' > "$AUD/demo.failures"
python3 "$EVPY" build "$AUD" "$SCRATCH/ev-built.json" >/dev/null 2>&1
[ "$(python3 -c "import json,sys;print('|'.join(json.load(open(sys.argv[1]))['suites'][0]['failures']))" "$SCRATCH/ev-built.json" 2>/dev/null)" = "G1 第一条失败|G2 第二条失败" ] \
  && pass "证据：失败的断言逐条记录（failures）" || fail "证据：failures 字段缺失：$(head -c 300 "$SCRATCH/ev-built.json" 2>/dev/null)"

LEFT=$(ls -d /tmp/dbx-st-* 2>/dev/null | tr '\n' ' ')
[ -z "$LEFT" ] && pass "无 /tmp/dbx-st-* 残留" || { fail "残留：$LEFT"; rm -rf /tmp/dbx-st-*; }

printf '\n[selftest] 结果：PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
