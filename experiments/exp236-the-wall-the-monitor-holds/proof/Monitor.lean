/-
SPDX-License-Identifier: Apache-2.0

# exp236 — the wall the monitor holds

What `monitor.bin` does, proved by running its own words on `PrivMachine`.

`monitorCode` is the binary, word for word, and `check.sh` holds it against `monitor.S`
assembled afresh. Everything below is about what those words do when the model
fetches and executes them:

  * `monitor_boot`   from reset, 53 steps leave the PMP fencing off the payload region,
                     the machine in U-mode at its first word, every register zero but
                     `sp`, the trap vector and the M-mode stack pointer set;
  * `monitor_halt` / `monitor_fault`   from the trap vector, whatever the payload left
                     in its registers, the machine parks with every register zero but
                     `a0` — the payload's own exit code on HALT, 1 on a fault;
  * `umode_*`        while the payload runs, it stays in the box or traps to the vector,
                     and memory outside the box is not changed.

Not proved, on purpose: that the payload memory is scrubbed (it is not), what the MMIO
words print (the model treats them as memory), or anything about the chip: the words
run on the model of `lean/Rv32/Priv.lean` and nowhere else.
-/
import Rv32.PrivRun
import Rv32.Refinement
import Rv32.Sandbox

set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

namespace Exp236
open Rv32
open Rv32.Priv
open Rv32.Refinement

/-- The words of `monitor.bin`, from `0x80000000`. -/
def monitorCode : List Word := [
  0x0400006f#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000000#32,
  0x00000297#32,
  0x0d428293#32,
  0x30529073#32,
  0x800082b7#32,
  0x34029073#32,
  0x3202d073#32,
  0x200062b7#32,
  0xfff28293#32,
  0x3b029073#32,
  0x01f00293#32,
  0x3a029073#32,
  0x800102b7#32,
  0x34129073#32,
  0x00300293#32,
  0x00b29293#32,
  0x3002b073#32,
  0xb0201073#32,
  0xb8201073#32,
  0xb0001073#32,
  0xb8001073#32,
  0x80020137#32,
  0x00000093#32,
  0x00000193#32,
  0x00000213#32,
  0x00000293#32,
  0x00000313#32,
  0x00000393#32,
  0x00000413#32,
  0x00000493#32,
  0x00000513#32,
  0x00000593#32,
  0x00000613#32,
  0x00000693#32,
  0x00000713#32,
  0x00000793#32,
  0x00000813#32,
  0x00000893#32,
  0x00000913#32,
  0x00000993#32,
  0x00000a13#32,
  0x00000a93#32,
  0x00000b13#32,
  0x00000b93#32,
  0x00000c13#32,
  0x00000c93#32,
  0x00000d13#32,
  0x00000d93#32,
  0x00000e13#32,
  0x00000e93#32,
  0x00000f13#32,
  0x00000f93#32,
  0x32005073#32,
  0x30200073#32,
  0x3202d073#32,
  0x34011173#32,
  0x00512023#32,
  0x00612223#32,
  0x342022f3#32,
  0x00800313#32,
  0x04628063#32,
  0xc0000337#32,
  0x00430313#32,
  0x464152b7#32,
  0x54c28293#32,
  0x00532023#32,
  0x342022f3#32,
  0x00532023#32,
  0x341022f3#32,
  0x00532023#32,
  0x343022f3#32,
  0x00532023#32,
  0xb02022f3#32,
  0x00532023#32,
  0x00100513#32,
  0x0380006f#32,
  0x00012283#32,
  0x00100313#32,
  0xfa629ee3#32,
  0xc0000337#32,
  0x00430313#32,
  0x484152b7#32,
  0xc5428293#32,
  0x00532023#32,
  0x00a32023#32,
  0xb02022f3#32,
  0x00532023#32,
  0xb00022f3#32,
  0x00532023#32,
  0x00012023#32,
  0x00012223#32,
  0x34001073#32,
  0x00000093#32,
  0x00000113#32,
  0x00000193#32,
  0x00000213#32,
  0x00000293#32,
  0x00000313#32,
  0x00000393#32,
  0x00000413#32,
  0x00000493#32,
  0x00000593#32,
  0x00000613#32,
  0x00000693#32,
  0x00000713#32,
  0x00000793#32,
  0x00000813#32,
  0x00000893#32,
  0x00000913#32,
  0x00000993#32,
  0x00000a13#32,
  0x00000a93#32,
  0x00000b13#32,
  0x00000b93#32,
  0x00000c13#32,
  0x00000c93#32,
  0x00000d13#32,
  0x00000d93#32,
  0x00000e13#32,
  0x00000e93#32,
  0x00000f13#32,
  0x00000f93#32,
  0xc0000337#32,
  0x00830313#32,
  0x00a32023#32,
  0x00000313#32,
  0x10500073#32,
  0xffdff06f#32
]


set_option maxRecDepth 100000 in
theorem monitorCode_length : monitorCode.length = 143 := by decide

/-- Run from here, one step at a time, on the words of the monitor. `M0` is the memory the
    words were loaded into; `Agree M0 m` says `m` still has them. -/
theorem step_mon {env : Rv32.Env} {M0 : Word → Byte} {t : PrivMachine}
    (hW : WordsAt M0 0x80000000#32 monitorCode)
    (hA : Agree M0 t.core.mem 0x80000000 572)
    (hlt : (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length)
    (hal : (t.core.pc - 0x80000000#32).toNat % 4 = 0) :
    PrivMachine.step env t =
      PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) := by
  have hW' : WordsAt t.core.mem 0x80000000#32 monitorCode :=
    WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact hA) hW
  exact step_of_words' hW' hlt hal

/-- With the monitor's memory untouched, the step of any state is the step of the word at its `pc`. -/
theorem sm_mon (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode) :
    ∀ t : PrivMachine, t.core.mem = M0 →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
  fun t ht h1 h2 => step_mon hW (by rw [ht]; exact Agree.refl _ _ _) h1 h2

/-! ## Definitions -/

/-- What boot's first twenty steps leave in the CSRs: trap vector, stack pointer for traps, the
    PMP fencing off the payload region, the `mret` target, counters frozen at zero. -/
def csrsConfigured : PrivCSRs :=
  { mtvec := 0x80000114#32, mscratch := 0x80008000#32, mepc := 0x80010000#32,
    pmpcfg0 := 0x1f#32, pmpaddr0 := 0x20005fff#32,
    mcountinhibit := { cy := true, ir := true } }

/-- Registers `x0..xK` hold what the launch sequence leaves them: zero, but `sp`. -/
def Cleared (K : Nat) (s : PrivMachine) : Prop :=
  ∀ r : Reg, r.toNat ≤ K → s.core.reg r = if r = 2 then 0x80020000#32 else 0#32

/-! ## The trap handler

From here the state is what a payload left behind: any registers, any memory outside the
monitor's own words, the CSRs boot set (`csrsFixed`) with the five fields a running payload
and a trap move (`mstatus`, `mepc`, `mcause` and the two counters) free. -/

/-- The CSRs a payload cannot change: everything boot set, with the counters running. -/
def csrsFixed : PrivCSRs := { csrsConfigured with mcountinhibit := {} }

/-- The handler's CSRs: `csrsFixed` with the free fields, the inhibit and `mscratch` named. -/
def csrsH (ms : MStatus) (e c m cy : Word) (inh : MCountInhibit) (sc : Word) : PrivCSRs :=
  { mstatus := ms, mtvec := 0x80000114#32, mscratch := sc, mepc := e, mcause := c,
    pmpcfg0 := 0x1f#32, pmpaddr0 := 0x20005fff#32, pmpaddr1 := 0#32, pmpaddr2 := 0#32,
    pmpaddr3 := 0#32, mcountinhibit := inh, minstret := m, mcycle := cy }

/-- A CSR file whose fixed fields are the monitor's is `csrsH` of its free fields. -/
theorem csrs_eq_csrsH (c : PrivCSRs) (h1 : c.mtvec = 0x80000114#32) (h2 : c.mscratch = 0x80008000#32)
    (h4 : c.pmpcfg0 = 0x1f#32) (h5 : c.pmpaddr0 = 0x20005fff#32)
    (h6 : c.pmpaddr1 = 0#32) (h7 : c.pmpaddr2 = 0#32) (h8 : c.pmpaddr3 = 0#32)
    (h9 : c.mcountinhibit = {}) :
    c = csrsH c.mstatus c.mepc c.mcause c.minstret c.mcycle {} 0x80008000#32 := by
  cases c
  simp_all [csrsH]

/-- `f` with the registers in `l` replaced. -/
def regsUpd (f : Reg → Word) (l : List (Nat × Word)) : Reg → Word := fun r =>
  match l.find? (fun p => p.1 == r.toNat) with
  | some p => p.2
  | none => f r

/-- The region Tier 1 lets M-mode code touch: monitor, payload, and the MMIO words. -/
def monRegion : Rv32.Region := ⟨0x80000000, 0xC0000100⟩

/-- With the PMP boot set, M-mode code outside the payload region is never refused. -/
theorem pmpCheck_mon (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (h0 : csrs.pmpcfg0 = 0x1f#32) (h1 : csrs.pmpaddr0 = 0x20005fff#32)
    (hout : addr.toNat + width ≤ 0x80010000 ∨ 0x80020000 ≤ addr.toNat) :
    pmpCheck csrs .M addr width acc = true := by
  apply pmpCheck_M_outside csrs 0x80010000 0x80020000 addr width acc _ hout
  unfold PmpFence
  rw [h0, h1]
  decide

/-- The common hypotheses of a handler step: loaded words, the region, not halted, M-mode. -/
structure HState (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine) : Prop where
  words : WordsAt M0 0x80000000#32 monitorCode
  agree : Agree M0 s.core.mem 0x80000000 572
  region : env.region = monRegion
  notHalted : s.halted = false
  mMode : s.mode = .M

/-! ## Boot, first half: configure the PMP, the trap vector, the stack and `mret` target -/

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_boot_config (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) :
    (PrivMachine.run env 20 s).core.pc = 0x80000090#32 ∧
    (PrivMachine.run env 20 s).core.mem = M0 ∧
    (PrivMachine.run env 20 s).halted = false ∧
    (PrivMachine.run env 20 s).mode = .M ∧
    (PrivMachine.run env 20 s).csrs = csrsConfigured := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 20 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs] at hF
  subst hF
  psimp [hpc, hmem, csrsConfigured]

/-! ## Boot, second half: clear every register, set `sp`, drop to U-mode -/

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_launch_1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000090#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) (hC : Cleared 0 s) :
    (PrivMachine.run env 12 s).core.pc = 0x800000c0#32 ∧
    (PrivMachine.run env 12 s).core.mem = M0 ∧
    (PrivMachine.run env 12 s).halted = false ∧
    (PrivMachine.run env 12 s).mode = .M ∧
    (PrivMachine.run env 12 s).csrs = csrsConfigured ∧
    Cleared 12 (PrivMachine.run env 12 s) := by
  have sm := sm_mon env M0 hW
  unfold Cleared at hC
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 12 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimp [hpc, hmem, csrsConfigured]
  all_goals try (intro r hr
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> first | (exfalso; revert hr; decide) | psimp [hC, hr])

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_launch_2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x800000c0#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) (hC : Cleared 12 s) :
    (PrivMachine.run env 12 s).core.pc = 0x800000f0#32 ∧
    (PrivMachine.run env 12 s).core.mem = M0 ∧
    (PrivMachine.run env 12 s).halted = false ∧
    (PrivMachine.run env 12 s).mode = .M ∧
    (PrivMachine.run env 12 s).csrs = csrsConfigured ∧
    Cleared 24 (PrivMachine.run env 12 s) := by
  have sm := sm_mon env M0 hW
  unfold Cleared at hC
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 12 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimp [hpc, hmem, csrsConfigured]
  all_goals try (intro r hr
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> first | (exfalso; revert hr; decide) | psimp [hC, hr])

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_launch_3 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x800000f0#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) (hC : Cleared 24 s) :
    (PrivMachine.run env 7 s).core.pc = 0x8000010c#32 ∧
    (PrivMachine.run env 7 s).core.mem = M0 ∧
    (PrivMachine.run env 7 s).halted = false ∧
    (PrivMachine.run env 7 s).mode = .M ∧
    (PrivMachine.run env 7 s).csrs = csrsConfigured ∧
    Cleared 31 (PrivMachine.run env 7 s) := by
  have sm := sm_mon env M0 hW
  unfold Cleared at hC
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 7 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimp [hpc, hmem, csrsConfigured]
  all_goals try (intro r hr
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> first | (exfalso; revert hr; decide) | psimp [hC, hr])

/-- After `csrwi mcountinhibit, 0`: the counters run again, and have counted that one. -/
def csrsReady : PrivCSRs := { csrsConfigured with mcountinhibit := {}, minstret := 1#32, mcycle := 1#32 }

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_launch_4 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x8000010c#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) :
    (PrivMachine.run env 1 s).core.pc = 0x80000110#32 ∧
    (PrivMachine.run env 1 s).core.mem = M0 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsReady ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = s.core.reg r) := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  psimp [hpc, hmem, csrsConfigured, csrsReady]

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem monitor_launch_5 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000110#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsReady) :
    (PrivMachine.run env 1 s).core.pc = 0x80010000#32 ∧
    (PrivMachine.run env 1 s).core.mem = M0 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .U ∧
    (PrivMachine.run env 1 s).csrs.pmpcfg0 = 0x1f#32 ∧
    (PrivMachine.run env 1 s).csrs.pmpaddr0 = 0x20005fff#32 ∧
    (PrivMachine.run env 1 s).csrs.pmpaddr1 = 0#32 ∧
    (PrivMachine.run env 1 s).csrs.pmpaddr2 = 0#32 ∧
    (PrivMachine.run env 1 s).csrs.pmpaddr3 = 0#32 ∧
    (PrivMachine.run env 1 s).csrs.mtvec = 0x80000114#32 ∧
    (PrivMachine.run env 1 s).csrs.mscratch = 0x80008000#32 ∧
    (PrivMachine.run env 1 s).csrs.mcountinhibit = {} ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = s.core.reg r) := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsReady, csrsConfigured] at hF
  subst hF
  psimp [hpc, hmem, csrsConfigured, csrsReady]

/-- From reset (the image loaded at `0x80000000`, `pc = 0x80000040`, M-mode, CSRs at their reset
    values, any registers), 53 steps leave the machine in U-mode at the payload's first word,
    the PMP fencing off `[0x80010000, 0x80020000)`, every register zero but `sp`. -/
theorem monitor_boot (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) :
    UBoxed (PrivMachine.run env 53 s) 0x80010000 0x80020000 ∧
    (PrivMachine.run env 53 s).core.pc = 0x80010000#32 ∧
    (∃ ms e c m cy, (PrivMachine.run env 53 s).csrs = csrsH ms e c m cy {} 0x80008000#32) ∧
    (PrivMachine.run env 53 s).core.mem = M0 ∧
    (∀ r, (PrivMachine.run env 53 s).core.reg r = if r = 2 then 0x80020000#32 else 0#32) := by
  obtain ⟨c1, c2, c3, c4, c5⟩ := monitor_boot_config env M0 s hW hmem hpc hh hm hcs
  have hC0 : Cleared 0 (PrivMachine.run env 20 s) := by
    intro r hr
    have : r = 0 := by bv_omega
    subst this
    simp
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := monitor_launch_1 env M0 _ hW c2 c1 c3 c4 c5 hC0
  obtain ⟨b1, b2, b3, b4, b5, b6⟩ := monitor_launch_2 env M0 _ hW a2 a1 a3 a4 a5 a6
  obtain ⟨e1, e2, e3, e4, e5, e6⟩ := monitor_launch_3 env M0 _ hW b2 b1 b3 b4 b5 b6
  obtain ⟨g1, g2, g3, g4, g5, g6⟩ := monitor_launch_4 env M0 _ hW e2 e1 e3 e4 e5
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13⟩ :=
    monitor_launch_5 env M0 _ hW g2 g1 g3 g4 g5
  rw [show 53 = 20 + 12 + 12 + 7 + 1 + 1 from rfl, PrivMachine.run_add, PrivMachine.run_add,
    PrivMachine.run_add, PrivMachine.run_add, PrivMachine.run_add]
  refine ⟨⟨h4, h3, ?_, ?_, ?_, ?_, ?_, ?_⟩, h1, ⟨_, _, _, _, _, csrs_eq_csrsH _ h10 h11 h5 h6 h7 h8 h9 h12⟩, h2, ?_⟩
  · simp [h5, decodePmpCfgByte]
  · simp [h5, decodePmpCfgByte]
  · simp [h5, decodePmpCfgByte]
  · simp [h5, decodePmpCfgByte]
  · simp [h6, decodeNapotRange, countTrailingOnes32, countTrailingOnes32.loop]
  · intro ⟨i, hi⟩ h
    match i, hi, h with
    | 1, _, _ => simp [h5, decodePmpCfgByte]
    | 2, _, _ => simp [h5, decodePmpCfgByte]
    | 3, _, _ => simp [h5, decodePmpCfgByte]
  · intro r
    rw [h13 r, g6 r]
    exact e6 r (by have h := r.isLt; omega)

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Trap entry, first three words: freeze the counters, swap in the M-mode stack, save `t0`. -/
theorem handler_e1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} (0x80008000#32)) :
    (PrivMachine.run env 3 s).core.pc = 0x80000120#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (s.core.reg 2#5) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(2, 0x80008000#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Save `t1` above it. -/
theorem handler_e2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000120#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hsp : s.core.reg 2#5 = 0x80008000#32) :
    (PrivMachine.run env 1 s).core.pc = 0x80000124#32 ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008004#32 4 = (s.core.reg 6#5).toNat % 4294967296 ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hsp] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hsp]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hsp])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Read `mcause`; an `ecall` goes to the syscall check. -/
theorem handler_e3_ecall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000124#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hc : c = 8#32) :
    (PrivMachine.run env 3 s).core.pc = 0x8000016c#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(5, c), (6, 8#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hc] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hc]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hc])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Read `mcause`; anything else goes to the fault report. -/
theorem handler_e3_other (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000124#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hc : c ≠ 8#32) :
    (PrivMachine.run env 3 s).core.pc = 0x80000130#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(5, c), (6, 8#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hc] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hc]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hc])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- The syscall check: the saved `t0` is 1, so it is HALT. -/
theorem handler_c_halt (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word) (k : Nat)
    (hpc : s.core.pc = 0x8000016c#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hsp : s.core.reg 2#5 = 0x80008000#32)
    (hk : readLE s.core.mem 0x80008000#32 4 = k) (hk1 : BitVec.ofNat 32 k = 1#32) :
    (PrivMachine.run env 3 s).core.pc = 0x80000178#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(5, BitVec.ofNat 32 k), (6, 1#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  rw [hmem] at hk
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hsp, hk, hk1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hsp, hk, hk1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hsp, hk, hk1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- The syscall check: the saved `t0` is not 1, so it is a bad call. -/
theorem handler_c_bad (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word) (k : Nat)
    (hpc : s.core.pc = 0x8000016c#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hsp : s.core.reg 2#5 = 0x80008000#32)
    (hk : readLE s.core.mem 0x80008000#32 4 = k) (hk1 : BitVec.ofNat 32 k ≠ 1#32) :
    (PrivMachine.run env 3 s).core.pc = 0x80000130#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(5, BitVec.ofNat 32 k), (6, 1#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  rw [hmem] at hk
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hsp, hk, hk1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hsp, hk, hk1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hsp, hk, hk1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report HALT: address and tag. -/
theorem handler_h1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000178#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p)) :
    (PrivMachine.run env 5 s).core.pc = 0x8000018c#32 ∧
    Agree M0 (PrivMachine.run env 5 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 5 s).halted = false ∧
    (PrivMachine.run env 5 s).mode = .M ∧
    (PrivMachine.run env 5 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 5 s).host = s.host ∧
    (PrivMachine.run env 5 s).io = s.io ++ [⟨0xc0000004#32, 0x48414c54#32⟩] ∧
    readLE (PrivMachine.run env 5 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 5 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 5 s).core.reg r = regsUpd s.core.reg [(6, 0xc0000004#32), (5, 0x48414c54#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 5 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report the exit code. -/
theorem handler_h2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x8000018c#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 1 s).core.pc = 0x80000190#32 ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ++ [⟨0xc0000004#32, s.core.reg 10#5⟩] ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `minstret`. -/
theorem handler_h3 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000190#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x80000198#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, m⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, m)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `mcycle`. -/
theorem handler_h4 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000198#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x800001a0#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, cy⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, cy)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report FAULT: address and tag. -/
theorem handler_f1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000130#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p)) :
    (PrivMachine.run env 5 s).core.pc = 0x80000144#32 ∧
    Agree M0 (PrivMachine.run env 5 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 5 s).halted = false ∧
    (PrivMachine.run env 5 s).mode = .M ∧
    (PrivMachine.run env 5 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 5 s).host = s.host ∧
    (PrivMachine.run env 5 s).io = s.io ++ [⟨0xc0000004#32, 0x4641554c#32⟩] ∧
    readLE (PrivMachine.run env 5 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 5 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 5 s).core.reg r = regsUpd s.core.reg [(6, 0xc0000004#32), (5, 0x4641554c#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 5 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `mcause`. -/
theorem handler_f2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000144#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x8000014c#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, c⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, c)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `mepc`. -/
theorem handler_f3 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x8000014c#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x80000154#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, e⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, e)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `mtval`. -/
theorem handler_f4 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000154#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x8000015c#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, 0#32⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, 0#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Report `minstret`. -/
theorem handler_f5 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x8000015c#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht1 : s.core.reg 6#5 = 0xc0000004#32) :
    (PrivMachine.run env 2 s).core.pc = 0x80000164#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ++ [⟨0xc0000004#32, m⟩] ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(5, m)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, ht1] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, ht1]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, ht1])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Exit code 1, then the scrub. -/
theorem handler_f6 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x80000164#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p)) :
    (PrivMachine.run env 2 s).core.pc = 0x800001a0#32 ∧
    Agree M0 (PrivMachine.run env 2 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 2 s).halted = false ∧
    (PrivMachine.run env 2 s).mode = .M ∧
    (PrivMachine.run env 2 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 2 s).host = s.host ∧
    (PrivMachine.run env 2 s).io = s.io ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 2 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 2 s).core.reg r = regsUpd s.core.reg [(10, 1#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 2 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear the saved `t0`. -/
theorem scrub_s1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x800001a0#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hsp : s.core.reg 2#5 = 0x80008000#32) :
    (PrivMachine.run env 1 s).core.pc = 0x800001a4#32 ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hsp] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hsp]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hsp])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear the saved `t1`. -/
theorem scrub_s2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x800001a4#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (hsp : s.core.reg 2#5 = 0x80008000#32) :
    (PrivMachine.run env 1 s).core.pc = 0x800001a8#32 ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008004#32 4 = 0 ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured, hsp] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd, hsp]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd, hsp])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear `mscratch` (the payload's `sp`) and `x1..x9`. -/
theorem scrub_s3 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x800001a8#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p)) :
    (PrivMachine.run env 10 s).core.pc = 0x800001d0#32 ∧
    Agree M0 (PrivMachine.run env 10 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 10 s).halted = false ∧
    (PrivMachine.run env 10 s).mode = .M ∧
    (PrivMachine.run env 10 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 10 s).host = s.host ∧
    (PrivMachine.run env 10 s).io = s.io ∧
    readLE (PrivMachine.run env 10 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 10 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 10 s).core.reg r = regsUpd s.core.reg [(1, 0#32), (2, 0#32), (3, 0#32), (4, 0#32), (5, 0#32), (6, 0#32), (7, 0#32), (8, 0#32), (9, 0#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 10 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear `x11..x22`. -/
theorem scrub_s4 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x800001d0#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32)) :
    (PrivMachine.run env 12 s).core.pc = 0x80000200#32 ∧
    Agree M0 (PrivMachine.run env 12 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 12 s).halted = false ∧
    (PrivMachine.run env 12 s).mode = .M ∧
    (PrivMachine.run env 12 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 12 s).host = s.host ∧
    (PrivMachine.run env 12 s).io = s.io ∧
    readLE (PrivMachine.run env 12 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 12 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 12 s).core.reg r = regsUpd s.core.reg [(11, 0#32), (12, 0#32), (13, 0#32), (14, 0#32), (15, 0#32), (16, 0#32), (17, 0#32), (18, 0#32), (19, 0#32), (20, 0#32), (21, 0#32), (22, 0#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 12 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear `x23..x31`. -/
theorem scrub_s5 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000200#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32)) :
    (PrivMachine.run env 9 s).core.pc = 0x80000224#32 ∧
    Agree M0 (PrivMachine.run env 9 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 9 s).halted = false ∧
    (PrivMachine.run env 9 s).mode = .M ∧
    (PrivMachine.run env 9 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 9 s).host = s.host ∧
    (PrivMachine.run env 9 s).io = s.io ∧
    readLE (PrivMachine.run env 9 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 9 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 9 s).core.reg r = regsUpd s.core.reg [(23, 0#32), (24, 0#32), (25, 0#32), (26, 0#32), (27, 0#32), (28, 0#32), (29, 0#32), (30, 0#32), (31, 0#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 9 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Write the exit code. -/
theorem scrub_s6 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000224#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32)) :
    (PrivMachine.run env 3 s).core.pc = 0x80000230#32 ∧
    Agree M0 (PrivMachine.run env 3 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 3 s).halted = false ∧
    (PrivMachine.run env 3 s).mode = .M ∧
    (PrivMachine.run env 3 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 3 s).host = s.host ∧
    (PrivMachine.run env 3 s).io = s.io ++ [⟨0xc0000008#32, s.core.reg 10#5⟩] ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 3 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 3 s).core.reg r = regsUpd s.core.reg [(6, 0xc0000008#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 3 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- Clear `t1`. -/
theorem scrub_s7 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000230#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32)) :
    (PrivMachine.run env 1 s).core.pc = 0x80000234#32 ∧
    Agree M0 (PrivMachine.run env 1 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).io = s.io ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008000#32 4 = readLE s.core.mem 0x80008000#32 4 ∧
    readLE (PrivMachine.run env 1 s).core.mem 0x80008004#32 4 = readLE s.core.mem 0x80008004#32 4 ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = regsUpd s.core.reg [(6, 0#32)] r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 572 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, t.core.mem = Mc →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW (by rw [ht]; exact hA') h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH, csrsFixed, csrsConfigured] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, hA', agree_writeLE_iff, csrsH, csrsFixed, csrsConfigured, readLE_writeLE_self, readLE_writeLE_far, regsUpd]
  all_goals try (intro r
                 have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
                 rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> psimpH [pmpCheck_mon, regsUpd])


/-! ## The chunks, chained -/

theorem run_two {env : Rv32.Env} {n m : Nat} {s s1 s2 : PrivMachine}
    (h1 : PrivMachine.run env n s = s1) (h2 : PrivMachine.run env m s1 = s2) :
    PrivMachine.run env (n + m) s = s2 := by
  rw [PrivMachine.run_add, h1, h2]

/-- A register a chunk did not name is what it was. -/
theorem reg_keep {cur prev : Reg → Word} {l : List (Nat × Word)} {k : Reg} {v : Word}
    (hr : ∀ r, cur r = regsUpd prev l r) (hn : l.find? (fun p => p.1 == k.toNat) = none)
    (hv : prev k = v) : cur k = v := by
  rw [hr k]; simp [regsUpd, hn, hv]

/-- A register a chunk named is what it was told. -/
theorem reg_set {cur prev : Reg → Word} {l : List (Nat × Word)} {k : Reg} {v : Word}
    (hr : ∀ r, cur r = regsUpd prev l r) (hn : l.find? (fun p => p.1 == k.toNat) = some (k.toNat, v)) :
    cur k = v := by
  rw [hr k]; simp [regsUpd, hn]

/-- The state after a chunk is a handler state again. -/
theorem HState.next {env : Rv32.Env} {M0 : Word → Byte} {s t : PrivMachine} (hS : HState env M0 s)
    (ha : Agree M0 t.core.mem 0x80000000 572) (hh : t.halted = false) (hm : t.mode = .M) :
    HState env M0 t := ⟨hS.words, ha, hS.region, hh, hm⟩

/-- The scrub, all of it: from the first word of `scrub_exit`, with `sp` at the M-mode stack,
    every register but `a0` is zero, `mscratch` is zero, the two saved words are zero, and the
    machine stands at the park loop. -/
theorem monitor_scrub (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy p : Word)
    (hpc : s.core.pc = 0x800001a0#32)
    (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } p)
    (hsp : s.core.reg 2#5 = 0x80008000#32) :
    (PrivMachine.run env 37 s).core.pc = 0x80000234#32 ∧
    Agree M0 (PrivMachine.run env 37 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 37 s).halted = false ∧
    (PrivMachine.run env 37 s).mode = .M ∧
    (PrivMachine.run env 37 s).csrs.mscratch = 0#32 ∧
    readLE (PrivMachine.run env 37 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 37 s).core.mem 0x80008004#32 4 = 0 ∧
    (PrivMachine.run env 37 s).core.reg 10#5 = s.core.reg 10#5 ∧
    (∀ r, r ≠ 10#5 → (PrivMachine.run env 37 s).core.reg r = 0#32) ∧
    (PrivMachine.run env 37 s).host = s.host ∧
    (PrivMachine.run env 37 s).io = s.io ++ [⟨0xc0000008#32, s.core.reg 10#5⟩] := by
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 1 s = t := ⟨_, rfl⟩
  obtain ⟨p1, a1, h1, m1, c1, o1, i1, x1, y1, r1⟩ := scrub_s1 env M0 s hS ms e c m cy p hpc hcs hsp
  rw [hs1] at p1 a1 h1 m1 c1 o1 i1 x1 y1 r1
  have hS1 := hS.next a1 h1 m1
  have sp1 : s1.core.reg 2#5 = 0x80008000#32 := reg_keep r1 (by decide) hsp
  obtain ⟨s2, hs2⟩ : ∃ t, PrivMachine.run env 1 s1 = t := ⟨_, rfl⟩
  obtain ⟨p2, a2, h2, m2, c2, o2, i2, x2, y2, r2⟩ := scrub_s2 env M0 s1 hS1 ms e c m cy p p1 c1 sp1
  rw [hs2] at p2 a2 h2 m2 c2 o2 i2 x2 y2 r2
  have hS2 := hS1.next a2 h2 m2
  obtain ⟨s3, hs3⟩ : ∃ t, PrivMachine.run env 10 s2 = t := ⟨_, rfl⟩
  obtain ⟨p3, a3, h3, m3, c3, o3, i3, x3, y3, r3⟩ := scrub_s3 env M0 s2 hS2 ms e c m cy p p2 c2
  rw [hs3] at p3 a3 h3 m3 c3 o3 i3 x3 y3 r3
  have hS3 := hS2.next a3 h3 m3
  obtain ⟨s4, hs4⟩ : ∃ t, PrivMachine.run env 12 s3 = t := ⟨_, rfl⟩
  obtain ⟨p4, a4, h4, m4, c4, o4, i4, x4, y4, r4⟩ := scrub_s4 env M0 s3 hS3 ms e c m cy p3 c3
  rw [hs4] at p4 a4 h4 m4 c4 o4 i4 x4 y4 r4
  have hS4 := hS3.next a4 h4 m4
  obtain ⟨s5, hs5⟩ : ∃ t, PrivMachine.run env 9 s4 = t := ⟨_, rfl⟩
  obtain ⟨p5, a5, h5, m5, c5, o5, i5, x5, y5, r5⟩ := scrub_s5 env M0 s4 hS4 ms e c m cy p4 c4
  rw [hs5] at p5 a5 h5 m5 c5 o5 i5 x5 y5 r5
  have hS5 := hS4.next a5 h5 m5
  obtain ⟨s6, hs6⟩ : ∃ t, PrivMachine.run env 3 s5 = t := ⟨_, rfl⟩
  obtain ⟨p6, a6, h6, m6, c6, o6, i6, x6, y6, r6⟩ := scrub_s6 env M0 s5 hS5 ms e c m cy p5 c5
  rw [hs6] at p6 a6 h6 m6 c6 o6 i6 x6 y6 r6
  have hS6 := hS5.next a6 h6 m6
  obtain ⟨s7, hs7⟩ : ∃ t, PrivMachine.run env 1 s6 = t := ⟨_, rfl⟩
  obtain ⟨p7, a7, h7, m7, c7, o7, i7, x7, y7, r7⟩ := scrub_s7 env M0 s6 hS6 ms e c m cy p6 c6
  rw [hs7] at p7 a7 h7 m7 c7 o7 i7 x7 y7 r7
  have hall : PrivMachine.run env 37 s = s7 :=
    run_two hs1 (run_two hs2 (run_two hs3 (run_two hs4 (run_two hs5 (run_two hs6 hs7)))))
  rw [hall]
  refine ⟨p7, a7, h7, m7, ?_, ?_, ?_, ?_, ?_, by rw [o7, o6, o5, o4, o3, o2, o1], ?_⟩
  · rw [c7]; rfl
  · rw [x7, x6, x5, x4, x3, x2, x1]
  · rw [y7, y6, y5, y4, y3, y2]
  · have k1 : s1.core.reg 10#5 = s.core.reg 10#5 := reg_keep r1 (by decide) rfl
    have k2 : s2.core.reg 10#5 = s.core.reg 10#5 := reg_keep r2 (by decide) k1
    have k3 : s3.core.reg 10#5 = s.core.reg 10#5 := reg_keep r3 (by decide) k2
    have k4 : s4.core.reg 10#5 = s.core.reg 10#5 := reg_keep r4 (by decide) k3
    have k5 : s5.core.reg 10#5 = s.core.reg 10#5 := reg_keep r5 (by decide) k4
    have k6 : s6.core.reg 10#5 = s.core.reg 10#5 := reg_keep r6 (by decide) k5
    exact reg_keep r7 (by decide) k6
  · intro r hr
    have hr32 : r = 0#5 ∨ r = 1#5 ∨ r = 2#5 ∨ r = 3#5 ∨ r = 4#5 ∨ r = 5#5 ∨ r = 6#5 ∨ r = 7#5 ∨ r = 8#5 ∨ r = 9#5 ∨ r = 10#5 ∨ r = 11#5 ∨ r = 12#5 ∨ r = 13#5 ∨ r = 14#5 ∨ r = 15#5 ∨ r = 16#5 ∨ r = 17#5 ∨ r = 18#5 ∨ r = 19#5 ∨ r = 20#5 ∨ r = 21#5 ∨ r = 22#5 ∨ r = 23#5 ∨ r = 24#5 ∨ r = 25#5 ∨ r = 26#5 ∨ r = 27#5 ∨ r = 28#5 ∨ r = 29#5 ∨ r = 30#5 ∨ r = 31#5 := by bv_omega
    rcases hr32 with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> first | (exfalso; exact hr rfl) | simp [r7, r6, r5, r4, r3, r2, r1, regsUpd]
  · rw [i7, i6, i5, i4, i3, i2, i1]
    simp [r5, r4, r3, r2, r1, regsUpd]

theorem ofNat_toNat_mod (x : Word) : BitVec.ofNat 32 (x.toNat % 4294967296) = x := by
  apply BitVec.eq_of_toNat_eq
  have := x.isLt
  simp only [BitVec.toNat_ofNat, Nat.reducePow]
  omega

set_option maxHeartbeats 4000000 in
/-- A payload `ecall` with `t0 = 1`: from the trap vector, the machine parks with the payload's `a0` and every other register zero. -/
theorem monitor_halt (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hc : c = 8#32) (ht0 : s.core.reg 5#5 = 1#32) :
    (PrivMachine.run env 57 s).core.pc = 0x80000234#32 ∧
    Agree M0 (PrivMachine.run env 57 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 57 s).halted = false ∧
    (PrivMachine.run env 57 s).mode = .M ∧
    (PrivMachine.run env 57 s).csrs.mscratch = 0#32 ∧
    readLE (PrivMachine.run env 57 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 57 s).core.mem 0x80008004#32 4 = 0 ∧
    (PrivMachine.run env 57 s).core.reg 10#5 = s.core.reg 10#5 ∧
    (∀ r, r ≠ 10#5 → (PrivMachine.run env 57 s).core.reg r = 0#32) ∧
    (PrivMachine.run env 57 s).host = s.host ∧
    (PrivMachine.run env 57 s).io = s.io ++ [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, s.core.reg 10#5⟩, ⟨0xc0000004#32, m⟩, ⟨0xc0000004#32, cy⟩, ⟨0xc0000008#32, s.core.reg 10#5⟩] := by

  have p0 := hpc
  have c0 := hcs
  have hS0 := hS
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 3 s = t := ⟨_, rfl⟩
  obtain ⟨p1, a1, h1, m1, c1, o1, i1, x1, y1, r1⟩ := handler_e1 env M0 s hS0 ms e c m cy p0 c0
  rw [hs1] at p1 a1 h1 m1 c1 o1 i1 x1 y1 r1
  have hS1 := hS0.next a1 h1 m1
  have sp1 : s1.core.reg 2#5 = 0x80008000#32 := reg_set r1 (by simp)
  obtain ⟨s2, hs2⟩ : ∃ t, PrivMachine.run env 1 s1 = t := ⟨_, rfl⟩
  obtain ⟨p2, a2, h2, m2, c2, o2, i2, x2, y2, r2⟩ := handler_e2 env M0 s1 hS1 ms e c m cy (s.core.reg 2#5) p1 c1 sp1
  rw [hs2] at p2 a2 h2 m2 c2 o2 i2 x2 y2 r2
  have hS2 := hS1.next a2 h2 m2
  have sp2 : s2.core.reg 2#5 = 0x80008000#32 := reg_keep r2 (by simp) sp1
  obtain ⟨s3, hs3⟩ : ∃ t, PrivMachine.run env 3 s2 = t := ⟨_, rfl⟩
  obtain ⟨p3, a3, h3, m3, c3, o3, i3, x3, y3, r3⟩ := handler_e3_ecall env M0 s2 hS2 ms e c m cy (s.core.reg 2#5) p2 c2 hc
  rw [hs3] at p3 a3 h3 m3 c3 o3 i3 x3 y3 r3
  have hS3 := hS2.next a3 h3 m3
  have sp3 : s3.core.reg 2#5 = 0x80008000#32 := reg_keep r3 (by simp) sp2
  have hk4 : readLE s3.core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 := by rw [x3, x2, x1]
  have hk14 : BitVec.ofNat 32 ((s.core.reg 5#5).toNat % 4294967296) = 1#32 := by rw [ofNat_toNat_mod]; exact ht0
  obtain ⟨s4, hs4⟩ : ∃ t, PrivMachine.run env 3 s3 = t := ⟨_, rfl⟩
  obtain ⟨p4, a4, h4, m4, c4, o4, i4, x4, y4, r4⟩ := handler_c_halt env M0 s3 hS3 ms e c m cy (s.core.reg 2#5) ((s.core.reg 5#5).toNat % 4294967296) p3 c3 sp3 (hk4) (hk14)
  rw [hs4] at p4 a4 h4 m4 c4 o4 i4 x4 y4 r4
  have hS4 := hS3.next a4 h4 m4
  have sp4 : s4.core.reg 2#5 = 0x80008000#32 := reg_keep r4 (by simp) sp3
  obtain ⟨s5, hs5⟩ : ∃ t, PrivMachine.run env 5 s4 = t := ⟨_, rfl⟩
  obtain ⟨p5, a5, h5, m5, c5, o5, i5, x5, y5, r5⟩ := handler_h1 env M0 s4 hS4 ms e c m cy (s.core.reg 2#5) p4 c4
  rw [hs5] at p5 a5 h5 m5 c5 o5 i5 x5 y5 r5
  have hS5 := hS4.next a5 h5 m5
  have sp5 : s5.core.reg 2#5 = 0x80008000#32 := reg_keep r5 (by simp) sp4
  have t5 : s5.core.reg 6#5 = 0xc0000004#32 := reg_set r5 (by simp)
  obtain ⟨s6, hs6⟩ : ∃ t, PrivMachine.run env 1 s5 = t := ⟨_, rfl⟩
  obtain ⟨p6, a6, h6, m6, c6, o6, i6, x6, y6, r6⟩ := handler_h2 env M0 s5 hS5 ms e c m cy (s.core.reg 2#5) p5 c5 t5
  rw [hs6] at p6 a6 h6 m6 c6 o6 i6 x6 y6 r6
  have hS6 := hS5.next a6 h6 m6
  have sp6 : s6.core.reg 2#5 = 0x80008000#32 := reg_keep r6 (by simp) sp5
  have t6 : s6.core.reg 6#5 = 0xc0000004#32 := reg_keep r6 (by simp) t5
  obtain ⟨s7, hs7⟩ : ∃ t, PrivMachine.run env 2 s6 = t := ⟨_, rfl⟩
  obtain ⟨p7, a7, h7, m7, c7, o7, i7, x7, y7, r7⟩ := handler_h3 env M0 s6 hS6 ms e c m cy (s.core.reg 2#5) p6 c6 t6
  rw [hs7] at p7 a7 h7 m7 c7 o7 i7 x7 y7 r7
  have hS7 := hS6.next a7 h7 m7
  have sp7 : s7.core.reg 2#5 = 0x80008000#32 := reg_keep r7 (by simp) sp6
  have t7 : s7.core.reg 6#5 = 0xc0000004#32 := reg_keep r7 (by simp) t6
  obtain ⟨s8, hs8⟩ : ∃ t, PrivMachine.run env 2 s7 = t := ⟨_, rfl⟩
  obtain ⟨p8, a8, h8, m8, c8, o8, i8, x8, y8, r8⟩ := handler_h4 env M0 s7 hS7 ms e c m cy (s.core.reg 2#5) p7 c7 t7
  rw [hs8] at p8 a8 h8 m8 c8 o8 i8 x8 y8 r8
  have hS8 := hS7.next a8 h8 m8
  have sp8 : s8.core.reg 2#5 = 0x80008000#32 := reg_keep r8 (by simp) sp7
  have t8 : s8.core.reg 6#5 = 0xc0000004#32 := reg_keep r8 (by simp) t7
  have hall : PrivMachine.run env 20 s = s8 := run_two hs1 (run_two hs2 (run_two hs3 (run_two hs4 (run_two hs5 (run_two hs6 (run_two hs7 (hs8)))))))
  obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, qh, qi⟩ := monitor_scrub env M0 s8 hS8 ms e c m cy (s.core.reg 2#5) p8 c8 sp8
  rw [show 57 = 20 + 37 from rfl, PrivMachine.run_add, hall]
  refine ⟨q1, q2, q3, q4, q5, q6, q7, ?_, q9, by rw [qh, o8, o7, o6, o5, o4, o3, o2, o1], ?_⟩
  rotate_left
  · rw [qi, i8, i7, i6, i5, i4, i3, i2, i1]
    simp [r8, r7, r6, r5, r4, r3, r2, r1, regsUpd, List.append_assoc]
  rw [q8]
  have k1 : s1.core.reg 10#5 = s.core.reg 10#5 := reg_keep r1 (by simp) rfl
  have k2 : s2.core.reg 10#5 = s.core.reg 10#5 := reg_keep r2 (by simp) k1
  have k3 : s3.core.reg 10#5 = s.core.reg 10#5 := reg_keep r3 (by simp) k2
  have k4 : s4.core.reg 10#5 = s.core.reg 10#5 := reg_keep r4 (by simp) k3
  have k5 : s5.core.reg 10#5 = s.core.reg 10#5 := reg_keep r5 (by simp) k4
  have k6 : s6.core.reg 10#5 = s.core.reg 10#5 := reg_keep r6 (by simp) k5
  have k7 : s7.core.reg 10#5 = s.core.reg 10#5 := reg_keep r7 (by simp) k6
  have k8 : s8.core.reg 10#5 = s.core.reg 10#5 := reg_keep r8 (by simp) k7
  exact k8

set_option maxHeartbeats 4000000 in
/-- A trap that is not an `ecall`: from the trap vector, the machine parks with `a0 = 1` and every other register zero. -/
theorem monitor_fault_cause (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hc : c ≠ 8#32) :
    (PrivMachine.run env 59 s).core.pc = 0x80000234#32 ∧
    Agree M0 (PrivMachine.run env 59 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 59 s).halted = false ∧
    (PrivMachine.run env 59 s).mode = .M ∧
    (PrivMachine.run env 59 s).csrs.mscratch = 0#32 ∧
    readLE (PrivMachine.run env 59 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 59 s).core.mem 0x80008004#32 4 = 0 ∧
    (PrivMachine.run env 59 s).core.reg 10#5 = 1#32 ∧
    (∀ r, r ≠ 10#5 → (PrivMachine.run env 59 s).core.reg r = 0#32) ∧
    (PrivMachine.run env 59 s).host = s.host ∧
    (PrivMachine.run env 59 s).io = s.io ++ [⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, c⟩, ⟨0xc0000004#32, e⟩, ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, m⟩, ⟨0xc0000008#32, 1#32⟩] := by

  have p0 := hpc
  have c0 := hcs
  have hS0 := hS
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 3 s = t := ⟨_, rfl⟩
  obtain ⟨p1, a1, h1, m1, c1, o1, i1, x1, y1, r1⟩ := handler_e1 env M0 s hS0 ms e c m cy p0 c0
  rw [hs1] at p1 a1 h1 m1 c1 o1 i1 x1 y1 r1
  have hS1 := hS0.next a1 h1 m1
  have sp1 : s1.core.reg 2#5 = 0x80008000#32 := reg_set r1 (by simp)
  obtain ⟨s2, hs2⟩ : ∃ t, PrivMachine.run env 1 s1 = t := ⟨_, rfl⟩
  obtain ⟨p2, a2, h2, m2, c2, o2, i2, x2, y2, r2⟩ := handler_e2 env M0 s1 hS1 ms e c m cy (s.core.reg 2#5) p1 c1 sp1
  rw [hs2] at p2 a2 h2 m2 c2 o2 i2 x2 y2 r2
  have hS2 := hS1.next a2 h2 m2
  have sp2 : s2.core.reg 2#5 = 0x80008000#32 := reg_keep r2 (by simp) sp1
  obtain ⟨s3, hs3⟩ : ∃ t, PrivMachine.run env 3 s2 = t := ⟨_, rfl⟩
  obtain ⟨p3, a3, h3, m3, c3, o3, i3, x3, y3, r3⟩ := handler_e3_other env M0 s2 hS2 ms e c m cy (s.core.reg 2#5) p2 c2 hc
  rw [hs3] at p3 a3 h3 m3 c3 o3 i3 x3 y3 r3
  have hS3 := hS2.next a3 h3 m3
  have sp3 : s3.core.reg 2#5 = 0x80008000#32 := reg_keep r3 (by simp) sp2
  obtain ⟨s4, hs4⟩ : ∃ t, PrivMachine.run env 5 s3 = t := ⟨_, rfl⟩
  obtain ⟨p4, a4, h4, m4, c4, o4, i4, x4, y4, r4⟩ := handler_f1 env M0 s3 hS3 ms e c m cy (s.core.reg 2#5) p3 c3
  rw [hs4] at p4 a4 h4 m4 c4 o4 i4 x4 y4 r4
  have hS4 := hS3.next a4 h4 m4
  have sp4 : s4.core.reg 2#5 = 0x80008000#32 := reg_keep r4 (by simp) sp3
  have t4 : s4.core.reg 6#5 = 0xc0000004#32 := reg_set r4 (by simp)
  obtain ⟨s5, hs5⟩ : ∃ t, PrivMachine.run env 2 s4 = t := ⟨_, rfl⟩
  obtain ⟨p5, a5, h5, m5, c5, o5, i5, x5, y5, r5⟩ := handler_f2 env M0 s4 hS4 ms e c m cy (s.core.reg 2#5) p4 c4 t4
  rw [hs5] at p5 a5 h5 m5 c5 o5 i5 x5 y5 r5
  have hS5 := hS4.next a5 h5 m5
  have sp5 : s5.core.reg 2#5 = 0x80008000#32 := reg_keep r5 (by simp) sp4
  have t5 : s5.core.reg 6#5 = 0xc0000004#32 := reg_keep r5 (by simp) t4
  obtain ⟨s6, hs6⟩ : ∃ t, PrivMachine.run env 2 s5 = t := ⟨_, rfl⟩
  obtain ⟨p6, a6, h6, m6, c6, o6, i6, x6, y6, r6⟩ := handler_f3 env M0 s5 hS5 ms e c m cy (s.core.reg 2#5) p5 c5 t5
  rw [hs6] at p6 a6 h6 m6 c6 o6 i6 x6 y6 r6
  have hS6 := hS5.next a6 h6 m6
  have sp6 : s6.core.reg 2#5 = 0x80008000#32 := reg_keep r6 (by simp) sp5
  have t6 : s6.core.reg 6#5 = 0xc0000004#32 := reg_keep r6 (by simp) t5
  obtain ⟨s7, hs7⟩ : ∃ t, PrivMachine.run env 2 s6 = t := ⟨_, rfl⟩
  obtain ⟨p7, a7, h7, m7, c7, o7, i7, x7, y7, r7⟩ := handler_f4 env M0 s6 hS6 ms e c m cy (s.core.reg 2#5) p6 c6 t6
  rw [hs7] at p7 a7 h7 m7 c7 o7 i7 x7 y7 r7
  have hS7 := hS6.next a7 h7 m7
  have sp7 : s7.core.reg 2#5 = 0x80008000#32 := reg_keep r7 (by simp) sp6
  have t7 : s7.core.reg 6#5 = 0xc0000004#32 := reg_keep r7 (by simp) t6
  obtain ⟨s8, hs8⟩ : ∃ t, PrivMachine.run env 2 s7 = t := ⟨_, rfl⟩
  obtain ⟨p8, a8, h8, m8, c8, o8, i8, x8, y8, r8⟩ := handler_f5 env M0 s7 hS7 ms e c m cy (s.core.reg 2#5) p7 c7 t7
  rw [hs8] at p8 a8 h8 m8 c8 o8 i8 x8 y8 r8
  have hS8 := hS7.next a8 h8 m8
  have sp8 : s8.core.reg 2#5 = 0x80008000#32 := reg_keep r8 (by simp) sp7
  have t8 : s8.core.reg 6#5 = 0xc0000004#32 := reg_keep r8 (by simp) t7
  obtain ⟨s9, hs9⟩ : ∃ t, PrivMachine.run env 2 s8 = t := ⟨_, rfl⟩
  obtain ⟨p9, a9, h9, m9, c9, o9, i9, x9, y9, r9⟩ := handler_f6 env M0 s8 hS8 ms e c m cy (s.core.reg 2#5) p8 c8
  rw [hs9] at p9 a9 h9 m9 c9 o9 i9 x9 y9 r9
  have hS9 := hS8.next a9 h9 m9
  have sp9 : s9.core.reg 2#5 = 0x80008000#32 := reg_keep r9 (by simp) sp8
  have hall : PrivMachine.run env 22 s = s9 := run_two hs1 (run_two hs2 (run_two hs3 (run_two hs4 (run_two hs5 (run_two hs6 (run_two hs7 (run_two hs8 (hs9))))))))
  obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, qh, qi⟩ := monitor_scrub env M0 s9 hS9 ms e c m cy (s.core.reg 2#5) p9 c9 sp9
  rw [show 59 = 22 + 37 from rfl, PrivMachine.run_add, hall]
  refine ⟨q1, q2, q3, q4, q5, q6, q7, ?_, q9, by rw [qh, o9, o8, o7, o6, o5, o4, o3, o2, o1], ?_⟩
  rotate_left
  · rw [qi, i9, i8, i7, i6, i5, i4, i3, i2, i1]
    simp [r9, r8, r7, r6, r5, r4, r3, r2, r1, regsUpd, List.append_assoc]
  rw [q8]
  exact reg_set r9 (by simp)

set_option maxHeartbeats 4000000 in
/-- An `ecall` with `t0 ≠ 1`: from the trap vector, the machine parks with `a0 = 1` and every other register zero. -/
theorem monitor_fault_syscall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hc : c = 8#32) (ht0 : s.core.reg 5#5 ≠ 1#32) :
    (PrivMachine.run env 62 s).core.pc = 0x80000234#32 ∧
    Agree M0 (PrivMachine.run env 62 s).core.mem 0x80000000 572 ∧
    (PrivMachine.run env 62 s).halted = false ∧
    (PrivMachine.run env 62 s).mode = .M ∧
    (PrivMachine.run env 62 s).csrs.mscratch = 0#32 ∧
    readLE (PrivMachine.run env 62 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 62 s).core.mem 0x80008004#32 4 = 0 ∧
    (PrivMachine.run env 62 s).core.reg 10#5 = 1#32 ∧
    (∀ r, r ≠ 10#5 → (PrivMachine.run env 62 s).core.reg r = 0#32) ∧
    (PrivMachine.run env 62 s).host = s.host ∧
    (PrivMachine.run env 62 s).io = s.io ++ [⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, c⟩, ⟨0xc0000004#32, e⟩, ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, m⟩, ⟨0xc0000008#32, 1#32⟩] := by

  have p0 := hpc
  have c0 := hcs
  have hS0 := hS
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 3 s = t := ⟨_, rfl⟩
  obtain ⟨p1, a1, h1, m1, c1, o1, i1, x1, y1, r1⟩ := handler_e1 env M0 s hS0 ms e c m cy p0 c0
  rw [hs1] at p1 a1 h1 m1 c1 o1 i1 x1 y1 r1
  have hS1 := hS0.next a1 h1 m1
  have sp1 : s1.core.reg 2#5 = 0x80008000#32 := reg_set r1 (by simp)
  obtain ⟨s2, hs2⟩ : ∃ t, PrivMachine.run env 1 s1 = t := ⟨_, rfl⟩
  obtain ⟨p2, a2, h2, m2, c2, o2, i2, x2, y2, r2⟩ := handler_e2 env M0 s1 hS1 ms e c m cy (s.core.reg 2#5) p1 c1 sp1
  rw [hs2] at p2 a2 h2 m2 c2 o2 i2 x2 y2 r2
  have hS2 := hS1.next a2 h2 m2
  have sp2 : s2.core.reg 2#5 = 0x80008000#32 := reg_keep r2 (by simp) sp1
  obtain ⟨s3, hs3⟩ : ∃ t, PrivMachine.run env 3 s2 = t := ⟨_, rfl⟩
  obtain ⟨p3, a3, h3, m3, c3, o3, i3, x3, y3, r3⟩ := handler_e3_ecall env M0 s2 hS2 ms e c m cy (s.core.reg 2#5) p2 c2 hc
  rw [hs3] at p3 a3 h3 m3 c3 o3 i3 x3 y3 r3
  have hS3 := hS2.next a3 h3 m3
  have sp3 : s3.core.reg 2#5 = 0x80008000#32 := reg_keep r3 (by simp) sp2
  have hk4 : readLE s3.core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 := by rw [x3, x2, x1]
  have hk14 : BitVec.ofNat 32 ((s.core.reg 5#5).toNat % 4294967296) ≠ 1#32 := by rw [ofNat_toNat_mod]; exact ht0
  obtain ⟨s4, hs4⟩ : ∃ t, PrivMachine.run env 3 s3 = t := ⟨_, rfl⟩
  obtain ⟨p4, a4, h4, m4, c4, o4, i4, x4, y4, r4⟩ := handler_c_bad env M0 s3 hS3 ms e c m cy (s.core.reg 2#5) ((s.core.reg 5#5).toNat % 4294967296) p3 c3 sp3 (hk4) (hk14)
  rw [hs4] at p4 a4 h4 m4 c4 o4 i4 x4 y4 r4
  have hS4 := hS3.next a4 h4 m4
  have sp4 : s4.core.reg 2#5 = 0x80008000#32 := reg_keep r4 (by simp) sp3
  obtain ⟨s5, hs5⟩ : ∃ t, PrivMachine.run env 5 s4 = t := ⟨_, rfl⟩
  obtain ⟨p5, a5, h5, m5, c5, o5, i5, x5, y5, r5⟩ := handler_f1 env M0 s4 hS4 ms e c m cy (s.core.reg 2#5) p4 c4
  rw [hs5] at p5 a5 h5 m5 c5 o5 i5 x5 y5 r5
  have hS5 := hS4.next a5 h5 m5
  have sp5 : s5.core.reg 2#5 = 0x80008000#32 := reg_keep r5 (by simp) sp4
  have t5 : s5.core.reg 6#5 = 0xc0000004#32 := reg_set r5 (by simp)
  obtain ⟨s6, hs6⟩ : ∃ t, PrivMachine.run env 2 s5 = t := ⟨_, rfl⟩
  obtain ⟨p6, a6, h6, m6, c6, o6, i6, x6, y6, r6⟩ := handler_f2 env M0 s5 hS5 ms e c m cy (s.core.reg 2#5) p5 c5 t5
  rw [hs6] at p6 a6 h6 m6 c6 o6 i6 x6 y6 r6
  have hS6 := hS5.next a6 h6 m6
  have sp6 : s6.core.reg 2#5 = 0x80008000#32 := reg_keep r6 (by simp) sp5
  have t6 : s6.core.reg 6#5 = 0xc0000004#32 := reg_keep r6 (by simp) t5
  obtain ⟨s7, hs7⟩ : ∃ t, PrivMachine.run env 2 s6 = t := ⟨_, rfl⟩
  obtain ⟨p7, a7, h7, m7, c7, o7, i7, x7, y7, r7⟩ := handler_f3 env M0 s6 hS6 ms e c m cy (s.core.reg 2#5) p6 c6 t6
  rw [hs7] at p7 a7 h7 m7 c7 o7 i7 x7 y7 r7
  have hS7 := hS6.next a7 h7 m7
  have sp7 : s7.core.reg 2#5 = 0x80008000#32 := reg_keep r7 (by simp) sp6
  have t7 : s7.core.reg 6#5 = 0xc0000004#32 := reg_keep r7 (by simp) t6
  obtain ⟨s8, hs8⟩ : ∃ t, PrivMachine.run env 2 s7 = t := ⟨_, rfl⟩
  obtain ⟨p8, a8, h8, m8, c8, o8, i8, x8, y8, r8⟩ := handler_f4 env M0 s7 hS7 ms e c m cy (s.core.reg 2#5) p7 c7 t7
  rw [hs8] at p8 a8 h8 m8 c8 o8 i8 x8 y8 r8
  have hS8 := hS7.next a8 h8 m8
  have sp8 : s8.core.reg 2#5 = 0x80008000#32 := reg_keep r8 (by simp) sp7
  have t8 : s8.core.reg 6#5 = 0xc0000004#32 := reg_keep r8 (by simp) t7
  obtain ⟨s9, hs9⟩ : ∃ t, PrivMachine.run env 2 s8 = t := ⟨_, rfl⟩
  obtain ⟨p9, a9, h9, m9, c9, o9, i9, x9, y9, r9⟩ := handler_f5 env M0 s8 hS8 ms e c m cy (s.core.reg 2#5) p8 c8 t8
  rw [hs9] at p9 a9 h9 m9 c9 o9 i9 x9 y9 r9
  have hS9 := hS8.next a9 h9 m9
  have sp9 : s9.core.reg 2#5 = 0x80008000#32 := reg_keep r9 (by simp) sp8
  have t9 : s9.core.reg 6#5 = 0xc0000004#32 := reg_keep r9 (by simp) t8
  obtain ⟨s10, hs10⟩ : ∃ t, PrivMachine.run env 2 s9 = t := ⟨_, rfl⟩
  obtain ⟨p10, a10, h10, m10, c10, o10, i10, x10, y10, r10⟩ := handler_f6 env M0 s9 hS9 ms e c m cy (s.core.reg 2#5) p9 c9
  rw [hs10] at p10 a10 h10 m10 c10 o10 i10 x10 y10 r10
  have hS10 := hS9.next a10 h10 m10
  have sp10 : s10.core.reg 2#5 = 0x80008000#32 := reg_keep r10 (by simp) sp9
  have hall : PrivMachine.run env 25 s = s10 := run_two hs1 (run_two hs2 (run_two hs3 (run_two hs4 (run_two hs5 (run_two hs6 (run_two hs7 (run_two hs8 (run_two hs9 (hs10)))))))))
  obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, qh, qi⟩ := monitor_scrub env M0 s10 hS10 ms e c m cy (s.core.reg 2#5) p10 c10 sp10
  rw [show 62 = 25 + 37 from rfl, PrivMachine.run_add, hall]
  refine ⟨q1, q2, q3, q4, q5, q6, q7, ?_, q9, by rw [qh, o10, o9, o8, o7, o6, o5, o4, o3, o2, o1], ?_⟩
  rotate_left
  · rw [qi, i10, i9, i8, i7, i6, i5, i4, i3, i2, i1]
    simp [r10, r9, r8, r7, r6, r5, r4, r3, r2, r1, regsUpd, List.append_assoc]
  rw [q8]
  exact reg_set r10 (by simp)

/-- A fault, as the host hears it: the report to the print word — the tag, `mcause`, `mepc`, `mtval` and
    `minstret` — then exit code 1. `mtval` is 0: Hazard3 hardwires it to 0. -/
def faultIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, u.csrs.mcause⟩, ⟨0xc0000004#32, u.csrs.mepc⟩,
   ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, u.csrs.minstret⟩, ⟨0xc0000008#32, 1#32⟩]

/-- A HALT, as the host hears it: the tag, the payload's `a0`, `minstret` and `mcycle`, then `a0` as the exit code. -/
def haltIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, u.core.reg 10#5⟩, ⟨0xc0000004#32, u.csrs.minstret⟩,
   ⟨0xc0000004#32, u.csrs.mcycle⟩, ⟨0xc0000008#32, u.core.reg 10#5⟩]

set_option maxHeartbeats 4000000 in
/-- **The wall the monitor holds.** From reset, the monitor boots (53 steps); the payload then runs
    for up to `n` steps. Either it is still running, in U-mode, boxed in `[0x80010000, 0x80020000)`,
    and the monitor's words are where they were — or it trapped, and from the trap vector the
    machine reaches the park loop with every register but `a0` zero, `mscratch` zero, and `a0` either
    the payload's own exit code (a clean HALT: `ecall` with `t0 = 1`) or 1; and what the host heard is the
    report for that ending, `haltIo` or `faultIo`, then the exit code. -/
theorem monitor_end_to_end (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ (PrivMachine.run env k (PrivMachine.run env 53 s)).mode = .U ∧
        UBoxed (PrivMachine.run env k (PrivMachine.run env 53 s)) 0x80010000 0x80020000 ∧
        Agree M0 (PrivMachine.run env k (PrivMachine.run env 53 s)).core.mem 0x80000000 572) ∨
       (0 < k ∧ ∃ j,
        (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.pc = 0x80000234#32 ∧
        (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).halted = false ∧
        (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).csrs.mscratch = 0#32 ∧
        (∀ r, r ≠ 10#5 →
          (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.reg r = 0#32) ∧
        (((PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.reg 10#5 = 1#32 ∧
          (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).io =
            (PrivMachine.run env k (PrivMachine.run env 53 s)).io ++ faultIo (PrivMachine.run env k (PrivMachine.run env 53 s))) ∨
         ((PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.reg 10#5 =
            (PrivMachine.run env k (PrivMachine.run env 53 s)).core.reg 10#5 ∧
          (PrivMachine.run env k (PrivMachine.run env 53 s)).csrs.mcause = 8#32 ∧
          (PrivMachine.run env k (PrivMachine.run env 53 s)).core.reg 5#5 = 1#32 ∧
          (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).io =
            (PrivMachine.run env k (PrivMachine.run env 53 s)).io ++ haltIo (PrivMachine.run env k (PrivMachine.run env 53 s)))))) := by
  obtain ⟨hbox, hpc1, hcs1, hmem1, hreg1⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  obtain ⟨ms0, e0, c0, m0, cy0, hcs1'⟩ := hcs1
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 53 s = t := ⟨_, rfl⟩
  rw [hs1] at hbox hpc1 hcs1' hmem1 hreg1 ⊢
  obtain ⟨k, hkn, hkept, hhalt, hframe, hres⟩ := umode_run env 0x80010000 0x80020000 (by decide) n s1 hbox
  refine ⟨k, hkn, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s1 = t := ⟨_, rfl⟩
  rw [hu] at hkept hhalt hframe hres ⊢
  have hagree : Agree M0 u.core.mem 0x80000000 572 := by
    intro x h1 h2
    rw [hframe x (by omega), hmem1]
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hpc2⟩
  · exact Or.inl ⟨hk, hmode, hb, hagree⟩
  · right
    refine ⟨hpos, ?_⟩
    obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := hkept
    rw [hcs1'] at k1 k2 k3 k4 k5 k6 k7 k8 hpc2
    have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
      csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8
    have hpcu : u.core.pc = 0x80000114#32 := by
      rw [hpc2]; show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32; decide
    have hS : HState env M0 u := ⟨hW, hagree, henv, hhalt, hmode⟩
    by_cases hc : u.csrs.mcause = 8#32
    · by_cases ht0 : u.core.reg 5#5 = 1#32
      · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, -, qi⟩ :=
          monitor_halt env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu hc ht0
        exact ⟨57, q1, q3, q5, q9, Or.inr ⟨q8, hc, ht0, qi⟩⟩
      · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, -, qi⟩ :=
          monitor_fault_syscall env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu hc ht0
        exact ⟨62, q1, q3, q5, q9, Or.inl ⟨q8, qi⟩⟩
    · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, -, qi⟩ :=
        monitor_fault_cause env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu hc
      exact ⟨59, q1, q3, q5, q9, Or.inl ⟨q8, qi⟩⟩


end Exp236

#print axioms Exp236.monitorCode_length
#print axioms Exp236.monitor_boot
#print axioms Exp236.monitor_scrub
#print axioms Exp236.monitor_halt
#print axioms Exp236.monitor_fault_cause
#print axioms Exp236.monitor_fault_syscall
#print axioms Exp236.monitor_end_to_end
#print axioms Rv32.Priv.umode_step
#print axioms Rv32.Priv.umode_run
