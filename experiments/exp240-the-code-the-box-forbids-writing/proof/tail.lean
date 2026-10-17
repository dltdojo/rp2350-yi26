/-! ## The payload runs, and traps -/

/-- The payload is in the box: it runs up to its first trap. Its writes land in the data and the stack only, the code
    is not among them, and the monitor's words stay where they were; at the trap the machine is in M-mode at the trap
    vector, with the CSRs boot set and `HState` true, so that the handler's theorems apply. -/
theorem payload_runs (env : Rv32.Env) (M0 : Word → Byte) (s1 : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem1 : s1.core.mem = M0) (henv : env.region = monRegion)
    (hcs1 : s1.csrs = csrsBooted)
    (hbox : WXBoxed s1 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000) (n : Nat) :
    ∃ k, k ≤ n ∧
      (∀ x : Word, WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x →
        (PrivMachine.run env k s1).core.mem x = M0 x) ∧
      Agree M0 (PrivMachine.run env k s1).core.mem 0x80000000 600 ∧
      ((k = n ∧ (PrivMachine.run env k s1).mode = .U ∧
        WXBoxed (PrivMachine.run env k s1) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000) ∨
       (0 < k ∧ (PrivMachine.run env k s1).mode = .M ∧ HState env M0 (PrivMachine.run env k s1) ∧
        (PrivMachine.run env k s1).core.pc = 0x80000130#32 ∧
        ∃ ms e c m cy, (PrivMachine.run env k s1).csrs = csrsH ms e c m cy {} 0x80008000#32)) := by
  obtain ⟨k, hkn, hkept, hhalt, hframe, hres⟩ :=
    wx_run env 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 (by decide) (by decide) n s1 hbox
  refine ⟨k, hkn, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s1 = t := ⟨_, rfl⟩
  rw [hu] at hkept hhalt hframe hres ⊢
  have hfroz : ∀ x : Word, WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x →
      u.core.mem x = M0 x := fun x hx => by rw [hframe x hx, hmem1]
  have hagree : Agree M0 u.core.mem 0x80000000 600 := by
    intro x h1 h2
    exact hfroz x (Or.inr ⟨by omega, by omega⟩)
  refine ⟨hfroz, hagree, ?_⟩
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hpc2⟩
  · exact Or.inl ⟨hk, hmode, hb⟩
  · right
    obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8, k9⟩ := hkept
    rw [hcs1] at k1 k2 k3 k4 k5 k6 k7 k8 k9 hpc2
    have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
      csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8 k9
    have hpcu : u.core.pc = 0x80000130#32 := by
      rw [hpc2]; show (0x80000130#32 &&& ~~~3#32) = 0x80000130#32; decide
    exact ⟨hpos, hmode, ⟨hW, hagree, henv, hhalt, hmode⟩, hpcu, _, _, _, _, _, hcsu⟩

set_option maxHeartbeats 4000000 in
/-- **The code the box forbids writing.** From reset, the monitor boots (60 steps) and the payload runs for up to `n`
    steps. Either it is still running, in U-mode, boxed by the three entries, the monitor's words where they were and
    the code, `[0x80010000, 0x80010080)`, **the bytes it started with** -- or it trapped, and the monitor takes
    `trapSteps` steps to the park loop with the exit code `exitCode u` (the payload's own `a0` for a HALT, 1 for the
    rest), every other register zero, and every byte of memory but the monitor's stack and report words as the payload
    left it -- the code among them, still the bytes it started with. -/
theorem monitor_end_to_end (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ (payloadAt env s k).mode = .U ∧
        WXBoxed (payloadAt env s k) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
        Agree M0 (payloadAt env s k).core.mem 0x80000000 600 ∧
        CodeSame M0 (payloadAt env s k).core.mem) ∨
       (0 < k ∧
        Parked (parkedAfter env (payloadAt env s k)) (exitCode (payloadAt env s k)) ∧
        Agree M0 (parkedAfter env (payloadAt env s k)).core.mem 0x80000000 600 ∧
        CodeSame M0 (parkedAfter env (payloadAt env s k)).core.mem ∧
        FrameSP (payloadAt env s k).core.mem (parkedAfter env (payloadAt env s k)).core.mem)) := by
  obtain ⟨hbox, hpc1, hcsb, hmem1, hreg1⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  obtain ⟨k, hkn, hfroz, hagree, hres⟩ := payload_runs env M0 _ hW hmem1 henv hcsb hbox n
  refine ⟨k, hkn, ?_⟩
  unfold payloadAt parkedAfter
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hS, hpcu, ms, e, c, m, cy, hcsu⟩
  · exact Or.inl ⟨hk, hmode, hb, hagree, fun x h1 h2 => hfroz x (Or.inl ⟨h1, h2⟩)⟩
  · right
    obtain ⟨hP, hA, hF⟩ := monitor_traps env M0 _ hS ms e c m cy hpcu hcsu
    refine ⟨hpos, hP, hA, ?_, hF⟩
    intro x h1 h2
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    rw [hF x hs hp]
    exact hfroz x (Or.inl ⟨h1, h2⟩)

/-! ## Round after round -/

/-- A hardware reset: the core starts again at the reset vector, in M-mode, with the CSRs at their reset values and
    nothing running; the registers and memory are whatever they were. -/
def resetOf (p : PrivMachine) : PrivMachine :=
  { core := { p.core with pc := 0x80000040#32 }, mode := .M, csrs := {}, halted := false }

/-- What a round needs of the machine it starts from, and nothing else: the monitor's words in memory, the code region
    as it was loaded (`C`), and the region Tier 1 lets M-mode touch. The registers and the CSRs are not in it. -/
structure Ready (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) : Prop where
  words  : WordsAt p.core.mem 0x80000000#32 monitorCode
  code   : CodeSame C p.core.mem
  region : env.region = monRegion

/-- `k` steps into a payload, `k > 0`, is its first trap: M-mode, and every step before was U-mode. -/
def Trapped (env : Rv32.Env) (s : PrivMachine) (k : Nat) : Prop :=
  0 < k ∧ (PrivMachine.run env k s).mode = .M ∧ ∀ i, i < k → (PrivMachine.run env i s).mode = .U

/-- One round, from `p` to `q`: reset, boot, the payload runs to its first trap, and the monitor takes it to the park loop. -/
def Round (env : Rv32.Env) (p q : PrivMachine) : Prop :=
  ∃ k, Trapped env (PrivMachine.run env 60 (resetOf p)) k ∧ q = parkedAfter env (payloadAt env (resetOf p) k)

/-- Any number of rounds. -/
inductive Rounds (env : Rv32.Env) : PrivMachine → PrivMachine → Prop
  | refl (p : PrivMachine) : Rounds env p p
  | step {p q r : PrivMachine} : Round env p q → Rounds env q r → Rounds env p r

/-- **Boot does not depend on what came before.** From any machine that is `Ready` -- whatever its registers, its
    CSRs, its privilege, its `pc`, and whatever is in memory outside the monitor's words -- a reset and 60 steps leave
    exactly the machine `monitor_boot` describes: boxed by the three entries, the CSR file `csrsBooted` (counters at 2,
    `mstatus`, `mepc`, the trap vector, the PMP -- all constants), `sp` at the top of the stack entry, every other
    register zero, memory untouched. Nothing a round leaves behind reaches the next. -/
theorem monitor_reentry (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p) :
    WXBoxed (PrivMachine.run env 60 (resetOf p)) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
    (PrivMachine.run env 60 (resetOf p)).csrs = csrsBooted ∧
    (PrivMachine.run env 60 (resetOf p)).core.pc = 0x80010000#32 ∧
    (PrivMachine.run env 60 (resetOf p)).core.mem = p.core.mem ∧
    (∀ r, (PrivMachine.run env 60 (resetOf p)).core.reg r = if r = 2 then 0x80020000#32 else 0#32) := by
  obtain ⟨hbox, hpc1, hcsb, hmem1, hreg1⟩ :=
    monitor_boot env p.core.mem (resetOf p) hR.words rfl rfl rfl rfl rfl
  exact ⟨hbox, hcsb, hpc1, hmem1, hreg1⟩

/-- **A round leaves the machine ready for the next.** If `p` is `Ready` and `q` is where a round from `p` ends, `q` is
    parked -- every register but `a0` zero, `mscratch` and the saved words zero -- and `Ready` again, with the code
    region the bytes it was. -/
theorem monitor_round_ready (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (hR : Ready env C p)
    (hq : Round env p q) : Ready env C q ∧ ∃ a, Parked q a := by
  obtain ⟨k, ⟨hk0, hkM, hkU⟩, hq⟩ := hq
  obtain ⟨hbox, hcsb, hpc1, hmem1, hreg1⟩ := monitor_reentry env C p hR
  obtain ⟨k', hk'k, hfroz, hagree, hres⟩ :=
    payload_runs env p.core.mem _ hR.words hmem1 hR.region hcsb hbox k
  -- the first trap is `k`: a shorter run that trapped would have been in M-mode before `k`
  have hkk : k' = k := by
    rcases hres with ⟨h1, h2, _⟩ | ⟨h1, h2, _⟩
    · exfalso
      have : (PrivMachine.run env k' (PrivMachine.run env 60 (resetOf p))).mode = .M := by rw [h1]; exact hkM
      rw [h2] at this
      exact absurd this (by decide)
    · by_cases hne : k' = k
      · exact hne
      · exfalso
        have := hkU k' (by omega)
        rw [h2] at this
        exact absurd this (by decide)
  subst hkk
  rcases hres with ⟨_, h2, _⟩ | ⟨hpos, hmode, hS, hpcu, ms, e, c, m, cy, hcsu⟩
  · exfalso
    rw [h2] at hkM
    exact absurd hkM (by decide)
  · obtain ⟨hP, hA, hF⟩ := monitor_traps env p.core.mem _ hS ms e c m cy hpcu hcsu
    rw [hq]
    unfold parkedAfter payloadAt
    refine ⟨⟨?_, ?_, hR.region⟩, _, hP⟩
    · exact WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact hA) hR.words
    · intro x h1 h2
      have hs : ¬ InStack x := by unfold InStack; omega
      have hp : ¬ InPorts x := by unfold InPorts; omega
      rw [hF x hs hp, hfroz x (Or.inl ⟨h1, h2⟩)]
      exact hR.code x h1 h2

/-- **Any number of rounds.** From a `Ready` machine, after any number of rounds, the machine is `Ready` again -- the
    monitor's words in place and the code region the bytes it was loaded with -- and so a reset and boot start the
    next round exactly as `monitor_reentry` says. -/
theorem monitor_rounds (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (h : Rounds env p q)
    (hR : Ready env C p) : Ready env C q := by
  induction h with
  | refl => exact hR
  | step hr _ ih => exact ih (monitor_round_ready env C _ _ hR hr).1

end Exp240

#print axioms Exp240.monitorCode_length
#print axioms Exp240.monitor_boot
#print axioms Exp240.monitor_halt
#print axioms Exp240.monitor_fault_cause
#print axioms Exp240.monitor_fault_syscall
#print axioms Exp240.monitor_traps
#print axioms Exp240.payload_runs
#print axioms Exp240.monitor_end_to_end
#print axioms Exp240.monitor_reentry
#print axioms Exp240.monitor_round_ready
#print axioms Exp240.monitor_rounds
#print axioms Rv32.Priv.wx_fetch_iff
#print axioms Rv32.Priv.wx_store_ok
#print axioms Rv32.Priv.wx_load_ok
#print axioms Rv32.Priv.pmpCheck_M_outside_in
#print axioms Rv32.Priv.wx_step
#print axioms Rv32.Priv.wx_run
#print axioms Rv32.Priv.wx_code_immutable
#print axioms Rv32.Priv.wx_no_write_exec
