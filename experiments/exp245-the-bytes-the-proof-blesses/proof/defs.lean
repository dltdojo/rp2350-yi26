/-! ## What the monitor writes, and where -/

/-- With the PMP boot set, an M-mode word access is not refused anywhere, the payload's box included: no entry is
    locked, so the entries bind U-mode and leave M-mode alone. The scrub of the slot needs it. -/
theorem pmpCheck_mon_in (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (h0 : csrs.pmpcfg0 = 0x191b1b1d#32) (hw : width = 4) (hal : addr.toNat % 4 = 0) :
    pmpCheck csrs .M addr width acc = true := by
  subst hw
  exact pmpCheck_M_unlocked csrs addr acc (by rw [h0]; intro i; revert i; decide) hal

/-- A four-byte read the monitor's stack words, report words and service port do not touch: what a chunk's `Frame`
    leaves as it was. The shrine is one. -/
theorem Frame.read {m m' : Word → Byte} (h : Frame m m') (a : Word)
    (ha : 0x80008010 ≤ a.toNat ∧ a.toNat + 4 ≤ 0xc0000000) : readLE m' a 4 = readLE m a 4 := by
  apply readLE_four_congr
  intro d hd
  have := a.isLt
  apply h <;> simp only [InStack, InPorts, InSvc, BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow] <;> omega

/-- Memory outside the monitor's stack words and report words is what it was. -/
def FrameSP (m m' : Word → Byte) : Prop := ∀ x, ¬ InStack x → ¬ InPorts x → m' x = m x

theorem frameSP_of {m m' : Word → Byte} (f : Frame m m') (v : SvcSame m m') : FrameSP m m' := by
  intro x hs hp
  by_cases hv : InSvc x
  · exact v x hv
  · exact f x hs hp hv

theorem FrameSP.trans {a b c : Word → Byte} (h1 : FrameSP a b) (h2 : FrameSP b c) : FrameSP a c :=
  fun x i p => (h2 x i p).trans (h1 x i p)

/-- [Charm 3] The sacred key slot, `[0x80010e00, 0x80010e20)`, in the data. -/
def InSlot (x : Word) : Prop := 0x80010e00 ≤ x.toNat ∧ x.toNat < 0x80010e20

/-- **What an exit leaves of memory.** The slot zero; every other byte but the monitor's stack words and report words
    as it was. -/
def SlotFrame (m m' : Word → Byte) : Prop :=
  (∀ x, InSlot x → m' x = 0) ∧ (∀ x, ¬ InStack x → ¬ InPorts x → ¬ InSlot x → m' x = m x)

/-- The part of a trap before the scrub, which wrote nothing but the stack and report words, then the scrub. -/
theorem slotFrame_of {m0 m1 m2 : Word → Byte} (f : FrameSP m0 m1) (s : SlotFrame m1 m2) : SlotFrame m0 m2 := by
  refine ⟨s.1, ?_⟩
  intro x h1 h2 h3
  rw [s.2 x h1 h2 h3, f x h1 h2]

/-- The scrub of the slot: the slot setup, which writes nothing, the loop, the registers' scrub, which writes nothing
    but the exit word. -/
theorem slotFrame_scrub {m0 m1 m2 m3 : Word → Byte} (f1 : Frame m0 m1) (v1 : SvcSame m0 m1)
    (z : Zeroed 0x80010e00 0x80010e20 m1 m2) (f3 : Frame m2 m3) (v3 : SvcSame m2 m3) : SlotFrame m0 m3 := by
  have g1 := frameSP_of f1 v1
  have g3 := frameSP_of f3 v3
  refine ⟨?_, ?_⟩
  · intro x hx
    unfold InSlot at hx
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    rw [g3 x hs hp, (z x).1 hx]
  · intro x hs hp hl
    unfold InSlot at hl
    rw [g3 x hs hp, (z x).2 hl, g1 x hs hp]

/-! ## The park loop, and the exit code -/

/-- The park loop, reached: every register but `a0` zero, `mscratch` zero, the two words trap entry saved zero. -/
def Parked (t : PrivMachine) (a0 : Word) : Prop :=
  t.core.pc = 0x800002c0#32 ∧ t.halted = false ∧ t.mode = .M ∧ t.csrs.mscratch = 0#32 ∧
  readLE t.core.mem 0x80008000#32 4 = 0 ∧ readLE t.core.mem 0x80008004#32 4 = 0 ∧
  t.core.reg 10#5 = a0 ∧ ∀ r, r ≠ 10#5 → t.core.reg r = 0#32

/-- [Charm 1] The shrine holds the seal: its two words read "OMAM" and "KUAI". -/
def Sealed (m : Word → Byte) : Prop :=
  BitVec.ofNat 32 (readLE m 0x80008010#32 4) = 0x4d414d4f#32 ∧
  BitVec.ofNat 32 (readLE m 0x80008014#32 4) = 0x4941554b#32

instance (m : Word → Byte) : Decidable (Sealed m) := inferInstanceAs (Decidable (_ ∧ _))

/-- The code the monitor parks with after a trap: the payload's own `a0` if it asked for HALT (`ecall` with
    `t0 = 1`) and the seal is intact, and 1 for everything else. -/
def exitCode (u : PrivMachine) : Word :=
  if u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ Sealed u.core.mem then u.core.reg 10#5 else 1#32

/-- A fault's report to the print word: the tag, `mcause`, `mepc`, `mtval` (0: Hazard3 hardwires it)
    and `minstret`. -/
def faultIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x4641554c#32⟩, ⟨0xc0000004#32, u.csrs.mcause⟩, ⟨0xc0000004#32, u.csrs.mepc⟩,
   ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, u.csrs.minstret⟩]

/-- A HALT's report to the print word: the tag, the payload's `a0`, `minstret` and `mcycle`. -/
def haltIo (u : PrivMachine) : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, u.core.reg 10#5⟩, ⟨0xc0000004#32, u.csrs.minstret⟩,
   ⟨0xc0000004#32, u.csrs.mcycle⟩]

/-- What the host hears of a trap, in order: the report for the way it trapped, then the exit code to the exit word. -/
def trapIo (u : PrivMachine) : List IoEvent :=
  (if u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 ∧ Sealed u.core.mem then haltIo u else faultIo u) ++
    [⟨0xc0000008#32, exitCode u⟩]

/-- How many steps the monitor takes from the trap vector to the park loop: an `ecall` for HALT with the seal intact,
    95; with its first word wrong, 96; with its second wrong, 100; an `ecall` for anything else, 90; any other trap, 87. -/
def trapSteps (u : PrivMachine) : Nat :=
  if u.csrs.mcause = 8#32 then
    (if u.core.reg 5#5 = 1#32 then
      (if BitVec.ofNat 32 (readLE u.core.mem 0x80008010#32 4) = 0x4d414d4f#32 then
        (if BitVec.ofNat 32 (readLE u.core.mem 0x80008014#32 4) = 0x4941554b#32 then 95 else 100) else 96)
     else 90)
  else 87

/-- The machine `k` steps into the payload, after boot's `71`. -/
def payloadAt (env : Rv32.Env) (s : PrivMachine) (k : Nat) : PrivMachine :=
  PrivMachine.run env k (PrivMachine.run env 71 s)

/-- The machine the monitor leaves after handling the trap at `u`. -/
def parkedAfter (env : Rv32.Env) (u : PrivMachine) : PrivMachine :=
  PrivMachine.run env (trapSteps u) u

/-- The bytes of the code entry, `[0x80010000, 0x80010080)`, are `C`'s. -/
def CodeSame (C : Word → Byte) (m : Word → Byte) : Prop :=
  ∀ x : Word, 0x80010000 ≤ x.toNat → x.toNat < 0x80010080 → m x = C x
