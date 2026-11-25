#!/usr/bin/env bash
# M51：`dbx-poc doctor`——版本偏差体检（真机，2 台 VM + 一个假的旧 daemon）。
#
#   D1  当前 daemon：报告同一修订；没有沙箱时退出码 0，--strict 也是 0
#   D2  旧 guest（默认 manifest 是旧资产时）：逐条列出缺少的修复，--strict 退出码 3；
#       guest 是新资产时：报告「guest 资产是最新的」，--strict 退出码 0
#   D3  补丁版 guest（当前源码）：没有任何发现
#   D4  --json 可解析，内容与文本一致
#   D5  旧 daemon（不认识版本查询；用一个按旧 daemon 措辞应答的假服务模拟）：报告它较旧并列出缺少的修复，
#       --strict 退出码 3
#   D6  daemon 连不上：退出码 2，不输出误导性的「一切正常」
#   D7  用法错误：退出码 2
#
# 资源纪律：scripts/lib/e2e-common.sh（假 daemon 的进程登记给 harness，退出时一并清理）。
set -u
. "$(dirname "$0")/lib/e2e-common.sh"
e2e_init doc
e2e_build_sign
cd "$E2E_ROOT"
RUN_FLAGS="${RUN_FLAGS:-}"
OUT="$E2E_WORK/out"; ERR="$E2E_WORK/err"
doctor() { "$BIN" doctor "$@" >"$OUT" 2>"$ERR" && RC=0 || RC=$?; }

# ---------- D6：连不上 ----------
doctor --daemon-sock "$E2E_WORK/no-such.sock"
[ "$RC" = 2 ] && ! grep -q 'ok ' "$OUT" && grep -q 'cannot connect' "$ERR" && pass "D6 daemon 连不上：退出码 2，没有任何「ok」" || fail "D6 rc=$RC out=[$(cat "$OUT")] err=[$(cat "$ERR")]"
doctor --fix
[ "$RC" = 2 ] && grep -q 'unknown option' "$ERR" && pass "D7 不认识的选项：退出码 2" || fail "D7 rc=$RC $(cat "$ERR")"

# ---------- D1：当前 daemon，没有沙箱 ----------
e2e_start_daemon || die "daemon 未就绪"
doctor --daemon-sock "$SOCK"
grep -q '^daemon     修订 [0-9]* *pid=[0-9]*' "$OUT" && grep -q 'ok daemon 与客户端同一修订' "$OUT" && grep -q '^sandboxes  （没有）' "$OUT" && [ "$RC" = 0 ] \
  && pass "D1 当前 daemon：同一修订（$(sed -n 's/^daemon *\(修订 [0-9]*\).*/\1/p' "$OUT")），没有沙箱" || fail "D1 rc=$RC $(cat "$OUT" "$ERR")"
[ "$(sed -n 's/^daemon *修订 \([0-9]*\).*/\1/p' "$OUT")" = "$(sed -n 's/^client *修订 //p' "$OUT")" ] && pass "D1 daemon 与客户端报告的修订号相同" || fail "D1 修订号不同：$(head -2 "$OUT")"
doctor --strict --daemon-sock "$SOCK"
[ "$RC" = 0 ] && pass "D1 没有问题时 --strict 退出码 0" || fail "D1 --strict rc=$RC"

# ---------- D2：默认 manifest 的 guest ----------
# shellcheck disable=SC2086
ID=$("$BIN" run --daemon-sock "$SOCK" "$MANIFEST" --memory-mib 1024 --cpus 1 $RUN_FLAGS 2>"$E2E_WORK/run.err" | sid_of)
[ -n "$ID" ] || die "run 失败：$(cat "$E2E_WORK/run.err")"
FDS=$("$BIN" stats --daemon-sock "$SOCK" "$ID" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('childFdsVersion') or 0)" 2>/dev/null || echo 0)
doctor --daemon-sock "$SOCK"
grep -q "^sandbox    $ID  running" "$OUT" && pass "D2 列出了 running 的沙箱" || fail "D2 没有列出沙箱：$(cat "$OUT")"
if [ "$FDS" -ge 1 ]; then
  grep -q 'ok guest 资产是最新的' "$OUT" && ! grep -q '^  ! \[' "$OUT" && pass "D2 这套 guest 是新资产：没有任何发现" || fail "D2 新 guest 却有发现：$(grep '^  ' "$OUT" | tr '\n' '|')"
  doctor --strict --daemon-sock "$SOCK"
  [ "$RC" = 0 ] && pass "D2 新 guest：--strict 退出码 0" || fail "D2 --strict rc=$RC"
else
  N_ISO=$(grep -c '^  ! \[isolation\]' "$OUT" || true)
  [ "$N_ISO" = 3 ] && grep -q '^  ! \[reliability\].*1023' "$OUT" && grep -q '^  ! \[feature\].*取消' "$OUT" \
    && pass "D2 旧 guest：列出 3 项隔离问题、输出截断、不支持取消（共 $(grep -c '^  ! \[' "$OUT") 条）" || fail "D2 旧 guest 的发现不全：$(grep '^  ' "$OUT" | cut -c1-60 | tr '\n' '|')"
  grep -q 'stdin 就是控制通道' "$OUT" && grep -q 'broker 入口' "$OUT" && grep -q '符号链接' "$OUT" && pass "D2 每条都说了是什么问题" || fail "D2 文案缺失"
  grep -q '重建 guest 资产' "$OUT" && pass "D2 给出了处理办法" || fail "D2 没有处理办法"
  [ "$RC" = 0 ] && pass "D2 缺省只报告，退出码 0" || fail "D2 rc=$RC"
  doctor --strict --daemon-sock "$SOCK"
  [ "$RC" = 3 ] && pass "D2 旧 guest：--strict 退出码 3" || fail "D2 --strict rc=$RC"
fi

# ---------- D4：--json ----------
doctor --json --daemon-sock "$SOCK"
python3 - "$OUT" "$ID" "$FDS" >"$E2E_WORK/json.out" 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sb = [s for s in d["sandboxes"] if s["sandboxId"] == sys.argv[2]][0]
ids = sorted(f["id"] for f in sb.get("findings", []))
ok = isinstance(d["clientRevision"], int) and d["daemon"]["revision"] == d["clientRevision"] and "daemonNote" not in d
expected_empty = int(sys.argv[3]) >= 1
ok = ok and ((ids == []) if expected_empty else ("child-fds" in ids and "exec-output" in ids))
print("OK" if ok else "BAD %s" % json.dumps(d, ensure_ascii=False)[:300])
PY
[ "$(cat "$E2E_WORK/json.out")" = OK ] && pass "D4 --json 可解析，修订号与发现和文本一致" || fail "D4 $(cat "$E2E_WORK/json.out")"

# ---------- D3：补丁版 guest（当前源码） ----------
PATCHED=$(
  export E2E_PATCHED_GUEST_DIR="${E2E_PATCHED_GUEST_DIR:-$E2E_WORK/patched-guest}"
  . "$E2E_ROOT/scripts/lib/patched-guest.sh"
  patched_guest_prepare doc >"$E2E_WORK/fixture.log" 2>&1
  printf '%s' "${PATCHED_MANIFEST:-}"
)
if [ -n "$PATCHED" ] && [ -f "$PATCHED" ]; then
  ID2=$("$BIN" run --daemon-sock "$SOCK" "$PATCHED" --memory-mib 1024 --cpus 1 --allow-unsigned-manifest 2>"$E2E_WORK/run.err" | sid_of)
  [ -n "$ID2" ] || die "补丁版 guest run 失败：$(cat "$E2E_WORK/run.err")"
  doctor --daemon-sock "$SOCK"
  awk -v id="$ID2" '$1=="sandbox" {cur=$2} cur==id' "$OUT" > "$E2E_WORK/sb2.out"
  grep -q 'ok guest 资产是最新的' "$E2E_WORK/sb2.out" && ! grep -q '^  ! ' "$E2E_WORK/sb2.out" \
    && pass "D3 补丁版 guest（当前源码）：没有任何发现" || fail "D3 $(tr '\n' '|' < "$E2E_WORK/sb2.out")"
  "$BIN" rm --daemon-sock "$SOCK" "$ID2" --force >/dev/null 2>&1
else
  skip "D3 补丁版 guest：$(tail -1 "$E2E_WORK/fixture.log" 2>/dev/null | cut -c1-120)"
fi
"$BIN" rm --daemon-sock "$SOCK" "$ID" --force >/dev/null 2>&1

# ---------- D5：旧 daemon（不认识版本查询） ----------
OLD_SOCK="$E2E_WORK/old.sock"
python3 - "$OLD_SOCK" >"$E2E_WORK/old-daemon.log" 2>&1 <<'PY' &
import json, os, socket, sys
path = sys.argv[1]
srv = socket.socket(socket.AF_UNIX); srv.bind(path); os.chmod(path, 0o600); srv.listen(8)
while True:
    conn, _ = srv.accept()
    try:
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk: break
            data += chunk
        if not data: continue
        kind = json.loads(data.decode()).get("kind", "?")
        if kind == "ps":
            reply = {"ok": True, "sandboxes": []}
        else:
            # 旧 daemon 对不认识的请求的固定措辞。
            reply = {"ok": False, "error": "request rejected (kind=%s): unknown kind=%s" % (kind, kind)}
        conn.sendall((json.dumps(reply) + "\n").encode())
    finally:
        conn.close()
PY
FAKE_PID=$!
E2E_DAEMON_PIDS="$E2E_DAEMON_PIDS $FAKE_PID"
for _ in $(seq 1 50); do [ -S "$OLD_SOCK" ] && break; sleep 0.1; done
doctor --daemon-sock "$OLD_SOCK"
grep -q '^daemon     不认识版本查询' "$OUT" && grep -q '^  ! 正在运行的 daemon 比这个客户端旧' "$OUT" && [ "$RC" = 0 ] \
  && pass "D5 旧 daemon：报告它比客户端旧（缺省退出码 0）" || fail "D5 rc=$RC $(cat "$OUT" "$ERR")"
grep -q '缺少的修复：终端大量输出时 daemon 可能崩溃' "$OUT" && [ "$(grep -c '缺少的修复：' "$OUT")" -ge 5 ] \
  && pass "D5 列出它缺少的修复（$(grep -c '缺少的修复：' "$OUT") 条，含 daemon 崩溃那一条）" || fail "D5 没有列出缺少的修复：$(cat "$OUT")"
grep -q '所有沙箱' "$OUT" && pass "D5 说明了重启 daemon 的代价（名下的沙箱会结束）" || fail "D5 没有说明代价"
doctor --strict --daemon-sock "$OLD_SOCK"
[ "$RC" = 3 ] && pass "D5 旧 daemon：--strict 退出码 3" || fail "D5 --strict rc=$RC"
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
rm -f "$OLD_SOCK"
e2e_finish
