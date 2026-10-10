import Dev.Blocks

/-! # What the shell put in the region, and the loop's invariant -/

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word}

/-! ## Address arithmetic: nothing wraps inside the region -/

theorem addi_pos (hfit : base.toNat + 0x10000 ≤ 2^32) (c : Nat) {imm : BitVec 12} {v : Nat}
    (himm : imm.toNat = v) (hv : v < 2048) (h : c + v < 0x10000) :
    base + BitVec.ofNat 32 c + imm.signExtend 32 = base + BitVec.ofNat 32 (c + v) := by
  rw [show imm = BitVec.ofNat 12 v from BitVec.eq_of_toNat_eq (by simp [himm]; omega), se_small _ hv,
    off_add hfit _ _ h]

theorem addi_neg (hfit : base.toNat + 0x10000 ≤ 2^32) (c : Nat) {imm : BitVec 12} {v : Nat}
    (himm : imm.toNat = 4096 - v) (hv1 : 0 < v) (hv2 : v ≤ 2048) (h : v ≤ c) (hc : c < 0x10000) :
    base + BitVec.ofNat 32 c + imm.signExtend 32 = base + BitVec.ofNat 32 (c - v) := by
  rw [show imm = BitVec.ofNat 12 (4096 - v) from BitVec.eq_of_toNat_eq (by simp [himm]; omega),
    se_neg _ (by omega) (by omega)]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_add, toNat_off hfit c hc, BitVec.toNat_ofNat, toNat_off hfit _ (by omega)]
  have := hfit
  rw [Nat.mod_eq_of_lt (show 2 ^ 32 - 4096 + (4096 - v) < 2 ^ 32 by omega)]
  omega

theorem sub_off (hfit : base.toNat + 0x10000 ≤ 2^32) (a b : Nat) (hb : b ≤ a) (ha : a < 0x10000) :
    (base + BitVec.ofNat 32 a) - (base + BitVec.ofNat 32 b) = BitVec.ofNat 32 (a - b) := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_sub, toNat_off hfit a ha, toNat_off hfit b (by omega), BitVec.toNat_ofNat]
  omega

theorem ult_ofNat (a b : Nat) (ha : a < 2 ^ 32) (hb : b < 2 ^ 32) :
    (BitVec.ofNat 32 a).ult (BitVec.ofNat 32 b) = decide (a < b) := by
  simp [BitVec.ult, Nat.mod_eq_of_lt ha, Nat.mod_eq_of_lt hb]

theorem ult_off (hfit : base.toNat + 0x10000 ≤ 2^32) (a b : Nat) (ha : a < 0x10000) (hb : b < 0x10000) :
    (base + BitVec.ofNat 32 a).ult (base + BitVec.ofNat 32 b) = decide (a < b) := by
  simp only [BitVec.ult, toNat_off hfit a ha, toNat_off hfit b hb]
  by_cases h : a < b <;> simp [h] <;> omega

/-! ## The input -/

/-- What the shell put in the region before the kernel ran: the kernel and its
table (the image), the script, and the stack it starts with. -/
structure Input (m0 : Word → Byte) (base : Word) (scr : List Byte) (st0 : List Elem) : Prop where
  code : CodeAt m0 base kernel
  table : ∀ op < 256, readLE m0 (base + BitVec.ofNat 32 (TABLE + 4 * op)) 4 = table.getD op 0
  slen : readLE m0 (base + BitVec.ofNat 32 SLEN) 4 = scr.length
  script : ∀ i < scr.length, m0 (base + BitVec.ofNat 32 (SCRIPT + i)) = scr.getD i 0
  len : scr.length ≤ SMAX
  depth : readLE m0 (base + BitVec.ofNat 32 DEPTH) 4 = st0.length
  dmax : st0.length ≤ DMAX
  stack : Holds m0 base st0
  elems : ∀ e ∈ st0, e.length ≤ EMAX

theorem kernel_length : kernel.length = 881 := by decide

theorem table_entry : ∀ op < 256, table.getD op 0 % 4 = 0 ∧ table.getD op 0 < 4 * 881 := by decide

/-! ## The invariant -/

/-- Everything true of the machine between opcodes but where it is and the
next script byte: registers, the stack in its slots, everything outside the
stack's window as the shell left it. -/
structure Core (base : Word) (m0 : Word → Byte) (scr : List Byte) (c : Cfg) (s : Machine) : Prop where
  r9 : s.reg 9 = base
  r24 : s.reg 24 = base + BitVec.ofNat 32 TABLE
  r19 : s.reg 19 = base + BitVec.ofNat 32 (SCRIPT + scr.length)
  r23 : s.reg 23 = base + BitVec.ofNat 32 STACK
  r22 : s.reg 22 = base + BitVec.ofNat 32 TMP
  r25 : s.reg 25 = base + BitVec.ofNat 32 TMP
  r20 : s.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * c.st.length)
  r21 : s.reg 21 = BitVec.ofNat 32 c.sigs
  agree : Agree m0 s.mem base STACK LIMIT
  stack : Holds s.mem base c.st
  depth : c.st.length ≤ DMAX
  elems : ∀ e ∈ c.st, e.length ≤ EMAX
  sigs : c.sigs ≤ 1
  pcle : c.pc ≤ scr.length

/-- At the top of the loop: `pc` at LOOP, `s2` at the next script byte. -/
structure Inv (base : Word) (m0 : Word → Byte) (scr : List Byte) (c : Cfg) (s : Machine) : Prop where
  core : Core base m0 scr c s
  pc : s.pc = base + BitVec.ofNat 32 (4 * LOOP)
  r18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc)

theorem code_of_agree (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte} (hc : CodeAt m0 base kernel)
    (ha : Agree m0 m base STACK LIMIT) : CodeAt m base kernel := by
  refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => ?_) hc
  have hx : x = base + BitVec.ofNat 32 (x.toNat - base.toNat) := by
    apply BitVec.eq_of_toNat_eq; rw [kernel_length] at h2; rw [toNat_off hfit _ (by omega)]; omega
  rw [kernel_length] at h2
  rw [hx, ha _ (by omega) (by left; simp only [STACK]; omega)]

theorem Core.code (hp : Placed env base) {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}
    (hin : Input m0 base scr st0) {c : Cfg} {s : Machine} (h : Core base m0 scr c s) :
    CodeAt s.mem base kernel := code_of_agree hp.fit hin.code h.agree

/-- The registers `Core` speaks of, kept: the rest can change freely. -/
theorem Core.regs {base : Word} {m0 : Word → Byte} {scr : List Byte} {c : Cfg} {s s' : Machine}
    (h : Core base m0 scr c s) (hm : s'.mem = s.mem)
    (hr : ∀ r : Reg, r = 9 ∨ r = 24 ∨ r = 19 ∨ r = 23 ∨ r = 22 ∨ r = 25 ∨ r = 20 ∨ r = 21 →
      s'.reg r = s.reg r) : Core base m0 scr c s' where
  r9 := by rw [hr 9 (by decide), h.r9]
  r24 := by rw [hr 24 (by decide), h.r24]
  r19 := by rw [hr 19 (by decide), h.r19]
  r23 := by rw [hr 23 (by decide), h.r23]
  r22 := by rw [hr 22 (by decide), h.r22]
  r25 := by rw [hr 25 (by decide), h.r25]
  r20 := by rw [hr 20 (by decide), h.r20]
  r21 := by rw [hr 21 (by decide), h.r21]
  agree := hm ▸ h.agree
  stack := hm ▸ h.stack
  depth := h.depth
  elems := h.elems
  sigs := h.sigs
  pcle := h.pcle

end Exp228
