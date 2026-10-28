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
import Rv32.Reach
import Rv32.WxTwin
import Rv32.WxBox

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
      by_cases h0 : m.reg T0 = 0 ∧ env.servesHash = true
      · simp only [h0, and_self, ↓reduceIte] at h
        split at h <;> cases h
      simp only [h0, ↓reduceIte] at h
      by_cases h1 : m.reg T0 = 1
      · simp only [h1, ↓reduceIte] at h
        injection h with e1 e2
        exact ⟨rfl, h1, e1, e2.symm, by omega, hok⟩
      simp only [h1, ↓reduceIte] at h
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
  rw [hBox.notHalted, sleeps_of_ecall he]
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
        (step_within (env := boxEnv env lo hi) (env' := env) ⟨rfl, rfl, rfl⟩ hReg).1 c1 hs
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
    {P : Ct.Pub} {H : Ct.Heads} (hc : Ct.check prog P H = true) (hq : Ct.haltsOnly prog P H = true)
    (hne : 0 < prog.length) {s : Machine} (hpc : s.pc = base) (hcode : CodeAt s.mem base prog)
    (hkc : ∀ c ∈ P.consts, readLE s.mem (base + BitVec.ofNat 32 c.1) 4 = c.2 := by intro c hc; cases hc) :
    ∀ i m, run env i s = .running m → decode (fetched m) = some .ecall → m.reg T0 = 1 := by
  intro i m hm hd
  obtain ⟨k, hk, hpc', hcode', hT⟩ :=
    Ct.ecalls_halt (hp.hosted (by have := Ct.check_len hc; omega)) hc hq hne hpc hcode hkc i m hm
  apply hT
  have : decode (fetched m) = some prog[k] := by
    simp only [fetched]
    rw [hpc', hcode' k hk, BitVec.ofNat_toNat, BitVec.setWidth_eq, decode_encode]
  rw [this] at hd
  exact Option.some.inj hd

/-- **What `Reach` gives this file.** A `Good` state's fetched `ecall` is at `t0 = 1`: the hypothesis
`run_in_box` and `halt_in_box` ask for, from a state the reach checker has vouched for. -/
theorem quiet_of_good {env : Env} {base : Word} {prog : List Instr} {lw sw : Nat × Nat} {m : Machine}
    (hg : Reach.Good env base prog lw sw m) : decode (fetched m) = some .ecall → m.reg T0 = 1 := by
  intro hd
  obtain ⟨k, hk, hpc, hcode, -, -, hT⟩ := hg
  apply hT
  have : decode (fetched m) = some prog[k] := by
    simp only [fetched]
    rw [hpc, hcode k hk, BitVec.ofNat_toNat, BitVec.setWidth_eq, decode_encode]
  rw [this] at hd
  exact Option.some.inj hd

/-! ## The calls a halted run made

A step that faults ends the run there: `run` does not go on from a fault. So a run that halted faulted
nowhere on the way, and every `ecall` it made was one its world serves, with its arguments as that world
asks for them. In a world that does not serve `HASH` (`t0 = 0`), that is `HALT`, `HASHB` or `CHECKSIG`
with its ranges in the region: the three exp238's monitor serves. A kernel proved for every world is
proved for that one. -/

/-- **A run that halted faulted nowhere before.** -/
theorem step_not_fault_of_halted {env : Env} {n i : Nat} {s m s' : Machine} {c : Word}
    (h : run env n s = .halted c s') (hi : i < n) (hm : run env i s = .running m) :
    ∀ f t, step env m ≠ .fault f t := by
  intro f t hf
  have e : run env (i + (n - i)) s = run env (n - i) m := run_add_running hm
  rw [Nat.add_sub_cancel' (by omega), h] at e
  obtain ⟨k, hk⟩ : ∃ k, n - i = k + 1 := ⟨n - i - 1, by omega⟩
  rw [hk] at e
  simp [run, hf] at e

/-- **A halted run made only the calls its world serves.** In a world that does not serve `HASH`, every
`ecall` a run that halted made on the way was `HALT`, or `HASHB` or `CHECKSIG` with its ranges in the
region. -/
theorem calls_of_halted {env : Env} (hs : env.servesHash = false) {n : Nat} {s s' : Machine} {c : Word}
    (h : run env n s = .halted c s') :
    ∀ i < n, ∀ m, run env i s = .running m → decode (fetched m) = some .ecall →
      m.reg T0 = 1 ∨
      (m.reg T0 = 2 ∧ env.region.ok (m.reg A0) (m.reg A1).toNat ∧ env.region.ok (m.reg A2) 32) ∨
      (m.reg T0 = 3 ∧ env.region.ok (m.reg A0) 32 ∧ env.region.ok (m.reg A1) 64) := by
  intro i hi m hm hd
  have hnf := step_not_fault_of_halted h hi hm
  unfold step fetch at hnf
  by_cases hal : m.pc.toNat % 4 ≠ 0
  · exact absurd (hnf .fetchMisaligned m) (by simp [hal])
  by_cases hok : env.region.ok m.pc 4
  case neg => exact absurd (hnf .fetchAccess m) (by simp [hal, hok])
  simp only [hal, hok, not_true_eq_false, ↓reduceIte] at hnf
  simp only [fetched] at hd
  rw [hd] at hnf
  simp only [exec, syscall] at hnf
  by_cases h1 : m.reg T0 = 1
  · exact Or.inl h1
  by_cases h2 : m.reg T0 = 2
  · by_cases ha : env.region.ok (m.reg A0) (m.reg A1).toNat ∧ env.region.ok (m.reg A2) 32
    · exact Or.inr (Or.inl ⟨h2, ha⟩)
    · exact absurd (hnf .hashArgs m) (by simp [h2, ha])
  by_cases h3 : m.reg T0 = 3
  · by_cases ha : env.region.ok (m.reg A0) 32 ∧ env.region.ok (m.reg A1) 64
    · exact Or.inr (Or.inr ⟨h3, ha⟩)
    · exact absurd (hnf .sigArgs m) (by simp [h3, ha])
  · have c0 : ¬ (m.reg T0 = 0 ∧ env.servesHash = true) := by simp [hs]
    refine absurd (hnf .unknownCall m) ?_
    rw [ite_eq_right_of_eq_false _ _ (eq_false c0), ite_eq_right_of_eq_false _ _ (eq_false h1),
      ite_eq_right_of_eq_false _ _ (eq_false h2), ite_eq_right_of_eq_false _ _ (eq_false h3)]
    simp


/-! ## Two cores that agree on the box

A monitor that serves a call writes its own stack and the ports, outside the box. After it, the Tier 2 core
and the Tier 1 core the kernel's proof is about differ there, and only there. A Tier 1 step in the box's
region reads nothing outside it, so the two go on alike. -/

/-- Two cores alike to a run in region `r`: the same `pc`, the same registers, the same bytes in `r`. -/
structure BoxEq (r : Region) (m c : Machine) : Prop where
  pc : m.pc = c.pc
  regs : ∀ x, m.reg x = c.reg x
  mem : ∀ x : Word, r.lo ≤ x.toNat → x.toNat < r.hi → m.mem x = c.mem x

theorem BoxEq.refl (r : Region) (m : Machine) : BoxEq r m m := ⟨rfl, fun _ => rfl, fun _ _ _ => rfl⟩

/-- Two cores alike in `r` read the same word anywhere in `r`. -/
theorem readLE_boxEq {r : Region} (hhi : r.hi ≤ 2^32) {m c : Machine} (h : BoxEq r m c) :
    ∀ (n : Nat) (a : Word), r.ok a n → readLE m.mem a n = readLE c.mem a n := by
  intro n
  induction n with
  | zero => intro a _; rfl
  | succ n ih =>
    intro a ha
    simp only [Region.ok] at ha
    simp only [readLE]
    rw [h.mem a (by omega) (by omega)]
    cases n with
    | zero => rfl
    | succ n =>
      have e : (a + 1).toNat = a.toNat + 1 := by
        rw [BitVec.toNat_add, show (1 : Word).toNat = 1 from rfl]; omega
      rw [ih (a + 1) (by simp only [Region.ok]; omega)]

/-- **Two cores alike in the region step alike.** A Tier 1 step that went on from one, not an `ecall`, goes on
from the other, and the two are alike after it. -/
theorem step_boxEq {env : Env} (hhi : env.region.hi ≤ 2^32) {m c m' : Machine} (h : BoxEq env.region m c)
    (hs : step env m = .running m') (he : decode (fetched m) ≠ some .ecall) :
    ∃ c', step env c = .running c' ∧ BoxEq env.region m' c' := by
  unfold step fetch at hs ⊢
  rw [← h.pc]
  by_cases hal : m.pc.toNat % 4 ≠ 0
  · simp [hal] at hs
  by_cases hok : env.region.ok m.pc 4
  case neg => simp [hal, hok] at hs
  have hw : readLE c.mem m.pc 4 = readLE m.mem m.pc 4 := (readLE_boxEq hhi h 4 m.pc hok).symm
  simp only [hal, hok, not_true_eq_false, ↓reduceIte, hw] at hs ⊢
  cases hd : decode (BitVec.ofNat 32 (readLE m.mem m.pc 4)) with
  | none => rw [hd] at hs; cases hs
  | some i =>
    rw [hd] at hs
    simp only at hs ⊢
    have hi : i ≠ .ecall := fun e => he (by simp only [fetched]; rw [hd, e])
    have hld : ∀ op rd rs1 imm, i = .ld op rd rs1 imm →
        readLE m.mem (m.reg rs1 + imm.signExtend 32) op.size = readLE c.mem (m.reg rs1 + imm.signExtend 32) op.size := by
      intro op rd rs1 imm hi'
      subst hi'
      simp only [exec] at hs
      split at hs
      · cases hs
      split at hs
      · cases hs
      rename_i _ h2
      exact readLE_boxEq hhi h _ _ (Classical.not_not.mp h2)
    rcases exec_twin (env := env) hi h.pc h.regs hld with ⟨c1, d, e1, e2, p, r, mm⟩ | ⟨f, c1, d, e1, -⟩
    · rw [e1] at hs
      cases hs
      exact ⟨d, e2, p, r, fun x h1 h2 => mm x (h.mem x h1 h2)⟩
    · rw [e1] at hs; cases hs

/-- Two cores alike in the region fetch the same word at a `pc` in it. -/
theorem fetched_boxEq {r : Region} (hhi : r.hi ≤ 2^32) {m c : Machine} (h : BoxEq r m c) (hok : r.ok m.pc 4) :
    fetched m = fetched c := by
  simp only [fetched]; rw [readLE_boxEq hhi h 4 m.pc hok, h.pc]

/-- A Tier 1 step that went on fetched in the region. -/
theorem fetch_ok_of_running {env : Env} {m m' : Machine} (hs : step env m = .running m') :
    m.pc.toNat % 4 = 0 ∧ env.region.ok m.pc 4 := by
  unfold step fetch at hs
  by_cases hal : m.pc.toNat % 4 ≠ 0
  · simp [hal] at hs
  by_cases hok : env.region.ok m.pc 4
  · exact ⟨by omega, hok⟩
  · simp [hal, hok] at hs

/-- **One step of a kernel's Tier 1 run is one Tier 2 step, from a core alike in the box.** Tier 1, in the box's
region, went on from `m`, not at an `ecall`. Tier 2, from a boxed state whose core is alike to `m` in the box,
counters running: one step, to a core alike to the Tier 1 one, still boxed, the monitor's CSRs kept, no port
touched, memory outside the box as it was. -/
theorem plain_in_box (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region) (hhi : hi ≤ 2^32)
    (s : PrivMachine) {m m' : Machine} (hBox : UBoxed s lo hi) (hinh : s.csrs.mcountinhibit = {})
    (h : BoxEq ⟨lo, hi⟩ m s.core) (hs : step (boxEnv env lo hi) m = .running m')
    (he : decode (fetched m) ≠ some .ecall) :
    BoxEq ⟨lo, hi⟩ m' (PrivMachine.run env 1 s).core ∧ UBoxed (PrivMachine.run env 1 s) lo hi ∧
      KeptCsrs s.csrs (PrivMachine.run env 1 s).csrs ∧
      (PrivMachine.run env 1 s).csrs.minstret = s.csrs.minstret + 1#32 ∧
      (PrivMachine.run env 1 s).io = s.io ∧ (PrivMachine.run env 1 s).host = s.host ∧
      (∀ x : Word, ¬ (lo ≤ x.toNat ∧ x.toNat < hi) → (PrivMachine.run env 1 s).core.mem x = s.core.mem x) := by
  obtain ⟨c', hc, hEq⟩ := step_boxEq (env := boxEnv env lo hi) hhi h hs he
  have hf : fetched m = fetched s.core := fetched_boxEq hhi h (fetch_ok_of_running hs).2
  obtain ⟨r1, r2, r3, r4, -, r6, r7, r8⟩ := run_in_box env hReg hhi 1 s c' hBox hinh
    (by simp only [run, hc]) (fun i hi m0 hm0 hd => by
      have : i = 0 := by omega
      subst this
      simp only [run] at hm0
      cases hm0
      exact absurd (hf ▸ hd) he)
  refine ⟨by rw [r1]; exact hEq, r2, r3, by rw [r4], r6, r7, fun x hx => by rw [r1]; exact r8 x hx⟩


/-- A run still going after `i + d` steps was going after `i`. -/
theorem run_running_prefix {env : Env} : ∀ (i d : Nat) (s : Machine) {m : Machine},
    run env (i + d) s = .running m → ∃ m', run env i s = .running m' := by
  intro i
  induction i with
  | zero => intro d s m _; exact ⟨s, rfl⟩
  | succ i ih =>
    intro d s m h
    rw [Nat.succ_add] at h
    simp only [run] at h ⊢
    cases hs : step env s with
    | running s1 => rw [hs] at h; exact ih d s1 h
    | _ => rw [hs] at h; cases h

/-- At a fetched `ecall`, a Tier 1 step is the call. -/
theorem step_at_ecall {env : Env} {m : Machine} (hal : m.pc.toNat % 4 = 0) (hok : env.region.ok m.pc 4)
    (hd : decode (fetched m) = some .ecall) : step env m = exec env m .ecall := by
  unfold step fetch
  simp only [fetched] at hd
  have hal' : ¬ m.pc.toNat % 4 ≠ 0 := by omega
  simp only [hal', hok, not_true_eq_false, ↓reduceIte, hd]

/-! ## In a W^X box

exp240's box has no byte both writable and runnable: a code entry, read and execute; a data entry, read and write,
with the code carved out of it; a stack entry. A Tier 1 step in the kernel's region is the Tier 2 step only where it
fetches in the code, loads where the box lets a load, and stores where it lets a store. `WxOk` says so of one core;
from it, the step is Tier 1's. -/

/-- What a W^X box asks of the step from core `m`: the fetch in the code; a load `WxReadable`; a store
`WxWritable`. -/
def WxOk (cLo cHi dLo dHi kLo kHi : Nat) (m : Machine) : Prop :=
  (cLo ≤ m.pc.toNat ∧ m.pc.toNat + 4 ≤ cHi) ∧
  match decode (fetched m) with
  | some (.ld op _ rs1 imm) => WxReadable cLo cHi dLo dHi kLo kHi (m.reg rs1 + imm.signExtend 32).toNat op.size
  | some (.st op rs1 _ imm) => WxWritable cLo cHi dLo dHi kLo kHi (m.reg rs1 + imm.signExtend 32).toNat op.size
  | _ => True

section
variable {cLo cHi dLo dHi kLo kHi : Nat}

/-- **One step of a kernel's Tier 1 run is one Tier 2 step in a W^X box.** Tier 1, in the box's region, went on
from the core, not at an `ecall`, and the step is one the box lets through (`WxOk`). Tier 2, in `env`, whose region
holds the box: the same core, the counters bumped, nothing else changed -- no port, no other CSR. -/
theorem wx_plain (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region) (s : PrivMachine)
    {c : Machine} (hB : WXBoxed s cLo cHi dLo dHi kLo kHi) (hs : step (boxEnv env lo hi) s.core = .running c)
    (he : decode (fetched s.core) ≠ some .ecall) (hw : WxOk cLo cHi dLo dHi kLo kHi s.core) :
    PrivMachine.step env s = { s with core := c, csrs := bumpCounters s.csrs } := by
  have hSafe := safe_of_step hs he
  have hReg' : env.region.lo ≤ lo ∧ hi ≤ env.region.hi := hReg
  obtain ⟨i, hdec, hex⟩ := tier1_step_eq_exec env s lo hi hSafe hReg'
  have hs' : step env s.core = .running c :=
    (step_within (env := boxEnv env lo hi) (env' := env) ⟨rfl, rfl, rfl⟩ hReg).1 c hs
  rw [hex] at hs'
  obtain ⟨hw1, hw2⟩ := hw
  have hf : pmpCheck s.csrs s.mode s.core.pc 4 .Fetch = true := (wx_fetch_iff hB _ 4 (by decide)).mpr hw1
  have hmem := hSafe.memInBounds
  simp only [fetched] at hw2
  rw [hdec] at hw2 hmem
  have htrap : uModeTrapCause s (BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)) = none := by
    unfold uModeTrapCause
    simp only [hf, not_true_eq_false, ↓reduceIte, hSafe.notEcall, Bool.false_eq_true, hSafe.notPriv.1,
      hSafe.notPriv.2, or_self, and_false, hdec, isEbreak_of_decode hdec]
    cases i with
    | ld op rd rs1 imm =>
      obtain ⟨hal, -, -⟩ := hmem
      have hl := wx_load_allowed hB _ op.size hw2 (by cases op <;> decide)
      have hal' : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
      simp [hal', hl]
    | st op rs1 rs2 imm =>
      obtain ⟨hal, -, -⟩ := hmem
      have hl := wx_store_allowed hB _ op.size hw2 (by cases op <;> decide)
      have hal' : (BitVec.toNat (s.core.reg rs1) + (BitVec.signExtend 32 imm).toNat) % 4294967296 % op.size = 0 := hal
      simp [hal', hl]
    | _ => rfl
  unfold PrivMachine.step PrivMachine.stepW
  rw [hB.notHalted, sleeps_of_decode (s := s) hdec, htrap]
  simp only [Bool.false_eq_true, ↓reduceIte, hSafe.notPriv.1, hSafe.notPriv.2, hdec, hs',
    portRead_U s hB.isUMode, portWrites_U s hB.isUMode, List.append_nil]

/-- **A boxed `ecall` in the code traps.** -/
theorem wx_ecall_trap (env : Env) (s : PrivMachine) (hB : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (hd : decode (fetched s.core) = some .ecall) (hin : cLo ≤ s.core.pc.toNat ∧ s.core.pc.toNat + 4 ≤ cHi) :
    PrivMachine.step env s = raiseTrap s CAUSE_ECALL_UMODE := by
  have hf : pmpCheck s.csrs s.mode s.core.pc 4 .Fetch = true := (wx_fetch_iff hB _ 4 (by decide)).mpr hin
  have he : isEcall (fetched s.core) = true := decode_ecall hd
  unfold PrivMachine.step PrivMachine.stepW uModeTrapCause
  simp only [fetched] at he
  rw [hB.isUMode] at hf
  rw [hB.notHalted, sleeps_of_ecall he]
  simp only [Bool.false_eq_true, ↓reduceIte, hB.isUMode, hf, not_true_eq_false, he]

/-- **A Tier 1 run in a W^X box is the Tier 2 run.** Tier 1, in the box's region, is still going after `n` steps;
at every state on the way an `ecall` is at `t0 = 1` and the step is one the box lets through. Tier 2, in `env`,
whose region holds the box, from a W^X-boxed state with that core and its counters running: `n` steps reach the same
core, still boxed, the CSRs the monitor set kept and both counters up by `n`; no port is written or read. -/
theorem wx_run_in_box (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region) :
    ∀ (n : Nat) (s : PrivMachine) (c : Machine), WXBoxed s cLo cHi dLo dHi kLo kHi → s.csrs.mcountinhibit = {} →
      run (boxEnv env lo hi) n s.core = .running c →
      (∀ i < n, ∀ m, run (boxEnv env lo hi) i s.core = .running m →
        (decode (fetched m) = some .ecall → m.reg T0 = 1) ∧ WxOk cLo cHi dLo dHi kLo kHi m) →
      (PrivMachine.run env n s).core = c ∧ WXBoxed (PrivMachine.run env n s) cLo cHi dLo dHi kLo kHi ∧
      KeptCsrs s.csrs (PrivMachine.run env n s).csrs ∧
      (PrivMachine.run env n s).csrs.minstret = s.csrs.minstret + BitVec.ofNat 32 n ∧
      (PrivMachine.run env n s).csrs.mcycle = s.csrs.mcycle + BitVec.ofNat 32 n ∧
      (PrivMachine.run env n s).io = s.io ∧ (PrivMachine.run env n s).host = s.host := by
  intro n
  induction n with
  | zero =>
    intro s c hB _ hr _
    simp only [run] at hr
    cases hr
    exact ⟨rfl, hB, KeptCsrs.refl _, by simp [PrivMachine.run], by simp [PrivMachine.run], rfl, rfl⟩
  | succ n ih =>
    intro s c hB hinh hr hq
    simp only [run] at hr
    cases hs : step (boxEnv env lo hi) s.core with
    | halted _ _ => rw [hs] at hr; cases hr
    | fault _ _ => rw [hs] at hr; cases hr
    | running c1 =>
      rw [hs] at hr
      obtain ⟨hq0, hw0⟩ := hq 0 (by omega) s.core rfl
      have hne : decode (fetched s.core) ≠ some .ecall := fun hd => step_not_running hd (hq0 hd) hs
      have hstep := wx_plain env hReg s hB hs hne hw0
      have hk1 : KeptCsrs s.csrs (PrivMachine.step env s).csrs := by rw [hstep]; exact kept_bump _
      have hB1 : WXBoxed (PrivMachine.step env s) cLo cHi dLo dHi kLo kHi :=
        wxboxed_of_kept hB hk1 (by rw [hstep]; exact hB.isUMode) (by rw [hstep]; exact hB.notHalted)
      have hinh1 : (PrivMachine.step env s).csrs.mcountinhibit = {} := by rw [hk1.2.2.2.2.2.2.2]; exact hinh
      have hq1 : ∀ i < n, ∀ m, run (boxEnv env lo hi) i (PrivMachine.step env s).core = .running m →
          (decode (fetched m) = some .ecall → m.reg T0 = 1) ∧ WxOk cLo cHi dLo dHi kLo kHi m := by
        intro i hi m hm
        refine hq (i + 1) (by omega) m ?_
        simp only [run, hs]
        rw [hstep] at hm; exact hm
      obtain ⟨r1, r2, r3, r4, r5, r6, r7⟩ :=
        ih (PrivMachine.step env s) c hB1 hinh1 (by rw [hstep]; exact hr) hq1
      rw [run_succ_step env n s hB.notHalted]
      refine ⟨r1, r2, hk1.trans r3, ?_, ?_, by rw [r6, hstep], by rw [r7, hstep]⟩
      · rw [r4, hstep]
        simp only [bumpCounters, hinh]
        simp only [Bool.false_eq_true, ↓reduceIte, BitVec.ofNat_add]
        bv_omega
      · rw [r5, hstep]
        simp only [bumpCounters, hinh]
        simp only [Bool.false_eq_true, ↓reduceIte, BitVec.ofNat_add]
        bv_omega

/-- **A kernel's HALT in a W^X box is the trap the monitor is proved from.** As `wx_run_in_box`, and the next Tier 1
step halts with `code`, its `ecall` in the code: `n + 1` Tier 2 steps reach the trap vector in M-mode, cause 8, `mepc`
at the `ecall`, the registers and memory the kernel's HALT left, the CSRs the monitor set kept and both counters up
by `n + 1`; no port touched. -/
theorem wx_halt_in_box (env : Env) {lo hi : Nat} (hReg : Region.within ⟨lo, hi⟩ env.region)
    (n : Nat) (s : PrivMachine) {c c' : Machine} {code : Word} (hB : WXBoxed s cLo cHi dLo dHi kLo kHi)
    (hinh : s.csrs.mcountinhibit = {})
    (hr : run (boxEnv env lo hi) n s.core = .running c)
    (hh : run (boxEnv env lo hi) (n + 1) s.core = .halted code c')
    (hq : ∀ i < n, ∀ m, run (boxEnv env lo hi) i s.core = .running m →
      (decode (fetched m) = some .ecall → m.reg T0 = 1) ∧ WxOk cLo cHi dLo dHi kLo kHi m)
    (hc : cLo ≤ c.pc.toNat ∧ c.pc.toNat + 4 ≤ cHi) :
    (PrivMachine.run env (n + 1) s).mode = .M ∧ (PrivMachine.run env (n + 1) s).halted = false ∧
    (PrivMachine.run env (n + 1) s).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
    (∀ r, (PrivMachine.run env (n + 1) s).core.reg r = c.reg r) ∧
    (PrivMachine.run env (n + 1) s).core.mem = c.mem ∧
    c.reg T0 = 1 ∧ c.reg A0 = code ∧ c' = c ∧
    (PrivMachine.run env (n + 1) s).csrs.mcause = CAUSE_ECALL_UMODE ∧
    (PrivMachine.run env (n + 1) s).csrs.mepc = c.pc ∧
    KeptCsrs s.csrs (PrivMachine.run env (n + 1) s).csrs ∧
    (PrivMachine.run env (n + 1) s).csrs.minstret = s.csrs.minstret + BitVec.ofNat 32 (n + 1) ∧
    (PrivMachine.run env (n + 1) s).csrs.mcycle = s.csrs.mcycle + BitVec.ofNat 32 (n + 1) ∧
    (PrivMachine.run env (n + 1) s).io = s.io ∧ (PrivMachine.run env (n + 1) s).host = s.host := by
  have hstep : step (boxEnv env lo hi) c = .halted code c' := by
    rw [run_add_running hr] at hh
    simp only [run] at hh
    revert hh
    cases step (boxEnv env lo hi) c <;> simp
  obtain ⟨hd, h1, h0, hc', -, -⟩ := step_halted hstep
  obtain ⟨r1, r2, r3, r4, r5, r6, r7⟩ := wx_run_in_box env hReg n s c hB hinh hr hq
  rw [PrivMachine.run_add, show PrivMachine.run env 1 (PrivMachine.run env n s) =
    PrivMachine.step env (PrivMachine.run env n s) from run_succ_step env 0 _ r2.notHalted]
  have hd' : decode (fetched (PrivMachine.run env n s).core) = some .ecall := by rw [r1]; exact hd
  rw [wx_ecall_trap env _ r2 hd' (by rw [r1]; exact hc)]
  have hk : KeptCsrs (PrivMachine.run env n s).csrs (raiseTrap (PrivMachine.run env n s) CAUSE_ECALL_UMODE).csrs :=
    kept_trap _ _
  have hinhn : (PrivMachine.run env n s).csrs.mcountinhibit = {} := by rw [r3.2.2.2.2.2.2.2]; exact hinh
  refine ⟨rfl, r2.notHalted, ?_, fun r => ?_, ?_, h1, h0, hc', rfl, by simp [raiseTrap, bumpCounters, r1],
    r3.trans hk, ?_, ?_, by simp [raiseTrap, r6], by simp [raiseTrap, r7]⟩
  · simp only [raiseTrap]; rw [r3.1]
  · simp only [raiseTrap]; rw [r1]; rfl
  · simp only [raiseTrap]; rw [r1]
  · simp only [raiseTrap, bumpCounters, hinhn, Bool.false_eq_true, ↓reduceIte, r4, BitVec.ofNat_add]
    bv_omega
  · simp only [raiseTrap, bumpCounters, hinhn, Bool.false_eq_true, ↓reduceIte, r5, BitVec.ofNat_add]
    bv_omega

/-- **What `Reach` gives a W^X box.** A `Good` state of a kernel whose instructions lie in the code, whose load
window is readable and whose store window is writable, takes a step the box lets through. -/
theorem wxOk_of_good {env : Env} {base : Word} {prog : List Instr} {lw sw : Nat × Nat} {m : Machine}
    (hfit : base.toNat + 0x10000 ≤ 2^32) (hg : Reach.Good env base prog lw sw m)
    (hc : cLo ≤ base.toNat ∧ base.toNat + 4 * prog.length ≤ cHi) (hlen : 4 * prog.length < 0x10000)
    (hl : lw.2 ≤ 0x10000 ∧ ∀ o w, lw.1 ≤ o → o + w ≤ lw.2 → 0 < w →
      WxReadable cLo cHi dLo dHi kLo kHi (base.toNat + o) w)
    (hs : sw.2 ≤ 0x10000 ∧ ∀ o w, sw.1 ≤ o → o + w ≤ sw.2 → 0 < w →
      WxWritable cLo cHi dLo dHi kLo kHi (base.toNat + o) w) :
    WxOk cLo cHi dLo dHi kLo kHi m := by
  obtain ⟨k, hk, hpc, hcode, -, hT, -⟩ := hg
  have hpcn : m.pc.toNat = base.toNat + 4 * k := by rw [hpc]; exact toNat_off hfit _ (by omega)
  have hdec : decode (fetched m) = some prog[k] := by
    simp only [fetched]
    rw [hpc, hcode k hk, BitVec.ofNat_toNat, BitVec.setWidth_eq, decode_encode]
  refine ⟨by omega, ?_⟩
  rw [hdec]
  cases hi : prog[k] with
  | ld op rd r1 imm =>
    rw [hi] at hT
    obtain ⟨o, o1, o2, e⟩ := hT
    have hsz : 0 < op.size := by cases op <;> decide
    dsimp only
    rw [e, toNat_off hfit o (by omega)]
    exact hl.2 o op.size o1 o2 hsz
  | st op r1 r2 imm =>
    rw [hi] at hT
    obtain ⟨o, o1, o2, e⟩ := hT
    have hsz : 0 < op.size := by cases op <;> decide
    dsimp only
    rw [e, toNat_off hfit o (by omega)]
    exact hs.2 o op.size o1 o2 hsz
  | _ => trivial

end

end Rv32.Join

#print axioms Rv32.Join.run_in_box
#print axioms Rv32.Join.halt_in_box
#print axioms Rv32.Join.quiet_of_ct
#print axioms Rv32.Join.calls_of_halted
#print axioms Rv32.Join.step_boxEq
#print axioms Rv32.Join.plain_in_box
#print axioms Rv32.Join.quiet_of_good
#print axioms Rv32.Join.wx_plain
#print axioms Rv32.Join.wx_run_in_box
#print axioms Rv32.Join.wx_halt_in_box
#print axioms Rv32.Join.wxOk_of_good
