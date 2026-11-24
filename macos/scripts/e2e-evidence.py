#!/usr/bin/env python3
"""M36：e2e 证据的生成、汇总与校验。

  e2e-evidence.py build <audit-dir> <out.json>     由 e2e-all.sh 调用：把一次运行的原始记录组装成证据文件
  e2e-evidence.py summarize <evidence.json>        按安全不变量汇总（人读）
  e2e-evidence.py summarize --markdown <evidence.json>
  e2e-evidence.py check <evidence.json>            退出码：0 = 可作为发布证据；3 = 无失败但不完整；1 = 有失败 / 无效

证据文件记录的是「这一次、在这台机器、这个 commit 上跑出来的结果」。它不替代
docs/security/security-verification-matrix.md 里「已验证」所要求的其它条件（独立评估、双平台等），
只回答一个问题：自动化真机套件对每个不变量给出了什么结果，以及有哪些断言**没有被验证**。
"""
import json
import sys

SCHEMA = "deskbox-e2e-evidence/v1"
INVARIANTS = ["INV-%02d" % i for i in range(1, 11)]

# 状态的严重程度：越靠后越糟。一个不变量的状态取它所有相关套件里最糟的那个。
ORDER = ["pass", "incomplete", "fail"]


def suite_status(suite):
    """单个套件的状态。"""
    if suite["exitCode"] != 0 or suite.get("fail", 0) > 0:
        return "fail"
    if suite.get("lockSkipped"):
        return "incomplete"
    return "pass"


def invariant_summary(evidence):
    """{INV-xx: {"status": pass|incomplete|fail|not-covered, "suites": [...], "unverified": [...]}}"""
    out = {}
    for inv in INVARIANTS:
        related = [s for s in evidence["suites"] if inv in s.get("invariants", [])]
        if not related:
            out[inv] = {"status": "not-covered", "suites": [], "unverified": []}
            continue
        worst = max((suite_status(s) for s in related), key=ORDER.index)
        unverified = ["%s: %s" % (s["name"], text) for s in related for text in s.get("lockSkipped", [])]
        out[inv] = {"status": worst, "suites": [s["name"] for s in related], "unverified": unverified}
    return out


def verdict(evidence):
    """整次运行的结论。

    failed      有套件失败，或卫生审计发现残留 / 用户状态被改动
    incomplete  没有失败，但有断言因宿主状态（锁屏）未被验证
    complete    全部通过，没有任何跳过
    """
    if any(suite_status(s) == "fail" for s in evidence["suites"]):
        return "failed"
    if any(v != "clean" for v in evidence.get("hygiene", {}).values()):
        return "failed"
    if any(s.get("lockSkipped") for s in evidence["suites"]):
        return "incomplete"
    return "complete"


def release_blockers(evidence):
    """这份证据为什么**不能**当作发布证据（空列表 = 可以）。"""
    reasons = []
    v = verdict(evidence)
    if v == "failed":
        reasons.append("有套件失败或卫生审计不干净")
    if v == "incomplete":
        n = sum(len(s.get("lockSkipped", [])) for s in evidence["suites"])
        reasons.append("%d 项断言因宿主锁屏未验证" % n)
    if evidence.get("commitDirty"):
        reasons.append("工作区有未提交的改动（%d 个文件）：证据无法对应到一个确定的 commit" % evidence.get("dirtyFiles", 0))
    if evidence.get("partial"):
        reasons.append("只运行了部分套件")
    if not evidence["suites"]:
        reasons.append("没有任何套件结果")
    return reasons


def validate(evidence):
    """结构校验；返回问题列表。"""
    problems = []
    if evidence.get("schema") != SCHEMA:
        problems.append("schema 不是 %s" % SCHEMA)
    for key in ("generatedAtUtc", "commit", "host", "suites", "hygiene"):
        if key not in evidence:
            problems.append("缺少字段 %s" % key)
    for s in evidence.get("suites", []):
        for key in ("name", "script", "exitCode", "invariants"):
            if key not in s:
                problems.append("套件 %s 缺少字段 %s" % (s.get("name", "?"), key))
        for inv in s.get("invariants", []):
            if inv not in INVARIANTS:
                problems.append("套件 %s 引用了未知不变量 %s" % (s.get("name", "?"), inv))
    # 记录下来的结论必须与由明细重新计算出来的一致（防止手改结论）。
    if "verdict" in evidence and not problems and evidence["verdict"] != verdict(evidence):
        problems.append("记录的 verdict=%s 与明细不符（应为 %s）" % (evidence["verdict"], verdict(evidence)))
    return problems


# ---------------------------------------------------------------- build

def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [line.rstrip("\n") for line in f if line.strip()]
    except FileNotFoundError:
        return []


def build(audit_dir, out_path):
    meta = {}
    for line in read_lines(audit_dir + "/meta.tsv"):
        key, _, value = line.partition("\t")
        meta[key] = value
    suites = []
    for line in read_lines(audit_dir + "/suites.tsv"):
        name, script, invs, rc, p, f, sk, secs = line.split("\t")
        suites.append({
            "name": name, "script": script,
            "invariants": [x for x in invs.split(",") if x],
            "exitCode": int(rc), "pass": int(p), "fail": int(f), "skip": int(sk), "seconds": int(secs),
            "lockSkipped": read_lines("%s/%s.locked" % (audit_dir, name)),
        })
    hygiene = {}
    for line in read_lines(audit_dir + "/hygiene.tsv"):
        key, _, value = line.partition("\t")
        hygiene[key] = value
    evidence = {
        "schema": SCHEMA,
        "generatedAtUtc": meta.get("generatedAtUtc", ""),
        "commit": meta.get("commit", "unknown"),
        "commitDirty": meta.get("commitDirty") == "true",
        "dirtyFiles": int(meta.get("dirtyFiles", "0") or 0),
        "partial": meta.get("partial") == "true",
        "host": {k: meta.get(k, "") for k in ("osVersion", "osBuild", "model", "arch")},
        "hostSessionLocked": {"atStart": meta.get("lockedAtStart") == "true", "atEnd": meta.get("lockedAtEnd") == "true"},
        "binarySha256": meta.get("binarySha256", ""),
        "guestManifestSha256": meta.get("guestManifestSha256", ""),
        "entrypoint": "macos/scripts/e2e-all.sh",
        "suites": suites,
        "hygiene": hygiene,
    }
    evidence["verdict"] = verdict(evidence)
    evidence["invariants"] = invariant_summary(evidence)
    evidence["releaseBlockers"] = release_blockers(evidence)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    return evidence


# ---------------------------------------------------------------- summarize

LABEL = {"pass": "通过", "incomplete": "不完整", "fail": "失败", "not-covered": "未覆盖"}


def summarize(evidence, markdown=False):
    summary = invariant_summary(evidence)
    lines = []
    head = "commit %s%s · %s · macOS %s (%s) %s" % (
        evidence["commit"], "（工作区有未提交改动）" if evidence.get("commitDirty") else "",
        evidence["generatedAtUtc"], evidence["host"].get("osVersion", "?"),
        evidence["host"].get("osBuild", "?"), evidence["host"].get("model", "?"))
    if markdown:
        lines.append("证据：%s" % head)
        lines.append("")
        lines.append("| 不变量 | e2e 结果 | 相关套件 | 未验证的断言 |")
        lines.append("| --- | --- | --- | --- |")
        for inv in INVARIANTS:
            item = summary[inv]
            lines.append("| %s | %s | %s | %s |" % (
                inv, LABEL[item["status"]], "、".join(item["suites"]) or "—",
                "<br>".join(item["unverified"]) or "—"))
    else:
        lines.append(head)
        for inv in INVARIANTS:
            item = summary[inv]
            lines.append("%-7s %-6s %s" % (inv, LABEL[item["status"]], ", ".join(item["suites"]) or "-"))
            for text in item["unverified"]:
                lines.append("          未验证: %s" % text)
    lines.append("")
    lines.append("整体结论：%s" % {"complete": "完整通过", "incomplete": "无失败但不完整", "failed": "失败"}[verdict(evidence)])
    blockers = release_blockers(evidence)
    if blockers:
        lines.append("不能作为发布证据：" + "；".join(blockers))
    else:
        lines.append("可作为发布证据（自动化真机套件部分）。")
    return "\n".join(lines)


def main(argv):
    if len(argv) >= 4 and argv[1] == "build":
        build(argv[2], argv[3])
        return 0
    if len(argv) >= 3 and argv[1] in ("summarize", "check"):
        markdown = "--markdown" in argv
        path = [a for a in argv[2:] if not a.startswith("--")][0]
        with open(path, encoding="utf-8") as f:
            evidence = json.load(f)
        problems = validate(evidence)
        if problems:
            print("证据文件无效：" + "；".join(problems), file=sys.stderr)
            return 1
        if argv[1] == "summarize":
            print(summarize(evidence, markdown))
            return 0
        blockers = release_blockers(evidence)
        for b in blockers:
            print(b, file=sys.stderr)
        if verdict(evidence) == "failed":
            return 1
        return 3 if blockers else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
