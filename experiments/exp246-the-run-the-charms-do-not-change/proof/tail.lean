namespace Exp246
open Rv32
open Rv32.Priv
open Rv32.Refinement

/-! ## What a payload can reach, and what two machines agree on -/

/-- The bytes a payload in the box can reach at all: the code, the data and the stack. -/
abbrev Vis : Word → Prop := WxVis 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000

/-- Two machines whose boxes hold the same bytes, whose hosts have heard the same, and will answer the same. -/
def BoxAgree (p p' : PrivMachine) : Prop :=
  (∀ x, Vis x → p.core.mem x = p'.core.mem x) ∧ p.io = p'.io ∧ p.host = p'.host

theorem vis_not_shrine {x : Word} (h : Vis x) : ¬ (0x80008010 ≤ x.toNat ∧ x.toNat < 0x80008018) := by
  unfold Vis WxVis at h; omega

theorem vis_not_stack240 {x : Word} (h : Vis x) : ¬ Exp240.InStack x ∧ ¬ Exp240.InPorts x := by
  unfold Vis WxVis at h; unfold Exp240.InStack Exp240.InPorts; omega

theorem vis_not_stack245 {x : Word} (h : Vis x) : ¬ Exp245.InStack x ∧ ¬ Exp245.InPorts x := by
  unfold Vis WxVis at h; unfold Exp245.InStack Exp245.InPorts; omega

/-! ## Boot: the same payload start, under either monitor -/

/-- **Boot leaves twins.** From two `Ready` machines whose boxes hold the same bytes, a reset and each monitor's boot
    -- 61 steps of exp240's, 71 of exp245's -- leave two machines boxed by the same three entries, at the same `pc`,
    twins: the registers, the box, the CSRs a payload's run reads or moves, and what the host has heard, the same. The
    trap vectors differ, and so does entry 3, which decides nothing; the shrine is outside the box. -/
theorem boot_twins (env : Rv32.Env) (C C' : Word → Byte) (p p' : PrivMachine)
    (hR : Exp240.Ready env C p) (hR' : Exp245.Ready env C' p') (hA : BoxAgree p p') :
    WXBoxed (PrivMachine.run env 61 (Exp240.resetOf p)) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
    WXBoxed (PrivMachine.run env 71 (Exp245.resetOf p')) 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 ∧
    (PrivMachine.run env 61 (Exp240.resetOf p)).core.pc = (PrivMachine.run env 71 (Exp245.resetOf p')).core.pc ∧
    Twin Vis (PrivMachine.run env 61 (Exp240.resetOf p)) (PrivMachine.run env 71 (Exp245.resetOf p')) := by
  obtain ⟨hb, hpc, hcs, hmem, hreg, hio, hho⟩ :=
    Exp240.monitor_boot env p.core.mem (Exp240.resetOf p) hR.words rfl rfl rfl rfl hR.unlocked
  obtain ⟨hb', hpc', hcs', hmem', hreg', hio', hho'⟩ :=
    Exp245.monitor_boot env p'.core.mem (Exp245.resetOf p') hR'.words rfl rfl rfl rfl hR'.unlocked hR'.region
  refine ⟨hb, hb', by rw [hpc, hpc'], fun r => by rw [hreg r, hreg' r], fun x hx => ?_,
    by rw [hb.isUMode, hb'.isUMode], by rw [hb.notHalted, hb'.notHalted], ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [hmem, hmem', Exp245.shrined_apply _ x (vis_not_shrine hx)]
    exact hA.1 x hx
  all_goals first
    | (rw [hcs, hcs']; rfl)
    | (rw [hio, hio']; exact hA.2.1)
    | (rw [hho, hho']; exact hA.2.2)

/-! ## The payload: the same steps, the same first trap -/

/-- The first trap of a run is the first: two `k` that both are, are one. -/
theorem trapped_unique {env : Rv32.Env} {s : PrivMachine} {k k' : Nat}
    (h : Exp240.Trapped env s k) (h' : Exp240.Trapped env s k') : k = k' := by
  obtain ⟨_, hM, hU⟩ := h
  obtain ⟨_, hM', hU'⟩ := h'
  by_cases hlt : k < k'
  · have := hU' k hlt; rw [hM] at this; exact absurd this (by decide)
  · by_cases hgt : k' < k
    · have := hU k' hgt; rw [hM'] at this; exact absurd this (by decide)
    · omega

/-- Twins boxed by the three entries trap first at the same step: a run of one traps first at `k` exactly when the
    other's does. -/
theorem trapped_iff (env : Rv32.Env) (s t : PrivMachine)
    (hs : WXBoxed s 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000)
    (ht : WXBoxed t 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000)
    (hpc : s.core.pc = t.core.pc) (hT : Twin Vis s t) (k : Nat) :
    Exp240.Trapped env s k ↔ Exp245.Trapped env t k := by
  have run := wx_twin_run (cLo := 0x80010000) (cHi := 0x80010080) (dLo := 0x80010000) (dHi := 0x80011000)
    (kLo := 0x8001f000) (kHi := 0x80020000) env (by decide) (by decide) (by decide)
  constructor
  · rintro ⟨hk0, hkM, hkU⟩
    refine ⟨hk0, ?_, fun i hi => ?_⟩
    · have := (run k s t hs ht hpc hT hkU).1.mode
      rw [← this]; exact hkM
    · have := (run i s t hs ht hpc hT (fun j hj => hkU j (by omega))).1.mode
      rw [← this]; exact hkU i hi
  · rintro ⟨hk0, hkM, hkU⟩
    refine ⟨hk0, ?_, fun i hi => ?_⟩
    · have := (run k t s ht hs hpc.symm hT.symm hkU).1.mode
      rw [← this]; exact hkM
    · have := (run i t s ht hs hpc.symm hT.symm (fun j hj => hkU j (by omega))).1.mode
      rw [← this]; exact hkU i hi

/-- **The payload runs the same.** After boot, for as long as the payload under exp240's monitor has not trapped, the
    two are twins, at the same `pc`: the same registers, the same box, the same counters -- a payload that never traps
    runs the same forever under either. -/
theorem payload_twins (env : Rv32.Env) (C C' : Word → Byte) (p p' : PrivMachine)
    (hR : Exp240.Ready env C p) (hR' : Exp245.Ready env C' p') (hA : BoxAgree p p') (n : Nat)
    (hU : ∀ i, i < n → (Exp240.payloadAt env (Exp240.resetOf p) i).mode = .U) :
    Twin Vis (Exp240.payloadAt env (Exp240.resetOf p) n) (Exp245.payloadAt env (Exp245.resetOf p') n) ∧
    ((Exp240.payloadAt env (Exp240.resetOf p) n).mode = .U →
      (Exp240.payloadAt env (Exp240.resetOf p) n).core.pc = (Exp245.payloadAt env (Exp245.resetOf p') n).core.pc) := by
  obtain ⟨hs, ht, hpc, hT⟩ := boot_twins env C C' p p' hR hR' hA
  obtain ⟨h1, h2⟩ := wx_twin_run env (by decide) (by decide) (by decide) n _ _ hs ht hpc hT hU
  exact ⟨h1, fun h => (h2 h).2.2⟩

/-! ## A round -/

/-- A round's first trap under exp240's monitor, from a `Ready` machine: what the handler's theorems need. -/
theorem round_trap240 (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Exp240.Ready env C p) (k : Nat)
    (hk : Exp240.Trapped env (PrivMachine.run env 61 (Exp240.resetOf p)) k) :
    (∀ x : Word, WxFrozen 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 x →
      (Exp240.payloadAt env (Exp240.resetOf p) k).core.mem x = p.core.mem x) ∧
    Exp240.HState env p.core.mem (Exp240.payloadAt env (Exp240.resetOf p) k) ∧
    (Exp240.payloadAt env (Exp240.resetOf p) k).core.pc = 0x80000134#32 ∧
    ∃ ms e c m cy, (Exp240.payloadAt env (Exp240.resetOf p) k).csrs = Exp240.csrsH ms e c m cy {} 0x80008000#32 := by
  obtain ⟨hbox, hcsb, hpc1, hmem1, hreg1⟩ := Exp240.monitor_reentry env C p hR
  obtain ⟨k', hk'k, hfroz, hagree, hres⟩ := Exp240.payload_runs env p.core.mem _ hR.words hmem1 hR.region hcsb hbox k
  obtain ⟨hk0, hkM, hkU⟩ := hk
  have hkk : k' = k := by
    rcases hres with ⟨h1, h2, _⟩ | ⟨h1, h2, _⟩
    · exfalso
      have : (PrivMachine.run env k' (PrivMachine.run env 61 (Exp240.resetOf p))).mode = .M := by rw [h1]; exact hkM
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
  · exfalso; rw [h2] at hkM; exact absurd hkM (by decide)
  · exact ⟨hfroz, hS, hpcu, hcs⟩

/-- **One round, either monitor, the same.** From two `Ready` machines whose boxes hold the same bytes, a round under
    exp240's monitor and a round under exp245's: the payload traps first at the same step, the host hears the same --
    the same report, the same exit code -- the hosts are the same, and at the park the boxes hold the same bytes but
    for exp245's slot, which is zero. -/
theorem round_same (env : Rv32.Env) (C C' : Word → Byte) (p p' q q' : PrivMachine)
    (hR : Exp240.Ready env C p) (hR' : Exp245.Ready env C' p') (hA : BoxAgree p p')
    (hq : Exp240.Round env p q) (hq' : Exp245.Round env p' q') :
    q.io = q'.io ∧ q.host = q'.host ∧
    (∀ x, Vis x → ¬ Exp245.InSlot x → q.core.mem x = q'.core.mem x) ∧
    (∀ x, Exp245.InSlot x → q'.core.mem x = 0) := by
  obtain ⟨hs, ht, hpc, hT⟩ := boot_twins env C C' p p' hR hR' hA
  obtain ⟨k, hk, rfl⟩ := hq
  obtain ⟨k', hk', rfl⟩ := hq'
  have hkk : k = k' := trapped_unique hk ((trapped_iff env _ _ hs ht hpc hT k').mpr hk')
  subst hkk
  obtain ⟨hT1, -⟩ := wx_twin_run env (by decide) (by decide) (by decide) k _ _ hs ht hpc hT hk.2.2
  obtain ⟨-, hS, hpcu, ms, e, c, m, cy, hcsu⟩ := round_trap240 env C p hR k hk
  obtain ⟨-, hS', hpcu', ms', e', c', m', cy', hcsu'⟩ := Exp245.round_trap env C' p' hR' k hk'
  have hseal := Exp245.shrine_always_intact env C' p' hR' k hk'
  obtain ⟨-, -, hF, -, hho, hio⟩ := Exp240.monitor_traps env p.core.mem _ hS ms e c m cy hpcu hcsu
  obtain ⟨-, -, hF', -, hho', hio'⟩ := Exp245.monitor_traps env (Exp245.shrined p'.core.mem) _ hS' ms' e' c' m' cy' hpcu' hcsu'
  unfold Exp240.parkedAfter Exp245.parkedAfter
  unfold Exp240.payloadAt at *
  unfold Exp245.payloadAt at *
  refine ⟨?_, by rw [hho, hho', hT1.host], ?_, fun x hx => hF'.1 x hx⟩
  · rw [hio, hio', hT1.io]
    congr 1
    unfold Exp245.Sealed at hseal
    simp [Exp240.trapIo, Exp245.trapIo, Exp240.exitCode, Exp245.exitCode, Exp240.haltIo, Exp245.haltIo,
      Exp240.faultIo, Exp245.faultIo, Exp245.Sealed, hseal, hT1.mcause, hT1.regs, hT1.mepc, hT1.minstret, hT1.mcycle]
  · intro x hx hl
    obtain ⟨n1, n2⟩ := vis_not_stack240 hx
    obtain ⟨n3, n4⟩ := vis_not_stack245 hx
    rw [hF x n1 n2, hF'.2 x n3 n4 hl]
    exact hT1.mem x hx

/-- **Either monitor's round has the other's.** From two `Ready` machines whose boxes hold the same bytes, for every
    round under exp240's monitor there is one under exp245's, and the other way round. -/
theorem round_exists (env : Rv32.Env) (C C' : Word → Byte) (p p' : PrivMachine)
    (hR : Exp240.Ready env C p) (hR' : Exp245.Ready env C' p') (hA : BoxAgree p p') :
    (∀ q, Exp240.Round env p q → ∃ q', Exp245.Round env p' q') ∧
    (∀ q', Exp245.Round env p' q' → ∃ q, Exp240.Round env p q) := by
  obtain ⟨hs, ht, hpc, hT⟩ := boot_twins env C C' p p' hR hR' hA
  refine ⟨fun q ⟨k, hk, _⟩ => ⟨_, k, (trapped_iff env _ _ hs ht hpc hT k).mp hk, rfl⟩,
    fun q' ⟨k, hk, _⟩ => ⟨_, k, (trapped_iff env _ _ hs ht hpc hT k).mpr hk, rfl⟩⟩

/-- **When the rounds stay the same.** If the round under exp240's monitor leaves the slot zero -- the payload left it
    zero at its trap, since exp240 writes nothing there -- the two parked machines agree again: the next round starts
    from boxes that hold the same bytes. If not, they differ in the slot, and only there. -/
theorem round_agree (env : Rv32.Env) (C C' : Word → Byte) (p p' q q' : PrivMachine)
    (hR : Exp240.Ready env C p) (hR' : Exp245.Ready env C' p') (hA : BoxAgree p p')
    (hq : Exp240.Round env p q) (hq' : Exp245.Round env p' q')
    (hz : ∀ x, Exp245.InSlot x → q.core.mem x = 0) : BoxAgree q q' := by
  obtain ⟨hio, hho, hmem, hslot⟩ := round_same env C C' p p' q q' hR hR' hA hq hq'
  refine ⟨fun x hx => ?_, hio, hho⟩
  by_cases hl : Exp245.InSlot x
  · rw [hz x hl, hslot x hl]
  · exact hmem x hx hl

/-! ## Any number of rounds -/

/-- Runs of rounds side by side, one under each monitor, from machines whose boxes agree: a round under each, whenever
    exp240's leaves the slot zero; and the host's writes between rounds, the same to the two boxes. -/
inductive Both (env : Rv32.Env) (C C' : Word → Byte) : PrivMachine → PrivMachine → Prop
  | start {p p' : PrivMachine} : Exp240.Ready env C p → Exp245.Ready env C' p' → BoxAgree p p' → Both env C C' p p'
  | round {p p' q q' : PrivMachine} : Both env C C' p p' → Exp240.Round env p q → Exp245.Round env p' q' →
      (∀ x, Exp245.InSlot x → q.core.mem x = 0) → Both env C C' q q'
  | host {p p' q q' : PrivMachine} : Both env C C' p p' → Exp240.HostWrite p q → Exp245.HostWrite p' q' →
      BoxAgree q q' → Both env C C' q q'

/-- **Any number of rounds, the same.** Runs side by side, as `Both` builds them, are `Ready` under their own monitor
    after any number of rounds and host writes, and agree: the boxes hold the same bytes and the host has heard the
    same. With `round_same` and `round_exists`: as long as every exit leaves the slot zero, the two monitors are the
    same to every payload and every host, for any number of rounds. -/
theorem both_agree (env : Rv32.Env) (C C' : Word → Byte) (p p' : PrivMachine) (h : Both env C C' p p') :
    Exp240.Ready env C p ∧ Exp245.Ready env C' p' ∧ BoxAgree p p' := by
  induction h with
  | start hR hR' hA => exact ⟨hR, hR', hA⟩
  | round _ hq hq' hz ih =>
    obtain ⟨hR, hR', hA⟩ := ih
    exact ⟨(Exp240.monitor_round_ready env C _ _ hR hq).1, (Exp245.monitor_round_ready env C' _ _ hR' hq').1,
      round_agree env C C' _ _ _ _ hR hR' hA hq hq' hz⟩
  | host _ hw hw' hA ih =>
    obtain ⟨hR, hR', -⟩ := ih
    exact ⟨Exp240.ready_of_host env C _ _ hR hw, Exp245.ready_of_host env C' _ _ hR' hw', hA⟩

end Exp246

#print axioms Rv32.Priv.wx_twin_step
#print axioms Rv32.Priv.wx_twin_run
#print axioms Exp246.boot_twins
#print axioms Exp246.trapped_iff
#print axioms Exp246.payload_twins
#print axioms Exp246.round_same
#print axioms Exp246.round_exists
#print axioms Exp246.round_agree
#print axioms Exp246.both_agree
