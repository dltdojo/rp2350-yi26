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
      Agree M0 (PrivMachine.run env k s1).core.mem 0x80000000 712 ∧
      ((k = n ∧ (PrivMachine.run env k s1).mode = .U ∧
        WXBoxed (PrivMachine.run env k s1) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000) ∨
       (0 < k ∧ (PrivMachine.run env k s1).mode = .M ∧ HState env M0 (PrivMachine.run env k s1) ∧
        (PrivMachine.run env k s1).core.pc = 0x8000015c#32 ∧
        ∃ ms e c m cy, (PrivMachine.run env k s1).csrs = csrsH ms e c m cy {} 0x80008000#32)) := by
  obtain ⟨k, hkn, hkept, hhalt, hframe, hres⟩ :=
    wx_run env 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 (by decide) (by decide) n s1 hbox
  refine ⟨k, hkn, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s1 = t := ⟨_, rfl⟩
  rw [hu] at hkept hhalt hframe hres ⊢
  have hfroz : ∀ x : Word, WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x →
      u.core.mem x = M0 x := fun x hx => by rw [hframe x hx, hmem1]
  have hagree : Agree M0 u.core.mem 0x80000000 712 := by
    intro x h1 h2
    exact hfroz x (Or.inr ⟨by omega, by omega⟩)
  refine ⟨hfroz, hagree, ?_⟩
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hpc2⟩
  · exact Or.inl ⟨hk, hmode, hb⟩
  · right
    obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := hkept
    rw [hcs1] at k1 k2 k3 k4 k5 k6 k7 k8 hpc2
    have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
      csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8
    have hpcu : u.core.pc = 0x8000015c#32 := by
      rw [hpc2]; show (0x8000015c#32 &&& ~~~3#32) = 0x8000015c#32; decide
    exact ⟨hpos, hmode, ⟨hW, hagree, henv, hhalt, hmode⟩, hpcu, _, _, _, _, _, hcsu⟩

/-- Boot changed only the shrine's eight bytes. -/
theorem shrined_apply (M0 : Word → Byte) (x : Word) (hx : ¬ (0x80008010 ≤ x.toNat ∧ x.toNat < 0x80008018)) :
    shrined M0 x = M0 x := by
  unfold shrined
  rw [writeLE_apply _ _ _ 4 (by decide), writeLE_apply _ _ _ 4 (by decide)]
  have := x.isLt
  have h1 : ¬ (x - 0x80008014#32).toNat < 4 := by
    simp only [BitVec.toNat_sub, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]; omega
  have h2 : ¬ (x - 0x80008010#32).toNat < 4 := by
    simp only [BitVec.toNat_sub, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]; omega
  simp only [h1, h2, ↓reduceIte]

/-- The shrine is two words of the box's outside: the payload cannot write it. -/
theorem shrine_frozen (x : Word) (h : 0x80008010 ≤ x.toNat ∧ x.toNat < 0x80008018) :
    WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x :=
  Or.inr ⟨by omega, by omega⟩

/-- Two memories that agree on the shrine's bytes agree on the seal. -/
theorem sealed_congr {m m' : Word → Byte} (h : ∀ x : Word, 0x80008010 ≤ x.toNat → x.toNat < 0x80008018 → m' x = m x)
    (hs : Sealed m) : Sealed m' := by
  have e : ∀ a : Word, 0x80008010 ≤ a.toNat → a.toNat + 4 ≤ 0x80008018 → readLE m' a 4 = readLE m a 4 := by
    intro a h1 h2
    apply readLE_four_congr
    intro d hd
    apply h <;> simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod] <;> omega
  unfold Sealed at *
  rw [e 0x80008010#32 (by decide) (by decide), e 0x80008014#32 (by decide) (by decide)]
  exact hs

/-! ## [Charm 1] The shrine seal -/

/-- **[Charm 1] Boot enshrines the seal.** Whatever memory held there, after boot the shrine reads "OMAMKUAI". -/
theorem shrine_set_at_boot (M0 : Word → Byte) : Sealed (shrined M0) := by
  unfold Sealed shrined
  rw [readLE_writeLE_far _ _ _ _ (by decide) (by decide) (by decide), readLE_writeLE_self, readLE_writeLE_self]
  decide

set_option maxHeartbeats 4000000 in
/-- **From reset.** From reset -- or from any CSRs that lock no PMP entry -- the monitor boots (71 steps) and the payload
    runs for up to `n` steps. Either it is still running, in U-mode, boxed by the three entries, the monitor's words
    where they were and the code, `[0x80010000, 0x80010080)`, the bytes it started with -- or it trapped, the seal
    intact, and the monitor takes `trapSteps` steps to the park loop with the exit code `exitCode u`, every other
    register zero, the slot zero and every other byte of memory but the monitor's stack and report words as the
    payload left it -- the code among them, still the bytes it started with -- and the host has heard `trapIo u`. -/
theorem monitor_end_to_end (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hlock : PmpUnlocked s.csrs.pmpcfg0) (henv : env.region = monRegion) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ (payloadAt env s k).mode = .U ∧
        WXBoxed (payloadAt env s k) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
        Agree M0 (payloadAt env s k).core.mem 0x80000000 712 ∧
        CodeSame M0 (payloadAt env s k).core.mem) ∨
       (0 < k ∧
        Sealed (payloadAt env s k).core.mem ∧
        Parked (parkedAfter env (payloadAt env s k)) (exitCode (payloadAt env s k)) ∧
        Agree M0 (parkedAfter env (payloadAt env s k)).core.mem 0x80000000 712 ∧
        CodeSame M0 (parkedAfter env (payloadAt env s k)).core.mem ∧
        SlotFrame (payloadAt env s k).core.mem (parkedAfter env (payloadAt env s k)).core.mem ∧
        (parkedAfter env (payloadAt env s k)).io = (payloadAt env s k).io ++ trapIo (payloadAt env s k))) := by
  obtain ⟨hbox, hpc1, hcsb, hmem1, hreg1, -, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hlock henv
  have hA1 := agree_shrined M0
  have hW1 : WordsAt (shrined M0) 0x80000000#32 monitorCode :=
    WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact hA1) hW
  obtain ⟨k, hkn, hfroz, hagree, hres⟩ := payload_runs env (shrined M0) _ hW1 hmem1 henv hcsb hbox n
  have hagree0 : ∀ m : Word → Byte, Agree (shrined M0) m 0x80000000 712 → Agree M0 m 0x80000000 712 :=
    fun m h x h1 h2 => (h x h1 h2).trans (hA1 x h1 h2)
  have hcode : ∀ x : Word, 0x80010000 ≤ x.toNat → x.toNat < 0x80010080 →
      (PrivMachine.run env k (PrivMachine.run env 71 s)).core.mem x = M0 x := fun x h1 h2 => by
    rw [hfroz x (Or.inl ⟨h1, h2⟩), shrined_apply M0 x (by omega)]
  refine ⟨k, hkn, ?_⟩
  unfold payloadAt parkedAfter
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hS, hpcu, ms, e, c, m, cy, hcsu⟩
  · exact Or.inl ⟨hk, hmode, hb, hagree0 _ hagree, hcode⟩
  · right
    have hseal : Sealed (PrivMachine.run env k (PrivMachine.run env 71 s)).core.mem := by
      apply sealed_congr _ (shrine_set_at_boot M0)
      intro x h1 h2
      exact hfroz x (shrine_frozen x ⟨h1, h2⟩)
    obtain ⟨hP, hA, hF, -, -, hio⟩ := monitor_traps env (shrined M0) _ hS ms e c m cy hpcu hcsu
    refine ⟨hpos, hseal, hP, hagree0 _ hA, ?_, hF, hio⟩
    intro x h1 h2
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    have hl : ¬ InSlot x := by unfold InSlot; omega
    rw [hF.2 x hs hp hl]
    exact hcode x h1 h2

/-! ## Round after round -/

/-- A reset, as weak as one can be: the core starts again at the reset vector, in M-mode, with nothing running; the
    registers, the CSRs and memory are whatever they were. A reset that also resets the CSRs is one of these. -/
def resetOf (p : PrivMachine) : PrivMachine :=
  { p with core := { p.core with pc := 0x80000040#32 }, mode := .M, halted := false }

/-- What a round needs of the machine it starts from, and nothing else: the monitor's words in memory, the code region
    as it was loaded (`C`), no PMP entry locked, and the region Tier 1 lets M-mode touch. -/
structure Ready (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) : Prop where
  words    : WordsAt p.core.mem 0x80000000#32 monitorCode
  code     : CodeSame C p.core.mem
  unlocked : PmpUnlocked p.csrs.pmpcfg0
  region   : env.region = monRegion

/-- `k` steps into a payload, `k > 0`, is its first trap: M-mode, and every step before was U-mode. -/
def Trapped (env : Rv32.Env) (s : PrivMachine) (k : Nat) : Prop :=
  0 < k ∧ (PrivMachine.run env k s).mode = .M ∧ ∀ i, i < k → (PrivMachine.run env i s).mode = .U

/-- One round, from `p` to `q`: reset, boot, the payload runs to its first trap, and the monitor takes it to the park loop. -/
def Round (env : Rv32.Env) (p q : PrivMachine) : Prop :=
  ∃ k, Trapped env (PrivMachine.run env 71 (resetOf p)) k ∧ q = parkedAfter env (payloadAt env (resetOf p) k)

/-- What the host may do between rounds: anything at all to the machine -- its registers, its CSRs, its memory, the
    shrine among it -- but write the monitor's words or the code, or lock a PMP entry. -/
def HostWrite (p q : PrivMachine) : Prop :=
  PmpUnlocked q.csrs.pmpcfg0 ∧
    ∀ x : Word, (0x80000000 ≤ x.toNat ∧ x.toNat < 0x80000000 + 712) ∨ (0x80010000 ≤ x.toNat ∧ x.toNat < 0x80010080) →
      q.core.mem x = p.core.mem x

/-- Any number of rounds, and between any two of them, any number of the host's writes. -/
inductive Rounds (env : Rv32.Env) : PrivMachine → PrivMachine → Prop
  | refl (p : PrivMachine) : Rounds env p p
  | step {p q r : PrivMachine} : Round env p q → Rounds env q r → Rounds env p r
  | host {p q r : PrivMachine} : HostWrite p q → Rounds env q r → Rounds env p r

/-- **The host's write leaves the machine ready.** -/
theorem ready_of_host (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (hR : Ready env C p)
    (h : HostWrite p q) : Ready env C q := by
  obtain ⟨hl, hm⟩ := h
  refine ⟨?_, ?_, hl, hR.region⟩
  · have hA : Agree p.core.mem q.core.mem 0x80000000 712 := fun x h1 h2 => hm x (Or.inl ⟨h1, h2⟩)
    exact WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact hA) hR.words
  · intro x h1 h2
    rw [hm x (Or.inr ⟨h1, h2⟩)]
    exact hR.code x h1 h2

/-- **Boot does not depend on what came before.** From any machine that is `Ready`, a reset and 71 steps leave exactly
    the machine `monitor_boot` describes: boxed by the three entries, the CSR file `csrsBooted`, `sp` at the top of the
    stack entry, every other register zero, memory as it was but for the shrine, written again. -/
theorem monitor_reentry (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p) :
    WXBoxed (PrivMachine.run env 71 (resetOf p)) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
    (PrivMachine.run env 71 (resetOf p)).csrs = csrsBooted ∧
    (PrivMachine.run env 71 (resetOf p)).core.pc = 0x80010000#32 ∧
    (PrivMachine.run env 71 (resetOf p)).core.mem = shrined p.core.mem ∧
    (∀ r, (PrivMachine.run env 71 (resetOf p)).core.reg r = if r = 2 then 0x80020000#32 else 0#32) := by
  obtain ⟨hbox, hpc1, hcsb, hmem1, hreg1, -, -⟩ :=
    monitor_boot env p.core.mem (resetOf p) hR.words rfl rfl rfl rfl hR.unlocked hR.region
  exact ⟨hbox, hcsb, hpc1, hmem1, hreg1⟩

/-- A round's first trap, from a `Ready` machine: the payload's state there is the one `payload_runs` describes. -/
theorem round_trap (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p) (k : Nat)
    (hk : Trapped env (PrivMachine.run env 71 (resetOf p)) k) :
    (∀ x : Word, WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x →
      (payloadAt env (resetOf p) k).core.mem x = shrined p.core.mem x) ∧
    HState env (shrined p.core.mem) (payloadAt env (resetOf p) k) ∧
    (payloadAt env (resetOf p) k).core.pc = 0x8000015c#32 ∧
    ∃ ms e c m cy, (payloadAt env (resetOf p) k).csrs = csrsH ms e c m cy {} 0x80008000#32 := by
  obtain ⟨hk0, hkM, hkU⟩ := hk
  obtain ⟨hbox, hcsb, hpc1, hmem1, hreg1⟩ := monitor_reentry env C p hR
  have hW1 : WordsAt (shrined p.core.mem) 0x80000000#32 monitorCode :=
    WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact agree_shrined _) hR.words
  obtain ⟨k', hk'k, hfroz, hagree, hres⟩ := payload_runs env (shrined p.core.mem) _ hW1 hmem1 hR.region hcsb hbox k
  -- the first trap is `k`: a shorter run that trapped would have been in M-mode before `k`
  have hkk : k' = k := by
    rcases hres with ⟨h1, h2, _⟩ | ⟨h1, h2, _⟩
    · exfalso
      have : (PrivMachine.run env k' (PrivMachine.run env 71 (resetOf p))).mode = .M := by rw [h1]; exact hkM
      rw [h2] at this
      exact absurd this (by decide)
    · by_cases hne : k' = k
      · exact hne
      · exfalso
        have := hkU k' (by omega)
        rw [h2] at this
        exact absurd this (by decide)
  subst hkk
  rcases hres with ⟨_, h2, _⟩ | ⟨hpos, hmode, hS, hpcu, hcs⟩
  · exfalso
    rw [h2] at hkM
    exact absurd hkM (by decide)
  · exact ⟨hfroz, hS, hpcu, hcs⟩

/-- **A round leaves the machine ready for the next.** -/
theorem monitor_round_ready (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (hR : Ready env C p)
    (hq : Round env p q) : Ready env C q ∧ ∃ a, Parked q a := by
  obtain ⟨k, hk, hq⟩ := hq
  obtain ⟨hfroz, hS, hpcu, ms, e, c, m, cy, hcsu⟩ := round_trap env C p hR k hk
  obtain ⟨hP, hA, hF, hC, -, -⟩ := monitor_traps env (shrined p.core.mem) _ hS ms e c m cy hpcu hcsu
  rw [hq]
  unfold parkedAfter
  have hAp : Agree p.core.mem (PrivMachine.run env (trapSteps (payloadAt env (resetOf p) k))
      (payloadAt env (resetOf p) k)).core.mem 0x80000000 712 :=
    fun x h1 h2 => (hA x h1 h2).trans (agree_shrined _ x h1 h2)
  refine ⟨⟨?_, ?_, ?_, hR.region⟩, _, hP⟩
  · exact WordsAt.of_agree (by rw [monitorCode_length]; decide) (by rw [monitorCode_length]; exact hAp) hR.words
  · intro x h1 h2
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    have hl : ¬ InSlot x := by unfold InSlot; omega
    rw [hF.2 x hs hp hl, hfroz x (Or.inl ⟨h1, h2⟩), shrined_apply _ x (by omega)]
    exact hR.code x h1 h2
  · rw [hC]; intro i; revert i; decide

/-- **Any number of rounds.** From a `Ready` machine, after any number of rounds and of the host's writes between them,
    the machine is `Ready` again. -/
theorem monitor_rounds (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (h : Rounds env p q)
    (hR : Ready env C p) : Ready env C q := by
  induction h with
  | refl => exact hR
  | step hr _ ih => exact ih (monitor_round_ready env C _ _ hR hr).1
  | host hw _ ih => exact ih (ready_of_host env C _ _ hR hw)

/-- **[Charm 1] A HALT requires the seal.** From the trap vector, whatever the machine -- reachable or not -- an `ecall`
    with `t0 = 1` is reported as a HALT with the payload's `a0` exactly when the seal is intact, and as a fault with
    exit code 1 when it is not. -/
theorem halt_requires_shrine (env : Rv32.Env) (M0 : Word → Byte) (u : PrivMachine)
    (hS : HState env M0 u) (ms : MStatus) (e c m cy : Word)
    (hpc : u.core.pc = 0x8000015c#32) (hcs : u.csrs = csrsH ms e c m cy {} 0x80008000#32)
    (hc : c = 8#32) (ht0 : u.core.reg 5#5 = 1#32) :
    (Sealed u.core.mem →
      (parkedAfter env u).io = u.io ++ haltIo u ++ [⟨0xc0000008#32, u.core.reg 10#5⟩] ∧
      (parkedAfter env u).core.reg 10#5 = u.core.reg 10#5) ∧
    (¬ Sealed u.core.mem →
      (parkedAfter env u).io = u.io ++ faultIo u ++ [⟨0xc0000008#32, 1#32⟩] ∧
      (parkedAfter env u).core.reg 10#5 = 1#32) := by
  obtain ⟨hP, -, -, -, -, hio⟩ := monitor_traps env M0 u hS ms e c m cy hpc hcs
  have hcu : u.csrs.mcause = 8#32 := by rw [hcs, hc]; rfl
  unfold parkedAfter
  refine ⟨fun hs => ⟨?_, ?_⟩, fun hs => ⟨?_, ?_⟩⟩
  · rw [hio]; simp [trapIo, exitCode, hcu, ht0, hs]
  · rw [hP.2.2.2.2.2.2.1]; simp [exitCode, hcu, ht0, hs]
  · rw [hio]; simp [trapIo, exitCode, hcu, ht0, hs]
  · rw [hP.2.2.2.2.2.2.1]; simp [exitCode, hcu, ht0, hs]

/-- **[Charm 1, exposed] The seal is always intact.** In every round from a `Ready` machine, at the payload's first
    trap the seal reads "OMAMKUAI": the shrine is outside the data and the stack, so the payload cannot write it, and
    boot wrote it again -- whatever the host wrote there between the rounds. The half of `halt_requires_shrine` about
    a broken seal is about no state a round reaches. -/
theorem shrine_always_intact (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p) (k : Nat)
    (hk : Trapped env (PrivMachine.run env 71 (resetOf p)) k) :
    Sealed (payloadAt env (resetOf p) k).core.mem := by
  obtain ⟨hfroz, -⟩ := round_trap env C p hR k hk
  apply sealed_congr _ (shrine_set_at_boot p.core.mem)
  intro x h1 h2
  exact hfroz x (shrine_frozen x ⟨h1, h2⟩)

/-- **[Charm 1, exposed] So the check changes no exit code a round reaches**: it is exp240's, the payload's `a0` for
    an `ecall` with `t0 = 1` and 1 for the rest, whatever the seal's words would be compared with. -/
theorem shrine_changes_nothing (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p) (k : Nat)
    (hk : Trapped env (PrivMachine.run env 71 (resetOf p)) k) :
    exitCode (payloadAt env (resetOf p) k) =
      if (payloadAt env (resetOf p) k).csrs.mcause = 8#32 ∧ (payloadAt env (resetOf p) k).core.reg 5#5 = 1#32
      then (payloadAt env (resetOf p) k).core.reg 10#5 else 1#32 := by
  have hs := shrine_always_intact env C p hR k hk
  unfold exitCode
  simp [hs]

/-! ## [Charm 2] The shadowed entry -/

/-- **[Charm 2] Boot configures the seed entry.** After boot, entry 3 is NAPOT, read-only, over the seed window
    `[0x80010100, 0x80010200)`. -/
theorem seed_entry_configured :
    decodePmpCfgByte csrsBooted.pmpcfg0 3 = { r := true, w := false, x := false, mode := .NAPOT, lock := false } ∧
    decodeNapotRange csrsBooted.pmpaddr3 = (0x80010100, 0x80010200) := by
  refine ⟨by decide, ?_⟩
  simp [csrsBooted, csrsH, decodeNapotRange, countTrailingOnes32, countTrailingOnes32.loop]

/-- **[Charm 2] Entry 3 forbids a store into the seed window.** Every access wholly inside the window is a full match
    of entry 3, and entry 3 does not let U-mode store. -/
theorem entry3_forbids_seed_store (addr : Word) (w : Nat) (hw : 0 < w)
    (h1 : 0x80010100 ≤ addr.toNat) (h2 : addr.toNat + w ≤ 0x80010200) :
    ∃ cfg, matchPmpEntry csrsBooted 3 addr w = .FullMatch cfg ∧ hasPermission cfg .U .Store = false := by
  obtain ⟨hc, hr⟩ := seed_entry_configured
  refine ⟨decodePmpCfgByte csrsBooted.pmpcfg0 3, ?_, by rw [hc]; decide⟩
  rw [matchPmpEntry_napot csrsBooted 3 addr w 0x80010100 0x80010200 _ rfl (by rw [hc]) hr]
  have hn : ¬ (addr.toNat + w ≤ 0x80010100 ∨ 0x80010200 ≤ addr.toNat) := by omega
  simp [hn, h1, h2]

/-- **[Charm 2, exposed] And the store goes in.** From reset, a U-mode store of a word at any aligned address of the
    seed window passes the PMP: entry 1, the data, is tried first and decides (`pmpCheck_shadowed`), and the data may
    be written (`wx_store_allowed_data`). -/
theorem seed_store_allowed (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hlock : PmpUnlocked s.csrs.pmpcfg0) (henv : env.region = monRegion) (a : Word)
    (h1 : 0x80010100 ≤ a.toNat) (h2 : a.toNat + 4 ≤ 0x80010200) :
    pmpCheck (PrivMachine.run env 71 s).csrs (PrivMachine.run env 71 s).mode a 4 .Store = true := by
  obtain ⟨hbox, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hlock henv
  exact wx_store_allowed_data hbox a 4 (Or.inr (by omega)) ⟨by omega, by omega⟩ (by decide)

/-! ## [Charm 3] The ceremonial scrub -/

/-- **[Charm 3] Every exit zeroes the slot.** From the trap vector, whatever the payload did: at the park loop the
    slot's 32 bytes are zero, and every other byte but the monitor's stack and report words is as the payload left it. -/
theorem slot_zeroed_on_exit (env : Rv32.Env) (M0 : Word → Byte) (u : PrivMachine)
    (hS : HState env M0 u) (ms : MStatus) (e c m cy : Word)
    (hpc : u.core.pc = 0x8000015c#32) (hcs : u.csrs = csrsH ms e c m cy {} 0x80008000#32) :
    (∀ x, InSlot x → (parkedAfter env u).core.mem x = 0) ∧
    (∀ x, ¬ InStack x → ¬ InPorts x → ¬ InSlot x → (parkedAfter env u).core.mem x = u.core.mem x) :=
  (monitor_traps env M0 u hS ms e c m cy hpc hcs).2.2.1

/-- **[Charm 3, exposed] What the payload leaves on its stack reaches the next round.** After a round, a reset and
    boot, the next payload starts with the bytes `[0x8001ffc0, 0x8001ffe0)` of its stack as the last payload left them
    at its trap: neither the scrub nor boot touches them. -/
theorem stack_reaches_next_round (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (hR : Ready env C p)
    (hq : Round env p q) :
    ∃ k, Trapped env (PrivMachine.run env 71 (resetOf p)) k ∧ q = parkedAfter env (payloadAt env (resetOf p) k) ∧
      ∀ x : Word, 0x8001ffc0 ≤ x.toNat → x.toNat < 0x8001ffe0 →
        (PrivMachine.run env 71 (resetOf q)).core.mem x = (payloadAt env (resetOf p) k).core.mem x := by
  have hRq := (monitor_round_ready env C p q hR hq).1
  obtain ⟨k, hk, hqk⟩ := hq
  refine ⟨k, hk, hqk, ?_⟩
  intro x h1 h2
  obtain ⟨-, hS, hpcu, ms, e, c, m, cy, hcsu⟩ := round_trap env C p hR k hk
  have hF := slot_zeroed_on_exit env (shrined p.core.mem) _ hS ms e c m cy hpcu hcsu
  obtain ⟨-, -, -, hmem, -⟩ := monitor_reentry env C q hRq
  have hs : ¬ InStack x := by unfold InStack; omega
  have hp : ¬ InPorts x := by unfold InPorts; omega
  have hl : ¬ InSlot x := by unfold InSlot; omega
  rw [hmem, shrined_apply _ x (by omega), hqk]
  exact hF.2 x hs hp hl

end Exp245

#print axioms Exp245.monitorCode_length
#print axioms Exp245.monitor_boot
#print axioms Exp245.monitor_traps
#print axioms Exp245.payload_runs
#print axioms Exp245.monitor_end_to_end
#print axioms Exp245.ready_of_host
#print axioms Exp245.monitor_reentry
#print axioms Exp245.monitor_round_ready
#print axioms Exp245.monitor_rounds
#print axioms Exp245.shrine_set_at_boot
#print axioms Exp245.halt_requires_shrine
#print axioms Exp245.shrine_always_intact
#print axioms Exp245.shrine_changes_nothing
#print axioms Exp245.seed_entry_configured
#print axioms Exp245.entry3_forbids_seed_store
#print axioms Exp245.seed_store_allowed
#print axioms Rv32.Priv.pmpCheck_shadowed
#print axioms Exp245.slot_zeroed_on_exit
#print axioms Exp245.stack_reaches_next_round
#print axioms Rv32.Priv.wx_store_allowed_data
#print axioms Rv32.Priv.wx_run
#print axioms Rv32.Priv.wx_code_immutable
