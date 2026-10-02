/-
SPDX-License-Identifier: Apache-2.0

# exp203 — the count the proof promised

The first kernel: fifteen RV32IM instructions, sixty bytes, that copy 64 bytes
from `base + 0x1000` to `base + 0x2000` and halt with 0. It is small on
purpose. The lesson is not the copy; it is that a proof about *bytes* can state
an instruction count, and that count can be held against a core.

What is proved, for every `base` the 64 KiB region fits at, every value of
every byte and every register:

- `copies`: it halts with 0, the destination is the source, and every other
  byte is what it was;
- `exactly_105`: it has not stopped after 104 instructions — no halt, no
  fault — so the 105th, the `ecall`, is the last;
- `code_of_image`: any image that begins with `bytes`, loaded at `base`,
  holds the kernel — the bridge from `kernel.bin` to the theorems;
- `from_boot`: all of it, from `boot`, the state the shell builds.

The proof is organised as the design asked: a contract per block — setup
(`setup`), one iteration (`iter`, carrying `Inv`), the halt (`halt`) — and the
whole only composes them (`loop`, `to_the_ecall`). Changing the loop body means
re-proving `iter`, and nothing else.

Two things about writing it, for whoever writes the next one. The state after
several instructions is a large term, and `simp` over it — with `decide` — ran
Lean out of fourteen gigabytes; each step therefore names its result machine
with `obtain` and keeps only a small description of it. And `0 : Reg` and
`0#5` are the same register spelled two ways, which `simp` will not identify
for you: the register facts are stated in both.
-/
import Rv32.Proof
import Rv32.Asm


namespace Exp203
open Rv32

def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29

def kernel : List Instr := [
  .auipc A0 0,
  .lui T1 1,
  .op .add T1 A0 T1,
  .lui T2 2,
  .op .add T2 A0 T2,
  .opi .addi T3 0 16,
  .ld .lw T4 T1 0,
  .st .sw T2 T4 0,
  .opi .addi T1 T1 4,
  .opi .addi T2 T2 4,
  .opi .addi T3 T3 0xfff,
  .br .bne T3 0 0xff6,
  .opi .addi T0 0 1,
  .opi .addi A0 0 0,
  .ecall ]

/-- The kernel as bytes: each instruction's word, little-endian. This is
`kernel.bin`, and the only thing on the chip the theorems are about. -/
def bytes : List UInt8 :=
  kernel.flatMap fun i =>
    let n := (encode i).toNat
    [n % 256, n / 256 % 256, n / 65536 % 256, n / 16777216].map UInt8.ofNat

def image : ByteArray := ⟨bytes.toArray⟩

/-- What the theorems assume about where the kernel is. -/
structure Placed (env : Env) (base : Word) : Prop where
  align : base.toNat % 4 = 0
  fit : base.toNat + 0x10000 ≤ 2^32
  region : env.region = ⟨base.toNat, base.toNat + 0x10000⟩

/-- `base + c`, as a number: nothing wraps inside the region. -/
theorem toNat_off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (c : Nat) (hc : c < 0x10000) :
    (base + BitVec.ofNat 32 c).toNat = base.toNat + c := by
  rw [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show c < 2^32 by omega),
    Nat.mod_eq_of_lt (show base.toNat + c < 2^32 by omega)]

theorem off_add {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (c d : Nat)
    (h : c + d < 0x10000) :
    base + BitVec.ofNat 32 c + BitVec.ofNat 32 d = base + BitVec.ofNat 32 (c + d) := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_add, toNat_off hfit c (by omega), toNat_off hfit (c + d) h, BitVec.toNat_ofNat,
    Nat.mod_eq_of_lt (show d < 2^32 by omega), Nat.mod_eq_of_lt (show base.toNat + c + d < 2^32 by omega)]
  omega

theorem ok_off {env : Env} {base : Word} (hp : Placed env base) (c n : Nat) (hc : c < 0x10000)
    (h : c + n ≤ 0x10000) :
    env.region.ok (base + BitVec.ofNat 32 c) n := by
  rw [hp.region]
  simp only [Region.ok]
  rw [toNat_off hp.fit c (by omega)]; omega

theorem align_off {base : Word} (hp : base.toNat % 4 = 0) (hfit : base.toNat + 0x10000 ≤ 2^32)
    (c : Nat) (hc : c < 0x10000) (h4 : c % 4 = 0) : (base + BitVec.ofNat 32 c).toNat % 4 = 0 := by
  rw [toNat_off hfit c hc]; omega

/-- The destination after `i` words have been copied: the first `4 * i` bytes
from the source, everything else as it was. -/
def copied (m0 : Word → Byte) (base : Word) (i : Nat) : Word → Byte := fun x =>
  if (x - (base + BitVec.ofNat 32 0x2000)).toNat < 4 * i then m0 (x - BitVec.ofNat 32 0x1000)
  else m0 x

/-- One instruction of the kernel: at `base + 4k`, memory holding the kernel,
`run` takes the step `exec` says. -/
theorem stepK {env : Env} {base : Word} (hp : Placed env base) {s s' : Machine} (k : Nat)
    (hk : k < 15) (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k))
    (hexec : exec env s (kernel[k]'(by simpa [kernel] using hk)) = .running s') (n : Nat) :
    run env (n + 1) s = run env n s' :=
  run_code n _ hcode hpc
    (by rw [hpc]; exact align_off hp.align hp.fit _ (by omega) (by omega))
    (by rw [hpc]; exact ok_off hp _ 4 (by omega) (by omega)) hexec

/-! ## The bytes are the kernel -/

theorem bytes_length : bytes.length = 60 := by decide

/-- Word `k` of `bytes`, put back together, is the encoding of instruction `k`.
Fifteen cases, each computed. -/
theorem bytes_words : ∀ k (h : k < 15),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode (kernel[k]'(by simpa [kernel] using h))).toNat := by
  decide

/-- **Any image that starts with `bytes`, loaded at `base`, holds the kernel.**
The bridge from the file to the theorems: the shell loads `kernel.bin`, which
`check.sh` holds byte-equal to `image`, and this says what those bytes are. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 60 ≤ img.size)
    (himg : ∀ d (h : d < 60), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel := by
  intro k hk
  have hk' : k < 15 := by simpa [kernel] using hk
  rw [readLE_four, ← bytes_words k hk']
  have at_ : ∀ j (hj : j < 4), memOfImage base img (base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 j)
      = BitVec.ofNat 8 (bytes.getD (4 * k + j) 0).toNat := by
    intro j hj
    unfold memOfImage
    have hd : (base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 j - base).toNat = 4 * k + j := by
      rw [off_add hfit _ _ (by omega), BitVec.toNat_sub, toNat_off hfit _ (by omega)]
      omega
    simp only [hd, show 4 * k + j < img.size by omega, ↓reduceDIte]
    rw [himg _ (by omega)]
  have e0 := at_ 0 (by decide); have e1 := at_ 1 (by decide)
  have e2 := at_ 2 (by decide); have e3 := at_ 3 (by decide)
  simp only [show base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 0 = base + BitVec.ofNat 32 (4 * k)
    by simp, Nat.add_zero] at e0
  rw [e0, show base + BitVec.ofNat 32 (4 * k) + 1 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 1
    from rfl, e1, show base + BitVec.ofNat 32 (4 * k) + 2 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 2
    from rfl, e2, show base + BitVec.ofNat 32 (4 * k) + 3 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 3
    from rfl, e3]
  simp only [BitVec.toNat_ofNat]
  have := (bytes.getD (4 * k) 0).toNat_lt
  have := (bytes.getD (4 * k + 1) 0).toNat_lt
  have := (bytes.getD (4 * k + 2) 0).toNat_lt
  have := (bytes.getD (4 * k + 3) 0).toNat_lt
  omega

/-! ## Block 1: six instructions of setup -/

theorem setup {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 6 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 24
      ∧ s'.reg T1 = base + BitVec.ofNat 32 0x1000 ∧ s'.reg T2 = base + BitVec.ofNat 32 0x2000
      ∧ s'.reg T3 = BitVec.ofNat 32 16 ∧ s'.mem = s.mem := by
  rw [stepK hp 0 (by decide) hcode (by simp [hpc]) rfl]
  rw [stepK hp 1 (by decide) (by simpa using hcode) (by simp [hpc]) rfl]
  rw [stepK hp 2 (by decide) (by simpa using hcode) (by simp [hpc, BitVec.add_assoc]) rfl]
  rw [stepK hp 3 (by decide) (by simpa using hcode) (by simp [hpc, BitVec.add_assoc]) rfl]
  rw [stepK hp 4 (by decide) (by simpa using hcode) (by simp [hpc, BitVec.add_assoc]) rfl]
  rw [stepK hp 5 (by decide) (by simpa using hcode) (by simp [hpc, BitVec.add_assoc]) rfl]
  refine ⟨_, rfl, ?_⟩
  simp [hpc, reg_setReg, T1, T2, T3, A0, aluR, aluI, BitVec.add_assoc]

/-! ## One word copied -/

theorem toNat_sub_off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (x : Word) (c : Nat)
    (hc : c < 0x10000) :
    (x - (base + BitVec.ofNat 32 c)).toNat = (2^32 - (base.toNat + c) + x.toNat) % 2^32 := by
  rw [BitVec.toNat_sub, toNat_off hfit c hc]

/-- What memory holds after iteration `i`'s store, given what it held before. -/
theorem mem_step {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte} {i : Nat}
    (hi : i < 16) (hm : ∀ x, m x = copied m0 base i x) (x : Word) :
    writeLE m (base + BitVec.ofNat 32 (0x2000 + 4 * i))
        (readLE m (base + BitVec.ofNat 32 (0x1000 + 4 * i)) 4) 4 x = copied m0 base (i + 1) x := by
  have hx := x.isLt
  have hb := base.isLt
  rw [writeLE_apply _ _ _ _ (by decide) x]
  have hd := toNat_sub_off hfit x (0x2000 + 4 * i) (by omega)
  have he := toNat_sub_off hfit x 0x2000 (by omega)
  generalize (x - (base + BitVec.ofNat 32 (0x2000 + 4 * i))).toNat = d at hd ⊢
  generalize hE : (x - (base + BitVec.ofNat 32 0x2000)).toNat = e at he
  by_cases hlt : d < 4
  · simp only [hlt, ↓reduceIte]
    rw [readLE_four_byte _ _ _ hlt, hm]
    unfold copied
    have hxv : x.toNat = base.toNat + 0x2000 + 4 * i + d := by omega
    have heq : base + BitVec.ofNat 32 (0x1000 + 4 * i) + BitVec.ofNat 32 d
        = x - BitVec.ofNat 32 0x1000 := by
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_add, toNat_off hfit _ (by omega), BitVec.toNat_sub, BitVec.toNat_ofNat,
        BitVec.toNat_ofNat]
      omega
    rw [heq, hE]
    have c1 : ¬ (x - BitVec.ofNat 32 0x1000 - (base + BitVec.ofNat 32 0x2000)).toNat < 4 * i := by
      rw [BitVec.toNat_sub, BitVec.toNat_sub, toNat_off hfit _ (by omega), BitVec.toNat_ofNat]
      omega
    have c2 : e < 4 * (i + 1) := by omega
    simp only [c1, c2, ↓reduceIte]
  · simp only [hlt, ↓reduceIte]
    rw [hm]; unfold copied
    rw [hE]
    by_cases c : e < 4 * i
    · have c' : e < 4 * (i + 1) := by omega
      simp only [c, c', ↓reduceIte]
    · have c' : ¬ e < 4 * (i + 1) := by omega
      simp only [c, c', ↓reduceIte]

/-! ## Block 2: the loop -/

/-- At the top of iteration `i` — or, once `i` is 16, at the instruction after
the loop: the pointers have moved `4 * i` bytes, the counter has `16 - i` left,
and memory is the original with the first `4 * i` bytes copied. -/
def Inv (base : Word) (m0 : Word → Byte) (i : Nat) (s : Machine) : Prop :=
  s.pc = base + BitVec.ofNat 32 (if i < 16 then 24 else 48) ∧
  s.reg T1 = base + BitVec.ofNat 32 (0x1000 + 4 * i) ∧
  s.reg T2 = base + BitVec.ofNat 32 (0x2000 + 4 * i) ∧
  s.reg T3 = BitVec.ofNat 32 (16 - i) ∧
  ∀ x, s.mem x = copied m0 base i x

/-- The copy never touches the kernel's own sixty bytes. -/
theorem code_of_copied {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m0 m : Word → Byte}
    {i : Nat} (hi : i ≤ 16) (hm : ∀ x, m x = copied m0 base i x) (hc : CodeAt m0 base kernel) :
    CodeAt m base kernel := by
  refine CodeAt.congr (by simp [kernel]; omega) (fun x h1 h2 => ?_) hc
  rw [hm]; unfold copied
  have := toNat_sub_off hfit x 0x2000 (by omega)
  have hx := x.isLt
  have : ¬ (x - (base + BitVec.ofNat 32 0x2000)).toNat < 4 * i := by
    simp [kernel] at h2; omega
  simp only [this, ↓reduceIte]

/-- `addi t3, t3, -1`, and whether `bne t3, x0` then goes round again. -/
theorem countdown {i : Nat} (hi : i < 16) :
    BitVec.ofNat 32 (16 - i) + BitVec.signExtend 32 (4095 : BitVec 12) = BitVec.ofNat 32 (16 - (i + 1)) := by
  have : BitVec.signExtend 32 (4095 : BitVec 12) = BitVec.ofNat 32 (2^32 - 1) := by decide
  rw [this]
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat]
  omega

theorem again {i : Nat} (hi : i < 16) :
    taken .bne (BitVec.ofNat 32 (16 - (i + 1))) 0 = decide (i + 1 < 16) := by
  simp only [taken]
  by_cases h : i + 1 < 16
  · simp only [h, decide_true]
    simp only [bne_iff_ne, ne_eq]
    intro e; have := congrArg BitVec.toNat e; simp at this; omega
  · simp only [h, decide_false]
    simp only [bne_eq_false_iff_eq]
    apply BitVec.eq_of_toNat_eq; simp; omega

theorem iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 16) {s : Machine} (h : Inv base m0 i s) :
    ∃ s', run env 6 s = .running s' ∧ Inv base m0 (i + 1) s' := by
  obtain ⟨hpc, h1, h2, h3, hm⟩ := h
  have fit := hp.fit
  simp only [hi, ↓reduceIte] at hpc
  have hcode := code_of_copied fit (by omega) hm hc0
  have se0 : (0 : BitVec 12).signExtend 32 = 0 := by decide
  have se4 : (4 : BitVec 12).signExtend 32 = BitVec.ofNat 32 4 := by decide
  have hoff : ((0xff6 : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 0xffffffec := by decide
  -- Which registers are which: a read of one is unaffected by a write to another.
  have n14 : T1 ≠ T4 := by decide
  have n24 : T2 ≠ T4 := by decide
  have n34 : T3 ≠ T4 := by decide
  have n21 : T2 ≠ T1 := by decide
  have n31 : T3 ≠ T1 := by decide
  have n32 : T3 ≠ T2 := by decide
  have z1 : T1 ≠ 0 := by decide
  have z2 : T2 ≠ 0 := by decide
  have z3 : T3 ≠ 0 := by decide
  have z4 : T4 ≠ 0 := by decide
  -- and the same, for the literal `0#5` that simp turns the other spelling into
  have z1' : T1 ≠ 0#5 := by decide
  have z2' : T2 ≠ 0#5 := by decide
  have z3' : T3 ≠ 0#5 := by decide
  have z4' : T4 ≠ 0#5 := by decide
  -- lw t4, 0(t1)
  have a1 : s.reg T1 + (0 : BitVec 12).signExtend 32 = base + BitVec.ofNat 32 (0x1000 + 4 * i) := by
    rw [se0]; simp [h1]
  obtain ⟨s1, e1, p1, m1, r1⟩ : ∃ s1, run env 1 s = .running s1
      ∧ s1.pc = base + BitVec.ofNat 32 28 ∧ s1.mem = s.mem
      ∧ ∀ r, s1.reg r = if r = T4 then
          BitVec.ofNat 32 (readLE s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * i)) 4) else s.reg r :=
    ⟨_, (stepK hp 6 (by decide) hcode (by rw [hpc])
        (exec_lw (by rw [a1]; exact align_off hp.align fit _ (by omega) (by omega))
          (by rw [a1]; exact ok_off hp _ 4 (by omega) (by omega))) 0).trans (run_zero _ _),
      by simp [hpc, BitVec.add_assoc],
      by simp,
      fun r => by rw [next_reg, reg_setReg, a1]; by_cases hr : r = T4 <;> simp [hr, z4']⟩
  -- sw t4, 0(t2)
  have a2 : s1.reg T2 + (0 : BitVec 12).signExtend 32 = base + BitVec.ofNat 32 (0x2000 + 4 * i) := by
    rw [se0, r1]; simp [n24, h2]
  obtain ⟨s2, e2, p2, m2, r2⟩ : ∃ s2, run env 1 s1 = .running s2
      ∧ s2.pc = base + BitVec.ofNat 32 32
      ∧ (∀ x, s2.mem x = copied m0 base (i + 1) x)
      ∧ ∀ r, s2.reg r = s1.reg r := by
    refine ⟨_, (stepK hp 7 (by decide) (by rw [m1]; exact hcode) (by rw [p1])
        (exec_sw (by rw [a2]; exact align_off hp.align fit _ (by omega) (by omega))
          (by rw [a2]; exact ok_off hp _ 4 (by omega) (by omega))) 0).trans (run_zero _ _),
      by simp [p1, BitVec.add_assoc], fun x => ?_, fun r => rfl⟩
    have v4 : (s1.reg T4).toNat = readLE s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * i)) 4 := by
      rw [r1]; simp only [↓reduceIte]
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)]
    simp only [next_mem]
    rw [a2, v4, m1]
    exact mem_step fit hi hm x
  have hcode2 := code_of_copied fit (by omega) m2 hc0
  -- addi t1, t1, 4; addi t2, t2, 4; addi t3, t3, -1
  obtain ⟨s3, e3, p3, m3, r3⟩ : ∃ s3, run env 3 s2 = .running s3
      ∧ s3.pc = base + BitVec.ofNat 32 44 ∧ s3.mem = s2.mem
      ∧ s3.reg T1 = base + BitVec.ofNat 32 (0x1000 + 4 * (i + 1))
      ∧ s3.reg T2 = base + BitVec.ofNat 32 (0x2000 + 4 * (i + 1))
      ∧ s3.reg T3 = BitVec.ofNat 32 (16 - (i + 1)) := by
    rw [stepK hp 8 (by decide) hcode2 (by rw [p2])  rfl,
      stepK hp 9 (by decide) (by simpa using hcode2) (by simp [p2, BitVec.add_assoc]) rfl,
      stepK hp 10 (by decide) (by simpa using hcode2) (by simp [p2, BitVec.add_assoc]) rfl]
    refine ⟨_, rfl, by simp [p2, BitVec.add_assoc], by simp, ?_, ?_, ?_⟩
    · simp only [next_reg, reg_setReg, n31, n21, false_and, ↓reduceIte, true_and, ne_eq, z1,
        not_false_eq_true, aluI, se4, r2, r1, n14, h1]
      rw [off_add fit _ _ (by omega)]; congr 2
    · simp only [next_reg, reg_setReg, n32, false_and, ↓reduceIte, true_and, ne_eq, z2,
        not_false_eq_true, aluI, se4, r2, r1, n24, n21, h2]
      rw [off_add fit _ _ (by omega)]; congr 2
    · simp only [next_reg, reg_setReg, true_and, ne_eq, z3, not_false_eq_true, ↓reduceIte, aluI,
        r2, r1, n34, h3]
      exact countdown hi
  -- bne t3, x0, loop
  refine ⟨if taken .bne (s3.reg T3) (s3.reg 0) then
      s3.setPc (s3.pc + ((0xff6 : BitVec 12) ++ 0#1).signExtend 32) else s3.next, ?_, ?_⟩
  · rw [show 6 = 1 + (1 + (3 + 1)) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3]
    exact (stepK hp 11 (by decide) (by rw [m3]; exact hcode2) (by rw [p3]) exec_br 0).trans
      (run_zero _ _)
  · have ht : taken .bne (s3.reg T3) (s3.reg 0) = decide (i + 1 < 16) := by
      rw [r3.2.2, reg_zero]; exact again hi
    rw [ht]
    by_cases hl : i + 1 < 16
    · simp only [hl, decide_true, ↓reduceIte]
      unfold Inv
      refine ⟨?_, ?_, ?_, ?_, ?_⟩
      · rw [setPc_pc, p3, hoff, BitVec.add_assoc]
        simp only [hl, ↓reduceIte]
        rw [show (44#32 : Word) + 4294967276#32 = BitVec.ofNat 32 24 from by decide]
      · rw [setPc_reg]; exact r3.1
      · rw [setPc_reg]; exact r3.2.1
      · rw [setPc_reg]; exact r3.2.2
      · intro x; rw [setPc_mem, m3]; exact m2 x
    · simp only [hl, decide_false, Bool.false_eq_true, ↓reduceIte]
      unfold Inv
      refine ⟨?_, ?_, ?_, ?_, ?_⟩
      · rw [next_pc, p3, BitVec.add_assoc]
        simp only [hl, ↓reduceIte]
        rw [show (44#32 : Word) + 4 = BitVec.ofNat 32 48 from by decide]
      · rw [next_reg]; exact r3.1
      · rw [next_reg]; exact r3.2.1
      · rw [next_reg]; exact r3.2.2
      · intro x; rw [next_mem, m3]; exact m2 x

/-- Sixteen iterations, by induction: after `j` of them, the invariant holds
for `j`. -/
theorem loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv base m0 0 s) :
    ∀ j ≤ 16, ∃ s', run env (6 * j) s = .running s' ∧ Inv base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 6 * (j + 1) = 6 * j + 6 by omega, run_add_running e, e'], hs''⟩

/-! ## Block 3: halt -/

theorem halt {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : Inv base m0 16 s) :
    ∃ s1 s2, run env 2 s = .running s1 ∧ run env 1 s1 = .halted 0 s2 ∧ ∀ x, s2.mem x = s.mem x := by
  obtain ⟨hpc, -, -, -, hm⟩ := h
  simp only [show ¬ (16 < 16) by decide, ↓reduceIte] at hpc
  have hcode := code_of_copied hp.fit (by omega) hm hc0
  have zt : T0 ≠ 0#5 := by decide
  have za : A0 ≠ 0#5 := by decide
  have zt' : T0 ≠ 0 := by decide
  have za' : A0 ≠ 0 := by decide
  have nta : ¬ (A0 = T0) := by decide
  have nat : ¬ (T0 = A0) := by decide
  -- addi t0, x0, 1; addi a0, x0, 0 — and the machine that reaches the ecall
  let s1 := ((s.setReg T0 (aluI .addi (s.reg 0) (BitVec.signExtend 32 (1 : BitVec 12)))).next.setReg A0
    (aluI .addi ((s.setReg T0 (aluI .addi (s.reg 0) (BitVec.signExtend 32 (1 : BitVec 12)))).next.reg 0)
      (BitVec.signExtend 32 (0 : BitVec 12)))).next
  have p1 : s1.pc = base + BitVec.ofNat 32 56 := by
    simp only [s1, next_pc, setReg_pc, hpc, BitVec.add_assoc]; rfl
  have t0 : s1.reg T0 = 1 := by
    simp only [s1, next_reg, reg_setReg, reg_zero, nat, false_and, ↓reduceIte, ne_eq, zt',
      not_false_eq_true, and_self, aluI]
    decide
  have a0 : s1.reg A0 = 0 := by
    simp only [s1, next_reg, reg_setReg, reg_zero, ne_eq, za',
      not_false_eq_true, and_self, ↓reduceIte, aluI]
    decide
  refine ⟨s1, s1, ?_, ?_, fun x => by simp [s1]⟩
  · rw [stepK hp 12 (by decide) hcode (by rw [hpc]) rfl,
      stepK hp 13 (by decide) (by simpa using hcode) (by simp [hpc, BitVec.add_assoc]) rfl]
    rfl
  · rw [← a0]
    exact run_code_halt (prog := kernel) (k := 14) 0 (by decide) (by simpa [s1] using hcode)
      (by rw [p1])
      (by rw [p1]; exact align_off hp.align hp.fit 56 (by omega) (by omega))
      (by rw [p1]; exact ok_off hp 56 4 (by omega) (by omega))
      (exec_halt t0)

/-! ## The whole kernel -/

/-- Setup, sixteen iterations, and the two instructions before the `ecall`:
104 instructions, and the machine they leave. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env 104 s = .running s1 ∧ run env 1 s1 = .halted 0 s2
      ∧ ∀ x, s2.mem x = copied s.mem base 16 x := by
  obtain ⟨s6, e6, p6, t1, t2, t3, m6⟩ := setup hp s hpc hcode
  have inv0 : Inv base s.mem 0 s6 :=
    ⟨by rw [p6]; rfl, by rw [t1], by rw [t2], by rw [t3],
     fun x => by rw [m6]; unfold copied; simp⟩
  obtain ⟨s102, e96, inv16⟩ := loop hp hcode inv0 16 (Nat.le_refl _)
  obtain ⟨s1, s2, e2, e1, hm⟩ := halt hp hcode inv16
  refine ⟨s1, s2, ?_, e1, fun x => by rw [hm]; exact inv16.2.2.2.2 x⟩
  rw [show 104 = 6 + (6 * 16 + 2) by rfl, run_add_running e6, run_add_running e96, e2]

/-- **The kernel copies.** From `base`, with the kernel's sixty bytes there, it
halts with result 0; the 64 bytes at `base + 0x2000` are then the 64 at
`base + 0x1000`, and every other byte is what it was. For every `base` the
64 KiB region fits at, every value of every byte, every register. -/
theorem copies {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env 105 s = .halted 0 s'
      ∧ (∀ k < 64, s'.mem (base + BitVec.ofNat 32 (0x2000 + k)) = s.mem (base + BitVec.ofNat 32 (0x1000 + k)))
      ∧ (∀ x, 64 ≤ (x - (base + BitVec.ofNat 32 0x2000)).toNat → s'.mem x = s.mem x) := by
  obtain ⟨s1, s2, e104, e1, hm⟩ := to_the_ecall hp s hpc hcode
  have fit := hp.fit
  refine ⟨s2, by rw [show 105 = 104 + 1 by rfl, run_add_running e104, e1], ?_, ?_⟩
  · intro k hk
    rw [hm]; unfold copied
    have hd : (base + BitVec.ofNat 32 (0x2000 + k) - (base + BitVec.ofNat 32 0x2000)).toNat = k := by
      rw [BitVec.toNat_sub, toNat_off fit _ (by omega), toNat_off fit _ (by omega)]; omega
    have he : base + BitVec.ofNat 32 (0x2000 + k) - BitVec.ofNat 32 0x1000
        = base + BitVec.ofNat 32 (0x1000 + k) := by
      apply BitVec.eq_of_toNat_eq
      rw [BitVec.toNat_sub, toNat_off fit _ (by omega), toNat_off fit _ (by omega),
        BitVec.toNat_ofNat]
      omega
    simp only [hd, show k < 4 * 16 by omega, ↓reduceIte, he]
  · intro x hx
    rw [hm]; unfold copied
    simp only [show ¬ (x - (base + BitVec.ofNat 32 0x2000)).toNat < 4 * 16 by omega, ↓reduceIte]

/-- **And in exactly 105 instructions.** It has not stopped after 104 — no
halt, no fault — for any input. The 105th is the `ecall`. -/
theorem exactly_105 {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1, run env 104 s = .running s1 := by
  obtain ⟨s1, -, e104, -, -⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s1, e104⟩

/-- **From the state the shell builds.** `boot` is the calling convention —
the image at the region's base, `pc` there, registers zero but `sp` — and it is
the state `rv32run` and the RTL harness both start from. Any image that begins
with the kernel's sixty bytes copies its own bytes `0x1000..0x1040` to
`0x2000..0x2040` and halts with 0 at instruction 105, and not before. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 60 ≤ img.size) (himg : ∀ d (h : d < 60), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env 104 (boot env.region img) = .running s1) ∧
    ∃ s', run env 105 (boot env.region img) = .halted 0 s'
      ∧ (∀ k < 64, s'.mem (base + BitVec.ofNat 32 (0x2000 + k))
          = memOfImage base img (base + BitVec.ofNat 32 (0x1000 + k)))
      ∧ (∀ x, 64 ≤ (x - (base + BitVec.ofNat 32 0x2000)).toNat → s'.mem x = memOfImage base img x) := by
  have hpc : (boot env.region img).pc = base := by
    simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by
    simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  refine ⟨exactly_105 hp _ hpc hcode, ?_⟩
  obtain ⟨s', e, h1, h2⟩ := copies hp _ hpc hcode
  exact ⟨s', e, fun k hk => by rw [h1 k hk, hmem], fun x hx => by rw [h2 x hx, hmem]⟩

#print axioms bytes_words
#print axioms code_of_image
#print axioms iter
#print axioms loop
#print axioms halt
#print axioms copies
#print axioms exactly_105
#print axioms from_boot
end Exp203

/-- `lean --run Copy64.lean OUT` writes `image` to OUT — that is `kernel.bin` —
and prints the listing: offset, word, instruction. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp203.image
  | _ => pure ()
  for (i, k) in Exp203.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
