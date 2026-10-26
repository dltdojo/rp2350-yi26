
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
  have hag : Agree M0 u.core.mem 0x80000000 808 := by
    intro x h1 h2
    rw [hframe x (by omega)]
    exact hagree x h1 h2
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := hkept
  rw [hcs0] at k1 k2 k3 k4 k5 k6 k7 k8
  have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
    csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8
  rcases hres with ⟨hk, hmode, hb⟩ | ⟨hpos, hmode, hpc, hmpp⟩
  · exact Or.inl ⟨hk, hb, hag, _, _, _, _, _, hcsu⟩
  · right
    refine ⟨hpos, ⟨hW, hag, henv, hhalt, hmode⟩, ?_, hmpp, hcsu⟩
    rw [hpc, hcs0]
    show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32
    decide

/-! ## One trap, and what follows it -/

/-- `[a, a + n)` lies wholly in the payload's box, the sum taken in the naturals. -/
def InBox (a : Word) (n : Nat) : Prop := 0x80010000 ≤ a.toNat ∧ a.toNat + n ≤ 0x80020000

/-- The ranges a call names, as the payload left its registers at the trap. -/
def CallBoxed (u : PrivMachine) : Prop :=
  (u.core.reg 5#5 = 2#32 → InBox (u.core.reg 10#5) (u.core.reg 11#5).toNat ∧ InBox (u.core.reg 12#5) 32) ∧
  (u.core.reg 5#5 = 3#32 → InBox (u.core.reg 10#5) 32 ∧ InBox (u.core.reg 11#5) 64)

/-- An `ecall` for `HASHB` or `CHECKSIG` with a range that is not wholly in the box. -/
def OutOfBox (u : PrivMachine) : Prop :=
  u.csrs.mcause = 8#32 ∧
  ((u.core.reg 5#5 = 2#32 ∧ ¬ (InBox (u.core.reg 10#5) (u.core.reg 11#5).toNat ∧ InBox (u.core.reg 12#5) 32)) ∨
   (u.core.reg 5#5 = 3#32 ∧ ¬ (InBox (u.core.reg 10#5) 32 ∧ InBox (u.core.reg 11#5) 64)))

/-! ## The calls served: the request, and what the host does with it

A `HASHB`'s request is the one store after which the host writes: 32 bytes of its own, `digest`, at the
output word's address. The theorems before this point cover the monitor's own words; this one step, and
the runs it joins, carry what the host wrote. -/

/-- A byte outside the box is not one a write of 32 bytes inside it reaches. -/
theorem writeBytes_box_far {m : Word → Byte} {a : Word} {f : Fin 32 → Byte} {x : Word}
    (ha : InBox a 32) (hx : x.toNat < 0x80010000 ∨ 0x80020000 ≤ x.toNat) : writeBytes m a f x = m x := by
  have h1 := x.isLt
  have h2 := a.isLt
  have : ¬ (x - a).toNat < 32 := by
    rw [BitVec.toNat_sub]; unfold InBox at ha; omega
  simp only [writeBytes, this, dite_false]

/-- Two memories the same but for the monitor's stack and the ports stay so under one write of 32 bytes. -/
theorem Frame.writeBytes {m m' : Word → Byte} (a : Word) (f : Fin 32 → Byte) (h : Frame m m') :
    Frame (Rv32.writeBytes m a f) (Rv32.writeBytes m' a f) := by
  intro x i p v
  simp only [Rv32.writeBytes]
  split
  · rfl
  · exact h x i p v

/-- The request word written, and nothing else. -/
theorem frame_req {m : Word → Byte} (a : Word) (f : Fin 32 → Byte) (v : Nat) :
    Frame (Rv32.writeBytes m a f) (Rv32.writeBytes (writeLE m 0xc000001c#32 v 4) a f) := by
  intro x i p sv
  simp only [Rv32.writeBytes]
  split
  · rfl
  · have : ¬ (x - 0xc000001c#32).toNat < 4 := by
      have := x.isLt
      rw [BitVec.toNat_sub]; simp only [InSvc, BitVec.toNat_ofNat] at sv ⊢; omega
    rw [writeLE4_apply]; simp only [this, ↓reduceIte]

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
/-- **The request.** `sw t0, 12(t3)` with `t0 = 2` and `t3` the service port: the request word holds 2, the
    host has heard it, and the 32 bytes at the output word's address are the host's `digest` of what it
    was told and of memory as it was. -/
theorem hashb_req (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word) (p : Word)
    (hpc : s.core.pc = 0x800001d8#32) (hcs : s.csrs = csrsH ms e c m cy { cy := true, ir := true } (p))
    (ht3 : s.core.reg 28#5 = 0xc0000010#32) (ht0 : s.core.reg 5#5 = 2#32) :
    (PrivMachine.run env 1 s).core.pc = 0x800001dc#32 ∧
    (PrivMachine.run env 1 s).halted = false ∧
    (PrivMachine.run env 1 s).mode = .M ∧
    (PrivMachine.run env 1 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (p) ∧
    (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).digest = s.digest ∧
    (PrivMachine.run env 1 s).io = s.io ++ [⟨0xc000001c#32, 2#32⟩] ∧
    (PrivMachine.run env 1 s).core.mem = Rv32.writeBytes (writeLE s.core.mem 0xc000001c#32 2 4)
      (BitVec.ofNat 32 (readLE s.core.mem 0xc0000018#32 4)) (s.digest (s.io ++ [⟨0xc000001c#32, 2#32⟩]) s.core.mem) ∧
    (∀ r, (PrivMachine.run env 1 s).core.reg r = s.core.reg r) := by
  obtain ⟨hW, hA, henv, hh, hm⟩ := hS
  obtain ⟨Mc, hmem⟩ : ∃ Mc, s.core.mem = Mc := ⟨_, rfl⟩
  have hA' : Agree M0 Mc 0x80000000 808 := hmem ▸ hA
  have sm : ∀ t : PrivMachine, Agree M0 t.core.mem 0x80000000 808 →
      (t.core.pc - 0x80000000#32).toNat / 4 < monitorCode.length →
      (t.core.pc - 0x80000000#32).toNat % 4 = 0 →
      PrivMachine.step env t =
        PrivMachine.stepW env t (monitorCode.getD ((t.core.pc - 0x80000000#32).toNat / 4) 0) :=
    fun t ht h1 h2 => step_mon hW ht h1 h2
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimpH [pmpCheck_mon, sm, hmem, hA', henv, monRegion, agree_writeLE_iff, hpc, monitorCode, hh, hm, hcs, csrsH,
    csrsFixed, csrsConfigured, ht3, ht0] at hF
  subst hF
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  all_goals try psimpH [pmpCheck_mon, hpc, hmem, csrsH, csrsFixed, csrsConfigured, regsUpd, ht3, ht0]

/-- A word outside the box is not one a write of 32 bytes inside it reaches. -/
theorem readLE_box_far {m : Word → Byte} {a : Word} {f : Fin 32 → Byte} {b : Word} (ha : InBox a 32)
    (hb : b.toNat + 4 ≤ 0x80010000 ∨ (0x80020000 ≤ b.toNat ∧ b.toNat + 4 ≤ 4294967296)) :
    readLE (Rv32.writeBytes m a f) b 4 = readLE m b 4 := by
  apply readLE_four_congr
  intro d hd
  apply writeBytes_box_far ha
  have : (b + BitVec.ofNat 32 d).toNat = b.toNat + d := by
    have := b.isLt
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow]; omega
  omega

/-- The request word's neighbours, and words below the box, are not the request word. -/
theorem readLE_req_far (m : Word → Byte) (v : Nat) {b : Word} (hb : b.toNat + 4 ≤ 0xc000001c) :
    readLE (writeLE m 0xc000001c#32 v 4) b 4 = readLE m b 4 :=
  readLE_writeLE_far _ _ _ _ (Or.inl (by simp only [BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]; omega))
    (by omega) (by decide)

set_option maxHeartbeats 4000000 in
/-- **A `HASHB` whose ranges lie in the box.** From the trap vector the call is forwarded exactly as the
    payload gave it, and the machine is back in the payload at the word after the `ecall`: the payload's
    registers as they were, the counters released and moved on by two. Memory is what the payload left,
    with the host's 32 bytes at the output pointer: its `digest` of the four words it heard and of memory as
    it was at the request -- which, outside the monitor's stack and the ports, is the payload's. -/
theorem monitor_hashb_ok (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} (0x80008000#32)) (hc : c = 8#32)
    (ht0 : s.core.reg 5#5 = 2#32)
    (hin : 0x80010000 ≤ (s.core.reg 10#5).toNat ∧ (s.core.reg 10#5).toNat + (s.core.reg 11#5).toNat ≤ 0x80020000)
    (hout : 0x80010000 ≤ (s.core.reg 12#5).toNat ∧ (s.core.reg 12#5).toNat + 32 ≤ 0x80020000) (hmpp : ms.mpp = .U) :
    (PrivMachine.run env 43 s).core.pc = e + 4#32 ∧
    Agree M0 (PrivMachine.run env 43 s).core.mem 0x80000000 808 ∧
    (PrivMachine.run env 43 s).halted = false ∧
    (PrivMachine.run env 43 s).mode = .U ∧
    (PrivMachine.run env 43 s).csrs =
      csrsH { mie := ms.mpie, mpie := true, mpp := .U } (e + 4#32) c (m + 2#32) (cy + 2#32) {} (0x80008000#32) ∧
    (PrivMachine.run env 43 s).host = s.host ∧
    (PrivMachine.run env 43 s).io = s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc0000018#32, s.core.reg 12#5⟩, ⟨0xc000001c#32, 2#32⟩] ∧
    readLE (PrivMachine.run env 43 s).core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0x80008004#32 4 = (s.core.reg 6#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0x80008008#32 4 = (s.core.reg 7#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0x8000800c#32 4 = (s.core.reg 28#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0xc0000010#32 4 = (s.core.reg 10#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0xc0000014#32 4 = (s.core.reg 11#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0xc0000018#32 4 = (s.core.reg 12#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 43 s).core.mem 0xc000001c#32 4 = 2 ∧
    Frame s.core.mem (PrivMachine.run env 31 s).core.mem ∧
    Frame (Rv32.writeBytes s.core.mem (s.core.reg 12#5)
        (s.digest (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
          ⟨0xc0000018#32, s.core.reg 12#5⟩, ⟨0xc000001c#32, 2#32⟩]) (PrivMachine.run env 31 s).core.mem))
      (PrivMachine.run env 43 s).core.mem ∧
    (∀ r, (PrivMachine.run env 43 s).core.reg r = regsUpd s.core.reg [] r) := by
  obtain ⟨p1, a1, h1, m1, c1, ho1, io1, w1_0, w1_1, w1_2, w1_3, sv1_0, sv1_1, sv1_2, sv1_3, fr1, r1⟩ :=
    monitor_hashb_ask env M0 s hS ms e c m cy hpc hcs hc ht0 hin hout
  have dg1 := (run_host_digest env 31 s).2
  obtain ⟨v, hv⟩ : ∃ t, PrivMachine.run env 31 s = t := ⟨_, rfl⟩
  rw [hv] at p1 a1 h1 m1 c1 ho1 io1 w1_0 w1_1 w1_2 w1_3 sv1_0 sv1_1 sv1_2 sv1_3 fr1 r1 dg1 ⊢
  have v28 : v.core.reg 28#5 = 0xc0000010#32 := by rw [r1]; simp [regsUpd]
  have v5 : v.core.reg 5#5 = 2#32 := by rw [r1]; simp [regsUpd]
  have v2 : v.core.reg 2#5 = 0x80008000#32 := by rw [r1]; simp [regsUpd]
  have hS1 := hS.next a1 h1 m1
  obtain ⟨p2, h2, m2, c2, ho2, -, io2, mem2, r2⟩ := hashb_req env M0 v hS1 ms e c m cy (s.core.reg 2#5) p1 c1 v28 v5
  obtain ⟨w, hw⟩ : ∃ t, PrivMachine.run env 1 v = t := ⟨_, rfl⟩
  rw [hw] at p2 h2 m2 c2 ho2 io2 mem2 r2
  have hdst : BitVec.ofNat 32 (readLE v.core.mem 0xc0000018#32 4) = s.core.reg 12#5 := by
    rw [sv1_2]; exact ofNat_toNat_mod _
  rw [hdst, dg1, io1] at mem2
  simp only [List.append_assoc, List.cons_append, List.nil_append] at mem2
  generalize hD : s.digest (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
    ⟨0xc0000018#32, s.core.reg 12#5⟩, ⟨0xc000001c#32, 2#32⟩]) v.core.mem = D at mem2 ⊢
  have aw : Agree M0 w.core.mem 0x80000000 808 := by
    intro x hx1 hx2
    have : ¬ (x - 0xc000001c#32).toNat < 4 := by
      have := x.isLt
      rw [BitVec.toNat_sub]; simp only [BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]; omega
    rw [mem2, writeBytes_box_far hout (by omega), writeLE4_apply]; simp only [this, ↓reduceIte]
    exact a1 x hx1 hx2
  have ws : ∀ b : Word, b.toNat + 4 ≤ 0x80010000 → readLE w.core.mem b 4 = readLE v.core.mem b 4 := by
    intro b hb
    rw [mem2, readLE_box_far hout (Or.inl hb), readLE_req_far _ _ (by omega)]
  have wsv : ∀ b : Word, 0x80020000 ≤ b.toNat → b.toNat + 4 ≤ 0xc000001c →
      readLE w.core.mem b 4 = readLE v.core.mem b 4 := by
    intro b hb1 hb2
    rw [mem2, readLE_box_far hout (Or.inr ⟨hb1, by omega⟩), readLE_req_far _ _ hb2]
  have wreq : readLE w.core.mem 0xc000001c#32 4 = 2 := by
    rw [mem2, readLE_box_far hout (Or.inr ⟨by decide, by decide⟩), readLE_writeLE_self]
  have ww0 : readLE w.core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 := by
    rw [ws _ (by decide), w1_0]
  have ww1 : readLE w.core.mem 0x80008004#32 4 = (s.core.reg 6#5).toNat % 4294967296 := by
    rw [ws _ (by decide), w1_1]
  have ww2 : readLE w.core.mem 0x80008008#32 4 = (s.core.reg 7#5).toNat % 4294967296 := by
    rw [ws _ (by decide), w1_2]
  have ww3 : readLE w.core.mem 0x8000800c#32 4 = (s.core.reg 28#5).toNat % 4294967296 := by
    rw [ws _ (by decide), w1_3]
  have w2 : w.core.reg 2#5 = 0x80008000#32 := by rw [r2]; exact v2
  obtain ⟨p3, a3, h3, m3, c3, ho3, io3, w3_0, w3_1, w3_2, w3_3, sv3, fr3, r3⟩ :=
    hashb_back env M0 w (hS1.next aw h2 m2) ms e c m cy (s.core.reg 2#5) p2 c2 w2 hmpp
  obtain ⟨t, ht⟩ : ∃ t, PrivMachine.run env 11 w = t := ⟨_, rfl⟩
  rw [ht] at p3 a3 h3 m3 c3 ho3 io3 w3_0 w3_1 w3_2 w3_3 sv3 fr3 r3
  have hall : PrivMachine.run env 43 s = t := run_two hv (run_two hw ht)
  rw [hall]
  have fw : Frame (Rv32.writeBytes v.core.mem (s.core.reg 12#5) D) w.core.mem := by
    rw [mem2]; exact frame_req _ _ 2
  refine ⟨p3, a3, h3, m3, c3, ho3.trans (ho2.trans ho1), ?_, by rw [w3_0, ww0], by rw [w3_1, ww1], by rw [w3_2, ww2],
    by rw [w3_3, ww3], ?_, ?_, ?_, ?_, fr1, ((Frame.writeBytes _ _ fr1).trans fw).trans fr3, ?_⟩
  · rw [io3, io2, io1]; simp
  · rw [SvcSame.read sv3 _ (by decide), wsv _ (by decide) (by decide), sv1_0]
  · rw [SvcSame.read sv3 _ (by decide), wsv _ (by decide) (by decide), sv1_1]
  · rw [SvcSame.read sv3 _ (by decide), wsv _ (by decide) (by decide), sv1_2]
  · rw [SvcSame.read sv3 _ (by decide), wreq]
  · intro r
    rw [r3 r]
    rcases reg32 r with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [regsUpd, r2, r1, ww0, ww1, ww2, ww3, ofNat_toNat_mod]

set_option maxHeartbeats 4000000 in
/-- **A `CHECKSIG` whose ranges lie in the box, answered 0 or 1.** From the trap vector the call is forwarded
    exactly as the payload gave it, and the machine is back in the payload at the word after the `ecall`: the
    payload's registers as they were but `a0`, which holds what the host answered -- given the three words it
    heard and memory as it was when it was asked -- the counters released and moved on by two. -/
theorem monitor_checksig_ok (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} (0x80008000#32)) (hc : c = 8#32)
    (ht0 : s.core.reg 5#5 = 3#32)
    (hkey : 0x80010000 ≤ (s.core.reg 10#5).toNat ∧ (s.core.reg 10#5).toNat + 32 ≤ 0x80020000)
    (hsig : 0x80010000 ≤ (s.core.reg 11#5).toNat ∧ (s.core.reg 11#5).toNat + 64 ≤ 0x80020000) (hmpp : ms.mpp = .U)
    (hans : BitVec.ult 1#32 (s.host (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩]) (PrivMachine.run env 34 s).core.mem 0xc000001c#32) = false) :
    (PrivMachine.run env 47 s).core.pc = e + 4#32 ∧
    Agree M0 (PrivMachine.run env 47 s).core.mem 0x80000000 808 ∧
    (PrivMachine.run env 47 s).halted = false ∧
    (PrivMachine.run env 47 s).mode = .U ∧
    (PrivMachine.run env 47 s).csrs =
      csrsH { mie := ms.mpie, mpie := true, mpp := .U } (e + 4#32) c (m + 2#32) (cy + 2#32) {} (0x80008000#32) ∧
    (PrivMachine.run env 47 s).host = s.host ∧
    (PrivMachine.run env 47 s).io = s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩] ∧
    readLE (PrivMachine.run env 47 s).core.mem 0x80008000#32 4 = (s.core.reg 5#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0x80008004#32 4 = (s.core.reg 6#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0x80008008#32 4 = (s.core.reg 7#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0x8000800c#32 4 = (s.core.reg 28#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0xc0000010#32 4 = (s.core.reg 10#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0xc0000014#32 4 = (s.core.reg 11#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0xc0000018#32 4 = readLE s.core.mem 0xc0000018#32 4 ∧
    readLE (PrivMachine.run env 47 s).core.mem 0xc000001c#32 4 = 3 ∧
    Frame s.core.mem (PrivMachine.run env 34 s).core.mem ∧
    Frame s.core.mem (PrivMachine.run env 47 s).core.mem ∧
    (∀ r, (PrivMachine.run env 47 s).core.reg r = regsUpd s.core.reg [(10, s.host (s.io ++
      [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩, ⟨0xc000001c#32, 3#32⟩])
      (PrivMachine.run env 34 s).core.mem 0xc000001c#32)] r) := by
  obtain ⟨p1, a1, h1, m1, c1, ho1, io1, w1_0, w1_1, w1_2, w1_3, sv1_0, sv1_1, sv1_2, sv1_3, fr1, r1⟩ :=
    monitor_checksig_ask env M0 s hS ms e c m cy hpc hcs hc ht0 hkey hsig
  obtain ⟨v, hv⟩ : ∃ t, PrivMachine.run env 34 s = t := ⟨_, rfl⟩
  rw [hv] at p1 a1 h1 m1 c1 ho1 io1 w1_0 w1_1 w1_2 w1_3 sv1_0 sv1_1 sv1_2 sv1_3 fr1 r1 hans ⊢
  have v28 : v.core.reg 28#5 = 0xc0000010#32 := by rw [r1]; simp [regsUpd]
  have hS1 := hS.next a1 h1 m1
  obtain ⟨p2, a2, h2, m2, c2, ho2, io2, w2_0, w2_1, w2_2, w2_3, sv2, fr2, r2⟩ :=
    checksig_fwd_4 env M0 v hS1 ms e c m cy (s.core.reg 2#5) p1 c1 v28
  obtain ⟨w, hw⟩ : ∃ t, PrivMachine.run env 1 v = t := ⟨_, rfl⟩
  rw [hw] at p2 a2 h2 m2 c2 ho2 io2 w2_0 w2_1 w2_2 w2_3 sv2 fr2 r2
  have w10 : w.core.reg 10#5 = s.host (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩]) v.core.mem 0xc000001c#32 := by
    rw [r2]; simp [regsUpd, ho1, io1]
  have w2 : w.core.reg 2#5 = 0x80008000#32 := by rw [r2]; simp [regsUpd, r1]
  obtain ⟨p3, a3, h3, m3, c3, ho3, io3, w3_0, w3_1, w3_2, w3_3, sv3, fr3, r3⟩ :=
    checksig_back_ok env M0 w (hS1.next a2 h2 m2) ms e c m cy (s.core.reg 2#5) p2 c2 w2 hmpp (by rw [w10]; exact hans)
  obtain ⟨t, ht⟩ : ∃ t, PrivMachine.run env 12 w = t := ⟨_, rfl⟩
  rw [ht] at p3 a3 h3 m3 c3 ho3 io3 w3_0 w3_1 w3_2 w3_3 sv3 fr3 r3
  have hall : PrivMachine.run env 47 s = t := run_two hv (run_two hw ht)
  rw [hall]
  refine ⟨p3, a3, h3, m3, c3, ho3.trans (ho2.trans ho1), by rw [io3, io2, io1], by rw [w3_0, w2_0, w1_0],
    by rw [w3_1, w2_1, w1_1], by rw [w3_2, w2_2, w1_2], by rw [w3_3, w2_3, w1_3],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_0],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_1],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_2],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_3], fr1, fr1.trans (fr2.trans fr3), ?_⟩
  intro r
  rw [r3 r]
  rcases reg32 r with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [regsUpd, r2, r1, w2_0, w2_1, w2_2, w2_3, w1_0, w1_1, w1_2, w1_3, ofNat_toNat_mod, ho1, io1]

set_option maxHeartbeats 4000000 in
/-- **A `CHECKSIG` answered neither 0 nor 1 is refused.** The request went out; then the machine parks with
    `a0 = 1`, every other register zero, the host having heard the call and then the fault report. -/
theorem monitor_checksig_bad_answer (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hS : HState env M0 s) (ms : MStatus) (e c m cy : Word)
    (hpc : s.core.pc = 0x80000114#32) (hcs : s.csrs = csrsH ms e c m cy {} (0x80008000#32)) (hc : c = 8#32)
    (ht0 : s.core.reg 5#5 = 3#32)
    (hkey : 0x80010000 ≤ (s.core.reg 10#5).toNat ∧ (s.core.reg 10#5).toNat + 32 ≤ 0x80020000)
    (hsig : 0x80010000 ≤ (s.core.reg 11#5).toNat ∧ (s.core.reg 11#5).toNat + 64 ≤ 0x80020000)
    (hans : BitVec.ult 1#32 (s.host (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩]) (PrivMachine.run env 34 s).core.mem 0xc000001c#32) = true) :
    (PrivMachine.run env 91 s).core.pc = 0x80000320#32 ∧
    Agree M0 (PrivMachine.run env 91 s).core.mem 0x80000000 808 ∧
    (PrivMachine.run env 91 s).halted = false ∧
    (PrivMachine.run env 91 s).mode = .M ∧
    (PrivMachine.run env 91 s).csrs = csrsH ms e c m cy { cy := true, ir := true } (0#32) ∧
    (PrivMachine.run env 91 s).host = s.host ∧
    (PrivMachine.run env 91 s).io = s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩, ⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, c⟩, ⟨0xc0000004#32, e⟩,
      ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, m⟩, ⟨0xc0000008#32, 1#32⟩] ∧
    readLE (PrivMachine.run env 91 s).core.mem 0x80008000#32 4 = 0 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0x80008004#32 4 = 0 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0x80008008#32 4 = 0 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0x8000800c#32 4 = 0 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0xc0000010#32 4 = (s.core.reg 10#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0xc0000014#32 4 = (s.core.reg 11#5).toNat % 4294967296 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0xc0000018#32 4 = readLE s.core.mem 0xc0000018#32 4 ∧
    readLE (PrivMachine.run env 91 s).core.mem 0xc000001c#32 4 = 3 ∧
    Frame s.core.mem (PrivMachine.run env 34 s).core.mem ∧
    Frame s.core.mem (PrivMachine.run env 91 s).core.mem ∧
    (∀ r, (PrivMachine.run env 91 s).core.reg r = regsUpd s.core.reg [(1, 0#32), (2, 0#32), (3, 0#32), (4, 0#32), (5, 0#32), (6, 0#32), (7, 0#32), (8, 0#32), (9, 0#32), (11, 0#32), (12, 0#32), (13, 0#32), (14, 0#32), (15, 0#32), (16, 0#32), (17, 0#32), (18, 0#32), (19, 0#32), (20, 0#32), (21, 0#32), (22, 0#32), (23, 0#32), (24, 0#32), (25, 0#32), (26, 0#32), (27, 0#32), (28, 0#32), (29, 0#32), (30, 0#32), (31, 0#32), (10, 1#32)] r) := by
  obtain ⟨p1, a1, h1, m1, c1, ho1, io1, w1_0, w1_1, w1_2, w1_3, sv1_0, sv1_1, sv1_2, sv1_3, fr1, r1⟩ :=
    monitor_checksig_ask env M0 s hS ms e c m cy hpc hcs hc ht0 hkey hsig
  obtain ⟨v, hv⟩ : ∃ t, PrivMachine.run env 34 s = t := ⟨_, rfl⟩
  rw [hv] at p1 a1 h1 m1 c1 ho1 io1 w1_0 w1_1 w1_2 w1_3 sv1_0 sv1_1 sv1_2 sv1_3 fr1 r1 hans ⊢
  have v28 : v.core.reg 28#5 = 0xc0000010#32 := by rw [r1]; simp [regsUpd]
  have hS1 := hS.next a1 h1 m1
  obtain ⟨p2, a2, h2, m2, c2, ho2, io2, w2_0, w2_1, w2_2, w2_3, sv2, fr2, r2⟩ :=
    checksig_fwd_4 env M0 v hS1 ms e c m cy (s.core.reg 2#5) p1 c1 v28
  obtain ⟨w, hw⟩ : ∃ t, PrivMachine.run env 1 v = t := ⟨_, rfl⟩
  rw [hw] at p2 a2 h2 m2 c2 ho2 io2 w2_0 w2_1 w2_2 w2_3 sv2 fr2 r2
  have w10 : w.core.reg 10#5 = s.host (s.io ++ [⟨0xc0000010#32, s.core.reg 10#5⟩, ⟨0xc0000014#32, s.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩]) v.core.mem 0xc000001c#32 := by
    rw [r2]; simp [regsUpd, ho1, io1]
  have w2 : w.core.reg 2#5 = 0x80008000#32 := by rw [r2]; simp [regsUpd, r1]
  obtain ⟨p3, a3, h3, m3, c3, ho3, io3, w3_0, w3_1, w3_2, w3_3, sv3, fr3, r3⟩ :=
    checksig_back_bad env M0 w (hS1.next a2 h2 m2) ms e c m cy (s.core.reg 2#5) p2 c2 w2 (by rw [w10]; exact hans)
  obtain ⟨t, ht⟩ : ∃ t, PrivMachine.run env 56 w = t := ⟨_, rfl⟩
  rw [ht] at p3 a3 h3 m3 c3 ho3 io3 w3_0 w3_1 w3_2 w3_3 sv3 fr3 r3
  have hall : PrivMachine.run env 91 s = t := run_two hv (run_two hw ht)
  rw [hall]
  refine ⟨p3, a3, h3, m3, c3, ho3.trans (ho2.trans ho1), by rw [io3, io2, io1]; simp, w3_0, w3_1, w3_2, w3_3,
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_0],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_1],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_2],
    by rw [SvcSame.read sv3 _ (by decide), SvcSame.read sv2 _ (by decide), sv1_3], fr1, fr1.trans (fr2.trans fr3), ?_⟩
  intro r
  rw [r3 r]
  rcases reg32 r with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> simp [regsUpd]

/-! ## What the monitor tells the host -/

/-- A fault, as the host hears it: the report to the print word — the tag, `mcause`, `mepc`, `mtval` and
    `minstret` — then exit code 1. `mtval` is 0: Hazard3 hardwires it to 0. -/
def faultIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, u.csrs.mcause⟩, ⟨0xc0000004#32, u.csrs.mepc⟩,
   ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, u.csrs.minstret⟩, ⟨0xc0000008#32, 1#32⟩]

/-- A HALT, as the host hears it: the tag, the payload's `a0`, `minstret` and `mcycle`, then `a0` as the exit code. -/
def haltIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, u.core.reg 10#5⟩, ⟨0xc0000004#32, u.csrs.minstret⟩,
   ⟨0xc0000004#32, u.csrs.mcycle⟩, ⟨0xc0000008#32, u.core.reg 10#5⟩]

/-- A call, as the host hears it: the arguments, then the call number, whose write is the request. -/
def callIo (u : PrivMachine) : List IoEvent :=
  if u.core.reg 5#5 = 2#32 then
    [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩, ⟨0xc0000018#32, u.core.reg 12#5⟩,
     ⟨0xc000001c#32, 2#32⟩]
  else
    [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩, ⟨0xc000001c#32, 3#32⟩]

/-- What the monitor did with a call it served, seen from the payload: the call's ranges were in the box,
    the host was asked exactly the payload's arguments and call number, and the payload has its registers
    as they were (but `a0` for a `CHECKSIG`, which is what the host answered, and 0 or 1), the word after its
    `ecall`, two instructions on the counter; the host heard the call and nothing else. And memory: `M` is
    memory as the host saw it when it was asked, the payload's but for the monitor's stack and the ports;
    after a `HASHB` the payload's memory holds the host's 32 bytes at the output pointer, its `digest` of what
    it heard and of `M`, and nothing else has changed; after a `CHECKSIG` nothing has. -/
def Served (u t : PrivMachine) : Prop :=
  u.csrs.mcause = 8#32 ∧ (u.core.reg 5#5 = 2#32 ∨ u.core.reg 5#5 = 3#32) ∧ CallBoxed u ∧
  readLE t.core.mem 0xc0000010#32 4 = (u.core.reg 10#5).toNat % 4294967296 ∧
  readLE t.core.mem 0xc0000014#32 4 = (u.core.reg 11#5).toNat % 4294967296 ∧
  readLE t.core.mem 0xc000001c#32 4 = (u.core.reg 5#5).toNat ∧
  t.core.pc = u.csrs.mepc + 4#32 ∧ t.csrs.minstret = u.csrs.minstret + 2#32 ∧
  (∀ r, r ≠ 10#5 → t.core.reg r = u.core.reg r) ∧
  (u.core.reg 5#5 = 2#32 → t.core.reg 10#5 = u.core.reg 10#5) ∧
  t.io = u.io ++ callIo u ∧
  ∃ M, Frame u.core.mem M ∧
    (u.core.reg 5#5 = 2#32 →
      Frame (Rv32.writeBytes u.core.mem (u.core.reg 12#5) (u.digest (u.io ++ callIo u) M)) t.core.mem) ∧
    (u.core.reg 5#5 = 3#32 → Frame u.core.mem t.core.mem ∧ t.core.reg 10#5 = u.host t.io M 0xc000001c#32 ∧
      (t.core.reg 10#5 = 0#32 ∨ t.core.reg 10#5 = 1#32))

/-- What a host answers a `CHECKSIG` that `u` asks for, the call having gone out, seeing memory `M`. -/
def answer (u : PrivMachine) (M : Word → Byte) : Word := u.host (u.io ++ callIo u) M 0xc000001c#32

/-- The four ways a trap can end: a fault (parked, `a0 = 1`, the service port as it was, the fault
    reported), the payload's own HALT (parked, `a0` its exit code, the HALT reported), a served call
    (the payload running again), or a `CHECKSIG` whose answer was neither 0 nor 1 (parked, `a0 = 1`,
    the call and then the fault reported). -/
def Ends (M0 : Word → Byte) (u t : PrivMachine) : Prop :=
  (Parked t 1#32 ∧ SvcSame u.core.mem t.core.mem ∧ t.io = u.io ++ faultIo u) ∨
  (Parked t (u.core.reg 10#5) ∧ u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ t.io = u.io ++ haltIo u) ∨
  (Running M0 t ∧ Served u t) ∨
  (Parked t 1#32 ∧ u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 3#32 ∧ CallBoxed u ∧
    (∃ M, Frame u.core.mem M ∧ BitVec.ult 1#32 (answer u M) = true) ∧ t.io = u.io ++ callIo u ++ faultIo u)

/-- A call with a range out of the box can only have ended the first way. -/
theorem ends_refuses {M0 : Word → Byte} {u t : PrivMachine} (h : Ends M0 u t) (ho : OutOfBox u) :
    Parked t 1#32 ∧ SvcSame u.core.mem t.core.mem := by
  obtain ⟨hc8, hcall⟩ := ho
  rcases h with hf | ⟨_, _, ht1, _⟩ | ⟨_, _, _, hboxed, _⟩ | ⟨_, _, ht3, hboxed, _⟩
  · exact ⟨hf.1, hf.2.1⟩
  · rcases hcall with ⟨h2, _⟩ | ⟨h3, _⟩
    · rw [ht1] at h2; exact absurd h2 (by decide)
    · rw [ht1] at h3; exact absurd h3 (by decide)
  · rcases hcall with ⟨h2, hn⟩ | ⟨h3, hn⟩
    · exact absurd (hboxed.1 h2) hn
    · exact absurd (hboxed.2 h3) hn
  · rcases hcall with ⟨h2, _⟩ | ⟨h3, hn⟩
    · rw [ht3] at h2; exact absurd h2 (by decide)
    · exact absurd (hboxed.2 h3) hn

/-- How a trap ends, and — said outright — that a call with a range out of the box is refused: the
    machine parks with `a0 = 1` and the service port as it was, so the host is never asked. -/
def Outcome (M0 : Word → Byte) (u t : PrivMachine) : Prop :=
  Ends M0 u t ∧ (OutOfBox u → Parked t 1#32 ∧ SvcSame u.core.mem t.core.mem)

theorem outcome_of_ends {M0 : Word → Byte} {u t : PrivMachine} (h : Ends M0 u t) : Outcome M0 u t :=
  ⟨h, ends_refuses h⟩

set_option maxHeartbeats 4000000 in
/-- **One trap.** A running payload runs for `n` steps or traps; at the trap the monitor, in the end,
    either parks (a fault: `a0 = 1`, the service port untouched; a HALT: `a0` the payload's own exit code;
    a `CHECKSIG` the host answered with neither 0 nor 1: `a0 = 1`) or has served a call whose ranges were in
    the box and stands the payload up again, running, at the word after its `ecall`. A call with a range
    out of the box is the first of these. -/
theorem monitor_cycle (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (henv : env.region = monRegion)
    (hR : Running M0 s) (n : Nat) :
    ∃ k, k ≤ n ∧
      ((k = n ∧ Running M0 (PrivMachine.run env k s)) ∨
       (0 < k ∧ ∃ j, Outcome M0 (PrivMachine.run env k s) (PrivMachine.run env j (PrivMachine.run env k s)))) := by
  obtain ⟨k, hkn, hres⟩ := trap_state env M0 s hW henv hR n
  refine ⟨k, hkn, ?_⟩
  rcases hres with hrun | ⟨hpos, hS, hpc, hmpp, hcs⟩
  · exact Or.inl hrun
  right
  refine ⟨hpos, ?_⟩
  obtain ⟨u, hu⟩ : ∃ t, PrivMachine.run env k s = t := ⟨_, rfl⟩
  rw [hu] at hS hpc hmpp hcs ⊢
  suffices h : ∃ j, Ends M0 u (PrivMachine.run env j u) by
    obtain ⟨j, hj⟩ := h
    exact ⟨j, outcome_of_ends hj⟩
  by_cases hc : u.csrs.mcause = 8#32
  · by_cases ht1 : u.core.reg 5#5 = 1#32
    · obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12⟩ :=
        monitor_halt env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpc hcs hc ht1
      exact ⟨_, Or.inr (Or.inl ⟨parked_halt q1 q3 q4 q5 q6 q7 q8 q9 q12, hc, ht1, qi⟩)⟩
    · by_cases ht2 : u.core.reg 5#5 = 2#32
      · by_cases hbox : (0x80010000 ≤ (u.core.reg 10#5).toNat ∧ (u.core.reg 10#5).toNat + (u.core.reg 11#5).toNat ≤ 0x80020000) ∧
            (0x80010000 ≤ (u.core.reg 12#5).toNat ∧ (u.core.reg 12#5).toNat + 32 ≤ 0x80020000)
        · obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12, q13, qA, q14, q15⟩ :=
            monitor_hashb_ok env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht2 hbox.1 hbox.2 hmpp
          have hci : callIo u = [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩,
              ⟨0xc0000018#32, u.core.reg 12#5⟩, ⟨0xc000001c#32, 2#32⟩] := by simp [callIo, ht2]
          refine ⟨_, Or.inr (Or.inr (Or.inl ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, hc, Or.inl ht2,
            ⟨fun _ => hbox, fun h => by rw [ht2] at h; exact absurd h (by decide)⟩, q10, q11, ?_, q1, ?_, ?_, ?_,
            by rw [qi, hci], _, qA, fun _ => by rw [hci]; exact q14, fun h => by rw [ht2] at h; exact absurd h (by decide)⟩))⟩
          · rw [q13, ht2]; rfl
          · rw [q5]; rfl
          · intro r hr; rw [q15 r]; simp [regsUpd]
          · intro _; rw [q15 10#5]; simp [regsUpd]
        · obtain ⟨N, q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12⟩ :=
            monitor_hashb_oob_fault env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht2 hbox
          exact ⟨N, Or.inl ⟨parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12, q10, qi⟩⟩
      · by_cases ht3 : u.core.reg 5#5 = 3#32
        · by_cases hbox : (0x80010000 ≤ (u.core.reg 10#5).toNat ∧ (u.core.reg 10#5).toNat + 32 ≤ 0x80020000) ∧
              (0x80010000 ≤ (u.core.reg 11#5).toNat ∧ (u.core.reg 11#5).toNat + 64 ≤ 0x80020000)
          · have hn2 : u.core.reg 5#5 ≠ 2#32 := by rw [ht3]; decide
            have hci : callIo u = [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩,
                ⟨0xc000001c#32, 3#32⟩] := by simp [callIo, hn2]
            by_cases hans : BitVec.ult 1#32 (answer u (PrivMachine.run env 34 u).core.mem) = true
            · obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12, q13, qA, q14, q15⟩ :=
                monitor_checksig_bad_answer env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
                  hpc hcs hc ht3 hbox.1 hbox.2 (by rw [← hci]; exact hans)
              refine ⟨_, Or.inr (Or.inr (Or.inr ⟨parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q15, hc, ht3,
                ⟨fun h => by rw [ht3] at h; exact absurd h (by decide), fun _ => hbox⟩, ⟨_, qA, hans⟩, ?_⟩))⟩
              rw [qi, hci]; simp [faultIo]
            have hans' : BitVec.ult 1#32 (u.host (u.io ++ [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩,
                ⟨0xc000001c#32, 3#32⟩]) (PrivMachine.run env 34 u).core.mem 0xc000001c#32) = false := by
              rw [← hci]; simpa [answer] using hans
            obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12, q13, qA, q14, q15⟩ :=
              monitor_checksig_ok env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
                hpc hcs hc ht3 hbox.1 hbox.2 hmpp hans'
            have ha : (PrivMachine.run env 47 u).core.reg 10#5 = answer u (PrivMachine.run env 34 u).core.mem := by
              rw [q15 10#5]; simp [regsUpd, answer, hci]
            refine ⟨_, Or.inr (Or.inr (Or.inl ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, hc, Or.inr ht3,
              ⟨fun h => by rw [ht3] at h; exact absurd h (by decide), fun _ => hbox⟩, q10, q11, ?_, q1, ?_, ?_,
              fun h => absurd h hn2, by rw [qi, hci], _, qA, fun h => absurd h hn2, fun _ => ⟨q14, ?_, ?_⟩⟩))⟩
            · rw [q13, ht3]; rfl
            · rw [q5]; rfl
            · intro r hr
              have hr' : ¬ (10 = r.toNat) := fun h => hr (BitVec.eq_of_toNat_eq (by simpa using h.symm))
              rw [q15 r]; simp [regsUpd, hr']
            · rw [ha, qi, ← hci]; rfl
            · rw [ha]
              have : ¬ BitVec.ult 1#32 (answer u (PrivMachine.run env 34 u).core.mem) = true := hans
              simp only [BitVec.ult, decide_eq_true_eq] at this
              bv_omega
          · obtain ⟨N, q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12⟩ :=
              monitor_checksig_oob_fault env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
                hpc hcs hc ht3 hbox
            exact ⟨N, Or.inl ⟨parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12, q10, qi⟩⟩
        · obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12⟩ :=
            monitor_fault_syscall env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
              hpc hcs hc ht1 ht2 ht3
          exact ⟨_, Or.inl ⟨parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12, q10, qi⟩⟩
  · obtain ⟨q1, q2, q3, q4, q5, _, qi, q6, q7, q8, q9, q10, q11, q12⟩ :=
      monitor_fault_cause env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpc hcs hc
    exact ⟨_, Or.inl ⟨parked_fault q1 q3 q4 q5 q6 q7 q8 q9 q12, q10, qi⟩⟩

/-! ## However many calls the payload makes -/

/-- From a running state, however many calls the payload makes: every trap has an `Outcome` — parked, or
    running again — and a call with a range out of the box is refused, `c` times over. -/
def SafeFor (env : Rv32.Env) (M0 : Word → Byte) : Nat → PrivMachine → Prop
  | 0, s => Running M0 s
  | c + 1, s => Running M0 s ∧ ∀ n, ∃ k, k ≤ n ∧
      ((k = n ∧ Running M0 (PrivMachine.run env k s)) ∨
       (0 < k ∧ ∃ j,
        Outcome M0 (PrivMachine.run env k s) (PrivMachine.run env j (PrivMachine.run env k s)) ∧
        (Running M0 (PrivMachine.run env j (PrivMachine.run env k s)) →
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
    · exact Or.inr ⟨hpos, j, h, fun hr => ih _ hr⟩

/-- **The call the monitor checks.** From reset, the monitor boots (53 steps), and then, however many
    calls the payload makes and whatever their arguments: each trap ends with the machine parked (a
    fault, or the payload's HALT), or with a call whose ranges were in the box served and the payload
    running again in U-mode at the word after its `ecall`, the box fence and the monitor's words as they
    were. A call with a range that is not wholly inside the box parks the machine with `a0 = 1` and the
    service port as it was: the host is never asked. -/
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
#print axioms Exp238.hashb_req
#print axioms Exp238.monitor_hashb_ok
#print axioms Exp238.monitor_hashb_oob_fault
#print axioms Exp238.monitor_checksig_ok
#print axioms Exp238.monitor_checksig_bad_answer
#print axioms Exp238.monitor_checksig_oob_fault
#print axioms Exp238.ends_refuses
#print axioms Exp238.monitor_cycle
#print axioms Exp238.monitor_end_to_end
