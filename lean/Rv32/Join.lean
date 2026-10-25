/-
SPDX-License-Identifier: Apache-2.0

# A kernel's run, inside a monitor's box

A kernel's own proof is a Tier 1 theorem: `Rv32.run`, in an `Env` whose region
is the kernel's 64 KiB, ends in `.halted`. A monitor's proof is a Tier 2
theorem: `PrivMachine.run`, from the trap vector, parks. This file is what
lets the first be read on the machine the second is about. Run the kernel in
U-mode, boxed by one RWX PMP entry over exactly its region, and its steps are
the Tier 2 steps one for one; its HALT is the trap the monitor is proved from.

Two things a Tier 1 run does not give for free, and this file asks for:

  * **No service call.** Tier 1's `ecall` is the shell's: `t0 = 0`, 2 and 3
    are HASH and SIG and the run goes on. Tier 2's is a trap, to a monitor
    that may serve none of them. So every `ecall` the run reaches before its
    HALT must be at `t0 = 1` -- which for a kernel `Ct.check` accepts is
    `Ct.ecalls_halt`, checked by `decide`.
  * **The region is the box.** The Tier 1 run is in `boxEnv env lo hi`, the
    world with the region `[lo, hi)`; the Tier 2 run is in `env`, whose region
    holds it (the monitor's own code runs outside the box). `run_within` is
    what carries one to the other.

Self-modifying code needs nothing more: the box is one RWX entry, so a store
into the code is the same store, and the same next fetch, in both tiers.
-/
import Rv32.Refinement
import Rv32.Sandbox
import Rv32.Within
import Rv32.Ct

namespace Rv32.Join
open Rv32 Rv32.Priv Rv32.Refinement

/-- `env`, with the region the box `[lo, hi)`: the world a kernel's own proof is about. -/
def boxEnv (env : Env) (lo hi : Nat) : Env := { env with region := ⟨lo, hi⟩ }

/-- The word a machine fetches. -/
abbrev fetched (m : Machine) : Word := BitVec.ofNat 32 (readLE m.mem m.pc 4)

/-! ## One step -/

/-- A word with opcode `0x73` decodes to `ecall` or to nothing. -/
theorem decode_sys {w : Word} (h : w.toNat % 128 = 0x73) : decode w = some .ecall ∨ decode w = none := by
  unfold decode decodeNat
  simp only [h]
  by_cases e : w.toNat = 0x73 <;> simp [e]

theorem opcode_toNat (w : Word) : (w &&& 0x7F#32).toNat = w.toNat % 128 := by
  rw [BitVec.toNat_and, show (0x7F#32).toNat = 2 ^ 7 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod]

/-- A word that decodes, and not to `ecall`, is not `ecall`, `mret` or a CSR access. -/
theorem plain_of_decode {w : Word} {i : Instr} (hd : decode w = some i) (hi : i ≠ .ecall) :
    isEcall w = false ∧ isMret w = false ∧ isZicsr w = false := by
  have hn : w.toNat % 128 ≠ 0x73 := by
    intro h
    rcases decode_sys h with e | e <;> rw [hd] at e
    · exact hi (Option.some.inj e)
    · cases e
  refine ⟨?_, ?_, ?_⟩
  · simp only [isEcall, decide_eq_false_iff_not]
    intro e; subst e; exact hn rfl
  · simp only [isMret, decide_eq_false_iff_not]
    intro e; subst e; exact hn rfl
  · simp only [isZicsr, decide_eq_false_iff_not, not_and]
    intro e
    have := congrArg BitVec.toNat e
    rw [opcode_toNat] at this
    exact absurd this hn

/-- **A step Tier 1 took inside the box is one Tier 2 takes as it is.** Tier 1 went
on from this core, in the box's own region, and the word is not an `ecall`: then
the instruction is aligned, in the box, plain, and whatever it loads or stores is
in the box. -/
theorem safe_of_step {env : Env} {s : PrivMachine} {lo hi : Nat} {c : Machine}
    (hs : step (boxEnv env lo hi) s.core = .running c)
    (he : decode (fetched s.core) ≠ some .ecall) : SafeUInstr s lo hi := by
  unfold step fetch at hs
  by_cases hal : s.core.pc.toNat % 4 ≠ 0
  · simp [hal] at hs
  by_cases hok : (boxEnv env lo hi).region.ok s.core.pc 4
  case neg => simp [hal, hok] at hs
  simp only [hal, hok, not_true_eq_false, ↓reduceIte] at hs
  cases hd : decode (fetched s.core) with
  | none => simp only [fetched] at hd; rw [hd] at hs; cases hs
  | some i =>
    simp only [fetched] at hd
    rw [hd] at hs
    simp only at hs
    have hi : i ≠ .ecall := fun e => he (by rw [← e]; exact hd)
    obtain ⟨p1, p2, p3⟩ := plain_of_decode hd hi
    simp only [boxEnv, Region.ok] at hok
    refine ⟨by omega, hok, p1, ⟨p2, p3⟩, ?_⟩
    rw [hd]
    cases i with
    | ld op rd rs1 imm =>
      simp only [exec] at hs
      split at hs
      · cases hs
      split at hs
      · cases hs
      rename_i h1 h2
      simp only [boxEnv, Region.ok] at h2
      exact ⟨by omega, by omega, by omega⟩
    | st op rs1 rs2 imm =>
      simp only [exec] at hs
      split at hs
      · cases hs
      split at hs
      · cases hs
      rename_i h1 h2
      simp only [boxEnv, Region.ok] at h2
      exact ⟨by omega, by omega, by omega⟩
    | _ => trivial

/-- A Tier 1 step that halts is a HALT: an `ecall` at `t0 = 1`, the code `a0`, the
machine as it was, at an aligned word in the region. -/
theorem step_halted {env : Env} {m m' : Machine} {code : Word} (h : step env m = .halted code m') :
    decode (fetched m) = some .ecall ∧ m.reg T0 = 1 ∧ m.reg A0 = code ∧ m' = m ∧
      m.pc.toNat % 4 = 0 ∧ env.region.ok m.pc 4 := by
  unfold step fetch at h
  by_cases hal : m.pc.toNat % 4 ≠ 0
  · simp [hal] at h
  by_cases hok : env.region.ok m.pc 4
  case neg => simp [hal, hok] at h
  simp only [hal, hok, not_true_eq_false, ↓reduceIte] at h
  cases hd : decode (fetched m) with
  | none => simp only [fetched] at hd; rw [hd] at h; cases h
  | some i =>
    simp only [fetched] at hd
    rw [hd] at h
    simp only at h
    by_cases hi : i = .ecall
    · subst hi
      simp only [exec, syscall] at h
      by_cases h0 : m.reg T0 = 0
      · simp only [h0, ↓reduceIte] at h
        split at h <;> cases h
      by_cases h1 : m.reg T0 = 1
      · simp only [h1, ↓reduceIte] at h
        injection h with e1 e2
        exact ⟨rfl, h1, e1, e2.symm, by omega, hok⟩
      simp only [h0, h1, ↓reduceIte] at h
      repeat' split at h
      all_goals cases h
    · exact absurd h (exec_no_halt hi)

/-- **A boxed `ecall` traps.** In U-mode, boxed, at a word in the box that is `ecall`:
the step is the trap, cause 8. -/
theorem ecall_trap (env : Env) (s : PrivMachine) {lo hi : Nat} (hBox : UBoxed s lo hi)
    (hd : decode (fetched s.core) = some .ecall) (hin : lo ≤ s.core.pc.toNat ∧ s.core.pc.toNat + 4 ≤ hi) :
    PrivMachine.step env s = raiseTrap s CAUSE_ECALL_UMODE := by
  have hf : pmpCheck s.csrs s.mode s.core.pc 4 .Fetch = true :=
    (pmpCheck_uboxed_iff s lo hi hBox s.core.pc 4 .Fetch (by decide)).mpr hin
  have he : isEcall (fetched s.core) = true := decode_ecall hd
  unfold PrivMachine.step PrivMachine.stepW uModeTrapCause
  simp only [fetched] at he
  rw [hBox.isUMode] at hf
  rw [hBox.notHalted]
  simp only [Bool.false_eq_true, ↓reduceIte, hBox.isUMode, hf, not_true_eq_false, he]

/-- At an `ecall` with `t0 = 1`, Tier 1 does not go on: it halts, or faults on the fetch. -/
theorem step_not_running {env : Env} {m c : Machine} (hd : decode (fetched m) = some .ecall)
    (h1 : m.reg T0 = 1) : step env m ≠ .running c := by
  intro hs
  unfold step fetch at hs
  by_cases hal : m.pc.toNat % 4 ≠ 0
  · simp [hal] at hs
  by_cases hok : env.region.ok m.pc 4
  case neg => simp [hal, hok] at hs
  simp only [fetched] at hd
  simp only [hal, hok, not_true_eq_false, ↓reduceIte, hd, exec, syscall, h1] at hs
  simp at hs

/-! ## Many steps -/

/-- **A Tier 1 run inside the box is the Tier 2 run.** Tier 1, in the box's region, is
still going after `n` steps, and every `ecall` it reaches on the way is at `t0 = 1` -- so
it executes none, since a HALT would have ended it. Tier 2, in `env`, whose region holds
the box, from a boxed state with that core and its counters running: `n` steps reach the
same core, still boxed, the CSRs the monitor set kept and both counters up by `n`; no port
is written or read; memory outside the box is as it was. -/
theorem run_in_box (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region) (hhi : hi ≤ 2^32) :
    ∀ (n : Nat) (s : PrivMachine) (c : Machine), UBoxed s lo hi → s.csrs.mcountinhibit = {} →
      run (boxEnv env lo hi) n s.core = .running c →
      (∀ i < n, ∀ m, run (boxEnv env lo hi) i s.core = .running m →
        decode (fetched m) = some .ecall → m.reg T0 = 1) →
      (PrivMachine.run env n s).core = c ∧ UBoxed (PrivMachine.run env n s) lo hi ∧
      KeptCsrs s.csrs (PrivMachine.run env n s).csrs ∧
      (PrivMachine.run env n s).csrs.minstret = s.csrs.minstret + BitVec.ofNat 32 n ∧
      (PrivMachine.run env n s).csrs.mcycle = s.csrs.mcycle + BitVec.ofNat 32 n ∧
      (PrivMachine.run env n s).io = s.io ∧ (PrivMachine.run env n s).host = s.host ∧
      (∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) → c.mem x = s.core.mem x) := by
  have hReg' : env.region.lo ≤ lo ∧ hi ≤ env.region.hi := hReg
  intro n
  induction n with
  | zero =>
    intro s c hBox _ hr _
    simp only [run] at hr
    cases hr
    exact ⟨rfl, hBox, KeptCsrs.refl _, by simp [PrivMachine.run], by simp [PrivMachine.run], rfl, rfl,
      fun _ _ => rfl⟩
  | succ n ih =>
    intro s c hBox hinh hr hq
    simp only [run] at hr
    cases hs : step (boxEnv env lo hi) s.core with
    | halted _ _ => rw [hs] at hr; cases hr
    | fault _ _ => rw [hs] at hr; cases hr
    | running c1 =>
      rw [hs] at hr
      have hne : decode (fetched s.core) ≠ some .ecall := fun hd =>
        step_not_running hd (hq 0 (by omega) s.core rfl hd) hs
      have hSafe := safe_of_step hs hne
      have hs' : step env s.core = .running c1 :=
        (step_within (env := boxEnv env lo hi) (env' := env) ⟨rfl, rfl⟩ hReg).1 c1 hs
      obtain ⟨hcore1, hBox1, hcsrs1⟩ := step_simulates_running env s lo hi hBox hSafe hReg' hs'
      obtain ⟨i, hdec, hstep⟩ := PrivMachine.step_eq_of_safe env s lo hi hBox hSafe
      obtain ⟨i', hdec', hex⟩ := tier1_step_eq_exec env s lo hi hSafe hReg'
      rw [hdec] at hdec'
      cases hdec'
      rw [← hex, hs'] at hstep
      have hio1 : (PrivMachine.step env s).io = s.io := by rw [hstep]
      have hhost1 : (PrivMachine.step env s).host = s.host := by rw [hstep]
      have hframe1 : ∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) → c1.mem x = s.core.mem x := by
        intro x hx
        obtain ⟨-, -, hcase⟩ := umode_step env s lo hi hBox hhi
        rcases hcase with ⟨-, -, hm⟩ | ⟨hm, -⟩
        · rw [← hm x hx, ← hcore1]; rfl
        · rw [hBox1.isUMode] at hm; cases hm
      have hinh1 : (PrivMachine.step env s).csrs.mcountinhibit = {} := by rw [hcsrs1]; exact hinh
      have hq1 : ∀ i < n, ∀ m, run (boxEnv env lo hi) i (PrivMachine.step env s).core = .running m →
          decode (fetched m) = some .ecall → m.reg T0 = 1 := by
        intro i hi m hm
        refine hq (i + 1) (by omega) m ?_
        simp only [run, hs]
        rw [← hcore1]; exact hm
      obtain ⟨r1, r2, r3, r4, r5, r6, r7, r8⟩ :=
        ih (PrivMachine.step env s) c hBox1 hinh1 (by rw [show (PrivMachine.step env s).core = c1 from hcore1]; exact hr) hq1
      rw [run_succ_step env n s hBox.notHalted]
      have hk : KeptCsrs s.csrs (PrivMachine.step env s).csrs := by rw [hcsrs1]; exact kept_bump _
      refine ⟨r1, r2, hk.trans r3, ?_, ?_, by rw [r6, hio1], by rw [r7, hhost1], fun x hx => ?_⟩
      · rw [r4, hcsrs1]
        simp only [bumpCounters, hinh]
        simp only [Bool.false_eq_true, ↓reduceIte, BitVec.ofNat_add]
        bv_omega
      · rw [r5, hcsrs1]
        simp only [bumpCounters, hinh]
        simp only [Bool.false_eq_true, ↓reduceIte, BitVec.ofNat_add]
        bv_omega
      · rw [r8 x hx, show (PrivMachine.step env s).core = c1 from hcore1, hframe1 x hx]

/-- **A kernel's HALT, inside the box, is the trap the monitor is proved from.** Tier 1, in
the box's region: running after `n` steps, halted with `code` on the next, every `ecall` on
the way at `t0 = 1`. Tier 2, in `env`, from a boxed state with that core, counters running:
`n + 1` steps reach the trap vector in M-mode, with cause 8 (`ecall` from U-mode) and `mepc`
at the kernel's `ecall`; the registers and memory are what the kernel's HALT left, so
`t0 = 1` and `a0 = code`; the CSRs the monitor set are kept and both counters up by `n + 1`;
no port was touched; memory outside the box is as it was. -/
theorem halt_in_box (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region) (hhi : hi ≤ 2^32)
    (n : Nat) (s : PrivMachine) {c c' : Machine} {code : Word} (hBox : UBoxed s lo hi)
    (hinh : s.csrs.mcountinhibit = {})
    (hr : run (boxEnv env lo hi) n s.core = .running c)
    (hh : run (boxEnv env lo hi) (n + 1) s.core = .halted code c')
    (hq : ∀ i < n, ∀ m, run (boxEnv env lo hi) i s.core = .running m →
      decode (fetched m) = some .ecall → m.reg T0 = 1) :
    (PrivMachine.run env (n + 1) s).mode = .M ∧ (PrivMachine.run env (n + 1) s).halted = false ∧
    (PrivMachine.run env (n + 1) s).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
    (∀ r, (PrivMachine.run env (n + 1) s).core.reg r = c.reg r) ∧
    (PrivMachine.run env (n + 1) s).core.mem = c.mem ∧
    c.reg T0 = 1 ∧ c.reg A0 = code ∧
    (PrivMachine.run env (n + 1) s).csrs.mcause = CAUSE_ECALL_UMODE ∧
    (PrivMachine.run env (n + 1) s).csrs.mepc = c.pc ∧
    KeptCsrs s.csrs (PrivMachine.run env (n + 1) s).csrs ∧
    (PrivMachine.run env (n + 1) s).csrs.minstret = s.csrs.minstret + BitVec.ofNat 32 (n + 1) ∧
    (PrivMachine.run env (n + 1) s).csrs.mcycle = s.csrs.mcycle + BitVec.ofNat 32 (n + 1) ∧
    (PrivMachine.run env (n + 1) s).io = s.io ∧ (PrivMachine.run env (n + 1) s).host = s.host ∧
    (∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) → (PrivMachine.run env (n + 1) s).core.mem x = s.core.mem x) := by
  have hstep : step (boxEnv env lo hi) c = .halted code c' := by
    rw [run_add_running hr] at hh
    simp only [run] at hh
    revert hh
    cases step (boxEnv env lo hi) c <;> simp
  obtain ⟨hd, h1, h0, -, -, hok⟩ := step_halted hstep
  obtain ⟨r1, r2, r3, r4, r5, r6, r7, r8⟩ := run_in_box env hReg hhi n s c hBox hinh hr hq
  rw [PrivMachine.run_add, show PrivMachine.run env 1 (PrivMachine.run env n s) =
    PrivMachine.step env (PrivMachine.run env n s) from run_succ_step env 0 _ r2.notHalted]
  have hd' : decode (fetched (PrivMachine.run env n s).core) = some .ecall := by rw [r1]; exact hd
  have hin : lo ≤ (PrivMachine.run env n s).core.pc.toNat ∧ (PrivMachine.run env n s).core.pc.toNat + 4 ≤ hi := by
    rw [r1]; simpa [boxEnv, Region.ok] using hok
  rw [ecall_trap env _ r2 hd' hin]
  have hk : KeptCsrs (PrivMachine.run env n s).csrs (raiseTrap (PrivMachine.run env n s) CAUSE_ECALL_UMODE).csrs :=
    kept_trap _ _
  have hinhn : (PrivMachine.run env n s).csrs.mcountinhibit = {} := by rw [r3.2.2.2.2.2.2.2]; exact hinh
  refine ⟨rfl, r2.notHalted, ?_, fun r => ?_, ?_, h1, h0, rfl, by simp [raiseTrap, bumpCounters, r1], r3.trans hk, ?_, ?_,
    by simp [raiseTrap, r6], by simp [raiseTrap, r7], fun x hx => ?_⟩
  · simp only [raiseTrap]; rw [r3.1]
  · simp only [raiseTrap]; rw [r1]; rfl
  · simp only [raiseTrap]; rw [r1]
  · simp only [raiseTrap, bumpCounters, hinhn, Bool.false_eq_true, ↓reduceIte, r4, BitVec.ofNat_add]
    bv_omega
  · simp only [raiseTrap, bumpCounters, hinhn, Bool.false_eq_true, ↓reduceIte, r5, BitVec.ofNat_add]
    bv_omega
  · simp only [raiseTrap]; rw [r1]; exact r8 x hx

/-! ## No service call, from the constant-time checker -/

/-- **What `Ct` gives this file.** A kernel the constant-time checker accepts, every
`ecall` of which it reaches knowing `t0 = 1`, run from `base` with the kernel in memory:
at every state the run reaches, a fetched `ecall` is at `t0 = 1` -- the hypothesis
`run_in_box` and `halt_in_box` ask for, in the form they ask for it. -/
theorem quiet_of_ct {env : Env} {base : Word} (hp : Placed env base) {prog : List Instr}
    {P : List (Nat × Nat)} {H : Ct.Heads} (hc : Ct.check prog P H = true) (hq : Ct.haltsOnly prog P H = true)
    (hne : 0 < prog.length) {s : Machine} (hpc : s.pc = base) (hcode : CodeAt s.mem base prog) :
    ∀ i m, run env i s = .running m → decode (fetched m) = some .ecall → m.reg T0 = 1 := by
  intro i m hm hd
  obtain ⟨k, hk, hpc', hcode', hT⟩ := Ct.ecalls_halt hp hc hq hne hpc hcode i m hm
  apply hT
  have : decode (fetched m) = some prog[k] := by
    simp only [fetched]
    rw [hpc', hcode' k hk, BitVec.ofNat_toNat, BitVec.setWidth_eq, decode_encode]
  rw [this] at hd
  exact Option.some.inj hd

end Rv32.Join

#print axioms Rv32.Join.run_in_box
#print axioms Rv32.Join.halt_in_box
#print axioms Rv32.Join.quiet_of_ct
