#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
What the generated proof of a W^X micro-monitor is made of, once (from exp245 on; exp240 wrote it first).

exp240's monitor is exp236's words with a box of three PMP entries, and its proof is exp236's definitions and boot
with the PMP changed and the addresses moved, and a table of chunks (tools/monitor/chunks.py) from the trap vector to
the park loop. exp245's monitor is exp240's with words added, so the same text serves it with other addresses. A
generator calls `configure` first, with where its words are; the rest reads what it set.

  configure(...)          the monitor's size, its PMP, and where exp236's words now are (`h`, `shift`)
  definitions(t)          exp236's definitions, for this PMP
  boot_proof(t, ...)      exp236's boot, from any CSRs that lock no entry, ending `WXBoxed`
  handler_chunks()        the chunks of trap entry, the fault and HALT reports, the scrub and the registers
  REG_LEMMAS              the register scrub, as two lemmas
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chunks
from chunks import Chunk, Step, FROZEN, RCASES, REGLIST

# exp236's offsets of what the handler is made of: the fault report, the check of what an ecall asked for, the HALT
# report, the scrub, its registers, the park loop
FAULT, ECALL, HALTR = 0x130, 0x16c, 0x178
SCRUB, REGS, PARK = 0x1a0, 0x1ac, 0x234

CODE = "0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000"
CFG = A0 = A1 = A2 = None
A3 = "0#32"
WORDS = BYTES = BOOT_STEPS = ALL_STEPS = None
_moves = []                 # (from, to, by): exp236's offsets in [from, to) move on by `by`
_halt_to = _scrub_to = None


def configure(words, boot_steps, all_steps, moves, cfg, a0, a1, a2, a3="0#32", halt_to=None, scrub_to=None):
    """The monitor is `words` words; its boot's first part takes `boot_steps` and all of it `all_steps`; exp236's word
    at offset `x` is at `x + by` for the `(lo, hi, by)` of `moves` that holds it; the PMP is `cfg`, `a0`..`a3`. The
    check of what an ecall asked for goes on to `halt_to` for a HALT (exp236's HALT report, unless something comes
    before it), and the scrub of `mscratch` to `scrub_to` (exp236's register scrub, unless something comes between)."""
    global WORDS, BYTES, BOOT_STEPS, ALL_STEPS, _moves, CFG, A0, A1, A2, A3, _halt_to, _scrub_to
    WORDS, BYTES, BOOT_STEPS, ALL_STEPS = words, words * 4, boot_steps, all_steps
    _moves = list(moves)
    CFG, A0, A1, A2, A3 = cfg, a0, a1, a2, a3
    _halt_to = halt_to if halt_to is not None else h(HALTR)
    _scrub_to = scrub_to if scrub_to is not None else h(REGS)
    chunks.configure(words)


def moved(x: int) -> int:
    for lo, hi, by in _moves:
        if lo <= x < hi:
            return x + by
    raise ValueError(f"exp236's offset {x:#x} is in none of the moves")


def h(x: int) -> str:
    """An address inside the monitor, after boot: exp236's offset, where this monitor has that word."""
    return f"0x{0x80000000 + moved(x):08x}"


def shift(text: str) -> str:
    """exp236's text with every address from its boot's 0x90 on moved to where this monitor has it."""
    def move(m):
        v = int(m.group(1), 16)
        return f"0x8000{moved(v):04x}" if 0x90 <= v < 0x400 else m.group(0)
    return re.sub(r"0x8000([0-9a-f]{4})\b", move, text)


def swap(text: str, old: str, new: str, count: int = 1) -> str:
    """`text` with `old` replaced by `new`, `count` times exactly: exp236 changing under us is a failure here."""
    assert text.count(old) == count, f"{old[:60]!r} occurs {text.count(old)} times, not {count}"
    return text.replace(old, new)


def monitor_code(exp_dir: str) -> str:
    r = subprocess.run([sys.executable, os.path.join(exp_dir, "monitor.py"), "--emit-lean"],
                       capture_output=True, text=True, check=True)
    return r.stdout


def length() -> str:
    return """

set_option maxRecDepth 100000 in
theorem monitorCode_length : monitorCode.length = %d := by decide

""" % WORDS


def _napot(h_, lo, hi):
    return (f"Or.inr ⟨{lo}, {hi},\n      by simp [pmpAddrVal, {h_}, decodeNapotRange, countTrailingOnes32, "
            "countTrailingOnes32.loop], by decide, by decide⟩")


def definitions(t: str, config_doc: str, entry3=None) -> str:
    """exp236's definitions for this PMP: `config_doc` says what boot's first part leaves in the CSRs, and `entry3`, if
    the fourth entry is on, is its range `(lo, hi)`, inside the box."""
    t = swap(t, "/-- What boot's first twenty steps leave in the CSRs: trap vector, stack pointer for traps, the\n"
                "    PMP fencing off the payload region, the `mret` target, counters frozen at zero. -/", config_doc)
    a3 = "" if A3 == "0#32" else f" pmpaddr3 := {A3},"
    t = swap(t, "    pmpcfg0 := 0x1f#32, pmpaddr0 := 0x20005fff#32,\n    mcountinhibit := { cy := true, ir := true } }",
             f"    pmpcfg0 := {CFG}, pmpaddr0 := {A0}, pmpaddr1 := {A1},\n    pmpaddr2 := {A2},{a3}\n"
             "    mcountinhibit := { cy := true, ir := true } }")
    t = swap(t, "    pmpcfg0 := 0x1f#32, pmpaddr0 := 0x20005fff#32, pmpaddr1 := 0#32, pmpaddr2 := 0#32,\n    pmpaddr3 := 0#32,",
             f"    pmpcfg0 := {CFG}, pmpaddr0 := {A0}, pmpaddr1 := {A1}, pmpaddr2 := {A2},\n    pmpaddr3 := {A3},")
    t = swap(t, "(h4 : c.pmpcfg0 = 0x1f#32) (h5 : c.pmpaddr0 = 0x20005fff#32)\n"
                "    (h6 : c.pmpaddr1 = 0#32) (h7 : c.pmpaddr2 = 0#32) (h8 : c.pmpaddr3 = 0#32)",
             f"(h4 : c.pmpcfg0 = {CFG}) (h5 : c.pmpaddr0 = {A0})\n"
             f"    (h6 : c.pmpaddr1 = {A1}) (h7 : c.pmpaddr2 = {A2}) (h8 : c.pmpaddr3 = {A3})")
    i = t.index("/-- With the PMP boot set")
    j = t.index("/-- The common hypotheses of a handler step")
    if entry3 is None:
        doc3, h4, e3 = "and the fourth is off", "", "Or.inl (by rw [h0]; decide)"
    else:
        doc3, h4, e3 = "and so does the fourth", f" (h4 : csrs.pmpaddr3 = {A3})", _napot("h4", *entry3)
    t = t[:i] + f"""/-- With the PMP boot set, M-mode code outside the payload region is never refused: the three entries all lie
    inside `[0x80010000, 0x80020000)`, {doc3}. -/
theorem pmpCheck_mon (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (h0 : csrs.pmpcfg0 = {CFG}) (h1 : csrs.pmpaddr0 = {A0}) (h2 : csrs.pmpaddr1 = {A1})
    (h3 : csrs.pmpaddr2 = {A2}){h4}
    (hout : addr.toNat + width ≤ 0x80010000 ∨ 0x80020000 ≤ addr.toNat) :
    pmpCheck csrs .M addr width acc = true := by
  apply pmpCheck_M_outside_in csrs 0x80010000 0x80020000 addr width acc _ _ _ _ hout
  · exact {_napot("h1", "0x80010000", "0x80010080")}
  · exact {_napot("h2", "0x80010000", "0x80011000")}
  · exact {_napot("h3", "0x8001f000", "0x80020000")}
  · exact {e3}

""" + t[j:]
    return t + """/-- Where boot leaves the CSRs, whatever came before it: after the `mret`, counters running and having counted two
    instructions (`csrwi mcountinhibit, 0` and the `mret`), `mstatus` as `mret` leaves it, `mepc` the payload's entry. -/
def csrsBooted : PrivCSRs :=
  csrsH { mie := false, mpie := true, mpp := .U } 0x80010000#32 0#32 2#32 2#32 {} 0x80008000#32

"""


def boot_config(end: str) -> str:
    """exp240's first part of boot: from any CSRs at all but a locked PMP entry, `BOOT_STEPS` steps that write every CSR
    the model has and nothing in memory, to `end`."""
    return f"""set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Boot's first {BOOT_STEPS} steps, from any CSRs at all but a locked PMP entry: they write every CSR the model has, so
    `csrsConfigured` is where they end whatever was there. Until `pmpcfg0` is written the PMP is whatever the
    machine came with, and what lets M-mode run through it is that none of its entries is locked
    (`pmpCheck_M_unlocked`). -/
theorem monitor_boot_config (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hlock : PmpUnlocked s.csrs.pmpcfg0) :
    (PrivMachine.run env {BOOT_STEPS} s).core.pc = {end} ∧
    (PrivMachine.run env {BOOT_STEPS} s).core.mem = M0 ∧
    (PrivMachine.run env {BOOT_STEPS} s).halted = false ∧
    (PrivMachine.run env {BOOT_STEPS} s).mode = .M ∧
    (PrivMachine.run env {BOOT_STEPS} s).csrs = csrsConfigured := by
  have sm := sm_mon env M0 hW
  have l0 := hlock 0
  have l1 := hlock 1
  have l2 := hlock 2
  have l3 := hlock 3
  have hcfg : PmpUnlocked {CFG} := by intro i; revert i; decide
  have k3 := hcfg 3
  -- the counters count until `csrwi mcountinhibit, 5`, or not, as the inhibit bits they find say; then they are zeroed
  rcases hci : s.csrs.mcountinhibit with ⟨_ | _, _ | _⟩ <;>
  · obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env {BOOT_STEPS} s = F := ⟨_, rfl⟩
    rw [hF]
    psimpH [sm, hmem, hpc, monitorCode, hh, hm, hci, l0, l1, l2, l3, k3, hlock, hcfg, pmpCheck_M_unlocked] at hF
    subst hF
    psimpH [hpc, hmem, csrsConfigured]

"""


def boot_proof(t: str, config: str, *, binders="", front=None, m1="M0", hw1="hW", mem_out="M0", split=None,
               state0=None, cfg3="exact Or.inl (by rw [h5]; decide)", boot_doc="") -> str:
    """exp236's boot, changed to set the three entries, to start from any CSRs that lock no entry, and to say `WXBoxed`
    where it said `UBoxed`. `config` is the first part of boot (exp240's: `boot_config`); `front`, the lines of
    `monitor_boot` that run it and leave `c1`..`c5` about the state after it, whose memory is `m1`, its words `hw1`;
    `mem_out`, the memory boot ends with; `split`, the run's steps as a sum; `state0`, the state after the first part,
    as `split` writes it; `cfg3`, why entry 3 decides nothing."""
    t = swap(t, "run env 20 ", f"run env {BOOT_STEPS} ", count=t.count("run env 20 "))
    i = t.index("set_option maxHeartbeats 4000000 in\nset_option maxRecDepth 100000 in\ntheorem monitor_boot_config")
    j = t.index("/-! ## Boot, second half")
    t = t[:i] + config + t[j:]
    t = swap(t, "    (PrivMachine.run env 1 s).csrs.pmpcfg0 = 0x1f#32 ∧\n"
                "    (PrivMachine.run env 1 s).csrs.pmpaddr0 = 0x20005fff#32 ∧\n"
                "    (PrivMachine.run env 1 s).csrs.pmpaddr1 = 0#32 ∧\n"
                "    (PrivMachine.run env 1 s).csrs.pmpaddr2 = 0#32 ∧\n",
             f"    (PrivMachine.run env 1 s).csrs.pmpcfg0 = {CFG} ∧\n"
             f"    (PrivMachine.run env 1 s).csrs.pmpaddr0 = {A0} ∧\n"
             f"    (PrivMachine.run env 1 s).csrs.pmpaddr1 = {A1} ∧\n"
             f"    (PrivMachine.run env 1 s).csrs.pmpaddr2 = {A2} ∧\n")
    k = t.index("theorem monitor_launch_5")
    a, b = t[:k], t[k:]
    if A3 != "0#32":
        b = swap(b, "    (PrivMachine.run env 1 s).csrs.pmpaddr3 = 0#32 ∧\n", f"    (PrivMachine.run env 1 s).csrs.pmpaddr3 = {A3} ∧\n")
    b = swap(b, "    (PrivMachine.run env 1 s).csrs.mcountinhibit = {} ∧\n",
             "    (PrivMachine.run env 1 s).csrs.mcountinhibit = {} ∧\n    (PrivMachine.run env 1 s).csrs = csrsBooted ∧\n")
    b = swap(b, "  psimp [hpc, hmem, csrsConfigured, csrsReady]", "  psimp [hpc, hmem, csrsConfigured, csrsReady, csrsBooted, csrsH]")
    t = a + b
    if front is None:
        front = "  obtain ⟨c1, c2, c3, c4, c5⟩ := monitor_boot_config env M0 s hW hmem hpc hh hm hlock\n"
    if split is None:
        split = [BOOT_STEPS, 12, 12, 7, 1, 1]
    if state0 is None:
        state0 = f"PrivMachine.run env {BOOT_STEPS} s"
    sums = " + ".join(str(x) for x in split)
    adds = ["PrivMachine.run_add"] * (len(split) - 1)
    adds = ", ".join(adds[:2]) + ",\n    " + ", ".join(adds[2:])
    i = t.index("/-- From reset (the image loaded")
    return t[:i] + f"""/-- From reset (the image loaded at `0x80000000`, `pc = 0x80000040`, M-mode, any CSRs that lock no PMP entry --
    reset's among them -- any registers), {ALL_STEPS} steps leave the machine in U-mode at the payload's first word, the PMP fencing it
    in with three entries -- code `[0x80010000, 0x80010080)` read and execute, data `[0x80010000, 0x80011000)` and
    stack `[0x8001f000, 0x80020000)` read and write -- every register zero but `sp`{boot_doc}. -/
theorem monitor_boot (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hlock : PmpUnlocked s.csrs.pmpcfg0){binders} :
    WXBoxed (PrivMachine.run env {ALL_STEPS} s) {CODE} ∧
    (PrivMachine.run env {ALL_STEPS} s).core.pc = 0x80010000#32 ∧
    (PrivMachine.run env {ALL_STEPS} s).csrs = csrsBooted ∧
    (PrivMachine.run env {ALL_STEPS} s).core.mem = {mem_out} ∧
    (∀ r, (PrivMachine.run env {ALL_STEPS} s).core.reg r = if r = 2 then 0x80020000#32 else 0#32) := by
{front}  have hC0 : Cleared 0 ({state0}) := by
    intro r hr
    have : r = 0 := by bv_omega
    subst this
    simp
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := monitor_launch_1 env {m1} _ {hw1} c2 c1 c3 c4 c5 hC0
  obtain ⟨b1, b2, b3, b4, b5, b6⟩ := monitor_launch_2 env {m1} _ {hw1} a2 a1 a3 a4 a5 a6
  obtain ⟨e1, e2, e3, e4, e5, e6⟩ := monitor_launch_3 env {m1} _ {hw1} b2 b1 b3 b4 b5 b6
  obtain ⟨g1, g2, g3, g4, g5, g6⟩ := monitor_launch_4 env {m1} _ {hw1} e2 e1 e3 e4 e5
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, hb, h13⟩ :=
    monitor_launch_5 env {m1} _ {hw1} g2 g1 g3 g4 g5
  rw [show {ALL_STEPS} = {sums} from rfl, {adds}]
  refine ⟨⟨h4, h3, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, h1, hb, h2, ?_⟩
  · rw [h5]; decide
  · rw [h5]; decide
  · rw [h5]; decide
  · {cfg3}
  · simp [h6, decodeNapotRange, countTrailingOnes32, countTrailingOnes32.loop]
  · simp [h7, decodeNapotRange, countTrailingOnes32, countTrailingOnes32.loop]
  · simp [h8, decodeNapotRange, countTrailingOnes32, countTrailingOnes32.loop]
  · intro r
    rw [h13 r, g6 r]
    exact e6 r (by have h := r.isLt; omega)

"""


# ---- the chunks: one theorem shape, from tools/monitor/chunks.py

HSP = " (hsp : s.core.reg 2#5 = 0x80008000#32)"
HT1P = " (ht1 : s.core.reg 6#5 = 0xc0000004#32)"


def num(x):
    return f"(s.core.reg {x}#5).toNat % 4294967296"


Z = "0#32"
zregs = lambda a, b: ", ".join(f"({i}, {Z})" for i in range(a, b + 1))
CSRZ = f"csrsH ms e c m cy {FROZEN} (0#32)"
CSR0 = "csrsH ms e c m cy {} (0x80008000#32)"

# what each chunk writes to the ports, as `IoEvent`s (Rv32.Priv)
PRINT, EXIT = "0xc0000004#32", "0xc0000008#32"
ev = lambda a, v: f"⟨{a}, {v}⟩"
evs = lambda *xs: "[" + ", ".join(xs) + "]"
FAULT_REPORT = [ev(PRINT, "0x4641554c#32"), ev(PRINT, "c"), ev(PRINT, "e"), ev(PRINT, "0#32"), ev(PRINT, "m")]
HALT_REPORT = [ev(PRINT, "0x48414c54#32"), ev(PRINT, "s.core.reg 10#5"), ev(PRINT, "m"), ev(PRINT, "cy")]
HK = " (k : Nat)"
HKS = (" (hk : readLE s.core.mem 0x80008000#32 4 = k)", " (hk1 : BitVec.ofNat 32 k = 1#32)", " (hk1 : BitVec.ofNat 32 k ≠ 1#32)")
P2 = dict(csr_in=CSRZ, pbind="")
ZALL = ", ".join(f"({i}, 0#32)" for i in [*range(1, 10), *range(11, 32)])
ZW2 = {0: "0", 1: "0"}
SAVED = {0: num(5), 1: num(6)}
KARG = "((s.core.reg 5#5).toNat % 4294967296)"
HC = " (hc : c = 8#32)"
HCN = " (hc : c ≠ 8#32)"
IS_HALT = lambda v: " (ht0 : s.core.reg 5#5 = 1#32)" if v else " (ht0 : s.core.reg 5#5 ≠ 1#32)"


def handler_chunks() -> list:
    """exp236's handler, for this monitor: trap entry, the fault report, the check of what an ecall asked for, the HALT
    report, the scrub of the saved words and `mscratch`, and the registers, each a chunk."""
    out = []
    # trap entry
    out += [
        Chunk("entry_1", "Trap entry, first three words: freeze the counters, swap in the M-mode stack, save `t0`.",
              3, h(0x114), h(0x120), pbind="", csr_in=CSR0,
              csr_out=f"csrsH ms e c m cy {FROZEN} (s.core.reg 2#5)", words={0: num(5)}, regs="(2, 0x80008000#32)"),
        Chunk("entry_2a", "Save `t1`.", 1, h(0x120), h(0x124), hyps=HSP, words={1: num(6)}, extra=", hsp", store=True),
        Chunk("entry_mcause", "Read `mcause`: an `ecall` goes to the check of what it asked for, anything else to the fault report.",
              3, h(0x124), f"if c = 8#32 then {h(ECALL)}#32 else {h(FAULT)}#32", regs="(5, c), (6, 8#32)"),
    ]
    # the fault report
    out += [
        Chunk("fault_1", "Report FAULT: address and tag.", 5, h(FAULT), h(0x144), regs="(6, 0xc0000004#32), (5, 0x4641554c#32)", store=True,
              io=evs(FAULT_REPORT[0])),
        Chunk("fault_2", "Report `mcause`.", 2, h(0x144), h(0x14c), hyps=HT1P, regs="(5, c)", extra=", ht1", store=True, io=evs(FAULT_REPORT[1])),
        Chunk("fault_3", "Report `mepc`.", 2, h(0x14c), h(0x154), hyps=HT1P, regs="(5, e)", extra=", ht1", store=True, io=evs(FAULT_REPORT[2])),
        Chunk("fault_4", "Report `mtval`.", 2, h(0x154), h(0x15c), hyps=HT1P, regs="(5, 0#32)", extra=", ht1", store=True, io=evs(FAULT_REPORT[3])),
        Chunk("fault_5", "Report `minstret`.", 2, h(0x15c), h(0x164), hyps=HT1P, regs="(5, m)", extra=", ht1", store=True, io=evs(FAULT_REPORT[4])),
        Chunk("fault_6", "Exit code 1, and on to the scrub.", 2, h(0x164), h(SCRUB), regs="(10, 1#32)"),
    ]
    # what an ecall asked for
    out += [
        Chunk("call_is_halt", "Is the saved `t0` 1? If so, HALT; if not, it is not a call the monitor offers.", 3, h(ECALL),
              f"if BitVec.ofNat 32 k = 1#32 then {_halt_to}#32 else {h(FAULT)}#32", binders=HK, hyps=HSP + HKS[0],
              regs="(5, BitVec.ofNat 32 k), (6, 1#32)", extra=", hsp, hk", pre="  rw [hmem] at hk\n"),
    ]
    # the HALT report
    out += [
        Chunk("halt_1", "Report HALT: address and tag.", 5, h(HALTR), h(0x18c), regs="(6, 0xc0000004#32), (5, 0x48414c54#32)", store=True,
              io=evs(HALT_REPORT[0])),
        Chunk("halt_2", "Report the exit code.", 1, h(0x18c), h(0x190), hyps=HT1P, extra=", ht1", store=True, io=evs(HALT_REPORT[1])),
        Chunk("halt_3", "Report `minstret`.", 2, h(0x190), h(0x198), hyps=HT1P, extra=", ht1", regs="(5, m)", store=True, io=evs(HALT_REPORT[2])),
        Chunk("halt_4", "Report `mcycle`.", 2, h(0x198), h(SCRUB), hyps=HT1P, extra=", ht1", regs="(5, cy)", store=True, io=evs(HALT_REPORT[3])),
    ]
    # the scrub: the saved words and mscratch, then the registers
    out += [
        Chunk("scrub_1a", "Zero the saved `t0`.", 1, h(SCRUB), h(0x1a4), hyps=HSP, extra=", hsp", words={0: "0"}, store=True),
        Chunk("scrub_1b", "Zero the saved `t1`.", 1, h(0x1a4), h(0x1a8), hyps=HSP, extra=", hsp", words={1: "0"}, store=True),
        Chunk("scrub_ms", "Zero `mscratch`.", 1, h(0x1a8), _scrub_to, csr_out=CSRZ),
        Chunk("regs_a", "Zero `x1..x9`.", 9, h(REGS), h(0x1d0), regs=zregs(1, 9), **P2),
        Chunk("regs_b", "Zero `x11..x22`.", 12, h(0x1d0), h(0x200), regs=zregs(11, 22), **P2),
        Chunk("regs_c", "Zero `x23..x31`.", 9, h(0x200), h(0x224), regs=zregs(23, 31), **P2),
        Chunk("regs_port", "Exit code to the exit word.", 3, h(0x224), h(0x230), regs="(6, 0xc0000008#32)", store=True,
              io=evs(ev(EXIT, "s.core.reg 10#5")), **P2),
        Chunk("regs_last", "Last register, and the park loop.", 1, h(0x230), h(PARK), regs="(6, 0#32)", **P2),
    ]
    return out


class Table:
    """The chunks, by name, and the phases built from them, in the order they are written."""

    def __init__(self, cs):
        self.chunks = list(cs)
        self.by = {c.name: c for c in self.chunks}

    def S(self, name, **kw):
        return Step(self.by[name], **kw)

    def phase(self, c):
        self.chunks.append(c)
        self.by[c.name] = c
        return c

    def __getitem__(self, name):
        return self.by[name]


def handler_phases(T: Table, halt_steps=None, after_ms=None) -> None:
    """exp236's four phases of the handler: trap entry; the fault report and the first of the scrub; the HALT report
    and the same; the registers. `halt_steps` is what comes before the HALT report, if anything does, and `after_ms` is
    the phase the scrub of `mscratch` ends at, if it is not the registers."""
    S, phase = T.S, T.phase
    to = after_ms if after_ms is not None else h(REGS)
    phase(Chunk("monitor_enter", "Trap entry: the counters frozen, the M-mode stack swapped in, the payload's `t0` and `t1` saved, `mcause` read.",
                0, h(0x114), f"if c = 8#32 then {h(ECALL)}#32 else {h(FAULT)}#32", pbind="", csr_in=CSR0,
                csr_out=f"csrsH ms e c m cy {FROZEN} (s.core.reg 2#5)", words=SAVED, regs="(2, 0x80008000#32), (5, c), (6, 8#32)",
                steps=[S("entry_1"), S("entry_2a"), S("entry_mcause", last=True)]))
    phase(Chunk("monitor_fault_exit", "The fault report, then the saved words and `mscratch` zeroed: `a0 = 1`.",
                0, h(FAULT), to, hyps=HSP, csr_out=CSRZ, words=ZW2, regs="(6, 0xc0000004#32), (5, m), (10, 1#32)", io=evs(*FAULT_REPORT),
                steps=[S("fault_1", p="p"), S("fault_2", p="p"), S("fault_3", p="p"), S("fault_4", p="p"), S("fault_5", p="p"),
                       S("fault_6", p="p"), S("scrub_1a", p="p"), S("scrub_1b", p="p"), S("scrub_ms", p="p", last=True)]))
    phase(Chunk("monitor_halt_exit", "The HALT report, then the saved words and `mscratch` zeroed: `a0` is the payload's.",
                0, h(HALTR), to, hyps=HSP, csr_out=CSRZ, words=ZW2, regs="(6, 0xc0000004#32), (5, cy)", io=evs(*HALT_REPORT),
                steps=[S("halt_1", p="p"), S("halt_2", p="p"), S("halt_3", p="p"), S("halt_4", p="p"), S("scrub_1a", p="p"),
                       S("scrub_1b", p="p"), S("scrub_ms", p="p", last=True)]))
    phase(Chunk("monitor_regs", "The last of the scrub: every register but `a0` zero, the exit code written, the machine at the park loop.",
                0, h(REGS), h(PARK), csr_in=CSRZ, pbind="", csr_out=CSRZ, regs=ZALL, io=evs(ev(EXIT, "s.core.reg 10#5")),
                steps=[S("regs_a"), S("regs_b"), S("regs_c"), S("regs_port"), S("regs_last", last=True)]))


REG_LEMMAS = f"""
theorem reg32 (r : Reg) : {REGLIST} := by bv_omega

/-- The register scrub of a HALT: every register but `a0` zero, `a0` as it was. -/
theorem regs_scrubbed {{u t : PrivMachine}} (q : ∀ r, t.core.reg r = regsUpd u.core.reg [{ZALL}] r) :
    t.core.reg 10#5 = u.core.reg 10#5 ∧ ∀ r, r ≠ 10#5 → t.core.reg r = 0#32 := by
  refine ⟨?_, ?_⟩
  · rw [q 10#5]; simp [regsUpd]
  · intro r hr
    rw [q r]
    rcases reg32 r with {RCASES} <;> first | (exfalso; exact hr rfl) | simp [regsUpd]

/-- The register scrub of a fault: `a0` is 1, every other register zero. -/
theorem regs_scrubbed_fault {{u t : PrivMachine}} (q : ∀ r, t.core.reg r = regsUpd u.core.reg [{ZALL}, (10, 1#32)] r) :
    t.core.reg 10#5 = 1#32 ∧ ∀ r, r ≠ 10#5 → t.core.reg r = 0#32 := by
  refine ⟨?_, ?_⟩
  · rw [q 10#5]; simp [regsUpd]
  · intro r hr
    rw [q r]
    rcases reg32 r with {RCASES} <;> first | (exfalso; exact hr rfl) | simp [regsUpd]

"""
