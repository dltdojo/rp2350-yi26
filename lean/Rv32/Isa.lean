/-
SPDX-License-Identifier: Apache-2.0

# RV32IM: the instructions, their 32-bit encodings, and the way back

This is the whole instruction set the verified kernel is allowed to use: RV32I's
computational, control-transfer, load and store instructions, the eight of the M
extension, and `ecall`. Everything else Hazard3 implements — the C, A, Zb*, Zbk*
extensions, CSR access, `fence`, `ebreak`, `mret` — has no constructor here, so
`decode` answers `none` for it and the machine model in `Rv32.Machine` faults.

That is deliberate, not an omission. The fewer encodings the model accepts, the
less of it has to be right: a kernel that decodes to `none` anywhere is simply
not a kernel any theorem here is about. `fence` is part of RV32I and is left
out anyway — on one hart with no caches between the kernel and its SRAM it would
be a no-op, and a no-op the kernel never needs is one more line to get wrong.

Encodings are computed in `Nat` and wrapped once at the end. Every field is a
`BitVec` of the width the specification gives it, so `omega` knows every bound
without being told, and the two theorems at the bottom — `decode_encode` and
`encode_decode` — say the encoder and the decoder agree in both directions:
every instruction survives a round trip, and the decoder accepts no word that
is not exactly the encoding of what it returns. The second is the one that
matters for the kernel: it means a word in `kernel.bin` has exactly one reading.

Whether these encodings are the ones the *specification* gives is a different
question that no theorem here can answer, because the specification is prose.
`experiments/exp201` answers it the only way available: every form, at its edge
values, assembled by LLVM and compared byte for byte.
-/

namespace Rv32

/-- A register number, `x0` to `x31`. -/
abbrev Reg := BitVec 5

inductive BrOp | beq | bne | blt | bge | bltu | bgeu
  deriving DecidableEq, Repr

inductive LdOp | lb | lh | lw | lbu | lhu
  deriving DecidableEq, Repr

inductive StOp | sb | sh | sw
  deriving DecidableEq, Repr

inductive IOp | addi | slti | sltiu | xori | ori | andi
  deriving DecidableEq, Repr

inductive ShOp | slli | srli | srai
  deriving DecidableEq, Repr

inductive ROp
  | add | sub | sll | slt | sltu | xor | srl | sra | or | and
  | mul | mulh | mulhsu | mulhu | div | divu | rem | remu
  deriving DecidableEq, Repr

/--
One instruction. Immediates are stored exactly as wide as the encoding carries
them, so that two different values here are always two different words:

- `jal`'s `off` is the offset in units of two bytes, bits 20..1 of the
  specification's `imm`, and the jump is `sext(off) * 2`;
- `br`'s `off` is likewise bits 12..1;
- `lui` and `auipc` carry bits 31..12.
-/
inductive Instr
  | lui   (rd : Reg) (imm : BitVec 20)
  | auipc (rd : Reg) (imm : BitVec 20)
  | jal   (rd : Reg) (off : BitVec 20)
  | jalr  (rd rs1 : Reg) (imm : BitVec 12)
  | br    (op : BrOp) (rs1 rs2 : Reg) (off : BitVec 12)
  | ld    (op : LdOp) (rd rs1 : Reg) (imm : BitVec 12)
  | st    (op : StOp) (rs1 rs2 : Reg) (imm : BitVec 12)
  | opi   (op : IOp) (rd rs1 : Reg) (imm : BitVec 12)
  | sh    (op : ShOp) (rd rs1 : Reg) (shamt : BitVec 5)
  | op    (op : ROp) (rd rs1 rs2 : Reg)
  | ecall
  deriving DecidableEq, Repr

/-! ## Function codes, one table per format -/

def BrOp.f3 : BrOp → Nat
  | .beq => 0 | .bne => 1 | .blt => 4 | .bge => 5 | .bltu => 6 | .bgeu => 7

def BrOp.ofF3 : Nat → Option BrOp
  | 0 => some .beq | 1 => some .bne | 4 => some .blt | 5 => some .bge
  | 6 => some .bltu | 7 => some .bgeu | _ => none

def LdOp.f3 : LdOp → Nat
  | .lb => 0 | .lh => 1 | .lw => 2 | .lbu => 4 | .lhu => 5

def LdOp.ofF3 : Nat → Option LdOp
  | 0 => some .lb | 1 => some .lh | 2 => some .lw | 4 => some .lbu | 5 => some .lhu
  | _ => none

def StOp.f3 : StOp → Nat
  | .sb => 0 | .sh => 1 | .sw => 2

def StOp.ofF3 : Nat → Option StOp
  | 0 => some .sb | 1 => some .sh | 2 => some .sw | _ => none

def IOp.f3 : IOp → Nat
  | .addi => 0 | .slti => 2 | .sltiu => 3 | .xori => 4 | .ori => 6 | .andi => 7

/-- `f3 = 1` and `f3 = 5` are the shifts, which are not `IOp`s. -/
def IOp.ofF3 : Nat → Option IOp
  | 0 => some .addi | 2 => some .slti | 3 => some .sltiu | 4 => some .xori
  | 6 => some .ori | 7 => some .andi | _ => none

/-- `(funct7, funct3)`. -/
def ShOp.f : ShOp → Nat × Nat
  | .slli => (0, 1) | .srli => (0, 5) | .srai => (32, 5)

def ShOp.ofF : Nat → Nat → Option ShOp
  | 0, 1 => some .slli | 0, 5 => some .srli | 32, 5 => some .srai | _, _ => none

/-- `(funct7, funct3)`. -/
def ROp.f : ROp → Nat × Nat
  | .add => (0, 0) | .sub => (32, 0) | .sll => (0, 1) | .slt => (0, 2)
  | .sltu => (0, 3) | .xor => (0, 4) | .srl => (0, 5) | .sra => (32, 5)
  | .or => (0, 6) | .and => (0, 7)
  | .mul => (1, 0) | .mulh => (1, 1) | .mulhsu => (1, 2) | .mulhu => (1, 3)
  | .div => (1, 4) | .divu => (1, 5) | .rem => (1, 6) | .remu => (1, 7)

def ROp.ofF : Nat → Nat → Option ROp
  | 0, 0 => some .add | 32, 0 => some .sub | 0, 1 => some .sll | 0, 2 => some .slt
  | 0, 3 => some .sltu | 0, 4 => some .xor | 0, 5 => some .srl | 32, 5 => some .sra
  | 0, 6 => some .or | 0, 7 => some .and
  | 1, 0 => some .mul | 1, 1 => some .mulh | 1, 2 => some .mulhsu | 1, 3 => some .mulhu
  | 1, 4 => some .div | 1, 5 => some .divu | 1, 6 => some .rem | 1, 7 => some .remu
  | _, _ => none

theorem BrOp.ofF3_f3 (o : BrOp) : BrOp.ofF3 o.f3 = some o := by cases o <;> rfl
theorem LdOp.ofF3_f3 (o : LdOp) : LdOp.ofF3 o.f3 = some o := by cases o <;> rfl
theorem StOp.ofF3_f3 (o : StOp) : StOp.ofF3 o.f3 = some o := by cases o <;> rfl
theorem IOp.ofF3_f3 (o : IOp) : IOp.ofF3 o.f3 = some o := by cases o <;> rfl
theorem ShOp.ofF_f (o : ShOp) : ShOp.ofF o.f.1 o.f.2 = some o := by cases o <;> rfl
theorem ROp.ofF_f (o : ROp) : ROp.ofF o.f.1 o.f.2 = some o := by cases o <;> rfl

theorem BrOp.f3_ofF3 {n : Nat} {o : BrOp} (h : BrOp.ofF3 n = some o) : o.f3 = n := by
  unfold BrOp.ofF3 at h; split at h <;> cases h <;> rfl
theorem LdOp.f3_ofF3 {n : Nat} {o : LdOp} (h : LdOp.ofF3 n = some o) : o.f3 = n := by
  unfold LdOp.ofF3 at h; split at h <;> cases h <;> rfl
theorem StOp.f3_ofF3 {n : Nat} {o : StOp} (h : StOp.ofF3 n = some o) : o.f3 = n := by
  unfold StOp.ofF3 at h; split at h <;> cases h <;> rfl
theorem IOp.f3_ofF3 {n : Nat} {o : IOp} (h : IOp.ofF3 n = some o) : o.f3 = n := by
  unfold IOp.ofF3 at h; split at h <;> cases h <;> rfl
theorem ShOp.f_ofF {a b : Nat} {o : ShOp} (h : ShOp.ofF a b = some o) : o.f = (a, b) := by
  unfold ShOp.ofF at h; split at h <;> cases h <;> rfl
theorem ROp.f_ofF {a b : Nat} {o : ROp} (h : ROp.ofF a b = some o) : o.f = (a, b) := by
  unfold ROp.ofF at h; split at h <;> cases h <;> rfl

theorem IOp.f3_ne_1 (o : IOp) : o.f3 ≠ 1 := by cases o <;> decide
theorem IOp.f3_ne_5 (o : IOp) : o.f3 ≠ 5 := by cases o <;> decide
theorem BrOp.f3_lt (o : BrOp) : o.f3 < 8 := by cases o <;> decide
theorem LdOp.f3_lt (o : LdOp) : o.f3 < 8 := by cases o <;> decide
theorem StOp.f3_lt (o : StOp) : o.f3 < 8 := by cases o <;> decide
theorem IOp.f3_lt (o : IOp) : o.f3 < 8 := by cases o <;> decide
theorem ShOp.f_lt (o : ShOp) : o.f.1 < 128 ∧ o.f.2 < 8 ∧ (o.f.2 = 1 ∨ o.f.2 = 5) := by
  cases o <;> decide
theorem ROp.f_lt (o : ROp) : o.f.1 < 128 ∧ o.f.2 < 8 := by cases o <;> decide

/-! ## Opcodes and fields -/

def OP_LUI    : Nat := 0x37
def OP_AUIPC  : Nat := 0x17
def OP_JAL    : Nat := 0x6f
def OP_JALR   : Nat := 0x67
def OP_BRANCH : Nat := 0x63
def OP_LOAD   : Nat := 0x03
def OP_STORE  : Nat := 0x23
def OP_IMM    : Nat := 0x13
def OP_OP     : Nat := 0x33
def ECALL     : Nat := 0x73

/-- The six formats, as sums of fields. -/
def rType (f7 rs2 rs1 f3 rd opc : Nat) : Nat :=
  f7 * 2^25 + rs2 * 2^20 + rs1 * 2^15 + f3 * 2^12 + rd * 2^7 + opc
def iType (imm rs1 f3 rd opc : Nat) : Nat :=
  imm * 2^20 + rs1 * 2^15 + f3 * 2^12 + rd * 2^7 + opc
def sType (imm rs2 rs1 f3 opc : Nat) : Nat :=
  (imm / 32) * 2^25 + rs2 * 2^20 + rs1 * 2^15 + f3 * 2^12 + (imm % 32) * 2^7 + opc
/-- `o` is `imm[12:1]`. The word holds `imm[12|10:5]` on top and `imm[4:1|11]`
where `rd` would be. -/
def bType (o rs2 rs1 f3 opc : Nat) : Nat :=
  ((o / 2^11) * 64 + (o / 16) % 64) * 2^25 + rs2 * 2^20 + rs1 * 2^15 + f3 * 2^12
    + ((o % 16) * 2 + (o / 2^10) % 2) * 2^7 + opc
def uType (imm rd opc : Nat) : Nat := imm * 2^12 + rd * 2^7 + opc
/-- `o` is `imm[20:1]`. The word holds `imm[20|10:1|11|19:12]`. -/
def jType (o rd opc : Nat) : Nat :=
  ((o / 2^19) * 2^19 + (o % 1024) * 2^9 + ((o / 1024) % 2) * 2^8 + (o / 2^11) % 256) * 2^12
    + rd * 2^7 + opc

def encodeNat : Instr → Nat
  | .lui rd imm        => uType imm.toNat rd.toNat OP_LUI
  | .auipc rd imm      => uType imm.toNat rd.toNat OP_AUIPC
  | .jal rd off        => jType off.toNat rd.toNat OP_JAL
  | .jalr rd rs1 imm   => iType imm.toNat rs1.toNat 0 rd.toNat OP_JALR
  | .br o rs1 rs2 off  => bType off.toNat rs2.toNat rs1.toNat o.f3 OP_BRANCH
  | .ld o rd rs1 imm   => iType imm.toNat rs1.toNat o.f3 rd.toNat OP_LOAD
  | .st o rs1 rs2 imm  => sType imm.toNat rs2.toNat rs1.toNat o.f3 OP_STORE
  | .opi o rd rs1 imm  => iType imm.toNat rs1.toNat o.f3 rd.toNat OP_IMM
  | .sh o rd rs1 sh    => rType o.f.1 sh.toNat rs1.toNat o.f.2 rd.toNat OP_IMM
  | .op o rd rs1 rs2   => rType o.f.1 rs2.toNat rs1.toNat o.f.2 rd.toNat OP_OP
  | .ecall             => ECALL

def encode (i : Instr) : BitVec 32 := BitVec.ofNat 32 (encodeNat i)

/-! ## Decoding -/

/-- The opcodes are written out as numbers here rather than as `OP_LUI` and the
rest: a proof that unfolded the name inside the `if` would leave the decision
procedure typed against the old term. -/
def decodeNat (n : Nat) : Option Instr :=
  let opc := n % 128
  let rd  := n / 2^7 % 32
  let f3  := n / 2^12 % 8
  let rs1 := n / 2^15 % 32
  let rs2 := n / 2^20 % 32
  let f7  := n / 2^25
  let immI := n / 2^20
  if opc = 0x37 then some (.lui (.ofNat 5 rd) (.ofNat 20 (n / 2^12)))
  else if opc = 0x17 then some (.auipc (.ofNat 5 rd) (.ofNat 20 (n / 2^12)))
  else if opc = 0x6f then
    let f := n / 2^12
    some (.jal (.ofNat 5 rd) (.ofNat 20
      ((f / 2^19) * 2^19 + (f % 256) * 2^11 + ((f / 2^8) % 2) * 2^10 + (f / 2^9) % 1024)))
  else if opc = 0x67 then
    if f3 = 0 then some (.jalr (.ofNat 5 rd) (.ofNat 5 rs1) (.ofNat 12 immI)) else none
  else if opc = 0x63 then
    (BrOp.ofF3 f3).map fun o => .br o (.ofNat 5 rs1) (.ofNat 5 rs2)
      (.ofNat 12 ((f7 / 64) * 2^11 + (rd % 2) * 2^10 + (f7 % 64) * 16 + rd / 2))
  else if opc = 0x03 then
    (LdOp.ofF3 f3).map fun o => .ld o (.ofNat 5 rd) (.ofNat 5 rs1) (.ofNat 12 immI)
  else if opc = 0x23 then
    (StOp.ofF3 f3).map fun o => .st o (.ofNat 5 rs1) (.ofNat 5 rs2) (.ofNat 12 (f7 * 32 + rd))
  else if opc = 0x13 then
    if f3 = 1 ∨ f3 = 5 then
      (ShOp.ofF f7 f3).map fun o => .sh o (.ofNat 5 rd) (.ofNat 5 rs1) (.ofNat 5 rs2)
    else
      (IOp.ofF3 f3).map fun o => .opi o (.ofNat 5 rd) (.ofNat 5 rs1) (.ofNat 12 immI)
  else if opc = 0x33 then
    (ROp.ofF f7 f3).map fun o => .op o (.ofNat 5 rd) (.ofNat 5 rs1) (.ofNat 5 rs2)
  else if n = 0x73 then some .ecall
  else none

def decode (w : BitVec 32) : Option Instr := decodeNat w.toNat

/-! ## Both directions -/

-- A linear fact about the encoding. `omega` alone hits Lean's recursion limit
-- on a sum multiplied by a large power of two — `(c * 32 + x) * 2^20` — and is
-- fine once the product is distributed, so distribute it first. It names `hn`,
-- the hypothesis that says what the word is, on purpose: hence no hygiene.
set_option hygiene false in
local macro "lin" : tactic =>
  `(tactic| first | (subst hn; simp only [Nat.add_mul, Nat.mul_assoc]; omega) | omega)

-- The last step of the way back: the fields, put back, are the word.
set_option hygiene false in
local macro "rfin" : tactic =>
  `(tactic| (subst hs; (try simp only [Nat.add_mul, Nat.mul_assoc]); omega))

/-- Take every `if` in the goal, keep the branch the hypotheses allow, and let
`omega` throw away the ones they do not. -/
local macro "walk" : tactic =>
  `(tactic| repeat' (split <;> (try (exfalso; omega))))

theorem encodeNat_lt (i : Instr) : encodeNat i < 2^32 := by
  cases i <;> simp only [encodeNat, uType, jType, iType, bType, sType, rType, ECALL,
    OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_BRANCH, OP_LOAD, OP_STORE, OP_IMM, OP_OP]
  all_goals first
    | omega
    | (rename_i o _ _ _
       first
         | (have := BrOp.f3_lt o; omega)
         | (have := LdOp.f3_lt o; omega)
         | (have := StOp.f3_lt o; omega)
         | (have := IOp.f3_lt o; omega)
         | (have := ShOp.f_lt o; omega)
         | (have := ROp.f_lt o; omega))

theorem toNat_encode (i : Instr) : (encode i).toNat = encodeNat i := by
  simp [encode, Nat.mod_eq_of_lt (encodeNat_lt i)]

/-- A field of a word, given the word as `(q * m + f) * p + r`: everything
above it, it, and everything below it. Stated this way, each premise is a
linear fact, which `omega` proves where it cannot prove the conclusion. -/
private theorem field {n p m q f r : Nat} (h : n = (q * m + f) * p + r) (hr : r < p)
    (hf : f < m) : n / p % m = f := by
  have hp : 0 < p := by omega
  have : n / p = q * m + f := by
    subst h; rw [Nat.add_comm, Nat.add_mul_div_right _ _ hp, Nat.div_eq_of_lt hr, Nat.zero_add]
  rw [this, Nat.add_comm, Nat.add_mul_mod_self_right, Nat.mod_eq_of_lt hf]

/-- A twelve-bit number is its four B-type pieces put back together. -/
private theorem split12 (x : Nat) (_ : x < 4096) :
    x = (x / 2^11) * 2^11 + (x / 2^10 % 2) * 2^10 + (x / 16 % 64) * 16 + x % 16 := by
  have h1 := Nat.div_add_mod x 16
  have h2 := Nat.div_add_mod (x / 16) 64
  have h3 := Nat.div_add_mod (x / 2^10) 2
  have e1 : x / 16 / 64 = x / 2^10 := by rw [Nat.div_div_eq_div_mul]
  have e2 : x / 2^10 / 2 = x / 2^11 := by rw [Nat.div_div_eq_div_mul]
  omega

/-- A twenty-bit number is its four J-type pieces put back together. -/
private theorem split20 (x : Nat) (_ : x < 2^20) :
    x = (x / 2^19) * 2^19 + (x / 2^11 % 256) * 2^11 + (x / 1024 % 2) * 1024 + x % 1024 := by
  have h1 := Nat.div_add_mod x 1024
  have h2 := Nat.div_add_mod (x / 1024) 2
  have h3 := Nat.div_add_mod (x / 2^11) 256
  have e1 : x / 1024 / 2 = x / 2^11 := by rw [Nat.div_div_eq_div_mul]
  have e2 : x / 2^11 / 256 = x / 2^19 := by rw [Nat.div_div_eq_div_mul]
  omega

private theorem ofNat_eq {w : Nat} {x : BitVec w} {n : Nat} (h : n % 2^w = x.toNat) :
    BitVec.ofNat w n = x := by
  apply BitVec.eq_of_toNat_eq; simpa using h

private theorem dec_br (o : BrOp) (rs1 rs2 : Reg) (off : BitVec 12) (n : Nat)
    (hn : n = encodeNat (.br o rs1 rs2 off)) : decodeNat n = some (.br o rs1 rs2 off) := by
  have := BrOp.f3_lt o
  simp only [encodeNat, bType, OP_BRANCH] at hn
  -- The offset is scattered over four places in the word. Naming the four
  -- pieces makes every field a plain linear sum, which is what omega wants:
  -- it does not implement the "dark shadow" step, so a goal with several
  -- divisions of one number can defeat it even when it is true.
  have hoff := split12 off.toNat off.isLt
  have := off.isLt
  have ha : off.toNat / 2^11 < 2 := by omega
  have hb : off.toNat / 2^10 % 2 < 2 := Nat.mod_lt _ (by decide)
  have hc : off.toNat / 16 % 64 < 64 := Nat.mod_lt _ (by decide)
  have hd : off.toNat % 16 < 16 := Nat.mod_lt _ (by decide)
  generalize off.toNat / 2^11 = a, off.toNat / 2^10 % 2 = b, off.toNat / 16 % 64 = c,
    off.toNat % 16 = d at hn hoff ha hb hc hd
  -- One field at a time, each from `hn` alone, and all of them before the
  -- `if`s are taken: omega sees every hypothesis, and each fact about one
  -- division of `n` makes the next harder for it.
  have hop : n % 128 = 0x63 := by omega
  have hf3 : n / 2^12 % 8 = o.f3 := by
    refine field (q := (a * 64 + c) * 2^10 + rs2.toNat * 2^5 + rs1.toNat)
      (r := (d * 2 + b) * 2^7 + 0x63) ?_ ?_ ?_ <;> lin
  have hr1 : n / 2^15 % 32 = rs1.toNat := by
    refine field (q := (a * 64 + c) * 2^5 + rs2.toNat)
      (r := o.f3 * 2^12 + (d * 2 + b) * 2^7 + 0x63) ?_ ?_ ?_ <;> lin
  have hr2 : n / 2^20 % 32 = rs2.toNat := by
    refine field (q := a * 64 + c)
      (r := rs1.toNat * 2^15 + o.f3 * 2^12 + (d * 2 + b) * 2^7 + 0x63) ?_ ?_ ?_ <;> lin
  have hf7 : n / 2^25 = a * 64 + c := by
    have h := field (n := n) (p := 2^25) (m := 2^7) (q := 0) (f := a * 64 + c)
      (r := rs2.toNat * 2^20 + rs1.toNat * 2^15 + o.f3 * 2^12 + (d * 2 + b) * 2^7 + 0x63)
      (by lin) (by lin) (by lin)
    have : n / 2^25 < 2^7 := by rw [Nat.div_lt_iff_lt_mul (by decide)]; lin
    rw [Nat.mod_eq_of_lt this] at h; exact h
  have hrd : n / 2^7 % 32 = d * 2 + b := by
    refine field (q := (a * 64 + c) * 2^13 + rs2.toNat * 2^8 + rs1.toNat * 2^3 + o.f3)
      (r := 0x63) ?_ ?_ ?_ <;> lin
  have e1 : (a * 64 + c) / 64 = a := by omega
  have e2 : (a * 64 + c) % 64 = c := by omega
  have e3 : (d * 2 + b) / 2 = d := by omega
  have e4 : (d * 2 + b) % 2 = b := by omega
  clear hn
  simp only [decodeNat]; walk
  rw [hf3, BrOp.ofF3_f3]
  simp only [Option.map_some, Option.some.injEq, Instr.br.injEq, true_and]
  rw [hf7, hrd, hr1, hr2, e1, e2, e3, e4]
  clear hop hf3 hr1 hr2 hf7 hrd e1 e2 e3 e4
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_ld (o : LdOp) (rd rs1 : Reg) (imm : BitVec 12) (n : Nat)
    (hn : n = encodeNat (.ld o rd rs1 imm)) : decodeNat n = some (.ld o rd rs1 imm) := by
  have := LdOp.f3_lt o
  simp only [encodeNat, iType, OP_LOAD] at hn
  simp only [decodeNat]; walk
  rw [show n / 2^12 % 8 = o.f3 by omega, LdOp.ofF3_f3]
  simp only [Option.map_some, Option.some.injEq, Instr.ld.injEq, true_and]
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_st (o : StOp) (rs1 rs2 : Reg) (imm : BitVec 12) (n : Nat)
    (hn : n = encodeNat (.st o rs1 rs2 imm)) : decodeNat n = some (.st o rs1 rs2 imm) := by
  have := StOp.f3_lt o
  simp only [encodeNat, sType, OP_STORE] at hn
  -- The immediate is in two places; name both, as `br` does with four.
  have hrec : imm.toNat = imm.toNat / 32 * 32 + imm.toNat % 32 := by omega
  have hh : imm.toNat / 32 < 128 := by omega
  have hl : imm.toNat % 32 < 32 := Nat.mod_lt _ (by decide)
  generalize imm.toNat / 32 = h, imm.toNat % 32 = l at hn hrec hh hl
  have hop : n % 128 = 0x23 := by omega
  have hf3 : n / 2^12 % 8 = o.f3 := by
    refine field (q := h * 2^10 + rs2.toNat * 2^5 + rs1.toNat) (r := l * 2^7 + 0x23)
      ?_ ?_ ?_ <;> lin
  have hr1 : n / 2^15 % 32 = rs1.toNat := by
    refine field (q := h * 2^5 + rs2.toNat) (r := o.f3 * 2^12 + l * 2^7 + 0x23)
      ?_ ?_ ?_ <;> lin
  have hr2 : n / 2^20 % 32 = rs2.toNat := by
    refine field (q := h) (r := rs1.toNat * 2^15 + o.f3 * 2^12 + l * 2^7 + 0x23)
      ?_ ?_ ?_ <;> lin
  have hf7 : n / 2^25 = h := by
    have e := field (n := n) (p := 2^25) (m := 2^7) (q := 0) (f := h)
      (r := rs2.toNat * 2^20 + rs1.toNat * 2^15 + o.f3 * 2^12 + l * 2^7 + 0x23)
      (by lin) (by lin) (by lin)
    have : n / 2^25 < 2^7 := by rw [Nat.div_lt_iff_lt_mul (by decide)]; lin
    rw [Nat.mod_eq_of_lt this] at e; exact e
  have hrd : n / 2^7 % 32 = l := by
    refine field (q := h * 2^13 + rs2.toNat * 2^8 + rs1.toNat * 2^3 + o.f3)
      (r := 0x23) ?_ ?_ ?_ <;> lin
  clear hn
  simp only [decodeNat]; walk
  rw [hf3, StOp.ofF3_f3]
  simp only [Option.map_some, Option.some.injEq, Instr.st.injEq, true_and]
  rw [hf7, hrd, hr1, hr2]
  clear hop hf3 hr1 hr2 hf7 hrd
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_opi (o : IOp) (rd rs1 : Reg) (imm : BitVec 12) (n : Nat)
    (hn : n = encodeNat (.opi o rd rs1 imm)) : decodeNat n = some (.opi o rd rs1 imm) := by
  have := IOp.f3_lt o; have := IOp.f3_ne_1 o; have := IOp.f3_ne_5 o
  simp only [encodeNat, iType, OP_IMM] at hn
  simp only [decodeNat]; walk
  rw [show n / 2^12 % 8 = o.f3 by omega, IOp.ofF3_f3]
  simp only [Option.map_some, Option.some.injEq, Instr.opi.injEq, true_and]
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_sh (o : ShOp) (rd rs1 : Reg) (sa : BitVec 5) (n : Nat)
    (hn : n = encodeNat (.sh o rd rs1 sa)) : decodeNat n = some (.sh o rd rs1 sa) := by
  have := ShOp.f_lt o
  simp only [encodeNat, rType, OP_IMM] at hn
  simp only [decodeNat]; walk
  rw [show n / 2^12 % 8 = o.f.2 by omega, show n / 2^25 = o.f.1 by omega, ShOp.ofF_f]
  simp only [Option.map_some, Option.some.injEq, Instr.sh.injEq, true_and]
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_op (o : ROp) (rd rs1 rs2 : Reg) (n : Nat)
    (hn : n = encodeNat (.op o rd rs1 rs2)) : decodeNat n = some (.op o rd rs1 rs2) := by
  have := ROp.f_lt o
  simp only [encodeNat, rType, OP_OP] at hn
  simp only [decodeNat]; walk
  rw [show n / 2^12 % 8 = o.f.2 by omega, show n / 2^25 = o.f.1 by omega, ROp.ofF_f]
  simp only [Option.map_some, Option.some.injEq, Instr.op.injEq, true_and]
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_lui (rd : Reg) (imm : BitVec 20) (n : Nat)
    (hn : n = encodeNat (.lui rd imm)) : decodeNat n = some (.lui rd imm) := by
  simp only [encodeNat, uType, OP_LUI] at hn
  simp only [decodeNat]; walk
  simp only [Option.some.injEq, Instr.lui.injEq]
  refine ⟨?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_auipc (rd : Reg) (imm : BitVec 20) (n : Nat)
    (hn : n = encodeNat (.auipc rd imm)) : decodeNat n = some (.auipc rd imm) := by
  simp only [encodeNat, uType, OP_AUIPC] at hn
  simp only [decodeNat]; walk
  simp only [Option.some.injEq, Instr.auipc.injEq]
  refine ⟨?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_jalr (rd rs1 : Reg) (imm : BitVec 12) (n : Nat)
    (hn : n = encodeNat (.jalr rd rs1 imm)) : decodeNat n = some (.jalr rd rs1 imm) := by
  simp only [encodeNat, iType, OP_JALR] at hn
  simp only [decodeNat]; walk
  simp only [Option.some.injEq, Instr.jalr.injEq]
  refine ⟨?_, ?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem dec_ecall (n : Nat)
    (hn : n = encodeNat .ecall) : decodeNat n = some .ecall := by
  simp only [encodeNat, ECALL] at hn
  subst hn; rfl

private theorem dec_jal (rd : Reg) (off : BitVec 20) (n : Nat)
    (hn : n = encodeNat (.jal rd off)) : decodeNat n = some (.jal rd off) := by
  simp only [encodeNat, jType, OP_JAL] at hn
  -- The same treatment as `br`'s offset: four pieces, each named.
  have hoff := split20 off.toNat off.isLt
  have := off.isLt
  have ha : off.toNat / 2^19 < 2 := by omega
  have hb : off.toNat / 2^11 % 256 < 256 := Nat.mod_lt _ (by decide)
  have hc : off.toNat / 1024 % 2 < 2 := Nat.mod_lt _ (by decide)
  have hd : off.toNat % 1024 < 1024 := Nat.mod_lt _ (by decide)
  generalize off.toNat / 2^19 = a, off.toNat / 2^11 % 256 = b, off.toNat / 1024 % 2 = c,
    off.toNat % 1024 = d at hn hoff ha hb hc hd
  have hop : n % 128 = 0x6f := by lin
  have hrd : n / 2^7 % 32 = rd.toNat := by
    refine field (q := a * 2^19 + d * 2^9 + c * 2^8 + b) (r := 0x6f) ?_ ?_ ?_ <;> lin
  have hf : n / 2^12 = a * 2^19 + d * 2^9 + c * 2^8 + b := by
    have h := field (n := n) (p := 2^12) (m := 2^20) (q := 0)
      (f := a * 2^19 + d * 2^9 + c * 2^8 + b) (r := rd.toNat * 2^7 + 0x6f)
      (by lin) (by lin) (by lin)
    have : n / 2^12 < 2^20 := by rw [Nat.div_lt_iff_lt_mul (by decide)]; lin
    rw [Nat.mod_eq_of_lt this] at h; exact h
  clear hn
  simp only [decodeNat]; walk
  simp only [Option.some.injEq, Instr.jal.injEq]
  rw [hrd, hf]
  have e1 : (a * 2^19 + d * 2^9 + c * 2^8 + b) / 2^19 = a := by omega
  have e2 : (a * 2^19 + d * 2^9 + c * 2^8 + b) % 256 = b := by omega
  have e3 : (a * 2^19 + d * 2^9 + c * 2^8 + b) / 2^8 % 2 = c := by
    refine field (q := a * 2^10 + d) (r := b) ?_ ?_ ?_ <;> omega
  have e4 : (a * 2^19 + d * 2^9 + c * 2^8 + b) / 2^9 % 1024 = d := by
    refine field (q := a) (r := c * 2^8 + b) ?_ ?_ ?_ <;> omega
  rw [e1, e2, e3, e4]
  clear hop hrd hf e1 e2 e3 e4
  refine ⟨?_, ?_⟩ <;> apply ofNat_eq <;> omega

private theorem decodeNat_encodeNat (i : Instr) (n : Nat) (hn : n = encodeNat i) :
    decodeNat n = some i := by
  cases i with
  | br o rs1 rs2 off => exact dec_br o rs1 rs2 off n hn
  | ld o rd rs1 imm => exact dec_ld o rd rs1 imm n hn
  | st o rs1 rs2 imm => exact dec_st o rs1 rs2 imm n hn
  | opi o rd rs1 imm => exact dec_opi o rd rs1 imm n hn
  | sh o rd rs1 sa => exact dec_sh o rd rs1 sa n hn
  | op o rd rs1 rs2 => exact dec_op o rd rs1 rs2 n hn
  | lui rd imm => exact dec_lui rd imm n hn
  | auipc rd imm => exact dec_auipc rd imm n hn
  | jalr rd rs1 imm => exact dec_jalr rd rs1 imm n hn
  | ecall => exact dec_ecall n hn
  | jal rd off => exact dec_jal rd off n hn

/-- **Every instruction survives a round trip.** -/
theorem decode_encode (i : Instr) : decode (encode i) = some i :=
  decodeNat_encodeNat i _ (toNat_encode i)

/-- A word is its six R-type fields put back together. -/
private theorem split32 (n : Nat) :
    n % 2^32 = n / 2^25 % 128 * 2^25 + n / 2^20 % 32 * 2^20 + n / 2^15 % 32 * 2^15
      + n / 2^12 % 8 * 2^12 + n / 2^7 % 32 * 2^7 + n % 128 := by
  have h0 := Nat.div_add_mod n 128
  have h1 := Nat.div_add_mod (n / 2^7) 32
  have h2 := Nat.div_add_mod (n / 2^12) 8
  have h3 := Nat.div_add_mod (n / 2^15) 32
  have h4 := Nat.div_add_mod (n / 2^20) 32
  have h5 := Nat.div_add_mod (n / 2^25) 128
  have e1 : n / 2^7 / 32 = n / 2^12 := by rw [Nat.div_div_eq_div_mul]
  have e2 : n / 2^12 / 8 = n / 2^15 := by rw [Nat.div_div_eq_div_mul]
  have e3 : n / 2^15 / 32 = n / 2^20 := by rw [Nat.div_div_eq_div_mul]
  have e4 : n / 2^20 / 32 = n / 2^25 := by rw [Nat.div_div_eq_div_mul]
  have e5 : n / 2^25 / 128 = n / 2^32 := by rw [Nat.div_div_eq_div_mul]
  have e0 : n / 128 = n / 2^7 := rfl
  have h6 := Nat.div_add_mod n (2^32)
  omega

private theorem divq {n p q r : Nat} (h : n = q * p + r) (hr : r < p) : n / p = q := by
  subst h
  rw [Nat.add_comm, Nat.add_mul_div_right _ _ (by omega), Nat.div_eq_of_lt hr, Nat.zero_add]

private theorem modq {n p q r : Nat} (h : n = q * p + r) (hr : r < p) : n % p = r := by
  subst h; rw [Nat.add_comm, Nat.add_mul_mod_self_right, Nat.mod_eq_of_lt hr]

-- A linear identity between two ways of writing the same word: distribute,
-- then let omega compare.
local macro "dist" : tactic =>
  `(tactic| ((try simp only [Nat.add_mul, Nat.mul_add, Nat.mul_assoc]) <;> omega))

private theorem encodeNat_decodeNat (n : Nat) (hw : n < 2^32) {i : Instr}
    (h : decodeNat n = some i) : encodeNat i = n := by
  have hs := split32 n
  rw [Nat.mod_eq_of_lt hw] at hs
  have hf7 : n / 2^25 % 128 = n / 2^25 := Nat.mod_eq_of_lt (by
    rw [Nat.div_lt_iff_lt_mul (by decide)]; omega)
  rw [hf7] at hs
  have bF7 : n / 2^25 < 128 := by rw [← hf7]; exact Nat.mod_lt _ (by decide)
  have bR2 : n / 2^20 % 32 < 32 := Nat.mod_lt _ (by decide)
  have bR1 : n / 2^15 % 32 < 32 := Nat.mod_lt _ (by decide)
  have bF3 : n / 2^12 % 8 < 8 := Nat.mod_lt _ (by decide)
  have bRD : n / 2^7 % 32 < 32 := Nat.mod_lt _ (by decide)
  have bOP : n % 128 < 128 := Nat.mod_lt _ (by decide)
  simp only [decodeNat] at h
  generalize n / 2^25 = F7, n / 2^20 % 32 = R2, n / 2^15 % 32 = R1, n / 2^12 % 8 = F3,
    n / 2^7 % 32 = RD, n % 128 = OP at h hs bF7 bR2 bR1 bF3 bRD bOP
  -- The two immediates that are not single fields, in terms of the fields.
  have hU : n / 2^12 = F7 * 2^13 + R2 * 2^8 + R1 * 2^3 + F3 := by
    apply divq (r := RD * 2^7 + OP) _ (by omega)
    subst hs; simp only [Nat.add_mul, Nat.mul_assoc]; omega
  have hI : n / 2^20 = F7 * 32 + R2 := by
    apply divq (r := R1 * 2^15 + F3 * 2^12 + RD * 2^7 + OP) _ (by omega)
    subst hs; simp only [Nat.add_mul, Nat.mul_assoc]; omega
  rw [hU, hI] at h
  clear hU hI hf7 hw
  split at h
  · cases h; simp only [encodeNat, uType, OP_LUI, BitVec.toNat_ofNat]; rfin
  split at h
  · cases h; simp only [encodeNat, uType, OP_AUIPC, BitVec.toNat_ofNat]; rfin
  split at h
  · cases h
    -- The J-type immediate, scattered over F7, R2, R1 and F3: split the two
    -- fields it cuts through, then read each piece off, one division at a time.
    have hA := Nat.div_add_mod F7 64
    have hC := Nat.div_add_mod R2 2
    have bB : F7 % 64 < 64 := Nat.mod_lt _ (by decide)
    have bD : R2 % 2 < 2 := Nat.mod_lt _ (by decide)
    have bA : F7 / 64 < 2 := by omega
    have bC : R2 / 2 < 16 := by omega
    generalize F7 / 64 = A, F7 % 64 = B, R2 / 2 = C, R2 % 2 = D at hA hC bA bB bC bD
    subst hA hC
    have k1 : ((64 * A + B) * 2^13 + (2 * C + D) * 2^8 + R1 * 2^3 + F3) / 2^19 = A :=
      divq (r := B * 2^13 + C * 2^9 + D * 2^8 + R1 * 2^3 + F3) (by dist) (by omega)
    have k2 : ((64 * A + B) * 2^13 + (2 * C + D) * 2^8 + R1 * 2^3 + F3) % 256 = R1 * 8 + F3 :=
      modq (q := A * 2^11 + B * 2^5 + C * 2 + D) (by dist) (by omega)
    have k3 : ((64 * A + B) * 2^13 + (2 * C + D) * 2^8 + R1 * 2^3 + F3) / 2^8 % 2 = D :=
      field (q := A * 2^10 + B * 2^4 + C) (r := R1 * 2^3 + F3) (by dist) (by omega) (by omega)
    have k4 : ((64 * A + B) * 2^13 + (2 * C + D) * 2^8 + R1 * 2^3 + F3) / 2^9 % 1024
        = B * 16 + C :=
      field (q := A) (r := D * 2^8 + R1 * 2^3 + F3) (by dist) (by omega) (by omega)
    simp only [encodeNat, jType, OP_JAL, BitVec.toNat_ofNat]
    rw [k1, k2, k3, k4]
    have x : (A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) % 2^20
        = A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C) := Nat.mod_eq_of_lt (by omega)
    rw [x]
    have m1 : (A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) / 2^19 = A :=
      divq (r := (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) (by dist) (by omega)
    have m2 : (A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) % 1024 = B * 16 + C :=
      modq (q := A * 2^9 + (R1 * 8 + F3) * 2 + D) (by dist) (by omega)
    have m3 : (A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) / 1024 % 2 = D :=
      field (q := A * 2^8 + (R1 * 8 + F3)) (r := B * 16 + C) (by dist) (by omega) (by omega)
    have m4 : (A * 2^19 + (R1 * 8 + F3) * 2^11 + D * 2^10 + (B * 16 + C)) / 2^11 % 256
        = R1 * 8 + F3 :=
      field (q := A) (r := D * 2^10 + (B * 16 + C)) (by dist) (by omega) (by omega)
    rw [m1, m2, m3, m4]
    have : RD % 32 = RD := Nat.mod_eq_of_lt bRD
    rw [this]; rfin
  split at h
  · split at h
    · cases h; simp only [encodeNat, iType, OP_JALR, BitVec.toNat_ofNat]; rfin
    · cases h
  split at h
  · cases h3 : BrOp.ofF3 F3 with
    | none => rw [h3] at h; cases h
    | some o =>
      rw [h3] at h; cases h
      have := BrOp.f3_ofF3 h3
      -- The B-type immediate cuts F7 and RD: the same treatment as `jal`.
      have hA := Nat.div_add_mod F7 64
      have hE := Nat.div_add_mod RD 2
      have bB : F7 % 64 < 64 := Nat.mod_lt _ (by decide)
      have bG : RD % 2 < 2 := Nat.mod_lt _ (by decide)
      have bA : F7 / 64 < 2 := by omega
      have bE : RD / 2 < 16 := by omega
      generalize F7 / 64 = A, F7 % 64 = B, RD / 2 = E, RD % 2 = G at hA hE bA bB bE bG
      subst hA hE
      have k1 : (64 * A + B) / 64 = A := by omega
      have k2 : (64 * A + B) % 64 = B := by omega
      have k3 : (2 * E + G) / 2 = E := by omega
      have k4 : (2 * E + G) % 2 = G := by omega
      simp only [encodeNat, bType, OP_BRANCH, BitVec.toNat_ofNat]
      try rw [k1, k2, k3, k4]
      have x : (A * 2^11 + G * 2^10 + B * 16 + E) % 2^12 = A * 2^11 + G * 2^10 + B * 16 + E :=
        Nat.mod_eq_of_lt (by omega)
      rw [x]
      have m1 : (A * 2^11 + G * 2^10 + B * 16 + E) / 2^11 = A :=
        divq (r := G * 2^10 + B * 16 + E) (by dist) (by omega)
      have m2 : (A * 2^11 + G * 2^10 + B * 16 + E) / 16 % 64 = B :=
        field (q := A * 2 + G) (r := E) (by dist) (by omega) (by omega)
      have m3 : (A * 2^11 + G * 2^10 + B * 16 + E) % 16 = E :=
        modq (q := A * 2^7 + G * 2^6 + B) (by dist) (by omega)
      have m4 : (A * 2^11 + G * 2^10 + B * 16 + E) / 2^10 % 2 = G :=
        field (q := A) (r := B * 16 + E) (by dist) (by omega) (by omega)
      rw [m1, m2, m3, m4]
      have : R1 % 32 = R1 := Nat.mod_eq_of_lt bR1
      have : R2 % 32 = R2 := Nat.mod_eq_of_lt bR2
      simp only [*]; rfin
  split at h
  · cases h3 : LdOp.ofF3 F3 with
    | none => rw [h3] at h; cases h
    | some o =>
      rw [h3] at h; cases h
      have := LdOp.f3_ofF3 h3
      simp only [encodeNat, iType, OP_LOAD, BitVec.toNat_ofNat]; rfin
  split at h
  · cases h3 : StOp.ofF3 F3 with
    | none => rw [h3] at h; cases h
    | some o =>
      rw [h3] at h; cases h
      have := StOp.f3_ofF3 h3
      simp only [encodeNat, sType, OP_STORE, BitVec.toNat_ofNat]; rfin
  split at h
  · split at h
    · cases h3 : ShOp.ofF F7 F3 with
      | none => rw [h3] at h; cases h
      | some o =>
        rw [h3] at h; cases h
        have := ShOp.f_ofF h3
        simp only [encodeNat, rType, OP_IMM, BitVec.toNat_ofNat]
        rw [this]; rfin
    · cases h3 : IOp.ofF3 F3 with
      | none => rw [h3] at h; cases h
      | some o =>
        rw [h3] at h; cases h
        have := IOp.f3_ofF3 h3
        simp only [encodeNat, iType, OP_IMM, BitVec.toNat_ofNat]; rfin
  split at h
  · cases h3 : ROp.ofF F7 F3 with
    | none => rw [h3] at h; cases h
    | some o =>
      rw [h3] at h; cases h
      have := ROp.f_ofF h3
      simp only [encodeNat, rType, OP_OP, BitVec.toNat_ofNat]
      rw [this]; rfin
  split at h
  · cases h; simp only [encodeNat, ECALL]; omega
  · cases h

/-- **The decoder accepts no word that is not exactly the encoding of what it
returns.** No alias, no ignored bit: a word of `kernel.bin` has one reading. -/
theorem encode_decode {w : BitVec 32} {i : Instr} (h : decode w = some i) : encode i = w := by
  apply BitVec.eq_of_toNat_eq
  rw [toNat_encode]
  exact encodeNat_decodeNat w.toNat w.isLt h

end Rv32
