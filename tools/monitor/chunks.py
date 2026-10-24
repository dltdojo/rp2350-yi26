#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
What a micro-monitor's generated Lean proof is made of, once (from exp239 on; exp238 wrote it first).

The proof runs a monitor's words on `PrivMachine` in short runs ("chunks"): each chunk is a theorem about a
handful of consecutive instructions, and every chunk has the same statement shape and the same proof, so a
generator writes them from a table. A chunk says where `pc` ends up, that the monitor's own words are where they
were, the CSRs, the four stack words trap entry saves, the service port, which memory is untouched (`Frame`), and
which registers changed. `Chunk` is one such run, or a chain of them; `Step` is one link of a chain; `chain` and
`final_chain` write the proof that joins them.

The monitor's words are exp236's for as far as they are the same: `from_236` cuts the proofs of boot and of the
chunks they share out of exp236's Monitor.lean and renames them. A generator calls `configure(words)` first, for the
size of its monitor.

  configure(words)       the monitor is `words` words long
  from_236(ns)           exp236's step lemmas, definitions, boot, helpers and `ofNat_toNat_mod`, in namespace ns
  FRAME, WRITELE4        the Lean text of where the monitor's own writes can land, and `writeLE4_apply`
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
EXP236 = os.path.join(REPO, "experiments", "exp236-the-wall-the-monitor-holds")

WORDS = 143
BYTES = WORDS * 4


def configure(words: int) -> None:
    """The monitor being proved is `words` words long."""
    global WORDS, BYTES
    WORDS, BYTES = words, words * 4


REGLIST = " ∨ ".join(f"r = {i}#5" for i in range(32))
RCASES = " | ".join(["rfl"] * 32)



def slice_between(text: str, start: str, end: str) -> str:
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j]


def from_236(ns: str) -> dict:
    with open(os.path.join(EXP236, "proof", "Monitor.lean"), encoding="utf-8") as f:
        t = f.read()
    sub = lambda s: s.replace("Exp236", ns).replace(" 572", f" {BYTES}")
    out = {}
    # step lemmas, then the definitions the handler proofs share
    out["step"] = sub(slice_between(t, "/-- Run from here, one step at a time", "/-! ## Definitions -/"))
    out["defs"] = sub(slice_between(t, "/-! ## Definitions -/", "/-! ## Boot, first half"))
    out["boot"] = sub(slice_between(t, "/-! ## Boot, first half", "set_option maxHeartbeats 4000000 in\nset_option maxRecDepth 100000 in\n/-- Trap entry, first three words"))
    out["helpers"] = sub(slice_between(t, "theorem run_two", "/-- The scrub, all of it"))
    out["ofnat"] = sub(slice_between(t, "theorem ofNat_toNat_mod", "set_option maxHeartbeats 4000000 in\n/-- A payload `ecall` with `t0 = 1`"))
    return out


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
                 pre="", steps=None, prelude="", custom=None, io=None):
        self.prelude, self.custom = prelude, custom
        self.io = io                                                     # None: no port written; else the Lean list appended to `io`
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
    {run}.host = s.host ∧
    {run}.io = {self.io_rhs()} ∧
{chr(10).join(words)}
{svc}
    Frame s.core.mem {run}.core.mem ∧
    (∀ r, {run}.core.reg r = regsUpd s.core.reg [{self.regs.replace('{RUN}', run)}] r) := by
"""

    def io_rhs(self) -> str:
        return "s.io" if self.io is None else f"s.io ++ {self.io}"

    def lean(self) -> str:
        if os.environ.get("STUBALL"):
            return self.statement() + "  sorry\n"
        return self.statement() + (self.custom if self.custom else self.chain_proof() if self.steps else self.simp_proof())

    def simp_proof(self) -> str:
        if os.environ.get("STUB") and self.name not in os.environ.get("REAL", "").split(","):
            return "  sorry\n"
        n, ex = self.n, self.extra
        simp_in = f"pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured{ex}"
        simp_out = f"pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd{ex}"
        holes = ", ".join(["?_"] * (5 + 2 + 4 + self.nsv + 2))
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
        return [f"p{i}", f"a{i}", f"h{i}", f"m{i}", f"c{i}", f"ho{i}", f"io{i}"] + ws + sv + [f"fr{i}", f"r{i}"]

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
            ios = ", ".join(f"io{j}, ho{j}" for j in range(i - 1, 0, -1))
            toks = [rlist(i) if t == "{R}" else (ios + ", List.append_assoc" if ios else "") if t == "{IO}" else t
                    for t in toks] + ["regsUpd"]
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
    holes = ", ".join([f"p{n}", f"a{n}", f"h{n}", f"m{n}", f"c{n}", "?ho", "?io"] + [f"?w{k}" for k in range(4)] + sv + ["?fr", "?r"])
    lines.append(f"  refine ⟨{holes}⟩\n")
    ho = "".join(f"(ho{i}.trans " for i in range(n, 1, -1)) + "ho1" + ")" * (n - 1)
    lines.append(f"  case ho => exact {ho}\n")
    ios = ", ".join(f"io{i}" for i in range(n, 0, -1))
    hos = ", ".join(f"ho{i}" for i in range(n, 0, -1))
    lines.append(f"  case io => simp [{simp(ios + ', ' + hos + ', List.append_assoc')}]\n")
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
    if "host" in c.regs:
        extra += ", " + ", ".join(f"io{j}, ho{j}" for j in range(n, 0, -1)) + ", List.append_assoc"
    lines.append(f"  case r =>\n    {R32} <;> simp [{simp(extra)}]\n")
    return "".join(lines)


# ---- a zeroing loop (from exp239 on)

def zloop(tag: str, store: str, exit_: str, framed: str) -> str:
    """The three words at `store`, `store + 4`, `store + 8`: `sw zero, 0(t0)`, `addi t0, t0, 4`, `bne t0, t1, store`,
    and `exit_` after them; the CSRs are `csrsH` with the inhibit `framed` and `mscratch` zero. The proof wants
    `pmpCheck_mon_in`: an M-mode access inside the payload's box is not refused. Three theorems, one per word, one
    for a trip round, and `zloop_{tag}`, by induction on the trips: `[A, E)` zeroed (`Zeroed`), the rest as it was."""
    B = BYTES
    s0 = int(store, 16)
    st, ad, bn, ex = store, f"0x{s0 + 4:08x}", f"0x{s0 + 8:08x}", exit_
    assert int(exit_, 16) == s0 + 12
    R32 = R32T
    FRAMED = framed
    guard = "set_option maxHeartbeats 4000000 in\nset_option maxRecDepth 100000 in\n"
    sm = f"""  obtain ⟨hW, hA', henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hAg : Agree M0 Mc 0x80000000 {B} := hmem ▸ hA'
  have sm : ∀ t : PrivMachine, Agree M0 t.core.mem 0x80000000 {B} →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW ht h1 h2
"""
    shape = lambda pc_out, mem_out, regs: f"""    (PrivMachine.run env 1 s).core.pc = {pc_out} ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 {B} ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy {FRAMED} (0#32) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ∧
    (PrivMachine.run env 1 s).core.mem = {mem_out} ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [{regs}] r)"""
    head = lambda name, pc, extra="": f"""theorem {name} (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word){extra}
    (hpc : s.core.pc = {pc}#32)
    (hcs : s.csrs = csrsH ms e c m cy {FRAMED} (0#32))"""
    tail = f"""  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hAg, agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, regsUpd]
  all_goals try ({R32} <;> psimpH [pmpCheck_mon, regsUpd])
"""
    out = f"""
/-! ### The zeroing loop at `{st}` ({tag}) -/

{guard}/-- The store: `sw zero, 0(t0)` zeroes the four bytes at `t0`, which lie wholly in the payload's box. -/
{head(f"zstore_{tag}", st, " (A : Word)")}
    (hA : s.core.reg 5#5 = A)
    (hal : A.toNat % 4 = 0) (hlo : 0x80010000 ≤ A.toNat) (hhi : A.toNat + 4 ≤ 0x80020000) :
{shape(ad + "#32", "writeLE s.core.mem A 0 4", "")} := by
{sm}  have hd1 : {0x80000000 + B} ≤ A.toNat := by omega
  have hw32 : A.toNat + 4 ≤ 4294967296 := by omega
  have hnr : ¬ (2147483648 ≤ A.toNat → 3221225724 < A.toNat) := by omega
  have hnp : ¬ (3221225472 ≤ A.toNat) := by omega
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [hnr, hnp, hal, hlo, hhi, hd1, hw32, pmpCheck_mon, pmpCheck_mon_in, sm, hmem, hAg, henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hA] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [hnp, hAg, hd1, hw32, hmem, hpc, csrsH, csrsFixed, csrsConfigured, agree_writeLE_iff, hlo, hhi, regsUpd]
  all_goals try ({R32} <;> psimpH [regsUpd])

{guard}/-- The add: `addi t0, t0, 4`. -/
{head(f"zadd_{tag}", ad)} :
{shape(bn + "#32", "s.core.mem", "(5, s.core.reg 5#5 + 4#32)")} := by
{sm}  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hAg, henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
{tail}
{guard}/-- The branch: `bne t0, t1, {st}` -- back to the store, or on. -/
{head(f"zbne_{tag}", bn)} :
{shape(f"(if s.core.reg 5#5 = s.core.reg 6#5 then {ex}#32 else {st}#32)", "s.core.mem", "")} := by
{sm}  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  by_cases hq : s.core.reg 5#5 = s.core.reg 6#5
  all_goals psimpH [pmpCheck_mon, sm, hmem, hAg, henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hq] at hF
  all_goals subst hF
  all_goals refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hAg, agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, regsUpd, hq]
  all_goals try ({R32} <;> psimpH [pmpCheck_mon, regsUpd, hq])

{guard}/-- One trip round the loop: three steps; the four bytes at `t0` zeroed, `t0` four on, and back to the store
    unless that was the last. -/
theorem zloop_iter_{tag} (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (A E : Word)
    (hpc : s.core.pc = {st}#32)
    (hcs : s.csrs = csrsH ms e c m cy {FRAMED} (0#32))
    (hA : s.core.reg 5#5 = A) (hE : s.core.reg 6#5 = E)
    (hal : A.toNat % 4 = 0) (hlo : 0x80010000 ≤ A.toNat) (hhi : A.toNat + 4 ≤ 0x80020000) :
    (PrivMachine.run env 3 s).core.pc = (if A + 4#32 = E then {ex}#32 else {st}#32) ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 {B} ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy {FRAMED} (0#32) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    (PrivMachine.run env 3 s).core.mem = writeLE s.core.mem A 0 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(5, A + 4#32)] r) := by
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 1 s = t := ⟨_, rfl⟩
  obtain ⟨p1, a1, h1, m1, c1, o1, i1, x1, r1⟩ := zstore_{tag} env M0 s hS ms e c m cy A hpc hcs hA hal hlo hhi
  rw [hs1] at p1 a1 h1 m1 c1 o1 i1 x1 r1
  have hS1 := hS.next a1 h1 m1
  obtain ⟨s2, hs2⟩ : ∃ t, PrivMachine.run env 1 s1 = t := ⟨_, rfl⟩
  obtain ⟨p2, a2, h2, m2, c2, o2, i2, x2, r2⟩ := zadd_{tag} env M0 s1 hS1 ms e c m cy p1 c1
  rw [hs2] at p2 a2 h2 m2 c2 o2 i2 x2 r2
  have hS2 := hS1.next a2 h2 m2
  obtain ⟨s3, hs3⟩ : ∃ t, PrivMachine.run env 1 s2 = t := ⟨_, rfl⟩
  obtain ⟨p3, a3, h3, m3, c3, o3, i3, x3, r3⟩ := zbne_{tag} env M0 s2 hS2 ms e c m cy p2 c2
  rw [hs3] at p3 a3 h3 m3 c3 o3 i3 x3 r3
  have hall : PrivMachine.run env 3 s = s3 := run_two hs1 (run_two hs2 hs3)
  have q1 : ∀ r, s1.core.reg r = s.core.reg r := fun r => by rw [r1 r]; simp [regsUpd]
  have t5 : s2.core.reg 5#5 = A + 4#32 := by rw [r2 5#5]; simp [regsUpd, q1, hA]
  have t6 : s2.core.reg 6#5 = E := by rw [r2 6#5]; simp [regsUpd, q1, hE]
  rw [hall]
  refine ⟨?_, a3, h3, m3, c3, by rw [o3, o2, o1], by rw [i3, i2, i1], ?_, ?_⟩
  · rw [p3, t5, t6]
  · rw [x3, x2, x1]
  · intro r
    have h3r := r3 r
    have h2r := r2 r
    simp only [regsUpd, List.find?_nil] at h3r h2r ⊢
    rw [h3r, h2r]
    simp [q1, hA]

{guard}/-- **The loop.** From the store, with `t0 = A` and `t1 = E` four-aligned, `A + 4 * (k + 1) = E`, and `[A, E)` in
    the payload's box: after `3 * (k + 1)` steps the machine stands at the instruction after the branch, `[A, E)` is
    zero, no other byte of memory has changed, and `t0 = E`. -/
theorem zloop_{tag} (env : Rv32.Env) (M0 : Word → Byte) :
    ∀ (k : Nat) (s : PrivMachine), HState env M0 s → ∀ (ms : MStatus) (e c m cy : Word) (A E : Word),
      s.core.pc = {st}#32 → s.csrs = csrsH ms e c m cy {FRAMED} (0#32) →
      s.core.reg 5#5 = A → s.core.reg 6#5 = E →
      A.toNat % 4 = 0 → 0x80010000 ≤ A.toNat → A.toNat + 4 * (k + 1) = E.toNat → E.toNat ≤ 0x80020000 →
      (PrivMachine.run env (3 * (k + 1)) s).core.pc = {ex}#32 ∧
      Agree M0 (PrivMachine.run env (3 * (k + 1)) s).core.mem 0x80000000 {B} ∧
      (PrivMachine.run env (3 * (k + 1)) s).halted = false ∧
      (PrivMachine.run env (3 * (k + 1)) s).mode = .M ∧
      (PrivMachine.run env (3 * (k + 1)) s).csrs = csrsH ms e c m cy {FRAMED} (0#32) ∧
      (PrivMachine.run env (3 * (k + 1)) s).host = s.host ∧
      (PrivMachine.run env (3 * (k + 1)) s).io = s.io ∧
      Zeroed A.toNat E.toNat s.core.mem (PrivMachine.run env (3 * (k + 1)) s).core.mem ∧
      (∀ r, (PrivMachine.run env (3 * (k + 1)) s).core.reg r = regsUpd s.core.reg [(5, E)] r) := by
  intro k
  induction k with
  | zero =>
    intro s hS ms e c m cy A E hpc hcs hA hE hal hlo hk hEhi
    have hAE : A + 4#32 = E := by
      apply BitVec.eq_of_toNat_eq
      have := A.isLt
      simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]
      omega
    obtain ⟨p, a, h, m', c', o, i, x, rr⟩ := zloop_iter_{tag} env M0 s hS ms e c m cy A E hpc hcs hA hE hal hlo (by omega)
    refine ⟨?_, a, h, m', c', o, i, ?_, ?_⟩
    · rw [p]; simp [hAE]
    · rw [x]
      have := zeroed_write A s.core.mem (by omega)
      rw [show E.toNat = A.toNat + 4 by omega]
      exact this
    · intro r
      rw [rr r, hAE]
  | succ k ih =>
    intro s hS ms e c m cy A E hpc hcs hA hE hal hlo hk hEhi
    have hne : ¬ (A + 4#32 = E) := by
      intro h
      have := congrArg BitVec.toNat h
      have := A.isLt
      simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod] at *
      omega
    have hA4 : (A + 4#32).toNat = A.toNat + 4 := by
      have := A.isLt
      simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]
      omega
    obtain ⟨p, a, h, m', c', o, i, x, r⟩ := zloop_iter_{tag} env M0 s hS ms e c m cy A E hpc hcs hA hE hal hlo (by omega)
    obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 3 s = t := ⟨_, rfl⟩
    rw [hs1] at p a h m' c' o i x r
    simp only [hne, ↓reduceIte] at p
    have hS1 := hS.next a h m'
    have hA1 : s1.core.reg 5#5 = A + 4#32 := by rw [r 5#5]; simp [regsUpd]
    have hE1 : s1.core.reg 6#5 = E := by rw [r 6#5]; simp [regsUpd, hE]
    obtain ⟨p2, a2, h2, m2, c2, o2, i2, z2, r2⟩ := ih s1 hS1 ms e c m cy (A + 4#32) E p c' hA1 hE1
      (by rw [hA4]; omega) (by rw [hA4]; omega) (by rw [hA4]; omega) hEhi
    rw [show 3 * (k + 1 + 1) = 3 + 3 * (k + 1) by omega, PrivMachine.run_add, hs1]
    refine ⟨p2, a2, h2, m2, c2, o2.trans o, i2.trans i, ?_, ?_⟩
    · rw [x] at z2
      rw [hA4] at z2
      have := zeroed_write A s.core.mem (by omega)
      exact zeroed_trans this z2 (by omega) (by omega)
    · intro r'
      rw [r2 r']
      by_cases h5 : r'.toNat = 5
      · simp [regsUpd, h5]
      · have h5' : 5 ≠ r'.toNat := fun h => h5 h.symm
        have h1r := r r'
        simp [regsUpd, h5, h5'] at h1r ⊢
        exact h1r
"""
    return out


FRAME = """
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

"""

WRITELE4 = """theorem writeLE4_apply (m : Word → Byte) (a : Word) (v : Nat) (x : Word) :
    writeLE m a v 4 x = if (x - a).toNat < 4 then BitVec.ofNat 8 (v / 256 ^ (x - a).toNat) else m x :=
  writeLE_apply m a v 4 (by decide) x

"""
