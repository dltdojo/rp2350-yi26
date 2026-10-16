
/-! ## What a trap from the payload leaves behind -/

/-- One step of a boxed payload leaves `mstatus` alone, or traps and records that the trap came
    from U-mode: the monitor's `mret` then goes back to U-mode. -/
theorem umode_step_ms (env : Rv32.Env) (s : PrivMachine) (hBox : UBoxed s 0x80010000 0x80020000) :
    ((PrivMachine.step env s).mode = .U ∧ (PrivMachine.step env s).csrs.mstatus = s.csrs.mstatus) ∨
    ((PrivMachine.step env s).mode = .M ∧ (PrivMachine.step env s).csrs.mstatus.mpp = .U) := by
  unfold PrivMachine.step PrivMachine.stepW
  rw [hBox.notHalted]
  simp only [Bool.false_eq_true, ↓reduceIte]
  generalize BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4) = w
  cases hc : uModeTrapCause s w with
  | some cause =>
    right
    simp [raiseTrap, bumpCounters, hBox.isUMode]
  | none =>
    obtain ⟨he, hm, hz, i, hd⟩ := trap_none_plain hBox.isUMode hc
    simp only [hm, hz, Bool.false_eq_true, ↓reduceIte, hd]
    have hne : i ≠ .ecall := by
      intro hi; subst hi; have := decode_ecall hd; rw [he] at this; exact absurd this (by decide)
    cases hx : Rv32.exec env s.core i with
    | halted code c => exact absurd hx (exec_no_halt hne)
    | fault f c =>
      right
      simp [raiseTrap, bumpCounters, hBox.isUMode]
    | running c =>
      left
      simp [bumpCounters, hBox.isUMode]

/-- Any number of steps of a boxed payload, as `umode_run`, and at the trap `mstatus.mpp` is U-mode. -/
theorem umode_run_ms (env : Rv32.Env) :
    ∀ (n : Nat) (s : PrivMachine), UBoxed s 0x80010000 0x80020000 →
      ∃ k, k ≤ n ∧ KeptCsrs s.csrs (PrivMachine.run env k s).csrs ∧
        (PrivMachine.run env k s).halted = false ∧
        (∀ x : Word, ¬ (0x80010000 ≤ x.toNat ∧ x.toNat < 0x80020000) →
          (PrivMachine.run env k s).core.mem x = s.core.mem x) ∧
        ((k = n ∧ (PrivMachine.run env k s).mode = .U ∧
            UBoxed (PrivMachine.run env k s) 0x80010000 0x80020000) ∨
         (0 < k ∧ (PrivMachine.run env k s).mode = .M ∧
          (PrivMachine.run env k s).core.pc = s.csrs.mtvec &&& ~~~3#32 ∧
          (PrivMachine.run env k s).csrs.mstatus.mpp = .U)) := by
  intro n
  induction n with
  | zero =>
    intro s hBox
    exact ⟨0, Nat.le_refl 0, KeptCsrs.refl _, hBox.notHalted, fun _ _ => rfl,
      Or.inl ⟨rfl, hBox.isUMode, hBox⟩⟩
  | succ n ih =>
    intro s hBox
    obtain ⟨hk, hh, hcase⟩ := umode_step env s 0x80010000 0x80020000 hBox (by decide)
    rcases hcase with ⟨hmode, hBox', hmem⟩ | ⟨hmode, hpc, hregs, hmem⟩
    · obtain ⟨k, hkn, hk2, hh2, hmem2, hres⟩ := ih (PrivMachine.step env s) hBox'
      refine ⟨k + 1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env k s hBox.notHalted]; exact hk.trans hk2
      · rw [run_succ_step env k s hBox.notHalted]; exact hh2
      · intro x hx; rw [run_succ_step env k s hBox.notHalted, hmem2 x hx, hmem x hx]
      · rw [run_succ_step env k s hBox.notHalted]
        rcases hres with ⟨hkeq, hm, hb⟩ | ⟨hpos, hm, hpc, hmpp⟩
        · exact Or.inl ⟨by omega, hm, hb⟩
        · exact Or.inr ⟨by omega, hm, by rw [hpc, hk.1], hmpp⟩
    · refine ⟨1, by omega, ?_, ?_, ?_, ?_⟩
      · rw [run_succ_step env 0 s hBox.notHalted]; exact hk
      · rw [run_succ_step env 0 s hBox.notHalted]; exact hh
      · intro x _; rw [run_succ_step env 0 s hBox.notHalted]; show (PrivMachine.step env s).core.mem x = _; rw [hmem]
      · rw [run_succ_step env 0 s hBox.notHalted]
        refine Or.inr ⟨by omega, hmode, hpc, ?_⟩
        rcases umode_step_ms env s hBox with ⟨h1, _⟩ | ⟨_, h2⟩
        · rw [hmode] at h1; exact absurd h1 (by decide)
        · exact h2

theorem uboxed_of_csrsH {t : PrivMachine} {ms : MStatus} {e c m cy sc : Word}
    (h : t.csrs = csrsH ms e c m cy {} sc) (hm : t.mode = .U) (hh : t.halted = false) :
    UBoxed t 0x80010000 0x80020000 := by
  have h5 : t.csrs.pmpcfg0 = 0x1f#32 := by rw [h]; rfl
  have h6 : t.csrs.pmpaddr0 = 0x20005fff#32 := by rw [h]; rfl
  refine ⟨hm, hh, ?_, ?_, ?_, ?_, ?_, ?_⟩
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

/-- A running payload either goes on running for `n` steps, or traps, and the machine stands at the
    trap vector in a state the handler's theorems take. -/
theorem trap_state (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (henv : env.region = monRegion)
    (hR : Running M0 s) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ Running M0 (PrivMachine.run env k s)) ∨
       (0 < k ∧ HState env M0 (PrivMachine.run env k s) ∧
        (PrivMachine.run env k s).core.pc = 0x80000114#32 ∧
        (PrivMachine.run env k s).csrs.mstatus.mpp = .U ∧
        (PrivMachine.run env k s).csrs =
          csrsH (PrivMachine.run env k s).csrs.mstatus (PrivMachine.run env k s).csrs.mepc
            (PrivMachine.run env k s).csrs.mcause (PrivMachine.run env k s).csrs.minstret
            (PrivMachine.run env k s).csrs.mcycle {} 0x80008000#32)) := by
  obtain ⟨hbox, hagree, ms0, e0, c0, m0, cy0, hcs0⟩ := hR
  obtain ⟨k, hkn, hkept, hhalt, hframe, hres⟩ := umode_run_ms env n s hbox
  refine ⟨k, hkn, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s = t := ⟨_, rfl⟩
  rw [hu] at hkept hhalt hframe hres ⊢
  have hag : Agree M0 u.core.mem 0x80000000 800 := by
    intro x h1 h2
    rw [hframe x (by omega)]
    exact hagree x h1 h2
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8, k9⟩ := hkept
  rw [hcs0] at k1 k2 k3 k4 k5 k6 k7 k8 k9
  have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
    csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8 k9
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hpc, hmpp⟩
  · exact Or.inl ⟨hk, hb, hag, _, _, _, _, _, hcsu⟩
  · right
    refine ⟨hpos, ⟨hW, hag, henv, hhalt, hmode⟩, ?_, hmpp, hcsu⟩
    rw [hpc, hcs0]
    show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32
    decide

/-! ## One trap, and what follows it -/

/-- What the monitor did with a call it served, seen from the payload: the registers as they were
    (but `a0` for a `CHECKSIG`), the word after the `ecall`, two instructions on the payload's counter. -/
def Served (u t : PrivMachine) : Prop :=
  u.csrs.mcause = 8#32 ∧ (u.core.reg 5#5 = 2#32 ∨ u.core.reg 5#5 = 3#32) ∧
  t.core.pc = u.csrs.mepc + 4#32 ∧ t.csrs.minstret = u.csrs.minstret + 2#32 ∧
  (∀ r, r ≠ 10#5 → t.core.reg r = u.core.reg r) ∧
  (u.core.reg 5#5 = 2#32 → t.core.reg 10#5 = u.core.reg 10#5) ∧
  Frame u.core.mem t.core.mem

set_option maxHeartbeats 4000000 in
/-- **One trap.** A running payload runs for `n` steps or traps; at the trap the monitor, in the end,
    either parks (a fault: `a0 = 1`; a HALT: `a0` the payload's own exit code) or has served a call and
    stands the payload up again, running, at the word after its `ecall`. -/
theorem monitor_cycle (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (henv : env.region = monRegion)
    (hR : Running M0 s) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ Running M0 (PrivMachine.run env k s)) ∨
       (0 < k ∧ ∃ j,
        Parked (PrivMachine.run env j (PrivMachine.run env k s)) 1#32 ∨
        (Parked (PrivMachine.run env j (PrivMachine.run env k s)) ((PrivMachine.run env k s).core.reg 10#5) ∧
          (PrivMachine.run env k s).csrs.mcause = 8#32 ∧ (PrivMachine.run env k s).core.reg 5#5 = 1#32) ∨
        (Running M0 (PrivMachine.run env j (PrivMachine.run env k s)) ∧
          Served (PrivMachine.run env k s) (PrivMachine.run env j (PrivMachine.run env k s))))) := by
  obtain ⟨k, hkn, hres⟩ := trap_state env M0 s hW henv hR n
  refine ⟨k, hkn, ?_⟩
  rcases hres with hrun | ⟨hpos, hS, hpc, hmpp, hcs⟩
  · exact Or.inl hrun
  right
  refine ⟨hpos, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s = t := ⟨_, rfl⟩
  rw [hu] at hS hpc hmpp hcs ⊢
  by_cases hc : u.csrs.mcause = 8#32
  · by_cases ht1 : u.core.reg 5#5 = 1#32
    · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ :=
        monitor_halt env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpc hcs hc ht1
      exact ⟨_, Or.inr (Or.inl ⟨parked_halt q1 q3 q4 q5 q6 q7 q8 q9 q12, hc, ht1⟩)⟩
    · by_cases ht2 : u.core.reg 5#5 = 2#32
      · by_cases hbox : (0x80010000 ≤ (u.core.reg 10#5).toNat ∧ (u.core.reg 10#5).toNat + (u.core.reg 11#5).toNat ≤ 0x80020000) ∧
            (0x80010000 ≤ (u.core.reg 12#5).toNat ∧ (u.core.reg 12#5).toNat + 32 ≤ 0x80020000)
        · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15⟩ :=
            monitor_hashb_ok env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht2 hbox.1 hbox.2 hmpp
          refine ⟨_, Or.inr (Or.inr ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, hc, Or.inl ht2, q1, ?_, ?_, ?_, q14⟩)⟩
          · rw [q5]; rfl
          · intro r hr; rw [q15 r]; simp [regsUpd]
          · intro _; rw [q15 10#5]; simp [regsUpd]
        · obtain ⟨N, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ :=
            monitor_hashb_oob_fault env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht2 hbox
          exact ⟨N, Or.inl (parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12)⟩
      · by_cases ht3 : u.core.reg 5#5 = 3#32
        · by_cases hbox : (0x80010000 ≤ (u.core.reg 10#5).toNat ∧ (u.core.reg 10#5).toNat + 32 ≤ 0x80020000) ∧
              (0x80010000 ≤ (u.core.reg 11#5).toNat ∧ (u.core.reg 11#5).toNat + 64 ≤ 0x80020000)
          · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15⟩ :=
              monitor_checksig_ok env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
                hpc hcs hc ht3 hbox.1 hbox.2 hmpp
            refine ⟨_, Or.inr (Or.inr ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, hc, Or.inr ht3, q1, ?_, ?_, ?_, q14⟩)⟩
            · rw [q5]; rfl
            · intro r hr
              have hr' : ¬ (10 = r.toNat) := fun h => hr (BitVec.eq_of_toNat_eq (by simpa using h.symm))
              rw [q15 r]; simp [regsUpd, hr']
            · intro h; rw [ht3] at h; exact absurd h (by decide)
          · obtain ⟨N, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ :=
              monitor_checksig_oob_fault env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
                hpc hcs hc ht3 hbox
            exact ⟨N, Or.inl (parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12)⟩
        · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ :=
            monitor_fault_syscall env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht1 ht2 ht3
          exact ⟨_, Or.inl (parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12)⟩
  · obtain ⟨q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12⟩ :=
      monitor_fault_cause env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpc hcs hc
    exact ⟨_, Or.inl (parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12)⟩

/-! ## However many calls the payload makes -/

/-- From a running state, however many calls the payload makes: every trap ends in the park loop or
    in a payload that is running again, `c` times over. -/
def SafeFor (env : Rv32.Env) (M0 : Word → Byte) : Nat → PrivMachine → Prop
  | 0, s => Running M0 s
  | c + 1, s => Running M0 s ∧ ∀ n, ∃ k, k ≤ n ∧
      ((k = n ∧ Running M0 (PrivMachine.run env k s)) ∨
       (0 < k ∧ ∃ j,
        Parked (PrivMachine.run env j (PrivMachine.run env k s)) 1#32 ∨
        (∃ a0, Parked (PrivMachine.run env j (PrivMachine.run env k s)) a0) ∨
        (Running M0 (PrivMachine.run env j (PrivMachine.run env k s)) ∧
          Served (PrivMachine.run env k s) (PrivMachine.run env j (PrivMachine.run env k s)) ∧
          SafeFor env M0 c (PrivMachine.run env j (PrivMachine.run env k s)))))

/-- A running payload is safe for any number of calls. -/
theorem safe_for (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode)
    (henv : env.region = monRegion) :
    ∀ (c : Nat) (s : PrivMachine), Running M0 s → SafeFor env M0 c s := by
  intro c
  induction c with
  | zero => intro s hR; exact hR
  | succ c ih =>
    intro s hR
    refine ⟨hR, fun n => ?_⟩
    obtain ⟨k, hkn, h⟩ := monitor_cycle env M0 s hW henv hR n
    refine ⟨k, hkn, ?_⟩
    rcases h with h | ⟨hpos, j, h⟩
    · exact Or.inl h
    · right
      refine ⟨hpos, j, ?_⟩
      rcases h with h | ⟨h, _⟩ | ⟨hr, hs⟩
      · exact Or.inl h
      · exact Or.inr (Or.inl ⟨_, h⟩)
      · exact Or.inr (Or.inr ⟨hr, hs, ih _ hr⟩)

/-- **The call the monitor checks.** From reset, the monitor boots (53 steps), and then, however many
    calls the payload makes and whatever their arguments: each trap ends with the machine parked
    (a fault, or the payload's HALT), or with the payload running again in U-mode at the word after
    its `ecall`, the box fence and the monitor's words as they were. A call whose ranges are not
    wholly inside the box is a fault, and the service port is as it was. -/
theorem monitor_end_to_end (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion) (c : Nat) :
    SafeFor env M0 c (PrivMachine.run env 53 s) := by
  obtain ⟨hbox, hpc1, ⟨ms0, e0, c0, m0, cy0, hcs1⟩, hmem1, hreg1⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  apply safe_for env M0 hW henv
  exact ⟨hbox, by rw [hmem1]; exact Agree.refl _ _ _, ms0, e0, c0, m0, cy0, hcs1⟩

end Exp238

#print axioms Exp238.monitorCode_length
#print axioms Exp238.monitor_boot
#print axioms Exp238.bounds_ok_iff
#print axioms Exp238.monitor_halt
#print axioms Exp238.monitor_fault_cause
#print axioms Exp238.monitor_fault_syscall
#print axioms Exp238.monitor_hashb_ok
#print axioms Exp238.monitor_hashb_oob_fault
#print axioms Exp238.monitor_checksig_ok
#print axioms Exp238.monitor_checksig_oob_fault
#print axioms Exp238.monitor_cycle
#print axioms Exp238.monitor_end_to_end
