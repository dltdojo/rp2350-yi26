#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26 — what the LLM judge reads, and what its verdicts add up to.
# ACCEPTANCE.md says why; JUDGE.md is the prompt the judge is given.
#
#   judge-bundle.sh bundle EXPDIR [GATES]   one experiment as the judge reads it,
#                                           on stdout: every line numbered as
#                                           path:line| text, so that a citation
#                                           can be checked. GATES, if given, is a
#                                           fresh check.sh output; otherwise the
#                                           PASS/FAIL/SKIP lines of the committed
#                                           capture.txt
#   judge-bundle.sh scan EXPDIR             text in the experiment addressed to
#                                           a judge; exit 1 if any
#   judge-bundle.sh tally BUNDLE VERDICT... three (or more) verdicts on one
#                                           bundle, per ACCEPTANCE.md: each
#                                           question YES, NO or SPLIT, and the
#                                           experiment PASS (exit 0), FAIL
#                                           (exit 1) or HUMAN (exit 2)
#
# The bundle holds, in this order: the experiment's README.md and WHY.zh-TW.md;
# its proof files and mutants.txt; its Python (top level and differential/);
# check.sh; the shell's shell.c; capture.txt; the first 80 lines of each board
# log; and, under calls/, the proposer's own Lean package. Never kernel.bin,
# build/ or anything generated. Before them: the experiments that came before
# it (experiments/README.md's index, each row cut to 700 characters) and the
# gates. It is the same for the same commit: no dates, no absolute paths.
#
#   VK26_AS=experiments/expNNN-…   bundle EXPDIR as though it were at that path
#                                  in the repository — which experiments count as
#                                  prior work, and the name the judge sees.
#                                  calibration/cases.sh uses it for its altered
#                                  copies; nothing else should

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

case "${1-}" in
    bundle|scan) [[ -d "${2-}" ]] || { sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 2; };;
    tally) [[ -f "${2-}" && -n "${3-}" ]] || { sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 2; };;
    *) sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 2;;
esac

exec python3 - "$REPO" "$@" <<'PY'
import glob
import os
import re
import subprocess
import sys

REPO, MODE, *ARGS = sys.argv[1:]

# Text addressed to whoever judges the experiment. Words that only an
# experiment about judging would use on their own are not enough: a hit needs
# a judge-word and an instruction-word on the same line, or one of the
# phrases nobody writes except to a model.
JUDGE_WORD = r"\b(judge|grader|evaluator|assessor|reviewer|llm|language model|ai model|the model reading)s?\b"
ORDER_WORD = r"\b(approve[ds]?|pre-?approved|answer|respond|reply|output|mark|score|rate|yes|pass)\b"
PHRASES = [r"ignore\s+(all\s+|any\s+)?(the\s+)?(previous|prior|above|earlier|other)\s+(instructions|rules|prompts?|questions)",
           r"system\s+prompt", r"\byou\s+(must|should|will)\s+(answer|reply|respond|output|say|mark)\b",
           r"\bverdict\s*:\s*pass\b", r"\bJ[1-5]\s*:\s*yes\b"]


def files_of(exp):
    """The experiment's files the judge reads, as (relative path, max lines)."""
    out = []
    def add(pattern, cap=4000):
        for p in sorted(glob.glob(os.path.join(exp, pattern))):
            if os.path.isfile(p):
                rel = os.path.relpath(p, exp)
                if rel not in [r for r, _ in out]:
                    out.append((rel, cap))
    add("README.md"); add("WHY.zh-TW.md")
    add("proof/*.lean"); add("proof/mutants.txt")
    add("*.py"); add("differential/*.py")
    # A reference this experiment imports from a sibling experiment (exp234
    # replays the world with exp232's cure.py): the judge must see it to
    # answer J5.
    for rel, _ in list(out):
        if not rel.endswith(".py"):
            continue
        src = open(os.path.join(exp, rel), encoding="utf-8", errors="replace").read()
        for sib in re.findall(r'os\.path\.join\(HERE,\s*"\.\.",\s*(?:"\.\.",\s*)?"([^"]+)"\)', src):
            for mod in re.findall(r"^\s*(?:from\s+(\w+)\s+import|import\s+(\w+))", src, re.M):
                name = mod[0] or mod[1]
                for base in (os.path.join(exp, "..", sib), os.path.join(exp, "..", "..", sib)):
                    cand = os.path.normpath(os.path.join(base, name + ".py"))
                    r = os.path.relpath(cand, exp)
                    if os.path.isfile(cand) and r not in [x for x, _ in out]:
                        out.append((r, 4000))
    add("check.sh"); add("shell/shell.c")
    add("capture.txt"); add("board/*.txt", 80)
    # A proposer's own package: calls/<call>/<proposer>/lean/.
    rel = os.path.relpath(os.path.abspath(exp), REPO).split(os.sep)
    if len(rel) >= 4 and rel[0] == "calls":
        pkg = os.path.join(REPO, *rel[:3], "lean")
        for p in sorted(glob.glob(os.path.join(pkg, "**", "*.lean"), recursive=True)):
            if "/.lake/" not in p:
                out.append((os.path.relpath(p, exp), 4000))
    return out


def scan(exp):
    hits = []
    for rel, cap in files_of(exp):
        with open(os.path.join(exp, rel), encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                if n > cap:
                    break
                low = line.lower()
                if (re.search(JUDGE_WORD, low) and re.search(ORDER_WORD, low)) or any(re.search(p, low) for p in PHRASES):
                    hits.append(f"{rel}:{n}  {line.strip()[:160]}")
    return hits


def where(exp):
    """The experiment's path in the repository, or VK26_AS's."""
    return os.environ.get("VK26_AS") or os.path.relpath(os.path.abspath(exp), REPO)


def prior_rows(exp):
    """experiments/README.md's index rows for the experiments before this one."""
    rel = where(exp).split(os.sep)
    mine = None
    if rel[0] == "experiments":
        m = re.match(r"exp(\d+)", rel[1])
        mine = int(m.group(1)) if m else None
    rows = []
    for line in open(os.path.join(REPO, "experiments", "README.md"), encoding="utf-8"):
        m = re.match(r"\| \[(exp(\d+)-[^\]]+)\]\([^)]*\) \| ([^|]*) \| (.*) \|\s*$", line)
        if not m or int(m.group(2)) < 201:
            continue
        if mine is not None and int(m.group(2)) >= mine:
            continue
        text = re.sub(r"\*\*|`", "", m.group(4))
        rows.append(f"{m.group(1)} [{m.group(3).strip()}]: {text[:700]}{'…' if len(text) > 700 else ''}")
    return rows


def bundle(exp, gates=None):
    exp = exp.rstrip("/")
    rel = where(exp)
    try:
        commit = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", rel], capture_output=True, text=True).stdout.strip()
    except OSError:
        commit, dirty = "unknown", ""
    hits = scan(exp)
    files = files_of(exp)
    out = ["=== VK26 BUNDLE v1",
           f"experiment: {rel}",
           f"commit: {commit}{' (with uncommitted changes in the experiment)' if dirty else ''}",
           f"files: {len(files)}",
           f"injection-scan: {len(hits)} hit(s)"]
    out += [f"  {h}" for h in hits]
    out += ["", "=== PRIOR WORK (experiments/README.md, the experiments before this one)"]
    out += [f"- {r}" for r in prior_rows(exp)]
    out += ["", "=== GATES (machine checks; facts, not for the judge to re-decide)"]
    src = gates or os.path.join(exp, "capture.txt")
    if os.path.isfile(src):
        lines = [l.rstrip("\n") for l in open(src, encoding="utf-8", errors="replace")]
        kept = [l for l in lines if re.match(r"^(PASS|FAIL|SKIP)\b", l)]
        out.append(f"source: {'a fresh check.sh run' if gates else 'capture.txt, as committed; not re-run for this bundle'}")
        out += kept or ["(no PASS/FAIL/SKIP lines)"]
        fails = sum(1 for l in kept if l.startswith("FAIL"))
        out.append(f"summary: {len(kept) - fails} PASS or SKIP, {fails} FAIL")
    else:
        out.append("(no gate output available)")
    for f, cap in files:
        out += ["", f"=== BEGIN {f}"]
        with open(os.path.join(exp, f), encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                if n > cap:
                    out.append(f"{f}:{n}| … (cut at {cap} lines)")
                    break
                out.append(f"{f}:{n}| {line.rstrip()}")
        out.append(f"=== END {f}")
    print("\n".join(out))


def tally(bundle_path, verdicts):
    text = open(bundle_path, encoding="utf-8").read()
    cites = set(re.findall(r"^(\S+?:\d+)\| ", text, re.M))
    scan_hits = int(re.search(r"^injection-scan: (\d+)", text, re.M).group(1))
    qs = [f"J{i}" for i in range(1, 6)]
    table = {q: [] for q in qs}
    injected = []
    for v in verdicts:
        body = open(v, encoding="utf-8").read()
        m = re.search(r"VERDICT vk26(.*?)^END\s*$", body, re.S | re.M)
        if not m:
            for q in qs:
                table[q].append(("INVALID", f"{os.path.basename(v)}: no VERDICT block"))
            continue
        block = m.group(1)
        for q in qs:
            qm = re.search(rf"^{q}:\s*(YES|NO)\s*$\s*^evidence:(.*)$\s*^reason:(.*)$", block, re.M)
            if not qm:
                table[q].append(("INVALID", f"{os.path.basename(v)}: {q} not in the form asked"))
                continue
            ans, ev, why = qm.group(1), qm.group(2), qm.group(3).strip()
            refs = re.findall(r"[^\s,]+:\d+", ev)
            bad = [r for r in refs if r not in cites]
            if not refs:
                table[q].append(("INVALID", f"{os.path.basename(v)}: {q} {ans} cites nothing"))
            elif bad:
                table[q].append(("INVALID", f"{os.path.basename(v)}: {q} {ans} cites {', '.join(bad)}, not in the bundle"))
            else:
                table[q].append((ans, f"{os.path.basename(v)}: {q} {ans} [{', '.join(refs)}] {why}"))
        im = re.search(r"^INJECTION:\s*(.*)$", block, re.M)
        if im and im.group(1).strip().upper() != "NONE":
            injected.append(f"{os.path.basename(v)}: {im.group(1).strip()}")
    result = {}
    for q in qs:
        answers = [a for a, _ in table[q]]
        if all(a == "YES" for a in answers):
            result[q] = "YES"
        elif all(a == "NO" for a in answers):
            result[q] = "NO"
        else:
            result[q] = "SPLIT"
        print(f"{q}: {' '.join(answers)} -> {result[q]}")
    for q in qs:
        for a, line in table[q]:
            if a != "YES":
                print(f"  {line}")
    if scan_hits:
        print(f"injection scan: {scan_hits} hit(s) in the bundle")
    for i in injected:
        print(f"injection reported: {i}")
    if len(verdicts) < 3:
        overall, why = "HUMAN", f"only {len(verdicts)} verdict(s); three are needed"
    elif scan_hits or injected:
        overall, why = "HUMAN", "text addressed to the judge"
    elif any(r == "NO" for r in result.values()):
        overall, why = "FAIL", "a question was answered NO by every run"
    elif all(r == "YES" for r in result.values()):
        overall, why = "PASS", "every question YES in every run"
    else:
        overall, why = "HUMAN", "the runs disagree or an answer was invalid"
    print(f"OVERALL: {overall} ({why})")
    return {"PASS": 0, "FAIL": 1, "HUMAN": 2}[overall]


if MODE == "bundle":
    bundle(ARGS[0], ARGS[1] if len(ARGS) > 1 else None)
elif MODE == "scan":
    hits = scan(ARGS[0].rstrip("/"))
    for h in hits:
        print(h)
    sys.exit(1 if hits else 0)
else:
    sys.exit(tally(ARGS[0], ARGS[1:]))
PY
