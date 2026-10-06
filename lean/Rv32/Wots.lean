/-
SPDX-License-Identifier: Apache-2.0

# WOTS (w = 16), the part a verifier and anything built on it share

exp205 wrote a WOTS verify kernel; exp206's MSS verifier is the same kernel up
to the end of each chain's walk, and different after it — where exp205
compares the chain's end with the public key, exp206 writes it down for the
leaf. So the first 69 instructions are here, `head`, with what they do:
`setup`, the 64 message digits and their checksum, and for each chain the
signature's value copied into the HASH buffer and walked `15 - d` steps.

Every theorem is about any program `prog` that starts with `head` (`Starts`),
from the instruction it names, so a kernel that continues differently after
instruction 68 still has all of it. exp205 and exp206 are the two.

The layout is exp205's: the message at `MSG`, the signature at `SIG`, the
second pointer `setup` makes at `KEY` (exp205's public key, exp206's chain
ends), and scratch at `SCR` — the 64-byte HASH buffer, then the 67 digits.
-/
import Rv32.Blocks

namespace Rv32.Wots
open Rv32

def S0 : Reg := 8
def S1 : Reg := 9
def S2 : Reg := 18
def S3 : Reg := 19
def S4 : Reg := 20
def S5 : Reg := 21
def S6 : Reg := 22
def S7 : Reg := 23
def T1 : Reg := 6
def T2 : Reg := 7
def T3 : Reg := 28
def T4 : Reg := 29
def A3 : Reg := 13
def A4 : Reg := 14
def A5 : Reg := 15
def A6 : Reg := 16

/-- Where everything is, from `auipc`; the HASH input's zero half; `t0 = 0`
for every HASH from here on. -/
def setup : List Instr := [
  .auipc S0 0,
  .lui T1 1, .op .add S3 S0 T1,
  .lui T1 2, .op .add S1 S0 T1,
  .lui T1 3, .op .add S2 S0 T1,
  .lui T1 8, .op .add S5 S0 T1,
  .opi .addi S6 0 0 ] ++
  (List.range 8).map (fun j => .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)))

/-- The 64 message digits into scratch, low nibble first, and their
checksum `Σ (15 - a)` into `a3`. -/
def digits : List Instr := [
  .opi .addi A4 S3 0, .opi .addi A5 S5 64, .opi .addi A6 S3 32, .opi .addi A3 0 0,
  .ld .lbu T1 A4 0, .opi .andi T2 T1 15, .sh .srli T1 T1 4,
  .st .sb A5 T2 0, .st .sb A5 T1 1,
  .op .sub A3 A3 T2, .op .sub A3 A3 T1, .opi .addi A3 A3 30,
  .opi .addi A4 A4 1, .opi .addi A5 A5 2, .br .bne A4 A6 0xfec ]

/-- The checksum's three digits, low first, after the message's. -/
def checksum : List Instr := [
  .opi .andi T1 A3 15, .st .sb A5 T1 0,
  .sh .srli T1 A3 4, .opi .andi T1 T1 15, .st .sb A5 T1 1,
  .sh .srli T1 A3 8, .st .sb A5 T1 2 ]

/-- The chains: the digit pointer, its end, and HASH's three arguments,
which no chain changes — the buffer is hashed in place. -/
def start : List Instr := [
  .opi .addi A4 S5 64, .opi .addi S7 S5 131, .opi .addi T0 0 0,
  .opi .addi A0 S5 0, .opi .addi A1 0 64, .opi .addi A2 S5 0 ]

def copy : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T4 S1 (BitVec.ofNat 12 (4 * j)), .st .sw S5 T4 (BitVec.ofNat 12 (4 * j))]

/-- `15 - d` steps along the chain, none at all when the digit is 15. -/
def walk : List Instr := [
  .ld .lbu T3 A4 0, .opi .addi T2 0 15, .op .sub T3 T2 T3,
  .br .beq T3 0 8,
  .ecall, .opi .addi T3 T3 0xfff, .br .bne T3 0 0xffc ]

/-- Instructions 0 to 68 of every kernel here that verifies WOTS. Chain `i`'s
body starts at 46, the copy; its walk ends at 69, where the kernels part. -/
def head : List Instr := setup ++ digits ++ checksum ++ start ++ copy ++ walk

theorem head_length : head.length = 69 := by decide

/-- `prog` starts with the first `n` instructions of `head`, and leaves the
scratch above its code alone. A verifier starts with all 69; exp213's signer
starts with the first 46 — setup, the digits, the checksum, the chains'
registers — and walks its chains its own way. -/
structure Starts (n : Nat) (prog : List Instr) : Prop where
  pre : ∀ k < n, prog.getD k .ecall = head.getD k .ecall
  long : n ≤ prog.length
  below : 4 * prog.length ≤ 0x1000

/-! ## Where everything is

Offsets from `base`, the kernel's own address, which `auipc` finds. -/

/-- The message, 32 bytes. -/
def MSG : Nat := 0x1000
/-- The signature: chain `i`'s value at `SIG + 32 i`, for `i < 67`. -/
def SIG : Nat := 0x2000
/-- What `s2` points at: exp205's public key, exp206's chain ends. -/
def KEY : Nat := 0x3000
/-- Scratch, 131 bytes: the HASH buffer — 32 bytes of chain value, then 32
zeros — and from `SCR + 64` the 67 digits. -/
def SCR : Nat := 0x8000

/-! ## WOTS

`H` is `env.hash`, and nothing is assumed about it. -/

/-- One step along a chain: HASH of the value and 32 zeros. -/
def F (H : List Byte → Fin 32 → Byte) (x : List Byte) : List Byte := List.ofFn (H (x ++ List.replicate 32 0))

/-- `k` steps along a chain from `x`. -/
def chain (H : List Byte → Fin 32 → Byte) (x : List Byte) : Nat → List Byte
  | 0 => x
  | k + 1 => F H (chain H x k)

/-- Digit `i < 64` of the message: base 16, low nibble of each byte first. -/
def msgDigit (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  (m (base + BitVec.ofNat 32 (MSG + i / 2))).toNat / 16 ^ (i % 2) % 16

/-- The checksum of the first `n` message digits: `Σ (15 - a)`. -/
def csumTo (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 15 - msgDigit m base i).sum

/-- Digit `i < 67`: the 64 of the message, then the checksum's three, low first. -/
def digit (m : Word → Byte) (base : Word) (i : Nat) : Nat :=
  if i < 64 then msgDigit m base i else csumTo m base 64 / 16 ^ (i - 64) % 16

def sigAt (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (SIG + 32 * i)) 32

/-- How many HASH calls the walks make: `Σ (15 - dᵢ)`, which depends on the
message. -/
def steps (m : Word → Byte) (base : Word) : Nat :=
  ((List.range 67).map fun i => 15 - digit m base i).sum

/-- The digits, as bytes: what the kernel writes into scratch. -/
def dg (m : Word → Byte) (base : Word) : Nat → Byte := fun d => BitVec.ofNat 8 (digit m base d)

/-! ## A program that starts with `head`

What every theorem below needs of `prog`: the instructions `head` has, and
room. -/

section
variable {prog : List Instr}

variable {n : Nat}

theorem Starts.hlen (hP : Starts n prog) : 4 * prog.length < 0x10000 := by have := hP.below; omega

theorem Starts.lt (hP : Starts n prog) {k : Nat} (hk : k < n) : k < prog.length := by
  have := hP.long; omega

/-- Starting with `n` of them is starting with fewer. -/
theorem Starts.down (hP : Starts n prog) {m : Nat} (hm : m ≤ n) : Starts m prog :=
  ⟨fun k hk => hP.pre k (by omega), by have := hP.long; omega, hP.below⟩

theorem Starts.at (hP : Starts n prog) {k : Nat} {i : Instr} (h : head.getD k .ecall = i) (hk : k < n) :
    prog.getD k .ecall = i := (hP.pre k hk).trans h

theorem head_zero : ∀ j < 8, head.getD (10 + j) .ecall = .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)) := by
  decide
theorem head_copy : ∀ j < 8, head.getD (46 + 2 * j) .ecall = .ld .lw T4 S1 (BitVec.ofNat 12 (4 * j))
    ∧ head.getD (46 + 2 * j + 1) .ecall = .st .sw S5 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide

theorem Starts.at_zero (hP : Starts 46 prog) :
    ∀ j < 8, prog.getD (10 + j) .ecall = .st .sw S5 0 (BitVec.ofNat 12 (32 + 4 * j)) :=
  fun j hj => (hP.pre _ (by omega)).trans (head_zero j hj)
theorem Starts.at_copy (hP : Starts 69 prog) :
    ∀ j < 8, prog.getD (46 + 2 * j) .ecall = .ld .lw T4 S1 (BitVec.ofNat 12 (4 * j))
      ∧ prog.getD (46 + 2 * j + 1) .ecall = .st .sw S5 T4 (BitVec.ofNat 12 (4 * j)) :=
  fun j hj => ⟨(hP.pre _ (by omega)).trans (head_copy j hj).1, (hP.pre _ (by omega)).trans (head_copy j hj).2⟩

end


/-! ## Block 1: setup -/

/-- The registers setup leaves that nothing after it changes. -/
structure Regs (base : Word) (s : Machine) : Prop where
  s0 : s.reg S0 = base
  s3 : s.reg S3 = base + BitVec.ofNat 32 MSG
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR

/-! ## Block 2: the digits -/

/-- `andi 15`: the low nibble. -/
theorem and15 (b : Nat) (hb : b < 2^32) :
    BitVec.ofNat 32 b &&& BitVec.signExtend 32 (15 : BitVec 12) = BitVec.ofNat 32 (b % 16) := by
  rw [show BitVec.signExtend 32 (15 : BitVec 12) = BitVec.ofNat 32 15 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat]
  rw [show (15 : Nat) % 2^32 = 2^4 - 1 by decide, Nat.and_two_pow_sub_one_eq_mod]
  omega

/-- `srli n`: division by `2^n`. -/
theorem shr (b n : Nat) (hb : b < 2^32) :
    BitVec.ofNat 32 b >>> n = BitVec.ofNat 32 (b / 2 ^ n) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow]
  rw [Nat.mod_eq_of_lt hb, Nat.mod_eq_of_lt (by have := Nat.div_le_self b (2 ^ n); omega)]

/-- `sub a3, a3, t2; sub a3, a3, t1; addi a3, a3, 30`: the checksum takes
`15 - lo` and `15 - hi`, and never wraps. -/
theorem csum_step (X lo hi : Nat) (hX : X ≤ 960) (hlo : lo < 16) (hhi : hi < 16) :
    BitVec.ofNat 32 X - BitVec.ofNat 32 lo - BitVec.ofNat 32 hi + BitVec.signExtend 32 (30 : BitVec 12)
      = BitVec.ofNat 32 (X + (15 - lo) + (15 - hi)) := by
  rw [show BitVec.signExtend 32 (30 : BitVec 12) = BitVec.ofNat 32 30 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_sub, BitVec.toNat_ofNat]
  rw [Nat.mod_eq_of_lt (show lo < 2^32 by omega), Nat.mod_eq_of_lt (show X < 2^32 by omega),
    Nat.mod_eq_of_lt (show hi < 2^32 by omega), Nat.mod_eq_of_lt (show (30 : Nat) < 2^32 by omega),
    Nat.mod_eq_of_lt (show X + (15 - lo) + (15 - hi) < 2^32 by omega)]
  generalize hA : (2 ^ 32 - lo + X) % 2 ^ 32 = A
  have hA' : A = if lo ≤ X then X - lo else 2 ^ 32 - lo + X := by
    rw [← hA]; exact wrapdist _ _ (by omega) (by omega)
  have hAlt : A < 2 ^ 32 := by rw [← hA]; exact Nat.mod_lt _ (by omega)
  generalize hB : (2 ^ 32 - hi + A) % 2 ^ 32 = B
  have hB' : B = if hi ≤ A then A - hi else 2 ^ 32 - hi + A := by
    rw [← hB]; exact wrapdist _ _ (by omega) hAlt
  have key : B + 30 = X + (15 - lo) + (15 - hi) ∨ B + 30 = X + (15 - lo) + (15 - hi) + 2 ^ 32 := by
    split at hA' <;> split at hB' <;> omega
  rcases key with k | k <;> rw [k]
  · exact Nat.mod_eq_of_lt (by omega)
  · rw [Nat.add_mod_right]; exact Nat.mod_eq_of_lt (by omega)

theorem csumTo_succ (m : Word → Byte) (base : Word) (n : Nat) :
    csumTo m base (n + 1) = csumTo m base n + (15 - msgDigit m base n) := by
  simp [csumTo, List.range_succ, List.sum_append]

theorem csumTo_le (m : Word → Byte) (base : Word) (n : Nat) : csumTo m base n ≤ 15 * n := by
  induction n with
  | zero => simp [csumTo]
  | succ n ih => rw [csumTo_succ]; omega

theorem msgDigit_lt (m : Word → Byte) (base : Word) (i : Nat) : msgDigit m base i < 16 := by
  unfold msgDigit; omega

theorem digit_lt (m : Word → Byte) (base : Word) (i : Nat) : digit m base i < 16 := by
  unfold digit; split
  · exact msgDigit_lt m base i
  · omega

theorem digit_of_lt (m : Word → Byte) (base : Word) (i : Nat) (hi : i < 64) :
    digit m base i = msgDigit m base i := by
  unfold digit; exact ite_eq_left_of_eq_true _ _ (eq_true hi)

/-- The low and the high nibble of message byte `k`, as `msgDigit` reads them. -/
theorem md_lo (m : Word → Byte) (base : Word) (k : Nat) :
    msgDigit m base (2 * k) = (m (base + BitVec.ofNat 32 (MSG + k))).toNat % 16 := by
  unfold msgDigit
  rw [show 2 * k / 2 = k by omega, show 2 * k % 2 = 0 by omega]; simp
theorem md_hi (m : Word → Byte) (base : Word) (k : Nat) :
    msgDigit m base (2 * k + 1) = (m (base + BitVec.ofNat 32 (MSG + k))).toNat / 16 := by
  unfold msgDigit
  rw [show (2 * k + 1) / 2 = k by omega, show (2 * k + 1) % 2 = 1 by omega]
  have := (m (base + BitVec.ofNat 32 (MSG + k))).isLt
  simp only [Nat.pow_one]; omega

/-- At the top of digit iteration `k` — or, at 32, at the checksum: the
pointers have moved `k` bytes and `2k` digits, `a3` holds the checksum of
the first `2k` digits, and those digits are in scratch over `M`, the memory
setup left. Every register the pass does not touch is what it was in `R`. -/
structure DInv (base : Word) (m0 M : Word → Byte) (R : Machine) (k : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if k < 32 then 22 else 33))
  a4 : s.reg A4 = base + BitVec.ofNat 32 (MSG + k)
  a5 : s.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * k)
  a6 : s.reg A6 = base + BitVec.ofNat 32 (MSG + 32)
  a3 : s.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * k))
  mem : s.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) (2 * k) (dg m0 base)
  regs : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s.reg r = R.reg r

/-! ## Block 3: the checksum's digits, and the start of the chains -/

/-- Checksum digit `t < 3`: base 16, low first. -/
theorem digit_ck (m : Word → Byte) (base : Word) (t : Nat) :
    digit m base (64 + t) = csumTo m base 64 / 16 ^ t % 16 := by
  unfold digit; rw [ite_eq_right_of_eq_false _ _ (eq_false (by omega)), show 64 + t - 64 = t by omega]

/-- At the top of chain `i`: the pointers have moved `i` chains, HASH's
arguments are set, memory is `M` outside scratch, and scratch holds the zero
half of the buffer and all 67 digits of the message in `m0`. `M` is what the
kernel has left so far outside scratch — the input itself for exp205, which
writes nowhere else, and the input with the first `i` chain ends written for
exp206. What else is true at the top of a chain is the kernel's own. -/
structure Chains (base : Word) (M m0 : Word → Byte) (i : Nat) (s : Machine) : Prop where
  s1 : s.reg S1 = base + BitVec.ofNat 32 (SIG + 32 * i)
  a4 : s.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + i)
  s5 : s.reg S5 = base + BitVec.ofNat 32 SCR
  s7 : s.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67)
  t0 : s.reg T0 = 0
  a0 : s.reg A0 = base + BitVec.ofNat 32 SCR
  a1 : s.reg A1 = BitVec.ofNat 32 64
  a2 : s.reg A2 = base + BitVec.ofNat 32 SCR
  out : Keeps (base + BitVec.ofNat 32 SCR) 131 M s.mem
  tail : ∀ d < 32, s.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0
  dig : ∀ d < 67, s.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d

/-! ## Block 4: one chain — the signature's value, and how far to walk it -/

/-- An address in scratch past the buffer: neither the copy nor HASH touches it. -/
theorem above_buffer {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) (f : Nat → Byte)
    (c : Nat) (h1 : SCR + 32 ≤ c) (h2 : c < 0x10000) :
    overlay m (base + BitVec.ofNat 32 SCR) 32 f (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) :=
  overlay_off_out hfit _ _ (by simp only [SCR]; omega) h2 (by right; exact h1)

/-! ## Block 4: one chain — the walk -/

/-- What the walk keeps, and the buffer it advances: `j` steps along the
chain from `x`. -/
structure WInv (H : List Byte → Fin 32 → Byte) (base : Word) (M m0 : Word → Byte) (x : List Byte) (j : Nat)
    (s : Machine) : Prop where
  buf : readBytes s.mem (base + BitVec.ofNat 32 SCR) 32 = chain H x j
  out : Keeps (base + BitVec.ofNat 32 SCR) 131 M s.mem
  tail : ∀ d < 32, s.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0
  dig : ∀ d < 67, s.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d

/-- Memory after HASH of the buffer, written over the buffer. -/
def hashedMem (H : List Byte → Fin 32 → Byte) (base : Word) (m : Word → Byte) : Word → Byte :=
  writeBytes m (base + BitVec.ofNat 32 SCR) (H (readBytes m (base + BitVec.ofNat 32 SCR) 64))

/-- HASH, in place, at the buffer: one step along the chain, and nothing
else moves. -/
theorem hash_in_place {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {M m0 : Word → Byte} {x : List Byte} {j : Nat} {s : Machine} (h : WInv H base M m0 x j s) :
    WInv H base M m0 x (j + 1) { s with mem := hashedMem H base s.mem } := by
  have hin : readBytes s.mem (base + BitVec.ofNat 32 SCR) 64 = chain H x j ++ List.replicate 32 0 := by
    rw [show (64 : Nat) = 32 + 32 from rfl, readBytes_append, h.buf]
    congr 1
    apply readBytes_const
    intro d hd
    rw [off_add hfit _ _ (by simp only [SCR]; omega), off_add hfit _ _ (by simp only [SCR]; omega)]
    exact h.tail d hd
  have far : ∀ c, 32 ≤ c → c < 131 → hashedMem H base s.mem (base + BitVec.ofNat 32 (SCR + c))
        = s.mem (base + BitVec.ofNat 32 (SCR + c)) := by
    intro c h1 h2
    rw [hashedMem, writeBytes_apply, dist_off hfit _ _ (by simp only [SCR]; omega)]
    simp only [show ¬ c < 32 by omega, ↓reduceDIte]
  refine ⟨?_, ?_, ?_, ?_⟩
  · show readBytes (hashedMem H base s.mem) _ 32 = _
    rw [hashedMem, readBytes_writeBytes, hin]; rfl
  · exact h.out.trans (keeps_writeBytes hfit _ _ (by omega) (by omega) (by simp only [SCR]; omega))
  · intro d hd
    show hashedMem H base s.mem _ = _
    rw [Nat.add_assoc, far _ (by omega) (by omega), ← Nat.add_assoc]; exact h.tail d hd
  · intro d hd
    show hashedMem H base s.mem _ = _
    rw [Nat.add_assoc, far _ (by omega) (by omega), ← Nat.add_assoc]; exact h.dig d hd


section
variable {prog : List Instr} (hP : Starts 46 prog)
include hP

/-- Ten instructions that only set registers: the pointers, from `auipc`. -/
theorem setup_regs {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base prog) :
    ∃ s', run env 10 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 10) ∧ s'.mem = s.mem
      ∧ Regs base s' ∧ s'.reg S1 = base + BitVec.ofNat 32 SIG ∧ s'.reg S2 = base + BitVec.ofNat 32 KEY
      ∧ s'.reg S6 = 0 := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 0 (hP.lt (by decide)) hcode (by simp [hpc])
      (i := .auipc S0 0) (hP.at (by decide) (by decide)) rfl
  have hc1 : CodeAt s1.mem base prog := by rw [m1]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 1 (hP.lt (by decide)) hc1 p1
      (i := .lui T1 1) (hP.at (by decide) (by decide)) rfl
  have hc2 : CodeAt s2.mem base prog := by rw [m2]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 2 (hP.lt (by decide)) hc2 p2
      (i := .op .add S3 S0 T1) (hP.at (by decide) (by decide)) rfl
  have hc3 : CodeAt s3.mem base prog := by rw [m3]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 3 (hP.lt (by decide)) hc3 p3
      (i := .lui T1 2) (hP.at (by decide) (by decide)) rfl
  have hc4 : CodeAt s4.mem base prog := by rw [m4]; exact hc3
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 4 (hP.lt (by decide)) hc4 p4
      (i := .op .add S1 S0 T1) (hP.at (by decide) (by decide)) rfl
  have hc5 : CodeAt s5.mem base prog := by rw [m5]; exact hc4
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 5 (hP.lt (by decide)) hc5 p5
      (i := .lui T1 3) (hP.at (by decide) (by decide)) rfl
  have hc6 : CodeAt s6.mem base prog := by rw [m6]; exact hc5
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 6 (hP.lt (by decide)) hc6 p6
      (i := .op .add S2 S0 T1) (hP.at (by decide) (by decide)) rfl
  have hc7 : CodeAt s7.mem base prog := by rw [m7]; exact hc6
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 7 (hP.lt (by decide)) hc7 p7
      (i := .lui T1 8) (hP.at (by decide) (by decide)) rfl
  have hc8 : CodeAt s8.mem base prog := by rw [m8]; exact hc7
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 8 (hP.lt (by decide)) hc8 p8
      (i := .op .add S5 S0 T1) (hP.at (by decide) (by decide)) rfl
  have hc9 : CodeAt s9.mem base prog := by rw [m9]; exact hc8
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 9 (hP.lt (by decide)) hc9 p9
      (i := .opi .addi S6 0 0) (hP.at (by decide) (by decide)) rfl
  refine ⟨s10, (run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7 (run_cons e8 (run_cons e9 e10))))))))), p10, by rw [m10, m9, m8, m7, m6, m5, m4, m3, m2, m1], ⟨?_, ?_, ?_⟩, ?_, ?_, ?_⟩ <;>
    simp [r10, r9, r8, r7, r6, r5, r4, r3, r2, r1, hpc, S0, S1, S2, S3, S5, S6, T1,
      aluR, aluI, MSG, SIG, KEY, SCR] <;> rfl

/-- One iteration of the digit pass: eleven instructions. -/
theorem digit_iter {env : Env} {base : Word} (hp : Placed env base) {m0 M : Word → Byte}
    (hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M) (hc : CodeAt M base prog) {R : Machine}
    {k : Nat} (hk : k < 32) {s : Machine} (h : DInv base m0 M R k s) :
    ∃ s', run env 11 s = .running s' ∧ DInv base m0 M R (k + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 22) := by rw [h.pc]; simp [hk]
  have hcode : CodeAt s.mem base prog := by
    rw [h.mem]; exact code_of_overlay fit hc (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  have hbyte : s.mem (base + BitVec.ofNat 32 (MSG + k)) = m0 (base + BitVec.ofNat 32 (MSG + k)) := by
    rw [h.mem, overlay_off_out fit _ _ (by simp only [SCR]; omega) (by simp only [MSG]; omega)
      (by left; simp only [MSG, SCR]; omega)]
    exact hM.off fit (by simp only [SCR]; omega) (by simp only [MSG]; omega) (by left; simp only [MSG, SCR]; omega)
  have hb256 := (m0 (base + BitVec.ofNat 32 (MSG + k))).isLt
  generalize hb : (m0 (base + BitVec.ofNat 32 (MSG + k))).toNat = b at hb256
  -- lbu t1, 0(a4)
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := prog) (hlen := hP.hlen) hp 22 (hP.lt (by decide)) hcode hpc
    (rd := T1) (rs1 := A4) (imm := 0) (hP.at (by decide) (by decide)) (MSG + k)
    (by rw [h.a4, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _)
    (by simp only [MSG]; omega)
  have v1 : s1.reg T1 = BitVec.ofNat 32 b := by rw [reg_wrote r1 (by decide), hbyte, hb]
  -- andi t2, t1, 15
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 23 (hP.lt (by decide)) (by rw [m1]; exact hcode) p1
    (i := .opi .andi T2 T1 15) (hP.at (by decide) (by decide)) rfl
  have v2 : s2.reg T2 = BitVec.ofNat 32 (b % 16) := by
    rw [reg_wrote r2 (by decide)]; simp only [aluI]; rw [v1]; exact and15 b (by omega)
  -- srli t1, t1, 4
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 24 (hP.lt (by decide)) (by rw [m2, m1]; exact hcode) p2
    (i := .sh .srli T1 T1 4) (hP.at (by decide) (by decide)) rfl
  have v3 : s3.reg T1 = BitVec.ofNat 32 (b / 16) := by
    rw [reg_wrote r3 (by decide)]; simp only [shiftI]; rw [reg_kept r2 (by decide), v1]
    exact shr b 4 (by omega)
  have a5_3 : s3.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * k) := by
    rw [reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a5]
  -- sb t2, 0(a5)
  obtain ⟨s4, e4, p4, m4, r4⟩ := sbStep (prog := prog) (hlen := hP.hlen) hp 25 (hP.lt (by decide)) (by rw [m3, m2, m1]; exact hcode) p3
    (rs1 := A5) (rs2 := T2) (imm := 0) (hP.at (by decide) (by decide)) (SCR + 64 + 2 * k)
    (by rw [a5_3, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  -- sb t1, 1(a5)
  have hc4 : CodeAt s4.mem base prog := by
    rw [m4]; exact code_of_writeByte fit (by rw [m3, m2, m1]; exact hcode) (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  obtain ⟨s5, e5, p5, m5, r5⟩ := sbStep (prog := prog) (hlen := hP.hlen) hp 26 (hP.lt (by decide)) hc4 p4
    (rs1 := A5) (rs2 := T1) (imm := 1) (hP.at (by decide) (by decide)) (SCR + 64 + 2 * k + 1)
    (by rw [r4, a5_3, show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
        off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc5 : CodeAt s5.mem base prog := by
    rw [m5]; exact code_of_writeByte fit hc4 (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  -- sub a3, a3, t2; sub a3, a3, t1; addi a3, a3, 30
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 27 (hP.lt (by decide)) hc5 p5
    (i := .op .sub A3 A3 T2) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 28 (hP.lt (by decide)) (by rw [m6]; exact hc5) p6
    (i := .op .sub A3 A3 T1) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 29 (hP.lt (by decide)) (by rw [m7, m6]; exact hc5) p7
    (i := .opi .addi A3 A3 30) (hP.at (by decide) (by decide)) rfl
  -- addi a4, a4, 1; addi a5, a5, 2
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 30 (hP.lt (by decide)) (by rw [m8, m7, m6]; exact hc5) p8
    (i := .opi .addi A4 A4 1) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 31 (hP.lt (by decide))
    (by rw [m9, m8, m7, m6]; exact hc5) p9 (i := .opi .addi A5 A5 2) (hP.at (by decide) (by decide)) rfl
  have hc10 : CodeAt s10.mem base prog := by rw [m10, m9, m8, m7, m6]; exact hc5
  -- the values
  have kept5 : ∀ r, s5.reg r = s3.reg r := fun r => by rw [r5, r4]
  have t2_5 : s5.reg T2 = BitVec.ofNat 32 (b % 16) := by rw [kept5, reg_kept r3 (by decide), v2]
  have t1_5 : s5.reg T1 = BitVec.ofNat 32 (b / 16) := by rw [kept5, v3]
  have a3_5 : s5.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * k)) := by
    rw [kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a3]
  have v_a3 : s10.reg A3 = BitVec.ofNat 32 (csumTo m0 base (2 * (k + 1))) := by
    rw [reg_kept r10 (by decide), reg_kept r9 (by decide), reg_wrote r8 (by decide), reg_wrote r7 (by decide),
      reg_wrote r6 (by decide), reg_kept r6 (by decide), t1_5, t2_5, a3_5]
    simp only [aluR, aluI]
    rw [csum_step _ _ _ (by have := csumTo_le m0 base (2 * k); omega) (by omega) (by omega),
      show 2 * (k + 1) = 2 * k + 1 + 1 by omega, csumTo_succ, csumTo_succ, md_lo, md_hi, hb]
  have v_a4 : s10.reg A4 = base + BitVec.ofNat 32 (MSG + (k + 1)) := by
    rw [reg_kept r10 (by decide), reg_wrote r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by simp only [MSG]; omega), Nat.add_assoc]
  have v_a5 : s10.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 2 * (k + 1)) := by
    rw [reg_wrote r10 (by decide), reg_kept r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, a5_3]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (2 : BitVec 12) = BitVec.ofNat 32 2 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
    congr 2
  have v_a6 : s10.reg A6 = base + BitVec.ofNat 32 (MSG + 32) := by
    rw [reg_kept r10 (by decide), reg_kept r9 (by decide), reg_kept r8 (by decide), reg_kept r7 (by decide),
      reg_kept r6 (by decide), kept5, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide), h.a6]
  have v_mem : s10.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) (2 * (k + 1)) (dg m0 base) := by
    rw [m10, m9, m8, m7, m6, m5, m4, m3, m2, m1, h.mem, r4, v3, reg_kept r3 (by decide), v2]
    rw [← off_add fit (SCR + 64) (2 * k) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [digit_of_lt _ _ _ (by omega), md_lo, hb]),
      show SCR + 64 + 2 * k + 1 = (SCR + 64) + (2 * k + 1) by omega,
      ← off_add fit (SCR + 64) (2 * k + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [digit_of_lt _ _ _ (by omega), md_hi, hb])]
    rw [show 2 * k + 1 + 1 = 2 * (k + 1) by omega]
  have regs10 : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s10.reg r = R.reg r := by
    intro r a b c d e
    rw [reg_kept r10 c, reg_kept r9 b, reg_kept r8 a, reg_kept r7 a, reg_kept r6 a, kept5, reg_kept r3 d,
      reg_kept r2 e, reg_kept r1 d, h.regs r a b c d e]
  have ht : taken .bne (s10.reg A4) (s10.reg A6) = decide (k + 1 < 32) := by
    rw [v_a4, v_a6]; simp only [taken]
    by_cases hl : k + 1 < 32
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by simp only [MSG]; omega), toNat_off fit _ (by simp only [MSG]; omega)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show k + 1 = 32 by omega]
  -- What the branch leaves, whichever way it goes.
  have finish : ∀ s11 : Machine, run env 1 s10 = .running s11 → (∀ r, s11.reg r = s10.reg r) →
      s11.mem = s10.mem → s11.pc = base + BitVec.ofNat 32 (4 * (if k + 1 < 32 then 22 else 33)) →
      ∃ s', run env 11 s = .running s' ∧ DInv base m0 M R (k + 1) s' := by
    intro s11 e11 hr hm hp11
    refine ⟨s11, ?_, hp11, by rw [hr, v_a4], by rw [hr, v_a5], by rw [hr, v_a6], by rw [hr, v_a3],
      by rw [hm, v_mem], fun r a b c d e => by rw [hr, regs10 r a b c d e]⟩
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7
      (run_cons e8 (run_cons e9 (run_cons e10 e11)))))))))
  by_cases hl : k + 1 < 32
  · have e11 : run env 1 s10 = .running (s10.setPc (s10.pc + ((0xfec : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := prog) (hlen := hP.hlen) hp 32 (hP.lt (by decide)) hc10 p10 (i := .br .bne A4 A6 0xfec) (hP.at (by decide) (by decide))
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p10]
    rw [BitVec.add_assoc]
    congr 1
  · have e11 : run env 1 s10 = .running s10.next :=
      (stepK (prog := prog) (hlen := hP.hlen) hp 32 (hP.lt (by decide)) hc10 p10 (i := .br .bne A4 A6 0xfec) (hP.at (by decide) (by decide))
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p10]
    exact pc_next fit 32 (by decide)

/-- Setup, the zero half of the HASH buffer, and the four instructions that
start the digit pass: the invariant for `k = 0`, over the memory setup left. -/
theorem front {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base prog) :
    ∃ s', run env 22 s = .running s'
      ∧ DInv base s.mem (overlay s.mem (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0)) s' 0 s'
      ∧ Regs base s' ∧ s'.reg S1 = base + BitVec.ofNat 32 SIG ∧ s'.reg S2 = base + BitVec.ofNat 32 KEY
      ∧ s'.reg S6 = 0 := by
  have fit := hp.fit
  obtain ⟨s10, e10, p10, m10, rg, h1, h2, h6⟩ := setup_regs hP hp s hpc hcode
  obtain ⟨s18, e8, p18, m18, r18⟩ := (zero_words (prog := prog) hp (k0 := 10) (rd := S5) (o := 32)
    (a := SCR) hP.at_zero (by have := hP.long; omega) (by decide) (by decide) (by decide)
    (by have := hP.below; simp only [SCR]; omega) p10
    (by rw [m10]; exact hcode) rg.s5 hP.hlen) 8 (Nat.le_refl _)
  have hc18 : CodeAt s18.mem base prog := by
    rw [m18, m10]; exact code_of_overlay fit hcode (by have := hP.below; simp only [SCR]; omega) (by decide) _
  obtain ⟨s19, e19, p19, m19, r19⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 18 (hP.lt (by decide)) hc18 p18
    (i := .opi .addi A4 S3 0) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s20, e20, p20, m20, r20⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 19 (hP.lt (by decide)) (by rw [m19]; exact hc18) p19
    (i := .opi .addi A5 S5 64) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s21, e21, p21, m21, r21⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 20 (hP.lt (by decide)) (by rw [m20, m19]; exact hc18) p20
    (i := .opi .addi A6 S3 32) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s22, e22, p22, m22, r22⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 21 (hP.lt (by decide))
    (by rw [m21, m20, m19]; exact hc18) p21 (i := .opi .addi A3 0 0) (hP.at (by decide) (by decide)) rfl
  have kept : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ A6 → s22.reg r = s10.reg r := by
    intro r a b c d
    rw [reg_kept r22 a, reg_kept r21 d, reg_kept r20 c, reg_kept r19 b, r18]
  have s3_18 : s18.reg S3 = base + BitVec.ofNat 32 MSG := by rw [r18, rg.s3]
  have s5_18 : s18.reg S5 = base + BitVec.ofNat 32 SCR := by rw [r18, rg.s5]
  refine ⟨s22, ?_, ⟨by rw [p22]; rfl, ?_, ?_, ?_, ?_, ?_, fun r _ _ _ _ _ => rfl⟩,
    ⟨by rw [kept _ (by decide) (by decide) (by decide) (by decide), rg.s0],
     by rw [kept _ (by decide) (by decide) (by decide) (by decide), rg.s3],
     by rw [kept _ (by decide) (by decide) (by decide) (by decide), rg.s5]⟩,
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h1],
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h2],
    by rw [kept _ (by decide) (by decide) (by decide) (by decide), h6]⟩
  · rw [show 22 = 10 + (8 + (1 + (1 + (1 + 1)))) by rfl, run_add_running e10, run_add_running e8]
    exact run_cons e19 (run_cons e20 (run_cons e21 e22))
  · rw [reg_kept r22 (by decide), reg_kept r21 (by decide), reg_kept r20 (by decide), reg_wrote r19 (by decide),
      s3_18]
    simp only [aluI]; rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [reg_kept r22 (by decide), reg_kept r21 (by decide), reg_wrote r20 (by decide), reg_kept r19 (by decide),
      s5_18]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [reg_kept r22 (by decide), reg_wrote r21 (by decide), reg_kept r20 (by decide), reg_kept r19 (by decide),
      s3_18]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
      off_add fit _ _ (by simp only [MSG]; omega)]
  · rw [reg_wrote r22 (by decide), show csumTo s.mem base (2 * 0) = 0 by simp [csumTo]]
    simp only [aluI, reg_zero]; decide
  · rw [m22, m21, m20, m19, m18, m10, overlay_zero]

/-- 32 iterations, by induction: after `j` of them, the invariant holds for `j`. -/
theorem digits_loop {env : Env} {base : Word} (hp : Placed env base) {m0 M : Word → Byte}
    (hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M) (hc : CodeAt M base prog) {R : Machine}
    {s : Machine} (h : DInv base m0 M R 0 s) :
    ∀ j ≤ 32, ∃ s', run env (11 * j) s = .running s' ∧ DInv base m0 M R j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := digit_iter hP hp hM hc (by omega) hs'
    exact ⟨s'', by rw [show 11 * (j + 1) = 11 * j + 11 by omega, run_add_running e, e'], hs''⟩

/-- Seven instructions for the checksum's digits, six to start the chains:
from the end of the digit pass to the invariant for chain 0. -/
theorem middle {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte} {R s : Machine}
    (hc0 : CodeAt m0 base prog)
    (h : DInv base m0 (overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0)) R 32 s)
    (hR : Regs base R) (h1 : R.reg S1 = base + BitVec.ofNat 32 SIG) :
    ∃ s', run env 13 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 46) ∧ Chains base m0 m0 0 s'
      ∧ ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → r ≠ S7 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 →
          s'.reg r = R.reg r := by
  have fit := hp.fit
  generalize hMdef : overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0) = M at h
  have hM : Keeps (base + BitVec.ofNat 32 SCR) 131 m0 M := by
    rw [← hMdef]; exact keeps_overlay fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega)
  have hcM : CodeAt M base prog := hM.code fit (by simp only [SCR]; omega) (by have := hP.below; simp only [SCR]; omega) hc0
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 33) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base prog := by
    rw [h.mem]; exact code_of_overlay fit hcM (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  have hcl := csumTo_le m0 base 64
  generalize hcdef : csumTo m0 base 64 = c at hcl
  have a3 : s.reg A3 = BitVec.ofNat 32 c := by rw [h.a3, ← hcdef]
  have a5 : s.reg A5 = base + BitVec.ofNat 32 (SCR + 64 + 64) := h.a5
  -- andi t1, a3, 15; sb t1, 0(a5)
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 33 (hP.lt (by decide)) hcode hpc
    (i := .opi .andi T1 A3 15) (hP.at (by decide) (by decide)) rfl
  have v1 : s1.reg T1 = BitVec.ofNat 32 (c % 16) := by
    rw [reg_wrote r1 (by decide)]; simp only [aluI]; rw [a3]; exact and15 c (by omega)
  obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep (prog := prog) (hlen := hP.hlen) hp 34 (hP.lt (by decide)) (by rw [m1]; exact hcode) p1
    (rs1 := A5) (rs2 := T1) (imm := 0) (hP.at (by decide) (by decide)) (SCR + 64 + 64)
    (by rw [reg_kept r1 (by decide), a5, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]
        exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  have hc2 : CodeAt s2.mem base prog := by
    rw [m2]; exact code_of_writeByte fit (by rw [m1]; exact hcode) (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  -- srli t1, a3, 4; andi t1, t1, 15; sb t1, 1(a5)
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 35 (hP.lt (by decide)) hc2 p2
    (i := .sh .srli T1 A3 4) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 36 (hP.lt (by decide)) (by rw [m3]; exact hc2) p3
    (i := .opi .andi T1 T1 15) (hP.at (by decide) (by decide)) rfl
  have v4 : s4.reg T1 = BitVec.ofNat 32 (c / 16 % 16) := by
    rw [reg_wrote r4 (by decide)]; simp only [aluI]
    rw [reg_wrote r3 (by decide)]; simp only [shiftI]
    rw [r2, reg_kept r1 (by decide), a3, show ((4 : BitVec 5)).toNat = 4 from rfl, shr c 4 (by omega)]
    exact and15 _ (by omega)
  obtain ⟨s5, e5, p5, m5, r5⟩ := sbStep (prog := prog) (hlen := hP.hlen) hp 37 (hP.lt (by decide)) (by rw [m4, m3]; exact hc2) p4
    (rs1 := A5) (rs2 := T1) (imm := 1) (hP.at (by decide) (by decide)) (SCR + 64 + 65)
    (by rw [reg_kept r4 (by decide), reg_kept r3 (by decide), r2, reg_kept r1 (by decide), a5,
          show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
          off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc5 : CodeAt s5.mem base prog := by
    rw [m5]; exact code_of_writeByte fit (by rw [m4, m3]; exact hc2) (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  -- srli t1, a3, 8; sb t1, 2(a5)
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 38 (hP.lt (by decide)) hc5 p5
    (i := .sh .srli T1 A3 8) (hP.at (by decide) (by decide)) rfl
  have v6 : s6.reg T1 = BitVec.ofNat 32 (c / 256) := by
    rw [reg_wrote r6 (by decide)]; simp only [shiftI]
    rw [r5, reg_kept r4 (by decide), reg_kept r3 (by decide), r2, reg_kept r1 (by decide), a3]
    exact shr c 8 (by omega)
  obtain ⟨s7, e7, p7, m7, r7⟩ := sbStep (prog := prog) (hlen := hP.hlen) hp 39 (hP.lt (by decide)) (by rw [m6]; exact hc5) p6
    (rs1 := A5) (rs2 := T1) (imm := 2) (hP.at (by decide) (by decide)) (SCR + 64 + 66)
    (by rw [reg_kept r6 (by decide), r5, reg_kept r4 (by decide), reg_kept r3 (by decide), r2,
          reg_kept r1 (by decide), a5, show BitVec.signExtend 32 (2 : BitVec 12) = BitVec.ofNat 32 2 by decide,
          off_add fit _ _ (by simp only [SCR]; omega)])
    (by simp only [SCR]; omega)
  have hc7 : CodeAt s7.mem base prog := by
    rw [m7]; exact code_of_writeByte fit (by rw [m6]; exact hc5) (by have := hP.below; simp only [SCR]; omega) (by simp only [SCR]; omega) _
  have mem7 : s7.mem = overlay M (base + BitVec.ofNat 32 (SCR + 64)) 67 (dg m0 base) := by
    rw [m7, m6, m5, m4, m3, m2, m1, h.mem, v1, v4, v6]
    rw [← off_add fit (SCR + 64) (2 * 32) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [show 2 * 32 = 64 + 0 by rfl, digit_ck, hcdef, Nat.pow_zero, Nat.div_one]),
      show SCR + 64 + 65 = (SCR + 64) + (2 * 32 + 1) by rfl,
      ← off_add fit (SCR + 64) (2 * 32 + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]; rw [show 2 * 32 + 1 = 64 + 1 by rfl, digit_ck, hcdef, Nat.pow_one]),
      show SCR + 64 + 66 = (SCR + 64) + (2 * 32 + 1 + 1) by rfl,
      ← off_add fit (SCR + 64) (2 * 32 + 1 + 1) (by simp only [SCR]; omega),
      overlay_byte (by rw [toNat_off fit _ (by simp only [SCR]; omega)]; simp only [SCR]; omega)
        (by rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
            simp only [dg]
            rw [show 2 * 32 + 1 + 1 = 64 + 2 by rfl, digit_ck, hcdef, show (16 : Nat) ^ 2 = 256 by rfl,
              Nat.mod_eq_of_lt (show c / 256 < 16 by omega)])]
  have k7 : ∀ r, r ≠ T1 → s7.reg r = s.reg r := by
    intro r hr; rw [r7, reg_kept r6 hr, r5, reg_kept r4 hr, reg_kept r3 hr, r2, reg_kept r1 hr]
  have fromR : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → s7.reg r = R.reg r :=
    fun r a b c d e => (k7 r d).trans (h.regs r a b c d e)
  have s5_7 : s7.reg S5 = base + BitVec.ofNat 32 SCR := by
    rw [fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), hR.s5]
  -- the chains' registers
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 40 (hP.lt (by decide)) hc7 p7
    (i := .opi .addi A4 S5 64) (hP.at (by decide) (by decide)) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 41 (hP.lt (by decide)) (by rw [n1]; exact hc7) q1
    (i := .opi .addi S7 S5 131) (hP.at (by decide) (by decide)) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 42 (hP.lt (by decide)) (by rw [n2, n1]; exact hc7) q2
    (i := .opi .addi T0 0 0) (hP.at (by decide) (by decide)) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 43 (hP.lt (by decide)) (by rw [n3, n2, n1]; exact hc7) q3
    (i := .opi .addi A0 S5 0) (hP.at (by decide) (by decide)) rfl
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 44 (hP.lt (by decide))
    (by rw [n4, n3, n2, n1]; exact hc7) q4 (i := .opi .addi A1 0 64) (hP.at (by decide) (by decide)) rfl
  obtain ⟨t6, f6, q6, n6, u6⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 45 (hP.lt (by decide))
    (by rw [n5, n4, n3, n2, n1]; exact hc7) q5 (i := .opi .addi A2 S5 0) (hP.at (by decide) (by decide)) rfl
  have k6 : ∀ r, r ≠ A4 → r ≠ S7 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 → t6.reg r = s7.reg r := by
    intro r a b c d e f
    rw [reg_kept u6 f, reg_kept u5 e, reg_kept u4 d, reg_kept u3 c, reg_kept u2 b, reg_kept u1 a]
  have mem6 : t6.mem = s7.mem := by rw [n6, n5, n4, n3, n2, n1]
  have mM : M = overlay m0 (base + BitVec.ofNat 32 (SCR + 32)) 32 (fun _ => 0) := hMdef.symm
  refine ⟨t6, ?_, q6, ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩
  · rw [show 13 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + 1))))))))))) by rfl]
    exact run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 (run_cons e7
      (run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 f6)))))))))))
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      fromR _ (by decide) (by decide) (by decide) (by decide) (by decide), h1]; rfl
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_wrote u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (64 : BitVec 12) = BitVec.ofNat 32 64 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [k6 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s5_7]
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_wrote u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (131 : BitVec 12) = BitVec.ofNat 32 131 by decide,
      off_add fit _ _ (by simp only [SCR]; omega)]
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_wrote u3 (by decide)]
    simp only [aluI, reg_zero]; decide
  · rw [reg_kept u6 (by decide), reg_kept u5 (by decide), reg_wrote u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [reg_kept u6 (by decide), reg_wrote u5 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_wrote u6 (by decide), reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide),
      reg_kept u2 (by decide), reg_kept u1 (by decide), s5_7]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]; exact BitVec.add_zero _
  · rw [mem6, mem7]
    exact hM.trans (keeps_overlay fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
  · intro d hd
    rw [mem6, mem7, overlay_off_out fit _ _ (by simp only [SCR]; omega) (by simp only [SCR]; omega)
      (by left; simp only [SCR]; omega), mM, overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega)
      (by omega)]
  · intro d hd
    rw [mem6, mem7, overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega) (by omega),
      show SCR + 64 + d - (SCR + 64) = d by omega]
  · intro r a b c d e f g h' i' j'
    rw [k6 r b f g h' i' j', fromR r a b c d e]

end

section
variable {prog : List Instr} (hP : Starts 69 prog)
include hP

/-- Sixteen instructions copy chain `i`'s value into the buffer; three more
load its digit `d` and leave `t3 = 15 - d`. -/
theorem fetch {env : Env} {base : Word} (hp : Placed env base) {M m0 : Word → Byte}
    (hc0 : CodeAt M base prog) {i : Nat} (hi : i < 67) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * 46)) (h : Chains base M m0 i s) :
    ∃ s', run env 19 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 65)
      ∧ s'.reg T3 = BitVec.ofNat 32 (15 - digit m0 base i)
      ∧ readBytes s'.mem (base + BitVec.ofNat 32 SCR) 32 = sigAt M base i
      ∧ Keeps (base + BitVec.ofNat 32 SCR) 131 M s'.mem
      ∧ (∀ d < 32, s'.mem (base + BitVec.ofNat 32 (SCR + 32 + d)) = 0)
      ∧ (∀ d < 67, s'.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d)
      ∧ ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → s'.reg r = s.reg r := by
  have fit := hp.fit
  have hcode : CodeAt s.mem base prog :=
    h.out.code fit (by simp only [SCR]; omega) (by have := hP.below; simp only [SCR]; omega) hc0
  obtain ⟨sc, ec, pc_, mc, rc⟩ := (copy_words (prog := prog) hp (k0 := 46) (rs := S1) (rd := S5) (t := T4)
    (src := SIG + 32 * i) (dst := SCR) hP.at_copy (by have := hP.long; omega) (by decide) (by decide) (by decide)
    (by simp only [SIG]; omega) (by decide) (by simp only [SIG]; omega) (by decide)
    (by have := hP.below; simp only [SCR]; omega)
    (by simp only [SIG, SCR]; omega) hpc hcode h.s1 h.s5 hP.hlen) 8 (Nat.le_refl _)
  have hcc : CodeAt sc.mem base prog := by
    rw [mc]; exact code_of_overlay fit hcode (by have := hP.below; simp only [SCR]; omega) (by decide) _
  have hdig : ∀ d < 67, sc.mem (base + BitVec.ofNat 32 (SCR + 64 + d)) = dg m0 base d := by
    intro d hd; rw [mc, above_buffer fit _ _ _ (by omega) (by simp only [SCR]; omega)]; exact h.dig d hd
  -- lbu t3, 0(a4); addi t2, x0, 15; sub t3, t2, t3
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := prog) (hlen := hP.hlen) hp 62 (hP.lt (by decide)) hcc (by rw [pc_]) (rd := T3) (rs1 := A4)
    (imm := 0) (hP.at (by decide) (by decide)) (SCR + 64 + i)
    (by rw [rc _ (by decide), h.a4, show BitVec.signExtend 32 (0 : BitVec 12) = 0 by decide]
        exact BitVec.add_zero _)
    (by simp only [SCR]; omega)
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 63 (hP.lt (by decide)) (by rw [m1]; exact hcc) p1
    (i := .opi .addi T2 0 15) (hP.at (by decide) (by decide)) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 64 (hP.lt (by decide)) (by rw [m2, m1]; exact hcc) p2
    (i := .op .sub T3 T2 T3) (hP.at (by decide) (by decide)) rfl
  have hd := digit_lt m0 base i
  have mm : s3.mem = overlay s.mem (base + BitVec.ofNat 32 SCR) (4 * 8)
      (fun d => s.mem (base + BitVec.ofNat 32 (SIG + 32 * i + d))) := by rw [m3, m2, m1, mc]
  refine ⟨s3, ?_, p3, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [show 19 = 16 + (1 + (1 + 1)) by rfl, run_add_running ec]; exact run_cons e1 (run_cons e2 e3)
  · rw [reg_wrote r3 (by decide), reg_wrote r2 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
      hdig i hi]
    simp only [aluR, aluI, reg_zero, dg]
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_sub, BitVec.toNat_add, BitVec.toNat_ofNat]
    rw [Nat.mod_eq_of_lt (show digit m0 base i < 2 ^ 8 by omega), Nat.mod_eq_of_lt (show digit m0 base i < 2 ^ 32 by omega)]
    have : ((BitVec.toNat (0 : Word) + (BitVec.signExtend 32 (15 : BitVec 12)).toNat) % 2 ^ 32) = 15 := by decide
    rw [this, show 2 ^ 32 - digit m0 base i + 15 = (15 - digit m0 base i) + 2 ^ 32 by omega, Nat.add_mod_right,
      Nat.mod_eq_of_lt (by omega)]
  · rw [mm]; unfold sigAt
    apply readBytes_shift
    intro d hd'
    rw [off_add fit _ _ (by simp only [SCR]; omega), overlay_off_in fit _ _ (by simp only [SCR]; omega) (by omega)
      (by omega), off_add fit _ _ (by simp only [SIG]; omega), show SCR + d - SCR = d by omega]
    exact h.out.off fit (by simp only [SCR]; omega) (by simp only [SIG]; omega) (by left; simp only [SIG, SCR]; omega)
  · rw [mm]; exact h.out.trans (keeps_overlay fit _ _ (by omega) (by omega) (by simp only [SCR]; omega))
  · intro d hd'
    rw [mm, above_buffer fit _ _ _ (by omega) (by simp only [SCR]; omega)]; exact h.tail d hd'
  · intro d hd'; rw [m3, m2, m1]; exact hdig d hd'
  · intro r a b c
    rw [reg_kept r3 b, reg_kept r2 c, reg_kept r1 b, rc r a]

/-- The walk, `n` rounds of `ecall; addi t3, t3, -1; bne t3, x0`: `n` more
steps along the chain, in exactly `3n` instructions. -/
theorem walk_chain {env : Env} {base : Word} (hp : Placed env base) {M m0 : Word → Byte}
    (hc0 : CodeAt M base prog) {x : List Byte} :
    ∀ n, 0 < n → n < 16 → ∀ (j : Nat) (s : Machine), s.pc = base + BitVec.ofNat 32 (4 * 66) →
      s.reg T3 = BitVec.ofNat 32 n → s.reg T0 = 0 → s.reg A0 = base + BitVec.ofNat 32 SCR →
      s.reg A1 = BitVec.ofNat 32 64 → s.reg A2 = base + BitVec.ofNat 32 SCR → WInv env.hash base M m0 x j s →
      ∃ s', run env (3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 69)
        ∧ WInv env.hash base M m0 x (j + n) s' ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro _ hn j s hpc h3 h0 ha0 ha1 ha2 hw
    have hcode : CodeAt s.mem base prog := hw.out.code fit (by simp only [SCR]; omega) (by have := hP.below; simp only [SCR]; omega) hc0
    have hexec := exec_hash (env := env) (s := s) h0 (by rw [ha1]; rfl)
      (by rw [ha0]; exact align_off hp.align fit _ (by decide) (by decide))
      (by rw [ha2]; exact align_off hp.align fit _ (by decide) (by decide))
      (by rw [ha0, ha1]; exact ok_off hp _ _ (by decide) (by decide))
      (by rw [ha2]; exact ok_off hp _ _ (by decide) (by decide))
    obtain ⟨s1, e1, hs1⟩ : ∃ s1, run env 1 s = .running s1 ∧
        s1 = ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next :=
      ⟨_, (stepK (prog := prog) (hlen := hP.hlen) hp 66 (hP.lt (by decide)) hcode hpc (i := .ecall) (hP.at (by decide) (by decide)) hexec 0).trans
        (run_zero _ _), rfl⟩
    have mem1 : s1.mem = hashedMem env.hash base s.mem := by
      rw [hs1, next_mem, ha0, ha2, ha1, show (BitVec.ofNat 32 64).toNat = 64 from rfl]; rfl
    have hw1 : WInv env.hash base M m0 x (j + 1) s1 := by
      obtain ⟨a, b, c, d⟩ := hash_in_place (s := s) fit hw
      exact ⟨by rw [mem1]; exact a, by rw [mem1]; exact b, by rw [mem1]; exact c, by rw [mem1]; exact d⟩
    have p1 : s1.pc = base + BitVec.ofNat 32 (4 * 67) := by
      rw [hs1]; simp only [next_pc]; rw [hpc]; exact pc_next fit 66 (by decide)
    have k1 : ∀ r, s1.reg r = s.reg r := fun r => by rw [hs1]; rfl
    have hc1 : CodeAt s1.mem base prog := hw1.out.code fit (by simp only [SCR]; omega) (by have := hP.below; simp only [SCR]; omega) hc0
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := prog) (hlen := hP.hlen) hp 67 (hP.lt (by decide)) hc1 p1
      (i := .opi .addi T3 T3 0xfff) (hP.at (by decide) (by decide)) rfl
    have v2 : s2.reg T3 = BitVec.ofNat 32 n := by
      rw [reg_wrote r2 (by decide), k1, h3]; simp only [aluI]; exact dec_one n (by omega)
    have hw2 : WInv env.hash base M m0 x (j + 1) s2 := by
      obtain ⟨a, b, c, d⟩ := hw1; exact ⟨by rw [m2]; exact a, by rw [m2]; exact b, by rw [m2]; exact c, by rw [m2]; exact d⟩
    have k2 : ∀ r, r ≠ T3 → s2.reg r = s.reg r := fun r hr => by rw [reg_kept r2 hr, k1]
    have hc2 : CodeAt s2.mem base prog := by rw [m2]; exact hc1
    by_cases hz : n = 0
    · -- the last round: fall through to the compare
      subst hz
      have e3 : run env 1 s2 = .running s2.next :=
        (stepK (prog := prog) (hlen := hP.hlen) hp 68 (hP.lt (by decide)) hc2 p2 (i := .br .bne T3 0 0xffc) (hP.at (by decide) (by decide))
          (exec_br_not (by rw [v2]; simp [taken])) 0).trans (run_zero _ _)
      refine ⟨s2.next, ?_, by simp only [next_pc, p2]; exact pc_next fit 68 (by decide), ?_, ?_⟩
      · exact run_cons e1 (run_cons e2 e3)
      · obtain ⟨a, b, c, d⟩ := hw2
        exact ⟨by rw [next_mem]; exact a, by rw [next_mem]; exact b, by rw [next_mem]; exact c,
          by rw [next_mem]; exact d⟩
      · intro r hr; rw [next_reg, k2 r hr]
    · have hne : BitVec.ofNat 32 n ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz this
      have e3 : run env 1 s2 = .running (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32)) :=
        (stepK (prog := prog) (hlen := hP.hlen) hp 68 (hP.lt (by decide)) hc2 p2 (i := .br .bne T3 0 0xffc) (hP.at (by decide) (by decide))
          (exec_br_taken (by rw [v2]; simp only [taken, bne_iff_ne, ne_eq]; exact hne)) 0).trans (run_zero _ _)
      obtain ⟨s', e', p', w', k'⟩ := ih (by omega) (by omega) (j + 1)
        (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32))
        (by simp only [setPc_pc, p2]; rw [BitVec.add_assoc]; congr 1)
        (by rw [setPc_reg, v2]) (by rw [setPc_reg, k2 _ (by decide), h0])
        (by rw [setPc_reg, k2 _ (by decide), ha0]) (by rw [setPc_reg, k2 _ (by decide), ha1])
        (by rw [setPc_reg, k2 _ (by decide), ha2])
        (by obtain ⟨a, b, c, d⟩ := hw2
            exact ⟨by rw [setPc_mem]; exact a, by rw [setPc_mem]; exact b, by rw [setPc_mem]; exact c,
              by rw [setPc_mem]; exact d⟩)
      refine ⟨s', ?_, p', by rw [show j + (n + 1) = j + 1 + n by omega]; exact w', ?_⟩
      · have := run_cons e1 (run_cons e2 (run_cons e3 e'))
        rwa [show 3 * n + 1 + 1 + 1 = 3 * (n + 1) by omega] at this
      · intro r hr; rw [k' r hr, setPc_reg, k2 r hr]

/-- `beq t3, x0` and the walk: when the digit is 15 nothing is hashed and
the branch goes straight to the compare; otherwise `15 - d` rounds. Either
way, `1 + 3n` instructions. -/
theorem skip_or_walk {env : Env} {base : Word} (hp : Placed env base) {M m0 : Word → Byte}
    (hc0 : CodeAt M base prog) {x : List Byte} (n : Nat) (hn : n < 16) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * 65)) (h3 : s.reg T3 = BitVec.ofNat 32 n) (h0 : s.reg T0 = 0)
    (ha0 : s.reg A0 = base + BitVec.ofNat 32 SCR) (ha1 : s.reg A1 = BitVec.ofNat 32 64)
    (ha2 : s.reg A2 = base + BitVec.ofNat 32 SCR) (hw : WInv env.hash base M m0 x 0 s) :
    ∃ s', run env (1 + 3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 69)
      ∧ WInv env.hash base M m0 x n s' ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  have hcode : CodeAt s.mem base prog := hw.out.code fit (by simp only [SCR]; omega) (by have := hP.below; simp only [SCR]; omega) hc0
  by_cases hz : n = 0
  · subst hz
    have e : run env 1 s = .running (s.setPc (s.pc + ((8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := prog) (hlen := hP.hlen) hp 65 (hP.lt (by decide)) hcode hpc (i := .br .beq T3 0 8) (hP.at (by decide) (by decide))
        (exec_br_taken (by rw [h3]; simp [taken])) 0).trans (run_zero _ _)
    refine ⟨_, e, by simp only [setPc_pc, hpc]; rw [BitVec.add_assoc]; congr 1, ?_, fun r _ => setPc_reg _ _ r⟩
    obtain ⟨a, b, c, d⟩ := hw
    exact ⟨by rw [setPc_mem]; exact a, by rw [setPc_mem]; exact b, by rw [setPc_mem]; exact c,
      by rw [setPc_mem]; exact d⟩
  · have hne : BitVec.ofNat 32 n ≠ 0 := by
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz this
    have e : run env 1 s = .running s.next :=
      (stepK (prog := prog) (hlen := hP.hlen) hp 65 (hP.lt (by decide)) hcode hpc (i := .br .beq T3 0 8) (hP.at (by decide) (by decide))
        (exec_br_not (by rw [h3]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact hne)) 0).trans
        (run_zero _ _)
    obtain ⟨s', e', p', w', k'⟩ := walk_chain hP hp hc0 n (by omega) hn 0 s.next
      (by simp only [next_pc, hpc]; exact pc_next fit 65 (by decide))
      (by rw [next_reg, h3]) (by rw [next_reg, h0]) (by rw [next_reg, ha0]) (by rw [next_reg, ha1])
      (by rw [next_reg, ha2])
      (by obtain ⟨a, b, c, d⟩ := hw
          exact ⟨by rw [next_mem]; exact a, by rw [next_mem]; exact b, by rw [next_mem]; exact c,
            by rw [next_mem]; exact d⟩)
    refine ⟨s', ?_, p', by rw [Nat.zero_add] at w'; exact w', fun r hr => by rw [k' r hr, next_reg]⟩
    have := run_cons e e'
    rwa [Nat.add_comm] at this

end

end Rv32.Wots
