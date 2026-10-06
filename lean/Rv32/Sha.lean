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

theorem ofNat_step (base : Word) (c : Nat) (hc : c + 4 < 2 ^ 32) :
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
    (by rw [line_add_T0, if_neg (by decide), r2, if_neg (by decide), seg1_keeps s S9 (by decide) (by decide)
          (by decide), hr.s9]; simp) (by omega) (by omega)
  have mem4 : s4.mem = s.mem := by rw [m4, line_mem, m2, line_mem]
  have c4 : CodeAt s4.mem base kernel := by rw [mem4]; exact hcode
  -- what s4 holds
  have k4 : ∀ r, r ≠ T0 → r ≠ T1 → r ≠ T2 → s4.reg r = s.reg r := by
    intro r h0 h1 h2
    rw [r4, if_neg (by simp [h1]), line_add_T0, if_neg h0, r2, if_neg (by simp [h1]), seg1_keeps s r h0 h1 h2]
  have v1 : s4.reg T1 = wordAt s.mem (base + BitVec.ofNat 32 (0x1300 + 4 * t)) := by
    rw [r4, if_pos (by decide), line_mem, m2, line_mem]; rfl
  have v0 : s4.reg T0 = s.reg A7 + bsig1 (s.reg A4) + ch (s.reg A4) (s.reg A5) (s.reg A6)
      + wordAt s.mem (base + BitVec.ofNat 32 (0x1000 + 4 * t)) := by
    rw [r4, if_neg (by decide), line_add_T0, if_pos rfl, r2, if_neg (by decide), r2, if_pos (by decide),
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
    · rw [b6, g9, ka S9 (by decide) (by decide) (by decide), hr.s9, ofNat_step base _ (by omega)]
      congr 2
    · rw [b6, g10, ka S10 (by decide) (by decide) (by decide), hr.s10, ofNat_step base _ (by omega)]
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

end Rv32.Sha
