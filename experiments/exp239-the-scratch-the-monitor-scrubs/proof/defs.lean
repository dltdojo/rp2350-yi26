/-! ## What the monitor writes into the payload's box, and where -/

/-- With the PMP boot set, an M-mode access wholly inside the payload's region is not refused: the entry
    that fences the payload in is not locked, so it binds U-mode and leaves M-mode alone. -/
theorem pmpCheck_mon_in (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (h0 : csrs.pmpcfg0 = 0x1f#32) (h1 : csrs.pmpaddr0 = 0x20005fff#32)
    (hw : 0 < width) (hlo : 0x80010000 ≤ addr.toNat) (hhi : addr.toNat + width ≤ 0x80020000) :
    pmpCheck csrs .M addr width acc = true := by
  unfold pmpCheck PMP_INDICES pmpCheckEntries matchPmpEntry
  have hn : ¬ (addr.toNat + width ≤ 2147549184 ∨ 2147614720 ≤ addr.toNat) := by omega
  have hb : 2147549184 ≤ addr.toNat ∧ addr.toNat + width ≤ 2147614720 := by omega
  simp [h0, h1, decodePmpCfgByte, pmpAddrVal, decodeNapotRange, countTrailingOnes32,
    countTrailingOnes32.loop, hasPermission, hn, hb]

/-- The confidential scratch of exp223's kernel: the SHA-256 schedule at `+0x2200` and the raw samples at
    `+0x3000`, up to the end of the samples at `+0x4000`. -/
def InConf (x : Word) : Prop := 0x80012200 ≤ x.toNat ∧ x.toNat < 0x80014000
/-- The 32-byte digest window, at `+0x2140`. -/
def InDigest (x : Word) : Prop := 0x80012140 ≤ x.toNat ∧ x.toNat < 0x80012160

/-- `m'` is `m` with the bytes `[lo, hi)` zeroed and every other byte as it was. -/
def Zeroed (lo hi : Nat) (m m' : Word → Byte) : Prop :=
  ∀ x : Word, (lo ≤ x.toNat ∧ x.toNat < hi → m' x = 0) ∧ (¬ (lo ≤ x.toNat ∧ x.toNat < hi) → m' x = m x)

/-- **What the monitor leaves of memory.** The payload left `m0` and exited with `a0`; the monitor parks with
    `m`: the confidential scratch zero; the digest window zero too, unless `a0` is 0, when its 32 bytes are
    the payload's; every other byte but the monitor's own stack words and report words as it was. -/
def Scrubbed (a0 : Word) (m0 m : Word → Byte) : Prop :=
  (∀ x, InConf x → m x = 0) ∧
  (∀ x, InDigest x → m x = if a0 = 0#32 then m0 x else 0) ∧
  (∀ x, ¬ InConf x → ¬ InDigest x → ¬ InStack x → ¬ InPorts x → m x = m0 x)

theorem zeroed_write (A : Word) (m : Word → Byte) (hw : A.toNat + 4 ≤ 4294967296) :
    Zeroed A.toNat (A.toNat + 4) m (writeLE m A 0 4) := by
  intro x
  rw [writeLE4_apply]
  simp only [BitVec.toNat_sub, Nat.reducePow, Nat.zero_div]
  have hx := x.isLt
  have ha := A.isLt
  constructor
  · intro h
    have : (4294967296 - A.toNat + x.toNat) % 4294967296 < 4 := by omega
    simp [this]
  · intro h
    have : ¬ (4294967296 - A.toNat + x.toNat) % 4294967296 < 4 := by omega
    simp [this]

theorem zeroed_trans {lo mid hi : Nat} {m0 m1 m2 : Word → Byte} (h1 : Zeroed lo mid m0 m1)
    (h2 : Zeroed mid hi m1 m2) (hlm : lo ≤ mid) (hmh : mid ≤ hi) : Zeroed lo hi m0 m2 := by
  intro x
  obtain ⟨a1, b1⟩ := h1 x
  obtain ⟨a2, b2⟩ := h2 x
  constructor
  · intro h
    by_cases hx : x.toNat < mid
    · rw [b2 (by omega)]; exact a1 ⟨h.1, hx⟩
    · exact a2 ⟨by omega, h.2⟩
  · intro h
    rw [b2 (by omega)]
    exact b1 (by omega)

/-- A four-byte read away from the zeroed bytes is what it was. -/
theorem readLE_zeroed {lo hi : Nat} {m m' : Word → Byte} (h : Zeroed lo hi m m') (a : Word)
    (ha : a.toNat + 4 ≤ lo ∨ hi ≤ a.toNat) (hw : a.toNat + 4 ≤ 4294967296) :
    readLE m' a 4 = readLE m a 4 := by
  apply readLE_four_congr
  intro d hd
  apply (h _).2
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.reducePow, Nat.reduceMod]
  have := a.isLt
  omega

/-- The payload's box and the rest of memory outside the monitor's stack words and report words: the
    monitor's earlier steps wrote nothing there. -/
def FrameSP (m m' : Word → Byte) : Prop := ∀ x, ¬ InStack x → ¬ InPorts x → m' x = m x

theorem frameSP_of {m m' : Word → Byte} (f : Frame m m') (v : SvcSame m m') : FrameSP m m' := by
  intro x hs hp
  by_cases hv : InSvc x
  · exact v x hv
  · exact f x hs hp hv

theorem FrameSP.trans {a b c : Word → Byte} (h1 : FrameSP a b) (h2 : FrameSP b c) : FrameSP a c :=
  fun x i p => (h2 x i p).trans (h1 x i p)

/-- A trap's first half, which wrote nothing in the box, followed by a scrub, is a scrub of the box as the
    payload left it. -/
theorem scrubbed_of_frame {a0 : Word} {m0 m1 m2 : Word → Byte} (f : FrameSP m0 m1) (s : Scrubbed a0 m1 m2) :
    Scrubbed a0 m0 m2 := by
  obtain ⟨c, d, o⟩ := s
  refine ⟨c, ?_, ?_⟩
  · intro x hx
    have hs : ¬ InStack x := by unfold InStack InDigest at *; omega
    have hp : ¬ InPorts x := by unfold InPorts InDigest at *; omega
    rw [d x hx, f x hs hp]
  · intro x h1 h2 h3 h4
    rw [o x h1 h2 h3 h4, f x h3 h4]

/-- The pass: the confidential scratch zeroed, the digest window and everything else but the stack and report
    words untouched. -/
theorem scrubbed_pass {m0 m1 m2 m3 m4 : Word → Byte}
    (f1 : Frame m0 m1) (v1 : SvcSame m0 m1) (z : Zeroed 0x80012200 0x80014000 m1 m2)
    (f3 : Frame m2 m3) (v3 : SvcSame m2 m3) (f4 : Frame m3 m4) (v4 : SvcSame m3 m4) :
    Scrubbed 0#32 m0 m4 := by
  have g1 := frameSP_of f1 v1
  have g3 := frameSP_of f3 v3
  have g4 := frameSP_of f4 v4
  refine ⟨?_, ?_, ?_⟩
  · intro x hx
    unfold InConf at hx
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    rw [g4 x hs hp, g3 x hs hp, (z x).1 hx]
  · intro x hx
    unfold InDigest at hx
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    have hc : ¬ (0x80012200 ≤ x.toNat ∧ x.toNat < 0x80014000) := by omega
    simp only [ite_true]
    rw [g4 x hs hp, g3 x hs hp, (z x).2 hc, g1 x hs hp]
  · intro x hc hd hs hp
    have hc' : ¬ (0x80012200 ≤ x.toNat ∧ x.toNat < 0x80014000) := hc
    rw [g4 x hs hp, g3 x hs hp, (z x).2 hc', g1 x hs hp]

/-- The fail: the digest window zeroed too. -/
theorem scrubbed_fail {a0 : Word} (ha : a0 ≠ 0#32) {m0 m1 m2 m3 m4 m5 m6 : Word → Byte}
    (f1 : Frame m0 m1) (v1 : SvcSame m0 m1) (z : Zeroed 0x80012200 0x80014000 m1 m2)
    (f3 : Frame m2 m3) (v3 : SvcSame m2 m3) (f4 : Frame m3 m4) (v4 : SvcSame m3 m4)
    (zd : Zeroed 0x80012140 0x80012160 m4 m5) (f6 : Frame m5 m6) (v6 : SvcSame m5 m6) :
    Scrubbed a0 m0 m6 := by
  have g1 := frameSP_of f1 v1
  have g3 := frameSP_of f3 v3
  have g4 := frameSP_of f4 v4
  have g6 := frameSP_of f6 v6
  refine ⟨?_, ?_, ?_⟩
  · intro x hx
    unfold InConf at hx
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    have hd : ¬ (0x80012140 ≤ x.toNat ∧ x.toNat < 0x80012160) := by omega
    rw [g6 x hs hp, (zd x).2 hd, g4 x hs hp, g3 x hs hp, (z x).1 hx]
  · intro x hx
    unfold InDigest at hx
    have hs : ¬ InStack x := by unfold InStack; omega
    have hp : ¬ InPorts x := by unfold InPorts; omega
    simp only [ha, ite_false]
    rw [g6 x hs hp]
    exact (zd x).1 hx
  · intro x hc hd hs hp
    have hc' : ¬ (0x80012200 ≤ x.toNat ∧ x.toNat < 0x80014000) := hc
    have hd' : ¬ (0x80012140 ≤ x.toNat ∧ x.toNat < 0x80012160) := hd
    rw [g6 x hs hp, (zd x).2 hd', g4 x hs hp, g3 x hs hp, (z x).2 hc', g1 x hs hp]

/-! ## The park loop, and the exit code -/

/-- The park loop, reached: every register but `a0` zero, `mscratch` zero, the two words trap entry saved zero. -/
def Parked (t : PrivMachine) (a0 : Word) : Prop :=
  t.core.pc = 0x80000268#32 ∧ t.halted = false ∧ t.mode = .M ∧ t.csrs.mscratch = 0#32 ∧
  readLE t.core.mem 0x80008000#32 4 = 0 ∧ readLE t.core.mem 0x80008004#32 4 = 0 ∧
  t.core.reg 10#5 = a0 ∧ ∀ r, r ≠ 10#5 → t.core.reg r = 0#32

/-- The code the monitor parks with after a trap: the payload's own `a0` if it asked for HALT (`ecall` with
    `t0 = 1`), and 1 for everything else. -/
def exitCode (u : PrivMachine) : Word :=
  if u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 then u.core.reg 10#5 else 1#32

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
  (if u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 then haltIo u else faultIo u) ++ [⟨0xc0000008#32, exitCode u⟩]

