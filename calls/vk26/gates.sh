#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/gates.sh — the machine layer of ACCEPTANCE.md, as far as a script
# can decide it. PASS / FAIL / SKIP lines; exit 1 if any FAIL.
#
#   gates.sh proposal PROPOSER_DIR [BASE]
#       S1  five directories vk26-<p>-1-<slug> … vk26-<p>-5-<slug>
#       S2  with BASE (the PR's base, e.g. origin/main): every path the PR
#           changes, `git diff --name-only BASE...HEAD`, is under PROPOSER_DIR
#       S3  the five kernel.sha256 differ, and each is its kernel.bin's hash
#       S4  the index table in PROPOSER_DIR/README.md: a row per experiment,
#           linking its directory, Needs 0–3, a last column that says something
#       G6  no file in PROPOSER_DIR is a byte-for-byte copy of one in lean/ or
#           tools/; experiments/duplication.sh --check
#
#   gates.sh experiment EXPDIR [CHECK_OUT]
#       G1.5  judge-bundle.sh gates
#       G2    every proof/*.lean with a `main` run by `lean.sh exec`: one of
#             them writes kernel.bin byte for byte
#       G6    README.md and WHY.zh-TW.md; capture.txt recorded clean, from a
#             commit of this history, and nothing it depends on changed since
#             (the experiment, the proposer's shared lean/ tools/ pages/ shell/,
#             anything outside the other experiments; text in .md files aside)
#             — a board log added after it is a change; README's Expected output is
#             capture.txt's lines, `...` or `…` where some are left out
#       G1 G3 G4 G5  check.sh exits 0 with no FAIL, its output in CHECK_OUT;
#             in it, lean.sh's own lines: the proof checks, its axioms, at
#             least 4 mutants refused (G3); at least 3 wrong shells caught (G5)
#
#   SKIP_CHECK=1  leaves check.sh out (G1, G3, G4, G5 say SKIP): about five
#                 minutes an experiment, most of it the RTL
#   SKIP_G2=1     leaves G2 out (it needs Lean)
#
# What a script cannot decide stays where ACCEPTANCE.md puts it: J1–J4 with the
# judge, G7 on the call's own board. vk26-alice's trial found the audit ran G1.5
# and nothing else of this layer, and S4 was a person reading a table.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

case "${1-}" in
    proposal|experiment) [[ -d "${2-}" ]] || { sed -n '3,38p' "${BASH_SOURCE[0]}"; exit 2; };;
    *) sed -n '3,38p' "${BASH_SOURCE[0]}"; exit 2;;
esac
MODE="$1"; DIR="$(cd "$2" && pwd)"; ARG="${3-}"
FAILED=0

if [[ "$MODE" == experiment ]]; then
    "$HERE/judge-bundle.sh" gates "$DIR" > /tmp/vk26-gates.$$ 2>&1; rc=$?
    sed 's/^PASS G1.5 /PASS  G1.5 /; s/^FAIL G1.5 /FAIL  G1.5 /' /tmp/vk26-gates.$$; rm -f /tmp/vk26-gates.$$
    (( rc )) && FAILED=1

    if [[ "${SKIP_G2-}" == 1 ]]; then
        echo "SKIP  G2 kernel.bin is what the proof writes: SKIP_G2=1"
    else
        work="$(mktemp -d)"; made=""
        for f in "$DIR"/proof/*.lean; do
            grep -q '^def main' "$f" || continue
            if "$REPO/tools/lean/lean.sh" exec "$f" "$work/kernel.bin" > /dev/null 2>&1 \
                && cmp -s "$work/kernel.bin" "$DIR/kernel.bin"; then made="proof/$(basename "$f")"; break; fi
        done
        if [[ -n "$made" && "$(sha256sum "$DIR/kernel.bin" | cut -d' ' -f1)" == "$(cut -d' ' -f1 "$DIR/kernel.sha256" 2>/dev/null)" ]]; then
            echo "PASS  G2 kernel.bin is what $made writes, $(stat -c %s "$DIR/kernel.bin") bytes, and kernel.sha256 is its hash"
        else
            echo "FAIL  G2 kernel.bin is what a proof file writes, and kernel.sha256 its hash: ${made:-no proof/*.lean with a main writes it}"
            FAILED=1
        fi
        rm -rf -- "$work"
    fi

    if [[ "${SKIP_CHECK-}" == 1 ]]; then
        ARG=__skip__
    else
        [[ -n "$ARG" ]] || { ARG="$(mktemp)"; trap 'rm -f -- "$ARG"' EXIT; }
        (cd "$DIR" && bash ./check.sh) > "$ARG" 2>&1
        echo "check.sh exit $?" >> "$ARG"
    fi
fi

python3 - "$REPO" "$MODE" "$DIR" "$ARG" <<'PY' || FAILED=1
import glob, hashlib, os, re, subprocess, sys

REPO, MODE, DIR, ARG = sys.argv[1:]
failed = False


def say(ok, what, why=""):
    global failed
    failed |= ok is False
    tag = "SKIP" if ok is None else "PASS" if ok else "FAIL"
    print(f"{tag}  {what}{' — ' + why if why and ok is not True else ''}")


def git(*args, cwd=DIR):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return r.returncode, r.stdout


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def experiments(pdir):
    p = os.path.basename(pdir)
    return sorted(d for d in glob.glob(os.path.join(pdir, f"vk26-{p}-[1-5]-*")) if os.path.isdir(d))


if MODE == "proposal":
    pdir, p = DIR, os.path.basename(DIR)
    exps = experiments(pdir)
    nums = sorted(os.path.basename(e)[len(f"vk26-{p}-")] for e in exps)
    say(nums == list("12345") and len(f"vk26-{p}-1") <= 34,
        f"S1 five experiments vk26-{p}-1-<slug> to vk26-{p}-5-<slug>, the id at most 34 characters",
        f"found {[os.path.basename(e) for e in exps]}")

    _, top = git("rev-parse", "--show-toplevel")
    top = top.strip()
    if ARG:
        rc, out = git("diff", "--name-only", f"{ARG}...HEAD", cwd=top)
        mine = os.path.relpath(pdir, top) + "/"
        outside = [l for l in out.split() if not l.startswith(mine)]
        say(rc == 0 and not outside, f"S2 every path changed since {ARG} is under {mine}",
            f"git diff failed" if rc else f"{len(outside)} outside it: {', '.join(outside[:5])}")
    else:
        say(None, "S2 every path the PR changes is under the proposer's directory", "no BASE given")

    hashes = {}
    for e in exps:
        k, s = os.path.join(e, "kernel.bin"), os.path.join(e, "kernel.sha256")
        if os.path.isfile(k) and os.path.isfile(s):
            hashes[os.path.basename(e)] = (open(s).read().split() or [""])[0]
            if hashes[os.path.basename(e)] != sha(k):
                say(False, f"S3 {os.path.basename(e)}'s kernel.sha256 is its kernel.bin's hash")
    say(len(hashes) == 5 and len(set(hashes.values())) == 5,
        "S3 five kernel.bin, five different hashes (J3 still judges each one new)",
        f"{len(hashes)} kernels, {len(set(hashes.values()))} different")

    index = os.path.join(pdir, "README.md")
    rows = {}
    if os.path.isfile(index):
        for line in open(index, encoding="utf-8"):
            m = re.match(r"\| \[(vk26-" + re.escape(p) + r"-([1-5]))\]\(\./([^)]+?)/?\) \|(.*)\|\s*$", line)
            if m:
                cells = [c.strip() for c in m.group(4).split("|")]
                rows[m.group(2)] = (m.group(3), cells)
    bad = []
    for e in exps:
        n = os.path.basename(e)[len(f"vk26-{p}-")]
        if n not in rows:
            bad.append(f"no row for vk26-{p}-{n}")
            continue
        link, cells = rows[n]
        if os.path.normpath(os.path.join(pdir, link)) != os.path.normpath(e):
            bad.append(f"vk26-{p}-{n} links {link}, not its directory")
        if not cells or not re.fullmatch(r"[0-3]", cells[0]):
            bad.append(f"vk26-{p}-{n}'s Needs is {cells[0] if cells else 'missing'}, not 0 to 3")
        if not cells or len(cells[-1]) < 20:
            bad.append(f"vk26-{p}-{n}'s last column says too little to be J3's one sentence")
    say(len(rows) == 5 and not bad, "S4 the index table: a row per experiment, its link, Needs 0–3, one sentence",
        "; ".join(bad) or f"{len(rows)} rows")

    theirs = {}
    for root in ("lean", "tools"):
        for f in glob.glob(os.path.join(REPO, root, "**", "*"), recursive=True):
            if os.path.isfile(f) and "/.lake/" not in f and os.path.getsize(f) >= 64:
                theirs.setdefault(sha(f), os.path.relpath(f, REPO))
    copies = []
    for f in glob.glob(os.path.join(pdir, "**", "*"), recursive=True):
        if os.path.isfile(f) and "/.lake/" not in f and "/build/" not in f and os.path.getsize(f) >= 64:
            h = sha(f)
            if h in theirs:
                copies.append(f"{os.path.relpath(f, pdir)} = {theirs[h]}")
    say(not copies, "G6 no file of the proposal is a copy of one in lean/ or tools/", "; ".join(copies[:5]))
    r = subprocess.run([os.path.join(REPO, "experiments", "duplication.sh"), "--check"], capture_output=True, text=True)
    say(r.returncode == 0, "G6 experiments/duplication.sh --check: nothing gained a copy",
        (r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else f"exit {r.returncode}")

else:
    e = DIR
    pdir = os.path.dirname(e)
    for doc in ("README.md", "WHY.zh-TW.md"):
        f = os.path.join(e, doc)
        say(os.path.isfile(f) and os.path.getsize(f) > 200, f"G6 {doc} is there")

    cap = os.path.join(e, "capture.txt")
    lines = open(cap, encoding="utf-8", errors="replace").read().split("\n") if os.path.isfile(cap) else []
    m = re.match(r"recorded at \S+ from commit (\S+)(.*)$", lines[1]) if len(lines) > 1 else None
    if not m:
        say(False, "G6 capture.txt is a run.sh recording", "no `recorded at … from commit …` line")
    else:
        commit, rest = m.group(1), m.group(2)
        say("dirty" not in rest, f"G6 capture.txt was recorded from a clean tree, commit {commit}", rest.strip())
        rc, _ = git("merge-base", "--is-ancestor", commit, "HEAD")
        say(rc == 0, f"G6 commit {commit} is in this history", "not an ancestor of HEAD")
        if rc == 0:
            _, top = git("rev-parse", "--show-toplevel")
            top = top.strip()
            _, changed = git("diff", "--name-only", commit, "HEAD", "--", os.path.relpath(pdir, top), cwd=top)
            _, dirty = git("status", "--porcelain", "--", os.path.relpath(pdir, top), cwd=top)
            mine = os.path.relpath(e, top) + "/"
            others = {os.path.relpath(x, top) + "/" for x in experiments(pdir)} - {mine}
            allowed = {mine + "README.md", mine + "WHY.zh-TW.md", mine + "capture.txt",
                       os.path.relpath(os.path.join(pdir, "README.md"), top)}
            # Text a person reads changes nothing run.sh records: any .md may
            # change after the capture, the README pasting it to begin with.
            stale = [c for c in changed.split() if c not in allowed and not c.endswith(".md")
                     and not any(c.startswith(o) for o in others)]
            say(not stale, f"G6 nothing capture.txt rests on changed since {commit}",
                f"{len(stale)} changed: {', '.join(os.path.relpath(os.path.join(top, s), e) for s in stale[:6])}"
                f"{' …' if len(stale) > 6 else ''}; run run.sh again")
            mine_dirty = [l[3:] for l in dirty.splitlines() if l[3:].startswith(mine)]
            say(not mine_dirty, "G6 the experiment has no uncommitted changes", ", ".join(mine_dirty[:5]))

    readme = os.path.join(e, "README.md")
    text = open(readme, encoding="utf-8").read() if os.path.isfile(readme) else ""
    sec = re.search(r"^## Expected output\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    block = re.search(r"^```[^\n]*\n(.*?)^```", sec.group(1), re.M | re.S) if sec else None
    if not block:
        say(False, "G6 README's Expected output is capture.txt pasted", "no fenced block under `## Expected output`")
    else:
        have = {l.rstrip() for l in lines}
        pasted = [l.rstrip() for l in block.group(1).split("\n")]
        missing = [l for l in pasted if l.strip() not in ("", "...", "…") and l not in have]
        say(not missing, f"G6 README's Expected output is capture.txt's own lines ({len(pasted)} pasted)",
            f"{len(missing)} not in capture.txt, first: {missing[0][:100] if missing else ''}")

    if ARG and os.path.isfile(ARG):
        out = open(ARG, encoding="utf-8", errors="replace").read()
        rc = re.search(r"^check\.sh exit (\d+)$", out, re.M)
        fails = [l for l in out.splitlines() if l.startswith("FAIL")]
        say(rc is not None and rc.group(1) == "0" and not fails, "G1 G3 G4 G5 check.sh exits 0, no FAIL",
            f"exit {rc.group(1) if rc else '?'}, {len(fails)} FAIL: {fails[0][:100] if fails else ''}")
        say(bool(re.search(r"^PASS  \S+\.lean checks, with no errors and no warnings$", out, re.M))
            and bool(re.search(r"^PASS  all \d+ theorems it prints rest on Lean's own axioms only", out, re.M)),
            "G1 lean.sh check: no error, no warning, Lean's own axioms")
        n = len(re.findall(r"^PASS  .*: the proof refuses a version where ", out, re.M))
        say(n >= 4, f"G3 {n} wrong versions refused by Lean (4 at least)")
        n = len(re.findall(r"^PASS  the shell catches a version where ", out, re.M))
        say(n >= 3, f"G5 {n} wrong shells caught (3 at least)")
        say(bool(re.search(r"^PASS  the UF2 is byte for byte the committed one", out, re.M)) or None,
            "G5 the UF2 is byte for byte the committed one", "not compared: another toolchain, or no UF2")
    else:
        say(None, "G1 G3 G4 G5 check.sh", "SKIP_CHECK=1")

sys.exit(1 if failed else 0)
PY

exit "$FAILED"
