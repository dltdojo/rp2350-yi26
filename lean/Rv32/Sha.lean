/-
SPDX-License-Identifier: Apache-2.0

# SHA-256, as a specification and as a kernel

Every kernel on the verified-kernel road calls `HASH`, and every theorem about
them holds for any function `HASH` might be. This is the other half: a kernel
that computes SHA-256 itself, in RV32IM, and the specification it is proved
against (exp208).

The specification is FIPS 180-4 written for proving rather than for running:
32-bit words are `BitVec 32`, rotation is the core library's `rotateRight`,
and every sum is written in the order FIPS 180-4 writes it. It is not
`lean/Sha256.lean` — that one is for `rv32run`, and no theorem mentions it.
This one is part of what the theorem trusts, and exp208 holds it to
`hashlib` by running it.

The kernel computes SHA-256 of a message whose length is a multiple of 64
bytes, as `HASH` is only ever asked to: every block of the message, then one
block of padding it builds itself.
-/
import Rv32.Line
import Rv32.Walk
import Rv32.Frame

set_option maxRecDepth 20000

namespace Rv32.Sha
open Rv32 Rv32.Wots

/-! ## The specification -/

abbrev W32 := BitVec 32

def rotr (x : W32) (n : Nat) : W32 := x.rotateRight n

def bsig0 (a : W32) : W32 := rotr a 2 ^^^ rotr a 13 ^^^ rotr a 22
def bsig1 (e : W32) : W32 := rotr e 6 ^^^ rotr e 11 ^^^ rotr e 25
def ssig0 (x : W32) : W32 := rotr x 7 ^^^ rotr x 18 ^^^ (x >>> 3)
def ssig1 (x : W32) : W32 := rotr x 17 ^^^ rotr x 19 ^^^ (x >>> 10)
def ch (e f g : W32) : W32 := (e &&& f) ^^^ (~~~e &&& g)
def maj (a b c : W32) : W32 := (a &&& b) ^^^ (a &&& c) ^^^ (b &&& c)

def K : List W32 := [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

/-- The initial hash value, H⁽⁰⁾. -/
def IV : List W32 := [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

/-- The working variables a … h. -/
structure St where
  a : W32
  b : W32
  c : W32
  d : W32
  e : W32
  f : W32
  g : W32
  h : W32
  deriving DecidableEq, Repr

def St.ofList (l : List W32) : St :=
  ⟨l.getD 0 0, l.getD 1 0, l.getD 2 0, l.getD 3 0, l.getD 4 0, l.getD 5 0, l.getD 6 0, l.getD 7 0⟩

def St.toList (s : St) : List W32 := [s.a, s.b, s.c, s.d, s.e, s.f, s.g, s.h]

/-- One round, FIPS 180-4 6.2.2 step 3. -/
def round (s : St) (k w : W32) : St :=
  let t1 := s.h + bsig1 s.e + ch s.e s.f s.g + k + w
  let t2 := bsig0 s.a + maj s.a s.b s.c
  ⟨t1 + t2, s.a, s.b, s.c, s.d + t1, s.e, s.f, s.g⟩

/-- Rounds over the constants and the schedule, in order. -/
def rounds (s : St) : List W32 → List W32 → St
  | k :: ks, w :: ws => rounds (round s k w) ks ws
  | _, _ => s

/-- The message schedule, extended by `n` words: word `t` is
σ₁(W[t-2]) + W[t-7] + σ₀(W[t-15]) + W[t-16]. -/
def expand (w : List W32) : Nat → List W32
  | 0 => w
  | n + 1 =>
    let v := expand w n
    let t := v.length
    v ++ [ssig1 (v.getD (t - 2) 0) + v.getD (t - 7) 0 + ssig0 (v.getD (t - 15) 0) + v.getD (t - 16) 0]

/-- A big-endian word from four bytes, the way the kernel assembles it. -/
def beWord (b0 b1 b2 b3 : Byte) : W32 :=
  BitVec.ofNat 32 b0.toNat <<< 24 ||| BitVec.ofNat 32 b1.toNat <<< 16 ||| BitVec.ofNat 32 b2.toNat <<< 8
    ||| BitVec.ofNat 32 b3.toNat

/-- The sixteen words of a 64-byte block. -/
def blockWords (b : List Byte) : List W32 :=
  (List.range 16).map fun j =>
    beWord (b.getD (4 * j) 0) (b.getD (4 * j + 1) 0) (b.getD (4 * j + 2) 0) (b.getD (4 * j + 3) 0)

/-- The compression function: H⁽ⁱ⁾ from H⁽ⁱ⁻¹⁾ and one block. -/
def compress (h : List W32) (block : List Byte) : List W32 :=
  let s := rounds (St.ofList h) K (expand (blockWords block) 48)
  List.zipWith (· + ·) h s.toList

/-- The message padded, FIPS 180-4 5.1.1: a 1 bit, zeros, and the length in
bits as a 64-bit big-endian number, to a multiple of 64 bytes. -/
def pad (msg : List Byte) : List Byte :=
  let bits := 8 * msg.length
  msg ++ [0x80] ++ List.replicate ((55 + 64 - msg.length % 64) % 64) 0
    ++ (List.range 8).map fun i => BitVec.ofNat 8 (bits / 2 ^ (8 * (7 - i)))

/-- The message's blocks, in order. -/
def blocks (m : List Byte) : List (List Byte) :=
  (List.range (m.length / 64)).map fun i => (m.drop (64 * i)).take 64

/-- A word's four bytes, big-endian, the way the kernel stores them. -/
def beBytes (x : W32) : List Byte :=
  [BitVec.ofNat 8 (x >>> 24).toNat, BitVec.ofNat 8 (x >>> 16).toNat, BitVec.ofNat 8 (x >>> 8).toNat,
    BitVec.ofNat 8 x.toNat]

/-- **SHA-256.** -/
def sha256 (msg : List Byte) : List Byte :=
  ((blocks (pad msg)).foldl compress IV).flatMap beBytes

/-! ## The kernel

Where everything is, from `R = base + 0x1000`; the message at `base + 0x2000`.

| | |
| --- | --- |
| `R + 0x000` | K, 64 words, as data |
| `R + 0x100` | IV, 8 words, as data |
| `R + 0x120` | the message's length in bytes, a multiple of 64 |
| `R + 0x140` | the digest, 32 bytes, written |
| `R + 0x200` | H, 8 words |
| `R + 0x300` | W, the schedule, 64 words |
| `R + 0x400` | the padding block, 64 bytes, built |
-/

def A7 : Reg := 17
def S10 : Reg := 26

/-- `R`, the message, H from IV, the padding block, the block count. -/
def setup : List Instr :=
  [ .auipc S0 0, .lui T1 1, .op .add S1 S0 T1, .op .add S4 S1 T1 ] ++
  ((List.range 8).flatMap fun j =>
    [ .ld .lw T0 S1 (BitVec.ofNat 12 (0x100 + 4 * j)), .st .sw S1 T0 (BitVec.ofNat 12 (0x200 + 4 * j)) ]) ++
  (List.range 16).map (fun j => .st .sw S1 0 (BitVec.ofNat 12 (0x400 + 4 * j))) ++
  [ .opi .addi T0 0 0x80, .st .sb S1 T0 0x400,
    .ld .lw T0 S1 0x120, .sh .slli T1 T0 3,
    .sh .srli T2 T1 24, .st .sb S1 T2 0x43c, .sh .srli T2 T1 16, .st .sb S1 T2 0x43d,
    .sh .srli T2 T1 8, .st .sb S1 T2 0x43e, .st .sb S1 T1 0x43f,
    .sh .srli S6 T0 6, .opi .addi S5 0 0 ]

/-- At the last block, the padding instead. -/
def choose : List Instr := [ .br .bne S5 S6 4, .opi .addi S4 S1 0x400 ]

/-- W[0..15]: the block's words, big-endian. -/
def load : List Instr :=
  [ .opi .addi S9 S1 0x300, .opi .addi S8 0 16,
    .ld .lbu T0 S4 0, .sh .slli T0 T0 24, .ld .lbu T1 S4 1, .sh .slli T1 T1 16, .op .or T0 T0 T1,
    .ld .lbu T1 S4 2, .sh .slli T1 T1 8, .op .or T0 T0 T1, .ld .lbu T1 S4 3, .op .or T0 T0 T1,
    .st .sw S9 T0 0, .opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff, .br .bne S8 0 0xfe4 ]

/-- σ₁ of `T0` into `T1`. -/
def ssig1Code : List Instr :=
  [ .sh .srli T1 T0 17, .sh .slli T2 T0 15, .op .or T1 T1 T2, .sh .srli T2 T0 19, .sh .slli T3 T0 13,
    .op .or T2 T2 T3, .op .xor T1 T1 T2, .sh .srli T2 T0 10, .op .xor T1 T1 T2 ]

/-- σ₀ of `T0` into `T2`. -/
def ssig0Code : List Instr :=
  [ .sh .srli T2 T0 7, .sh .slli T3 T0 25, .op .or T2 T2 T3, .sh .srli T3 T0 18, .sh .slli T4 T0 14,
    .op .or T3 T3 T4, .op .xor T2 T2 T3, .sh .srli T3 T0 3, .op .xor T2 T2 T3 ]

/-- W[16..63]. -/
def expandCode : List Instr :=
  [ .opi .addi S8 0 48, .ld .lw T0 S9 0xff8 ] ++ ssig1Code ++
  [ .ld .lw T0 S9 0xfe4, .op .add T1 T1 T0, .ld .lw T0 S9 0xfc4 ] ++ ssig0Code ++
  [ .op .add T1 T1 T2, .ld .lw T0 S9 0xfc0, .op .add T1 T1 T0, .st .sw S9 T1 0,
    .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff, .br .bne S8 0 0xfc8 ]

/-- a … h from H, into a0 … a7. -/
def loadState : List Instr :=
  (List.range 8).map fun j => .ld .lw (BitVec.ofNat 5 (10 + j)) S1 (BitVec.ofNat 12 (0x200 + 4 * j))

/-- Σ₁(e) into `T0`. -/
def bsig1Code : List Instr :=
  [ .sh .srli T0 A4 6, .sh .slli T1 A4 26, .op .or T0 T0 T1, .sh .srli T1 A4 11, .sh .slli T2 A4 21,
    .op .or T1 T1 T2, .op .xor T0 T0 T1, .sh .srli T1 A4 25, .sh .slli T2 A4 7, .op .or T1 T1 T2,
    .op .xor T0 T0 T1 ]

/-- Σ₀(a) into `T1`. -/
def bsig0Code : List Instr :=
  [ .sh .srli T1 A0 2, .sh .slli T2 A0 30, .op .or T1 T1 T2, .sh .srli T2 A0 13, .sh .slli T3 A0 19,
    .op .or T2 T2 T3, .op .xor T1 T1 T2, .sh .srli T2 A0 22, .sh .slli T3 A0 10, .op .or T2 T2 T3,
    .op .xor T1 T1 T2 ]

/-- One round: t₁ into `T0`, t₂ into `T1`, then a … h move down. -/
def roundBody : List Instr :=
  bsig1Code ++
  [ .op .and T1 A4 A5, .opi .xori T2 A4 0xfff, .op .and T2 T2 A6, .op .xor T1 T1 T2,
    .op .add T0 A7 T0, .op .add T0 T0 T1, .ld .lw T1 S10 0, .op .add T0 T0 T1,
    .ld .lw T1 S9 0, .op .add T0 T0 T1 ] ++
  bsig0Code ++
  [ .op .and T2 A0 A1, .op .and T3 A0 A2, .op .xor T2 T2 T3, .op .and T3 A1 A2, .op .xor T2 T2 T3,
    .op .add T1 T1 T2,
    .opi .addi A7 A6 0, .opi .addi A6 A5 0, .opi .addi A5 A4 0, .op .add A4 A3 T0,
    .opi .addi A3 A2 0, .opi .addi A2 A1 0, .opi .addi A1 A0 0, .op .add A0 T0 T1 ]

/-- The 64 rounds. -/
def roundsCode : List Instr :=
  [ .opi .addi S9 S1 0x300, .opi .addi S10 S1 0, .opi .addi S8 0 64 ] ++ roundBody ++
  [ .opi .addi S9 S9 4, .opi .addi S10 S10 4, .opi .addi S8 S8 0xfff, .br .bne S8 0 0xf9e ]

/-- H += a … h. -/
def addBack : List Instr :=
  (List.range 8).flatMap fun j =>
    [ .ld .lw T0 S1 (BitVec.ofNat 12 (0x200 + 4 * j)), .op .add T0 T0 (BitVec.ofNat 5 (10 + j)),
      .st .sw S1 T0 (BitVec.ofNat 12 (0x200 + 4 * j)) ]

/-- The next block, while there is one: the message's, then the padding. -/
def next : List Instr := [ .opi .addi S5 S5 1, .br .bge S6 S5 0xef2 ]

/-- The digest, big-endian, then HALT with 0. -/
def output : List Instr :=
  ((List.range 8).flatMap fun j =>
    [ .ld .lw T0 S1 (BitVec.ofNat 12 (0x200 + 4 * j)),
      .sh .srli T1 T0 24, .st .sb S1 T1 (BitVec.ofNat 12 (0x140 + 4 * j)),
      .sh .srli T1 T0 16, .st .sb S1 T1 (BitVec.ofNat 12 (0x141 + 4 * j)),
      .sh .srli T1 T0 8, .st .sb S1 T1 (BitVec.ofNat 12 (0x142 + 4 * j)),
      .st .sb S1 T0 (BitVec.ofNat 12 (0x143 + 4 * j)) ]) ++
  [ .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  setup ++ choose ++ load ++ expandCode ++ loadState ++ roundsCode ++ addBack ++ next ++ output

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 252 := by rfl

/-! ## The round, as register instructions

The round body is three straight lines of register instructions with the two
loads between them: `seg1` makes t₁ without K[t] and W[t], the loads add
them, `seg3` makes t₂, moves a … h down and steps the counters. -/

def seg1 : List Instr :=
  bsig1Code ++
  [ .op .and T1 A4 A5, .opi .xori T2 A4 0xfff, .op .and T2 T2 A6, .op .xor T1 T1 T2,
    .op .add T0 A7 T0, .op .add T0 T0 T1 ]

def seg3 : List Instr :=
  [ .op .add T0 T0 T1 ] ++ bsig0Code ++
  [ .op .and T2 A0 A1, .op .and T3 A0 A2, .op .xor T2 T2 T3, .op .and T3 A1 A2, .op .xor T2 T2 T3,
    .op .add T1 T1 T2,
    .opi .addi A7 A6 0, .opi .addi A6 A5 0, .opi .addi A5 A4 0, .op .add A4 A3 T0,
    .opi .addi A3 A2 0, .opi .addi A2 A1 0, .opi .addi A1 A0 0, .op .add A0 T0 T1,
    .opi .addi S9 S9 4, .opi .addi S10 S10 4, .opi .addi S8 S8 0xfff ]

theorem roundsCode_eq : roundsCode =
    [ .opi .addi S9 S1 0x300, .opi .addi S10 S1 0, .opi .addi S8 0 64 ] ++ seg1 ++
    [ .ld .lw T1 S10 0, .op .add T0 T0 T1, .ld .lw T1 S9 0 ] ++ seg3 ++ [ .br .bne S8 0 0xf9e ] := rfl

/-- `xori rd, rs, -1` is `not`: `simp` evaluates the sign extension to all
ones, and this reads that back. -/
theorem xor_ones (x : Word) : x ^^^ 4294967295#32 = ~~~x := by
  rw [show (4294967295#32 : Word) = BitVec.allOnes 32 from rfl, BitVec.xor_allOnes]

theorem seg1_T0 (s : Machine) :
    (s.line seg1).reg T0 = s.reg A7 + bsig1 (s.reg A4) + ch (s.reg A4) (s.reg A5) (s.reg A6) := by
  simp [Machine.line, seg1, bsig1Code, Machine.alu, reg_setReg, T0, T1, T2, A4, A5, A6, A7, aluR, aluI,
    shiftI, bsig1, ch, rotr, BitVec.rotateRight, BitVec.rotateRightAux, xor_ones]


theorem seg1_keeps (s : Machine) (r : Reg) (h0 : r ≠ T0) (h1 : r ≠ T1) (h2 : r ≠ T2) :
    (s.line seg1).reg r = s.reg r := by
  simp [Machine.line, seg1, bsig1Code, Machine.alu, reg_setReg, h0, h1, h2]

/-- What `seg3` leaves, from t₁ less W[t] in `T0` and W[t] in `T1`. -/
theorem seg3_regs (s : Machine) :
    let t1 := s.reg T0 + s.reg T1
    let s' := s.line seg3
    s'.reg A0 = t1 + (bsig0 (s.reg A0) + maj (s.reg A0) (s.reg A1) (s.reg A2)) ∧
    s'.reg A1 = s.reg A0 ∧ s'.reg A2 = s.reg A1 ∧ s'.reg A3 = s.reg A2 ∧
    s'.reg A4 = s.reg A3 + t1 ∧ s'.reg A5 = s.reg A4 ∧ s'.reg A6 = s.reg A5 ∧ s'.reg A7 = s.reg A6 ∧
    s'.reg S9 = s.reg S9 + 4 ∧ s'.reg S10 = s.reg S10 + 4 ∧
    s'.reg S8 = s.reg S8 + (0xfff : BitVec 12).signExtend 32 := by
  simp [Machine.line, seg3, bsig0Code, Machine.alu, reg_setReg, T0, T1, T2, T3, A0, A1, A2, A3, A4, A5, A6,
    A7, S8, S9, S10, aluR, aluI, shiftI, bsig0, maj, rotr, BitVec.rotateRight, BitVec.rotateRightAux]

theorem seg3_keeps (s : Machine) (r : Reg) (h0 : r ≠ T0) (h1 : r ≠ T1) (h2 : r ≠ T2) (h3 : r ≠ T3)
    (ha0 : r ≠ A0) (ha1 : r ≠ A1) (ha2 : r ≠ A2) (ha3 : r ≠ A3) (ha4 : r ≠ A4) (ha5 : r ≠ A5)
    (ha6 : r ≠ A6) (ha7 : r ≠ A7) (h8 : r ≠ S8) (h9 : r ≠ S9) (h10 : r ≠ S10) :
    (s.line seg3).reg r = s.reg r := by
  simp [Machine.line, seg3, bsig0Code, Machine.alu, reg_setReg, h0, h1, h2, h3, ha0, ha1, ha2, ha3, ha4, ha5,
    ha6, ha7, h8, h9, h10]


/-! ## One round, run -/

/-- The word at `a`, as `lw` reads it. -/
def wordAt (m : Word → Byte) (a : Word) : Word := BitVec.ofNat 32 (readLE m a 4)

/-- a … h in a0 … a7. -/
def Holds (s : Machine) (st : St) : Prop :=
  s.reg A0 = st.a ∧ s.reg A1 = st.b ∧ s.reg A2 = st.c ∧ s.reg A3 = st.d ∧
  s.reg A4 = st.e ∧ s.reg A5 = st.f ∧ s.reg A6 = st.g ∧ s.reg A7 = st.h

/-- The rounds loop's counters at the top of round `t`: W[t], K[t], and the
rounds still to go. -/
structure RInv (base : Word) (t : Nat) (s : Machine) : Prop where
  s9 : s.reg S9 = base + BitVec.ofNat 32 (0x1300 + 4 * t)
  s10 : s.reg S10 = base + BitVec.ofNat 32 (0x1000 + 4 * t)
  s8 : s.reg S8 = BitVec.ofNat 32 (64 - t)

theorem line_add_T0 (s : Machine) (r : Reg) :
    (s.line [.op .add T0 T0 T1]).reg r = if r = T0 then s.reg T0 + s.reg T1 else s.reg r := by
  simp only [Machine.line, List.foldl, Machine.alu, next_reg, reg_setReg, aluR]
  by_cases h : r = T0 <;> simp [h, show ¬ (T0 = 0#5) by decide]

theorem ofNat_step (base : Word) (c : Nat) :
    base + BitVec.ofNat 32 c + 4 = base + BitVec.ofNat 32 (c + 4) := by
  rw [BitVec.add_assoc, show (4 : Word) = BitVec.ofNat 32 4 from rfl, BitVec.ofNat_add_ofNat]

/-- **One round**, run: fifty instructions from the top of the loop take a … h
to `round` of them with K[t] and W[t] as memory holds them, step the
counters, and go back to the top — or on, after the 64th. -/
theorem round_step {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 109))
    {st : St} (hst : Holds s st) {t : Nat} (ht : t < 64) (hr : RInv base t s) :
    ∃ s', run env 50 s = .running s' ∧ s'.mem = s.mem ∧
      Holds s' (round st (wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)))
        (wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t)))) ∧
      RInv base (t + 1) s' ∧
      s'.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 109 else 159)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ A3 → r ≠ A4 → r ≠ A5 →
        r ≠ A6 → r ≠ A7 → r ≠ S8 → r ≠ S9 → r ≠ S10 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  -- t₁ without K[t] and W[t]
  have e1 : run env 17 s = .running (s.line seg1) := run_line (prog := kernel) hp seg1 (by decide) 109 s (by decide) (by decide) hcode hpc (by decide)
  have p1 : (s.line seg1).pc = base + BitVec.ofNat 32 (4 * 126) := line_pc_at seg1 hpc (by decide)
  have c1 : CodeAt (s.line seg1).mem base kernel := by rw [line_mem]; exact hcode
  -- K[t]
  obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep (prog := kernel) hp 126 (by decide) c1 p1 (rd := T1) (rs1 := S10)
    (imm := 0) (by decide) (0x1000 + 4 * t)
    (by rw [seg1_keeps s S10 (by decide) (by decide) (by decide), hr.s10]; simp) (by omega) (by omega)
  have c2 : CodeAt s2.mem base kernel := by rw [m2, line_mem]; exact hcode
  -- + K[t]
  have e3 : run env 1 s2 = .running (s2.line [.op .add T0 T0 T1]) :=
    run_line (prog := kernel) hp [.op .add T0 T0 T1] (by decide) 127 s2 (by decide) (by decide) c2 p2
    (by decide)
  have p3 : (s2.line [.op .add T0 T0 T1]).pc = base + BitVec.ofNat 32 (4 * 128) :=
    line_pc_at [.op .add T0 T0 T1] p2 (by decide)
  have c3 : CodeAt (s2.line [.op .add T0 T0 T1]).mem base kernel := by rw [line_mem]; exact c2
  -- W[t]
  obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp 128 (by decide) c3 p3 (rd := T1) (rs1 := S9)
    (imm := 0) (by decide) (0x1300 + 4 * t)
    (by rw [line_add_T0, ifF (by decide), r2, ifF (by decide), seg1_keeps s S9 (by decide) (by decide)
          (by decide), hr.s9]; simp) (by omega) (by omega)
  have mem4 : s4.mem = s.mem := by rw [m4, line_mem, m2, line_mem]
  have c4 : CodeAt s4.mem base kernel := by rw [mem4]; exact hcode
  -- what s4 holds
  have k4 : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → s4.reg r = s.reg r := by
    intro r h0 h1 h2
    rw [r4, ifF (by simp [h1]), line_add_T0, ifF h0, r2, ifF (by simp [h1]), seg1_keeps s r h0 h1 h2]
  have v1 : s4.reg T1 = wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t)) := by
    rw [r4, ifT (by decide), line_mem, m2, line_mem]; rfl
  have v0 : s4.reg T0 = s.reg A7 + bsig1 (s.reg A4) + ch (s.reg A4) (s.reg A5) (s.reg A6)
      + wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) := by
    rw [r4, ifF (by decide), line_add_T0, ifT rfl, r2, ifF (by decide), r2, ifT (by decide),
      seg1_T0, line_mem]; rfl
  -- t₂, a … h down, the counters
  have e5 : run env 29 s4 = .running (s4.line seg3) := run_line (prog := kernel) hp seg3 (by decide) 129 s4 (by decide) (by decide) c4 p4 (by decide)
  have p5 : (s4.line seg3).pc = base + BitVec.ofNat 32 (4 * 158) := line_pc_at seg3 p4 (by decide)
  have c5 : CodeAt (s4.line seg3).mem base kernel := by rw [line_mem]; exact c4
  obtain ⟨g0, g1, g2, g3, g4, g5, g6, g7, g9, g10, g8⟩ := seg3_regs s4
  have k5 := seg3_keeps s4
  have m5 := line_mem s4 seg3
  generalize s4.line seg3 = s5 at e5 p5 c5 g0 g1 g2 g3 g4 g5 g6 g7 g9 g10 g8 k5 m5
  have v8 : s5.reg S8 = BitVec.ofNat 32 (64 - (t + 1)) := by
    rw [g8, k4 _ (by decide) (by decide) (by decide), hr.s8, show 64 - t = 64 - (t + 1) + 1 by omega]
    exact dec_one _ (by omega)
  have ht' : taken .bne (s5.reg S8) (s5.reg 0) = decide (t + 1 < 64) := by
    rw [v8, reg_zero]; simp only [taken]
    by_cases hl : t + 1 < 64
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this
      simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show 64 - (t + 1) = 0 by omega]; rfl
  -- what the branch leaves, whichever way it goes
  have finish : ∀ s6 : Machine, run env 1 s5 = .running s6 → (∀ r, s6.reg r = s5.reg r) → s6.mem = s5.mem →
      s6.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 109 else 159)) →
      ∃ s', run env 50 s = .running s' ∧ s'.mem = s.mem ∧
        Holds s' (round st (wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)))
          (wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t)))) ∧
        RInv base (t + 1) s' ∧
        s'.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 109 else 159)) ∧
        (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ A3 → r ≠ A4 → r ≠ A5 →
          r ≠ A6 → r ≠ A7 → r ≠ S8 → r ≠ S9 → r ≠ S10 → s'.reg r = s.reg r) := by
    intro s6 e6 b6 m6 p6
    obtain ⟨ha, hb, hc, hd, he, hf, hg, hh⟩ := hst
    have ka : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → s4.reg r = s.reg r := k4
    refine ⟨s6, ?_, ?_, ?_, ⟨?_, ?_, ?_⟩, p6, ?_⟩
    · rw [show 50 = 17 + (1 + (1 + (1 + (29 + 1)))) by rfl, run_add_running e1, run_add_running e2,
        run_add_running e3, run_add_running e4, run_add_running e5]
      exact e6
    · rw [m6, m5, mem4]
    · simp only [Holds, round]
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> rw [b6]
      · rw [g0, v0, v1, ka A0 (by decide) (by decide) (by decide), ka A1 (by decide) (by decide) (by decide),
          ka A2 (by decide) (by decide) (by decide), ha, hb, hc, he, hf, hg, hh]
      · rw [g1, ka A0 (by decide) (by decide) (by decide), ha]
      · rw [g2, ka A1 (by decide) (by decide) (by decide), hb]
      · rw [g3, ka A2 (by decide) (by decide) (by decide), hc]
      · rw [g4, v0, v1, ka A3 (by decide) (by decide) (by decide), hd, he, hf, hg, hh]
      · rw [g5, ka A4 (by decide) (by decide) (by decide), he]
      · rw [g6, ka A5 (by decide) (by decide) (by decide), hf]
      · rw [g7, ka A6 (by decide) (by decide) (by decide), hg]
    · rw [b6, g9, ka S9 (by decide) (by decide) (by decide), hr.s9, ofNat_step base _]
      congr 2
    · rw [b6, g10, ka S10 (by decide) (by decide) (by decide), hr.s10, ofNat_step base _]
      congr 2
    · rw [b6, v8]
    · intro r h0 h1 h2 h3 ha0 ha1 ha2 ha3 ha4 ha5 ha6 ha7 h8 h9 h10
      rw [b6, k5 r h0 h1 h2 h3 ha0 ha1 ha2 ha3 ha4 ha5 ha6 ha7 h8 h9 h10, ka r h0 h1 h2]
  by_cases hl : t + 1 < 64
  · have e6 : run env 1 s5 = .running (s5.setPc (s5.pc + ((0xf9e : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 158 (by decide) c5 p5 (i := .br .bne S8 0 0xf9e) (by decide)
        (exec_br_taken (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e6 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p5]
    rw [BitVec.add_assoc]
    congr 1
  · have e6 : run env 1 s5 = .running s5.next :=
      (stepK (prog := kernel) hp 158 (by decide) c5 p5 (i := .br .bne S8 0 0xf9e) (by decide)
        (exec_br_not (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e6 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p5]
    exact pc_next fit 158 (by decide)


/-! ## The 64 rounds -/

/-- The first `j` rounds, with K[t] and W[t] as functions of `t`. -/
def iter (st : St) (kf wf : Nat → W32) : Nat → St
  | 0 => st
  | j + 1 => round (iter st kf wf j) (kf j) (wf j)

theorem rounds_iter (st : St) (kf wf : Nat → W32) (j n : Nat) :
    rounds (iter st kf wf j) ((List.range' j n).map kf) ((List.range' j n).map wf) = iter st kf wf (j + n) := by
  induction n generalizing j with
  | zero => rfl
  | succ n ih =>
    simp only [List.range'_succ, List.map_cons, rounds]
    rw [show round (iter st kf wf j) (kf j) (wf j) = iter st kf wf (j + 1) from rfl, ih (j + 1)]
    congr 1; omega

theorem rounds_eq_iter (st : St) (kf wf : Nat → W32) :
    rounds st ((List.range 64).map kf) ((List.range 64).map wf) = iter st kf wf 64 := by
  rw [List.range_eq_range']
  exact rounds_iter st kf wf 0 64

/-- **The 64 rounds**, run: by induction on rounds done, from the top of the
loop with its counters at round 0. -/
theorem rounds_loop {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 109))
    {st : St} (hst : Holds s st) (hr : RInv base 0 s) :
    ∀ j ≤ 64, ∃ s', run env (50 * j) s = .running s' ∧ s'.mem = s.mem ∧
      Holds s' (iter st (fun t => wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)))
        (fun t => wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t))) j) ∧
      RInv base j s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (if j < 64 then 109 else 159)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ A3 → r ≠ A4 → r ≠ A5 →
        r ≠ A6 → r ≠ A7 → r ≠ S8 → r ≠ S9 → r ≠ S10 → s'.reg r = s.reg r) := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, rfl, hst, hr, by simp [hpc], fun _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, m1, h1, r1, p1, k1⟩ := ih (by omega)
    obtain ⟨s2, e2, m2, h2, r2, p2, k2⟩ :=
      round_step hp (by rw [m1]; exact hcode) (by rw [p1, ifT (by omega)]) h1 (by omega) r1
    refine ⟨s2, ?_, by rw [m2, m1], ?_, r2, p2, ?_⟩
    · rw [show 50 * (j + 1) = 50 * j + 50 by omega, run_add_running e1, e2]
    · rw [m1] at h2; exact h2
    · intro r a b c d e f g h i k l m n o p
      rw [k2 r a b c d e f g h i k l m n o p, k1 r a b c d e f g h i k l m n o p]


/-! ## Words in memory -/

theorem add_sub_left' (a b : Word) : a + b - a = b := by
  rw [BitVec.add_comm a b, BitVec.add_sub_cancel]

/-- A store of four bytes at `c` keeps everything outside them. -/
theorem keeps_writeLE {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {S N c : Nat} (m : Word → Byte)
    (v : Nat) (hc : S ≤ c) (hn : c + 4 ≤ S + N) (hSN : S + N < 0x10000) :
    Keeps (base + BitVec.ofNat 32 S) N m (writeLE m (base + BitVec.ofNat 32 c) v 4) := by
  intro x hx
  rw [writeLE_apply _ _ _ _ (by decide)]
  rw [toNat_sub_off hfit _ S (by omega)] at hx
  have : ¬ (x - (base + BitVec.ofNat 32 c)).toNat < 4 := by
    rw [toNat_sub_off hfit _ c (by omega)]
    have := x.isLt; have := base.isLt
    rw [wrapdist _ _ (by omega) (by omega)] at hx ⊢
    split at hx <;> split <;> omega
  simp only [this, ↓reduceIte]

/-- A word stored, read back where it was stored. -/
theorem wordAt_same (m : Word → Byte) (a : Word) (v : Word) : wordAt (writeLE m a v.toNat 4) a = v := by
  unfold wordAt
  apply BitVec.eq_of_toNat_eq
  have hb : ∀ k : Word, k.toNat < 4 → writeLE m a v.toNat 4 (a + k) = BitVec.ofNat 8 (v.toNat / 256 ^ k.toNat) := by
    intro k hk
    rw [writeLE_apply _ _ _ _ (by decide), add_sub_left']
    simp [hk]
  have h0 := hb 0 (by decide); rw [show a + (0 : Word) = a from BitVec.add_zero a] at h0
  rw [BitVec.toNat_ofNat, readLE_four, h0, hb 1 (by decide), hb 2 (by decide), hb 3 (by decide)]
  simp only [BitVec.toNat_ofNat, show (1 : Word).toNat = 1 from rfl, show (2 : Word).toNat = 2 from rfl,
    show (3 : Word).toNat = 3 from rfl, show (0 : Word).toNat = 0 from rfl]
  have := v.isLt
  omega

/-- A word stored, and a word read four bytes or more away from it. -/
theorem wordAt_other {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c c' : Nat}
    (v : Nat) (hc : c + 4 < 0x10000) (hc' : c' + 4 < 0x10000) (hd : c + 4 ≤ c' ∨ c' + 4 ≤ c) :
    wordAt (writeLE m (base + BitVec.ofNat 32 c) v 4) (base + BitVec.ofNat 32 c') = wordAt m (base + BitVec.ofNat 32 c') := by
  unfold wordAt
  congr 1
  apply readLE_four_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact (keeps_writeLE hfit m v (Nat.le_refl c) (Nat.le_refl _) hc).off hfit hc (by omega) (by omega)


/-! ## Sixteen words in -/

theorem Keeps.symm' {a : Word} {n : Nat} {m m' : Word → Byte} (h : Keeps a n m m') : Keeps a n m' m :=
  fun x hx => (h x hx).symm

/-- The `i`th big-endian word of the 64 bytes at `P`. -/
def bw (base : Word) (m : Word → Byte) (P i : Nat) : W32 :=
  beWord (m (base + BitVec.ofNat 32 (P + 4 * i))) (m (base + BitVec.ofNat 32 (P + 4 * i + 1)))
    (m (base + BitVec.ofNat 32 (P + 4 * i + 2))) (m (base + BitVec.ofNat 32 (P + 4 * i + 3)))

/-- The load loop at the top of word `j`: the block at `P`, W[0..j) written,
nothing else. -/
structure LInv (base : Word) (m0 : Word → Byte) (P j : Nat) (s : Machine) : Prop where
  s4 : s.reg S4 = base + BitVec.ofNat 32 (P + 4 * j)
  s9 : s.reg S9 = base + BitVec.ofNat 32 (0x1300 + 4 * j)
  s8 : s.reg S8 = BitVec.ofNat 32 (16 - j)
  keeps : Keeps (base + BitVec.ofNat 32 0x1300) 64 m0 s.mem
  words : ∀ i < j, wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * i)) = bw base m0 P i

theorem load_line1 (s : Machine) :
    (s.line [.sh .slli T0 T0 24]).reg T0 = s.reg T0 <<< 24 ∧
    ∀ r, r ≠ T0 → (s.line [.sh .slli T0 T0 24]).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, shiftI, T0], fun r h => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h])

theorem load_line2 (s : Machine) (n : BitVec 5) :
    (s.line [.sh .slli T1 T1 n, .op .or T0 T0 T1]).reg T0 = s.reg T0 ||| s.reg T1 <<< n.toNat ∧
    ∀ r, r ≠ T0 → r ≠ T1 → (s.line [.sh .slli T1 T1 n, .op .or T0 T0 T1]).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, shiftI, aluR, T0, T1], fun r h0 h1 => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h0, Ne.symm h1])

theorem load_line3 (s : Machine) :
    (s.line [.op .or T0 T0 T1]).reg T0 = s.reg T0 ||| s.reg T1 ∧
    ∀ r, r ≠ T0 → (s.line [.op .or T0 T0 T1]).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, aluR, T0, T1], fun r h => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h])

theorem load_line4 (s : Machine) :
    let s' := s.line [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]
    s'.reg S4 = s.reg S4 + 4 ∧ s'.reg S9 = s.reg S9 + 4 ∧ s'.reg S8 = s.reg S8 + (0xfff : BitVec 12).signExtend 32 ∧
    ∀ r, r ≠ S4 → r ≠ S9 → r ≠ S8 → s'.reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, aluI, S4, S8, S9],
    by simp [Machine.line, Machine.alu, reg_setReg, aluI, S4, S8, S9],
    by simp [Machine.line, Machine.alu, reg_setReg, aluI, S4, S8, S9], fun r h4 h9 h8 => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h4, Ne.symm h9, Ne.symm h8])


theorem se1 : (1 : BitVec 12).signExtend 32 = 1 := by decide
theorem se2 : (2 : BitVec 12).signExtend 32 = 2 := by decide
theorem se3 : (3 : BitVec 12).signExtend 32 = 3 := by decide

/-- The bne at the bottom of a loop counting `S8` down to zero: taken while
there is more to do. -/
theorem taken_count (n : Nat) (hn : n < 2 ^ 32) :
    taken .bne (BitVec.ofNat 32 n) 0 = decide (0 < n) := by
  simp only [taken]
  by_cases h : 0 < n
  · simp only [h, decide_true, bne_iff_ne, ne_eq]
    intro e; have := congrArg BitVec.toNat e
    rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt hn] at this
    simp at this; omega
  · simp only [h, decide_false, bne_eq_false_iff_eq]
    rw [show n = 0 by omega]; rfl

/-- **One word in**: fifteen instructions from the top of the load loop store
the block's word `j`, big-endian, at W[j]. -/
theorem load_step {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 53))
    {m0 : Word → Byte} {P j : Nat} (hj : j < 16) (hP : 0x1340 ≤ P) (hP2 : P + 64 ≤ 0x10000)
    (h : LInv base m0 P j s) :
    ∃ s', run env 15 s = .running s' ∧ LInv base m0 P (j + 1) s' ∧
      s'.pc = base + BitVec.ofNat 32 (4 * (if j + 1 < 16 then 53 else 68)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ S4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  have byte : ∀ d < 4, s.mem (base + BitVec.ofNat 32 (P + 4 * j + d)) = m0 (base + BitVec.ofNat 32 (P + 4 * j + d)) :=
    fun d hd => h.keeps.off fit (by decide) (by omega) (by omega)
  have a0 : s.reg S4 + (0 : BitVec 12).signExtend 32 = base + BitVec.ofNat 32 (P + 4 * j) := by rw [h.s4]; simp
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep (prog := kernel) hp 53 (by decide) hcode hpc (rd := T0) (rs1 := S4)
    (imm := 0) (by decide) (P + 4 * j) a0 (by omega)
  have c1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  -- slli T0, T0, 24
  have e2 : run env 1 s1 = .running (s1.line [.sh .slli T0 T0 24]) :=
    run_line (prog := kernel) hp [.sh .slli T0 T0 24] (by decide) 54 s1 (by decide) (by decide) c1 p1 (by decide)
  have p2 := line_pc_at [.sh .slli T0 T0 24] p1 (by decide)
  have mm2 := line_mem s1 [.sh .slli T0 T0 24]
  obtain ⟨v2, k2⟩ := load_line1 s1
  generalize s1.line [.sh .slli T0 T0 24] = s2 at e2 p2 mm2 v2 k2
  have c2 : CodeAt s2.mem base kernel := by rw [mm2]; exact c1
  have s4_2 : s2.reg S4 = base + BitVec.ofNat 32 (P + 4 * j) := by
    rw [k2 _ (by decide), r1, ifF (by decide), h.s4]
  -- lbu T1, 1(S4)
  obtain ⟨s3, e3, p3, m3, r3⟩ := lbuStep (prog := kernel) hp 55 (by decide) c2 p2 (rd := T1) (rs1 := S4)
    (imm := 1) (by decide) (P + 4 * j + 1)
    (by rw [s4_2, se1, show (1 : Word) = BitVec.ofNat 32 1 from rfl, off_add fit _ _ (by omega)]) (by omega)
  have c3 : CodeAt s3.mem base kernel := by rw [m3]; exact c2
  -- slli T1, T1, 16; or T0, T0, T1
  have e4 : run env 2 s3 = .running (s3.line [.sh .slli T1 T1 16, .op .or T0 T0 T1]) :=
    run_line (prog := kernel) hp [.sh .slli T1 T1 16, .op .or T0 T0 T1] (by decide) 56 s3 (by decide) (by decide)
      c3 p3 (by decide)
  have p4 := line_pc_at [.sh .slli T1 T1 16, .op .or T0 T0 T1] p3 (by decide)
  have mm4 := line_mem s3 [.sh .slli T1 T1 16, .op .or T0 T0 T1]
  obtain ⟨v4, k4⟩ := load_line2 s3 16
  generalize s3.line [.sh .slli T1 T1 16, .op .or T0 T0 T1] = s4 at e4 p4 mm4 v4 k4
  have c4 : CodeAt s4.mem base kernel := by rw [mm4]; exact c3
  have s4_4 : s4.reg S4 = base + BitVec.ofNat 32 (P + 4 * j) := by
    rw [k4 _ (by decide) (by decide), r3, ifF (by decide), s4_2]
  -- lbu T1, 2(S4)
  obtain ⟨s5, e5, p5, m5, r5⟩ := lbuStep (prog := kernel) hp 58 (by decide) c4 p4 (rd := T1) (rs1 := S4)
    (imm := 2) (by decide) (P + 4 * j + 2)
    (by rw [s4_4, se2, show (2 : Word) = BitVec.ofNat 32 2 from rfl, off_add fit _ _ (by omega)]) (by omega)
  have c5 : CodeAt s5.mem base kernel := by rw [m5]; exact c4
  -- slli T1, T1, 8; or T0, T0, T1
  have e6 : run env 2 s5 = .running (s5.line [.sh .slli T1 T1 8, .op .or T0 T0 T1]) :=
    run_line (prog := kernel) hp [.sh .slli T1 T1 8, .op .or T0 T0 T1] (by decide) 59 s5 (by decide) (by decide)
      c5 p5 (by decide)
  have p6 := line_pc_at [.sh .slli T1 T1 8, .op .or T0 T0 T1] p5 (by decide)
  have mm6 := line_mem s5 [.sh .slli T1 T1 8, .op .or T0 T0 T1]
  obtain ⟨v6, k6⟩ := load_line2 s5 8
  generalize s5.line [.sh .slli T1 T1 8, .op .or T0 T0 T1] = s6 at e6 p6 mm6 v6 k6
  have c6 : CodeAt s6.mem base kernel := by rw [mm6]; exact c5
  have s4_6 : s6.reg S4 = base + BitVec.ofNat 32 (P + 4 * j) := by
    rw [k6 _ (by decide) (by decide), r5, ifF (by decide), s4_4]
  -- lbu T1, 3(S4)
  obtain ⟨s7, e7, p7, m7, r7⟩ := lbuStep (prog := kernel) hp 61 (by decide) c6 p6 (rd := T1) (rs1 := S4)
    (imm := 3) (by decide) (P + 4 * j + 3)
    (by rw [s4_6, se3, show (3 : Word) = BitVec.ofNat 32 3 from rfl, off_add fit _ _ (by omega)]) (by omega)
  have c7 : CodeAt s7.mem base kernel := by rw [m7]; exact c6
  -- or T0, T0, T1
  have e8 : run env 1 s7 = .running (s7.line [.op .or T0 T0 T1]) :=
    run_line (prog := kernel) hp [.op .or T0 T0 T1] (by decide) 62 s7 (by decide) (by decide) c7 p7 (by decide)
  have p8 := line_pc_at [.op .or T0 T0 T1] p7 (by decide)
  have mm8 := line_mem s7 [.op .or T0 T0 T1]
  obtain ⟨v8, k8⟩ := load_line3 s7
  generalize s7.line [.op .or T0 T0 T1] = s8 at e8 p8 mm8 v8 k8
  have c8 : CodeAt s8.mem base kernel := by rw [mm8]; exact c7
  have mem8 : s8.mem = s.mem := by rw [mm8, m7, mm6, m5, mm4, m3, mm2, m1]
  -- the word, put together
  have q7 : s7.reg T0 = s6.reg T0 := by rw [r7, ifF (by decide)]
  have b7 : s7.reg T1 = BitVec.ofNat 32 (s6.mem (base + BitVec.ofNat 32 (P + 4 * j + 3))).toNat := by
    rw [r7, ifT (by decide)]
  have q5 : s5.reg T0 = s4.reg T0 := by rw [r5, ifF (by decide)]
  have b5 : s5.reg T1 = BitVec.ofNat 32 (s4.mem (base + BitVec.ofNat 32 (P + 4 * j + 2))).toNat := by
    rw [r5, ifT (by decide)]
  have q3 : s3.reg T0 = s2.reg T0 := by rw [r3, ifF (by decide)]
  have b3 : s3.reg T1 = BitVec.ofNat 32 (s2.mem (base + BitVec.ofNat 32 (P + 4 * j + 1))).toNat := by
    rw [r3, ifT (by decide)]
  have b1 : s1.reg T0 = BitVec.ofNat 32 (s.mem (base + BitVec.ofNat 32 (P + 4 * j))).toNat := by
    rw [r1, ifT (by decide)]
  have word : s8.reg T0 = bw base m0 P j := by
    rw [v8, q7, b7, v6, q5, b5, v4, q3, b3, v2, b1, mm6, m5, mm4, m3, mm2, m1]
    simp only [bw, beWord]
    rw [byte 1 (by decide), byte 2 (by decide), byte 3 (by decide),
      show P + 4 * j = P + 4 * j + 0 from rfl, byte 0 (by decide)]
    rfl
  have s9_8 : s8.reg S9 = base + BitVec.ofNat 32 (0x1300 + 4 * j) := by
    rw [k8 _ (by decide), r7, ifF (by decide), k6 _ (by decide) (by decide), r5, ifF (by decide),
      k4 _ (by decide) (by decide), r3, ifF (by decide), k2 _ (by decide), r1, ifF (by decide), h.s9]
  -- sw T0, 0(S9)
  obtain ⟨s9, e9, p9, m9, r9⟩ := storeStep (prog := kernel) hp 63 (by decide) c8 p8 (rs1 := S9) (rs2 := T0)
    (imm := 0) (by decide) (0x1300 + 4 * j) (by rw [s9_8]; simp) (by omega) (by omega)
  have c9 : CodeAt s9.mem base kernel := by
    rw [m9]
    exact (keeps_writeLE fit s8.mem _ (Nat.le_refl _) (Nat.le_refl _) (by omega)).code fit (by omega)
      (by rw [kernel_length]; omega) c8
  -- the counters
  have e10 : run env 3 s9 = .running (s9.line [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]) :=
    run_line (prog := kernel) hp [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] (by decide) 64 s9
      (by decide) (by decide) c9 p9 (by decide)
  have p10 := line_pc_at [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] p9 (by decide)
  have mm10 := line_mem s9 [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]
  obtain ⟨g4, g9, g8, k10⟩ := load_line4 s9
  generalize s9.line [.opi .addi S4 S4 4, .opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] = s10 at e10 p10 mm10 g4 g9 g8 k10
  have c10 : CodeAt s10.mem base kernel := by rw [mm10]; exact c9
  -- s9's registers are s8's, and s8's other than T0 and T1 are s's
  have k8' : ∀ r, r ≠ T0 → r ≠ T1 → s9.reg r = s.reg r := by
    intro r h0 h1
    rw [r9, k8 r h0, r7, ifF (by simp [h1]), k6 r h0 h1, r5, ifF (by simp [h1]), k4 r h0 h1, r3, ifF (by simp [h1]),
      k2 r h0, r1, ifF (by simp [h0])]
  have v8' : s10.reg S8 = BitVec.ofNat 32 (16 - (j + 1)) := by
    rw [g8, k8' _ (by decide) (by decide), h.s8, show 16 - j = 16 - (j + 1) + 1 by omega]
    exact dec_one _ (by omega)
  have ht' : taken .bne (s10.reg S8) (s10.reg 0) = decide (j + 1 < 16) := by
    rw [v8', reg_zero, taken_count _ (by omega)]; simp only [decide_eq_decide]; omega
  have finish : ∀ s11 : Machine, run env 1 s10 = .running s11 → (∀ r, s11.reg r = s10.reg r) →
      s11.mem = s10.mem → s11.pc = base + BitVec.ofNat 32 (4 * (if j + 1 < 16 then 53 else 68)) →
      ∃ s', run env 15 s = .running s' ∧ LInv base m0 P (j + 1) s' ∧
        s'.pc = base + BitVec.ofNat 32 (4 * (if j + 1 < 16 then 53 else 68)) ∧
        (∀ r, r ≠ T0 → r ≠ T1 → r ≠ S4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
    intro s11 e11 b11 m11 p11
    have mem11 : s11.mem = writeLE s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * j)) (s8.reg T0).toNat 4 := by
      rw [m11, mm10, m9, mem8]
    refine ⟨s11, ?_, ⟨?_, ?_, ?_, ?_, ?_⟩, p11, ?_⟩
    · rw [show 15 = 1 + (1 + (1 + (2 + (1 + (2 + (1 + (1 + (1 + (3 + 1))))))))) by rfl, run_add_running e1,
        run_add_running e2, run_add_running e3, run_add_running e4, run_add_running e5, run_add_running e6,
        run_add_running e7, run_add_running e8, run_add_running e9, run_add_running e10, e11]
    · rw [b11, g4, k8' _ (by decide) (by decide), h.s4, ofNat_step]; congr 2
    · rw [b11, g9, k8' _ (by decide) (by decide), h.s9, ofNat_step]; congr 2
    · rw [b11, v8']
    · rw [mem11]
      exact h.keeps.trans (keeps_writeLE fit s.mem _ (by omega) (by omega) (by decide))
    · intro i hi
      rw [mem11]
      rcases Nat.lt_or_ge i j with hl | hl
      · rw [wordAt_other fit _ _ (by omega) (by omega) (by omega)]; exact h.words i hl
      · rw [show i = j by omega, wordAt_same, word]
    · intro r h0 h1 h4 h8 h9
      rw [b11, k10 r h4 h9 h8, k8' r h0 h1]
  by_cases hl : j + 1 < 16
  · have e11 : run env 1 s10 = .running (s10.setPc (s10.pc + ((0xfe4 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 67 (by decide) c10 p10 (i := .br .bne S8 0 0xfe4) (by decide)
        (exec_br_taken (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p10]
    rw [BitVec.add_assoc]
    congr 1
  · have e11 : run env 1 s10 = .running s10.next :=
      (stepK (prog := kernel) hp 67 (by decide) c10 p10 (i := .br .bne S8 0 0xfe4) (by decide)
        (exec_br_not (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p10]
    exact pc_next fit 67 (by decide)


/-- **Sixteen words in**, by induction on words loaded. -/
theorem load_loop {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 53))
    {m0 : Word → Byte} {P : Nat} (hP : 0x1340 ≤ P) (hP2 : P + 64 ≤ 0x10000) (h : LInv base m0 P 0 s) :
    ∀ j ≤ 16, ∃ s', run env (15 * j) s = .running s' ∧ LInv base m0 P j s' ∧
      s'.pc = base + BitVec.ofNat 32 (4 * (if j < 16 then 53 else 68)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ S4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h, by simp [hpc], fun _ _ _ _ _ _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, h1, p1, k1⟩ := ih (by omega)
    have c0 : CodeAt m0 base kernel := (Keeps.symm' h.keeps).code hp.fit (by decide) (by decide) hcode
    have c1 : CodeAt s1.mem base kernel := h1.keeps.code hp.fit (by decide) (by decide) c0
    obtain ⟨s2, e2, h2, p2, k2⟩ := load_step hp c1 (by rw [p1, ifT (by omega)]) (by omega) hP hP2 h1
    refine ⟨s2, by rw [show 15 * (j + 1) = 15 * j + 15 by omega, run_add_running e1, e2], h2, p2, ?_⟩
    intro r a b c d e
    rw [k2 r a b c d e, k1 r a b c d e]


/-! ## Forty-eight words more -/

theorem getD_app_left {a b : List W32} {i : Nat} (h : i < a.length) : (a ++ b).getD i 0 = a.getD i 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_left h]

theorem getD_app_right {a b : List W32} {i : Nat} (h : a.length ≤ i) :
    (a ++ b).getD i 0 = b.getD (i - a.length) 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_right h]

theorem expand_length (w : List W32) (n : Nat) : (expand w n).length = w.length + n := by
  induction n with
  | zero => rfl
  | succ n ih => simp [expand, ih]; omega

/-- Extending the schedule leaves the words already there. -/
theorem expand_prefix (w : List W32) (n : Nat) : ∀ k i, i < w.length + n →
    (expand w (n + k)).getD i 0 = (expand w n).getD i 0 := by
  intro k
  induction k with
  | zero => intro i _; rfl
  | succ k ih =>
    intro i hi
    rw [show n + (k + 1) = (n + k) + 1 by omega]
    simp only [expand]
    rw [getD_app_left (by rw [expand_length]; omega)]
    exact ih i hi

/-- Word `16 + n` of the schedule, from the four before it that FIPS 180-4 names. -/
theorem expand_new (w : List W32) (hw : w.length = 16) (n : Nat) :
    (expand w (n + 1)).getD (16 + n) 0 =
      ssig1 ((expand w n).getD (14 + n) 0) + (expand w n).getD (9 + n) 0 + ssig0 ((expand w n).getD (1 + n) 0)
        + (expand w n).getD n 0 := by
  simp only [expand]
  have hl : (expand w n).length = 16 + n := by rw [expand_length, hw]
  rw [getD_app_right (by omega), hl, Nat.sub_self]
  simp only [List.getD_cons_zero]
  rw [show 16 + n - 2 = 14 + n by omega, show 16 + n - 7 = 9 + n by omega, show 16 + n - 15 = 1 + n by omega,
    show 16 + n - 16 = n by omega]

/-- The same, for the whole schedule: word `t` from words `t-2`, `t-7`, `t-15`, `t-16`. -/
theorem sched_word (w : List W32) (hw : w.length = 16) (t : Nat) (h1 : 16 ≤ t) (h2 : t < 64) :
    (expand w 48).getD t 0 = ssig1 ((expand w 48).getD (t - 2) 0) + (expand w 48).getD (t - 7) 0
      + ssig0 ((expand w 48).getD (t - 15) 0) + (expand w 48).getD (t - 16) 0 := by
  have pre : ∀ n i, n ≤ 48 → i < 16 + n → (expand w 48).getD i 0 = (expand w n).getD i 0 := fun n i hn hi => by
    rw [show 48 = n + (48 - n) by omega]; exact expand_prefix w n _ i (by rw [hw]; exact hi)
  obtain ⟨n, rfl⟩ : ∃ n, t = 16 + n := ⟨t - 16, by omega⟩
  rw [pre (n + 1) _ (by omega) (by omega), expand_new w hw, pre n _ (by omega) (by omega),
    pre n _ (by omega) (by omega), pre n _ (by omega) (by omega), pre n _ (by omega) (by omega),
    show 16 + n - 2 = 14 + n by omega, show 16 + n - 7 = 9 + n by omega, show 16 + n - 15 = 1 + n by omega,
    show 16 + n - 16 = n by omega]

/-- An address `d` bytes below one past `base`, from a negative 12-bit offset. -/
theorem off_back (base : Word) (c d : Nat) (h0 : 1 ≤ d) (h1 : d ≤ c) (h2 : d ≤ 2048) (hc : c < 2 ^ 32) :
    base + BitVec.ofNat 32 c + (BitVec.ofNat 12 (4096 - d)).signExtend 32 = base + BitVec.ofNat 32 (c - d) := by
  rw [se_neg _ (by omega) (by omega), BitVec.add_assoc]
  congr 1
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
  rw [Nat.mod_eq_of_lt hc, Nat.mod_eq_of_lt (show 2 ^ 32 - 4096 + (4096 - d) < 2 ^ 32 by omega),
    Nat.mod_eq_of_lt (show c - d < 2 ^ 32 by omega), show c + (2 ^ 32 - 4096 + (4096 - d)) = (c - d) + 2 ^ 32 by omega,
    Nat.add_mod_right, Nat.mod_eq_of_lt (show c - d < 2 ^ 32 by omega)]

theorem ssig1_line (s : Machine) :
    (s.line ssig1Code).reg T1 = ssig1 (s.reg T0) ∧
    ∀ r, r ≠ T1 → r ≠ T2 → r ≠ T3 → (s.line ssig1Code).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, ssig1Code, Machine.alu, reg_setReg, T0, T1, T2, T3, aluR, shiftI, ssig1, rotr,
    BitVec.rotateRight, BitVec.rotateRightAux], fun r h1 h2 h3 => ?_⟩
  exact line_keeps _ _ _ (by simp [ssig1Code, rdOf, Ne.symm h1, Ne.symm h2, Ne.symm h3])

theorem ssig0_line (s : Machine) :
    (s.line ssig0Code).reg T2 = ssig0 (s.reg T0) ∧
    ∀ r, r ≠ T2 → r ≠ T3 → r ≠ T4 → (s.line ssig0Code).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, ssig0Code, Machine.alu, reg_setReg, T0, T2, T3, T4, aluR, shiftI, ssig0, rotr,
    BitVec.rotateRight, BitVec.rotateRightAux], fun r h2 h3 h4 => ?_⟩
  exact line_keeps _ _ _ (by simp [ssig0Code, rdOf, Ne.symm h2, Ne.symm h3, Ne.symm h4])


theorem add_T1_T0_line (s : Machine) :
    (s.line [.op .add T1 T1 T0]).reg T1 = s.reg T1 + s.reg T0 ∧
    ∀ r, r ≠ T1 → (s.line [.op .add T1 T1 T0]).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, aluR, T0, T1], fun r h => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h])

/-- σ₀ of `T0`, added to `T1`. -/
def ssig0Add : List Instr := ssig0Code ++ [.op .add T1 T1 T2]

theorem ssig0_add_line (s : Machine) :
    (s.line ssig0Add).reg T1 = s.reg T1 + ssig0 (s.reg T0) ∧
    ∀ r, r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → (s.line ssig0Add).reg r = s.reg r := by
  refine ⟨by simp [Machine.line, ssig0Add, ssig0Code, Machine.alu, reg_setReg, T0, T1, T2, T3, T4, aluR, shiftI, ssig0, rotr,
    BitVec.rotateRight, BitVec.rotateRightAux], fun r h1 h2 h3 h4 => ?_⟩
  exact line_keeps _ _ _ (by simp [ssig0Add, ssig0Code, rdOf, Ne.symm h1, Ne.symm h2, Ne.symm h3, Ne.symm h4])

theorem expand_ctr_line (s : Machine) :
    let s' := s.line [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]
    s'.reg S9 = s.reg S9 + 4 ∧ s'.reg S8 = s.reg S8 + (0xfff : BitVec 12).signExtend 32 ∧
    ∀ r, r ≠ S9 → r ≠ S8 → s'.reg r = s.reg r := by
  refine ⟨by simp [Machine.line, Machine.alu, reg_setReg, aluI, S8, S9],
    by simp [Machine.line, Machine.alu, reg_setReg, aluI, S8, S9], fun r h9 h8 => ?_⟩
  exact line_keeps _ _ _ (by simp [rdOf, Ne.symm h9, Ne.symm h8])

/-- The expansion loop at the top of word `t`: W[0..t) is the schedule. -/
structure EInv (base : Word) (m0 : Word → Byte) (E : List W32) (t : Nat) (s : Machine) : Prop where
  s9 : s.reg S9 = base + BitVec.ofNat 32 (0x1300 + 4 * t)
  s8 : s.reg S8 = BitVec.ofNat 32 (64 - t)
  keeps : Keeps (base + BitVec.ofNat 32 0x1300) 256 m0 s.mem
  words : ∀ i < t, wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * i)) = E.getD i 0


/-- `lw rd, -d(S9)` with `S9` at W[t]: W[t - d/4]. -/
theorem w_back {base : Word} (t d : Nat) (h0 : 1 ≤ d) (h1 : d ≤ 4 * t) (h2 : d ≤ 2048)
    (h3 : 0x1300 + 4 * t < 0x10000) (hd : d % 4 = 0) :
    base + BitVec.ofNat 32 (0x1300 + 4 * t) + (BitVec.ofNat 12 (4096 - d)).signExtend 32 =
      base + BitVec.ofNat 32 (0x1300 + 4 * (t - d / 4)) := by
  rw [off_back base _ d h0 (by omega) h2 (by omega)]; congr 2; omega

/-- **One schedule word**: twenty-nine instructions from the top of the
expansion loop store W[t], from W[t-2], W[t-7], W[t-15] and W[t-16]. -/
theorem expand_step {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 69))
    {m0 : Word → Byte} {w : List W32} (hw : w.length = 16) {t : Nat} (ht1 : 16 ≤ t) (ht : t < 64)
    (h : EInv base m0 (expand w 48) t s) :
    ∃ s', run env 29 s = .running s' ∧ EInv base m0 (expand w 48) (t + 1) s' ∧
      s'.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 69 else 98)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  have rd : ∀ i < t, BitVec.ofNat 32 (readLE s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * i)) 4) =
      (expand w 48).getD i 0 := fun i hi => h.words i hi
  -- lw T0, -8(S9)
  obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep (prog := kernel) hp 69 (by decide) hcode hpc (rd := T0) (rs1 := S9)
    (imm := 0xff8) (by decide) (0x1300 + 4 * (t - 2))
    (by rw [h.s9]; exact w_back t 8 (by decide) (by omega) (by decide) (by omega) (by decide)) (by omega) (by omega)
  have c1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  -- σ₁
  have e2 : run env 9 s1 = .running (s1.line ssig1Code) :=
    run_line (prog := kernel) hp ssig1Code (by decide) 70 s1 (by decide) (by decide) c1 p1 (by decide)
  have p2 := line_pc_at ssig1Code p1 (by decide)
  have mm2 := line_mem s1 ssig1Code
  obtain ⟨v2, k2⟩ := ssig1_line s1
  generalize s1.line ssig1Code = s2 at e2 p2 mm2 v2 k2
  have c2 : CodeAt s2.mem base kernel := by rw [mm2]; exact c1
  have s9_2 : s2.reg S9 = s.reg S9 := by
    rw [k2 _ (by decide) (by decide) (by decide), r1, ifF (by decide)]
  -- lw T0, -28(S9)
  obtain ⟨s3, e3, p3, m3, r3⟩ := loadStep (prog := kernel) hp 79 (by decide) c2 p2 (rd := T0) (rs1 := S9)
    (imm := 0xfe4) (by decide) (0x1300 + 4 * (t - 7))
    (by rw [s9_2, h.s9]; exact w_back t 28 (by decide) (by omega) (by decide) (by omega) (by decide)) (by omega)
    (by omega)
  have c3 : CodeAt s3.mem base kernel := by rw [m3]; exact c2
  -- add T1, T1, T0
  have e4 : run env 1 s3 = .running (s3.line [.op .add T1 T1 T0]) :=
    run_line (prog := kernel) hp [.op .add T1 T1 T0] (by decide) 80 s3 (by decide) (by decide) c3 p3 (by decide)
  have p4 := line_pc_at [.op .add T1 T1 T0] p3 (by decide)
  have mm4 := line_mem s3 [.op .add T1 T1 T0]
  obtain ⟨v4, k4⟩ := add_T1_T0_line s3
  generalize s3.line [.op .add T1 T1 T0] = s4 at e4 p4 mm4 v4 k4
  have c4 : CodeAt s4.mem base kernel := by rw [mm4]; exact c3
  have s9_4 : s4.reg S9 = s.reg S9 := by rw [k4 _ (by decide), r3, ifF (by decide), s9_2]
  -- lw T0, -60(S9)
  obtain ⟨s5, e5, p5, m5, r5⟩ := loadStep (prog := kernel) hp 81 (by decide) c4 p4 (rd := T0) (rs1 := S9)
    (imm := 0xfc4) (by decide) (0x1300 + 4 * (t - 15))
    (by rw [s9_4, h.s9]; exact w_back t 60 (by decide) (by omega) (by decide) (by omega) (by decide)) (by omega)
    (by omega)
  have c5 : CodeAt s5.mem base kernel := by rw [m5]; exact c4
  -- σ₀, added
  have e6 : run env 10 s5 = .running (s5.line ssig0Add) :=
    run_line (prog := kernel) hp ssig0Add (by decide) 82 s5 (by decide) (by decide) c5 p5 (by decide)
  have p6 := line_pc_at ssig0Add p5 (by decide)
  have mm6 := line_mem s5 ssig0Add
  obtain ⟨v6, k6⟩ := ssig0_add_line s5
  generalize s5.line ssig0Add = s6 at e6 p6 mm6 v6 k6
  have c6 : CodeAt s6.mem base kernel := by rw [mm6]; exact c5
  have s9_6 : s6.reg S9 = s.reg S9 := by
    rw [k6 _ (by decide) (by decide) (by decide) (by decide), r5, ifF (by decide), s9_4]
  -- lw T0, -64(S9)
  obtain ⟨s7, e7, p7, m7, r7⟩ := loadStep (prog := kernel) hp 92 (by decide) c6 p6 (rd := T0) (rs1 := S9)
    (imm := 0xfc0) (by decide) (0x1300 + 4 * (t - 16))
    (by rw [s9_6, h.s9]; exact w_back t 64 (by decide) (by omega) (by decide) (by omega) (by decide)) (by omega)
    (by omega)
  have c7 : CodeAt s7.mem base kernel := by rw [m7]; exact c6
  -- add T1, T1, T0
  have e8 : run env 1 s7 = .running (s7.line [.op .add T1 T1 T0]) :=
    run_line (prog := kernel) hp [.op .add T1 T1 T0] (by decide) 93 s7 (by decide) (by decide) c7 p7 (by decide)
  have p8 := line_pc_at [.op .add T1 T1 T0] p7 (by decide)
  have mm8 := line_mem s7 [.op .add T1 T1 T0]
  obtain ⟨v8, k8⟩ := add_T1_T0_line s7
  generalize s7.line [.op .add T1 T1 T0] = s8 at e8 p8 mm8 v8 k8
  have c8 : CodeAt s8.mem base kernel := by rw [mm8]; exact c7
  have mem8 : s8.mem = s.mem := by rw [mm8, m7, mm6, m5, mm4, m3, mm2, m1]
  have s9_8 : s8.reg S9 = s.reg S9 := by rw [k8 _ (by decide), r7, ifF (by decide), s9_6]
  -- the word
  have word : s8.reg T1 = (expand w 48).getD t 0 := by
    rw [v8, r7, ifF (by decide), r7, ifT (by decide), v6, r5, ifF (by decide), r5, ifT (by decide), v4, r3,
      ifF (by decide), r3, ifT (by decide), v2, r1, ifT (by decide), mm6, m5, mm4, m3, mm2, m1,
      rd _ (by omega), rd _ (by omega), rd _ (by omega), rd _ (by omega), sched_word w hw t ht1 ht]
  -- sw T1, 0(S9)
  obtain ⟨s9, e9, p9, m9, r9⟩ := storeStep (prog := kernel) hp 94 (by decide) c8 p8 (rs1 := S9) (rs2 := T1)
    (imm := 0) (by decide) (0x1300 + 4 * t) (by rw [s9_8, h.s9]; simp) (by omega) (by omega)
  have c9 : CodeAt s9.mem base kernel := by
    rw [m9]
    exact (keeps_writeLE fit s8.mem _ (Nat.le_refl _) (Nat.le_refl _) (by omega)).code fit (by omega)
      (by rw [kernel_length]; omega) c8
  -- the counters
  have e10 : run env 2 s9 = .running (s9.line [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]) :=
    run_line (prog := kernel) hp [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] (by decide) 95 s9 (by decide)
      (by decide) c9 p9 (by decide)
  have p10 := line_pc_at [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] p9 (by decide)
  have mm10 := line_mem s9 [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff]
  obtain ⟨g9, g8, k10⟩ := expand_ctr_line s9
  generalize s9.line [.opi .addi S9 S9 4, .opi .addi S8 S8 0xfff] = s10 at e10 p10 mm10 g9 g8 k10
  have c10 : CodeAt s10.mem base kernel := by rw [mm10]; exact c9
  have k9 : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → s9.reg r = s.reg r := by
    intro r h0 h1 h2 h3 h4
    rw [r9, k8 r h1, r7, ifF (by simp [h0]), k6 r h1 h2 h3 h4, r5, ifF (by simp [h0]), k4 r h1, r3,
      ifF (by simp [h0]), k2 r h1 h2 h3, r1, ifF (by simp [h0])]
  have v8' : s10.reg S8 = BitVec.ofNat 32 (64 - (t + 1)) := by
    rw [g8, k9 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.s8,
      show 64 - t = 64 - (t + 1) + 1 by omega]
    exact dec_one _ (by omega)
  have ht' : taken .bne (s10.reg S8) (s10.reg 0) = decide (t + 1 < 64) := by
    rw [v8', reg_zero, taken_count _ (by omega)]; simp only [decide_eq_decide]; omega
  have finish : ∀ s11 : Machine, run env 1 s10 = .running s11 → (∀ r, s11.reg r = s10.reg r) →
      s11.mem = s10.mem → s11.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 69 else 98)) →
      ∃ s', run env 29 s = .running s' ∧ EInv base m0 (expand w 48) (t + 1) s' ∧
        s'.pc = base + BitVec.ofNat 32 (4 * (if t + 1 < 64 then 69 else 98)) ∧
        (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
    intro s11 e11 b11 m11 p11
    have mem11 : s11.mem = writeLE s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t)) (s8.reg T1).toNat 4 := by
      rw [m11, mm10, m9, mem8]
    refine ⟨s11, ?_, ⟨?_, ?_, ?_, ?_⟩, p11, ?_⟩
    · rw [show 29 = 1 + (9 + (1 + (1 + (1 + (10 + (1 + (1 + (1 + (2 + 1))))))))) by rfl, run_add_running e1,
        run_add_running e2, run_add_running e3, run_add_running e4, run_add_running e5, run_add_running e6,
        run_add_running e7, run_add_running e8, run_add_running e9, run_add_running e10, e11]
    · rw [b11, g9, k9 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.s9, ofNat_step]; congr 2
    · rw [b11, v8']
    · rw [mem11]
      exact h.keeps.trans (keeps_writeLE fit s.mem _ (by omega) (by omega) (by decide))
    · intro i hi
      rw [mem11]
      rcases Nat.lt_or_ge i t with hl | hl
      · rw [wordAt_other fit _ _ (by omega) (by omega) (by omega)]; exact h.words i hl
      · rw [show i = t by omega, wordAt_same, word]
    · intro r h0 h1 h2 h3 h4 h8 h9
      rw [b11, k10 r h9 h8, k9 r h0 h1 h2 h3 h4]
  by_cases hl : t + 1 < 64
  · have e11 : run env 1 s10 = .running (s10.setPc (s10.pc + ((0xfc8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 97 (by decide) c10 p10 (i := .br .bne S8 0 0xfc8) (by decide)
        (exec_br_taken (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p10]
    rw [BitVec.add_assoc]
    congr 1
  · have e11 : run env 1 s10 = .running s10.next :=
      (stepK (prog := kernel) hp 97 (by decide) c10 p10 (i := .br .bne S8 0 0xfc8) (by decide)
        (exec_br_not (by rw [ht']; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e11 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p10]
    exact pc_next fit 97 (by decide)

/-- **The schedule**, by induction on words written from W[16]. -/
theorem expand_loop {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 69))
    {m0 : Word → Byte} {w : List W32} (hw : w.length = 16) (h : EInv base m0 (expand w 48) 16 s) :
    ∀ n ≤ 48, ∃ s', run env (29 * n) s = .running s' ∧ EInv base m0 (expand w 48) (16 + n) s' ∧
      s'.pc = base + BitVec.ofNat 32 (4 * (if 16 + n < 64 then 69 else 98)) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S8 → r ≠ S9 → s'.reg r = s.reg r) := by
  intro n hn
  induction n with
  | zero => exact ⟨s, rfl, h, by simp [hpc], fun _ _ _ _ _ _ _ _ => rfl⟩
  | succ n ih =>
    obtain ⟨s1, e1, h1, p1, k1⟩ := ih (by omega)
    have c0 : CodeAt m0 base kernel := (Keeps.symm' h.keeps).code hp.fit (by decide) (by decide) hcode
    have c1 : CodeAt s1.mem base kernel := h1.keeps.code hp.fit (by decide) (by decide) c0
    obtain ⟨s2, e2, h2, p2, k2⟩ := expand_step hp c1 (by rw [p1, ifT (by omega)]) hw (by omega) (by omega) h1
    refine ⟨s2, by rw [show 29 * (n + 1) = 29 * n + 29 by omega, run_add_running e1, e2],
      by rw [show 16 + (n + 1) = 16 + n + 1 by omega]; exact h2, by rw [show 16 + (n + 1) = 16 + n + 1 by omega]; exact p2, ?_⟩
    intro r a b c d e f g
    rw [k2 r a b c d e f g, k1 r a b c d e f g]


/-! ## One block -/

theorem readBytes_getD (m : Word → Byte) (a : Word) (n d : Nat) (hd : d < n) :
    (readBytes m a n).getD d 0 = m (a + BitVec.ofNat 32 d) := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by rw [readBytes_length]; exact hd)]
  exact readBytes_getElem m a n d hd

/-- The block's words, as the specification takes them from its bytes, are
the words the load loop puts together. -/
theorem blockWords_bw {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {P : Nat}
    (hP : P + 64 ≤ 0x10000) (i : Nat) (hi : i < 16) :
    (blockWords (readBytes m (base + BitVec.ofNat 32 P) 64)).getD i 0 = bw base m P i := by
  simp only [blockWords, List.getD_eq_getElem?_getD, List.getElem?_map, List.getElem?_range hi, Option.map_some,
    Option.getD_some]
  rw [← List.getD_eq_getElem?_getD, ← List.getD_eq_getElem?_getD, ← List.getD_eq_getElem?_getD,
    ← List.getD_eq_getElem?_getD, readBytes_getD _ _ _ _ (by omega), readBytes_getD _ _ _ _ (by omega),
    readBytes_getD _ _ _ _ (by omega), readBytes_getD _ _ _ _ (by omega), off_add hfit _ _ (by omega),
    off_add hfit _ _ (by omega), off_add hfit _ _ (by omega), off_add hfit _ _ (by omega)]
  rfl

theorem blockWords_length (b : List Byte) : (blockWords b).length = 16 := by simp [blockWords]

/-- A list of 64 is the map over 0 … 63 of what its words are. -/
theorem map_range_eq (f : Nat → W32) (l : List W32) (hl : l.length = 64) (h : ∀ t < 64, f t = l.getD t 0) :
    (List.range 64).map f = l := by
  apply List.ext_getElem (by simp [hl])
  intro t h1 h2
  simp only [List.getElem_map, List.getElem_range]
  rw [h t (by simpa using h1), List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h2]; rfl

theorem K_length : K.length = 64 := by rfl

theorem zipWith_getD (a b : List W32) (i : Nat) (ha : i < a.length) (hb : i < b.length) :
    (List.zipWith (· + ·) a b).getD i 0 = a.getD i 0 + b.getD i 0 := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by simp; omega), List.getElem_zipWith]
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem ha, List.getElem?_eq_getElem hb]

/-- A word outside what a run kept to is the word that was there. -/
theorem wordAt_keeps {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {S N c : Nat} {m m' : Word → Byte}
    (h : Keeps (base + BitVec.ofNat 32 S) N m m') (hSN : S + N < 0x10000) (hc : c + 4 ≤ 0x10000)
    (hout : c + 4 ≤ S ∨ S + N ≤ c) :
    wordAt m' (base + BitVec.ofNat 32 c) = wordAt m (base + BitVec.ofNat 32 c) := by
  unfold wordAt
  congr 1
  apply readLE_four_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit hSN (by omega) (by omega)

/-- a0 … a7 are registers 10 … 17. -/
theorem areg_ne {i j : Nat} (hi : i < 8) (hj : j < 8) (h : i ≠ j) :
    BitVec.ofNat 5 (10 + i) ≠ BitVec.ofNat 5 (10 + j) := by
  intro e; have := congrArg BitVec.toNat e; simp at this; omega

theorem areg_nz {i : Nat} (hi : i < 8) : BitVec.ofNat 5 (10 + i) ≠ 0 := by
  intro e; have := congrArg BitVec.toNat e; simp at this; omega

theorem holds_getD {s : Machine} {st : St} (h : Holds s st) :
    ∀ i < 8, s.reg (BitVec.ofNat 5 (10 + i)) = st.toList.getD i 0 := by
  obtain ⟨ha, hb, hc, hd, he, hf, hg, hh⟩ := h
  intro i hi
  rcases i with _ | _ | _ | _ | _ | _ | _ | _ | i
  · exact ha
  · exact hb
  · exact hc
  · exact hd
  · exact he
  · exact hf
  · exact hg
  · exact hh
  · omega

theorem at_loadState : ∀ j < 8,
    kernel.getD (98 + j) .ecall = .ld .lw (BitVec.ofNat 5 (10 + j)) S1 (BitVec.ofNat 12 (0x200 + 4 * j)) := by
  decide

/-- **a … h from H**: `lw a_j, 0x200 + 4j(s1)` for `j < 8`. -/
theorem loadState_run {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 98))
    (h1 : s.reg S1 = base + BitVec.ofNat 32 0x1000) :
    ∀ j ≤ 8, ∃ s', run env j s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (98 + j)) ∧
      s'.mem = s.mem ∧
      (∀ i < j, s'.reg (BitVec.ofNat 5 (10 + i)) = wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i))) ∧
      (∀ r, (∀ i < 8, r ≠ BitVec.ofNat 5 (10 + i)) → s'.reg r = s.reg r) := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, rfl, fun i h => absurd h (Nat.not_lt_zero _), fun r _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, m1, v1, k1⟩ := ih (by omega)
    have hS1 : s1.reg S1 = base + BitVec.ofNat 32 0x1000 := by
      rw [k1 _ (fun i hi e => by have := congrArg BitVec.toNat e; simp [S1] at this; omega), h1]
    obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp (98 + j) (by rw [kernel_length]; omega) (by rw [m1]; exact hcode)
      p1 (at_loadState j (by omega)) (0x1200 + 4 * j)
      (by rw [hS1, se_small _ (by omega), off_add hp.fit _ _ (by omega)]; congr 2; omega) (by omega) (by omega)
    refine ⟨s2, by rw [run_add_running e1]; exact e2, by rw [p2]; rfl, by rw [m2, m1], ?_, ?_⟩
    · intro i hi
      rcases (by omega : i < j ∨ i = j) with h | h
      · rw [reg_kept r2 (areg_ne (by omega) (by omega) (by omega)), v1 i h]
      · subst h; rw [reg_wrote r2 (areg_nz (by omega)), m1]; rfl
    · intro r hr; rw [reg_kept r2 (hr j (by omega)), k1 r hr]

theorem at_addBack : ∀ j < 8,
    kernel.getD (159 + 3 * j) .ecall = .ld .lw T0 S1 (BitVec.ofNat 12 (0x200 + 4 * j)) ∧
    kernel.getD (159 + 3 * j + 1) .ecall = .op .add T0 T0 (BitVec.ofNat 5 (10 + j)) ∧
    kernel.getD (159 + 3 * j + 2) .ecall = .st .sw S1 T0 (BitVec.ofNat 12 (0x200 + 4 * j)) := by
  decide

/-- **H += a … h**: `lw t0; add t0, t0, a_j; sw t0` for `j < 8`. -/
theorem addBack_run {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 159))
    (h1 : s.reg S1 = base + BitVec.ofNat 32 0x1000) (v : Nat → W32)
    (hv : ∀ i < 8, s.reg (BitVec.ofNat 5 (10 + i)) = v i) :
    ∀ j ≤ 8, ∃ s', run env (3 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (159 + 3 * j)) ∧
      Keeps (base + BitVec.ofNat 32 0x1200) 32 s.mem s'.mem ∧
      (∀ i < 8, wordAt s'.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i)) =
        if i < j then wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i)) + v i
        else wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i))) ∧
      (∀ r, r ≠ T0 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, Keeps.refl _ _ _, fun i _ => by simp, fun r _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, k1, w1, f1⟩ := ih (by omega)
    obtain ⟨a1, a2, a3⟩ := at_addBack j (by omega)
    have c0 : CodeAt s1.mem base kernel := k1.code fit (by decide) (by decide) hcode
    have hS1 : s1.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [f1 _ (by decide), h1]
    have ad : s1.reg S1 + (BitVec.ofNat 12 (0x200 + 4 * j)).signExtend 32 =
        base + BitVec.ofNat 32 (0x1200 + 4 * j) := by
      rw [hS1, se_small _ (by omega), off_add fit _ _ (by omega)]; congr 2; omega
    obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp (159 + 3 * j) (by rw [kernel_length]; omega) c0 p1 a1
      (0x1200 + 4 * j) ad (by omega) (by omega)
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep hp (159 + 3 * j + 1) (by rw [kernel_length]; omega)
      (by rw [m2]; exact c0) p2 a2 rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := storeStep hp (159 + 3 * j + 2) (by rw [kernel_length]; omega)
      (by rw [m3, m2]; exact c0) p3 a3 (0x1200 + 4 * j)
      (by rw [r3, ifF (by decide), reg_kept r2 (by decide)]; exact ad) (by omega) (by omega)
    have vt : s3.reg T0 = wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) + v j := by
      rw [reg_wrote r3 (by decide)]
      simp only [aluR]
      have n0 : BitVec.ofNat 5 (10 + j) ≠ T0 := by
        intro e; have := congrArg BitVec.toNat e; simp [T0] at this; omega
      rw [reg_wrote r2 (by decide), reg_kept r2 n0, f1 _ n0, hv j (by omega)]
      have := w1 j (by omega)
      rw [ifF (by omega)] at this
      rw [← this]; rfl
    have mm : s4.mem = writeLE s1.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) (s3.reg T0).toNat 4 := by
      rw [m4, m3, m2]
    refine ⟨s4, ?_, by rw [p4]; congr 2, ?_, ?_, ?_⟩
    · rw [show 3 * (j + 1) = 3 * j + (1 + (1 + 1)) by omega, run_add_running e1, run_cons e2 (run_cons e3 e4)]
    · rw [mm]; exact k1.trans (keeps_writeLE fit _ _ (by omega) (by omega) (by decide))
    · intro i hi
      rw [mm]
      rcases (by omega : i = j ∨ i ≠ j) with h | h
      · subst h; rw [wordAt_same, vt, ifT (by omega)]
      · rw [wordAt_other fit _ _ (by omega) (by omega) (by omega), w1 i hi]
        by_cases hij : i < j
        · rw [ifT hij, ifT (by omega)]
        · rw [ifF hij, ifF (by omega)]
    · intro r hr
      rw [r4, r3, ifF (by simp [hr]), reg_kept r2 hr, f1 r hr]

theorem areg_ne_of {i : Nat} (r : Reg) (hr : r.toNat < 10 ∨ 18 ≤ r.toNat) (hi : i < 8) :
    BitVec.ofNat 5 (10 + i) ≠ r := by
  intro e; have := congrArg BitVec.toNat e; simp at this; omega

def loadPre : List Instr := [ .opi .addi S9 S1 0x300, .opi .addi S8 0 16 ]
def expandPre : List Instr := [ .opi .addi S8 0 48 ]
def roundsPre : List Instr := [ .opi .addi S9 S1 0x300, .opi .addi S10 S1 0, .opi .addi S8 0 64 ]

theorem loadPre_line (s : Machine) :
    (s.line loadPre).reg S9 = s.reg S1 + BitVec.ofNat 32 0x300 ∧ (s.line loadPre).reg S8 = BitVec.ofNat 32 16 ∧
    ∀ r, r ≠ S9 → r ≠ S8 → (s.line loadPre).reg r = s.reg r := by
  refine ⟨by simp [loadPre, Machine.line, Machine.alu, reg_setReg, aluI, S1, S8, S9],
    by simp [loadPre, Machine.line, Machine.alu, reg_setReg, aluI, S1, S8, S9], fun r h9 h8 => ?_⟩
  exact line_keeps _ _ _ (by simp [loadPre, rdOf, Ne.symm h9, Ne.symm h8])

theorem expandPre_line (s : Machine) :
    (s.line expandPre).reg S8 = BitVec.ofNat 32 48 ∧ ∀ r, r ≠ S8 → (s.line expandPre).reg r = s.reg r := by
  refine ⟨by simp [expandPre, Machine.line, Machine.alu, reg_setReg, aluI, S8], fun r h8 => ?_⟩
  exact line_keeps _ _ _ (by simp [expandPre, rdOf, Ne.symm h8])

theorem roundsPre_line (s : Machine) :
    (s.line roundsPre).reg S9 = s.reg S1 + BitVec.ofNat 32 0x300 ∧ (s.line roundsPre).reg S10 = s.reg S1 ∧
    (s.line roundsPre).reg S8 = BitVec.ofNat 32 64 ∧
    ∀ r, r ≠ S9 → r ≠ S10 → r ≠ S8 → (s.line roundsPre).reg r = s.reg r := by
  refine ⟨by simp [roundsPre, Machine.line, Machine.alu, reg_setReg, aluI, S1, S8, S9, S10],
    by simp [roundsPre, Machine.line, Machine.alu, reg_setReg, aluI, S1, S8, S9, S10],
    by simp [roundsPre, Machine.line, Machine.alu, reg_setReg, aluI, S1, S8, S9, S10], fun r h9 h10 h8 => ?_⟩
  exact line_keeps _ _ _ (by simp [roundsPre, rdOf, Ne.symm h9, Ne.symm h10, Ne.symm h8])

/-- **One block**: from the top of the load, 4870 steps later H is
`compress H` of the 64 bytes at `P`, the block pointer has moved on 64, and
nothing outside H and W has changed. -/
theorem block_step {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 51))
    (hS1 : s.reg S1 = base + BitVec.ofNat 32 0x1000)
    {P : Nat} (hS4 : s.reg S4 = base + BitVec.ofNat 32 P) (hP : 0x1400 ≤ P) (hP2 : P + 64 ≤ 0x10000)
    (hK : ∀ t < 64, wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = K.getD t 0)
    {H : List W32} (hH8 : H.length = 8)
    (hH : ∀ j < 8, wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) = H.getD j 0) :
    ∃ s', run env 4870 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 183) ∧
      Keeps (base + BitVec.ofNat 32 0x1200) 0x200 s.mem s'.mem ∧
      (∀ j < 8, wordAt s'.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) =
        (compress H (readBytes s.mem (base + BitVec.ofNat 32 P) 64)).getD j 0) ∧
      s'.reg S4 = base + BitVec.ofNat 32 (P + 64) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S4 → r ≠ S8 → r ≠ S9 → r ≠ S10 →
        (∀ i < 8, BitVec.ofNat 5 (10 + i) ≠ r) → s'.reg r = s.reg r) := by
  have fit := hp.fit
  generalize hw : blockWords (readBytes s.mem (base + BitVec.ofNat 32 P) 64) = w
  have hwl : w.length = 16 := by rw [← hw, blockWords_length]
  -- addi s9, s1, 0x300; addi s8, x0, 16
  have e1 : run env 2 s = .running (s.line loadPre) :=
    run_line (prog := kernel) hp loadPre (by decide) 51 s (by decide) (by decide) hcode hpc (by decide)
  have p1 : (s.line loadPre).pc = base + BitVec.ofNat 32 (4 * 53) := line_pc_at loadPre hpc (by decide)
  have mm1 := line_mem s loadPre
  obtain ⟨v9, v8, k1⟩ := loadPre_line s
  generalize s.line loadPre = s1 at e1 p1 mm1 v9 v8 k1
  have c1 : CodeAt s1.mem base kernel := by rw [mm1]; exact hcode
  have L0 : LInv base s.mem P 0 s1 :=
    { s4 := by rw [k1 _ (by decide) (by decide), hS4]; rfl
      s9 := by rw [v9, hS1, off_add fit _ _ (by decide)]
      s8 := by rw [v8]
      keeps := by rw [mm1]; exact Keeps.refl _ _ _
      words := fun i h => absurd h (Nat.not_lt_zero _) }
  -- W[0..15]
  obtain ⟨s2, e2, L16, p2, k2⟩ := load_loop hp c1 p1 (by omega) hP2 L0 16 (Nat.le_refl _)
  have c2 : CodeAt s2.mem base kernel := L16.keeps.code fit (by decide) (by decide) hcode
  -- addi s8, x0, 48
  have e3 : run env 1 s2 = .running (s2.line expandPre) :=
    run_line (prog := kernel) hp expandPre (by decide) 68 s2 (by decide) (by decide) c2
      (by rw [p2, ifF (by decide)]) (by decide)
  have p3 : (s2.line expandPre).pc = base + BitVec.ofNat 32 (4 * 69) :=
    line_pc_at expandPre (by rw [p2, ifF (by decide)]) (by decide)
  have mm3 := line_mem s2 expandPre
  obtain ⟨u8, k3⟩ := expandPre_line s2
  generalize s2.line expandPre = s3 at e3 p3 mm3 u8 k3
  have c3 : CodeAt s3.mem base kernel := by rw [mm3]; exact c2
  have E16 : EInv base s.mem (expand w 48) 16 s3 :=
    { s9 := by rw [k3 _ (by decide), L16.s9]
      s8 := by rw [u8]
      keeps := by rw [mm3]; exact L16.keeps.widen fit (Nat.le_refl _) (by decide) (by decide)
      words := fun i hi => by
        rw [mm3, L16.words i hi, ← blockWords_bw fit s.mem hP2 i hi, hw]
        have := expand_prefix w 0 48 i (by rw [hwl]; omega)
        rw [Nat.zero_add] at this
        exact this.symm }
  -- W[16..63]
  obtain ⟨s4, e4, E64, p4, k4⟩ := expand_loop hp c3 p3 hwl E16 48 (Nat.le_refl _)
  have c4 : CodeAt s4.mem base kernel := E64.keeps.code fit (by decide) (by decide) hcode
  have hS1_4 : s4.reg S1 = base + BitVec.ofNat 32 0x1000 := by
    rw [k4 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      k3 _ (by decide), k2 _ (by decide) (by decide) (by decide) (by decide) (by decide),
      k1 _ (by decide) (by decide), hS1]
  have hH4 : ∀ i < 8, wordAt s4.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i)) = H.getD i 0 := fun i hi => by
    rw [wordAt_keeps fit E64.keeps (by decide) (by omega) (by omega), hH i hi]
  -- a … h
  obtain ⟨s5, e5, p5, m5, v5, k5⟩ := loadState_run hp c4 (by rw [p4, ifF (by decide)]) hS1_4 8 (Nat.le_refl _)
  have c5 : CodeAt s5.mem base kernel := by rw [m5]; exact c4
  have hS1_5 : s5.reg S1 = base + BitVec.ofNat 32 0x1000 := by
    rw [k5 _ (fun i hi => areg_ne_of S1 (by decide) hi |>.symm), hS1_4]
  -- addi s9, s1, 0x300; addi s10, s1, 0; addi s8, x0, 64
  have e6 : run env 3 s5 = .running (s5.line roundsPre) :=
    run_line (prog := kernel) hp roundsPre (by decide) 106 s5 (by decide) (by decide) c5 p5 (by decide)
  have p6 : (s5.line roundsPre).pc = base + BitVec.ofNat 32 (4 * 109) := line_pc_at roundsPre p5 (by decide)
  have mm6 := line_mem s5 roundsPre
  obtain ⟨w9, w10, w8, k6⟩ := roundsPre_line s5
  generalize s5.line roundsPre = s6 at e6 p6 mm6 w9 w10 w8 k6
  have c6 : CodeAt s6.mem base kernel := by rw [mm6]; exact c5
  have mem6 : s6.mem = s4.mem := by rw [mm6, m5]
  have hA6 : ∀ i < 8, s6.reg (BitVec.ofNat 5 (10 + i)) = H.getD i 0 := fun i hi => by
    rw [k6 _ (areg_ne_of S9 (by decide) hi) (areg_ne_of S10 (by decide) hi) (areg_ne_of S8 (by decide) hi),
      v5 i hi, hH4 i hi]
  have hold6 : Holds s6 (St.ofList H) :=
    ⟨hA6 0 (by decide), hA6 1 (by decide), hA6 2 (by decide), hA6 3 (by decide), hA6 4 (by decide),
      hA6 5 (by decide), hA6 6 (by decide), hA6 7 (by decide)⟩
  have R0 : RInv base 0 s6 :=
    { s9 := by rw [w9, hS1_5, off_add fit _ _ (by decide)]
      s10 := by rw [w10, hS1_5]
      s8 := by rw [w8] }
  -- the 64 rounds
  obtain ⟨s7, e7, m7, h7, _, p7, k7⟩ := rounds_loop hp c6 p6 hold6 R0 64 (Nat.le_refl _)
  have it : iter (St.ofList H) (fun t => wordAt s6.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)))
      (fun t => wordAt s6.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t))) 64 =
      rounds (St.ofList H) K (expand w 48) := by
    rw [← rounds_eq_iter, map_range_eq _ K K_length (fun t ht => ?_),
      map_range_eq _ (expand w 48) (by rw [expand_length, hwl]) (fun t ht => ?_)]
    · rw [mem6]; exact E64.words t (by omega)
    · rw [mem6, wordAt_keeps fit E64.keeps (by decide) (by omega) (by omega), hK t ht]
  rw [it] at h7
  generalize hst : rounds (St.ofList H) K (expand w 48) = st at h7
  have hS1_7 : s7.reg S1 = base + BitVec.ofNat 32 0x1000 := by
    rw [k7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      k6 _ (by decide) (by decide) (by decide), hS1_5]
  -- H += a … h
  obtain ⟨s8, e8, p8, kk8, w8', f8⟩ := addBack_run hp (by rw [m7]; exact c6) (by rw [p7, ifF (by decide)])
    hS1_7 _ (holds_getD h7) 8 (Nat.le_refl _)
  have mem7 : s7.mem = s4.mem := by rw [m7, mem6]
  refine ⟨s8, ?_, by rw [p8], ?_, ?_, ?_, ?_⟩
  · rw [show 4870 = 2 + (15 * 16 + (1 + (29 * 48 + (8 + (3 + (50 * 64 + 3 * 8)))))) by rfl,
      run_add_running e1, run_add_running e2, run_add_running e3, run_add_running e4, run_add_running e5,
      run_add_running e6, run_add_running e7]
    exact e8
  · have a : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 s.mem s7.mem := by
      rw [mem7]; exact E64.keeps.widen fit (by decide) (by decide) (by decide)
    exact a.trans (kk8.widen fit (Nat.le_refl _) (by decide) (by decide))
  · intro j hj
    rw [w8' j hj, ifT hj, mem7, hH4 j hj]
    simp only [compress]
    rw [hw, hst]
    exact (zipWith_getD H st.toList j (by omega) (by simp [St.toList]; omega)).symm
  · rw [f8 _ (by decide), k7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      k6 _ (by decide) (by decide) (by decide), k5 _ (fun i hi => areg_ne_of S4 (by decide) hi |>.symm),
      k4 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide),
      k3 _ (by decide), L16.s4]
  · intro r h0 h1 h2 h3 h4 hs4 hs8 hs9 hs10 hA
    rw [f8 r h0, k7 r h0 h1 h2 h3 (hA 0 (by decide)).symm (hA 1 (by decide)).symm (hA 2 (by decide)).symm
      (hA 3 (by decide)).symm (hA 4 (by decide)).symm (hA 5 (by decide)).symm (hA 6 (by decide)).symm
      (hA 7 (by decide)).symm hs8 hs9 hs10,
      k6 r hs9 hs10 hs8, k5 r (fun i hi => (hA i hi).symm), k4 r h0 h1 h2 h3 h4 hs8 hs9, k3 r hs8,
      k2 r h0 h1 hs4 hs8 hs9, k1 r hs9 hs8]

/-! ## The specification, for a message of whole blocks -/

/-- The block of padding the kernel builds, for a message of `L` bytes. -/
def padBlock (L : Nat) : List Byte :=
  [0x80] ++ List.replicate 59 0 ++
    [BitVec.ofNat 8 (8 * L / 2 ^ 24), BitVec.ofNat 8 (8 * L / 2 ^ 16), BitVec.ofNat 8 (8 * L / 2 ^ 8),
      BitVec.ofNat 8 (8 * L)]

theorem padBlock_length (L : Nat) : (padBlock L).length = 64 := by simp [padBlock]

set_option linter.unusedSimpArgs false in
/-- A message of whole blocks is padded with one block more. -/
theorem pad_whole (msg : List Byte) (h : msg.length % 64 = 0) (h32 : 8 * msg.length < 2 ^ 32) :
    pad msg = msg ++ padBlock msg.length := by
  simp only [pad, padBlock, h, Nat.sub_zero, List.append_assoc]
  congr 1
  simp only [List.range_succ, List.range_zero, List.nil_append, List.map_append, List.map_cons, List.map_nil,
    List.cons_append, List.singleton_append]
  rw [Nat.div_eq_of_lt (by omega : 8 * msg.length < 2 ^ (8 * (7 - 0))),
    Nat.div_eq_of_lt (by omega : 8 * msg.length < 2 ^ (8 * (7 - 1))),
    Nat.div_eq_of_lt (by omega : 8 * msg.length < 2 ^ (8 * (7 - 2))),
    Nat.div_eq_of_lt (by omega : 8 * msg.length < 2 ^ (8 * (7 - 3)))]
  simp only [show (55 + 64) % 64 = 55 from rfl, show 7 - 4 = 3 from rfl, show 7 - 5 = 2 from rfl,
    show 7 - 6 = 1 from rfl, show 7 - 7 = 0 from rfl, Nat.mul_zero, Nat.pow_zero, Nat.div_one]
  rfl

theorem blocks_length (m : List Byte) : (blocks m).length = m.length / 64 := by simp [blocks]

/-- The blocks of a message and one block more. -/
theorem blocks_snoc (a b : List Byte) (ha : a.length % 64 = 0) (hb : b.length = 64) :
    blocks (a ++ b) = blocks a ++ [b] := by
  simp only [blocks, List.length_append, hb]
  rw [show (a.length + 64) / 64 = a.length / 64 + 1 by omega, List.range_succ, List.map_append]
  congr 1
  · apply List.map_congr_left
    intro i hi
    rw [List.mem_range] at hi
    rw [List.drop_append_of_le_length (by omega), List.take_append_of_le_length (by simp; omega)]
  · simp only [List.map_cons, List.map_nil]
    rw [show 64 * (a.length / 64) = a.length by omega, List.drop_left, List.take_of_length_le (by omega)]

/-- **SHA-256 of whole blocks**: the message's blocks, then the padding block. -/
theorem sha256_whole (msg : List Byte) (h : msg.length % 64 = 0) (h32 : 8 * msg.length < 2 ^ 32) :
    sha256 msg = (compress ((blocks msg).foldl compress IV) (padBlock msg.length)).flatMap beBytes := by
  rw [sha256, pad_whole msg h h32, blocks_snoc _ _ h (padBlock_length _), List.foldl_append]
  rfl

/-- H after the first `i` blocks. -/
def hs (msg : List Byte) (i : Nat) : List W32 := ((blocks msg).take i).foldl compress IV

theorem compress_length (h : List W32) (b : List Byte) (hl : h.length = 8) : (compress h b).length = 8 := by
  simp [compress, St.toList, hl]

theorem hs_length (msg : List Byte) (i : Nat) : (hs msg i).length = 8 := by
  unfold hs
  generalize (blocks msg).take i = l
  suffices ∀ h : List W32, h.length = 8 → (l.foldl compress h).length = 8 from this IV rfl
  induction l with
  | nil => intro h hh; exact hh
  | cons b l ih => intro h hh; exact ih _ (compress_length h b hh)

/-- The block `i` of a message in memory is the 64 bytes at `64 i`. -/
theorem blocks_mem (m : Word → Byte) (a : Word) (L i : Nat) (hi : 64 * i + 64 ≤ L) :
    (blocks (readBytes m a L))[i]'(by rw [blocks_length, readBytes_length]; omega) =
      readBytes m (a + BitVec.ofNat 32 (64 * i)) 64 := by
  simp only [blocks, List.getElem_map, List.getElem_range]
  rw [show L = 64 * i + (64 + (L - 64 * i - 64)) by omega, readBytes_append, List.drop_left' (readBytes_length _ _ _),
    readBytes_append, List.take_left' (readBytes_length _ _ _)]

theorem hs_succ (m : Word → Byte) (a : Word) (L i : Nat) (hi : 64 * i + 64 ≤ L) :
    hs (readBytes m a L) (i + 1) = compress (hs (readBytes m a L) i) (readBytes m (a + BitVec.ofNat 32 (64 * i)) 64) := by
  unfold hs
  rw [List.take_add_one, List.getElem?_eq_getElem (by rw [blocks_length, readBytes_length]; omega), blocks_mem m a L i hi]
  simp [List.foldl_append]

theorem hs_all (msg : List Byte) : hs msg (msg.length / 64) = (blocks msg).foldl compress IV := by
  unfold hs; rw [List.take_of_length_le (by rw [blocks_length]; exact Nat.le_refl _)]

/-! ## Setup -/

theorem readBytes_eq_of {m : Word → Byte} {a : Word} {n : Nat} {l : List Byte} (hl : l.length = n)
    (h : ∀ d < n, m (a + BitVec.ofNat 32 d) = l.getD d 0) : readBytes m a n = l := by
  apply List.ext_getElem (by rw [readBytes_length, hl])
  intro d h1 h2
  rw [readBytes_getElem _ _ _ _ (by rw [readBytes_length] at h1; exact h1), h d (by rw [readBytes_length] at h1; exact h1),
    List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h2]
  rfl

/-- A byte written, read back at any address in the region. -/
theorem wb_at {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (m : Word → Byte) {c c' : Nat}
    (hc : c < 0x10000) (hc' : c' < 0x10000) (v : Byte) :
    writeByte m (base + BitVec.ofNat 32 c) v (base + BitVec.ofNat 32 c') =
      if c' = c then v else m (base + BitVec.ofNat 32 c') := by
  unfold writeByte
  by_cases h : c' = c
  · subst h; simp
  · have : base + BitVec.ofNat 32 c' ≠ base + BitVec.ofNat 32 c := fun e => h (by
      have := congrArg BitVec.toNat e; rw [toNat_off hfit _ hc', toNat_off hfit _ hc] at this; omega)
    simp [h, this]

theorem padBlock_mid (L d : Nat) (h1 : 1 ≤ d) (h2 : d < 60) : (padBlock L).getD d 0 = 0 := by
  unfold padBlock
  rw [List.getD_eq_getElem?_getD, List.getElem?_append_left (by simp; omega), List.getElem?_append_right (by simp; omega),
    List.getElem?_replicate]
  simp
  rw [ifT (show d - 1 < 59 by omega)]
  rfl

theorem at_ivCopy : ∀ j < 8,
    kernel.getD (4 + 2 * j) .ecall = .ld .lw T0 S1 (BitVec.ofNat 12 (0x100 + 4 * j)) ∧
    kernel.getD (4 + 2 * j + 1) .ecall = .st .sw S1 T0 (BitVec.ofNat 12 (0x200 + 4 * j)) := by
  decide

/-- **H from IV**: `lw t0, 0x100 + 4j(s1); sw t0, 0x200 + 4j(s1)` for `j < 8`. -/
theorem ivCopy_run {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 4))
    (h1 : s.reg S1 = base + BitVec.ofNat 32 0x1000) :
    ∀ j ≤ 8, ∃ s', run env (2 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (4 + 2 * j)) ∧
      Keeps (base + BitVec.ofNat 32 0x1200) 32 s.mem s'.mem ∧
      (∀ i < j, wordAt s'.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i)) =
        wordAt s.mem (base + BitVec.ofNat 32 (0x1100 + 4 * i))) ∧
      (∀ r, r ≠ T0 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, Keeps.refl _ _ _, fun i h => absurd h (Nat.not_lt_zero _), fun r _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, k1, w1, f1⟩ := ih (by omega)
    obtain ⟨a1, a2⟩ := at_ivCopy j (by omega)
    have c0 : CodeAt s1.mem base kernel := k1.code fit (by decide) (by decide) hcode
    have hS1 : s1.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [f1 _ (by decide), h1]
    obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp (4 + 2 * j) (by rw [kernel_length]; omega) c0 p1 a1
      (0x1100 + 4 * j) (by rw [hS1, se_small _ (by omega), off_add fit _ _ (by omega)]; congr 2; omega)
      (by omega) (by omega)
    obtain ⟨s3, e3, p3, m3, r3⟩ := storeStep hp (4 + 2 * j + 1) (by rw [kernel_length]; omega)
      (by rw [m2]; exact c0) p2 a2 (0x1200 + 4 * j)
      (by rw [reg_kept r2 (by decide), hS1, se_small _ (by omega), off_add fit _ _ (by omega)]; congr 2; omega)
      (by omega) (by omega)
    have vt : s2.reg T0 = wordAt s.mem (base + BitVec.ofNat 32 (0x1100 + 4 * j)) := by
      rw [reg_wrote r2 (by decide)]
      exact wordAt_keeps fit k1 (by decide) (by omega) (by omega)
    have mm : s3.mem = writeLE s1.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) (s2.reg T0).toNat 4 := by
      rw [m3, m2]
    refine ⟨s3, ?_, by rw [p3]; congr 2, ?_, ?_, ?_⟩
    · rw [show 2 * (j + 1) = 2 * j + (1 + 1) by omega, run_add_running e1, run_cons e2 e3]
    · rw [mm]; exact k1.trans (keeps_writeLE fit _ _ (by omega) (by omega) (by decide))
    · intro i hi
      rw [mm]
      rcases (by omega : i = j ∨ i < j) with h | h
      · subst h; rw [wordAt_same, vt]
      · rw [wordAt_other fit _ _ (by omega) (by omega) (by omega), w1 i h]
    · intro r hr
      rw [r3, reg_kept r2 hr, f1 r hr]

theorem at_zeroA : ∀ j < 8, kernel.getD (20 + j) .ecall = .st .sw S1 0 (BitVec.ofNat 12 (0x400 + 4 * j)) := by
  decide
theorem at_zeroB : ∀ j < 8, kernel.getD (28 + j) .ecall = .st .sw S1 0 (BitVec.ofNat 12 (0x420 + 4 * j)) := by
  decide

theorem imm_off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (d c : Nat) (hc : c < 2048)
    (hd : d + c < 0x10000) :
    base + BitVec.ofNat 32 d + (BitVec.ofNat 12 c).signExtend 32 = base + BitVec.ofNat 32 (d + c) := by
  rw [se_small c hc, off_add hfit _ _ hd]

theorem len_bits (L : Nat) (hL : 8 * L < 2 ^ 32) : (BitVec.ofNat 32 L <<< (3 : BitVec 5).toNat).toNat = 8 * L := by
  rw [BitVec.toNat_shiftLeft, BitVec.toNat_ofNat, Nat.shiftLeft_eq]
  simp only [show (3 : BitVec 5).toNat = 3 from rfl]
  rw [Nat.mod_eq_of_lt (show L < 2 ^ 32 by omega)]
  omega

theorem len_blocks (L : Nat) (hL : L < 2 ^ 32) :
    BitVec.ofNat 32 L >>> (6 : BitVec 5).toNat = BitVec.ofNat 32 (L / 64) := by
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow,
    show (6 : BitVec 5).toNat = 6 from rfl]
  rw [Nat.mod_eq_of_lt hL, Nat.mod_eq_of_lt (by omega)]

theorem shr_bits (x : Word) (n : BitVec 5) : (x >>> n.toNat).toNat = x.toNat / 2 ^ n.toNat := by
  simp [BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]

/-- **Setup**, 49 instructions: `s1` at `R`, `s4` at the message, H from IV,
the padding block built, `s5 = 0` and `s6` the message's block count. -/
theorem setup_run {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) {L : Nat}
    (hlen : wordAt s.mem (base + BitVec.ofNat 32 0x1120) = BitVec.ofNat 32 L) (hL : 8 * L < 2 ^ 32) :
    ∃ s', run env 49 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 49) ∧
      s'.reg S1 = base + BitVec.ofNat 32 0x1000 ∧ s'.reg S4 = base + BitVec.ofNat 32 0x2000 ∧
      s'.reg S5 = BitVec.ofNat 32 0 ∧ s'.reg S6 = BitVec.ofNat 32 (L / 64) ∧
      Keeps (base + BitVec.ofNat 32 0x1200) 0x240 s.mem s'.mem ∧
      (∀ j < 8, wordAt s'.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) =
        wordAt s.mem (base + BitVec.ofNat 32 (0x1100 + 4 * j))) ∧
      readBytes s'.mem (base + BitVec.ofNat 32 0x1400) 64 = padBlock L := by
  have fit := hp.fit
  -- the registers
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (i := .lui T1 1) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
      (i := .op .add S4 S1 T1) (by decide) rfl
  have mem4 : s4.mem = s.mem := by rw [m4, m3, m2, m1]
  have v1 : s4.reg S1 = base + BitVec.ofNat 32 0x1000 := by
    simp [r4, r3, r2, r1, hpc, S0, S1, S4, T1, aluR]
  have v4 : s4.reg S4 = base + BitVec.ofNat 32 0x2000 := by
    simp [r4, r3, r2, r1, hpc, S0, S1, S4, T1, aluR, BitVec.add_assoc]
  -- H from IV
  obtain ⟨sc, ec, pc, kc, wc, fc⟩ := ivCopy_run hp (by rw [mem4]; exact hcode) p4 v1 8 (Nat.le_refl _)
  have cc : CodeAt sc.mem base kernel := kc.code fit (by decide) (by decide) (by rw [mem4]; exact hcode)
  have vc1 : sc.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [fc _ (by decide), v1]
  -- the padding block, zeroed
  obtain ⟨z1, ez1, pz1, mz1, rz1⟩ := (zero_words (prog := kernel) hp (k0 := 20) (rd := S1) (o := 0x400)
    (a := 0x1000) at_zeroA (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    (by rw [kernel_length]; decide) pc cc vc1) 8 (Nat.le_refl _)
  have cz1 : CodeAt z1.mem base kernel := by
    rw [mz1]; exact code_of_overlay fit cc (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨z2, ez2, pz2, mz2, rz2⟩ := (zero_words (prog := kernel) hp (k0 := 28) (rd := S1) (o := 0x420)
    (a := 0x1000) at_zeroB (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    (by rw [kernel_length]; decide) pz1 cz1 (by rw [rz1, vc1])) 8 (Nat.le_refl _)
  have cz2 : CodeAt z2.mem base kernel := by
    rw [mz2]; exact code_of_overlay fit cz1 (by rw [kernel_length]; decide) (by decide) _
  have vz1 : z2.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [rz2, rz1, vc1]
  -- 0x80
  obtain ⟨t1, et1, pt1, mt1, rt1⟩ := regStep (prog := kernel) hp 36 (by decide) cz2 pz2
      (i := .opi .addi T0 0 0x80) (by decide) rfl
  obtain ⟨t2, et2, pt2, mt2, rt2⟩ := sbStep (prog := kernel) hp 37 (by decide) (by rw [mt1]; exact cz2) pt1
      (rs1 := S1) (rs2 := T0) (imm := BitVec.ofNat 12 0x400) (by decide) 0x1400
      (by rw [reg_kept rt1 (by decide), vz1, imm_off fit _ _ (by decide) (by decide)]) (by decide)
  have b80 : BitVec.ofNat 8 (t1.reg T0).toNat = 0x80 := by
    rw [reg_wrote rt1 (by decide)]; simp only [aluI, reg_zero]; decide
  have ct2 : CodeAt t2.mem base kernel := by
    rw [mt2, mt1]; exact code_of_writeByte fit cz2 (by rw [kernel_length]; decide) (by decide) _
  -- the length, in bits
  obtain ⟨t3, et3, pt3, mt3, rt3⟩ := loadStep (prog := kernel) hp 38 (by decide) ct2 pt2
      (rd := T0) (rs1 := S1) (imm := BitVec.ofNat 12 0x120) (by decide) 0x1120
      (by rw [rt2, reg_kept rt1 (by decide), vz1, imm_off fit _ _ (by decide) (by decide)]) (by decide) (by decide)
  obtain ⟨t4, et4, pt4, mt4, rt4⟩ := regStep (prog := kernel) hp 39 (by decide) (by rw [mt3]; exact ct2) pt3
      (i := .sh .slli T1 T0 3) (by decide) rfl
  -- the memory so far, against s's
  have kz : Keeps (base + BitVec.ofNat 32 0x1400) 0x40 sc.mem t2.mem := by
    rw [mt2, mt1, mz2, mz1]
    exact ((keeps_overlay fit _ _ (by decide) (by decide) (by decide)).trans
      (keeps_overlay fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))
  have kall : Keeps (base + BitVec.ofNat 32 0x1200) 0x240 s.mem t2.mem := by
    rw [← mem4]
    exact (kc.widen fit (Nat.le_refl _) (by decide) (by decide)).trans (kz.widen fit (by decide) (by decide) (by decide))
  have v0 : t3.reg T0 = BitVec.ofNat 32 L := by
    rw [reg_wrote rt3 (by decide)]
    have := wordAt_keeps fit kall (c := 0x1120) (by decide) (by decide) (by decide)
    unfold wordAt at this hlen
    rw [this, hlen]
  have vbits : (t4.reg T1).toNat = 8 * L := by
    rw [reg_wrote rt4 (by decide)]; simp only [shiftI]; rw [v0]; exact len_bits L hL
  have k4 : ∀ r, r ≠ T0 → r ≠ T1 → t4.reg r = z2.reg r := fun r h0 h1 => by
    rw [reg_kept rt4 h1, reg_kept rt3 h0, rt2, reg_kept rt1 h0]
  have ct4 : CodeAt t4.mem base kernel := by rw [mt4, mt3]; exact ct2
  -- the length's four bytes
  obtain ⟨t5, et5, pt5, mt5, rt5⟩ := regStep (prog := kernel) hp 40 (by decide) ct4 pt4
      (i := .sh .srli T2 T1 24) (by decide) rfl
  obtain ⟨t6, et6, pt6, mt6, rt6⟩ := sbStep (prog := kernel) hp 41 (by decide) (by rw [mt5]; exact ct4) pt5
      (rs1 := S1) (rs2 := T2) (imm := BitVec.ofNat 12 0x43c) (by decide) 0x143c
      (by rw [reg_kept rt5 (by decide), k4 _ (by decide) (by decide), vz1, imm_off fit _ _ (by decide) (by decide)])
      (by decide)
  obtain ⟨t7, et7, pt7, mt7, rt7⟩ := regStep (prog := kernel) hp 42 (by decide)
      (by rw [mt6, mt5]; exact code_of_writeByte fit ct4 (by rw [kernel_length]; decide) (by decide) _) pt6
      (i := .sh .srli T2 T1 16) (by decide) rfl
  have ct7 : CodeAt t7.mem base kernel := by
    rw [mt7, mt6, mt5]; exact code_of_writeByte fit ct4 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨t8, et8, pt8, mt8, rt8⟩ := sbStep (prog := kernel) hp 43 (by decide) ct7 pt7
      (rs1 := S1) (rs2 := T2) (imm := BitVec.ofNat 12 0x43d) (by decide) 0x143d
      (by rw [reg_kept rt7 (by decide), rt6, reg_kept rt5 (by decide), k4 _ (by decide) (by decide), vz1,
        imm_off fit _ _ (by decide) (by decide)]) (by decide)
  have ct8 : CodeAt t8.mem base kernel := by
    rw [mt8]; exact code_of_writeByte fit ct7 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨t9, et9, pt9, mt9, rt9⟩ := regStep (prog := kernel) hp 44 (by decide) ct8 pt8
      (i := .sh .srli T2 T1 8) (by decide) rfl
  obtain ⟨t10, et10, pt10, mt10, rt10⟩ := sbStep (prog := kernel) hp 45 (by decide) (by rw [mt9]; exact ct8) pt9
      (rs1 := S1) (rs2 := T2) (imm := BitVec.ofNat 12 0x43e) (by decide) 0x143e
      (by rw [reg_kept rt9 (by decide), rt8, reg_kept rt7 (by decide), rt6, reg_kept rt5 (by decide),
        k4 _ (by decide) (by decide), vz1, imm_off fit _ _ (by decide) (by decide)]) (by decide)
  have ct10 : CodeAt t10.mem base kernel := by
    rw [mt10, mt9]; exact code_of_writeByte fit ct8 (by rw [kernel_length]; decide) (by decide) _
  -- the regs t5 … t10 leave alone
  have k10 : ∀ r, r ≠ T2 → t10.reg r = t4.reg r := fun r h => by
    rw [rt10, reg_kept rt9 h, rt8, reg_kept rt7 h, rt6, reg_kept rt5 h]
  obtain ⟨t11, et11, pt11, mt11, rt11⟩ := sbStep (prog := kernel) hp 46 (by decide) ct10 pt10
      (rs1 := S1) (rs2 := T1) (imm := BitVec.ofNat 12 0x43f) (by decide) 0x143f
      (by rw [k10 _ (by decide), k4 _ (by decide) (by decide), vz1, imm_off fit _ _ (by decide) (by decide)])
      (by decide)
  have ct11 : CodeAt t11.mem base kernel := by
    rw [mt11]; exact code_of_writeByte fit ct10 (by rw [kernel_length]; decide) (by decide) _
  -- s6, s5
  obtain ⟨t12, et12, pt12, mt12, rt12⟩ := regStep (prog := kernel) hp 47 (by decide) ct11 pt11
      (i := .sh .srli S6 T0 6) (by decide) rfl
  obtain ⟨t13, et13, pt13, mt13, rt13⟩ := regStep (prog := kernel) hp 48 (by decide)
      (by rw [mt12]; exact ct11) pt12 (i := .opi .addi S5 0 0) (by decide) rfl
  have b24 : BitVec.ofNat 8 (t5.reg T2).toNat = BitVec.ofNat 8 (8 * L / 2 ^ 24) := by
    rw [reg_wrote rt5 (by decide)]; simp only [shiftI]; rw [shr_bits, vbits]; rfl
  have b16 : BitVec.ofNat 8 (t7.reg T2).toNat = BitVec.ofNat 8 (8 * L / 2 ^ 16) := by
    rw [reg_wrote rt7 (by decide)]; simp only [shiftI]; rw [rt6, reg_kept rt5 (by decide), shr_bits, vbits]; rfl
  have b8 : BitVec.ofNat 8 (t9.reg T2).toNat = BitVec.ofNat 8 (8 * L / 2 ^ 8) := by
    rw [reg_wrote rt9 (by decide)]; simp only [shiftI]
    rw [rt8, reg_kept rt7 (by decide), rt6, reg_kept rt5 (by decide), shr_bits, vbits]; rfl
  have b0 : BitVec.ofNat 8 (t10.reg T1).toNat = BitVec.ofNat 8 (8 * L) := by
    rw [k10 _ (by decide), vbits]
  have memF : t13.mem = writeByte (writeByte (writeByte (writeByte (writeByte z2.mem
      (base + BitVec.ofNat 32 0x1400) 0x80)
      (base + BitVec.ofNat 32 0x143c) (BitVec.ofNat 8 (8 * L / 2 ^ 24)))
      (base + BitVec.ofNat 32 0x143d) (BitVec.ofNat 8 (8 * L / 2 ^ 16)))
      (base + BitVec.ofNat 32 0x143e) (BitVec.ofNat 8 (8 * L / 2 ^ 8)))
      (base + BitVec.ofNat 32 0x143f) (BitVec.ofNat 8 (8 * L)) := by
    rw [mt13, mt12, mt11, mt10, mt9, mt8, mt7, mt6, mt5, mt4, mt3, mt2, mt1, b80, ← b24, ← b16, ← b8, ← b0]
  have kF : Keeps (base + BitVec.ofNat 32 0x1400) 0x40 sc.mem t13.mem := by
    rw [memF, mz2, mz1]
    exact ((((((keeps_overlay fit _ _ (by decide) (by decide) (by decide)).trans
      (keeps_overlay fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))).trans
      (keeps_writeByte fit _ _ (by decide) (by decide) (by decide))
  have tail : run env 13 z2 = .running t13 :=
    run_cons et1 (run_cons et2 (run_cons et3 (run_cons et4 (run_cons et5 (run_cons et6 (run_cons et7
      (run_cons et8 (run_cons et9 (run_cons et10 (run_cons et11 (run_cons et12 et13)))))))))))
  have kt : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ S5 → r ≠ S6 → t13.reg r = z2.reg r := fun r h0 h1 h2 h5 h6 => by
    rw [reg_kept rt13 h5, reg_kept rt12 h6, rt11, k10 r h2, k4 r h0 h1]
  refine ⟨t13, ?_, by rw [pt13], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · refine run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 ?_)))
    rw [show 45 = 2 * 8 + (8 + (8 + 13)) by rfl, run_add_running ec, run_add_running ez1, run_add_running ez2]
    exact tail
  · rw [kt _ (by decide) (by decide) (by decide) (by decide) (by decide), vz1]
  · rw [kt _ (by decide) (by decide) (by decide) (by decide) (by decide), rz2, rz1, fc _ (by decide), v4]
  · rw [reg_wrote rt13 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [reg_kept rt13 (by decide), reg_wrote rt12 (by decide)]
    simp only [shiftI]
    rw [rt11, k10 _ (by decide), reg_kept rt4 (by decide), v0, len_blocks L (by omega)]
  · rw [← mem4]
    exact (kc.widen fit (by decide) (by decide) (by decide)).trans (kF.widen fit (by decide) (by decide) (by decide))
  · intro j hj
    rw [wordAt_keeps fit kF (by decide) (by omega) (by omega), wc j hj, mem4]
  · rw [memF]
    apply readBytes_eq_of (padBlock_length L)
    intro d hd
    rw [off_add fit _ _ (by omega), wb_at fit _ (c := 0x143f) (by decide) (by omega),
      wb_at fit _ (c := 0x143e) (by decide) (by omega), wb_at fit _ (c := 0x143d) (by decide) (by omega),
      wb_at fit _ (c := 0x143c) (by decide) (by omega), wb_at fit _ (c := 0x1400) (by decide) (by omega)]
    rcases (by omega : d = 63 ∨ d = 62 ∨ d = 61 ∨ d = 60 ∨ d = 0 ∨ (1 ≤ d ∧ d < 60)) with h | h | h | h | h | h
    · subst h; rfl
    · subst h; rfl
    · subst h; rfl
    · subst h; rfl
    · subst h; rfl
    · rw [ifF (by omega), ifF (by omega), ifF (by omega), ifF (by omega), ifF (by omega), mz2, mz1,
        padBlock_mid L d h.1 h.2]
      by_cases h32 : 32 ≤ d
      · rw [overlay_off_in fit _ _ (by omega) (by omega) (by omega)]
      · rw [overlay_off_out fit _ _ (by omega) (by omega) (by omega), overlay_off_in fit _ _ (by omega) (by omega)
          (by omega)]

/-! ## The block loop -/

theorem slt_small (a b : Nat) (ha : a < 2 ^ 31) (hb : b < 2 ^ 31) :
    (BitVec.ofNat 32 a).slt (BitVec.ofNat 32 b) = decide (a < b) := by
  rw [BitVec.slt, BitVec.toInt_eq_toNat_cond, BitVec.toInt_eq_toNat_cond]
  simp only [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show a < 2 ^ 32 by omega),
    Nat.mod_eq_of_lt (show b < 2 ^ 32 by omega)]
  rw [ifT (by omega), ifT (by omega)]
  simp

theorem ofNat_ne (a b : Nat) (ha : a < 2 ^ 32) (hb : b < 2 ^ 32) (h : a ≠ b) :
    BitVec.ofNat 32 a ≠ BitVec.ofNat 32 b := by
  intro e; have := congrArg BitVec.toNat e
  rw [BitVec.toNat_ofNat, BitVec.toNat_ofNat, Nat.mod_eq_of_lt ha, Nat.mod_eq_of_lt hb] at this; exact h this

/-- `bne s5, s6`, taken: a block of the message is next. -/
theorem choose_msg {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 49)) {i n : Nat}
    (h5 : s.reg S5 = BitVec.ofNat 32 i) (h6 : s.reg S6 = BitVec.ofNat 32 n) (hi : i < n) (hn : n < 2 ^ 31) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 51) ∧ s'.mem = s.mem ∧
      ∀ r, s'.reg r = s.reg r := by
  have e : run env 1 s = .running (s.setPc (s.pc + ((4 : BitVec 12) ++ 0#1).signExtend 32)) :=
    (stepK (prog := kernel) hp 49 (by decide) hcode hpc (i := .br .bne S5 S6 4) (by decide)
      (exec_br_taken (by rw [h5, h6]; simp only [taken]; simp [ofNat_ne i n (by omega) (by omega) (by omega)])) 0).trans
      (run_zero _ _)
  refine ⟨_, e, ?_, setPc_mem _ _, fun r => setPc_reg _ _ r⟩
  simp only [setPc_pc, hpc]
  rw [BitVec.add_assoc]
  congr 1

/-- `bne s5, s6`, not taken: the padding block is next. -/
theorem choose_pad {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 49)) {n : Nat}
    (h5 : s.reg S5 = BitVec.ofNat 32 n) (h6 : s.reg S6 = BitVec.ofNat 32 n)
    (h1 : s.reg S1 = base + BitVec.ofNat 32 0x1000) :
    ∃ s', run env 2 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 51) ∧ s'.mem = s.mem ∧
      s'.reg S4 = base + BitVec.ofNat 32 0x1400 ∧ ∀ r, r ≠ S4 → s'.reg r = s.reg r := by
  have e : run env 1 s = .running s.next :=
    (stepK (prog := kernel) hp 49 (by decide) hcode hpc (i := .br .bne S5 S6 4) (by decide)
      (exec_br_not (by rw [h5, h6]; simp [taken])) 0).trans (run_zero _ _)
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 50 (by decide) (by rw [next_mem]; exact hcode)
    (by rw [next_pc, hpc]; exact pc_next hp.fit 49 (by decide)) (i := .opi .addi S4 S1 0x400) (by decide) rfl
  refine ⟨s2, run_cons e e2, p2, by rw [m2, next_mem], ?_, fun r hr => by rw [reg_kept r2 hr, next_reg]⟩
  rw [reg_wrote r2 (by decide)]
  simp only [aluI, next_reg, h1]
  rw [show (0x400 : BitVec 12) = BitVec.ofNat 12 0x400 from rfl, imm_off hp.fit _ _ (by decide) (by decide)]

/-- `addi s5, s5, 1; bge s6, s5`: back to the top while blocks remain. -/
theorem next_run {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 183)) {i n : Nat}
    (h5 : s.reg S5 = BitVec.ofNat 32 i) (h6 : s.reg S6 = BitVec.ofNat 32 n) (hi : i + 1 < 2 ^ 31)
    (hn : n < 2 ^ 31) :
    ∃ s', run env 2 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (if i + 1 ≤ n then 49 else 185)) ∧
      s'.mem = s.mem ∧ s'.reg S5 = BitVec.ofNat 32 (i + 1) ∧ ∀ r, r ≠ S5 → s'.reg r = s.reg r := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 183 (by decide) hcode hpc
    (i := .opi .addi S5 S5 1) (by decide) rfl
  have v5 : s1.reg S5 = BitVec.ofNat 32 (i + 1) := by
    rw [reg_wrote r1 (by decide)]; simp only [aluI, h5, se1]
    rw [show (1 : Word) = BitVec.ofNat 32 1 from rfl, BitVec.ofNat_add_ofNat]
  have v6 : s1.reg S6 = BitVec.ofNat 32 n := by rw [reg_kept r1 (by decide), h6]
  have c1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  have ht : taken .bge (s1.reg S6) (s1.reg S5) = decide (i + 1 ≤ n) := by
    rw [v5, v6]; simp only [taken]; rw [slt_small n (i + 1) hn hi]; simp only [Bool.not_eq_eq_eq_not]
    by_cases h : i + 1 ≤ n <;> simp [h] <;> omega
  by_cases hl : i + 1 ≤ n
  · have e2 : run env 1 s1 = .running (s1.setPc (s1.pc + ((0xef2 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 184 (by decide) c1 p1 (i := .br .bge S6 S5 0xef2) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine ⟨_, run_cons e1 e2, ?_, by rw [setPc_mem, m1], by rw [setPc_reg, v5],
      fun r hr => by rw [setPc_reg, reg_kept r1 hr]⟩
    simp only [hl, ↓reduceIte, setPc_pc, p1]
    rw [BitVec.add_assoc]
    congr 1
  · have e2 : run env 1 s1 = .running s1.next :=
      (stepK (prog := kernel) hp 184 (by decide) c1 p1 (i := .br .bge S6 S5 0xef2) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine ⟨_, run_cons e1 e2, ?_, by rw [next_mem, m1], by rw [next_reg, v5],
      fun r hr => by rw [next_reg, reg_kept r1 hr]⟩
    simp only [hl, ↓reduceIte, next_pc, p1]
    exact pc_next hp.fit 184 (by decide)

/-- The block loop at its top, `i` blocks of the message done. -/
structure BInv (base : Word) (m1 : Word → Byte) (msg : List Byte) (n i : Nat) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * 49)
  s1 : s.reg S1 = base + BitVec.ofNat 32 0x1000
  s4 : s.reg S4 = base + BitVec.ofNat 32 (0x2000 + 64 * i)
  s5 : s.reg S5 = BitVec.ofNat 32 i
  s6 : s.reg S6 = BitVec.ofNat 32 n
  keeps : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 m1 s.mem
  h : ∀ j < 8, wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) = (hs msg i).getD j 0

/-- A block, from the top of the loop to the top of the loop or past it:
choose, compress, next. -/
theorem block_iter {env : Env} {base : Word} (hp : Placed env base) {m1 : Word → Byte}
    (hc1 : CodeAt m1 base kernel) (hK : ∀ t < 64, wordAt m1 (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = K.getD t 0)
    {n : Nat} (hn : 0x2000 + 64 * n ≤ 0x10000) {i : Nat} (hi : i < n) {s : Machine}
    (h : BInv base m1 (readBytes m1 (base + BitVec.ofNat 32 0x2000) (64 * n)) n i s) :
    ∃ s', run env 4873 s = .running s' ∧ BInv base m1 (readBytes m1 (base + BitVec.ofNat 32 0x2000) (64 * n)) n (i + 1) s' := by
  have fit := hp.fit
  have c0 : CodeAt s.mem base kernel := h.keeps.code fit (by decide) (by decide) hc1
  obtain ⟨sa, ea, pa, ma, ra⟩ := choose_msg hp c0 h.pc h.s5 h.s6 hi (by omega)
  have ka : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 m1 sa.mem := by rw [ma]; exact h.keeps
  obtain ⟨sb, eb, pb, kb, wb, s4b, fb⟩ := block_step hp (by rw [ma]; exact c0) pa (by rw [ra, h.s1])
    (P := 0x2000 + 64 * i) (by rw [ra, h.s4]) (by omega) (by omega)
    (fun t ht => by rw [wordAt_keeps fit ka (by decide) (by omega) (by omega), hK t ht])
    (hs_length _ i) (fun j hj => by rw [ma]; exact h.h j hj)
  have kb' : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 m1 sb.mem := ka.trans kb
  have hb : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S4 → r ≠ S8 → r ≠ S9 → r ≠ S10 →
      (∀ i < 8, BitVec.ofNat 5 (10 + i) ≠ r) → sb.reg r = s.reg r := fun r a b c d e f g k l m => by
    rw [fb r a b c d e f g k l m, ra]
  have ar : ∀ r : Reg, r.toNat < 10 ∨ 18 ≤ r.toNat → ∀ i < 8, BitVec.ofNat 5 (10 + i) ≠ r :=
    fun r hr i hi => areg_ne_of r hr hi
  obtain ⟨sc, ec, pc, mc, s5c, fc⟩ := next_run hp (kb'.code fit (by decide) (by decide) hc1) pb
    (i := i) (n := n)
    (by rw [hb _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (ar _ (by decide)), h.s5])
    (by rw [hb _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (ar _ (by decide)), h.s6]) (by omega) (by omega)
  refine ⟨sc, ?_, ⟨?_, ?_, ?_, s5c, ?_, ?_, ?_⟩⟩
  · rw [show 4873 = 1 + (4870 + 2) by rfl, run_add_running ea, run_add_running eb]; exact ec
  · rw [pc, ifT (by omega)]
  · rw [fc _ (by decide), hb _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (ar _ (by decide)), h.s1]
  · rw [fc _ (by decide), s4b, show 0x2000 + 64 * i + 64 = 0x2000 + 64 * (i + 1) by omega]
  · rw [fc _ (by decide), hb _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (ar _ (by decide)), h.s6]
  · rw [mc]; exact kb'
  · intro j hj
    rw [mc, wb j hj, hs_succ m1 _ (64 * n) i (by omega), off_add fit _ _ (by omega),
      Keeps.bytes fit ka (by decide) (by omega) (by omega)]

/-- **The message's blocks**, by induction on blocks done. -/
theorem block_loop {env : Env} {base : Word} (hp : Placed env base) {m1 : Word → Byte}
    (hc1 : CodeAt m1 base kernel) (hK : ∀ t < 64, wordAt m1 (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = K.getD t 0)
    {n : Nat} (hn : 0x2000 + 64 * n ≤ 0x10000) {s : Machine}
    (h : BInv base m1 (readBytes m1 (base + BitVec.ofNat 32 0x2000) (64 * n)) n 0 s) :
    ∀ i ≤ n, ∃ s', run env (4873 * i) s = .running s' ∧
      BInv base m1 (readBytes m1 (base + BitVec.ofNat 32 0x2000) (64 * n)) n i s' := by
  intro i hi
  induction i with
  | zero => exact ⟨s, rfl, h⟩
  | succ i ih =>
    obtain ⟨s1, e1, h1⟩ := ih (by omega)
    obtain ⟨s2, e2, h2⟩ := block_iter hp hc1 hK hn (by omega) h1
    exact ⟨s2, by rw [show 4873 * (i + 1) = 4873 * i + 4873 by omega, run_add_running e1, e2], h2⟩

/-! ## The digest -/

theorem at_output : ∀ j < 8,
    kernel.getD (185 + 8 * j) .ecall = .ld .lw T0 S1 (BitVec.ofNat 12 (0x200 + 4 * j)) ∧
    kernel.getD (185 + 8 * j + 1) .ecall = .sh .srli T1 T0 24 ∧
    kernel.getD (185 + 8 * j + 2) .ecall = .st .sb S1 T1 (BitVec.ofNat 12 (0x140 + 4 * j)) ∧
    kernel.getD (185 + 8 * j + 3) .ecall = .sh .srli T1 T0 16 ∧
    kernel.getD (185 + 8 * j + 4) .ecall = .st .sb S1 T1 (BitVec.ofNat 12 (0x141 + 4 * j)) ∧
    kernel.getD (185 + 8 * j + 5) .ecall = .sh .srli T1 T0 8 ∧
    kernel.getD (185 + 8 * j + 6) .ecall = .st .sb S1 T1 (BitVec.ofNat 12 (0x142 + 4 * j)) ∧
    kernel.getD (185 + 8 * j + 7) .ecall = .st .sb S1 T0 (BitVec.ofNat 12 (0x143 + 4 * j)) := by
  decide

/-- **The digest out**: word `j` of H, big-endian, at `R + 0x140 + 4j`. -/
theorem output_run {env : Env} {base : Word} (hp : Placed env base) {s : Machine}
    (hcode : CodeAt s.mem base kernel) (hpc : s.pc = base + BitVec.ofNat 32 (4 * 185))
    (h1 : s.reg S1 = base + BitVec.ofNat 32 0x1000) :
    ∀ j ≤ 8, ∃ s', run env (8 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (185 + 8 * j)) ∧
      Keeps (base + BitVec.ofNat 32 0x1140) 32 s.mem s'.mem ∧
      (∀ i < j, readBytes s'.mem (base + BitVec.ofNat 32 (0x1140 + 4 * i)) 4 =
        beBytes (wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * i)))) ∧
      (∀ r, r ≠ T0 → r ≠ T1 → s'.reg r = s.reg r) := by
  have fit := hp.fit
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, Keeps.refl _ _ _, fun i h => absurd h (Nat.not_lt_zero _),
      fun r _ _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, k1, w1, f1⟩ := ih (by omega)
    obtain ⟨a0, a1, a2, a3, a4, a5, a6, a7⟩ := at_output j (by omega)
    have c1 : CodeAt s1.mem base kernel := k1.code fit (by decide) (by decide) hcode
    have hS1 : s1.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [f1 _ (by decide) (by decide), h1]
    have hk : ∀ d < 8, 185 + 8 * j + d < kernel.length := fun d hd => by rw [kernel_length]; omega
    obtain ⟨u0, g0, q0, n0, r0⟩ := loadStep hp (185 + 8 * j) (hk 0 (by decide)) c1 p1 a0 (0x1200 + 4 * j)
      (by rw [hS1, imm_off fit _ _ (by omega) (by omega)]; congr 2; omega) (by omega) (by omega)
    have x0 : u0.reg T0 = wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) := by
      rw [reg_wrote r0 (by decide)]; exact wordAt_keeps fit k1 (by decide) (by omega) (by omega)
    generalize hx : wordAt s.mem (base + BitVec.ofNat 32 (0x1200 + 4 * j)) = x at x0
    have s1_0 : u0.reg S1 = base + BitVec.ofNat 32 0x1000 := by rw [reg_kept r0 (by decide), hS1]
    have cu0 : CodeAt u0.mem base kernel := by rw [n0]; exact c1
    obtain ⟨u1, g1, q1, n1, r1⟩ := regStep hp (185 + 8 * j + 1) (hk 1 (by decide)) cu0 q0 a1 rfl
    obtain ⟨u2, g2, q2, n2, r2⟩ := sbStep hp (185 + 8 * j + 2) (hk 2 (by decide)) (by rw [n1]; exact cu0) q1 a2
      (0x1000 + (0x140 + 4 * j)) (by rw [reg_kept r1 (by decide), s1_0, imm_off fit _ _ (by omega) (by omega)])
      (by omega)
    have cu2 : CodeAt u2.mem base kernel := by
      rw [n2, n1]; exact code_of_writeByte fit cu0 (by rw [kernel_length]; omega) (by omega) _
    obtain ⟨u3, g3, q3, n3, r3⟩ := regStep hp (185 + 8 * j + 3) (hk 3 (by decide)) cu2 q2 a3 rfl
    obtain ⟨u4, g4, q4, n4, r4⟩ := sbStep hp (185 + 8 * j + 4) (hk 4 (by decide)) (by rw [n3]; exact cu2) q3 a4
      (0x1000 + (0x141 + 4 * j))
      (by rw [reg_kept r3 (by decide), r2, reg_kept r1 (by decide), s1_0, imm_off fit _ _ (by omega) (by omega)])
      (by omega)
    have cu4 : CodeAt u4.mem base kernel := by
      rw [n4, n3]; exact code_of_writeByte fit cu2 (by rw [kernel_length]; omega) (by omega) _
    obtain ⟨u5, g5, q5, n5, r5⟩ := regStep hp (185 + 8 * j + 5) (hk 5 (by decide)) cu4 q4 a5 rfl
    obtain ⟨u6, g6, q6, n6, r6⟩ := sbStep hp (185 + 8 * j + 6) (hk 6 (by decide)) (by rw [n5]; exact cu4) q5 a6
      (0x1000 + (0x142 + 4 * j))
      (by rw [reg_kept r5 (by decide), r4, reg_kept r3 (by decide), r2, reg_kept r1 (by decide), s1_0,
        imm_off fit _ _ (by omega) (by omega)]) (by omega)
    have cu6 : CodeAt u6.mem base kernel := by
      rw [n6, n5]; exact code_of_writeByte fit cu4 (by rw [kernel_length]; omega) (by omega) _
    have kT : ∀ r, r ≠ T1 → u6.reg r = u0.reg r := fun r h => by
      rw [r6, reg_kept r5 h, r4, reg_kept r3 h, r2, reg_kept r1 h]
    obtain ⟨u7, g7, q7, n7, r7⟩ := sbStep hp (185 + 8 * j + 7) (hk 7 (by decide)) cu6 q6 a7
      (0x1000 + (0x143 + 4 * j)) (by rw [kT _ (by decide), s1_0, imm_off fit _ _ (by omega) (by omega)]) (by omega)
    have B0 : BitVec.ofNat 8 (u1.reg T1).toNat = (beBytes x).getD 0 0 := by
      rw [reg_wrote r1 (by decide)]; simp only [shiftI]; rw [x0]; rfl
    have B1 : BitVec.ofNat 8 (u3.reg T1).toNat = (beBytes x).getD 1 0 := by
      rw [reg_wrote r3 (by decide)]; simp only [shiftI]; rw [r2, reg_kept r1 (by decide), x0]; rfl
    have B2 : BitVec.ofNat 8 (u5.reg T1).toNat = (beBytes x).getD 2 0 := by
      rw [reg_wrote r5 (by decide)]; simp only [shiftI]
      rw [r4, reg_kept r3 (by decide), r2, reg_kept r1 (by decide), x0]; rfl
    have B3 : BitVec.ofNat 8 (u6.reg T0).toNat = (beBytes x).getD 3 0 := by
      rw [kT _ (by decide), x0]; rfl
    have mm : u7.mem = writeByte (writeByte (writeByte (writeByte s1.mem
        (base + BitVec.ofNat 32 (0x1000 + (0x140 + 4 * j))) ((beBytes x).getD 0 0))
        (base + BitVec.ofNat 32 (0x1000 + (0x141 + 4 * j))) ((beBytes x).getD 1 0))
        (base + BitVec.ofNat 32 (0x1000 + (0x142 + 4 * j))) ((beBytes x).getD 2 0))
        (base + BitVec.ofNat 32 (0x1000 + (0x143 + 4 * j))) ((beBytes x).getD 3 0) := by
      rw [n7, n6, n5, n4, n3, n2, n1, n0, B0, B1, B2, B3]
    have kw : Keeps (base + BitVec.ofNat 32 (0x1140 + 4 * j)) 4 s1.mem u7.mem := by
      rw [mm]
      exact (((keeps_writeByte fit _ _ (by omega) (by omega) (by omega)).trans
        (keeps_writeByte fit _ _ (by omega) (by omega) (by omega))).trans
        (keeps_writeByte fit _ _ (by omega) (by omega) (by omega))).trans
        (keeps_writeByte fit _ _ (by omega) (by omega) (by omega))
    refine ⟨u7, ?_, by rw [q7]; congr 2, ?_, ?_, ?_⟩
    · rw [show 8 * (j + 1) = 8 * j + (1 + (1 + (1 + (1 + (1 + (1 + (1 + 1))))))) by omega, run_add_running e1,
        run_cons g0 (run_cons g1 (run_cons g2 (run_cons g3 (run_cons g4 (run_cons g5 (run_cons g6 g7))))))]
    · exact k1.trans (kw.widen fit (by omega) (by omega) (by decide))
    · intro i hi
      rcases (by omega : i = j ∨ i < j) with h | h
      · subst h
        rw [hx]
        apply readBytes_eq_of (by rfl)
        intro d hd
        rw [mm, off_add fit _ _ (by omega), wb_at fit _ (by omega) (by omega), wb_at fit _ (by omega) (by omega),
          wb_at fit _ (by omega) (by omega), wb_at fit _ (by omega) (by omega)]
        rcases (by omega : d = 0 ∨ d = 1 ∨ d = 2 ∨ d = 3) with e | e | e | e <;> subst e
        · rw [ifF (by omega), ifF (by omega), ifF (by omega), ifT (by omega)]
        · rw [ifF (by omega), ifF (by omega), ifT (by omega)]
        · rw [ifF (by omega), ifT (by omega)]
        · rw [ifT (by omega)]
      · rw [Keeps.bytes fit kw (by omega) (by omega) (by omega), w1 i h]
    · intro r h0 h1'
      rw [r7, kT r h1', reg_kept r0 h0, f1 r h0 h1']

theorem readBytes_words (m : Word → Byte) (a : Word) :
    ∀ n, readBytes m a (4 * n) = (List.range n).flatMap fun i => readBytes m (a + BitVec.ofNat 32 (4 * i)) 4
  | 0 => rfl
  | n + 1 => by
    rw [show 4 * (n + 1) = 4 * n + 4 by omega, readBytes_append, readBytes_words m a n, List.range_succ,
      List.flatMap_append]
    simp

theorem flatMap_words (l : List W32) (hl : l.length = 8) :
    l.flatMap beBytes = (List.range 8).flatMap fun i => beBytes (l.getD i 0) := by
  have : l = (List.range 8).map fun i => l.getD i 0 := by
    apply List.ext_getElem (by simp [hl])
    intro i h1 h2
    simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h1]
  conv => lhs; rw [this]
  rw [List.flatMap_map]

/-! ## The whole kernel -/

/-- **SHA-256, computed.** From `base`, with the kernel there, K and IV as
words at `R` and `R + 0x100`, and a message of `n` whole blocks at
`base + 0x2000` with its length in bytes at `R + 0x120`, the kernel halts with
0 after exactly `4990 + 4873 n` instructions, and the 32 bytes at `R + 0x140`
are `sha256` of the message. Nothing outside `R + 0x140 … R + 0x440` changes. -/
theorem computes {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel)
    (hK : ∀ t < 64, wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = K.getD t 0)
    (hIV : ∀ j < 8, wordAt s.mem (base + BitVec.ofNat 32 (0x1100 + 4 * j)) = IV.getD j 0)
    {n : Nat} (hlen : wordAt s.mem (base + BitVec.ofNat 32 0x1120) = BitVec.ofNat 32 (64 * n))
    (hn : 0x2000 + 64 * n ≤ 0x10000) :
    ∃ s', run env (4990 + 4873 * n) s = .halted 0 s' ∧
      readBytes s'.mem (base + BitVec.ofNat 32 0x1140) 32 =
        sha256 (readBytes s.mem (base + BitVec.ofNat 32 0x2000) (64 * n)) ∧
      Keeps (base + BitVec.ofNat 32 0x1140) 0x300 s.mem s'.mem := by
  have fit := hp.fit
  obtain ⟨s0, e0, p0, h1, h4, h5, h6, k0, w0, pad0⟩ := setup_run hp s hpc hcode hlen (by omega)
  have hc1 : CodeAt s0.mem base kernel := k0.code fit (by decide) (by decide) hcode
  have hK1 : ∀ t < 64, wordAt s0.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) = K.getD t 0 := fun t ht => by
    rw [wordAt_keeps fit k0 (by decide) (by omega) (by omega), hK t ht]
  have hmsg : readBytes s0.mem (base + BitVec.ofNat 32 0x2000) (64 * n) =
      readBytes s.mem (base + BitVec.ofNat 32 0x2000) (64 * n) := Keeps.bytes fit k0 (by decide) hn (by omega)
  generalize hm : readBytes s0.mem (base + BitVec.ofNat 32 0x2000) (64 * n) = msg at hmsg
  have B0 : BInv base s0.mem (readBytes s0.mem (base + BitVec.ofNat 32 0x2000) (64 * n)) n 0 s0 :=
    { pc := p0, s1 := h1, s4 := h4, s5 := h5
      s6 := by rw [h6, Nat.mul_div_cancel_left n (by decide)]
      keeps := Keeps.refl _ _ _
      h := fun j hj => by rw [w0 j hj, hIV j hj]; rfl }
  rw [hm] at B0
  obtain ⟨s2, e2, B⟩ := block_loop hp hc1 hK1 hn (by rw [hm]; exact B0) n (Nat.le_refl _)
  rw [hm] at B
  -- the padding block
  have c2 : CodeAt s2.mem base kernel := B.keeps.code fit (by decide) (by decide) hc1
  obtain ⟨sa, ea, pa, ma, s4a, fa⟩ := choose_pad hp c2 B.pc B.s5 B.s6 B.s1
  have ka : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 s0.mem sa.mem := by rw [ma]; exact B.keeps
  obtain ⟨sb, eb, pb, kb, wb, _, fb⟩ := block_step hp (by rw [ma]; exact c2) pa
    (by rw [fa _ (by decide), B.s1]) (P := 0x1400) s4a (by decide) (by decide)
    (fun t ht => by rw [wordAt_keeps fit ka (by decide) (by omega) (by omega), hK1 t ht])
    (hs_length msg n) (fun j hj => by rw [ma]; exact B.h j hj)
  have hpad : readBytes sa.mem (base + BitVec.ofNat 32 0x1400) 64 = padBlock (64 * n) := by
    rw [Keeps.bytes fit ka (by decide) (by decide) (by decide), pad0]
  rw [hpad] at wb
  have ar : ∀ r : Reg, r.toNat < 10 ∨ 18 ≤ r.toNat → ∀ i < 8, BitVec.ofNat 5 (10 + i) ≠ r :=
    fun r hr i hi => areg_ne_of r hr hi
  have fb' : ∀ r : Reg, r ≠ T0 → r ≠ T1 → r ≠ T2 → r ≠ T3 → r ≠ T4 → r ≠ S4 → r ≠ S8 → r ≠ S9 → r ≠ S10 →
      (r.toNat < 10 ∨ 18 ≤ r.toNat) → sb.reg r = s2.reg r := fun r a b c d e f g h i j => by
    rw [fb r a b c d e f g h i (ar r j), fa r f]
  have hcb : CodeAt sb.mem base kernel := (ka.trans kb).code fit (by decide) (by decide) hc1
  obtain ⟨sc, ec, pc, mc, _, fc⟩ := next_run hp hcb pb (i := n) (n := n)
    (by rw [fb' _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide), B.s5])
    (by rw [fb' _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide), B.s6]) (by omega) (by omega)
  have kc : Keeps (base + BitVec.ofNat 32 0x1200) 0x200 s0.mem sc.mem := by rw [mc]; exact ka.trans kb
  have hcc : CodeAt sc.mem base kernel := kc.code fit (by decide) (by decide) hc1
  -- the digest
  obtain ⟨so, eo, po, ko, wo, fo⟩ := output_run hp hcc (by rw [pc, ifF (by omega)])
    (by rw [fc _ (by decide), fb' _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide) (by decide), B.s1]) 8 (Nat.le_refl _)
  have hco : CodeAt so.mem base kernel := ko.code fit (by decide) (by decide) hcc
  obtain ⟨u1, g1, o1, l1, v1⟩ := regStep (prog := kernel) hp 249 (by decide) hco po
    (i := .opi .addi A0 0 0) (by decide) rfl
  obtain ⟨u2, g2, o2, l2, v2⟩ := regStep (prog := kernel) hp 250 (by decide) (by rw [l1]; exact hco) o1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : u2.reg T0 = 1 := by rw [reg_wrote v2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : u2.reg A0 = 0 := by
    rw [reg_kept v2 (by decide), reg_wrote v1 (by decide)]; simp only [aluI, reg_zero]; decide
  have halt : run env 1 u2 = .halted 0 u2 := by
    rw [← a0]
    exact (step_of_code (k := 251) (by rw [kernel_length]; decide) (by rw [l2, l1]; exact hco)
      (by rw [o2])
      (by rw [o2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [o2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[251]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])
  refine ⟨u2, ?_, ?_, ?_⟩
  · rw [show 4990 + 4873 * n = 49 + (4873 * n + (2 + (4870 + (2 + (8 * 8 + (1 + (1 + 1))))))) by omega,
      run_add_running e0, run_add_running e2, run_add_running ea, run_add_running eb, run_add_running ec,
      run_add_running eo, run_add_running g1, run_add_running g2]
    exact halt
  · have hl : msg.length = 64 * n := by rw [hmsg, readBytes_length]
    rw [← hmsg, sha256_whole msg (by rw [hl]; omega) (by rw [hl]; omega), ← hs_all, hl,
      Nat.mul_div_cancel_left n (by decide), flatMap_words _ (compress_length _ _ (hs_length msg n)),
      l2, l1, show readBytes so.mem (base + BitVec.ofNat 32 0x1140) 32 =
        readBytes so.mem (base + BitVec.ofNat 32 0x1140) (4 * 8) from rfl, readBytes_words]
    simp only [List.flatMap_def]
    congr 1
    apply List.map_congr_left
    intro i hi
    rw [List.mem_range] at hi
    rw [off_add fit _ _ (by omega), wo i hi, mc, wb i hi]
  · rw [l2, l1]
    exact (((k0.widen fit (by decide) (by decide) (by decide)).trans
      ((kc).widen fit (by decide) (by decide) (by decide))).trans (ko.widen fit (Nat.le_refl _) (by decide) (by decide)))

end Rv32.Sha
