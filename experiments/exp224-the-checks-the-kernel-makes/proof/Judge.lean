/-
SPDX-License-Identifier: Apache-2.0

# exp224 — the checks the kernel makes

exp223's shell checked, in C, what `conditions` says about each of its three
sources. Here a kernel makes those checks, and the C shell only gathers what
they are made on: for each source a record of facts, which the kernel reads.

  records   three of 0x100 bytes from base + 0x1000, one a source:
    0x00 mcause   0x04 t0   0x08 a0   0x0c minstret       what the trap said
    0x10 the RTL's minstret for HALT 0, 0x14 for HALT 1     what it should say
    0x18 nonzero if the chip's SHA-256 block reported no error
    0x20 SHA-256 of the kernel's bytes    0x40 kernel.sha256
    0x60 the 32 bytes at 0x2140           0x80 SHA-256 of the samples
    0xa0 the region's hash after          0xc0 and before

For each record the kernel makes exp223's five checks, without a branch:
  1 the kernel's bytes are kernel.sha256's, and the block reported no error
  2 it halted (mcause 8, t0 1) with 0 or 1
  3 minstret is the one for the code it halted with
  4 halting with 0, the digest is the samples' SHA-256
  5 the region is as it was
and gathers the failures as five bits. The first record with a failure is
the verdict, 1; failing that, the TRNG's samples withheld, 3, or a broken
source let through, 4; failing all of those, 0. The verdict halts as

  a0 = verdict | source << 3 | failures << 6

and the kernel writes nothing.

   0      auipc s0, 0
   1-2    s1 = base + 0x1000        the first record
   3      s2 = 0                    the source
   4-102  three 32-byte comparisons into s4, s5, s6
   103-109 the seven words
   110-141 the five checks, the failures in a6
   142-148 failures: HALT 1 | s << 3 | failures << 6
   149-159 the TRNG withheld: HALT 3; a broken source passed: HALT 4 | s << 3
   160-163 the next record, round to 4 while s < 3
   164-166 HALT 0
-/
import Rv32.Blocks
import Rv32.Line
import Rv32.Within
import Rv32.Asm

set_option maxRecDepth 20000

namespace Exp224
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S4 : Reg := 20
def S5 : Reg := 21
def S6 : Reg := 22
def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def T5 : Reg := 30
def T6 : Reg := 31
def A3 : Reg := 13
def A4 : Reg := 14
def A5 : Reg := 15
def A6 : Reg := 16
def A7 : Reg := 17

/-- Eight words at `s1 + oa` and `s1 + ob` compared into `acc`, no early exit. -/
def compare (acc : Reg) (oa ob : Nat) : List Instr :=
  (List.range 8).flatMap fun j =>
    [ .ld .lw T1 S1 (BitVec.ofNat 12 (oa + 4 * j)), .ld .lw T2 S1 (BitVec.ofNat 12 (ob + 4 * j)),
      .op .xor T1 T1 T2, .op .or acc acc T1 ]

def setup : List Instr := [ .auipc S0 0, .lui T1 1, .op .add S1 S0 T1, .opi .addi S2 0 0 ]

def compares : List Instr :=
  [ .opi .addi S4 0 0 ] ++ compare S4 0x20 0x40 ++
  [ .opi .addi S5 0 0 ] ++ compare S5 0x60 0x80 ++
  [ .opi .addi S6 0 0 ] ++ compare S6 0xa0 0xc0

def loads : List Instr := [
  .ld .lw T3 S1 0x00, .ld .lw T4 S1 0x04, .ld .lw T5 S1 0x08, .ld .lw T6 S1 0x0c,
  .ld .lw A1 S1 0x10, .ld .lw A2 S1 0x14, .ld .lw A3 S1 0x18 ]

/-- The five checks, as bits, gathered in a6. -/
def checks : List Instr := [
  .opi .xori A4 T3 8, .opi .sltiu A4 A4 1,            -- mcause = 8
  .opi .xori A5 T4 1, .opi .sltiu A5 A5 1,            -- t0 = 1
  .op .and A4 A4 A5,                                  -- a4: it halted
  .opi .sltiu A5 T5 1,                                -- a5: with 0
  .op .sltu A6 0 S4, .opi .sltiu A7 A3 1, .op .or A6 A6 A7,               -- check 1 failed
  .opi .sltiu A7 T5 2, .op .and A7 A7 A4, .opi .xori A7 A7 1,             -- check 2 failed
  .op .xor T1 T6 A1, .op .sltu T1 0 T1, .op .and T1 T1 A5,
  .op .xor T2 T6 A2, .op .sltu T2 0 T2, .opi .xori T3 A5 1, .op .and T2 T2 T3,
  .op .or T1 T1 T2,                                                       -- check 3 failed
  .op .sltu T2 0 S5, .op .and T2 T2 A4, .op .and T2 T2 A5,                -- check 4 failed
  .op .sltu T3 0 S6,                                                      -- check 5 failed
  .sh .slli A7 A7 1, .sh .slli T1 T1 2, .sh .slli T2 T2 3, .sh .slli T3 T3 4,
  .op .or A6 A6 A7, .op .or A6 A6 T1, .op .or A6 A6 T2, .op .or A6 A6 T3 ]

/-- A failure: HALT 1 | s << 3 | failures << 6, but for the `ecall`. -/
def fail1 : List Instr := [ .sh .slli A0 A6 6, .sh .slli T1 S2 3, .op .or A0 A0 T1, .opi .ori A0 A0 1, .opi .addi T0 0 1 ]
/-- The TRNG's samples withheld: HALT 3. -/
def fail3 : List Instr := [ .opi .addi A0 0 3, .opi .addi T0 0 1 ]
/-- A broken source let through: HALT 4 | s << 3. -/
def fail4 : List Instr := [ .sh .slli A0 S2 3, .opi .ori A0 A0 4, .opi .addi T0 0 1 ]

def exits : List Instr :=
  [ .br .beq A6 0 14 ] ++ fail1 ++ [ .ecall ] ++                         -- 142: no failure → 149; 143-148
  [ .br .bne S2 0 10, .br .beq T5 0 20 ] ++ fail3 ++ [ .ecall ] ++        -- 149: a broken source → 154; 150: passed → 160
  [ .opi .addi T1 T5 0xfff, .br .beq T1 0 10 ] ++ fail4 ++ [ .ecall ]     -- 154-155: withheld → 160; 156-159

def nextLine : List Instr := [ .opi .addi S1 S1 0x100, .opi .addi S2 S2 1, .opi .addi T1 0 3 ]

def next : List Instr := nextLine ++ [ .br .bne S2 T1 0xec2 ]

def finishLine : List Instr := [ .opi .addi A0 0 0, .opi .addi T0 0 1 ]

def finish : List Instr := finishLine ++ [ .ecall ]

def kernel : List Instr := setup ++ compares ++ loads ++ checks ++ exits ++ next ++ finish

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 167 := by decide

/-! ## What the kernel is held to -/

def RECORDS : Nat := 0x1000

/-- Where field `off` of record `s` is, from `base`. -/
def at_ (s off : Nat) : Nat := RECORDS + 0x100 * s + off

/-- A word of a record. -/
def word (m : Word → Byte) (base : Word) (s off : Nat) : Word :=
  BitVec.ofNat 32 (readLE m (base + BitVec.ofNat 32 (at_ s off)) 4)

/-- The 32 bytes at two offsets of a record are the same, as eight words. -/
def Same (m : Word → Byte) (base : Word) (s oa ob : Nat) : Prop :=
  ∀ j < 8, readLE m (base + BitVec.ofNat 32 (at_ s 0 + oa + 4 * j)) 4
    = readLE m (base + BitVec.ofNat 32 (at_ s 0 + ob + 4 * j)) 4

instance (m : Word → Byte) (base : Word) (s oa ob : Nat) : Decidable (Same m base s oa ob) := by
  unfold Same; infer_instance

/-- The trap was HALT: an `ecall` from User mode (mcause 8) with t0 = 1. -/
def Halted (m : Word → Byte) (base : Word) (s : Nat) : Prop := word m base s 0x00 = 8 ∧ word m base s 0x04 = 1

/-- exp223's five checks, on record `s`. -/
def Check1 (m : Word → Byte) (base : Word) (s : Nat) : Prop :=
  Same m base s 0x20 0x40 ∧ word m base s 0x18 ≠ 0
def Check2 (m : Word → Byte) (base : Word) (s : Nat) : Prop :=
  (word m base s 0x08).toNat < 2 ∧ Halted m base s
def Check3 (m : Word → Byte) (base : Word) (s : Nat) : Prop :=
  if word m base s 0x08 = 0 then word m base s 0x0c = word m base s 0x10 else word m base s 0x0c = word m base s 0x14
def Check4 (m : Word → Byte) (base : Word) (s : Nat) : Prop :=
  Halted m base s ∧ word m base s 0x08 = 0 → Same m base s 0x60 0x80
def Check5 (m : Word → Byte) (base : Word) (s : Nat) : Prop := Same m base s 0xa0 0xc0

instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Halted m base s) := by unfold Halted; infer_instance
instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Check1 m base s) := by unfold Check1; infer_instance
instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Check2 m base s) := by unfold Check2; infer_instance
instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Check3 m base s) := by unfold Check3; infer_instance
instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Check4 m base s) := by unfold Check4; infer_instance
instance (m : Word → Byte) (base : Word) (s : Nat) : Decidable (Check5 m base s) := by unfold Check5; infer_instance

/-- A proposition as a word: 1 or 0. -/
def bit (P : Prop) [Decidable P] : Word := if P then 1#32 else 0#32

/-- The failed checks as five bits: check `k` failed is bit `k - 1`. -/
def failures (m : Word → Byte) (base : Word) (s : Nat) : Word :=
  bit (¬ Check1 m base s) ||| bit (¬ Check2 m base s) <<< 1 ||| bit (¬ Check3 m base s) <<< 2
    ||| bit (¬ Check4 m base s) <<< 3 ||| bit (¬ Check5 m base s) <<< 4

/-- Record `s`'s verdict, if it gives one: a failure, 1; the TRNG's samples
withheld, 3; a broken source let through, 4. -/
def verdictOf (m : Word → Byte) (base : Word) (s : Nat) : Option Word :=
  if failures m base s ≠ 0 then some ((failures m base s <<< 6) ||| (BitVec.ofNat 32 s <<< 3) ||| 1#32)
  else if s = 0 then (if word m base s 0x08 ≠ 0 then some 3#32 else none)
  else if word m base s 0x08 ≠ 1 then some ((BitVec.ofNat 32 s <<< 3) ||| 4#32) else none

/-- **The verdict**: the first record that gives one, or 0. -/
def verdict (m : Word → Byte) (base : Word) : Word :=
  match verdictOf m base 0 with
  | some c => c
  | none => match verdictOf m base 1 with
    | some c => c
    | none => (verdictOf m base 2).getD 0

/-! ## Words that are 0 or 1 -/

theorem bit_and (P Q : Prop) [Decidable P] [Decidable Q] : bit P &&& bit Q = bit (P ∧ Q) := by
  unfold bit; by_cases hp : P <;> by_cases hq : Q <;> simp [hp, hq]

theorem bit_or (P Q : Prop) [Decidable P] [Decidable Q] : bit P ||| bit Q = bit (P ∨ Q) := by
  unfold bit; by_cases hp : P <;> by_cases hq : Q <;> simp [hp, hq]

theorem bit_not (P : Prop) [Decidable P] : bit P ^^^ 1#32 = bit ¬ P := by
  unfold bit; by_cases hp : P <;> simp [hp]

theorem toNat_ne (x : Word) (h : x ≠ 0) : x.toNat ≠ 0 := by
  intro e; apply h; apply BitVec.eq_of_toNat_eq; rw [e]; rfl

theorem bit_eqz (x : Word) : (if BitVec.ult x ((1 : BitVec 12).signExtend 32) = true then 1#32 else 0#32) = bit (x = 0) := by
  rw [show (1 : BitVec 12).signExtend 32 = 1#32 by decide]
  unfold bit
  by_cases h : x = 0
  · subst h; decide
  · have := toNat_ne x h
    have : BitVec.ult x 1#32 = false := by simp only [BitVec.ult]; simp; omega
    have h' : ¬ x = 0#32 := h
    simp [this, h']

theorem bit_lt2 (x : Word) : (if BitVec.ult x ((2 : BitVec 12).signExtend 32) = true then 1#32 else 0#32) = bit (x.toNat < 2) := by
  rw [show (2 : BitVec 12).signExtend 32 = 2#32 by decide]
  unfold bit
  have : BitVec.ult x 2#32 = decide (x.toNat < 2) := by simp [BitVec.ult]
  rw [this]; by_cases h : x.toNat < 2 <;> simp [h]

theorem bit_nez (x : Word) : (if BitVec.ult 0#32 x = true then 1#32 else 0#32) = bit (x ≠ 0) := by
  unfold bit
  by_cases h : x = 0
  · subst h; decide
  · have := toNat_ne x h
    have : BitVec.ult 0#32 x = true := by simp only [BitVec.ult]; simp; omega
    have h' : ¬ x = 0#32 := h
    simp [this, h']

theorem xor_eqz (x c : Word) : x ^^^ c = 0 ↔ x = c := by
  constructor
  · intro h
    have := congrArg (· ^^^ c) h
    simp only [BitVec.xor_assoc, BitVec.xor_self, BitVec.xor_zero] at this
    rw [this]; apply BitVec.eq_of_toNat_eq; simp
  · intro h; rw [h]; simp


/-! ## The five checks, as the instructions make them -/

/-- `sltiu rd, rs, 1`, `sltu rd, x0, rs` and `sltiu rd, rs, 2`, as words. -/
def lt1 (y : Word) : Word := if BitVec.ult y 1#32 = true then 1#32 else 0#32
def nz (y : Word) : Word := if (0#32).ult y = true then 1#32 else 0#32
def lt2 (y : Word) : Word := if BitVec.ult y 2#32 = true then 1#32 else 0#32

/-- What `checks` leaves in a6, from the registers it starts with. -/
def checksOf (st : Machine) : Word :=
  let h := lt1 (st.reg T3 ^^^ 8#32) &&& lt1 (st.reg T4 ^^^ 1#32)
  let z := lt1 (st.reg T5)
  (nz (st.reg S4) ||| lt1 (st.reg A3))
    ||| ((lt2 (st.reg T5) &&& h) ^^^ 1#32) <<< 1
    ||| ((nz (st.reg T6 ^^^ st.reg A1) &&& z) ||| (nz (st.reg T6 ^^^ st.reg A2) &&& (z ^^^ 1#32))) <<< 2
    ||| ((nz (st.reg S5) &&& h) &&& z) <<< 3
    ||| nz (st.reg S6) <<< 4

theorem checks_a6 (st : Machine) : (st.line checks).reg A6 = checksOf st := by
  simp [checksOf, lt1, nz, lt2, Machine.line, checks, Machine.alu, reg_setReg, aluR, aluI, shiftI,
    A6, A7, A4, A5, T1, T2, T3, T4, T5, T6, A1, A2, A3, S4, S5, S6] <;> rfl

theorem lt1_eq (y : Word) : lt1 y = bit (y = 0) := by
  rw [lt1, ← bit_eqz]; rfl

theorem nz_eq (y : Word) : nz y = bit (y ≠ 0) := by
  rw [nz, ← bit_nez]

theorem lt2_eq (y : Word) : lt2 y = bit (y.toNat < 2) := by
  rw [lt2, ← bit_lt2]; rfl

theorem bit_iff {P Q : Prop} [Decidable P] [Decidable Q] (h : P ↔ Q) : bit P = bit Q := by
  unfold bit; by_cases hp : P
  · have hq : Q := h.1 hp; simp [hp, hq]
  · have hq : ¬ Q := fun hq => hp (h.2 hq); simp [hp, hq]

/-- **The five checks**: with the record's words in the registers and the
three comparisons' accumulators zero exactly when their 32 bytes agree,
`checks` leaves in a6 the record's failures. -/
theorem checks_spec (st : Machine) (m : Word → Byte) (base : Word) (s : Nat)
    (h3 : st.reg T3 = word m base s 0x00) (h4 : st.reg T4 = word m base s 0x04)
    (h5 : st.reg T5 = word m base s 0x08) (h6 : st.reg T6 = word m base s 0x0c)
    (ha1 : st.reg A1 = word m base s 0x10) (ha2 : st.reg A2 = word m base s 0x14)
    (ha3 : st.reg A3 = word m base s 0x18)
    (hs4 : st.reg S4 = 0 ↔ Same m base s 0x20 0x40) (hs5 : st.reg S5 = 0 ↔ Same m base s 0x60 0x80)
    (hs6 : st.reg S6 = 0 ↔ Same m base s 0xa0 0xc0) :
    checksOf st = failures m base s := by
  simp only [checksOf, failures, lt1_eq, nz_eq, lt2_eq, bit_and, bit_or, bit_not]
  have e1 : bit (st.reg S4 ≠ 0 ∨ st.reg A3 = 0) = bit (¬ Check1 m base s) := bit_iff (by
    simp only [Check1, ha3, Ne, ← hs4]
    by_cases a : st.reg S4 = 0#32 <;> by_cases b : word m base s 0x18 = 0#32 <;> simp [a, b])
  have e2 : bit (¬ ((st.reg T5).toNat < 2 ∧ st.reg T3 ^^^ 8#32 = 0 ∧ st.reg T4 ^^^ 1#32 = 0))
      = bit (¬ Check2 m base s) := bit_iff (by simp only [Check2, Halted, h3, h4, h5, xor_eqz]; exact Iff.rfl)
  have e3 : bit (st.reg T6 ^^^ st.reg A1 ≠ 0 ∧ st.reg T5 = 0 ∨ st.reg T6 ^^^ st.reg A2 ≠ 0 ∧ ¬ st.reg T5 = 0)
      = bit (¬ Check3 m base s) := bit_iff (by
    simp only [Check3, h5, h6, ha1, ha2, Ne, xor_eqz]
    by_cases a : word m base s 0x08 = 0#32 <;> simp [a])
  have e4 : bit ((st.reg S5 ≠ 0 ∧ st.reg T3 ^^^ 8#32 = 0 ∧ st.reg T4 ^^^ 1#32 = 0) ∧ st.reg T5 = 0)
      = bit (¬ Check4 m base s) := bit_iff (by
    simp only [Check4, Halted, h3, h4, h5, xor_eqz, Ne, ← hs5]
    by_cases a : st.reg S5 = 0#32 <;> by_cases b : word m base s 0x00 = 8#32 <;>
      by_cases c : word m base s 0x04 = 1#32 <;> by_cases d : word m base s 0x08 = 0#32 <;> simp [a, b, c, d])
  have e5 : bit (st.reg S6 ≠ 0) = bit (¬ Check5 m base s) := bit_iff (by simp only [Check5, Ne, ← hs6])
  rw [e1, e2, e3, e4, e5]

/-! ## A record at a time -/

/-- At the top of record `s`, or once `s` is 3 at the final HALT: memory as
the shell left it, the record pointer and the source. -/
structure Inv (m0 : Word → Byte) (base : Word) (s : Nat) (st : Machine) : Prop where
  pc : st.pc = base + BitVec.ofNat 32 (4 * if s < 3 then 4 else 164)
  mem : st.mem = m0
  s1 : st.reg S1 = base + BitVec.ofNat 32 (at_ s 0)
  s2 : st.reg S2 = BitVec.ofNat 32 s

variable {env : Env} {base : Word}

/-- An accumulator cleared, then a comparison of eight words into it. -/
theorem compare_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {s : Nat} (hs : s < 3)
    {acc : Reg} {k oa ob : Nat}
    (hclr : kernel.getD k .ecall = .opi .addi acc 0 0)
    (hat : ∀ j < 8, kernel.getD (k + 1 + 4 * j) .ecall = .ld .lw T1 S1 (BitVec.ofNat 12 (oa + 4 * j))
      ∧ kernel.getD (k + 1 + 4 * j + 1) .ecall = .ld .lw T2 S1 (BitVec.ofNat 12 (ob + 4 * j))
      ∧ kernel.getD (k + 1 + 4 * j + 2) .ecall = .op .xor T1 T1 T2
      ∧ kernel.getD (k + 1 + 4 * j + 3) .ecall = .op .or acc acc T1)
    (hk : k + 33 ≤ 167) (hacc : acc ≠ 0) (h1 : acc ≠ T1) (h2 : acc ≠ T2) (h3 : acc ≠ S1)
    (hoa : oa + 32 ≤ 2048) (hob : ob + 32 ≤ 2048) (ha4 : oa % 4 = 0) (hb4 : ob % 4 = 0)
    {st : Machine} (hpc : st.pc = base + BitVec.ofNat 32 (4 * k)) (hm : st.mem = m0)
    (hs1 : st.reg S1 = base + BitVec.ofNat 32 (at_ s 0)) :
    ∃ st', run env 33 st = .running st' ∧ st'.pc = base + BitVec.ofNat 32 (4 * (k + 33)) ∧ st'.mem = m0
      ∧ (st'.reg acc = 0 ↔ Same m0 base s oa ob)
      ∧ ∀ r, r ≠ acc → r ≠ T1 → r ≠ T2 → st'.reg r = st.reg r := by
  have hcode : CodeAt st.mem base kernel := by rw [hm]; exact hc
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp k (by rw [kernel_length]; omega) hcode hpc
    (i := .opi .addi acc 0 0) hclr rfl
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have z1 : s1.reg acc = 0 := by rw [reg_wrote r1 hacc]; simp [aluI]
  obtain ⟨s2, e2, p2, m2, z2, k2⟩ := compare_words (prog := kernel) hp (k0 := k + 1) (oa := oa) (ob := ob)
    (a := at_ s 0) (b := at_ s 0) hat (by rw [kernel_length]; omega)
    (by decide) (by decide) hacc (by decide) (by decide) (by decide) (by decide) (by decide)
    h1 h2 (Ne.symm h3) (Ne.symm h3) hoa hob
    (by simp only [at_, RECORDS]; omega) (by simp only [at_, RECORDS]; omega)
    (by simp only [at_, RECORDS]; omega) (by simp only [at_, RECORDS]; omega)
    p1 hc1 (by rw [reg_kept r1 (Ne.symm h3), hs1]) (by rw [reg_kept r1 (Ne.symm h3), hs1]) (by decide) 8 (Nat.le_refl _)
  refine ⟨s2, ?_, by rw [p2], by rw [m2, m1, hm], ?_, fun r ha ht hu => by rw [k2 r ha ht hu, reg_kept r1 ha]⟩
  · rw [show 33 = 1 + 4 * 8 by rfl]; exact run_cons e1 e2
  · rw [z2, z1, m1, hm]; simp only [true_and, Same]

/-- `lw rd, off(s1)`: a word of the record. -/
theorem load_field (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {s : Nat} (hs : s < 3)
    {k off : Nat} {rd : Reg} (hi : kernel.getD k .ecall = .ld .lw rd S1 (BitVec.ofNat 12 off)) (hk : k < 167)
    (hoff : off < 0x100) (h4 : off % 4 = 0) (hrd : rd ≠ 0)
    {st : Machine} (hpc : st.pc = base + BitVec.ofNat 32 (4 * k)) (hm : st.mem = m0)
    (hs1 : st.reg S1 = base + BitVec.ofNat 32 (at_ s 0)) :
    ∃ st', run env 1 st = .running st' ∧ st'.pc = base + BitVec.ofNat 32 (4 * (k + 1)) ∧ st'.mem = m0
      ∧ st'.reg rd = word m0 base s off ∧ ∀ r, r ≠ rd → st'.reg r = st.reg r := by
  have hcode : CodeAt st.mem base kernel := by rw [hm]; exact hc
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp k (by rw [kernel_length]; exact hk) hcode hpc
    hi (at_ s off)
    (by rw [hs1, se_small _ (by omega), off_add hp.fit _ _ (by simp only [at_, RECORDS]; omega)]
        simp only [at_, Nat.add_zero])
    (by simp only [at_, RECORDS]; omega) (by simp only [at_, RECORDS]; omega)
  exact ⟨s1, e1, p1, by rw [m1, hm], by rw [reg_wrote r1 hrd, hm]; rfl, fun r hr => reg_kept r1 hr⟩

theorem seg_checks : (kernel.drop 110).take checks.length = checks := by decide

/-- **One record judged**: from the top of record `s`, 138 instructions on,
at the first branch, a6 holds the record's failures and t5 its a0; memory,
the record pointer and the source are as they were. -/
theorem body_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {s : Nat} (hs : s < 3)
    {st : Machine} (h : Inv m0 base s st) :
    ∃ st', run env 138 st = .running st' ∧ st'.pc = base + BitVec.ofNat 32 (4 * 142) ∧ st'.mem = m0
      ∧ st'.reg A6 = failures m0 base s ∧ st'.reg T5 = word m0 base s 0x08
      ∧ st'.reg S1 = st.reg S1 ∧ st'.reg S2 = st.reg S2 := by
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 4) := by rw [h.pc]; simp [hs]
  obtain ⟨sa, ea, pa, ma, za, ka⟩ := compare_run hp hc hs (acc := S4) (k := 4) (oa := 0x20) (ob := 0x40)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) hpc h.mem h.s1
  obtain ⟨sb, eb, pb, mb, zb, kb⟩ := compare_run hp hc hs (acc := S5) (k := 37) (oa := 0x60) (ob := 0x80)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) pa ma (by rw [ka _ (by decide) (by decide) (by decide), h.s1])
  obtain ⟨sc, ec, pc', mc, zc, kc⟩ := compare_run hp hc hs (acc := S6) (k := 70) (oa := 0xa0) (ob := 0xc0)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) pb mb
    (by rw [kb _ (by decide) (by decide) (by decide), ka _ (by decide) (by decide) (by decide), h.s1])
  have c1 : sc.reg S1 = base + BitVec.ofNat 32 (at_ s 0) := by
    rw [kc _ (by decide) (by decide) (by decide), kb _ (by decide) (by decide) (by decide),
      ka _ (by decide) (by decide) (by decide), h.s1]
  obtain ⟨l1, f1, q1, n1, v1, k1⟩ := load_field hp hc hs (k := 103) (off := 0x00) (rd := T3) (by decide) (by decide)
    (by decide) (by decide) (by decide) pc' mc c1
  obtain ⟨l2, f2, q2, n2, v2, k2⟩ := load_field hp hc hs (k := 104) (off := 0x04) (rd := T4) (by decide) (by decide)
    (by decide) (by decide) (by decide) q1 n1 (by rw [k1 _ (by decide), c1])
  obtain ⟨l3, f3, q3, n3, v3, k3⟩ := load_field hp hc hs (k := 105) (off := 0x08) (rd := T5) (by decide) (by decide)
    (by decide) (by decide) (by decide) q2 n2 (by rw [k2 _ (by decide), k1 _ (by decide), c1])
  obtain ⟨l4, f4, q4, n4, v4, k4⟩ := load_field hp hc hs (k := 106) (off := 0x0c) (rd := T6) (by decide) (by decide)
    (by decide) (by decide) (by decide) q3 n3 (by rw [k3 _ (by decide), k2 _ (by decide), k1 _ (by decide), c1])
  obtain ⟨l5, f5, q5, n5, v5, k5⟩ := load_field hp hc hs (k := 107) (off := 0x10) (rd := A1) (by decide) (by decide)
    (by decide) (by decide) (by decide) q4 n4
    (by rw [k4 _ (by decide), k3 _ (by decide), k2 _ (by decide), k1 _ (by decide), c1])
  obtain ⟨l6, f6, q6, n6, v6, k6⟩ := load_field hp hc hs (k := 108) (off := 0x14) (rd := A2) (by decide) (by decide)
    (by decide) (by decide) (by decide) q5 n5
    (by rw [k5 _ (by decide), k4 _ (by decide), k3 _ (by decide), k2 _ (by decide), k1 _ (by decide), c1])
  obtain ⟨l7, f7, q7, n7, v7, k7⟩ := load_field hp hc hs (k := 109) (off := 0x18) (rd := A3) (by decide) (by decide)
    (by decide) (by decide) (by decide) q6 n6
    (by rw [k6 _ (by decide), k5 _ (by decide), k4 _ (by decide), k3 _ (by decide), k2 _ (by decide),
      k1 _ (by decide), c1])
  -- every load's register, and the accumulators, as l7 has them
  have keep7 : ∀ r, r ≠ T3 → r ≠ T4 → r ≠ T5 → r ≠ T6 → r ≠ A1 → r ≠ A2 → r ≠ A3 → l7.reg r = sc.reg r :=
    fun r a b c d e f g => by rw [k7 r g, k6 r f, k5 r e, k4 r d, k3 r c, k2 r b, k1 r a]
  have hc7 : CodeAt l7.mem base kernel := by rw [n7]; exact hc
  have e8 := run_line (prog := kernel) hp checks (by decide) 110 l7 seg_checks (by decide) hc7 q7 (by decide)
  have kl : ∀ r, (∀ i ∈ checks, rdOf i ≠ some r) → (l7.line checks).reg r = l7.reg r :=
    fun r hr => line_keeps _ _ r hr
  refine ⟨l7.line checks, ?_, by rw [line_pc_at checks q7 (by decide)]; rfl, by rw [line_mem, n7], ?_, ?_, ?_, ?_⟩
  · rw [show 138 = 33 + (33 + (33 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + checks.length))))))))) by rfl,
      run_add_running ea, run_add_running eb, run_add_running ec, run_add_running f1, run_add_running f2,
      run_add_running f3, run_add_running f4, run_add_running f5, run_add_running f6, run_add_running f7, e8]
  · rw [checks_a6]
    apply checks_spec l7 m0 base s
    · rw [k7 _ (by decide), k6 _ (by decide), k5 _ (by decide), k4 _ (by decide), k3 _ (by decide),
        k2 _ (by decide), v1]
    · rw [k7 _ (by decide), k6 _ (by decide), k5 _ (by decide), k4 _ (by decide), k3 _ (by decide), v2]
    · rw [k7 _ (by decide), k6 _ (by decide), k5 _ (by decide), k4 _ (by decide), v3]
    · rw [k7 _ (by decide), k6 _ (by decide), k5 _ (by decide), v4]
    · rw [k7 _ (by decide), k6 _ (by decide), v5]
    · rw [k7 _ (by decide), v6]
    · exact v7
    · rw [keep7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
        kc _ (by decide) (by decide) (by decide), kb _ (by decide) (by decide) (by decide)]; exact za
    · rw [keep7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
        kc _ (by decide) (by decide) (by decide)]; exact zb
    · rw [keep7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)]; exact zc
  · rw [kl T5 (by decide), k7 _ (by decide), k6 _ (by decide), k5 _ (by decide), k4 _ (by decide), v3]
  · rw [kl S1 (by decide), keep7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      kc _ (by decide) (by decide) (by decide), kb _ (by decide) (by decide) (by decide),
      ka _ (by decide) (by decide) (by decide)]
  · rw [kl S2 (by decide), keep7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      kc _ (by decide) (by decide) (by decide), kb _ (by decide) (by decide) (by decide),
      ka _ (by decide) (by decide) (by decide)]

/-! ## The branches -/

theorem dec_eqz (x : Word) : x + (0xfff : BitVec 12).signExtend 32 = 0 ↔ x = 1 := by
  constructor
  · intro h
    have e : x = x + (0xfff : BitVec 12).signExtend 32 - (0xfff : BitVec 12).signExtend 32 := by
      rw [BitVec.add_sub_cancel]
    rw [e, h]; decide
  · intro h; rw [h]; decide

theorem src_eqz {s : Nat} (hs : s < 3) : BitVec.ofNat 32 s = 0 ↔ s = 0 := by
  rcases (by omega : s = 0 ∨ s = 1 ∨ s = 2) with rfl | rfl | rfl <;> decide

theorem src_next {s : Nat} (hs : s < 3) : BitVec.ofNat 32 s + 1#32 = BitVec.ofNat 32 (s + 1) := by
  rcases (by omega : s = 0 ∨ s = 1 ∨ s = 2) with rfl | rfl | rfl <;> decide

theorem src_three {s : Nat} (hs : s < 3) : BitVec.ofNat 32 (s + 1) = 3#32 ↔ s + 1 = 3 := by
  rcases (by omega : s = 0 ∨ s = 1 ∨ s = 2) with rfl | rfl | rfl <;> decide

/-- HALT, at an `ecall` of the kernel with `t0 = 1`. -/
theorem halts_at (hp : Placed env base) {st : Machine} (k : Nat) (hk : k < 167)
    (hcode : CodeAt st.mem base kernel) (hpc : st.pc = base + BitVec.ofNat 32 (4 * k))
    (hi : kernel.getD k .ecall = .ecall) (ht0 : st.reg T0 = 1) :
    run env 1 st = .halted (st.reg A0) st := by
  have hk' : k < kernel.length := by rw [kernel_length]; exact hk
  have : kernel[k] = .ecall := by rw [← hi]; simp [List.getD_eq_getElem?_getD, hk']
  exact run_code_halt 0 hk' hcode hpc (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) (by rw [this]; exact exec_halt ht0)

theorem to149 (base : Word) :
    base + BitVec.ofNat 32 (4 * 142) + ((14 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 149) := by
  rw [BitVec.add_assoc]; congr 1
theorem to154 (base : Word) :
    base + BitVec.ofNat 32 (4 * 149) + ((10 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 154) := by
  rw [BitVec.add_assoc]; congr 1
theorem to160a (base : Word) :
    base + BitVec.ofNat 32 (4 * 150) + ((20 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 160) := by
  rw [BitVec.add_assoc]; congr 1
theorem to160b (base : Word) :
    base + BitVec.ofNat 32 (4 * 155) + ((10 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 160) := by
  rw [BitVec.add_assoc]; congr 1
theorem back4 (base : Word) :
    base + BitVec.ofNat 32 (4 * 163) + ((0xec2 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 (4 * 4) := by
  rw [BitVec.add_assoc]; congr 1


theorem seg_fail1 : (kernel.drop 143).take fail1.length = fail1 := by decide
theorem seg_fail3 : (kernel.drop 151).take fail3.length = fail3 := by decide
theorem seg_fail4 : (kernel.drop 156).take fail4.length = fail4 := by decide
theorem seg_next : (kernel.drop 160).take nextLine.length = nextLine := by decide

/-- From the record's end, at 160: on to the next record, or to the final HALT. -/
theorem next_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {s : Nat} (hs : s < 3)
    {st : Machine} (hpc : st.pc = base + BitVec.ofNat 32 (4 * 160)) (hm : st.mem = m0)
    (h1 : st.reg S1 = base + BitVec.ofNat 32 (at_ s 0)) (h2 : st.reg S2 = BitVec.ofNat 32 s) :
    ∃ st', run env 4 st = .running st' ∧ Inv m0 base (s + 1) st' := by
  have hcode : CodeAt st.mem base kernel := by rw [hm]; exact hc
  have e1 := run_line (prog := kernel) hp nextLine (by decide) 160 st seg_next (by decide) hcode hpc (by decide)
  have p1 : (st.line nextLine).pc = base + BitVec.ofNat 32 (4 * 163) := line_pc_at nextLine hpc (by decide)
  have g1 : (st.line nextLine).reg S1 = st.reg S1 + 256#32 := by
    simp [nextLine, Machine.line, Machine.alu, reg_setReg, aluI, S1, S2, T1]
  have g2 : (st.line nextLine).reg S2 = st.reg S2 + 1#32 := by
    simp [nextLine, Machine.line, Machine.alu, reg_setReg, aluI, S1, S2, T1]
  have g3 : (st.line nextLine).reg T1 = 3#32 := by
    simp [nextLine, Machine.line, Machine.alu, reg_setReg, aluI, S1, S2, T1]
  have c1 : (st.line nextLine).reg S1 = base + BitVec.ofNat 32 (at_ (s + 1) 0) := by
    rw [g1, h1, show (256#32 : Word) = BitVec.ofNat 32 256 from rfl,
      off_add hp.fit _ _ (by simp only [at_, RECORDS]; omega)]
    congr 2
  have c2 : (st.line nextLine).reg S2 = BitVec.ofNat 32 (s + 1) := by rw [g2, h2, src_next hs]
  have hcl : CodeAt (st.line nextLine).mem base kernel := by rw [line_mem]; exact hcode
  have tk : taken .bne ((st.line nextLine).reg S2) ((st.line nextLine).reg T1) = decide (s + 1 < 3) := by
    rw [c2, g3]; rcases (by omega : s = 0 ∨ s = 1 ∨ s = 2) with rfl | rfl | rfl <;> decide
  by_cases hlt : s + 1 < 3
  · refine ⟨(st.line nextLine).setPc ((st.line nextLine).pc + ((0xec2 : BitVec 12) ++ 0#1).signExtend 32), ?_,
      ⟨by rw [setPc_pc, p1, back4]; simp [hlt], by rw [setPc_mem, line_mem, hm],
        by rw [setPc_reg, c1], by rw [setPc_reg, c2]⟩⟩
    rw [show 4 = nextLine.length + 1 by rfl, run_add_running e1]
    exact (stepK hp 163 (by decide) hcl p1 (i := .br .bne S2 T1 0xec2) (by decide)
      (exec_br_taken (by rw [tk]; simp [hlt])) 0).trans (run_zero _ _)
  · refine ⟨(st.line nextLine).next, ?_, ⟨by rw [next_pc, p1, pc_next hp.fit 163 (by decide)]; simp [hlt],
      by rw [next_mem, line_mem, hm], by rw [next_reg, c1], by rw [next_reg, c2]⟩⟩
    rw [show 4 = nextLine.length + 1 by rfl, run_add_running e1]
    exact (stepK hp 163 (by decide) hcl p1 (i := .br .bne S2 T1 0xec2) (by decide)
      (exec_br_not (by rw [tk]; simp [hlt])) 0).trans (run_zero _ _)

/-- **One record**: from the top of record `s`, the kernel halts with the
record's verdict if it gives one, memory untouched; if it gives none, it
goes on to the next record. -/
theorem iter (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {s : Nat} (hs : s < 3)
    {st : Machine} (h : Inv m0 base s st) :
    (∀ c, verdictOf m0 base s = some c → ∃ n st', run env n st = .halted c st' ∧ st'.mem = m0) ∧
    (verdictOf m0 base s = none → ∃ n st', run env n st = .running st' ∧ Inv m0 base (s + 1) st') := by
  obtain ⟨sB, eB, pB, mB, aB, tB, s1B, s2B⟩ := body_run hp hc hs h
  have hcB : CodeAt sB.mem base kernel := by rw [mB]; exact hc
  rw [h.s1] at s1B
  rw [h.s2] at s2B
  by_cases hF : failures m0 base s = 0
  · -- no failure: on to 149
    have tk : taken .beq (sB.reg A6) (sB.reg 0) = true := by rw [aB, reg_zero, hF]; rfl
    let s9 := sB.setPc (sB.pc + ((14 : BitVec 12) ++ 0#1).signExtend 32)
    have e9 : run env 1 sB = .running s9 :=
      (stepK hp 142 (by decide) hcB pB (i := .br .beq A6 0 14) (by decide) (exec_br_taken tk) 0).trans (run_zero _ _)
    have p9 : s9.pc = base + BitVec.ofNat 32 (4 * 149) := by simp only [s9, setPc_pc]; rw [pB, to149]
    have hc9 : CodeAt s9.mem base kernel := by simp only [s9, setPc_mem]; exact hcB
    have r9 : ∀ r, s9.reg r = sB.reg r := fun r => by simp [s9, setPc_reg]
    -- the record gives no failure, so its verdict is the source's own
    have vF : verdictOf m0 base s = if s = 0 then (if word m0 base s 0x08 ≠ 0 then some 3#32 else none)
        else if word m0 base s 0x08 ≠ 1 then some ((BitVec.ofNat 32 s <<< 3) ||| 4#32) else none := by
      simp only [verdictOf, hF, ne_eq, not_true_eq_false, ↓reduceIte]
    -- the end of the record, at 160, for both sources' ways on
    have onward : ∀ (q : Machine) (k : Nat), run env k sB = .running q → q.pc = base + BitVec.ofNat 32 (4 * 160) →
        q.mem = m0 → q.reg S1 = sB.reg S1 → q.reg S2 = sB.reg S2 →
        ∃ n st', run env n st = .running st' ∧ Inv m0 base (s + 1) st' := by
      intro q k ek pq mq q1 q2
      obtain ⟨st', e', i'⟩ := next_run hp hc hs pq mq (by rw [q1, s1B]) (by rw [q2, s2B])
      exact ⟨138 + (k + 4), st', by rw [run_add_running eB, run_add_running ek, e'], i'⟩
    by_cases h0 : s = 0
    · subst h0
      have tk2 : taken .bne (s9.reg S2) (s9.reg 0) = false := by rw [r9, s2B, reg_zero]; rfl
      let s10 := s9.next
      have e10 : run env 1 s9 = .running s10 :=
        (stepK hp 149 (by decide) hc9 p9 (i := .br .bne S2 0 10) (by decide) (exec_br_not tk2) 0).trans (run_zero _ _)
      have p10 : s10.pc = base + BitVec.ofNat 32 (4 * 150) := by
        simp only [s10, next_pc]; rw [p9]; exact pc_next hp.fit 149 (by decide)
      have hc10 : CodeAt s10.mem base kernel := by simp only [s10, next_mem]; exact hc9
      have r10 : ∀ r, s10.reg r = sB.reg r := fun r => by simp only [s10, next_reg]; exact r9 r
      by_cases hz : word m0 base 0 0x08 = 0
      · -- the TRNG's samples passed: on to the next record
        have vn : verdictOf m0 base 0 = none := by rw [vF]; simp only [ne_eq, hz, not_true_eq_false, ↓reduceIte]
        refine ⟨fun c hc' => (by rw [vn] at hc'; cases hc'), fun _ => ?_⟩
        have tk3 : taken .beq (s10.reg T5) (s10.reg 0) = true := by rw [r10, tB, reg_zero, hz]; rfl
        let s11 := s10.setPc (s10.pc + ((20 : BitVec 12) ++ 0#1).signExtend 32)
        have e11 : run env 1 s10 = .running s11 :=
          (stepK hp 150 (by decide) hc10 p10 (i := .br .beq T5 0 20) (by decide) (exec_br_taken tk3) 0).trans
            (run_zero _ _)
        exact onward s11 3 (by rw [show 3 = 1 + (1 + 1) by rfl]; exact run_cons e9 (run_cons e10 e11))
          (by simp only [s11, setPc_pc]; rw [p10, to160a]) (by simp only [s11, s10, s9, setPc_mem, next_mem]; exact mB)
          (by simp only [s11, setPc_reg]; exact r10 S1) (by simp only [s11, setPc_reg]; exact r10 S2)
      · -- the TRNG's samples withheld: HALT 3
        have vs : verdictOf m0 base 0 = some 3#32 := by
          rw [vF]; simp only [ne_eq, hz, not_false_eq_true, ↓reduceIte]
        refine ⟨fun c hc' => ?_, fun hn => (by rw [vs] at hn; cases hn)⟩
        rw [vs] at hc'; cases hc'
        have tk3 : taken .beq (s10.reg T5) (s10.reg 0) = false := by
          rw [r10, tB, reg_zero]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact hz
        let s11 := s10.next
        have e11 : run env 1 s10 = .running s11 :=
          (stepK hp 150 (by decide) hc10 p10 (i := .br .beq T5 0 20) (by decide) (exec_br_not tk3) 0).trans
            (run_zero _ _)
        have p11 : s11.pc = base + BitVec.ofNat 32 (4 * 151) := by
          simp only [s11, next_pc]; rw [p10]; exact pc_next hp.fit 150 (by decide)
        have hc11 : CodeAt s11.mem base kernel := by simp only [s11, next_mem]; exact hc10
        have e12 := run_line (prog := kernel) hp fail3 (by decide) 151 s11 seg_fail3 (by decide) hc11 p11 (by decide)
        have p12 : (s11.line fail3).pc = base + BitVec.ofNat 32 (4 * 153) := line_pc_at fail3 p11 (by decide)
        have hc12 : CodeAt (s11.line fail3).mem base kernel := by rw [line_mem]; exact hc11
        have a12 : (s11.line fail3).reg A0 = 3 := by simp [fail3, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
        have t12 : (s11.line fail3).reg T0 = 1 := by simp [fail3, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
        have e13 := halts_at hp (st := s11.line fail3) 153 (by decide) hc12 p12 (by decide) t12
        rw [a12] at e13
        refine ⟨138 + (1 + (1 + (1 + (fail3.length + 1)))), s11.line fail3, ?_, ?_⟩
        · rw [run_add_running eB, run_add_running e9, run_add_running e10, run_add_running e11,
            run_add_running e12, e13]
          rfl
        · rw [line_mem]; simp only [s11, s10, s9, next_mem, setPc_mem]; exact mB
    · -- a broken source: 154
      have tk2 : taken .bne (s9.reg S2) (s9.reg 0) = true := by
        rw [r9, s2B, reg_zero]; simp only [taken, bne_iff_ne, ne_eq, src_eqz hs]; simpa using h0
      let s10 := s9.setPc (s9.pc + ((10 : BitVec 12) ++ 0#1).signExtend 32)
      have e10 : run env 1 s9 = .running s10 :=
        (stepK hp 149 (by decide) hc9 p9 (i := .br .bne S2 0 10) (by decide) (exec_br_taken tk2) 0).trans
          (run_zero _ _)
      have p10 : s10.pc = base + BitVec.ofNat 32 (4 * 154) := by simp only [s10, setPc_pc]; rw [p9, to154]
      have hc10 : CodeAt s10.mem base kernel := by simp only [s10, setPc_mem]; exact hc9
      have r10 : ∀ r, s10.reg r = sB.reg r := fun r => by simp only [s10, setPc_reg]; exact r9 r
      obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp 154 (by decide) hc10 p10
        (i := .opi .addi T1 T5 0xfff) (by decide) rfl
      have hc11 : CodeAt s11.mem base kernel := by rw [m11]; exact hc10
      have v11 : s11.reg T1 = word m0 base s 0x08 + (0xfff : BitVec 12).signExtend 32 := by
        rw [reg_wrote r11 (by decide)]; simp only [aluI]; rw [r10, tB]
      by_cases h1 : word m0 base s 0x08 = 1
      · have vn : verdictOf m0 base s = none := by
          rw [vF]; simp only [h0, h1, ne_eq, not_true_eq_false, ↓reduceIte]
        refine ⟨fun c hc' => (by rw [vn] at hc'; cases hc'), fun _ => ?_⟩
        have tk3 : taken .beq (s11.reg T1) (s11.reg 0) = true := by
          rw [v11, reg_zero]; simp only [taken, beq_iff_eq]; exact (dec_eqz _).2 h1
        let s12 := s11.setPc (s11.pc + ((10 : BitVec 12) ++ 0#1).signExtend 32)
        have e12 : run env 1 s11 = .running s12 :=
          (stepK hp 155 (by decide) hc11 p11 (i := .br .beq T1 0 10) (by decide) (exec_br_taken tk3) 0).trans
            (run_zero _ _)
        exact onward s12 4 (by rw [show 4 = 1 + (1 + (1 + 1)) by rfl]; exact run_cons e9 (run_cons e10 (run_cons e11 e12)))
          (by simp only [s12, setPc_pc]; rw [p11, to160b])
          (by simp only [s12, setPc_mem]; rw [m11]; simp only [s10, s9, setPc_mem]; exact mB)
          (by simp only [s12, setPc_reg]; rw [reg_kept r11 (by decide)]; exact r10 S1)
          (by simp only [s12, setPc_reg]; rw [reg_kept r11 (by decide)]; exact r10 S2)
      · have vs : verdictOf m0 base s = some ((BitVec.ofNat 32 s <<< 3) ||| 4#32) := by
          rw [vF]; simp only [h0, h1, ne_eq, not_false_eq_true, ↓reduceIte]
        refine ⟨fun c hc' => ?_, fun hn => (by rw [vs] at hn; cases hn)⟩
        rw [vs] at hc'; cases hc'
        have tk3 : taken .beq (s11.reg T1) (s11.reg 0) = false := by
          rw [v11, reg_zero]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact fun e => h1 ((dec_eqz _).1 e)
        let s12 := s11.next
        have e12 : run env 1 s11 = .running s12 :=
          (stepK hp 155 (by decide) hc11 p11 (i := .br .beq T1 0 10) (by decide) (exec_br_not tk3) 0).trans
            (run_zero _ _)
        have p12 : s12.pc = base + BitVec.ofNat 32 (4 * 156) := by
          simp only [s12, next_pc]; rw [p11]; exact pc_next hp.fit 155 (by decide)
        have hc12 : CodeAt s12.mem base kernel := by simp only [s12, next_mem]; exact hc11
        have e13 := run_line (prog := kernel) hp fail4 (by decide) 156 s12 seg_fail4 (by decide) hc12 p12 (by decide)
        have p13 : (s12.line fail4).pc = base + BitVec.ofNat 32 (4 * 159) := line_pc_at fail4 p12 (by decide)
        have hc13 : CodeAt (s12.line fail4).mem base kernel := by rw [line_mem]; exact hc12
        have a13 : (s12.line fail4).reg A0 = (s12.reg S2 <<< 3) ||| 4#32 := by
          simp [fail4, Machine.line, Machine.alu, reg_setReg, aluI, shiftI, T0, A0, S2]
        have t13 : (s12.line fail4).reg T0 = 1 := by
          simp [fail4, Machine.line, Machine.alu, reg_setReg, aluI, shiftI, T0, A0, S2]
        have e14 := halts_at hp (st := s12.line fail4) 159 (by decide) hc13 p13 (by decide) t13
        rw [a13, show s12.reg S2 = BitVec.ofNat 32 s by
          simp only [s12, next_reg]; rw [reg_kept r11 (by decide), r10, s2B]] at e14
        refine ⟨138 + (1 + (1 + (1 + (1 + (fail4.length + 1))))), s12.line fail4, ?_, ?_⟩
        · rw [run_add_running eB, run_add_running e9, run_add_running e10, run_add_running e11,
            run_add_running e12, run_add_running e13, e14]
        · rw [line_mem]; simp only [s12, next_mem]; rw [m11]; simp only [s10, s9, setPc_mem]; exact mB
  · -- a failure: HALT with it
    have vs : verdictOf m0 base s = some ((failures m0 base s <<< 6) ||| (BitVec.ofNat 32 s <<< 3) ||| 1#32) := by
      simp only [verdictOf, ne_eq, hF, not_false_eq_true, ↓reduceIte]
    refine ⟨fun c hc' => ?_, fun hn => (by rw [vs] at hn; cases hn)⟩
    rw [vs] at hc'; cases hc'
    have tk : taken .beq (sB.reg A6) (sB.reg 0) = false := by
      rw [aB, reg_zero]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact hF
    let s9 := sB.next
    have e9 : run env 1 sB = .running s9 :=
      (stepK hp 142 (by decide) hcB pB (i := .br .beq A6 0 14) (by decide) (exec_br_not tk) 0).trans (run_zero _ _)
    have p9 : s9.pc = base + BitVec.ofNat 32 (4 * 143) := by
      simp only [s9, next_pc]; rw [pB]; exact pc_next hp.fit 142 (by decide)
    have hc9 : CodeAt s9.mem base kernel := by simp only [s9, next_mem]; exact hcB
    have e10 := run_line (prog := kernel) hp fail1 (by decide) 143 s9 seg_fail1 (by decide) hc9 p9 (by decide)
    have p10 : (s9.line fail1).pc = base + BitVec.ofNat 32 (4 * 148) := line_pc_at fail1 p9 (by decide)
    have hc10 : CodeAt (s9.line fail1).mem base kernel := by rw [line_mem]; exact hc9
    have a10 : (s9.line fail1).reg A0 = ((s9.reg A6 <<< 6) ||| (s9.reg S2 <<< 3)) ||| 1#32 := by
      simp [fail1, Machine.line, Machine.alu, reg_setReg, aluI, aluR, shiftI, T0, T1, A0, A6, S2]
    have t10 : (s9.line fail1).reg T0 = 1 := by
      simp [fail1, Machine.line, Machine.alu, reg_setReg, aluI, aluR, shiftI, T0, T1, A0, A6, S2]
    have e11 := halts_at hp (st := s9.line fail1) 148 (by decide) hc10 p10 (by decide) t10
    rw [a10, show s9.reg A6 = failures m0 base s by simp only [s9, next_reg]; exact aB,
      show s9.reg S2 = BitVec.ofNat 32 s by simp only [s9, next_reg]; exact s2B] at e11
    refine ⟨138 + (1 + (fail1.length + 1)), s9.line fail1, ?_, ?_⟩
    · rw [run_add_running eB, run_add_running e9, run_add_running e10, e11]
    · rw [line_mem]; simp only [s9, next_mem]; exact mB

/-! ## The kernel, whole -/

/-- Four instructions: the first record, source 0. -/
theorem setup_run (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ st', run env 4 st = .running st' ∧ Inv st.mem base 0 st' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (i := .lui T1 1) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (i := .opi .addi S2 0 0) (by decide) rfl
  refine ⟨s4, ?_, ⟨by rw [p4]; rfl, by rw [m4, m3, m2, m1], ?_, ?_⟩⟩
  · rw [show 4 = 1 + (1 + (1 + 1)) by rfl]; exact run_cons e1 (run_cons e2 (run_cons e3 e4))
  · rw [reg_kept r4 (by decide), reg_wrote r3 (by decide)]
    simp only [aluR]; rw [reg_kept r2 (by decide), reg_wrote r1 (by decide), reg_wrote r2 (by decide), hpc]
    simp [at_, RECORDS]
  · rw [reg_wrote r4 (by decide)]; simp [aluI]


theorem seg_finish : (kernel.drop 164).take finishLine.length = finishLine := by decide

/-- After the third record: HALT 0. -/
theorem finish_run (hp : Placed env base) {m0 : Word → Byte} (hc : CodeAt m0 base kernel) {st : Machine}
    (h : Inv m0 base 3 st) : ∃ st', run env 3 st = .halted 0 st' ∧ st'.mem = m0 := by
  have hpc : st.pc = base + BitVec.ofNat 32 (4 * 164) := by rw [h.pc]; rfl
  have hcode : CodeAt st.mem base kernel := by rw [h.mem]; exact hc
  have e1 := run_line (prog := kernel) hp finishLine (by decide) 164 st seg_finish (by decide) hcode hpc (by decide)
  have p1 : (st.line finishLine).pc = base + BitVec.ofNat 32 (4 * 166) := line_pc_at finishLine hpc (by decide)
  have t1 : (st.line finishLine).reg T0 = 1 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have a1 : (st.line finishLine).reg A0 = 0 := by
    simp [finishLine, Machine.line, Machine.alu, reg_setReg, aluI, T0, A0]
  have e2 := halts_at hp (st := st.line finishLine) 166 (by decide) (by rw [line_mem]; exact hcode) p1 (by decide) t1
  rw [a1] at e2
  exact ⟨_, by rw [show 3 = finishLine.length + 1 by rfl, run_add_running e1, e2], by rw [line_mem, h.mem]⟩

/-- **The kernel judges.** From `base`, with the kernel's bytes there, it
halts with `verdict` of the three records — whatever they hold — and memory
is just as it was. -/
theorem judges (hp : Placed env base) (st : Machine) (hpc : st.pc = base) (hcode : CodeAt st.mem base kernel) :
    ∃ n st', run env n st = .halted (verdict st.mem base) st' ∧ st'.mem = st.mem := by
  obtain ⟨s0, e0, i0⟩ := setup_run hp st hpc hcode
  have hc := hcode
  obtain ⟨y0, n0⟩ := iter hp hc (by decide) i0
  cases v0 : verdictOf st.mem base 0 with
  | some c =>
    obtain ⟨n, st', e, m⟩ := y0 c v0
    exact ⟨4 + n, st', by rw [run_add_running e0, e, verdict, v0], m⟩
  | none =>
    obtain ⟨k0, s1, e1, i1⟩ := n0 v0
    obtain ⟨y1, n1⟩ := iter hp hc (by decide) i1
    cases v1 : verdictOf st.mem base 1 with
    | some c =>
      obtain ⟨n, st', e, m⟩ := y1 c v1
      exact ⟨4 + (k0 + n), st', by rw [run_add_running e0, run_add_running e1, e, verdict, v0, v1], m⟩
    | none =>
      obtain ⟨k1, s2, e2, i2⟩ := n1 v1
      obtain ⟨y2, n2⟩ := iter hp hc (by decide) i2
      cases v2 : verdictOf st.mem base 2 with
      | some c =>
        obtain ⟨n, st', e, m⟩ := y2 c v2
        exact ⟨4 + (k0 + (k1 + n)), st', by
          rw [run_add_running e0, run_add_running e1, run_add_running e2, e, verdict, v0, v1, v2]; rfl, m⟩
      | none =>
        obtain ⟨k2, s3, e3, i3⟩ := n2 v2
        obtain ⟨st', e, m⟩ := finish_run hp hc i3
        exact ⟨4 + (k0 + (k1 + (k2 + 3))), st', by
          rw [run_add_running e0, run_add_running e1, run_add_running e2, run_add_running e3, e, verdict, v0, v1, v2]
          rfl, m⟩

/-! ## The bytes are the kernel -/

set_option maxHeartbeats 0 in
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

/-- **From the state the shell builds**, in the 128 KiB region exp223's
kernel ran in: any image that begins with the kernel's 668 bytes, the
records where the shell put them. -/
theorem from_boot (hw : Wide env base) (img : ByteArray) (hsize : 668 ≤ img.size)
    (himg : ∀ d (h : d < 668), img.get d (by omega) = bytes.getD d 0) :
    let m0 := memOfImage base img
    ∃ n st', run env n (boot env.region img) = .halted (verdict m0 base) st' ∧ st'.mem = m0 := by
  intro m0
  have hpc : (boot env.region img).pc = base := by simp [boot, hw.region]
  have hmem : (boot env.region img).mem = m0 := by simp [boot, hw.region, m0]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]
    exact code_of_image hw.fit64 (by decide) bytes_words img (by rw [kernel_length]; exact hsize)
      (fun d h => himg d (by rw [kernel_length] at h; exact h))
  obtain ⟨n, st', e, m⟩ := judges hw.placed _ hpc hcode
  rw [hmem] at e m
  exact ⟨n, st', hw.halted e, m⟩

#print axioms checks_spec
#print axioms iter
#print axioms judges
#print axioms bytes_words
#print axioms from_boot

end Exp224

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp224.image
  | _ => pure ()
  for (i, k) in Exp224.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
