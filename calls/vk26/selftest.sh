#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# calls/vk26/selftest.sh — regression tests for judge-bundle.sh and
# audit-proposal.sh. No model, no board, no network: `claude` is a stub on PATH
# that keeps every message it is sent and answers a fixed verdict.
#
#   ./selftest.sh        exit 0 = every case below behaved as stated
#
# A PRE-FLIGHT CHECK, not a calibration. It says that the bundle, G1.5, the
# prompts and the audit's bookkeeping do what ACCEPTANCE.md says; whether a
# judge answers right is calibration/'s question, and nothing printed here may
# stand in for it. Each case is a bug this directory once shipped.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$REPO/experiments/lib.sh"

JB="$HERE/judge-bundle.sh"
E="$REPO/experiments"
E205="$E/exp205-the-chain-the-checksum-closes"
E207="$E/exp207-the-trace-the-seed-cannot-move"
E208="$E/exp208-the-hash-the-kernel-computes"
E217="$E/exp217-the-words-the-model-inverts"
E224="$E/exp224-the-checks-the-kernel-makes"
E225="$E/exp225-the-life-every-beat-proved"
E228="$E/exp228-the-script-the-kernel-runs"
E230="$E/exp230-the-motion-the-fly-sees"
E234="$E/exp234-the-rate-the-proof-predicts"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

has()   { grep -qF -- "$3" "$2" && pass "$1" || fail "$1" "not in $(basename "$2"): $3"; }
lacks() { grep -qF -- "$3" "$2" && fail "$1" "in $(basename "$2"): $3" || pass "$1"; }
gate()  { # desc PASS|FAIL expdir [text the output must hold]
    local out; out="$("$JB" gates "$3")"
    if [[ "$out" != "$2 "* ]]; then fail "$1" "expected $2, got: ${out:0:160}"
    elif [[ -n "${4:-}" && "$out" != *"$4"* ]]; then fail "$1" "no \"$4\" in: ${out:0:160}"
    else pass "$1"; fi
}

# ---------- 1. Lean: the proof is left out, never the statement --------------

echo "== 1. theorem statements"
"$JB" bundle "$E228" > "$WORK/b228.txt"
has "a default argument \`(h : P := by decide)\` does not end the statement (exp228)" \
    "$WORK/b228.txt" "proof/Script.lean:1349|     ∀ j ≤ n, ∃ s', run env j s = .running s'"
has "  … the statement ends at its own \`:=\`" "$WORK/b228.txt" "proof/Script.lean:1351|       ∧ ∀ r, s'.reg r = s.reg r := …"
has "  … and the proof after it is left out" "$WORK/b228.txt" "proof/Script.lean:1352| … (proof, lines 1352-1370, left out)"
"$JB" bundle "$E217" > "$WORK/b217.txt"
has "a structure update \`{ s with pc := 1 }\` does not end the statement (exp217)" \
    "$WORK/b217.txt" "proof/Invert.lean:32|     step cfg prog ext s = some { s with pc := 1, osr := w, osrCount := 0, tx := rest, delay := 0, exec := none } := …"
"$JB" bundle "$E230" > "$WORK/b230.txt"
has "a proof by pattern matching is a proof, not part of the statement (exp230)" \
    "$WORK/b230.txt" "proof/Fly.lean:279| … (proof, lines 279-281, left out)"

mkdir -p "$WORK/syn/proof"
cat > "$WORK/syn/proof/T.lean" <<'LEAN'
theorem a (n : Nat) (h : n < 4 := by decide) :
    (step { s with pc := 1 }).pc = n := by
  secret_tactic_a
theorem b (s : S) :
    let t := s.next
    t.pc = 1 := by
  secret_tactic_b
theorem c : 1 = 1 := secret_term_c
LEAN
"$JB" bundle "$WORK/syn" > "$WORK/bsyn.txt"
has "  synthetic: both \`:=\` inside brackets kept" "$WORK/bsyn.txt" "proof/T.lean:2|     (step { s with pc := 1 }).pc = n := …"
has "  synthetic: a \`let\` line is part of the statement" "$WORK/bsyn.txt" "proof/T.lean:5|     let t := s.next"
has "  synthetic: a one-line term proof" "$WORK/bsyn.txt" "proof/T.lean:8| theorem c : 1 = 1 := …"
lacks "  synthetic: no proof text leaks" "$WORK/bsyn.txt" "secret_"

# Every theorem of every experiment and of lean/: its statement is cut at a
# `:=` outside all brackets, so no statement loses its conclusion.
python3 - "$JB" "$REPO" <<'PY' && pass "no statement anywhere in experiments/ is cut inside a bracket" || fail "a statement is cut inside a bracket"
import glob, re, subprocess, sys
jb, repo = sys.argv[1:]
bad, n = [], 0
for exp in sorted(glob.glob(f"{repo}/experiments/exp2*/")):
    if not glob.glob(exp + "proof/*.lean"):
        continue
    text = subprocess.run([jb, "bundle", exp], capture_output=True, text=True).stdout
    stmt = None
    for line in text.split("\n"):
        m = re.match(r"^(proof/\S+:\d+)\| (.*)$", line)
        if not m:
            continue
        body = m.group(2)
        if re.match(r"(?:@\[[^\]]*\]\s*)?(?:private\s+|protected\s+)?(?:theorem|lemma)\b", body):
            stmt = ""
        if stmt is None:
            continue
        if body.startswith("… (proof"):
            stmt = None
            continue
        stmt += re.sub(r"--.*", "", body) + "\n"
        if body.endswith(":= …"):
            n += 1
            s = stmt[:-len(":= …\n")]
            if sum(s.count(c) for c in "([{⟨⦃") > sum(s.count(c) for c in ")]}⟩⦄"):
                bad.append(f"{exp.split('/')[-2][:6]} {m.group(1)}")
            stmt = None
print(f"  {n} statements checked", *bad, sep="\n  ")
sys.exit(1 if bad or n < 400 else 0)
PY

# ---------- 2. G1.5 -----------------------------------------------------------

echo "== 2. G1.5"
gate "exp225 passes" PASS "$E225"
gate "exp230 passes" PASS "$E230"
gate "exp234 passes" PASS "$E234"
gate "exp205's count computed from its input, \`run env (4141 + 3 * steps …)\`, is exact" PASS "$E205"
gate "exp224's \`∃ n, run env n (boot …)\` is not an exact count" FAIL "$E224" "not an exact number of instructions"
gate "exp207's \`∀ n, … run env n (boot …)\` is not one either" FAIL "$E207" "not an exact number of instructions"
gate "exp208 has no \`run env N (boot …)\`" FAIL "$E208" "no theorem states"

conclusion_case() { # name conclusion
    mkdir -p "$WORK/g/$1/proof"
    python3 - "$E230/proof/Fly.lean" "$WORK/g/$1/proof/Fly.lean" "$2" <<'PY'
import sys
src, dst, concl = sys.argv[1:]
s = open(src, encoding="utf-8").read()
i, j = s.index("theorem watches_life"), s.index("/-- **The fly watching a stripe move.**")
open(dst, "w", encoding="utf-8").write(s[:i] + "theorem watches_life (x : Nat) :\n    " + concl + "\n\n" + s[j:])
PY
}
conclusion_case true    'True := trivial'
conclusion_case arrow   '(x = x) → True := fun _ => trivial'
conclusion_case forall  '∀ t < 256, True := fun _ _ => trivial'
conclusion_case and     'x = x ∧ True := ⟨rfl, trivial⟩'
conclusion_case oneone  '1 = 1 := rfl'
gate "a conclusion \`True\` fails" FAIL "$WORK/g/true" "conclusion is literally True"
gate "\`P → True\` fails" FAIL "$WORK/g/arrow" "conclusion is literally True"
gate "\`∀ t < 256, True\` fails" FAIL "$WORK/g/forall" "conclusion is literally True"
gate "\`x = x ∧ True\` is not literally True" PASS "$WORK/g/and"
gate "\`1 = 1\` passes G1.5 (J2's to catch, as ACCEPTANCE.md says)" PASS "$WORK/g/oneone"

boot_case() { # name statement
    mkdir -p "$WORK/fb/$1/proof"
    printf 'theorem fb %s := by\n  sorry\n' "$2" > "$WORK/fb/$1/proof/K.lean"
}
boot_case exists '(img : ByteArray) : ∃ n s, run env n (boot env.region img) = .halted 0 s'
boot_case param  '(n : Nat) (img : ByteArray) : ∃ s, run env n (boot env.region img) = .halted 0 s'
boot_case term   '(img : ByteArray) : ∃ s, run env (3 * steps img + 7) (boot env.region img) = .halted 0 s'
boot_case num    '(img : ByteArray) : ∃ s, run env 3078 (boot env.region img) = .halted 0 s'
gate "a count bound by ∃ fails" FAIL "$WORK/fb/exists" "not an exact number of instructions"
gate "a count that is a bare parameter fails" FAIL "$WORK/fb/param" "not an exact number of instructions"
gate "a count computed from the parameters passes" PASS "$WORK/fb/term"
gate "a numeral passes" PASS "$WORK/fb/num"

# ---------- 3. PRIOR WORK -----------------------------------------------------

echo "== 3. PRIOR WORK"
VK26_AS=calls/vk26/zz/exp101-x "$JB" bundle "$E225" > "$WORK/bprop.txt"
for e in exp203 exp207 exp208 exp213 exp234; do
    has "a proposal's prior work lists $e" "$WORK/bprop.txt" "- $e-"
done
"$JB" bundle "$E225" > "$WORK/b225.txt"
has "exp225's prior work starts at exp201" "$WORK/b225.txt" "- exp201-"
lacks "  … and stops before exp225 itself" "$WORK/b225.txt" "- exp225-"

# ---------- 4. prompts --------------------------------------------------------

echo "== 4. prompts"
"$JB" prompt J2 > "$WORK/p2.txt"
"$JB" prompt J1,J3,J4 > "$WORK/p134.txt"
"$JB" prompt > "$WORK/pall.txt"
for p in p2 p134 pall; do
    has "$p keeps JUDGE.md's citation example" "$WORK/$p.txt" 'For the bundle line `proof/Fly.lean:578|     True := trivial` the citation'
    lacks "$p leaves JUDGE.md's comments out" "$WORK/$p.txt" "<!--"
done
python3 - "$HERE/JUDGE.md" "$WORK/p2.txt" "$WORK/p134.txt" "$WORK/pall.txt" <<'PY' && pass "every prompt holds JUDGE.md's Rules section word for word" || fail "a prompt lost part of JUDGE.md's Rules"
import sys
src = open(sys.argv[1], encoding="utf-8").read()
rules = src[src.index("## Rules"):src.index("## The questions")].strip()
sys.exit(0 if all(rules in open(p, encoding="utf-8").read() for p in sys.argv[2:]) else 1)
PY
has "the J2 prompt asks J2" "$WORK/p2.txt" "**J2 — The theorem is what the text says.**"
lacks "  … and not J1" "$WORK/p2.txt" "**J1 —"
lacks "  … nor asks for J1 in its output" "$WORK/p2.txt" "J1: YES|NO"
has "the J1/J3/J4 prompt keeps J1's reading rule" "$WORK/p134.txt" "Explanations, analogies and motivation are not"
has "  … asks J4" "$WORK/p134.txt" "**J4 — The reference is independent.**"
lacks "  … and not J2" "$WORK/p134.txt" "**J2 —"
for q in J1 J2 J3 J4; do has "the full prompt asks $q" "$WORK/pall.txt" "$q: YES|NO"; done

# The stub: answers YES with citations from exp225's bundle, NO to J2 when the
# bundle carries STUB-SAYS-NO, and fails like a 429 for the model in STUB_FAIL.
mkdir -p "$WORK/bin" "$WORK/sent"
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
model=""
while (( $# )); do [[ $1 == --model ]] && model="$2"; shift; done
f="$(mktemp "$STUB_SENT/$model-XXXXXX")"
cat > "$f"
[[ "$model" == "${STUB_FAIL:-}" ]] && { echo "API Error: 429 You've hit your session limit" >&2; exit 1; }
j2=YES; grep -q STUB-SAYS-NO "$f" && j2=NO
echo "VERDICT vk26"
grep -q '^\*\*J1 — ' "$f" && printf 'J1: YES\nevidence: README.md:1\nreason: stub\n'
grep -q '^\*\*J2 — ' "$f" && printf 'J2: %s\nevidence: proof/Life.lean:1\nreason: stub\n' "$j2"
grep -q '^\*\*J3 — ' "$f" && printf 'J3: YES\nevidence: README.md:2\nreason: stub\n'
grep -q '^\*\*J4 — ' "$f" && printf 'J4: YES\nevidence: rule30.py:1\nreason: stub\n'
printf 'INJECTION: NONE\nEND\n'
SH
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH" STUB_SENT="$WORK/sent" STUB_FAIL=""
sent() { find "$STUB_SENT" -type f | wc -l; }

"$JB" judge "$WORK/b225.txt" "$WORK/v-tiered.txt" > /dev/null
s="$(ls "$STUB_SENT"/sonnet-* 2>/dev/null | head -1)"; o="$(ls "$STUB_SENT"/opus-* 2>/dev/null | head -1)"
if [[ -n "$s" && -n "$o" ]]; then
    cmp -s <(cat "$WORK/p134.txt"; printf '\n\n=== THE BUNDLE DATA ===\n\n'; cat "$WORK/b225.txt") "$s" \
        && pass "tiered: Sonnet is sent \`prompt J1,J3,J4\` and the whole bundle, in one message" \
        || fail "tiered: Sonnet's message is not \`prompt J1,J3,J4\` + the bundle"
    has "tiered: Opus is sent \`prompt J2\`" "$o" "$(sed -n '/^\*\*J2 — /p' "$WORK/p2.txt")"
    lacks "  … on the J2 slice: no PRIOR WORK" "$o" "=== SLICE: PRIOR WORK"
    lacks "  … no capture" "$o" "=== BEGIN capture.txt"
    has "  … but the README and the Lean" "$o" "=== BEGIN proof/Life.lean"
else
    fail "tiered: expected one Sonnet and one Opus session" "$(ls "$STUB_SENT")"
fi
"$JB" tally "$WORK/b225.txt" "$WORK/v-tiered.txt" > "$WORK/t.txt" && pass "tiered: the merged verdict tallies PASS" || fail "tiered: merged verdict" "$(tail -1 "$WORK/t.txt")"

# ---------- 5. audit-proposal.sh ---------------------------------------------

echo "== 5. audit-proposal.sh"
mkdir -p "$WORK/prop/zz"
for i in 1 2 3 4 5; do
    cp -a "$E225" "$WORK/prop/zz/exp10$i-life"
    rm -rf "$WORK/prop/zz/exp10$i-life/build" "$WORK/prop/zz/exp10$i-life/__pycache__"
done
NAMES="exp101-life exp102-life exp103-life exp104-life exp105-life"
AUD="$HERE/audit-proposal.sh"
O="$WORK/aud1"

rm -rf "$STUB_SENT"/*
STUB_FAIL=opus JOBS=3 "$AUD" "$WORK/prop/zz" "$O" > "$WORK/a1.txt" 2>&1; rc=$?
target="$(cat "$O/audit-target.txt" 2>/dev/null)"
[[ $rc == 2 ]] && pass "a run that hits a 429 stops the audit before the tally (exit 2)" || fail "429: expected exit 2, got $rc" "$(tail -2 "$WORK/a1.txt")"
n_failed=$(ls "$O"/*.failed 2>/dev/null | wc -l); n_kept=$(ls "$O"/*-[123].txt 2>/dev/null | wc -l)
[[ $n_failed == 7 && $n_kept == 0 ]] && pass "  … all 7 error files moved to .failed, none left to be mistaken for a verdict" \
    || fail "  … expected 7 .failed and 0 verdict files" "$n_failed .failed, $n_kept left"
[[ " $NAMES " == *" $target "* ]] && pass "  … the sampled experiment is recorded: $target" || fail "  … no sampled experiment recorded" "$target"

rm -rf "$STUB_SENT"/*
"$AUD" "$WORK/prop/zz" "$O" > "$WORK/a2.txt" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q "ALL 5 EXPERIMENTS PASSED" "$WORK/a2.txt" && pass "started again, it retries the failed runs and passes" \
    || fail "retry: expected PASS, got exit $rc" "$(tail -2 "$WORK/a2.txt")"
[[ $(sent) == 14 ]] && pass "  … 7 runs, 14 sessions (tiered: two a run)" || fail "  … expected 14 sessions" "$(sent)"
[[ "$(cat "$O/audit-target.txt")" == "$target" ]] && pass "  … the same experiment stays sampled" || fail "  … the sampled experiment changed"

rm -rf "$STUB_SENT"/*
"$AUD" "$WORK/prop/zz" "$O" > "$WORK/a3.txt" 2>&1; rc=$?
[[ $rc == 0 && $(sent) == 0 ]] && pass "a third start finds every verdict and calls no model" || fail "third start" "exit $rc, $(sent) sessions"

echo "STUB-SAYS-NO" >> "$WORK/prop/zz/exp103-life/README.md"
rm -rf "$STUB_SENT"/*
"$AUD" "$WORK/prop/zz" "$WORK/aud2" exp103-life > "$WORK/a4.txt" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q "^ESCALATED" "$WORK/a4.txt" && pass "a sampled experiment that fails escalates the other four, and the audit fails" \
    || fail "escalation: expected ESCALATED and exit 1, got $rc" "$(tail -2 "$WORK/a4.txt")"
ok3=1; for e in exp101 exp102 exp104 exp105; do [[ -f "$WORK/aud2/$e-life-2.txt" && -f "$WORK/aud2/$e-life-3.txt" ]] || ok3=0; done
(( ok3 )) && [[ $(sent) == 30 ]] && pass "  … each of them gets runs 2 and 3: 15 runs, 30 sessions" || fail "  … escalation runs" "$(sent) sessions"
[[ $(grep -c "^Mode: 3-run Consensus Audit" "$WORK/a4.txt") == 5 ]] && pass "  … and all five are tallied on three runs" || fail "  … not all tallied on three"

draws=""
for i in $(seq 12); do
    DRY_RUN=1 "$AUD" "$WORK/prop/zz" "$WORK/draw$i" > /dev/null 2>&1
    draws+="$(cat "$WORK/draw$i/audit-target.txt") "
done
n=$(tr ' ' '\n' <<< "$draws" | sort -u | grep -c .)
(( n >= 2 )) && pass "the sampled experiment is drawn at random ($n different in 12 draws)" || fail "the sampled experiment is always the same" "$draws"

echo
(( FAILED )) && { echo "selftest: FAIL"; exit 1; }
echo "selftest: PASS"
