#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Writes proof/Calls.lean.

The proof runs `monitorCode` on `PrivMachine` in short runs ("chunks"): each chunk is a theorem
about a handful of consecutive instructions, and every chunk has the same statement shape and the
same proof, so they are written down once, here, as a table. Boot is exp236's, word for word (the
first 73 words of the two monitors are the same), copied from its proof with the names changed.
The theorems that join the chunks — the calls, the faults, the end to end — are written by hand in
`tail.lean`.

  gen.py            write Calls.lean
  gen.py --check    exit 0 if Calls.lean is what this writes
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
EXP236 = os.path.join(REPO, "experiments", "exp236-the-wall-the-monitor-holds")
OUT = os.path.join(HERE, os.environ.get("OUT", "Calls.lean"))

WORDS = 200
BYTES = WORDS * 4

REGLIST = " ∨ ".join(f"r = {i}#5" for i in range(32))
RCASES = " | ".join(["rfl"] * 32)


def slice_between(text: str, start: str, end: str) -> str:
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j]


def from_236() -> dict:
    with open(os.path.join(EXP236, "proof", "Monitor.lean"), encoding="utf-8") as f:
        t = f.read()
    sub = lambda s: s.replace("Exp236", "Exp238").replace(" 572", f" {BYTES}")
    out = {}
    # step lemmas, then the definitions the handler proofs share
    out["step"] = sub(slice_between(t, "/-- Run from here, one step at a time", "/-! ## Definitions -/"))
    out["defs"] = sub(slice_between(t, "/-! ## Definitions -/", "/-! ## Boot, first half"))
    out["boot"] = sub(slice_between(t, "/-! ## Boot, first half", "set_option maxHeartbeats 4000000 in\nset_option maxRecDepth 100000 in\n/-- Trap entry, first three words"))
    out["helpers"] = sub(slice_between(t, "theorem run_two", "/-- The scrub, all of it"))
    out["ofnat"] = sub(slice_between(t, "theorem ofNat_toNat_mod", "set_option maxHeartbeats 4000000 in\n/-- A payload `ecall` with `t0 = 1`"))
    return out


def monitor_code() -> str:
    r = subprocess.run([sys.executable, os.path.join(HERE, "..", "monitor.py"), "--emit-lean"],
                       capture_output=True, text=True, check=True)
    return r.stdout


STACK = [("0x80008000#32", 0), ("0x80008004#32", 1), ("0x80008008#32", 2), ("0x8000800c#32", 3)]
FROZEN = "{ cy := true, ir := true }"


def hexpc(x: str) -> str:
    if x.startswith("if "):
        return f"({x})"
    return x if ("#32" in x or x[0].isalpha()) else f"{x}#32"


def r32(ind):
    pad = " " * ind
    return f"intro r\n{pad}have hr32 : {REGLIST} := by bv_omega\n{pad}rcases hr32 with {RCASES}"


R32 = r32(4)
R32T = r32(17)

HNAMES = re.compile(r"\((h\w*) :")


class Chunk:
    """One short run. Every field that is Lean text is Lean text."""

    def __init__(self, name, doc, n, pc, pc_out, *, hyps="", binders="", regs="", words=None,
                 csr_in=None, csr_out=None, mode_out=".M", svc=None, extra="", store=False, pbind=" (p : Word)",
                 pre="", steps=None, prelude="", custom=None):
        self.prelude, self.custom = prelude, custom
        self.pre = pre
        self.pbind = pbind
        self.name, self.doc, self.n, self.pc, self.pc_out = name, doc, n, pc, pc_out
        self.hyps, self.binders, self.regs = hyps, binders, regs        # regs: "(5, c), (6, 8#32)"
        self.words = words or {}                                         # index -> Lean text of the new value
        self.csr_in = csr_in or f"csrsH ms e c m cy {FROZEN} (p)"
        self.csr_out = csr_out or self.csr_in
        self.mode_out = mode_out
        self.svc = svc                                                   # None: unchanged; else four Lean texts
        self.extra = extra                                               # extra simp names
        self.store = store
        self.steps = steps                                               # a chain of chunks, instead of a run of words
        if steps:
            self.n = sum(st.chunk.n for st in steps)
        self.nsv = 1 if svc is None else 4

    exists_n = False

    def run(self):
        return f"(PrivMachine.run env {self.n} s)"

    def statement(self) -> str:
        run = self.run()
        words = []
        for addr, i in STACK:
            rhs = self.words.get(i, f"readLE s.core.mem {addr} 4")
            words.append(f"    readLE {run}.core.mem {addr} 4 = {rhs} ∧")
        if self.svc is None:
            svc = f"    SvcSame s.core.mem {run}.core.mem ∧"
        else:
            addrs = ["0xc0000010", "0xc0000014", "0xc0000018", "0xc000001c"]
            svc = "\n".join(f"    readLE {run}.core.mem {a}#32 4 = {v if v is not None else f'readLE s.core.mem {a}#32 4'} ∧"
                            for a, v in zip(addrs, self.svc))
        return f"""set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- {self.doc} -/
theorem {self.name} (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word){self.pbind}{self.binders}
    (hpc : s.core.pc = {hexpc(self.pc)}) (hcs : s.csrs = {self.csr_in}){self.hyps} :
    {"∃ N, " if self.exists_n else ""}{run}.core.pc = {hexpc(self.pc_out)} ∧
    Agree M0 {run}.core.mem 0x80000000 {BYTES} ∧
    {run}.halted = false ∧
    {run}.mode = {self.mode_out} ∧
    {run}.csrs = {self.csr_out} ∧
{chr(10).join(words)}
{svc}
    Frame s.core.mem {run}.core.mem ∧
    (∀ r, {run}.core.reg r = regsUpd s.core.reg [{self.regs.replace('{RUN}', run)}] r) := by
"""

    def lean(self) -> str:
        return self.statement() + (self.custom if self.custom else self.chain_proof() if self.steps else self.simp_proof())

    def simp_proof(self) -> str:
        if os.environ.get("STUB") and self.name not in os.environ.get("REAL", "").split(","):
            return "  sorry\n"
        n, ex = self.n, self.extra
        simp_in = f"pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured{ex}"
        simp_out = f"pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd{ex}"
        holes = ", ".join(["?_"] * (5 + 4 + self.nsv + 2))
        m = re.match(r"^\(?if (.*) then .* else .*?\)?$", self.pc_out)
        cond = m.group(1) if m else None
        split = f"  by_cases hq : {cond}\n" if cond else ""
        hq = ", hq" if cond else ""
        return f"""  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 {BYTES} := hmem ▸ hA
  have sm : ∀ t : PrivMachine, Agree M0 t.core.mem 0x80000000 {BYTES} →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW ht h1 h2
{self.pre}  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env {n} s = F := ⟨_, rfl⟩
  rw [hF]
{split}  all_goals psimpH [{simp_in}{hq}] at hF
  all_goals subst hF
  all_goals refine ⟨{holes}⟩
  all_goals try psimpH [{simp_out}{hq}]
  all_goals try (unfold Frame
                 intro x h1 h2 h3
                 simp only [writeLE4_apply, InStack, InPorts, InSvc, BitVec.toNat_sub, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod] at h1 h2 h3 ⊢
                 repeat' split
                 all_goals first | rfl | omega)
  all_goals try (unfold SvcSame
                 intro x h1
                 simp only [writeLE4_apply, InSvc, BitVec.toNat_sub, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod] at h1 ⊢
                 repeat' split
                 all_goals first | rfl | omega)
  all_goals try ({R32T} <;> psimpH [pmpCheck_mon, regsUpd{ex}])
"""

    # ---- chains: a chunk that is a run of other chunks

    def names(self, i):
        """The names of the facts one step of a chain returns, in the order of the statement."""
        ws = [f"w{i}_{k}" for k in range(4)]
        sv = [f"sv{i}"] if self.svc is None else [f"sv{i}_{k}" for k in range(4)]
        return [f"p{i}", f"a{i}", f"h{i}", f"m{i}", f"c{i}"] + ws + sv + [f"fr{i}", f"r{i}"]

    def chain_proof(self) -> str:
        return chain(self.steps, "  have p0 := hpc\n  have c0 := hcs\n  have hS0 := hS\n" + self.prelude, final_chain(self), own=HNAMES.findall(self.hyps))


class Step:
    """One link of a chain: the chunk, what to pass it, and the proofs of its hypotheses."""

    def __init__(self, chunk, e="e", p="(s.core.reg 2#5)", args=(), hyps=None, resolve="", last=False):
        self.chunk, self.e, self.p, self.args, self.hyps = chunk, e, p, list(args), hyps or {}
        self.resolve, self.last = resolve, last


def rlist(i):
    return ", ".join(f"r{j}" for j in range(i - 1, 0, -1))


def wlist(i, k):
    return ", ".join(f"w{j}_{k}" for j in range(i - 1, 0, -1))


def chain(steps, start, finish, own=(), state0="s") -> str:
    out = [start]
    for i, st in enumerate(steps, 1):
        c = st.chunk
        prev = state0 if i == 1 else f"s{i-1}"
        ns = c.names(i)
        simp = ", ".join(x for x in [rlist(i), "regsUpd", *own] if x)
        hy = []
        for hn in HNAMES.findall(c.hyps):
            if hn in st.hyps:
                hy.append(st.hyps[hn])
            elif hn.startswith(("hsp", "ht")):
                hy.append(f"(by simp [{simp}])")
            else:
                raise KeyError(f"{c.name}: no proof for {hn}")
        parg = f" {st.p}" if c.pbind else ""
        out.append(f"  obtain ⟨s{i}, hs{i}⟩ : ∃ t, PrivMachine.run env {c.n} {prev} = t := ⟨_, rfl⟩\n")
        out.append(f"  obtain ⟨{', '.join(ns)}⟩ := {c.name} env M0 {prev} hS{i-1} ms {st.e} c m cy{parg}{''.join(' ' + a for a in st.args)} p{i-1} c{i-1}{''.join(' ' + x for x in hy)}\n")
        out.append(f"  rw [hs{i}] at {' '.join(ns)}\n")
        if c.svc is None:
            for k, a in enumerate(SVCADDR):
                out.append(f"  have sv{i}_{k} : readLE s{i}.core.mem {a}#32 4 = readLE {prev}.core.mem {a}#32 4 := SvcSame.read sv{i} _ (by decide)\n")
        if st.resolve:
            toks = [t for t in (x.strip() for x in st.resolve.split(",")) if t]
            toks = [rlist(i) if t == "{R}" else t for t in toks] + ["regsUpd"]
            out.append(f"  simp [{', '.join(t for t in toks if t)}] at p{i}\n")
        if not st.last:
            out.append(f"  have hS{i} := hS{i-1}.next a{i} h{i} m{i}\n")
    n = len(steps)
    comp = f"hs{n}"
    for i in range(n - 1, 0, -1):
        comp = f"run_two hs{i} ({comp})"
    out.append(f"  have hall : PrivMachine.run env {sum(st.chunk.n for st in steps)} {state0} = s{n} := {comp}\n")
    out.append(finish)
    return "".join(out)


SVCADDR = ["0xc0000010", "0xc0000014", "0xc0000018", "0xc000001c"]


def final_chain(c):
    """The conclusion of a phase: each fact of the statement, from the facts of its steps."""
    steps = c.steps
    n = len(steps)
    R = rlist(n + 1)
    own = ", ".join(HNAMES.findall(c.hyps))
    simp = lambda w: ", ".join(x for x in [w, R, "regsUpd", own] if x)
    lines = ["  rw [hall]\n"]
    sv = ["?sv"] if c.svc is None else [f"?sv{k}" for k in range(4)]
    holes = ", ".join([f"p{n}", f"a{n}", f"h{n}", f"m{n}", f"c{n}"] + [f"?w{k}" for k in range(4)] + sv + ["?fr", "?r"])
    lines.append(f"  refine ⟨{holes}⟩\n")
    for k in range(4):
        lines.append(f"  case w{k} => simp [{simp(wlist(n + 1, k))}]\n")
    if c.svc is None:
        fr = "".join(f"(sv{i}.trans " for i in range(1, n)) + f"sv{n}" + ")" * (n - 1)
        lines.append(f"  case sv => exact {fr}\n")
    else:
        for k in range(4):
            w = ", ".join(f"sv{j}_{k}" for j in range(n, 0, -1))
            lines.append(f"  case sv{k} => simp [{simp(w)}]\n")
    fr = "".join(f"(fr{i}.trans " for i in range(1, n)) + f"fr{n}" + ")" * (n - 1)
    lines.append(f"  case fr => exact {fr}\n")
    extra = ", ".join(f"w{j}_{k}" for j in range(n, 0, -1) for k in range(4)) + ", ofNat_toNat_mod"
    if "{RUN}" in c.regs:
        extra += ", " + ", ".join(f"sv{j}_3" for j in range(n, 0, -1))
    lines.append(f"  case r =>\n    {R32} <;> simp [{simp(extra)}]\n")
    return "".join(lines)



HEAD = """/-
SPDX-License-Identifier: Apache-2.0

# exp238 — the call the monitor checks

What `monitor.bin` does, proved by running its own words on `PrivMachine`.

GENERATED by gen.py: the short runs ("chunks") are one theorem shape with one proof; the
theorems that join them are in tail.lean.
-/
import Rv32.PrivRun
import Rv32.Refinement
import Rv32.Sandbox

set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

namespace Exp238
open Rv32
open Rv32.Priv
open Rv32.Refinement

/-- The words of `monitor.bin`, from `0x80000000`. -/
"""

LENGTH = """

set_option maxRecDepth 100000 in
theorem monitorCode_length : monitorCode.length = %d := by decide

""" % WORDS

MEM = """
/-! ## Where the monitor's own writes can land -/

/-- The four words trap entry saves on the M-mode stack. -/
def InStack (x : Word) : Prop := 0x80008000 ≤ x.toNat ∧ x.toNat < 0x80008010
/-- The testbench's report words: print and exit. -/
def InPorts (x : Word) : Prop := 0xc0000000 ≤ x.toNat ∧ x.toNat < 0xc0000010
/-- The service port: three argument words and the request. -/
def InSvc (x : Word) : Prop := 0xc0000010 ≤ x.toNat ∧ x.toNat < 0xc0000020

/-- Memory outside the monitor's stack words, the report words and the service port is what it was:
    the payload's box included. -/
def Frame (m m' : Word → Byte) : Prop := ∀ x, ¬ InStack x → ¬ InPorts x → ¬ InSvc x → m' x = m x

/-- The service port's bytes are what they were: the host was not asked. -/
def SvcSame (m m' : Word → Byte) : Prop := ∀ x, InSvc x → m' x = m x

theorem Frame.trans {a b c : Word → Byte} (h1 : Frame a b) (h2 : Frame b c) : Frame a c :=
  fun x i p v => (h2 x i p v).trans (h1 x i p v)

theorem SvcSame.trans {a b c : Word → Byte} (h1 : SvcSame a b) (h2 : SvcSame b c) : SvcSame a c :=
  fun x h => (h2 x h).trans (h1 x h)

theorem SvcSame.read {m m' : Word → Byte} (h : SvcSame m m') (a : Word)
    (ha : 0xc0000010 ≤ a.toNat ∧ a.toNat + 4 ≤ 0xc0000020) : readLE m' a 4 = readLE m a 4 := by
  apply readLE_four_congr
  intro d hd
  apply h
  unfold InSvc
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]
  omega

/-! ## The bounds check, as arithmetic -/

theorem ult_lo_iff (a : Word) : BitVec.ult a 0x80010000#32 = false ↔ 0x80010000 ≤ a.toNat := by
  simp only [BitVec.ult, decide_eq_false_iff_not, Nat.not_lt, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]

theorem ult_hi_iff (a : Word) : BitVec.ult 0x80020000#32 a = false ↔ a.toNat ≤ 0x80020000 := by
  simp only [BitVec.ult, decide_eq_false_iff_not, Nat.not_lt, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]

theorem ult_room_iff (a len : Word) (h : a.toNat ≤ 0x80020000) :
    BitVec.ult (0x80020000#32 - a) len = false ↔ a.toNat + len.toNat ≤ 0x80020000 := by
  have e : (0x80020000#32 - a).toNat = 0x80020000 - a.toNat := by
    rw [BitVec.toNat_sub_of_le (by rw [BitVec.le_def]; simpa using h)]
    simp
  simp only [BitVec.ult, decide_eq_false_iff_not, Nat.not_lt, e]
  omega

/-- The three comparisons of the bounds check pass exactly when `[a, a + len)` lies in the box, the sum
    taken in the naturals: a range whose end wraps past `2^32` does not. -/
theorem bounds_ok_iff (a len : Word) :
    (BitVec.ult a 0x80010000#32 = false ∧ BitVec.ult 0x80020000#32 a = false ∧
      BitVec.ult (0x80020000#32 - a) len = false) ↔
    (0x80010000 ≤ a.toNat ∧ a.toNat + len.toNat ≤ 0x80020000) := by
  constructor
  · rintro ⟨h1, h2, h3⟩
    have h2' := (ult_hi_iff a).mp h2
    exact ⟨(ult_lo_iff a).mp h1, (ult_room_iff a len h2').mp h3⟩
  · rintro ⟨h1, h2⟩
    have h2' : a.toNat ≤ 0x80020000 := by omega
    exact ⟨(ult_lo_iff a).mpr h1, (ult_hi_iff a).mpr h2', (ult_room_iff a len h2').mpr h2⟩

/-- The same, for a length that is a constant. -/
theorem bounds_len_iff (a : Word) (n : Nat) (hn : n < 4294967296) :
    (BitVec.ult a 0x80010000#32 = false ∧ BitVec.ult 0x80020000#32 a = false ∧
      BitVec.ult (0x80020000#32 - a) (BitVec.ofNat 32 n) = false) ↔
    (0x80010000 ≤ a.toNat ∧ a.toNat + n ≤ 0x80020000) := by
  rw [bounds_ok_iff]
  simp only [BitVec.toNat_ofNat, Nat.reducePow, Nat.mod_eq_of_lt hn]

theorem writeLE4_apply (m : Word → Byte) (a : Word) (v : Nat) (x : Word) :
    writeLE m a v 4 x = if (x - a).toNat < 4 then BitVec.ofNat 8 (v / 256 ^ (x - a).toNat) else m x :=
  writeLE_apply m a v 4 (by decide) x

"""


def build(chunks_text: str) -> str:
    f = from_236()
    with open(os.path.join(HERE, "tail.lean"), encoding="utf-8") as g:
        tail = g.read()
    parts = [HEAD, monitor_code(), LENGTH, f["step"], f["defs"], MEM, f["boot"], f["helpers"], f["ofnat"], chunks_text, tail]
    return "\n".join(parts)


LO, HI = "0x80010000#32", "0x80020000#32"
HT1 = f" (ht1 : s.core.reg 6#5 = {LO})"
HT2 = f" (ht2 : s.core.reg 7#5 = {HI})"
HSP = " (hsp : s.core.reg 2#5 = 0x80008000#32)"
HT1P = " (ht1 : s.core.reg 6#5 = 0xc0000004#32)"
FAULT, ECALL = 0x138, 0x174


def h(x: int) -> str:
    """An address inside the monitor: its offset, as the word it is at."""
    return f"0x{0x80000000 + x:08x}"


def branch(name, doc, pc, n, cond, nxt, regs="", binders="", hyps="", extra=""):
    """A compare-and-branch of the bounds check: to the fault report if `cond`, else on."""
    return Chunk(name, f"{doc}: if so, to the fault report; if not, on.", n, h(pc),
                 f"if {cond} = true then {h(FAULT)}#32 else {h(nxt)}#32", regs=regs, binders=binders, hyps=hyps, extra=extra)


def u(n):
    return f"s.core.reg {n}#5"


CHUNKS = []


def add(*cs):
    for c in cs:
        if isinstance(c, list):
            CHUNKS.extend(c)
        else:
            CHUNKS.append(c)


def num(x):
    return f"(s.core.reg {x}#5).toNat % 4294967296"


# ---- trap entry
add(Chunk("entry_1", "Trap entry, first three words: freeze the counters, swap in the M-mode stack, save `t0`.",
          3, "0x80000114", "0x80000120", pbind="", csr_in="csrsH ms e c m cy {} (0x80008000#32)",
          csr_out=f"csrsH ms e c m cy {FROZEN} (s.core.reg 2#5)", words={0: num(5)}, regs="(2, 0x80008000#32)"),
    Chunk("entry_2a", "Save `t1`.", 1, "0x80000120", "0x80000124", hyps=HSP, words={1: num(6)}, extra=", hsp", store=True),
    Chunk("entry_2b", "Save `t2`.", 1, "0x80000124", "0x80000128", hyps=HSP, words={2: num(7)}, extra=", hsp", store=True),
    Chunk("entry_2c", "Save `t3`.", 1, "0x80000128", "0x8000012c", hyps=HSP, words={3: num(28)}, extra=", hsp", store=True),
    Chunk("entry_mcause", "Read `mcause`: an `ecall` goes to the call check, anything else to the fault report.", 3, "0x8000012c",
          f"if c = 8#32 then {h(ECALL)}#32 else {h(FAULT)}#32", regs="(5, c), (6, 8#32)"))

# ---- the fault report, then the scrub that every way out of the monitor ends in
add(Chunk("fault_1", "Report FAULT: address and tag.", 5, h(FAULT), "0x8000014c", regs="(6, 0xc0000004#32), (5, 0x4641554c#32)", store=True),
    Chunk("fault_2", "Report `mcause`.", 2, "0x8000014c", "0x80000154", hyps=HT1P, regs="(5, c)", extra=", ht1", store=True),
    Chunk("fault_3", "Report `mepc`.", 2, "0x80000154", "0x8000015c", hyps=HT1P, regs="(5, e)", extra=", ht1", store=True),
    Chunk("fault_4", "Report `mtval`.", 2, "0x8000015c", "0x80000164", hyps=HT1P, regs="(5, 0#32)", extra=", ht1", store=True),
    Chunk("fault_5", "Report `minstret`.", 2, "0x80000164", "0x8000016c", hyps=HT1P, regs="(5, m)", extra=", ht1", store=True),
    Chunk("fault_6", "Exit code 1, and on to the scrub.", 2, "0x8000016c", "0x8000027c", regs="(10, 1#32)"))

HK = " (k : Nat)"
HKS = (" (hk : readLE s.core.mem 0x80008000#32 4 = k)", " (hk1 : BitVec.ofNat 32 k = 1#32)", " (hk1 : BitVec.ofNat 32 k ≠ 1#32)")
add(Chunk("call_is_halt", "Is the saved `t0` 1? If so, HALT; if not, on.", 3, h(0x174),
          f"if BitVec.ofNat 32 k = 1#32 then {h(0x254)}#32 else {h(0x180)}#32", binders=HK, hyps=HSP + HKS[0],
          regs="(5, BitVec.ofNat 32 k), (6, 1#32)", extra=", hsp, hk", pre="  rw [hmem] at hk\n"),
    Chunk("call_is_hashb", "Is `t0` 2? If so, HASHB; if not, on.", 2, h(0x180),
          f"if s.core.reg 5#5 = 2#32 then {h(0x194)}#32 else {h(0x188)}#32", regs="(6, 2#32)"),
    Chunk("call_is_checksig", "Is `t0` 3? If so, CHECKSIG; if not, it is not a call the monitor offers.", 2, h(0x188),
          f"if s.core.reg 5#5 = 3#32 then {h(0x1e0)}#32 else {h(0x190)}#32", regs="(6, 3#32)"),
    Chunk("call_unknown", "Not a call the monitor offers: to the fault report.", 1, h(0x190), h(FAULT)))

# ---- HASHB
SUB = lambda r: f"{HI} - {u(r)}"
add(Chunk("hashb_load", "Load `BOX_LO` and `BOX_HI`.", 2, h(0x194), h(0x19c), regs=f"(6, {LO}), (7, {HI})"),
    branch("hashb_b1", "`a0 < BOX_LO`", 0x19c, 1, f"BitVec.ult ({u(10)}) {LO}", 0x1a0, hyps=HT1, extra=", ht1"),
    branch("hashb_b2", "`BOX_HI < a0`", 0x1a0, 1, f"BitVec.ult {HI} ({u(10)})", 0x1a4, hyps=HT2, extra=", ht2"),
    Chunk("hashb_s3", "`t3 = BOX_HI - a0`.", 1, h(0x1a4), h(0x1a8), regs=f"(28, {SUB(10)})", hyps=HT2, extra=", ht2"),
    branch("hashb_b3", "`BOX_HI - a0 < a1`", 0x1a8, 1, f"BitVec.ult ({u(28)}) ({u(11)})", 0x1ac),
    branch("hashb_b4", "`a2 < BOX_LO`", 0x1ac, 1, f"BitVec.ult ({u(12)}) {LO}", 0x1b0, hyps=HT1, extra=", ht1"),
    branch("hashb_b5", "`BOX_HI < a2`", 0x1b0, 1, f"BitVec.ult {HI} ({u(12)})", 0x1b4, hyps=HT2, extra=", ht2"),
    Chunk("hashb_s6", "`t3 = BOX_HI - a2`, `t0 = 32`.", 2, h(0x1b4), h(0x1bc), regs=f"(28, {SUB(12)}), (5, 32#32)", hyps=HT2, extra=", ht2"),
    branch("hashb_b6", "`BOX_HI - a2 < 32`", 0x1bc, 1, f"BitVec.ult ({u(28)}) ({u(5)})", 0x1c0),
    Chunk("hashb_fwd_1", "Forward: the port's address, and the input pointer.", 3, h(0x1c0), h(0x1cc),
          regs="(28, 0xc0000010#32)", svc=[num(10), None, None, None], store=True),
    Chunk("hashb_fwd_2", "Forward: the length.", 1, h(0x1cc), h(0x1d0), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          svc=[None, num(11), None, None], store=True),
    Chunk("hashb_fwd_3", "Forward: the output pointer.", 1, h(0x1d0), h(0x1d4), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          svc=[None, None, num(12), None], store=True),
    Chunk("hashb_fwd_4", "Forward: the request.", 2, h(0x1d4), h(0x1dc), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          regs="(5, 2#32)", svc=[None, None, None, "2"], store=True),
    Chunk("hashb_fwd_5", "On to the way back.", 1, h(0x1dc), h(0x22c)))

# ---- CHECKSIG
add(Chunk("checksig_load", "Load `BOX_LO` and `BOX_HI`.", 2, h(0x1e0), h(0x1e8), regs=f"(6, {LO}), (7, {HI})"),
    branch("checksig_b1", "`a0 < BOX_LO`", 0x1e8, 1, f"BitVec.ult ({u(10)}) {LO}", 0x1ec, hyps=HT1, extra=", ht1"),
    branch("checksig_b2", "`BOX_HI < a0`", 0x1ec, 1, f"BitVec.ult {HI} ({u(10)})", 0x1f0, hyps=HT2, extra=", ht2"),
    Chunk("checksig_s3", "`t3 = BOX_HI - a0`, `t0 = 32`.", 2, h(0x1f0), h(0x1f8), regs=f"(28, {SUB(10)}), (5, 32#32)", hyps=HT2, extra=", ht2"),
    branch("checksig_b3", "`BOX_HI - a0 < 32`", 0x1f8, 1, f"BitVec.ult ({u(28)}) ({u(5)})", 0x1fc),
    branch("checksig_b4", "`a1 < BOX_LO`", 0x1fc, 1, f"BitVec.ult ({u(11)}) {LO}", 0x200, hyps=HT1, extra=", ht1"),
    branch("checksig_b5", "`BOX_HI < a1`", 0x200, 1, f"BitVec.ult {HI} ({u(11)})", 0x204, hyps=HT2, extra=", ht2"),
    Chunk("checksig_s6", "`t3 = BOX_HI - a1`, `t0 = 64`.", 2, h(0x204), h(0x20c), regs=f"(28, {SUB(11)}), (5, 64#32)", hyps=HT2, extra=", ht2"),
    branch("checksig_b6", "`BOX_HI - a1 < 64`", 0x20c, 1, f"BitVec.ult ({u(28)}) ({u(5)})", 0x210),
    Chunk("checksig_fwd_1", "Forward: the port's address, and the key pointer.", 3, h(0x210), h(0x21c),
          regs="(28, 0xc0000010#32)", svc=[num(10), None, None, None], store=True),
    Chunk("checksig_fwd_2", "Forward: the signature pointer.", 1, h(0x21c), h(0x220), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          svc=[None, num(11), None, None], store=True),
    Chunk("checksig_fwd_3", "Forward: the request.", 2, h(0x220), h(0x228), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          regs="(5, 3#32)", svc=[None, None, None, "3"], store=True),
    Chunk("checksig_fwd_4", "Read the answer, into `a0`.", 1, h(0x228), h(0x22c), hyps=" (ht3 : s.core.reg 28#5 = 0xc0000010#32)", extra=", ht3",
          regs="(10, BitVec.ofNat 32 (readLE s.core.mem 0xc000001c#32 4))"))

# ---- the way back
add(Chunk("return_1", "Past the `ecall`: `mepc <- mepc + 4`.", 3, h(0x22c), h(0x238), csr_out=f"csrsH ms (e + 4#32) c m cy {FROZEN} (p)",
          regs="(5, e + 4#32)"),
    Chunk("return_2", "The payload's `t0..t3` back from the stack.", 4, h(0x238), h(0x248), hyps=HSP, extra=", hsp",
          csr_in=f"csrsH ms e c m cy {FROZEN} (p)",
          regs="(5, BitVec.ofNat 32 (readLE s.core.mem 0x80008000#32 4)), (6, BitVec.ofNat 32 (readLE s.core.mem 0x80008004#32 4)), "
               "(7, BitVec.ofNat 32 (readLE s.core.mem 0x80008008#32 4)), (28, BitVec.ofNat 32 (readLE s.core.mem 0x8000800c#32 4))"),
    Chunk("return_3", "The payload's `sp` back, the counters released, `mret`.", 3, h(0x248), "e",
          hyps=HSP + " (hmpp : ms.mpp = .U)", mode_out=".U",
          csr_out="csrsH { mie := ms.mpie, mpie := true, mpp := .U } e c (m + 2#32) (cy + 2#32) {} (0x80008000#32)",
          regs="(2, p)", extra=", hsp, hmpp, BitVec.add_assoc"))

# ---- HALT
add(Chunk("halt_1", "Report HALT: address and tag.", 5, h(0x254), h(0x268), regs="(6, 0xc0000004#32), (5, 0x48414c54#32)", store=True),
    Chunk("halt_2", "Report the exit code.", 1, h(0x268), h(0x26c), hyps=HT1P, extra=", ht1", store=True),
    Chunk("halt_3", "Report `minstret`.", 2, h(0x26c), h(0x274), hyps=HT1P, extra=", ht1", regs="(5, m)", store=True),
    Chunk("halt_4", "Report `mcycle`.", 2, h(0x274), h(0x27c), hyps=HT1P, extra=", ht1", regs="(5, cy)", store=True))

# ---- the scrub
Z = "0#32"
zregs = lambda a, b: ", ".join(f"({i}, {Z})" for i in range(a, b + 1))
add(Chunk("scrub_1a", "Zero the saved `t0`.", 1, h(0x27c), h(0x280), hyps=HSP, extra=", hsp", words={0: "0"}, store=True),
    Chunk("scrub_1b", "Zero the saved `t1`.", 1, h(0x280), h(0x284), hyps=HSP, extra=", hsp", words={1: "0"}, store=True),
    Chunk("scrub_1c", "Zero the saved `t2`.", 1, h(0x284), h(0x288), hyps=HSP, extra=", hsp", words={2: "0"}, store=True),
    Chunk("scrub_1d", "Zero the saved `t3`.", 1, h(0x288), h(0x28c), hyps=HSP, extra=", hsp", words={3: "0"}, store=True),
    Chunk("scrub_2", "Zero `mscratch`, and `x1..x9`.", 10, h(0x28c), h(0x2b4), csr_out=f"csrsH ms e c m cy {FROZEN} (0#32)", regs=zregs(1, 9)),
    Chunk("scrub_3", "Zero `x11..x22`.", 12, h(0x2b4), h(0x2e4), csr_in=f"csrsH ms e c m cy {FROZEN} (0#32)", regs=zregs(11, 22), pbind=""),
    Chunk("scrub_4", "Zero `x23..x31`.", 9, h(0x2e4), h(0x308), csr_in=f"csrsH ms e c m cy {FROZEN} (0#32)", regs=zregs(23, 31), pbind=""),
    Chunk("scrub_5", "Exit code to the exit word.", 3, h(0x308), h(0x314), csr_in=f"csrsH ms e c m cy {FROZEN} (0#32)", regs="(6, 0xc0000008#32)", pbind="", store=True),
    Chunk("scrub_6", "Last register, and the park loop.", 1, h(0x314), h(0x318), csr_in=f"csrsH ms e c m cy {FROZEN} (0#32)", regs="(6, 0#32)", pbind=""))


# ---- phases: chains of the chunks above, with the same shape of statement
CH = {c.name: c for c in CHUNKS}


def S(name, **kw):
    return Step(CH[name], **kw)


def phase(c, steps_):
    CHUNKS.append(c)
    CH[c.name] = c
    return c


ZALL = ", ".join(f"({i}, 0#32)" for i in [*range(1, 10), *range(11, 32)])
ZW = {0: "0", 1: "0", 2: "0", 3: "0"}
CSR0 = "csrsH ms e c m cy {} (0x80008000#32)"
CSRZ = f"csrsH ms e c m cy {FROZEN} (0#32)"
SAVED = {0: num(5), 1: num(6), 2: num(7), 3: num(28)}
PARK = h(0x318)

phase(Chunk("monitor_scrub", "The scrub, all of it: every register but `a0` zero, `mscratch` zero, the four saved words zero, the machine at the park loop.",
            0, h(0x27c), PARK, hyps=HSP, csr_out=CSRZ, words=ZW, regs=ZALL,
            steps=[S("scrub_1a", p="p"), S("scrub_1b", p="p"), S("scrub_1c", p="p"), S("scrub_1d", p="p"), S("scrub_2", p="p"),
                   S("scrub_3"), S("scrub_4"), S("scrub_5"), S("scrub_6", last=True)]), None)
phase(Chunk("monitor_fault_exit", "The fault report, then the scrub: `a0 = 1`, every other register zero.",
            0, h(FAULT), PARK, hyps=HSP, csr_out=CSRZ, words=ZW, regs=ZALL + ", (10, 1#32)",
            steps=[S("fault_1", p="p"), S("fault_2", p="p"), S("fault_3", p="p"), S("fault_4", p="p"), S("fault_5", p="p"),
                   S("fault_6", p="p"), S("monitor_scrub", p="p", last=True)]), None)
phase(Chunk("monitor_halt_exit", "The HALT report, then the scrub: `a0` is the payload's exit code, every other register zero.",
            0, h(0x254), PARK, hyps=HSP, csr_out=CSRZ, words=ZW, regs=ZALL,
            steps=[S("halt_1", p="p"), S("halt_2", p="p"), S("halt_3", p="p"), S("halt_4", p="p"), S("monitor_scrub", p="p", last=True)]), None)
phase(Chunk("monitor_enter", "Trap entry: the counters frozen, the M-mode stack swapped in, the payload's `t0..t3` saved, `mcause` read.",
            0, h(0x114), f"if c = 8#32 then {h(ECALL)}#32 else {h(FAULT)}#32", pbind="", csr_in=CSR0,
            csr_out=f"csrsH ms e c m cy {FROZEN} (s.core.reg 2#5)", words=SAVED, regs="(2, 0x80008000#32), (5, c), (6, 8#32)",
            steps=[S("entry_1"), S("entry_2a"), S("entry_2b"), S("entry_2c"), S("entry_mcause", last=True)]), None)

KARG = "((s.core.reg 5#5).toNat % 4294967296)"
OFM = "ofNat_toNat_mod, {R}"


def dispatch(*, halt, hashb=None, checksig=None):
    """The steps from the trap vector to the first word of the code that `t0` selects."""
    st = [S("monitor_enter", resolve="hc"),
          S("call_is_halt", args=[KARG], hyps={"hk": "w1_0"}, resolve=OFM + ", ht0")]
    return st


def scenario(name, doc, hyps, steps_, *, pc_out, csr_out, words, regs, svc=None, mode_out=".M", prelude="", custom=None):
    c = Chunk(name, doc, 0, h(0x114), pc_out, pbind="", hyps=hyps, csr_in=CSR0, csr_out=csr_out,
              words=words, regs=regs, svc=svc, mode_out=mode_out, steps=steps_, prelude=prelude, custom=custom)

    phase(c, None)
    return c


HC = " (hc : c = 8#32)"
HCN = " (hc : c ≠ 8#32)"
IS_HALT = lambda v: " (ht0 : s.core.reg 5#5 = 1#32)" if v else " (ht0 : s.core.reg 5#5 ≠ 1#32)"
LAST = dict(last=True)

scenario("monitor_halt", "`ecall` with `t0 = 1`: from the trap vector the machine parks, `a0` the payload's own exit code, every other register zero.",
         HC + IS_HALT(True),
         [S("monitor_enter", resolve="hc"),
          S("call_is_halt", args=[KARG], hyps={"hk": "w1_0"}, resolve="ofNat_toNat_mod, ht0"),
          S("monitor_halt_exit", last=True)],
         pc_out=PARK, csr_out=CSRZ, words=ZW, regs=ZALL)
scenario("monitor_fault_cause", "A trap that is not an `ecall`: from the trap vector the machine parks with `a0 = 1` and every other register zero.",
         HCN,
         [S("monitor_enter", resolve="hc"), S("monitor_fault_exit", last=True)],
         pc_out=PARK, csr_out=CSRZ, words=ZW, regs=ZALL + ", (10, 1#32)")
scenario("monitor_fault_syscall", "An `ecall` whose `t0` is none of 1, 2, 3: from the trap vector the machine parks with `a0 = 1` and every other register zero.",
         HC + IS_HALT(False) + " (ht2 : s.core.reg 5#5 ≠ 2#32) (ht3 : s.core.reg 5#5 ≠ 3#32)",
         [S("monitor_enter", resolve="hc"),
          S("call_is_halt", args=[KARG], hyps={"hk": "w1_0"}, resolve="ofNat_toNat_mod, ht0"),
          S("call_is_hashb", resolve=OFM + ", ht2"),
          S("call_is_checksig", resolve=OFM + ", ht3"),
          S("call_unknown"),
          S("monitor_fault_exit", last=True)],
         pc_out=PARK, csr_out=CSRZ, words=ZW, regs=ZALL + ", (10, 1#32)")


# ---- the calls
BOUND = [  # the six checks of each call: name, condition on the call's registers
    ("hashb", [f"BitVec.ult ({u(10)}) {LO}", f"BitVec.ult {HI} ({u(10)})", f"BitVec.ult ({SUB(10)}) ({u(11)})",
               f"BitVec.ult ({u(12)}) {LO}", f"BitVec.ult {HI} ({u(12)})", f"BitVec.ult ({SUB(12)}) 32#32"]),
    ("checksig", [f"BitVec.ult ({u(10)}) {LO}", f"BitVec.ult {HI} ({u(10)})", f"BitVec.ult ({SUB(10)}) 32#32",
                  f"BitVec.ult ({u(11)}) {LO}", f"BitVec.ult {HI} ({u(11)})", f"BitVec.ult ({SUB(11)}) 64#32"]),
]
RET_CSR = "csrsH { mie := ms.mpie, mpie := true, mpp := .U } (e + 4#32) c (m + 2#32) (cy + 2#32) {} (0x80008000#32)"
HMPP = " (hmpp : ms.mpp = .U)"
INBOX = lambda a, n: f"0x80010000 ≤ (s.core.reg {a}#5).toNat ∧ (s.core.reg {a}#5).toNat + {n} ≤ 0x80020000"


def call_steps(call, upto, ok):
    """The steps from the trap vector through the first `upto` checks of `call`; `ok`: all of them pass and the call returns."""
    pre = "hashb" if call == "hashb" else "checksig"
    st = [S("monitor_enter", resolve="hc"),
          S("call_is_halt", args=[KARG], hyps={"hk": "w1_0"}, resolve="ofNat_toNat_mod, ht0")]
    st.append(S("call_is_hashb", resolve=OFM + ", ht0"))
    if call == "checksig":
        st.append(S("call_is_checksig", resolve=OFM + ", ht0"))
    st.append(S(f"{pre}_load"))
    for j in range(1, upto + 1):
        if j in (3, 6):
            st.append(S(f"{pre}_s{j}"))
        st.append(S(f"{pre}_b{j}", resolve=f"{{R}}, hb{j}"))
    return st


for call, conds in BOUND:
    t0 = 2 if call == "hashb" else 3
    HT = f" (ht0 : s.core.reg 5#5 = {t0}#32)"
    # a served call
    if call == "hashb":
        hyps = HC + HT + f" (hin : {INBOX(10, '(s.core.reg 11#5).toNat')}) (hout : {INBOX(12, 32)})" + HMPP
        prelude = ("  obtain ⟨hb1, hb2, hb3⟩ := (bounds_ok_iff _ _).mpr hin\n"
                   "  obtain ⟨hb4, hb5, hb6⟩ := (bounds_len_iff _ 32 (by decide)).mpr hout\n")
        fwd = [S(f"hashb_fwd_{i}") for i in range(1, 6)]
        svc = [num(10), num(11), num(12), "2"]
        regs = ""
    else:
        hyps = HC + HT + f" (hkey : {INBOX(10, 32)}) (hsig : {INBOX(11, 64)})" + HMPP
        prelude = ("  obtain ⟨hb1, hb2, hb3⟩ := (bounds_len_iff _ 32 (by decide)).mpr hkey\n"
                   "  obtain ⟨hb4, hb5, hb6⟩ := (bounds_len_iff _ 64 (by decide)).mpr hsig\n")
        fwd = [S(f"checksig_fwd_{i}") for i in range(1, 5)]
        svc = [num(10), num(11), None, "3"]
        regs = "(10, BitVec.ofNat 32 (readLE {RUN}.core.mem 0xc000001c#32 4))"
    steps = call_steps(call, 6, True) + fwd + [
        S("return_1"), S("return_2", e="(e + 4#32)"), S("return_3", e="(e + 4#32)", hyps={"hmpp": "hmpp"}, last=True)]
    scenario(f"monitor_{call}_ok",
             f"A `{call.upper()}` whose ranges lie in the box: from the trap vector the call is forwarded exactly as the payload gave it, "
             f"and the machine is back in the payload at the word after the `ecall` — the payload's registers "
             f"{'as they were' if call == 'hashb' else 'as they were but `a0`, which holds the service port word the request read'}, "
             "the counters released and moved on by two.",
             hyps, steps, pc_out="e + 4#32", csr_out=RET_CSR, words=SAVED, regs=regs, svc=svc, mode_out=".U", prelude=prelude)
    # a refused call: one scenario for each check
    for k in range(1, 7):
        hy = HC + HT
        for j in range(1, k):
            hy += f" (hb{j} : {conds[j-1]} = false)"
        hy += f" (hb{k} : {conds[k-1]} = true)"
        steps = call_steps(call, k, False) + [S("monitor_fault_exit", last=True)]
        scenario(f"monitor_{call}_oob_{k}",
                 f"A `{call.upper()}` that fails check {k} of 6: from the trap vector the machine parks with `a0 = 1`, "
                 "every other register zero, and the service port as it was.",
                 hy, steps, pc_out=PARK, csr_out=CSRZ, words=ZW, regs=ZALL + ", (10, 1#32)")


# ---- the headline: a call that is not wholly in the box is refused, whichever check it fails
for call, conds in BOUND:
    t0 = 2 if call == "hashb" else 3
    HT = f" (ht0 : s.core.reg 5#5 = {t0}#32)"
    if call == "hashb":
        a, b = INBOX(10, "(s.core.reg 11#5).toNat"), INBOX(12, 32)
        done = ("(bounds_ok_iff _ _).mp ⟨c1', c2', c3'⟩", "(bounds_len_iff _ 32 (by decide)).mp ⟨c4', c5', c6'⟩")
    else:
        a, b = INBOX(10, 32), INBOX(11, 64)
        done = ("(bounds_len_iff _ 32 (by decide)).mp ⟨c1', c2', c3'⟩", "(bounds_len_iff _ 64 (by decide)).mp ⟨c4', c5', c6'⟩")
    body = []
    for k in range(1, 7):
        prev = "".join(f" c{j}'" for j in range(1, k))
        body.append(f"  by_cases c{k} : {conds[k-1]} = true\n")
        body.append(f"  · exact ⟨_, monitor_{call}_oob_{k} env M0 s hS ms e c m cy hpc hcs hc ht0{prev} c{k}⟩\n")
        body.append(f"  have c{k}' : {conds[k-1]} = false := by simpa using c{k}\n")
    body.append(f"  exact absurd (And.intro ({done[0]}) ({done[1]})) hbad\n")
    c = Chunk(f"monitor_{call}_oob_fault",
              f"**A `{call.upper()}` that is not wholly in the box is refused.** Whichever of its ranges is out — below the box, "
              "past it, straddling either end, or one whose end wraps past `2^32` — the machine parks with `a0 = 1`, every other "
              "register zero, and the service port as it was: the host is never asked.",
              "N", h(0x114), PARK, pbind="", hyps=HC + HT + f" (hbad : ¬ (({a}) ∧ ({b})))", csr_in=CSR0, csr_out=CSRZ,
              words=ZW, regs=ZALL + ", (10, 1#32)", custom="".join(body))
    c.exists_n = True
    CHUNKS.append(c)

def main():
    only = os.environ.get("ONLY")
    cs = [c for c in CHUNKS if not only or not (c.steps or c.custom) or c.name in only.split(",")]
    text = build("\n".join(c.lean() for c in cs))
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as g:
            return 0 if g.read() == text else 1
    with open(OUT, "w", encoding="utf-8") as g:
        g.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
