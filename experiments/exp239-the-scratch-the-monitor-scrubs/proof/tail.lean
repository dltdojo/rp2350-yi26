/-- The exit code is 0 only for a HALT with `a0 = 0`: a fault, a bad `ecall` and a HALT with any other
    `a0` all exit with something else. -/
theorem exitCode_zero_iff (u : PrivMachine) :
    exitCode u = 0#32 ↔ (u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ u.core.reg 10#5 = 0#32) := by
  unfold exitCode
  by_cases h : u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32
  · simp [h]
  · simp only [h, ite_false]
    constructor
    · intro h1; exact absurd h1 (by decide)
    · intro h2; exact absurd ⟨h2.1, h2.2.1⟩ h

/-- **A failed run leaves no digest.** A fault, an `ecall` that is not HALT, or a HALT with a nonzero `a0` (exp223's
    kernel halts with 1 when a health test fails): the machine parks with the confidential scratch and the digest
    window both zero, and every other byte, bar the monitor's own stack and report words, as the payload left it. -/
theorem monitor_fail_closed_scrub (env : Rv32.Env) (M0 : Word → Byte) (u : PrivMachine)
    (hS : HState env M0 u) (ms : MStatus) (e c m cy : Word)
    (hpc : u.core.pc = 0x80000114#32) (hcs : u.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hfail : ¬ (u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ u.core.reg 10#5 = 0#32)) :
    ∃ N, Parked (PrivMachine.run env N u) (exitCode u) ∧
      Agree M0 (PrivMachine.run env N u).core.mem 0x80000000 624 ∧
      (∀ x, InConf x ∨ InDigest x → (PrivMachine.run env N u).core.mem x = 0) ∧
      (∀ x, ¬ InConf x → ¬ InDigest x → ¬ InStack x → ¬ InPorts x →
        (PrivMachine.run env N u).core.mem x = u.core.mem x) := by
  obtain ⟨N, hP, hA, ⟨hc, hd, ho⟩, _, _⟩ := monitor_scrubs env M0 u hS ms e c m cy hpc hcs
  have hne : exitCode u ≠ 0#32 := fun h => hfail ((exitCode_zero_iff u).mp h)
  refine ⟨N, hP, hA, ?_, ho⟩
  rintro x (hx | hx)
  · exact hc x hx
  · rw [hd x hx]; simp [hne]

/-- **Only a clean HALT keeps its digest.** An `ecall` for HALT with `a0 = 0`: the machine parks with the
    confidential scratch zero, the 32 bytes of the digest window exactly as the payload left them, and every other
    byte, bar the monitor's own stack and report words, as it was. -/
theorem monitor_pass_digest_kept (env : Rv32.Env) (M0 : Word → Byte) (u : PrivMachine)
    (hS : HState env M0 u) (ms : MStatus) (e c m cy : Word)
    (hpc : u.core.pc = 0x80000114#32) (hcs : u.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hpass : u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ u.core.reg 10#5 = 0#32) :
    ∃ N, Parked (PrivMachine.run env N u) 0#32 ∧
      Agree M0 (PrivMachine.run env N u).core.mem 0x80000000 624 ∧
      (∀ x, InConf x → (PrivMachine.run env N u).core.mem x = 0) ∧
      (∀ x, InDigest x → (PrivMachine.run env N u).core.mem x = u.core.mem x) ∧
      (∀ x, ¬ InConf x → ¬ InStack x → ¬ InPorts x →
        (PrivMachine.run env N u).core.mem x = u.core.mem x) := by
  obtain ⟨N, hP, hA, ⟨hc, hd, ho⟩, _, _⟩ := monitor_scrubs env M0 u hS ms e c m cy hpc hcs
  have h0 : exitCode u = 0#32 := (exitCode_zero_iff u).mpr hpass
  rw [h0] at hP hd
  refine ⟨N, hP, hA, hc, fun x hx => by rw [hd x hx]; simp, ?_⟩
  intro x h1 h2 h3
  by_cases hx : InDigest x
  · rw [hd x hx]; simp
  · exact ho x h1 hx h2 h3

/-! ## From reset -/

set_option maxHeartbeats 4000000 in
/-- **The scratch the monitor scrubs.** From reset, the monitor boots (53 steps); the payload then runs for up to
    `n` steps. Either it is still running, in U-mode, boxed in `[0x80010000, 0x80020000)`, and the monitor's words
    are where they were -- or it trapped, and from the trap vector the machine reaches the park loop with the exit
    code `exitCode u`, every other register zero, and memory scrubbed: the confidential scratch zero, the digest
    window zero unless the payload halted with 0, nothing else changed but the monitor's stack and report words; and
    what the host heard of it is `trapIo u`: the report for the way it trapped, then the exit code. -/
theorem monitor_end_to_end (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ (PrivMachine.run env k (PrivMachine.run env 53 s)).mode = .U ∧
        UBoxed (PrivMachine.run env k (PrivMachine.run env 53 s)) 0x80010000 0x80020000 ∧
        Agree M0 (PrivMachine.run env k (PrivMachine.run env 53 s)).core.mem 0x80000000 624) ∨
       (0 < k ∧ ∃ j,
        Parked (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s)))
          (exitCode (PrivMachine.run env k (PrivMachine.run env 53 s))) ∧
        Agree M0 (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.mem 0x80000000 624 ∧
        Scrubbed (exitCode (PrivMachine.run env k (PrivMachine.run env 53 s)))
          (PrivMachine.run env k (PrivMachine.run env 53 s)).core.mem
          (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).core.mem ∧
        (PrivMachine.run env j (PrivMachine.run env k (PrivMachine.run env 53 s))).io =
          (PrivMachine.run env k (PrivMachine.run env 53 s)).io ++ trapIo (PrivMachine.run env k (PrivMachine.run env 53 s)))) := by
  obtain ⟨hbox, hpc1, hcs1, hmem1, hreg1⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  obtain ⟨ms0, e0, c0, m0, cy0, hcs1'⟩ := hcs1
  obtain ⟨s1, hs1⟩ : ∃ t, PrivMachine.run env 53 s = t := ⟨_, rfl⟩
  rw [hs1] at hbox hpc1 hcs1' hmem1 hreg1 ⊢
  obtain ⟨k, hkn, hkept, hhalt, hframe, hres⟩ := umode_run env 0x80010000 0x80020000 (by decide) n s1 hbox
  refine ⟨k, hkn, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s1 = t := ⟨_, rfl⟩
  rw [hu] at hkept hhalt hframe hres ⊢
  have hagree : Agree M0 u.core.mem 0x80000000 624 := by
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
    obtain ⟨N, hP, hA, hSc, _, hio⟩ := monitor_scrubs env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret
      u.csrs.mcycle hpcu hcsu
    exact ⟨N, hP, hA, hSc, hio⟩

end Exp239

#print axioms Exp239.monitorCode_length
#print axioms Exp239.monitor_boot
#print axioms Exp239.zloop_conf
#print axioms Exp239.zloop_dig
#print axioms Exp239.monitor_scrub
#print axioms Exp239.monitor_scrubs
#print axioms Exp239.monitor_fail_closed_scrub
#print axioms Exp239.monitor_pass_digest_kept
#print axioms Exp239.monitor_end_to_end
