/-! ## What the monitor writes, and where -/

/-- Memory outside the monitor's stack words and report words is what it was. -/
def FrameSP (m m' : Word → Byte) : Prop := ∀ x, ¬ InStack x → ¬ InPorts x → m' x = m x

theorem frameSP_of {m m' : Word → Byte} (f : Frame m m') (v : SvcSame m m') : FrameSP m m' := by
  intro x hs hp
  by_cases hv : InSvc x
  · exact v x hv
  · exact f x hs hp hv

theorem FrameSP.trans {a b c : Word → Byte} (h1 : FrameSP a b) (h2 : FrameSP b c) : FrameSP a c :=
  fun x i p => (h2 x i p).trans (h1 x i p)

/-! ## The park loop, and the exit code -/

/-- The park loop, reached: every register but `a0` zero, `mscratch` zero, the two words trap entry saved zero. -/
def Parked (t : PrivMachine) (a0 : Word) : Prop :=
  t.core.pc = 0x80000250#32 ∧ t.halted = false ∧ t.mode = .M ∧ t.csrs.mscratch = 0#32 ∧
  readLE t.core.mem 0x80008000#32 4 = 0 ∧ readLE t.core.mem 0x80008004#32 4 = 0 ∧
  t.core.reg 10#5 = a0 ∧ ∀ r, r ≠ 10#5 → t.core.reg r = 0#32

/-- The code the monitor parks with after a trap: the payload's own `a0` if it asked for HALT (`ecall` with
    `t0 = 1`), and 1 for everything else. -/
def exitCode (u : PrivMachine) : Word :=
  if u.csrs.mcause = 8#32 ∧ u.core.reg 5#5 = 1#32 then u.core.reg 10#5 else 1#32

/-- How many steps the monitor takes from the trap vector to the park loop: an `ecall` for HALT, 57; an `ecall` for
    anything else, 62; any other trap, 59. -/
def trapSteps (u : PrivMachine) : Nat :=
  if u.csrs.mcause = 8#32 then (if u.core.reg 5#5 = 1#32 then 57 else 62) else 59

/-- The machine `k` steps into the payload, after boot's `60`. -/
def payloadAt (env : Rv32.Env) (s : PrivMachine) (k : Nat) : PrivMachine :=
  PrivMachine.run env k (PrivMachine.run env 60 s)

/-- The machine the monitor leaves after handling the trap at `u`. -/
def parkedAfter (env : Rv32.Env) (u : PrivMachine) : PrivMachine :=
  PrivMachine.run env (trapSteps u) u

/-- The bytes of the code entry, `[0x80010000, 0x80010080)`, are `C`'s. -/
def CodeSame (C : Word → Byte) (m : Word → Byte) : Prop :=
  ∀ x : Word, 0x80010000 ≤ x.toNat → x.toNat < 0x80010080 → m x = C x
