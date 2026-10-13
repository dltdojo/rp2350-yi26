#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26 — what the LLM judge reads, and what its verdicts add up to.
# ACCEPTANCE.md says why; JUDGE.md is the prompt the judge is given.
#
#   judge-bundle.sh bundle EXPDIR [GATES]   the experiment as the judge reads it,
#                                           sliced by topic on stdout: each file
#                                           between `=== BEGIN path` and `=== END
#                                           path`, each of its lines as `line| text`,
#                                           so that a citation path:line can be
#                                           checked. Excludes build artifacts and
#                                           check.sh (G5/G6 run it).
#   judge-bundle.sh slice EXPDIR QUESTION   extract only the slice for one question
#                                           (J1, J2, J3, or J4), for low-token checks.
#   judge-bundle.sh scan EXPDIR             text in the experiment addressed to
#                                           a judge; exit 1 if any
#   judge-bundle.sh gates EXPDIR            G1.5, a machine check on the proof files:
#                                           a from_boot theorem whose statement runs
#                                           `run env N (boot …)` with N an exact count
#                                           (a numeral, or a term of the parameters;
#                                           not a name bound by ∀ or ∃), and no theorem
#                                           whose conclusion is literally True; exit 1
#                                           if not
#   judge-bundle.sh judge BUNDLE OUT [MODEL]
#                                           one judge run: default MODEL is `tiered`,
#                                           two sessions — J1/J3/J4 to the fast model
#                                           on the whole bundle, J2 to the deep model
#                                           on the J2 slice (README, WHY and the Lean:
#                                           42–61% of the bundle on exp225/230/234, so
#                                           the deep model reads about half of what it
#                                           would alone); or `fast` or `deep` for one
#                                           session with every question. Which models
#                                           those are is models.env's: the announced
#                                           ones. Each session gets its
#                                           prompt and its bundle in ONE message, and
#                                           appends what it used, as claude reports
#                                           it, to OUT.usage (one JSON line each)
#   judge-bundle.sh usage FILE.usage...     those sessions, and the tokens per model
#   judge-bundle.sh prompt [J1,J3,J4]       the prompt a judge run sends for those
#                                           questions (default all four), built
#                                           from JUDGE.md: what `judge` puts before
#                                           the bundle
#   judge-bundle.sh tally BUNDLE VERDICT... one verdict (single confirmation) or
#                                           three (or more) verdicts (consensus audit)
#                                           on one bundle, per ACCEPTANCE.md: each
#                                           question YES, NO or SPLIT, and the
#                                           experiment PASS (exit 0), FAIL
#                                           (exit 1) or HUMAN (exit 2)
#
# The bundle is organized in topic slices:
# - Prior Work (for J3): every index row from exp201 on, 150 characters each.
# - Documentation (for J1, J2, J3): README.md and WHY.zh-TW.md.
# - Proof & Specification (for J1, J2, J4): Lean definitions, theorem statements
#   (proof bodies omitted, line numbers preserved), and mutants.txt.
# - Reference Implementation (for J4): top-level Python algorithms (differential
#   harnesses omitted; imported sibling algorithms capped).
# - Empirical Evidence (for J1): capture.txt summary, shell/shell.c (what a board
#   claim argues from), differential/*.py (what a measured claim's inputs are:
#   exp225's twenty seeds), board log results (PATIENT/TRIAL lines kept,
#   polling deduplicated), and every page README.md or WHY.zh-TW.md links
#   (.html, .mjs) with the scripts the page loads from beside it.
# Never kernel.bin, check.sh, build/ or anything generated.
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
    bundle|scan|gates) [[ -d "${2-}" ]] || { sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2; };;
    slice) [[ -d "${2-}" && -n "${3-}" ]] || { sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2; };;
    judge) [[ -f "${2-}" && -n "${3-}" ]] || { sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2; };;
    tally) [[ -f "${2-}" && -n "${3-}" ]] || { sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2; };;
    prompt) ;;
    usage) [[ -f "${2-}" ]] || { sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2; };;
    *) sed -n '3,68p' "${BASH_SOURCE[0]}"; exit 2;;
esac

exec python3 - "$REPO" "$@" <<'PY'
import datetime
import glob
import json
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


THEOREM = re.compile(r"^(?:@\[[^\]]*\]\s*)?(?:private\s+|protected\s+)?(?:theorem|lemma)\b")
OPEN, CLOSE = "([{⟨⦃", ")]}⟩⦄"
QUESTIONS = ["J1", "J2", "J3", "J4"]


def top_level(text, depth=0):
    """Scan one line of Lean: the positions of `:=` outside every bracket, and
    the bracket depth at the end of the line. `{ s with pc := 1 }` and a default
    argument `(h : P := by decide)` sit inside brackets, so neither ends a
    statement; a `--` comment ends the line."""
    hits, i = [], 0
    while i < len(text):
        if text.startswith("--", i):
            break
        c = text[i]
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth = max(0, depth - 1)
        elif depth == 0 and text.startswith(":=", i):
            hits.append(i)
            i += 1
        i += 1
    return hits, depth


def lean_split(lines):
    """Walk a Lean file: yield (line number, text, kind) with kind 'keep' or
    'proof' (a theorem's proof, to be omitted). A theorem's statement runs to the
    first `:=` outside brackets that is not a `let`'s, or to a line starting
    with `|` (a proof by pattern matching); what follows, until the next line
    that starts in column 0, is its proof."""
    state, depth = "top", 0
    for n, line in enumerate(lines, 1):
        text = line.rstrip("\n")
        if state == "body":
            if text.strip() and not text[0].isspace():
                state = "top"
            else:
                yield n, text, "proof"
                continue
        if state == "top" and THEOREM.match(text):
            state, depth = "stmt", 0
        if state == "stmt":
            if depth == 0 and text.lstrip().startswith("|"):
                state = "body"
                yield n, text, "proof"
                continue
            hits, depth = top_level(text, depth)
            if text.lstrip().startswith("let "):
                hits = hits[1:]
            if hits:
                state = "body"
                yield n, text[:hits[0] + 2] + " …", "keep"
            else:
                yield n, text, "keep"
            continue
        yield n, text, "keep"


def lean_statements(path):
    """Each theorem's statement in a Lean file, as (first line, text)."""
    out, cur = [], None
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    for n, text, kind in lean_split(lines):
        if THEOREM.match(text):
            cur = [n, text]
            out.append(cur)
        elif cur and kind == "keep" and text.strip() and text[0].isspace():
            cur[1] += "\n" + text
        else:
            cur = None
        if cur and text.rstrip().endswith("…"):
            cur = None
    return out


def split_top(text, seps):
    """text cut at every occurrence of one of seps outside brackets. `:` never
    matches inside `:=` or `::`."""
    parts, depth, last, i = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth = max(0, depth - 1)
        elif depth == 0:
            for sep in seps:
                if text.startswith(sep, i) and not (sep == ":" and text[i + 1:i + 2] in ("=", ":") or text[i - 1:i] == ":"):
                    parts.append(text[last:i])
                    last = i + len(sep)
                    i = last - 1
                    break
        i += 1
    return parts + [text[last:]]


IDENT = r"[A-Za-z_][\w'.]*"


def signature(st):
    """A theorem statement (as lean_statements gives it) split into the names
    its parameters bind, the names its type binds with ∀/∃/fun, and the type."""
    st = re.sub(r"--[^\n]*", "", st)
    sig = st[:st.rindex(":=")] if st.rstrip().endswith("…") else st
    parts = split_top(sig, [":"])
    params, typ = parts[0], ":".join(parts[1:])
    pnames = set()
    for group in re.findall(r"[(\[{⦃]\s*([^:()\[\]{}⦃⦄]+?)\s*:", params):
        pnames |= set(re.findall(IDENT, group))
    tnames = set()
    for b in re.findall(r"(?:[∀∃λ]|\bfun\b)\s*([^,=]+?)\s*(?:,|=>)", typ):
        tnames |= set(re.findall(IDENT, re.split(r"[:<>≤≥∈]", b)[0]))
    return pnames, tnames, typ


def conclusion(typ):
    """The type's conclusion: after its last top-level `→`, ∀ and ∃ binders off."""
    c = split_top(typ, ["→"])[-1].strip()
    while c[:1] in ("∀", "∃"):
        rest = split_top(c, [","])
        if len(rest) < 2:
            break
        c = ",".join(rest[1:]).strip()
    return c


def boot_counts(st):
    """Each `run env N (boot …)` in a statement, as (N, exact): exact unless N
    is, or mentions, a name the statement binds — `∃ n, run env n (boot …)`
    says the kernel halts at some count, not after exactly N instructions. A
    count computed from the parameters, `run env (4141 + 3 * steps …) (boot …)`,
    is exact."""
    pnames, tnames, _ = signature(st)
    out = []
    for m in re.finditer(r"\brun\s+env\s+", st):
        i = m.end()
        if st[i:i + 1] == "(":
            depth, j = 0, i
            while j < len(st):
                depth += st[j] in OPEN
                depth -= st[j] in CLOSE
                j += 1
                if depth == 0:
                    break
            n = st[i:j]
        else:
            mm = re.match(r"\d+|" + IDENT, st[i:])
            if not mm:
                continue
            n, j = mm.group(0), i + mm.end()
        if not re.match(r"\s+\(boot\b", st[j:]):
            continue
        names = set(re.findall(IDENT, n))
        bare = re.fullmatch(IDENT, n) is not None
        exact = not (names & tnames) and not (bare and n in pnames)
        out.append((" ".join(n.split()), exact))
    return out


def gate15(exp):
    """G1.5: what a machine can settle before the judge is asked. A from_boot
    theorem — `run env N (boot …)` with N an exact count — and no theorem whose
    conclusion is literally True. A conclusion like `1 = 1` passes: J2 compares
    the main theorems with the README, and that is where it fails."""
    probs, found, loose = [], False, []
    for p in sorted(glob.glob(os.path.join(exp, "proof", "*.lean"))):
        name = os.path.relpath(p, exp)
        for n, st in lean_statements(p):
            for count, exact in boot_counts(st):
                if exact:
                    found = True
                else:
                    loose.append(f"{name}:{n} `run env {count} (boot …)`")
            if conclusion(signature(st)[2]) == "True":
                probs.append(f"{name}:{n} conclusion is literally True")
    if not found:
        if loose:
            probs.append("no from_boot form: the count in " + ", ".join(dict.fromkeys(loose))
                         + " is bound by the statement, so it is not an exact number of instructions")
        else:
            probs.append("no theorem states `run env N (boot …)`: no from_boot form")
    return probs


def files_of(exp, question=None):
    """The experiment's files the judge reads, as (relative path, max lines).
    If question is given ('J1', 'J2', 'J3', 'J4'), returns only the files
    needed for that topic slice. Omits check.sh (G5/G6 run it)."""
    out = []
    def add(pattern, cap=4000):
        for p in sorted(glob.glob(os.path.join(exp, pattern))):
            if os.path.isfile(p):
                rel = os.path.relpath(p, exp)
                if rel not in [r for r, _ in out]:
                    out.append((rel, cap))

    # Docs: needed by J1, J2, J3, J4
    add("README.md")
    if question in (None, "J1", "J2"):
        add("WHY.zh-TW.md")

    # Lean specification & theorems: needed by J1, J2, J4
    if question in (None, "J1", "J2", "J4"):
        add("proof/*.lean")
        if question in (None, "J1"):
            add("proof/mutants.txt")

    # Python reference: needed by J4
    if question in (None, "J4"):
        add("*.py", 1000)
        # Sibling reference algorithms (capped at 150 lines)
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
                            out.append((r, 150))

    # Evidence: capture summary, the shell, the differential and board logs,
    # needed by J1. The shell is what turns "the LED beats" into "every check
    # held": exp225's README argues from it, and without it J1 rightly found
    # that unsupported. The differential is where a measured claim's inputs
    # are (exp225's "twenty seeds … one live cell, none, all …" is its seeds());
    # without it round 2's re-probe found that claim unsupported too. J1 only:
    # the J4 slice reads the reference, not the harness around it.
    if question in (None, "J1"):
        add("shell/shell.c", 1000)
        add("differential/*.py", 1000)
        add("capture.txt", 200)
        add("board/*.txt", 100)
        # A claim about an earlier experiment rests on that experiment's
        # record: its board logs, or its capture. The README or WHY.zh-TW.md
        # links the record, and the link brings it into the bundle; a claim
        # about another experiment that links nothing stays unsupported.
        for doc in ("README.md", "WHY.zh-TW.md"):
            path = os.path.join(exp, doc)
            if not os.path.isfile(path):
                continue
            text = open(path, encoding="utf-8").read()
            for link in re.findall(r"\]\((\.\./[^)#\s]+/(?:board/[^)#\s]+\.txt|capture\.txt))\)", text):
                cand = os.path.normpath(os.path.join(exp, link))
                r = os.path.relpath(cand, exp)
                if os.path.isfile(cand) and r not in [x for x, _ in out]:
                    out.append((r, 200 if r.endswith("capture.txt") else 100))
            # A page the README says a person opens is what its claims about
            # the page rest on: the page, and the scripts it loads from beside
            # it (`<script src="../pages/core.js">`), which is how one
            # proposer's pages share their code. A page nothing links, and
            # anything outside the directory the experiment sits in (the
            # proposer's, or experiments/), stay out.
            root = os.path.dirname(os.path.abspath(exp)) + os.sep
            for link in re.findall(r"\]\(((?:\.\./)?[\w./-]+\.(?:html|mjs))\)", text):
                page = os.path.normpath(os.path.join(os.path.abspath(exp), link))
                if not os.path.isfile(page) or not page.startswith(root):
                    continue
                found = [page]
                if page.endswith(".html"):
                    src = open(page, encoding="utf-8", errors="replace").read()
                    for js in re.findall(r'<script src="([\w./-]+\.m?js)"></script>', src):
                        cand = os.path.normpath(os.path.join(os.path.dirname(page), js))
                        if os.path.isfile(cand) and cand.startswith(root):
                            found.append(cand)
                for cand in found:
                    r = os.path.relpath(cand, os.path.abspath(exp))
                    if r not in [x for x, _ in out]:
                        out.append((r, 2000))

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
    scan_files = []
    for pattern in ["README.md", "WHY.zh-TW.md", "proof/*.lean", "*.py", "check.sh", "shell/shell.c", "differential/*.py", "capture.txt", "board/*.txt"]:
        for p in sorted(glob.glob(os.path.join(exp, pattern))):
            if os.path.isfile(p):
                scan_files.append(os.path.relpath(p, exp))
    for rel in scan_files:
        with open(os.path.join(exp, rel), encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                if n > 2000:
                    break
                low = line.lower()
                if (re.search(JUDGE_WORD, low) and re.search(ORDER_WORD, low)) or any(re.search(p, low) for p in PHRASES):
                    hits.append(f"{rel}:{n}  {line.strip()[:160]}")
    return hits


def where(exp):
    """The experiment's path in the repository, or VK26_AS's."""
    return os.environ.get("VK26_AS") or os.path.relpath(os.path.abspath(exp), REPO)


def prior_rows(exp):
    """experiments/README.md's index rows from exp201 on, for the experiments
    before this one, each cut to 150 characters. All of them: a proposal that
    redoes exp207 or exp208 has to find them here, or J3 calls it new."""
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
        rows.append(f"{m.group(1)} [{m.group(3).strip()}]: {text[:150]}{'…' if len(text) > 150 else ''}")
    return rows


def bundle(exp, gates=None, question=None):
    exp = exp.rstrip("/")
    rel = where(exp)
    try:
        commit = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", rel], capture_output=True, text=True).stdout.strip()
    except OSError:
        commit, dirty = "unknown", ""
    hits = scan(exp)
    files = files_of(exp, question)
    header = "=== VK26 SLICE BUNDLE v3" + (f" (question: {question})" if question else "")
    out = [header,
           f"experiment: {rel}",
           f"commit: {commit}{' (with uncommitted changes in the experiment)' if dirty else ''}",
           f"files: {len(files)}",
           f"injection-scan: {len(hits)} hit(s)"]
    out += [f"  {h}" for h in hits]
    if question in (None, "J3"):
        out += ["", "=== SLICE: PRIOR WORK (for J3; every experiment from exp201 on that came before this one)"]
        out += [f"- {r}" for r in prior_rows(exp)]
    if question in (None, "J1"):
        out += ["", "=== SLICE: GATES (facts, not for the judge to re-decide; details in capture.txt)"]
        src = gates or os.path.join(exp, "capture.txt")
        if os.path.isfile(src):
            lines = [l.rstrip("\n") for l in open(src, encoding="utf-8", errors="replace")]
            kept = [l for l in lines if re.match(r"^(PASS|FAIL|SKIP)\b", l)]
            out.append(f"source: {'a fresh check.sh run' if gates else 'capture.txt, as committed; not re-run for this bundle'}")
            fails = sum(1 for l in kept if l.startswith("FAIL"))
            out.append(f"summary: {len(kept) - fails} PASS or SKIP, {fails} FAIL")
        else:
            out.append("(no gate output available)")
    for f, cap in files:
        out += ["", f"=== BEGIN {f}"]
        with open(os.path.join(exp, f), encoding="utf-8", errors="replace") as fh:
            raw = fh.read().split("\n")
        if raw and raw[-1] == "":
            raw.pop()
        if f.endswith(".lean"):
            run = None
            for n, text, kind in lean_split(raw):
                if kind == "proof":
                    run = (run[0], n) if run else (n, n)
                    continue
                if run:
                    out.append(f"{run[0]}| … (proof, lines {run[0]}-{run[1]}, left out)")
                    run = None
                out.append(f"{n}| {text}")
            if run:
                out.append(f"{run[0]}| … (proof, lines {run[0]}-{run[1]}, left out)")
        elif f.startswith("board/") or "/board/" in f:
            seen = set()
            count = 0
            for n, line in enumerate(raw, 1):
                if count >= cap:
                    out.append(f"{n}| … (cut at {cap} lines)")
                    break
                if re.match(r"^(PATIENT|TRIAL|SEARCH|PLAN|#page)\b", line):
                    out.append(f"{n}| {line.rstrip()}")
                    count += 1
                elif line not in seen and len(seen) < 5:
                    seen.add(line)
                    out.append(f"{n}| {line.rstrip()}")
                    count += 1
        else:
            for n, line in enumerate(raw, 1):
                if n > cap:
                    out.append(f"{n}| … (cut at {cap} lines)")
                    break
                out.append(f"{n}| {line.rstrip()}")
        out.append(f"=== END {f}")
    print("\n".join(out))


def bundle_cites(text):
    """The citations a bundle supports: `path:line` for every `line| ` inside
    `=== BEGIN path` … `=== END path`. Each line carries only its number; the
    path is said once, at the top of its file — the path on every line was a
    fifth of the bundle. No line of a file can start a BEGIN of its own, since
    every one of them starts with its number."""
    cites, cur = set(), None
    for line in text.split("\n"):
        if line.startswith("=== BEGIN "):
            cur = line[len("=== BEGIN "):].strip()
        elif line.startswith("=== END "):
            cur = None
        elif cur:
            m = re.match(r"(\d+)\| ", line)
            if m:
                cites.add(f"{cur}:{m.group(1)}")
    return cites


def tally(bundle_path, verdicts):
    text = open(bundle_path, encoding="utf-8").read()
    cites = bundle_cites(text)
    scan_hits = int(re.search(r"^injection-scan: (\d+)", text, re.M).group(1))
    qs = QUESTIONS
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
    if scan_hits or injected:
        overall, why = "HUMAN", "text addressed to the judge"
    elif len(verdicts) == 1:
        if any(r == "NO" for r in result.values()):
            overall, why = "FAIL", "a question was answered NO"
        elif all(r == "YES" for r in result.values()):
            overall, why = "PASS", "every question YES (single confirmation; spot-check requires 3 runs on sampled experiments)"
        else:
            overall, why = "HUMAN", "an answer was invalid or missing citation"
    elif len(verdicts) >= 3:
        if any(r == "NO" for r in result.values()):
            overall, why = "FAIL", "a question was answered NO by every run"
        elif all(r == "YES" for r in result.values()):
            overall, why = "PASS", "every question YES in every run"
        else:
            overall, why = "HUMAN", "the runs disagree or an answer was invalid"
    else:
        overall, why = "HUMAN", f"{len(verdicts)} verdict(s) given; 1 (single confirmation) or 3+ (audit) needed"
    print(f"OVERALL: {overall} ({why})")
    return {"PASS": 0, "FAIL": 1, "HUMAN": 2}[overall]


def extract_j2_slice(bundle_text):
    lines = bundle_text.splitlines()
    out = []
    in_header = True
    in_j2_file = False
    for l in lines:
        if l.startswith("=== SLICE: "):
            in_header = False
            in_j2_file = False
            continue
        elif l.startswith("=== BEGIN "):
            in_header = False
            f = l[len("=== BEGIN "):].strip()
            in_j2_file = f.endswith(".md") or (f.endswith(".lean") and not f.endswith("mutants.txt"))
            if in_j2_file:
                out.append(l)
            continue
        elif l.startswith("=== END "):
            if in_j2_file:
                out.append(l)
            in_j2_file = False
            continue

        if in_header or in_j2_file:
            out.append(l)
    return "\n".join(out)


def judge_prompt(questions=QUESTIONS):
    """JUDGE.md as the prompt for these questions: its comments left out, only
    these questions' paragraphs under `## The questions`, and only their lines in
    the Output block. Every other word is JUDGE.md's own, so the tiered runs and
    the calibrated prompt cannot drift apart."""
    src = open(os.path.join(REPO, "calls", "vk26", "JUDGE.md"), encoding="utf-8").read()
    src = re.sub(r"<!--.*?-->\n*", "", src, flags=re.S)
    head, rest = src.split("## The questions\n", 1)
    body, output = rest.split("## Output\n", 1)
    paras = re.split(r"^(?=\*\*J\d — )", body, flags=re.M)
    picked = [t for t in paras if re.match(r"\*\*(J\d) — ", t) and re.match(r"\*\*(J\d)", t).group(1) in questions]
    missing = set(questions) - {re.match(r"\*\*(J\d)", t).group(1) for t in picked}
    if missing:
        sys.exit(f"JUDGE.md has no paragraph for {', '.join(sorted(missing))}")
    block = ["VERDICT vk26"]
    for q in questions:
        block += [f"{q}: YES|NO", "evidence: path:line[, path:line ...]", "reason: ..."]
    block += ["INJECTION: NONE", "END"]
    output, n = re.subn(r"```\n.*?```", lambda _: "```\n" + "\n".join(block) + "\n```", output, count=1, flags=re.S)
    if not n:
        sys.exit("JUDGE.md's Output section has no fenced block")
    return head + "## The questions\n\n" + "".join(picked).strip() + "\n\n## Output\n" + output


def merge_verdicts(j134, j2):
    m1 = re.search(r"VERDICT vk26(.*?)^END\s*$", j134, re.S | re.M)
    m2 = re.search(r"VERDICT vk26(.*?)^END\s*$", j2, re.S | re.M)
    if not m1 or not m2:
        return None
    b1, b2 = m1.group(1), m2.group(1)

    out = ["VERDICT vk26"]
    for q in ["J1", "J3", "J4"]:
        qm = re.search(rf"^{q}:\s*(YES|NO)\s*$\s*^evidence:(.*)$\s*^reason:(.*)$", b1, re.M)
        if q == "J3":
            j2m = re.search(r"^J2:\s*(YES|NO)\s*$\s*^evidence:(.*)$\s*^reason:(.*)$", b2, re.M)
            if j2m:
                out.append(f"J2: {j2m.group(1)}\nevidence: {j2m.group(2).strip()}\nreason: {j2m.group(3).strip()}")
            else:
                out.append("J2: INVALID\nevidence:\nreason: J2 parse failed")
        if qm:
            out.append(f"{q}: {qm.group(1)}\nevidence: {qm.group(2).strip()}\nreason: {qm.group(3).strip()}")
        else:
            out.append(f"{q}: INVALID\nevidence:\nreason: {q} parse failed")

    injections = []
    for b in (b1, b2):
        im = re.search(r"^INJECTION:\s*(.*)$", b, re.M)
        if im and im.group(1).strip().upper() != "NONE":
            injections.append(im.group(1).strip())
    out.append(f"INJECTION: {', '.join(injections) if injections else 'NONE'}")
    out.append("END")
    return "\n".join(out)


USAGE_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def announced(key):
    """The model models.env names for a role: the call's announcement. An
    environment variable of the same name wins, for tests and self-checks."""
    if os.environ.get(key):
        return os.environ[key]
    path = os.path.join(REPO, "calls", "vk26", "models.env")
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\s*" + key + r"\s*=\s*(\S+)\s*$", line)
        if m:
            return m.group(1)
    sys.exit(f"{path} names no {key}")


def run_claude(model, questions, content, out_path):
    """One judge session: the prompt for these questions and the bundle in one
    message, no tools. Returns (ok, text, error). Appends one JSON line to
    OUT.usage with what `claude -p --output-format json` reports the session
    used — failed sessions too, since they may have cost something — so that
    the next estimate is a measurement, not a guess."""
    msg = judge_prompt(questions) + "\n\n=== THE BUNDLE DATA ===\n\n" + content
    cmd = ["claude", "-p", "--model", model, "--tools", "", "--no-session-persistence",
           "--disable-slash-commands", "--output-format", "json"]
    r = subprocess.run(cmd, input=msg, capture_output=True, text=True)
    try:
        obj = json.loads(r.stdout)
        if isinstance(obj, list):
            obj = [o for o in obj if isinstance(o, dict) and o.get("type") == "result"][-1]
    except (ValueError, IndexError):
        obj = None
    if isinstance(obj, dict):
        text = obj.get("result") or ""
        ok = r.returncode == 0 and not obj.get("is_error")
        usage = obj.get("usage") or {}
        rec = {k: usage.get(k, 0) for k in USAGE_KEYS}
        rec["total_cost_usd"] = obj.get("total_cost_usd")
        rec["served"] = sorted((obj.get("modelUsage") or {}).keys())
        error = "" if ok else f"exit {r.returncode}: {text}\n{r.stderr}"
    else:
        text, ok = r.stdout, r.returncode == 0
        rec = {"tokens": "unknown: claude printed no JSON"}
        error = "" if ok else f"exit {r.returncode}: {r.stderr}\n{r.stdout}"
    entry = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
             "verdict": os.path.basename(out_path), "model": model, "questions": ",".join(questions),
             "message_bytes": len(msg.encode()), "ok": ok, **rec}
    with open(out_path + ".usage", "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return ok, text, error


def usage_report(paths):
    """The sessions recorded in .usage files, and their totals per model."""
    rows = []
    for p in paths:
        for line in open(p, encoding="utf-8"):
            if line.strip():
                rows.append(json.loads(line))
    per = {}
    for e in rows:
        t = per.setdefault(e["model"], {"sessions": 0, "failed": 0, "unknown": 0, "prompt": 0, "output": 0, "cost": 0.0})
        t["sessions"] += 1
        t["failed"] += not e["ok"]
        if "input_tokens" not in e:
            t["unknown"] += 1
            continue
        prompt = sum(e.get(k) or 0 for k in USAGE_KEYS[:3])
        t["prompt"] += prompt
        t["output"] += e.get("output_tokens") or 0
        t["cost"] += e.get("total_cost_usd") or 0
        print(f"{e['verdict']:24} {e['model']:8} {e['questions']:9} {'ok    ' if e['ok'] else 'FAILED'} "
              f"sent {e['message_bytes']:>7} B  prompt {prompt:>7}  output {e.get('output_tokens') or 0:>5}")
    total = {"prompt": 0, "output": 0, "unknown": 0}
    for m, t in per.items():
        print(f"TOTAL {m}: {t['sessions']} session(s), {t['failed']} failed, prompt {t['prompt']} tokens "
              f"(input + cache), output {t['output']} tokens, ${t['cost']:.4f} as reported"
              + (f"; {t['unknown']} with no usage reported" if t["unknown"] else ""))
        total["prompt"] += t["prompt"]
        total["output"] += t["output"]
        total["unknown"] += t["unknown"]
    print(f"TOTAL: {len(rows)} session(s), prompt {total['prompt']} tokens, output {total['output']} tokens"
          + (f"; {total['unknown']} with no usage reported, not counted" if total["unknown"] else ""))


if MODE == "bundle":
    bundle(ARGS[0], ARGS[1] if len(ARGS) > 1 else None)
elif MODE == "slice":
    bundle(ARGS[0], question=ARGS[1].upper() if len(ARGS) > 1 else "J1")
elif MODE == "prompt":
    print(judge_prompt([q.upper() for q in ARGS[0].split(",")] if ARGS else QUESTIONS), end="")
elif MODE == "usage":
    usage_report(ARGS)
elif MODE == "gates":
    probs = gate15(ARGS[0].rstrip("/"))
    for p in probs:
        print(f"FAIL G1.5 {p}")
    if not probs:
        print("PASS G1.5 a from_boot theorem, no conclusion that is literally True")
    sys.exit(1 if probs else 0)
elif MODE == "judge":
    bundle_path, out_path = ARGS[0], ARGS[1]
    model = ARGS[2] if len(ARGS) > 2 else "tiered"
    bundle_text = open(bundle_path, encoding="utf-8").read()
    if model in ("fast", "deep"):
        model = announced("VK26_FAST_MODEL" if model == "fast" else "VK26_DEEP_MODEL")

    if model == "tiered" or model.startswith("tiered:"):
        parts = model.split(":")
        fast_model = parts[1] if len(parts) > 1 else announced("VK26_FAST_MODEL")
        deep_model = parts[2] if len(parts) > 2 else announced("VK26_DEEP_MODEL")

        ok, t134, err = run_claude(fast_model, ["J1", "J3", "J4"], bundle_text, out_path)
        if not ok:
            open(out_path, "w", encoding="utf-8").write(f"ERROR fast_model ({fast_model}) {err}")
            sys.exit(1)

        ok, t2, err = run_claude(deep_model, ["J2"], extract_j2_slice(bundle_text), out_path)
        if not ok:
            open(out_path, "w", encoding="utf-8").write(f"ERROR deep_model ({deep_model}) {err}")
            sys.exit(1)

        merged = merge_verdicts(t134, t2)
        if not merged:
            open(out_path, "w", encoding="utf-8").write("INVALID MERGE:\n--- J134 ---\n" + t134 + "\n--- J2 ---\n" + t2)
            sys.exit(1)
        open(out_path, "w", encoding="utf-8").write(merged)
        sys.exit(0)
    else:
        ok, text, err = run_claude(model, QUESTIONS, bundle_text, out_path)
        open(out_path, "w", encoding="utf-8").write(text if ok else f"ERROR model ({model}) {err}")
        sys.exit(0 if ok else 1)
elif MODE == "scan":
    hits = scan(ARGS[0].rstrip("/"))
    for h in hits:
        print(h)
    sys.exit(1 if hits else 0)
else:
    sys.exit(tally(ARGS[0], ARGS[1:]))
PY
