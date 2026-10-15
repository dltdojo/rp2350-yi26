/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-4 — the state the generator keeps

SP 800-90A Rev. 1's Hash_DRBG (§10.1.1), with SHA-256 and seedlen = 440 bits
(55 bytes), keeps a state (V, C, reseed_counter). Its Generate, with no
additional input (§10.1.1.4):

1. if reseed_counter > reseed_interval, return "reseed required";
2. returned bits = Hashgen(V): Hash(V), Hash(V + 1), …;
3. H = Hash(0x03 ‖ V);
4. V = (V + H + C + reseed_counter) mod 2^440;
5. reseed_counter = reseed_counter + 1.

This kernel is that Generate, for `m` blocks of 32 bytes, with the hash as
`ecall HASHB`. Everything is a byte offset from `base`:

  0x400  m (a word), 0x404 reseed_interval, 0x408 reseed_counter
  0x43f  the byte 0x03, then V at 0x440 (55 bytes, big-endian)
  0x480  C        0x4c0  data, Hashgen's running V + i
  0x500  H, as 55 bytes: 23 zeros, then Hash(0x03 ‖ V) at 0x517
  0x540  reseed_counter, as 55 bytes: 51 zeros, then its 4 bytes at 0x573
  0x580  the number 1, as 55 bytes      0x600  the m blocks returned

   0       s0 = base
   1-3     t1 = interval, s3 = counter; interval <u counter → RESEED
   4-12    COPY: V to data, a byte at a time
   13-14   s1 = m, s2 = the first block's place
   15-25   GEN: HASHB(data, 55) to s2; data += 1 (ADD); s2 += 32; s1 -= 1
   26-30   HASHB(0x03 ‖ V, 56) to 0x517
   31-36   V += H (ADD); V += C (ADD)
   37-43   the counter's 4 bytes, big-endian, to 0x573
   44-46   V += counter (ADD)
   47-51   counter += 1, stored; HALT 0
   52-54   RESEED: HALT 1
   55-69   ADD: the 55 bytes at a0 += the 55 at a1, from the last byte up,
           a carry in a3; back through ra
-/
import Rv32.Asm
import Rv32.Flow
import Rv32.Health
import Rv32.Ct

set_option maxRecDepth 20000

namespace Drbg
open Rv32 Rv32.Health

def RA : Reg := 1
def A3 : Reg := 13
def A4 : Reg := 14

/-- Instruction `k`'s branch to instruction `t`. -/
def br (op : BrOp) (a b : Reg) (k t : Int) : Instr := .br op a b (BitVec.ofInt 12 (2 * (t - k)))
def call (k t : Int) : Instr := .jal RA (BitVec.ofInt 20 (2 * (t - k)))

def kernel : List Instr := [
  /- 0 -/ .auipc S0 0,
  /- 1 -/ .ld .lw T1 S0 0x404, .ld .lw S3 S0 0x408, br .bltu T1 S3 3 52,
  /- 4 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x4c0, .opi .addi T2 0 55,
  /- 7 -/ .ld .lbu T1 A0 0, .st .sb A1 T1 0, .opi .addi A0 A0 1, .opi .addi A1 A1 1,
  /- 11 -/ .opi .addi T2 T2 0xfff, br .bne T2 0 12 7,
  /- 13 -/ .ld .lw S1 S0 0x400, .opi .addi S2 S0 0x600,
  /- 15 -/ .opi .addi A0 S0 0x4c0, .opi .addi A1 0 55, .opi .addi A2 S2 0, .opi .addi T0 0 2, .ecall,
  /- 20 -/ .opi .addi A0 S0 0x4c0, .opi .addi A1 S0 0x580, call 22 55,
  /- 23 -/ .opi .addi S2 S2 32, .opi .addi S1 S1 0xfff, br .bne S1 0 25 15,
  /- 26 -/ .opi .addi A0 S0 0x43f, .opi .addi A1 0 56, .opi .addi A2 S0 0x517, .opi .addi T0 0 2, .ecall,
  /- 31 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x500, call 33 55,
  /- 34 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x480, call 36 55,
  /- 37 -/ .sh .srli T1 S3 24, .st .sb S0 T1 0x573, .sh .srli T1 S3 16, .st .sb S0 T1 0x574,
  /- 41 -/ .sh .srli T1 S3 8, .st .sb S0 T1 0x575, .st .sb S0 S3 0x576,
  /- 44 -/ .opi .addi A0 S0 0x440, .opi .addi A1 S0 0x540, call 46 55,
  /- 47 -/ .opi .addi S3 S3 1, .st .sw S0 S3 0x408, .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall,
  /- 52 -/ .opi .addi A0 0 1, .opi .addi T0 0 1, .ecall,
  /- 55 -/ .opi .addi A0 A0 54, .opi .addi A1 A1 54, .opi .addi T2 0 55, .opi .addi A3 0 0,
  /- 59 -/ .ld .lbu T1 A0 0, .ld .lbu A4 A1 0, .op .add T1 T1 A4, .op .add T1 T1 A3, .st .sb A0 T1 0,
  /- 64 -/ .sh .srli A3 T1 8, .opi .addi A0 A0 0xfff, .opi .addi A1 A1 0xfff, .opi .addi T2 T2 0xfff,
  /- 68 -/ br .bne T2 0 68 59, .jalr 0 RA 0 ]

theorem kernel_length : kernel.length = 70 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-! ## The arithmetic of a 55-byte number

`N`'s byte `i` of 55, big-endian, is `N / 256^(54 - i)`, truncated to a
byte. A field holds `N` when its 55 bytes are those. Adding from the last
byte up, with a carry: the digit and the carry at each step. -/

theorem div_sum (a b P : Nat) (hP : 0 < P) : (a + b) / P = a / P + b / P + (a % P + b % P) / P := by
  have ha := Nat.div_add_mod a P
  have hb := Nat.div_add_mod b P
  have e : a + b = (a % P + b % P) + P * (a / P + b / P) := by rw [Nat.mul_add]; omega
  rw [e, Nat.add_mul_div_left _ _ hP]; omega

theorem add_digit (a b P : Nat) (hP : 0 < P) :
    (a + b) / P % 256 = (a / P % 256 + b / P % 256 + (a % P + b % P) / P) % 256 := by
  rw [div_sum a b P hP]
  generalize a / P = x; generalize b / P = y; generalize (a % P + b % P) / P = c
  omega

theorem carry_le (a b P : Nat) (hP : 0 < P) : (a % P + b % P) / P ≤ 1 := by
  have := Nat.mod_lt a hP; have := Nat.mod_lt b hP
  exact Nat.le_of_lt_succ ((Nat.div_lt_iff_lt_mul hP).mpr (by omega))

theorem add_carry (a b P : Nat) (hP : 0 < P) :
    (a % (P * 256) + b % (P * 256)) / (P * 256)
      = (a / P % 256 + b / P % 256 + (a % P + b % P) / P) / 256 := by
  rw [Nat.mod_mul, Nat.mod_mul]
  have e : a % P + P * (a / P % 256) + (b % P + P * (b / P % 256))
      = (a % P + b % P) % P + P * (a / P % 256 + b / P % 256 + (a % P + b % P) / P) := by
    have := Nat.div_add_mod (a % P + b % P) P
    rw [Nat.mul_add, Nat.mul_add]; omega
  rw [e, ← Nat.div_div_eq_div_mul, Nat.add_mul_div_left _ _ hP, Nat.div_eq_of_lt (Nat.mod_lt _ hP), Nat.zero_add]

/-- The carry into byte `54 - k`, `k` bytes from the end. -/
def carry (a b k : Nat) : Nat := (a % 256 ^ k + b % 256 ^ k) / 256 ^ k

/-! ## The region, byte by byte

`View m base F`: every byte of the region is `F` of its offset. Each kind of
write changes `F` in one place. -/

def View (m : Word → Byte) (base : Word) (F : Nat → Byte) : Prop :=
  ∀ o, o < 0x10000 → m (base + BitVec.ofNat 32 o) = F o

/-- `F` with byte `c` set to `v`. -/
def setB (F : Nat → Byte) (c : Nat) (v : Byte) : Nat → Byte := fun o => if o = c then v else F o

/-- `F` with the 55 bytes from `X` holding `N`. -/
def setF (F : Nat → Byte) (X N : Nat) : Nat → Byte := fun o =>
  if X ≤ o ∧ o < X + 55 then BitVec.ofNat 8 (N / 256 ^ (X + 54 - o)) else F o

/-- The 55 bytes from `X` hold `N`. -/
def Holds (F : Nat → Byte) (X N : Nat) : Prop := ∀ i, i < 55 → F (X + i) = BitVec.ofNat 8 (N / 256 ^ (54 - i))

variable {base : Word}

/-- Two places past `base` are the same exactly when their offsets are. -/
theorem off_eq (hfit : base.toNat + 0x10000 ≤ 2^32) {a b : Nat} (ha : a < 0x10000) (hb : b < 0x10000) :
    (base + BitVec.ofNat 32 a = base + BitVec.ofNat 32 b) ↔ a = b := by
  constructor
  · intro e
    have := congrArg BitVec.toNat e
    rwa [toNat_off hfit a ha, toNat_off hfit b hb, Nat.add_left_cancel_iff] at this
  · intro e; rw [e]

theorem view_writeByte (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {c : Nat} (hc : c < 0x10000) (v : Byte) :
    View (writeByte m (base + BitVec.ofNat 32 c) v) base (setB F c v) := by
  intro o ho
  simp only [writeByte, setB, off_eq hfit ho hc]
  split
  · rfl
  · exact hv o ho

theorem setF_holds (F : Nat → Byte) (X N : Nat) : Holds (setF F X N) X N := by
  intro i hi
  simp only [setF, show X ≤ X + i ∧ X + i < X + 55 by omega, and_self, ↓reduceIte]
  rw [show X + 54 - (X + i) = 54 - i by omega]

/-- How far `base + o` is past `base + c`, round the 32-bit circle. -/
theorem dist_view (hfit : base.toNat + 0x10000 ≤ 2^32) {o c : Nat} (ho : o < 0x10000) (hc : c < 0x10000) :
    (base + BitVec.ofNat 32 o - (base + BitVec.ofNat 32 c)).toNat = if c ≤ o then o - c else 2 ^ 32 - (c - o) := by
  rw [toNat_sub_off hfit _ c hc, toNat_off hfit o ho]
  have hb := base.isLt
  rw [show 2 ^ 32 - (base.toNat + c) + (base.toNat + o) = 2 ^ 32 - c + o by omega,
    wrapdist c o (by omega) (by omega)]
  split <;> omega

/-- `F` with the 32 bytes from `c` those of `f`. -/
def setH (F : Nat → Byte) (c : Nat) (f : Fin 32 → Byte) : Nat → Byte := fun o =>
  if h : c ≤ o ∧ o < c + 32 then f ⟨o - c, by omega⟩ else F o

theorem view_writeBytes (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {c : Nat} (hc : c + 32 ≤ 0x10000) (f : Fin 32 → Byte) :
    View (writeBytes m (base + BitVec.ofNat 32 c) f) base (setH F c f) := by
  intro o ho
  simp only [writeBytes, dist_view hfit ho (show c < 0x10000 by omega)]
  by_cases h1 : c ≤ o ∧ o < c + 32
  · simp only [h1.1, ↓reduceIte, show o - c < 32 by omega, ↓reduceDIte, setH, h1, and_self]
  · rw [show setH F c f o = F o by simp only [setH]; exact dite_eq_right_iff.mpr (fun h => absurd h h1)]
    by_cases h2 : c ≤ o
    · simp only [h2, ↓reduceIte, show ¬ o - c < 32 by omega, ↓reduceDIte]; exact hv o ho
    · simp only [h2, ↓reduceIte, show ¬ 2 ^ 32 - (c - o) < 32 by omega, ↓reduceDIte]; exact hv o ho

/-- `n` bytes read from the region are `F`'s. -/
theorem readBytes_view (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {n : Nat} : ∀ c, c + n ≤ 0x10000 →
    readBytes m (base + BitVec.ofNat 32 c) n = (List.range n).map (fun d => F (c + d)) := by
  induction n with
  | zero => intro c _; rfl
  | succ n ih =>
    intro c hc
    rw [readBytes, List.range_succ_eq_map, List.map_cons, List.map_map, hv c (by omega), Nat.add_zero]
    rcases Nat.eq_zero_or_pos n with rfl | hn
    · rfl
    rw [show (1 : Word) = BitVec.ofNat 32 1 from rfl, off_add hfit c 1 (by omega), ih (c + 1) (by omega)]
    congr 1; apply List.map_congr_left; intro d _; simp only [Function.comp, Nat.add_assoc, Nat.add_comm 1]

/-- `N` as its 55 bytes, big-endian. -/
def digs (N : Nat) : List Byte := (List.range 55).map (fun i => BitVec.ofNat 8 (N / 256 ^ (54 - i)))

theorem read_holds (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {X N : Nat} (hX : X + 55 ≤ 0x10000) (h : Holds F X N) :
    readBytes m (base + BitVec.ofNat 32 X) 55 = digs N := by
  rw [readBytes_view hfit hv X hX, digs]
  apply List.map_congr_left; intro d hd; exact h d (List.mem_range.mp hd)

theorem setF_setF (F : Nat → Byte) (X N K : Nat) : setF (setF F X N) X K = setF F X K := by
  funext o; simp only [setF]; split <;> rfl

/-- `F` with the 4 bytes from `c` holding `n`, little-endian: a `sw`. -/
def setW (F : Nat → Byte) (c n : Nat) : Nat → Byte := fun o =>
  if c ≤ o ∧ o < c + 4 then BitVec.ofNat 8 (n / 256 ^ (o - c)) else F o

theorem view_writeLE (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {c : Nat} (hc : c + 4 ≤ 0x10000) (n : Nat) :
    View (writeLE m (base + BitVec.ofNat 32 c) n 4) base (setW F c n) := by
  intro o ho
  rw [writeLE_apply _ _ _ _ (by decide), dist_view hfit ho (by omega)]
  simp only [setW]
  by_cases h1 : c ≤ o ∧ o < c + 4
  · simp only [h1.1, ↓reduceIte, show o - c < 4 by omega, h1, and_self]
  · simp only [h1, ↓reduceIte]
    by_cases h2 : c ≤ o
    · simp only [h2, ↓reduceIte, show ¬ o - c < 4 by omega]; exact hv o ho
    · simp only [h2, ↓reduceIte, show ¬ 2 ^ 32 - (c - o) < 4 by omega]; exact hv o ho

/-- The word at `c`, little-endian, as `lw` reads it. -/
def word (F : Nat → Byte) (c : Nat) : Nat :=
  (F c).toNat + 256 * (F (c + 1)).toNat + 65536 * (F (c + 2)).toNat + 16777216 * (F (c + 3)).toNat

theorem readLE_view (hfit : base.toNat + 0x10000 ≤ 2^32) {m : Word → Byte} {F : Nat → Byte}
    (hv : View m base F) {c : Nat} (hc : c + 4 ≤ 0x10000) : readLE m (base + BitVec.ofNat 32 c) 4 = word F c := by
  rw [readLE_four, word, hv c (by omega), show (1 : Word) = BitVec.ofNat 32 1 from rfl,
    show (2 : Word) = BitVec.ofNat 32 2 from rfl, show (3 : Word) = BitVec.ofNat 32 3 from rfl,
    off_add hfit _ _ (by omega), off_add hfit _ _ (by omega), off_add hfit _ _ (by omega),
    hv _ (by omega), hv _ (by omega), hv _ (by omega)]

theorem View.congr {m : Word → Byte} {F G : Nat → Byte} (hv : View m base F)
    (h : ∀ o, o < 0x10000 → F o = G o) : View m base G := fun o ho => (hv o ho).trans (h o ho)

/-- A step back, as `addi r, r, -1` takes it. -/
theorem off_dec {c : Nat} (h1 : 1 ≤ c) (hc : c < 0x10000) :
    base + BitVec.ofNat 32 c + (0xfff : BitVec 12).signExtend 32 = base + BitVec.ofNat 32 (c - 1) := by
  rw [BitVec.add_assoc, count_down c h1 (by omega)]

theorem ofNat8_eq {n k : Nat} (h : n % 256 = k % 256) : BitVec.ofNat 8 n = BitVec.ofNat 8 k := by
  apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_ofNat]; omega

theorem hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide

variable {env : Env}

/-! ## ADD: the 55 bytes at `a0` += the 55 at `a1` -/

/-- The field at `X`, `k` bytes of the sum written from the end. -/
def addView (F : Nat → Byte) (X a b k : Nat) : Nat → Byte := fun o =>
  if X + 55 - k ≤ o ∧ o < X + 55 then BitVec.ofNat 8 ((a + b) / 256 ^ (X + 54 - o)) else F o

/-- At LOOP with `k` bytes added, or at the `jalr` once all 55 have been. -/
structure AInv (base : Word) (F : Nat → Byte) (X Y a b k : Nat) (keep : Reg → Word) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if k < 55 then 59 else 69))
  mem : View s.mem base (addView F X a b k)
  a0 : s.reg A0 = base + BitVec.ofNat 32 (X + 54 - k)
  a1 : s.reg A1 = base + BitVec.ofNat 32 (Y + 54 - k)
  t2 : s.reg T2 = BitVec.ofNat 32 (55 - k)
  a3 : s.reg A3 = BitVec.ofNat 32 (carry a b k)
  kept : ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ T2 → r ≠ A3 → s.reg r = keep r

/-- Where ADD may work: two fields of 55 bytes, apart, above the kernel. -/
structure Fields (X Y : Nat) : Prop where
  x : 4 * 70 ≤ X ∧ X + 55 ≤ 0x10000
  y : 4 * 70 ≤ Y ∧ Y + 55 ≤ 0x10000
  apart : X + 55 ≤ Y ∨ Y + 55 ≤ X

/-- Memory that agrees with the image on the kernel's 280 bytes holds the kernel. -/
theorem code_of_view (hp : Placed env base) {M0 m : Word → Byte} {F0 G : Nat → Byte}
    (hc0 : CodeAt M0 base kernel) (hv0 : View M0 base F0) (hv : View m base G)
    (hG : ∀ o, o < 4 * 70 → G o = F0 o) : CodeAt m base kernel :=
  Ct.code_keep hp.fit hlen (fun o' ho' => by
    rw [kernel_length] at ho'
    rw [hv o' (by omega), hv0 o' (by omega), hG o' ho']) hc0

theorem lbu_val {s s1 : Machine} {rd : Reg} {v : Word} {r : Reg}
    (h : ∀ r', s1.reg r' = if r' = rd ∧ rd ≠ 0 then v else s.reg r') (hr : r = rd) (hz : rd ≠ 0) :
    s1.reg r = v := by subst hr; exact reg_wrote h hz

theorem add_iter (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {X Y a b : Nat} (hf : Fields X Y)
    (ha : Holds F X a) (hb : Holds F Y b) {keep : Reg → Word} {k : Nat} (hk : k < 55) {s : Machine}
    (h : AInv base F X Y a b k keep s) :
    ∃ s', run env 10 s = .running s' ∧ AInv base F X Y a b (k + 1) keep s' := by
  obtain ⟨⟨hX1, hX2⟩, ⟨hY1, hY2⟩, hap⟩ := hf
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 59) := by rw [h.pc]; simp [hk]
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 h.mem (fun o ho => by
    simp only [addView, show ¬ (X + 55 - k ≤ o ∧ o < X + 55) by omega, ↓reduceIte]; exact hFc o ho)
  have hP : 0 < 256 ^ k := Nat.pow_pos (by decide)
  -- lbu t1, 0(a0): byte 54 - k of X, not yet written
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep hp 59 (by rw [kernel_length]; decide) hcode hpc
    (rd := T1) (rs1 := A0) (imm := 0) rfl (X + 54 - k)
    (by rw [h.a0, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]) (by omega) hlen
  have vx : s1.reg T1 = BitVec.ofNat 32 (a / 256 ^ k % 256) := by
    rw [reg_wrote r1 (by decide), h.mem _ (by omega)]
    simp only [addView, show ¬ (X + 55 - k ≤ X + 54 - k ∧ X + 54 - k < X + 55) by omega, ↓reduceIte]
    rw [show X + 54 - k = X + (54 - k) by omega, ha (54 - k) (by omega), show 54 - (54 - k) = k by omega]
    simp
  -- lbu a4, 0(a1): byte 54 - k of Y, apart from X
  have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := lbuStep hp 60 (by rw [kernel_length]; decide) hc1 p1
    (rd := A4) (rs1 := A1) (imm := 0) rfl (Y + 54 - k)
    (by rw [reg_kept r1 (by decide), h.a1, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero])
    (by omega) hlen
  have vy : s2.reg A4 = BitVec.ofNat 32 (b / 256 ^ k % 256) := by
    rw [reg_wrote r2 (by decide), m1, h.mem _ (by omega)]
    simp only [addView, show ¬ (X + 55 - k ≤ Y + 54 - k ∧ Y + 54 - k < X + 55) by omega, ↓reduceIte]
    rw [show Y + 54 - k = Y + (54 - k) by omega, hb (54 - k) (by omega), show 54 - (54 - k) = k by omega]
    simp
  have k2 : ∀ r, r ≠ T1 → r ≠ A4 → s2.reg r = s.reg r := fun r h1 h4 => by
    rw [reg_kept r2 h4, reg_kept r1 h1]
  -- t1 = x + y + carry
  have hc2 : CodeAt s2.mem base kernel := by rw [m2]; exact hc1
  have e3 := run_line hp [.op .add T1 T1 A4, .op .add T1 T1 A3] (by decide) 61 s2 (by decide)
    (by rw [kernel_length]; decide) hc2 p2 hlen
  generalize hs3 : s2.line [.op .add T1 T1 A4, .op .add T1 T1 A3] = s3 at e3
  have hcar := carry_le a b (256 ^ k) hP
  have t3 : s3.reg T1 = BitVec.ofNat 32 (a / 256 ^ k % 256 + b / 256 ^ k % 256 + carry a b k) := by
    have : s3.reg T1 = s2.reg T1 + s2.reg A4 + s2.reg A3 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluR, T1, A4, A3]
    rw [this, vy, reg_kept r2 (show T1 ≠ A4 by decide), vx, k2 A3 (by decide) (by decide), h.a3,
      ← BitVec.ofNat_add, ← BitVec.ofNat_add]
  have k3 : ∀ r, r ≠ T1 → s3.reg r = s2.reg r := fun r hr => by
    rw [← hs3]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> exact fun e => hr e.symm
  have p3 : s3.pc = base + BitVec.ofNat 32 (4 * (61 + 2)) := by rw [← hs3]; exact line_pc_at _ p2 (by decide)
  have ms3 : s3.mem = s.mem := by rw [← hs3, line_mem, m2, m1]
  -- sb t1, 0(a0)
  have a0s : s3.reg A0 = base + BitVec.ofNat 32 (X + 54 - k) := by
    rw [k3 A0 (by decide), k2 A0 (by decide) (by decide), h.a0]
  obtain ⟨s4, e4, p4, m4, r4⟩ := sbStep hp 63 (by rw [kernel_length]; decide) (by rw [ms3]; exact hcode) p3
    (rs1 := A0) (rs2 := T1) (imm := 0) rfl (X + 54 - k)
    (by rw [a0s, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]) (by omega) hlen
  generalize hn : a / 256 ^ k % 256 + b / 256 ^ k % 256 + carry a b k = n at t3
  have hn5 : n < 512 := by
    have := Nat.mod_lt (a / 256 ^ k) (show 0 < 256 by decide)
    have := Nat.mod_lt (b / 256 ^ k) (show 0 < 256 by decide)
    simp only [carry] at hn; omega
  have mv4 : View s4.mem base (addView F X a b (k + 1)) := by
    rw [m4, ms3, t3]
    refine (view_writeByte hp.fit h.mem (by omega) _).congr (fun o ho => ?_)
    simp only [setB, addView]
    by_cases ho1 : o = X + 54 - k
    · subst ho1
      simp only [↓reduceIte, show X + 55 - (k + 1) ≤ X + 54 - k ∧ X + 54 - k < X + 55 by omega, and_self]
      rw [show X + 54 - (X + 54 - k) = k by omega, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
      apply ofNat8_eq
      rw [add_digit a b _ hP, ← hn]; simp only [carry]
    · simp only [ho1, ↓reduceIte]
      by_cases h2 : X + 55 - (k + 1) ≤ o ∧ o < X + 55
      · simp only [h2, show X + 55 - k ≤ o ∧ o < X + 55 by omega, and_self, ↓reduceIte]
      · simp only [h2, show ¬ (X + 55 - k ≤ o ∧ o < X + 55) by omega, ↓reduceIte]
  -- srli a3, t1, 8; and the pointers and the count, one back
  have hc4 : CodeAt s4.mem base kernel := code_of_view hp hc0 hv0 mv4 (fun o ho => by
    simp only [addView, show ¬ (X + 55 - (k + 1) ≤ o ∧ o < X + 55) by omega, ↓reduceIte]; exact hFc o ho)
  have e5 := run_line hp [.sh .srli A3 T1 8, .opi .addi A0 A0 0xfff, .opi .addi A1 A1 0xfff, .opi .addi T2 T2 0xfff]
    (by decide) 64 s4 (by decide) (by rw [kernel_length]; decide) hc4 p4 hlen
  generalize hs5 : s4.line [.sh .srli A3 T1 8, .opi .addi A0 A0 0xfff, .opi .addi A1 A1 0xfff,
    .opi .addi T2 T2 0xfff] = s5 at e5
  have g3 : s5.reg A3 = BitVec.ofNat 32 (carry a b (k + 1)) := by
    have : s5.reg A3 = s4.reg T1 >>> 8 := by
      rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, shiftI, aluI, T1, A3, A0, A1, T2]
    have hc : carry a b (k + 1) = n / 256 := by
      rw [← hn]; simp only [carry]; rw [Nat.pow_succ]; exact add_carry a b _ hP
    rw [this, r4, t3, hc]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, BitVec.toNat_ofNat, Nat.shiftRight_eq_div_pow,
      Nat.mod_eq_of_lt (show n < 2 ^ 32 by omega), Nat.mod_eq_of_lt (show n / 256 < 2 ^ 32 by omega)]
  have k4 : ∀ r, s4.reg r = s.reg r ∨ r = T1 ∨ r = A4 := fun r => by
    by_cases h1 : r = T1
    · exact Or.inr (Or.inl h1)
    · by_cases h4 : r = A4
      · exact Or.inr (Or.inr h4)
      · left; rw [r4, k3 r h1, k2 r h1 h4]
  have s4of : ∀ r, r ≠ T1 → r ≠ A4 → s4.reg r = s.reg r := fun r h1 h4 => by rw [r4, k3 r h1, k2 r h1 h4]
  have g0 : s5.reg A0 = base + BitVec.ofNat 32 (X + 54 - (k + 1)) := by
    have : s5.reg A0 = s4.reg A0 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, shiftI, aluI, T1, A3, A0, A1, T2]
    rw [this, s4of A0 (by decide) (by decide), h.a0, off_dec (by omega) (by omega), Nat.sub_sub]
  have g1 : s5.reg A1 = base + BitVec.ofNat 32 (Y + 54 - (k + 1)) := by
    have : s5.reg A1 = s4.reg A1 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, shiftI, aluI, T1, A3, A0, A1, T2]
    rw [this, s4of A1 (by decide) (by decide), h.a1, off_dec (by omega) (by omega), Nat.sub_sub]
  have g2 : s5.reg T2 = BitVec.ofNat 32 (55 - (k + 1)) := by
    have : s5.reg T2 = s4.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, shiftI, aluI, T1, A3, A0, A1, T2]
    rw [this, s4of T2 (by decide) (by decide), h.t2, count_down _ (by omega) (by omega), Nat.sub_sub]
  have k5 : ∀ r, r ≠ A3 → r ≠ A0 → r ≠ A1 → r ≠ T2 → s5.reg r = s4.reg r := fun r h3 h0 h1 h2 => by
    rw [← hs5]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => h3 e.symm | exact fun e => h0 e.symm | exact fun e => h1 e.symm | exact fun e => h2 e.symm
  have p5 : s5.pc = base + BitVec.ofNat 32 (4 * (64 + 4)) := by rw [← hs5]; exact line_pc_at _ p4 (by decide)
  have hc5 : CodeAt s5.mem base kernel := by rw [← hs5, line_mem]; exact hc4
  -- bne t2, zero → LOOP
  obtain ⟨s6, e6, p6, m6, r6⟩ := brStep hp 68 (by rw [kernel_length]; decide) hc5 p5
    (op := .bne) (rs1 := T2) (rs2 := 0) (off := BitVec.ofInt 12 (2 * (59 - 68 : Int))) rfl (k' := 59) (by decide) hlen
  have tk : taken .bne (s5.reg T2) (s5.reg 0) = decide (k + 1 < 55) := by
    rw [g2, show s5.reg 0 = 0 from reg_zero _]
    by_cases hlt : k + 1 < 55
    · have : BitVec.ofNat 32 (55 - (k + 1)) ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; simp at this; omega
      simp only [taken, hlt, decide_true]; exact bne_iff_ne.mpr this
    · rw [show 55 - (k + 1) = 0 by omega]; simp only [taken, hlt, decide_false]; decide
  have e3' : run env 2 s2 = .running s3 := e3
  have e5' : run env 4 s4 = .running s5 := e5
  refine ⟨s6, ?_, ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 10 = 1 + (1 + (2 + (1 + (4 + 1)))) by rfl, run_add_running e1, run_add_running e2, run_add_running e3',
      run_add_running e4, run_add_running e5', e6]
  · rw [p6, tk]; by_cases hlt : k + 1 < 55 <;> simp [hlt]
  · rw [m6, ← hs5, line_mem]; exact mv4
  · rw [r6, g0]
  · rw [r6, g1]
  · rw [r6, g2]
  · rw [r6, g3]
  · intro r a b' c d e f
    rw [r6, k5 r f c d e, s4of r a b', h.kept r a b' c d e f]

theorem add_loop (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {X Y a b : Nat} (hf : Fields X Y)
    (ha : Holds F X a) (hb : Holds F Y b) {keep : Reg → Word} {s : Machine}
    (h : AInv base F X Y a b 0 keep s) :
    ∀ j, j ≤ 55 → ∃ s', run env (10 * j) s = .running s' ∧ AInv base F X Y a b j keep s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := add_iter hp hc0 hv0 hFc hf ha hb (by omega) hs'
    exact ⟨s'', by rw [show 10 * (j + 1) = 10 * j + 10 by omega, run_add_running e, e'], hs''⟩

theorem addView_done (F : Nat → Byte) (X a b : Nat) : addView F X a b 55 = setF F X (a + b) := by
  funext o; simp only [addView, setF, Nat.add_sub_cancel]

/-- Instructions for one ADD, from its first instruction through its `jalr`. -/
def ADD : Nat := 4 + 10 * 55 + 1

/-- **ADD**: entered with `a0` at a field holding `a` and `a1` at one holding
`b`, it returns through `ra` with the first holding `a + b` — mod 2^440,
which is what a field can hold — and every other byte as it was. -/
theorem add_run (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {X Y a b : Nat} (hf : Fields X Y)
    (ha : Holds F X a) (hb : Holds F Y b) {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * 55))
    (hmem : View s.mem base F) (ha0 : s.reg A0 = base + BitVec.ofNat 32 X)
    (ha1 : s.reg A1 = base + BitVec.ofNat 32 Y) {ret : Nat} (hret : s.reg RA = base + BitVec.ofNat 32 (4 * ret))
    (hr : 4 * ret < 0x10000) :
    ∃ s', run env ADD s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * ret) ∧ View s'.mem base (setF F X (a + b))
      ∧ ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ T2 → r ≠ A3 → s'.reg r = s.reg r := by
  have hf' := hf
  obtain ⟨⟨hX1, hX2⟩, ⟨hY1, hY2⟩, _⟩ := hf'
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 hmem hFc
  have e1 := run_line hp [.opi .addi A0 A0 54, .opi .addi A1 A1 54, .opi .addi T2 0 55, .opi .addi A3 0 0]
    (by decide) 55 s (by decide) (by rw [kernel_length]; decide) hcode hpc hlen
  generalize hs1 : s.line [.opi .addi A0 A0 54, .opi .addi A1 A1 54, .opi .addi T2 0 55, .opi .addi A3 0 0]
    = s1 at e1
  have q : ∀ r, s1.reg r = if r = A3 then 0 else if r = T2 then BitVec.ofNat 32 55
      else if r = A1 then s.reg A1 + (54 : BitVec 12).signExtend 32
      else if r = A0 then s.reg A0 + (54 : BitVec 12).signExtend 32 else s.reg r := by
    intro r; rw [← hs1]
    by_cases h3 : r = A3
    · subst h3; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, A3]
    · by_cases h2 : r = T2
      · subst h2; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, A3]
      · by_cases h1 : r = A1
        · subst h1; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, A3]
        · by_cases h0 : r = A0
          · subst h0; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, A3]
          · simp only [h3, h2, h1, h0, ↓reduceIte]
            refine line_keeps _ _ r (fun i hi => ?_)
            simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
            rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
              first | exact fun e => h0 e.symm | exact fun e => h1 e.symm | exact fun e => h2 e.symm | exact fun e => h3 e.symm
  have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (55 + 4)) := by rw [← hs1]; exact line_pc_at _ hpc (by decide)
  have se54 : (54 : BitVec 12).signExtend 32 = BitVec.ofNat 32 54 := by decide
  have h0 : AInv base F X Y a b 0 s.reg s1 := by
    refine ⟨by rw [p1]; rfl, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · rw [← hs1, line_mem]
      exact hmem.congr (fun o ho => by simp only [addView, Nat.sub_zero]; split <;> first | omega | rfl)
    · rw [q, ite_eq_right_of_eq_false _ _ (show (A0 = A3) = False by decide),
        ite_eq_right_of_eq_false _ _ (show (A0 = T2) = False by decide), ite_eq_right_of_eq_false _ _ (show (A0 = A1) = False by decide),
        ite_eq_left_of_eq_true _ _ (show (A0 = A0) = True by simp), ha0, se54, off_add hp.fit _ _ (by omega), Nat.sub_zero]
    · rw [q, ite_eq_right_of_eq_false _ _ (show (A1 = A3) = False by decide),
        ite_eq_right_of_eq_false _ _ (show (A1 = T2) = False by decide), ite_eq_left_of_eq_true _ _ (show (A1 = A1) = True by simp),
        ha1, se54, off_add hp.fit _ _ (by omega), Nat.sub_zero]
    · rw [q, ite_eq_right_of_eq_false _ _ (show (T2 = A3) = False by decide), ite_eq_left_of_eq_true _ _ (show (T2 = T2) = True by simp)]
    · rw [q]; simp [carry, Nat.mod_one]
    · intro r _ _ a0 a1 t2 a3; rw [q]; simp [a0, a1, t2, a3]
  obtain ⟨s2, e2, h2⟩ := add_loop hp hc0 hv0 hFc hf ha hb h0 55 (Nat.le_refl _)
  have p2 : s2.pc = base + BitVec.ofNat 32 (4 * 69) := by rw [h2.pc]; simp
  have hm2 := h2.mem
  rw [addView_done] at hm2
  have hc2 : CodeAt s2.mem base kernel := code_of_view hp hc0 hv0 hm2 (fun o ho => by
    simp only [setF, show ¬ (X ≤ o ∧ o < X + 55) by omega, ↓reduceIte]; exact hFc o ho)
  obtain ⟨s3, e3, p3, m3, r3⟩ := jalrStep hp 69 (by rw [kernel_length]; decide) hc2 p2 (rs := RA) rfl (k' := ret)
    (by rw [h2.kept RA (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), hret]) hr hlen
  refine ⟨s3, ?_, p3, by rw [m3]; exact hm2, fun r a b' c d e f => ?_⟩
  · have e1' : run env 4 s = .running s1 := e1
    rw [show ADD = 4 + (10 * 55 + 1) by rfl, run_add_running e1', run_add_running e2, e3]
  · rw [r3, h2.kept r a b' c d e f]

/-! ## A hash as a number -/

/-- The number whose `k` big-endian digits are `g 0`, …, `g (k - 1)`. -/
def beN (g : Nat → Nat) : Nat → Nat
  | 0 => 0
  | k + 1 => beN g k * 256 + g k

theorem beN_lt (g : Nat → Nat) (hg : ∀ d, g d < 256) : ∀ k, beN g k < 256 ^ k := by
  intro k
  induction k with
  | zero => simp [beN]
  | succ k ih => simp only [beN, Nat.pow_succ]; have := hg k; omega

theorem beN_digit (g : Nat → Nat) (hg : ∀ d, g d < 256) :
    ∀ k d, d < k → beN g k / 256 ^ (k - 1 - d) % 256 = g d := by
  intro k
  induction k with
  | zero => intro d hd; omega
  | succ k ih =>
    intro d hd
    have hk := hg k
    by_cases e : d = k
    · subst e; simp only [beN, Nat.add_sub_cancel, Nat.sub_self, Nat.pow_zero, Nat.div_one]; omega
    · rw [show k + 1 - 1 - d = (k - 1 - d) + 1 by omega, Nat.pow_succ, Nat.mul_comm (256 ^ _) 256,
        ← Nat.div_div_eq_div_mul, beN, show (beN g k * 256 + g k) / 256 = beN g k by omega]
      exact ih d (by omega)

/-- A hash's 32 bytes, as a number. -/
def hnum (h : Fin 32 → Byte) : Nat := beN (fun d => if hd : d < 32 then (h ⟨d, hd⟩).toNat else 0) 32

/-- A field of 23 zeros and then a hash's 32 bytes holds the hash's number. -/
theorem holds_hash {F : Nat → Byte} {X : Nat} {h : Fin 32 → Byte} (hz : ∀ i, i < 23 → F (X + i) = 0)
    (hh : ∀ d (hd : d < 32), F (X + 23 + d) = h ⟨d, hd⟩) : Holds F X (hnum h) := by
  have hg : ∀ d, (fun d => if hd : d < 32 then (h ⟨d, hd⟩).toNat else 0) d < 256 := by
    intro d; simp only; split
    · exact (h _).isLt
    · decide
  intro i hi
  by_cases h23 : i < 23
  · rw [hz i h23]
    have : hnum h < 256 ^ (54 - i) := Nat.lt_of_lt_of_le (beN_lt _ hg 32)
      (Nat.pow_le_pow_right (by decide) (by omega))
    rw [Nat.div_eq_of_lt this]; rfl
  · rw [show X + i = X + 23 + (i - 23) by omega, hh (i - 23) (by omega)]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_ofNat, show 54 - i = 32 - 1 - (i - 23) by omega, hnum, beN_digit _ hg 32 (i - 23) (by omega)]
    simp only [show i - 23 < 32 by omega, ↓reduceDIte]

/-- A field of 51 zeros and then a word's 4 bytes, big-endian, holds the word. -/
theorem holds_word {F : Nat → Byte} {X n : Nat} (hn : n < 2 ^ 32) (hz : ∀ i, i < 51 → F (X + i) = 0)
    (hw : ∀ d, d < 4 → F (X + 51 + d) = BitVec.ofNat 8 (n / 256 ^ (3 - d))) : Holds F X n := by
  intro i hi
  by_cases h51 : i < 51
  · have hp : 2 ^ 32 ≤ 256 ^ (54 - i) :=
      calc 2 ^ 32 = 256 ^ 4 := by rfl
        _ ≤ 256 ^ (54 - i) := Nat.pow_le_pow_right (by decide) (by omega)
    rw [hz i h51, Nat.div_eq_of_lt (by omega)]; rfl
  · rw [show X + i = X + 51 + (i - 51) by omega, hw (i - 51) (by omega), show 54 - i = 3 - (i - 51) by omega]

/-! ## The places -/

def PAR : Nat := 0x400
def PRE : Nat := 0x43f
def VV : Nat := 0x440
def CC : Nat := 0x480
def DATA : Nat := 0x4c0
def HB : Nat := 0x500
def CB : Nat := 0x540
def ONE : Nat := 0x580
def OUT : Nat := 0x600

/-! ## COPY: V to data, a byte at a time -/

def copyView (F : Nat → Byte) (i : Nat) : Nat → Byte := fun o =>
  if DATA ≤ o ∧ o < DATA + i then F (VV + (o - DATA)) else F o

structure CInv (base : Word) (F : Nat → Byte) (i : Nat) (keep : Reg → Word) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 55 then 7 else 13))
  mem : View s.mem base (copyView F i)
  a0 : s.reg A0 = base + BitVec.ofNat 32 (VV + i)
  a1 : s.reg A1 = base + BitVec.ofNat 32 (DATA + i)
  t2 : s.reg T2 = BitVec.ofNat 32 (55 - i)
  kept : ∀ r, r ≠ T1 → r ≠ A0 → r ≠ A1 → r ≠ T2 → s.reg r = keep r

theorem copy_iter (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {keep : Reg → Word} {i : Nat} (hi : i < 55)
    {s : Machine} (h : CInv base F i keep s) :
    ∃ s', run env 6 s = .running s' ∧ CInv base F (i + 1) keep s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 7) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 h.mem (fun o ho => by
    simp only [copyView, DATA, show ¬ (0x4c0 ≤ o ∧ o < 0x4c0 + i) by omega, ↓reduceIte]; exact hFc o ho)
  obtain ⟨s1, e1, p1, m1, r1⟩ := lbuStep hp 7 (by rw [kernel_length]; decide) hcode hpc
    (rd := T1) (rs1 := A0) (imm := 0) rfl (VV + i)
    (by rw [h.a0, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]) (by simp only [VV]; omega) hlen
  have vx : s1.reg T1 = BitVec.ofNat 32 (F (VV + i)).toNat := by
    rw [reg_wrote r1 (by decide), h.mem _ (by simp only [VV]; omega)]
    simp only [copyView, DATA, VV, show ¬ (0x4c0 ≤ 0x440 + i ∧ 0x440 + i < 0x4c0 + i) by omega, ↓reduceIte]
  obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep hp 8 (by rw [kernel_length]; decide) (by rw [m1]; exact hcode) p1
    (rs1 := A1) (rs2 := T1) (imm := 0) rfl (DATA + i)
    (by rw [reg_kept r1 (by decide), h.a1, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero])
    (by simp only [DATA]; omega) hlen
  have mv2 : View s2.mem base (copyView F (i + 1)) := by
    rw [m2, m1, vx]
    refine (view_writeByte hp.fit h.mem (by simp only [DATA]; omega) _).congr (fun o ho => ?_)
    simp only [setB, copyView]
    by_cases ho1 : o = DATA + i
    · subst ho1
      simp only [↓reduceIte, show DATA ≤ DATA + i ∧ DATA + i < DATA + (i + 1) by omega, and_self,
        Nat.add_sub_cancel_left]
      apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_ofNat]
      have := (F (VV + i)).isLt; omega
    · simp only [ho1, ↓reduceIte]
      by_cases h2 : DATA ≤ o ∧ o < DATA + (i + 1)
      · simp only [h2, show DATA ≤ o ∧ o < DATA + i by omega, and_self, ↓reduceIte]
      · simp only [h2, show ¬ (DATA ≤ o ∧ o < DATA + i) by omega, ↓reduceIte]
  have hc2 : CodeAt s2.mem base kernel := code_of_view hp hc0 hv0 mv2 (fun o ho => by
    simp only [copyView, DATA, show ¬ (0x4c0 ≤ o ∧ o < 0x4c0 + (i + 1)) by omega, ↓reduceIte]; exact hFc o ho)
  have e3 := run_line hp [.opi .addi A0 A0 1, .opi .addi A1 A1 1, .opi .addi T2 T2 0xfff] (by decide) 9 s2
    (by decide) (by rw [kernel_length]; decide) hc2 p2 hlen
  generalize hs3 : s2.line [.opi .addi A0 A0 1, .opi .addi A1 A1 1, .opi .addi T2 T2 0xfff] = s3 at e3
  have k2 : ∀ r, r ≠ T1 → s2.reg r = s.reg r := fun r hr => by rw [r2, reg_kept r1 hr]
  have se1 : (1 : BitVec 12).signExtend 32 = BitVec.ofNat 32 1 := by decide
  have g0 : s3.reg A0 = base + BitVec.ofNat 32 (VV + (i + 1)) := by
    have : s3.reg A0 = s2.reg A0 + (1 : BitVec 12).signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2]
    rw [this, k2 A0 (by decide), h.a0, se1, off_add hp.fit _ _ (by simp only [VV]; omega)]; rfl
  have g1 : s3.reg A1 = base + BitVec.ofNat 32 (DATA + (i + 1)) := by
    have : s3.reg A1 = s2.reg A1 + (1 : BitVec 12).signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2]
    rw [this, k2 A1 (by decide), h.a1, se1, off_add hp.fit _ _ (by simp only [DATA]; omega)]; rfl
  have g2 : s3.reg T2 = BitVec.ofNat 32 (55 - (i + 1)) := by
    have : s3.reg T2 = s2.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2]
    rw [this, k2 T2 (by decide), h.t2, count_down _ (by omega) (by omega), Nat.sub_sub]
  have k3 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ T2 → s3.reg r = s2.reg r := fun r h0 h1 h2 => by
    rw [← hs3]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => h0 e.symm | exact fun e => h1 e.symm | exact fun e => h2 e.symm
  have p3 : s3.pc = base + BitVec.ofNat 32 (4 * (9 + 3)) := by rw [← hs3]; exact line_pc_at _ p2 (by decide)
  have hc3 : CodeAt s3.mem base kernel := by rw [← hs3, line_mem]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := brStep hp 12 (by rw [kernel_length]; decide) hc3 p3
    (op := .bne) (rs1 := T2) (rs2 := 0) (off := BitVec.ofInt 12 (2 * (7 - 12 : Int))) rfl (k' := 7) (by decide) hlen
  have tk : taken .bne (s3.reg T2) (s3.reg 0) = decide (i + 1 < 55) := by
    rw [g2, show s3.reg 0 = 0 from reg_zero _]
    by_cases hlt : i + 1 < 55
    · have : BitVec.ofNat 32 (55 - (i + 1)) ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; simp at this; omega
      simp only [taken, hlt, decide_true]; exact bne_iff_ne.mpr this
    · rw [show 55 - (i + 1) = 0 by omega]; simp only [taken, hlt, decide_false]; decide
  have e3' : run env 3 s2 = .running s3 := e3
  refine ⟨s4, ?_, ⟨?_, ?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 6 = 1 + (1 + (3 + 1)) by rfl, run_add_running e1, run_add_running e2, run_add_running e3', e4]
  · rw [p4, tk]; by_cases hlt : i + 1 < 55 <;> simp [hlt]
  · rw [m4, ← hs3, line_mem]; exact mv2
  · rw [r4, g0]
  · rw [r4, g1]
  · rw [r4, g2]
  · intro r a b c d
    rw [r4, k3 r b c d, k2 r a, h.kept r a b c d]

theorem copy_done (F : Nat → Byte) {v : Nat} (hv : Holds F VV v) : copyView F 55 = setF F DATA v := by
  funext o; simp only [copyView, setF]
  split
  · rename_i h
    rw [hv (o - DATA) (by omega), show 54 - (o - DATA) = DATA + 54 - o by omega]
  · rfl

/-! ## GEN: Hashgen's blocks -/

/-- `F` with the first `j` blocks written: block `i` at `OUT + 32i` is the
hash of `v + i`, as 55 bytes. -/
def blocks (env : Env) (F : Nat → Byte) (v : Nat) : Nat → Nat → Byte
  | 0 => F
  | j + 1 => setH (blocks env F v j) (OUT + 32 * j) (env.hash (digs (v + j)))

/-- At GEN with `j` blocks made, or at the H step once all `m` have been. -/
structure GInv (env : Env) (base : Word) (F : Nat → Byte) (v m j : Nat) (keep : Reg → Word) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if j < m then 15 else 26))
  mem : View s.mem base (setF (blocks env F v j) DATA (v + j))
  s1 : s.reg S1 = BitVec.ofNat 32 (m - j)
  s2 : s.reg S2 = base + BitVec.ofNat 32 (OUT + 32 * j)
  kept : ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T2 → r ≠ A3 → r ≠ T0 → r ≠ RA → r ≠ S1 → r ≠ S2 →
    s.reg r = keep r

theorem blocks_low (F : Nat → Byte) (v : Nat) : ∀ j o, o < OUT → blocks env F v j o = F o := by
  intro j o ho
  induction j with
  | zero => rfl
  | succ j ih => simp only [blocks, setH, show ¬ (OUT + 32 * j ≤ o ∧ o < OUT + 32 * j + 32) by omega,
      ↓reduceDIte, ih]

theorem gen_iter (hp : Placed env base) {M0 : Word → Byte} {F0 : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) {F : Nat → Byte} (hFl : ∀ o, o < OUT → F o = F0 o) (hone : Holds F0 ONE 1)
    {v m : Nat} (hm : OUT + 32 * m < 0x10000) {keep : Reg → Word} (k0 : keep S0 = base)
    {j : Nat} (hj : j < m) {s : Machine} (h : GInv env base F v m j keep s) :
    ∃ s', run env (566) s = .running s' ∧ GInv env base F v m (j + 1) keep s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 15) := by rw [h.pc]; simp [hj]
  have hlow : ∀ o, o < 4 * 70 → setF (blocks env F v j) DATA (v + j) o = F0 o := fun o ho => by
    simp only [setF, DATA, show ¬ (0x4c0 ≤ o ∧ o < 0x4c0 + 55) by omega, ↓reduceIte]
    rw [blocks_low F v j o (by simp only [OUT]; omega), hFl o (by simp only [OUT]; omega)]
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 h.mem hlow
  have s0 : s.reg S0 = base := by
    rw [h.kept S0 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide), k0]
  -- the HASHB call's arguments
  have e1 := run_line hp [.opi .addi A0 S0 0x4c0, .opi .addi A1 0 55, .opi .addi A2 S2 0, .opi .addi T0 0 2]
    (by decide) 15 s (by decide) (by rw [kernel_length]; decide) hcode hpc hlen
  generalize hs1 : s.line [.opi .addi A0 S0 0x4c0, .opi .addi A1 0 55, .opi .addi A2 S2 0, .opi .addi T0 0 2]
    = s1 at e1
  have q1 : s1.reg A0 = base + BitVec.ofNat 32 DATA := by
    have : s1.reg A0 = s.reg S0 + (0x4c0 : BitVec 12).signExtend 32 := by
      rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0, S2]
    rw [this, s0]; rfl
  have q2 : s1.reg A1 = BitVec.ofNat 32 55 := by
    rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0, S2]
  have q3 : s1.reg A2 = base + BitVec.ofNat 32 (OUT + 32 * j) := by
    have : s1.reg A2 = s.reg S2 + (0 : BitVec 12).signExtend 32 := by
      rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0, S2]
    rw [this, h.s2, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]
  have q4 : s1.reg T0 = 2 := by
    rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0, S2]
  have k1 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T0 → s1.reg r = s.reg r := fun r a b c d => by
    rw [← hs1]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => a e.symm | exact fun e => b e.symm | exact fun e => c e.symm | exact fun e => d e.symm
  have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (15 + 4)) := by rw [← hs1]; exact line_pc_at _ hpc (by decide)
  have ms1 : s1.mem = s.mem := by rw [← hs1, line_mem]
  have hc1 : CodeAt s1.mem base kernel := by rw [ms1]; exact hcode
  -- HASHB(data, 55) to block j's place
  have hin : env.region.ok (s1.reg A0) (s1.reg A1).toNat := by
    rw [q1, q2, BitVec.toNat_ofNat]; exact ok_off hp DATA 55 (by decide) (by decide)
  have hout : env.region.ok (s1.reg A2) 32 := by rw [q3]; exact ok_off hp _ 32 (by omega) (by omega)
  have e2 := stepK (prog := kernel) hp 19 (by rw [kernel_length]; decide) hc1 p1 rfl
    (exec_hashb (env := env) (s := s1) q4 hin hout) 0 hlen
  rw [run_zero] at e2
  generalize hs2 : ({ s1 with mem := writeBytes s1.mem (s1.reg A2) (env.hash (readBytes s1.mem (s1.reg A0) (s1.reg A1).toNat)) } : Machine).next = s2 at e2
  have hrd : readBytes s1.mem (s1.reg A0) (s1.reg A1).toNat = digs (v + j) := by
    rw [q1, q2, BitVec.toNat_ofNat, ms1]
    exact read_holds hp.fit h.mem (by decide) (setF_holds _ _ _)
  have p2 : s2.pc = base + BitVec.ofNat 32 (4 * 20) := by
    rw [← hs2, next_pc]; simp only; rw [p1]; exact pc_next hp.fit _ (by decide)
  have mv2 : View s2.mem base (setH (setF (blocks env F v j) DATA (v + j)) (OUT + 32 * j) (env.hash (digs (v + j)))) := by
    rw [← hs2]; simp only [next_mem]; rw [hrd, q3, ms1]
    exact view_writeBytes hp.fit h.mem (by omega) _
  have r2 : ∀ r, s2.reg r = s1.reg r := fun r => by rw [← hs2]; rfl
  -- data += 1, by ADD
  have hlow2 : ∀ o, o < 4 * 70 →
      setH (setF (blocks env F v j) DATA (v + j)) (OUT + 32 * j) (env.hash (digs (v + j))) o = F0 o := fun o ho => by
    simp only [setH, show ¬ (OUT + 32 * j ≤ o ∧ o < OUT + 32 * j + 32) by simp only [OUT]; omega, ↓reduceDIte]
    exact hlow o ho
  have hc2 : CodeAt s2.mem base kernel := code_of_view hp hc0 hv0 mv2 hlow2
  have e3 := run_line hp [.opi .addi A0 S0 0x4c0, .opi .addi A1 S0 0x580] (by decide) 20 s2 (by decide)
    (by rw [kernel_length]; decide) hc2 p2 hlen
  generalize hs3 : s2.line [.opi .addi A0 S0 0x4c0, .opi .addi A1 S0 0x580] = s3 at e3
  have s0' : s2.reg S0 = base := by rw [r2, k1 S0 (by decide) (by decide) (by decide) (by decide), s0]
  have g30 : s3.reg A0 = base + BitVec.ofNat 32 DATA := by
    have : s3.reg A0 = s2.reg S0 + (0x4c0 : BitVec 12).signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, S0]
    rw [this, s0']; rfl
  have g31 : s3.reg A1 = base + BitVec.ofNat 32 ONE := by
    have : s3.reg A1 = s2.reg S0 + (0x580 : BitVec 12).signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, S0]
    rw [this, s0']; rfl
  have k3 : ∀ r, r ≠ A0 → r ≠ A1 → s3.reg r = s2.reg r := fun r a b => by
    rw [← hs3]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => b e.symm
  have p3 : s3.pc = base + BitVec.ofNat 32 (4 * (20 + 2)) := by rw [← hs3]; exact line_pc_at _ p2 (by decide)
  have hc3 : CodeAt s3.mem base kernel := by rw [← hs3, line_mem]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := callStep hp 22 (by rw [kernel_length]; decide) hc3 p3
    (off := BitVec.ofInt 20 (2 * (55 - 22 : Int))) rfl (k' := 55) (by decide) hlen
  have ho : Holds (setH (setF (blocks env F v j) DATA (v + j)) (OUT + 32 * j) (env.hash (digs (v + j)))) ONE 1 :=
    fun i hi => by
      simp only [setH, setF, ONE, OUT, DATA, show ¬ (0x600 + 32 * j ≤ 0x580 + i ∧ 0x580 + i < 0x600 + 32 * j + 32) by omega,
        ↓reduceDIte, show ¬ (0x4c0 ≤ 0x580 + i ∧ 0x580 + i < 0x4c0 + 55) by omega, ↓reduceIte]
      rw [blocks_low F v j _ (by simp only [OUT]; omega), hFl _ (by simp only [OUT]; omega)]
      exact hone i hi
  have hd : Holds (setH (setF (blocks env F v j) DATA (v + j)) (OUT + 32 * j) (env.hash (digs (v + j)))) DATA (v + j) :=
    fun i hi => by
      simp only [setH, OUT, DATA, show ¬ (0x600 + 32 * j ≤ 0x4c0 + i ∧ 0x4c0 + i < 0x600 + 32 * j + 32) by omega,
        ↓reduceDIte]
      exact setF_holds _ _ _ i hi
  obtain ⟨s5, e5, p5, mv5, k5⟩ := add_run hp hc0 hv0 hlow2 ⟨by decide, by decide, Or.inl (by decide)⟩ hd ho p4
    (by rw [m4, ← hs3, line_mem]; exact mv2) (by rw [r4]; simp only [show A0 ≠ 1 by decide, ↓reduceIte, g30])
    (by rw [r4]; simp only [show A1 ≠ 1 by decide, ↓reduceIte, g31]) (ret := 23) (by rw [r4]; simp [RA]) (by decide)
  -- s2 += 32, s1 -= 1, bne s1 → GEN
  have hc5 : CodeAt s5.mem base kernel := code_of_view hp hc0 hv0 mv5 (fun o ho => by
    simp only [setF, DATA, show ¬ (0x4c0 ≤ o ∧ o < 0x4c0 + 55) by omega, ↓reduceIte]; exact hlow2 o ho)
  have e6 := run_line hp [.opi .addi S2 S2 32, .opi .addi S1 S1 0xfff] (by decide) 23 s5 (by decide)
    (by rw [kernel_length]; decide) hc5 p5 hlen
  generalize hs6 : s5.line [.opi .addi S2 S2 32, .opi .addi S1 S1 0xfff] = s6 at e6
  -- s5's registers, back to s's
  have b5 : ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T2 → r ≠ A3 → r ≠ T0 → r ≠ RA →
      s5.reg r = s.reg r := fun r a b c d e f g t ra => by
    rw [k5 r a b c d f g, r4]
    simp only [show ¬ r = 1 from ra, ↓reduceIte]
    rw [k3 r c d, r2, k1 r c d e t]
  have g6s2 : s6.reg S2 = base + BitVec.ofNat 32 (OUT + 32 * (j + 1)) := by
    have : s6.reg S2 = s5.reg S2 + (32 : BitVec 12).signExtend 32 := by
      rw [← hs6]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S1, S2]
    rw [this, b5 S2 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide), h.s2, show (32 : BitVec 12).signExtend 32 = BitVec.ofNat 32 32 by decide,
      off_add hp.fit _ _ (by omega), show OUT + 32 * j + 32 = OUT + 32 * (j + 1) by omega]
  have g6s1 : s6.reg S1 = BitVec.ofNat 32 (m - (j + 1)) := by
    have : s6.reg S1 = s5.reg S1 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs6]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S1, S2]
    rw [this, b5 S1 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide), h.s1, count_down _ (by omega) (by omega), Nat.sub_sub]
  have k6 : ∀ r, r ≠ S1 → r ≠ S2 → s6.reg r = s5.reg r := fun r a b => by
    rw [← hs6]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => b e.symm
  have p6 : s6.pc = base + BitVec.ofNat 32 (4 * (23 + 2)) := by rw [← hs6]; exact line_pc_at _ p5 (by decide)
  have hc6 : CodeAt s6.mem base kernel := by rw [← hs6, line_mem]; exact hc5
  obtain ⟨s7, e7, p7, m7, r7⟩ := brStep hp 25 (by rw [kernel_length]; decide) hc6 p6
    (op := .bne) (rs1 := S1) (rs2 := 0) (off := BitVec.ofInt 12 (2 * (15 - 25 : Int))) rfl (k' := 15) (by decide) hlen
  have tk : taken .bne (s6.reg S1) (s6.reg 0) = decide (j + 1 < m) := by
    rw [g6s1, show s6.reg 0 = 0 from reg_zero _]
    by_cases hlt : j + 1 < m
    · have : BitVec.ofNat 32 (m - (j + 1)) ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; simp at this; omega
      simp only [taken, hlt, decide_true]; exact bne_iff_ne.mpr this
    · rw [show m - (j + 1) = 0 by omega]; simp only [taken, hlt, decide_false]; decide
  have e1' : run env 4 s = .running s1 := e1
  have e3' : run env 2 s2 = .running s3 := e3
  have e6' : run env 2 s5 = .running s6 := e6
  refine ⟨s7, ?_, ⟨?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 566 = 4 + (1 + (2 + (1 + (ADD + (2 + 1))))) by rfl, run_add_running e1', run_add_running e2,
      run_add_running e3', run_add_running e4, run_add_running e5, run_add_running e6', e7]
  · rw [p7, tk]; by_cases hlt : j + 1 < m <;> simp [hlt]
  · rw [m7, ← hs6, line_mem]
    refine mv5.congr (fun o _ => ?_)
    simp only [setF, blocks, setH]
    by_cases hD : DATA ≤ o ∧ o < DATA + 55
    · simp only [hD, and_self, ↓reduceIte, Nat.add_assoc]
    · simp only [hD, ↓reduceIte]
  · rw [r7, g6s1]
  · rw [r7, g6s2]
  · intro r a b c d e f g t ra s1' s2'
    rw [r7, k6 r s1' s2', b5 r a b c d e f g t ra, h.kept r a b c d e f g t ra s1' s2']

theorem copy_loop (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {keep : Reg → Word} {s : Machine}
    (h : CInv base F 0 keep s) : ∀ i, i ≤ 55 → ∃ s', run env (6 * i) s = .running s' ∧ CInv base F i keep s' := by
  intro i hi
  induction i with
  | zero => exact ⟨s, rfl, h⟩
  | succ i ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := copy_iter hp hc0 hv0 hFc (by omega) hs'
    exact ⟨s'', by rw [show 6 * (i + 1) = 6 * i + 6 by omega, run_add_running e, e'], hs''⟩

theorem gen_loop (hp : Placed env base) {M0 : Word → Byte} {F0 : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) {F : Nat → Byte} (hFl : ∀ o, o < OUT → F o = F0 o) (hone : Holds F0 ONE 1)
    {v m : Nat} (hm : OUT + 32 * m < 0x10000) {keep : Reg → Word} (k0 : keep S0 = base) {s : Machine}
    (h : GInv env base F v m 0 keep s) :
    ∀ j, j ≤ m → ∃ s', run env (566 * j) s = .running s' ∧ GInv env base F v m j keep s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := gen_iter hp hc0 hv0 hFl hone hm k0 (by omega) hs'
    exact ⟨s'', by rw [show 566 * (j + 1) = 566 * j + 566 by omega, run_add_running e, e'], hs''⟩

/-! ## The first three instructions, and the reseed check -/

theorem word_lt (F : Nat → Byte) (c : Nat) : word F c < 2 ^ 32 := by
  simp only [word]
  have := (F c).isLt; have := (F (c + 1)).isLt; have := (F (c + 2)).isLt; have := (F (c + 3)).isLt
  omega

theorem head_run (hp : Placed env base) {s : Machine} (hpc : s.pc = base) {F0 : Nat → Byte}
    (hv0 : View s.mem base F0) (hc0 : CodeAt s.mem base kernel) :
    ∃ s3, run env 3 s = .running s3 ∧ s3.pc = base + BitVec.ofNat 32 (4 * 3) ∧ s3.mem = s.mem
      ∧ s3.reg S0 = base ∧ s3.reg T1 = BitVec.ofNat 32 (word F0 (PAR + 4))
      ∧ s3.reg S3 = BitVec.ofNat 32 (word F0 (PAR + 8))
      ∧ ∀ r, r ≠ S0 → r ≠ T1 → r ≠ S3 → s3.reg r = s.reg r := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide)
    (by exact hc0) (by rw [hpc]; simp) (i := .auipc S0 0) rfl (rd := S0) (v := s.pc + (0#20 ++ 0#12)) rfl hlen
  have b1 : s1.reg S0 = base := by
    rw [reg_wrote r1 (by decide), hpc, show (0#20 ++ 0#12 : BitVec 32) = 0#32 by decide, BitVec.add_zero]
  have se404 : (0x404 : BitVec 12).signExtend 32 = BitVec.ofNat 32 (PAR + 4) := by decide
  have se408 : (0x408 : BitVec 12).signExtend 32 = BitVec.ofNat 32 (PAR + 8) := by decide
  obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp 1 (by decide) (by rw [m1]; exact hc0) p1
    (rd := T1) (rs1 := S0) (imm := 0x404) rfl (PAR + 4) (by rw [b1, se404]) (by decide) (by decide) hlen
  obtain ⟨s3, e3, p3, m3, r3⟩ := loadStep hp 2 (by decide) (by rw [m2, m1]; exact hc0) p2
    (rd := S3) (rs1 := S0) (imm := 0x408) rfl (PAR + 8)
    (by rw [reg_kept r2 (by decide), b1, se408]) (by decide) (by decide) hlen
  refine ⟨s3, ?_, p3, by rw [m3, m2, m1], ?_, ?_, ?_, fun r a b c => ?_⟩
  · rw [show 3 = 1 + (1 + 1) by rfl, run_add_running e1, run_add_running e2, e3]
  · rw [reg_kept r3 (by decide), reg_kept r2 (by decide), b1]
  · rw [reg_kept r3 (by decide), reg_wrote r2 (by decide), m1, readLE_view hp.fit hv0 (by decide)]
  · rw [reg_wrote r3 (by decide), m2, m1, readLE_view hp.fit hv0 (by decide)]
  · rw [reg_kept r3 c, reg_kept r2 b, reg_kept r1 a]

/-- **Reseed required**: when the counter is past the interval, HALT 1
after seven instructions, memory as it was. -/
theorem reseed_run (hp : Placed env base) {s : Machine} (hpc : s.pc = base) {F0 : Nat → Byte}
    (hv0 : View s.mem base F0) (hc0 : CodeAt s.mem base kernel)
    (hgt : word F0 (PAR + 4) < word F0 (PAR + 8)) :
    ∃ s', run env 7 s = .halted 1 s' ∧ s'.mem = s.mem := by
  obtain ⟨s3, e3, p3, m3, b0, bt, b3, _⟩ := head_run hp hpc hv0 hc0
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc0
  obtain ⟨s4, e4, p4, m4, r4⟩ := brStep hp 3 (by rw [kernel_length]; decide) hc3 p3
    (op := .bltu) (rs1 := T1) (rs2 := S3) (off := BitVec.ofInt 12 (2 * (52 - 3 : Int))) rfl (k' := 52) (by decide) hlen
  have tk : taken .bltu (s3.reg T1) (s3.reg S3) = true := by
    rw [bt, b3]; simp only [taken, BitVec.ult, BitVec.toNat_ofNat,
      Nat.mod_eq_of_lt (word_lt F0 _), decide_eq_true_eq]; exact hgt
  rw [tk] at p4; simp only [↓reduceIte] at p4
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  have e5 := run_line hp [.opi .addi A0 0 1, .opi .addi T0 0 1] (by decide) 52 s4 (by decide)
    (by rw [kernel_length]; decide) hc4 p4 hlen
  generalize hs5 : s4.line [.opi .addi A0 0 1, .opi .addi T0 0 1] = s5 at e5
  have g0 : s5.reg A0 = 1 := by rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have g5 : s5.reg T0 = 1 := by rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have p5 : s5.pc = base + BitVec.ofNat 32 (4 * (52 + 2)) := by rw [← hs5]; exact line_pc_at _ p4 (by decide)
  have hc5 : CodeAt s5.mem base kernel := by rw [← hs5, line_mem]; exact hc4
  have e6 := haltStep hp 54 (by rw [kernel_length]; decide) hc5 p5 rfl g5 hlen 0
  have e5' : run env 2 s4 = .running s5 := e5
  refine ⟨s5, ?_, by rw [← hs5, line_mem, m4, m3]⟩
  rw [show 7 = 3 + (1 + (2 + (0 + 1))) by rfl, run_add_running e3, run_add_running e4, run_add_running e5', e6, g0]

/-- **A call of ADD**: `a0`, `a1` set from `s0`, `jal ra`; back three
instructions on with the field at `X` holding `a + b`. -/
theorem call_add (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {X Y a b : Nat} (hf : Fields X Y)
    (ha : Holds F X a) (hb : Holds F Y b) {xi yi : BitVec 12} (hxi : xi.signExtend 32 = BitVec.ofNat 32 X)
    (hyi : yi.signExtend 32 = BitVec.ofNat 32 Y) {k : Nat} (hk : k + 3 ≤ 70)
    (hseg : (kernel.drop k).take 2 = [.opi .addi A0 S0 xi, .opi .addi A1 S0 yi]) {off : BitVec 20}
    (hj : kernel.getD (k + 2) .ecall = .jal 1 off)
    (hoff : BitVec.ofNat 32 (4 * (k + 2)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * 55))
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) (hmem : View s.mem base F) (hs0 : s.reg S0 = base) :
    ∃ s', run env (3 + ADD) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 3))
      ∧ View s'.mem base (setF F X (a + b))
      ∧ ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ T2 → r ≠ A3 → r ≠ RA → s'.reg r = s.reg r := by
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 hmem hFc
  have e1 := run_line hp [.opi .addi A0 S0 xi, .opi .addi A1 S0 yi] rfl k s hseg
    (by simp only [List.length_cons, List.length_nil, kernel_length]; omega) hcode hpc hlen
  generalize hs1 : s.line [.opi .addi A0 S0 xi, .opi .addi A1 S0 yi] = s1 at e1
  have g0 : s1.reg A0 = base + BitVec.ofNat 32 X := by
    have : s1.reg A0 = s.reg S0 + xi.signExtend 32 := by
      rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, S0]
    rw [this, hs0, hxi]
  have g1 : s1.reg A1 = base + BitVec.ofNat 32 Y := by
    have : s1.reg A1 = s.reg S0 + yi.signExtend 32 := by
      rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, S0]
    rw [this, hs0, hyi]
  have k1 : ∀ r, r ≠ A0 → r ≠ A1 → s1.reg r = s.reg r := fun r a b => by
    rw [← hs1]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => b e.symm
  have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (k + 2)) := by
    rw [← hs1]; exact line_pc_at _ hpc (by simp only [List.length_cons, List.length_nil]; omega)
  have hc1 : CodeAt s1.mem base kernel := by rw [← hs1, line_mem]; exact hcode
  obtain ⟨s2, e2, p2, m2, r2⟩ := callStep hp (k + 2) (by rw [kernel_length]; omega) hc1 p1 hj hoff hlen
  obtain ⟨s3, e3, p3, mv3, k3⟩ := add_run hp hc0 hv0 hFc hf ha hb p2
    (by rw [m2, ← hs1, line_mem]; exact hmem) (by rw [r2]; simp only [show A0 ≠ 1 by decide, ↓reduceIte, g0])
    (by rw [r2]; simp only [show A1 ≠ 1 by decide, ↓reduceIte, g1]) (ret := k + 3) (by rw [r2]; simp [RA])
    (by omega)
  have e1' : run env 2 s = .running s1 := e1
  refine ⟨s3, ?_, p3, mv3, fun r a b c d e f g => ?_⟩
  · rw [show 3 + ADD = 2 + (1 + ADD) by rfl, run_add_running e1', run_add_running e2, e3]
  · rw [k3 r a b c d e f, r2]
    simp only [show ¬ r = 1 from g, ↓reduceIte]
    exact k1 r c d

/-- `srli t1, s3, sh` and `sb t1, imm(s0)`: byte `c` one byte of the counter's. -/
theorem shift_sb (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 70 → F o = F0 o) {k : Nat} (hk : k + 2 ≤ 70)
    {sh : BitVec 5} {imm : BitVec 12} (hseg : (kernel.drop k).take 1 = [.sh .srli T1 S3 sh])
    (hsb : kernel.getD (k + 1) .ecall = .st .sb S0 T1 imm) {j c : Nat} (hsh : sh.toNat = j)
    (himm : imm.signExtend 32 = BitVec.ofNat 32 c) (hc : c < 0x10000) {cnt : Nat} (hcnt : cnt < 2 ^ 32)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) (hmem : View s.mem base F)
    (hs0 : s.reg S0 = base) (hs3 : s.reg S3 = BitVec.ofNat 32 cnt) :
    ∃ s', run env 2 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 2))
      ∧ View s'.mem base (setB F c (BitVec.ofNat 8 (cnt / 2 ^ j))) ∧ ∀ r, r ≠ T1 → s'.reg r = s.reg r := by
  have hcode : CodeAt s.mem base kernel := code_of_view hp hc0 hv0 hmem hFc
  have e1 := run_line hp [.sh .srli T1 S3 sh] rfl k s hseg
    (by simp only [List.length_cons, List.length_nil, kernel_length]; omega) hcode hpc hlen
  generalize hs1 : s.line [.sh .srli T1 S3 sh] = s1 at e1
  have t1 : s1.reg T1 = s.reg S3 >>> sh.toNat := by
    rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, shiftI, T1, S3]
  have k1 : ∀ r, r ≠ T1 → s1.reg r = s.reg r := fun r a => by
    rw [← hs1]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (k + 1)) := by
    rw [← hs1]; exact line_pc_at _ hpc (by simp only [List.length_cons, List.length_nil]; omega)
  have ms1 : s1.mem = s.mem := by rw [← hs1, line_mem]
  obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep hp (k + 1) (by rw [kernel_length]; omega) (by rw [ms1]; exact hcode) p1
    hsb c (by rw [k1 S0 (by decide), hs0, himm]) hc hlen
  have e1' : run env 1 s = .running s1 := e1
  refine ⟨s2, by rw [show 2 = 1 + 1 by rfl, run_add_running e1', e2], p2, ?_, fun r a => by rw [r2, k1 r a]⟩
  rw [m2, ms1, t1, hs3, BitVec.toNat_ushiftRight, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hcnt,
    Nat.shiftRight_eq_div_pow, hsh]
  exact view_writeByte hp.fit hmem hc _

theorem setB_low {F F0 : Nat → Byte} (hF : ∀ o, o < 4 * 70 → F o = F0 o) {c : Nat} (hc : 4 * 70 ≤ c) (v : Byte) :
    ∀ o, o < 4 * 70 → setB F c v o = F0 o := fun o ho => by
  simp only [setB, show ¬ o = c by omega, ↓reduceIte]; exact hF o ho

/-! ## The specification of a Generate

Memory afterwards, from the image's bytes `F0`, the state `v`, `c`, `cnt`
it held, and `m` blocks asked for: the `m` blocks; data at `v + m`; H at
0x517; the counter's bytes at 0x573; V the new V; the counter word one more.
Everything else is the image's. -/

/-- Hash(0x03 ‖ V), §10.1.1.4 step 3. -/
def hpre (env : Env) (v : Nat) : Fin 32 → Byte := env.hash (BitVec.ofNat 8 3 :: digs v)

/-- `F` with the counter's 4 bytes, big-endian, at the end of its field. -/
def setT (F : Nat → Byte) (n : Nat) : Nat → Byte := fun o =>
  if CB + 51 ≤ o ∧ o < CB + 55 then BitVec.ofNat 8 (n / 256 ^ (CB + 54 - o)) else F o

/-- The four bytes `sb` puts there are the counter's. -/
theorem setT_bytes (G : Nat → Byte) (n : Nat) :
    setB (setB (setB (setB G (CB + 51) (BitVec.ofNat 8 (n / 2 ^ 24))) (CB + 52) (BitVec.ofNat 8 (n / 2 ^ 16)))
      (CB + 53) (BitVec.ofNat 8 (n / 2 ^ 8))) (CB + 54) (BitVec.ofNat 8 n) = setT G n := by
  funext o; simp only [setB, setT, CB]
  by_cases h0 : o = 0x540 + 54
  · subst h0; simp
  by_cases h1 : o = 0x540 + 53
  · subst h1; simp
  by_cases h2 : o = 0x540 + 52
  · subst h2; simp
  by_cases h3 : o = 0x540 + 51
  · subst h3; simp
  simp only [h0, h1, h2, h3, ↓reduceIte, show ¬ (0x540 + 51 ≤ o ∧ o < 0x540 + 55) by omega]

theorem setF_setT (G : Nat → Byte) (a b n : Nat) : setF (setT (setF G VV a) n) VV b = setF (setT G n) VV b := by
  funext o; simp only [setF, setT]
  by_cases h : VV ≤ o ∧ o < VV + 55
  · simp only [h, and_self, ↓reduceIte]
  · simp only [h, ↓reduceIte]

/-- **V's next value**, §10.1.1.4 step 4: V + H + C + reseed_counter. A field
holds it mod 2^440. -/
def vnext (env : Env) (v c cnt : Nat) : Nat := v + hnum (hpre env v) + c + cnt

def after (env : Env) (F0 : Nat → Byte) (v c cnt m : Nat) : Nat → Byte :=
  setW (setF (setT (setH (setF (blocks env F0 v m) DATA (v + m)) (HB + 23) (hpre env v)) cnt) VV (vnext env v c cnt))
    (PAR + 8) (cnt + 1)

/-- Instructions to the halt, for `m` blocks. -/
def COST (m : Nat) : Nat := 2030 + 566 * m

theorem generate_run (hp : Placed env base) {s : Machine} (hpc : s.pc = base) {F0 : Nat → Byte}
    (hv0 : View s.mem base F0) (hc0 : CodeAt s.mem base kernel)
    {v c m cnt : Nat} (hV : Holds F0 VV v) (hC : Holds F0 CC c) (hone : Holds F0 ONE 1)
    (hpre3 : F0 PRE = 3) (hhb : ∀ i, i < 23 → F0 (HB + i) = 0) (hcb : ∀ i, i < 51 → F0 (CB + i) = 0)
    (hm : word F0 PAR = m) (hcnt : word F0 (PAR + 8) = cnt) (hm1 : 1 ≤ m) (hm2 : OUT + 32 * m < 0x10000)
    (hiv : word F0 (PAR + 4) < 2 ^ 32 - 1) (hok : cnt ≤ word F0 (PAR + 4)) :
    ∃ s', run env (COST m - 1) s = .running s' ∧ run env (COST m) s = .halted 0 s'
      ∧ View s'.mem base (after env F0 v c cnt m) := by
  obtain ⟨s3, e3, p3, m3, b0, bt, b3, k3⟩ := head_run hp hpc hv0 hc0
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hc0
  obtain ⟨s4, e4, p4, m4, r4⟩ := brStep hp 3 (by rw [kernel_length]; decide) hc3 p3
    (op := .bltu) (rs1 := T1) (rs2 := S3) (off := BitVec.ofInt 12 (2 * (52 - 3 : Int))) rfl (k' := 52) (by decide) hlen
  have tk : taken .bltu (s3.reg T1) (s3.reg S3) = false := by
    rw [bt, b3, hcnt]; simp only [taken, BitVec.ult, BitVec.toNat_ofNat,
      Nat.mod_eq_of_lt (word_lt F0 _), Nat.mod_eq_of_lt (show cnt < 2 ^ 32 by rw [← hcnt]; exact word_lt _ _),
      decide_eq_false_iff_not, Nat.not_lt]; exact hok
  rw [tk] at p4; simp only [Bool.false_eq_true, ↓reduceIte] at p4
  have mv4 : View s4.mem base F0 := by rw [m4, m3]; exact hv0
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  -- COPY
  have e5 := run_line hp [.opi .addi A0 S0 0x440, .opi .addi A1 S0 0x4c0, .opi .addi T2 0 55] (by decide) 4 s4
    (by decide) (by rw [kernel_length]; decide) hc4 p4 hlen
  generalize hs5 : s4.line [.opi .addi A0 S0 0x440, .opi .addi A1 S0 0x4c0, .opi .addi T2 0 55] = s5 at e5
  have s40 : s4.reg S0 = base := by rw [r4, b0]
  have hC0 : CInv base F0 0 s5.reg s5 := by
    refine ⟨by rw [← hs5]; exact line_pc_at _ p4 (by decide), ?_, ?_, ?_, ?_, fun _ _ _ _ _ => rfl⟩
    · rw [← hs5, line_mem]; exact mv4.congr (fun o _ => by simp only [copyView, Nat.add_zero]; split <;> first | omega | rfl)
    · have : s5.reg A0 = s4.reg S0 + (0x440 : BitVec 12).signExtend 32 := by
        rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, S0]
      rw [this, s40]; rfl
    · have : s5.reg A1 = s4.reg S0 + (0x4c0 : BitVec 12).signExtend 32 := by
        rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, S0]
      rw [this, s40]; rfl
    · rw [← hs5]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, T2, S0]
  have hFc0 : ∀ o, o < 4 * 70 → F0 o = F0 o := fun _ _ => rfl
  obtain ⟨s6, e6, h6⟩ := copy_loop hp hc0 hv0 hFc0 hC0 55 (Nat.le_refl _)
  have p6 : s6.pc = base + BitVec.ofNat 32 (4 * 13) := by rw [h6.pc]; simp
  have mv6 := h6.mem
  rw [copy_done F0 hV] at mv6
  have k5 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ T2 → s5.reg r = s4.reg r := fun r a b c => by
    rw [← hs5]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => a e.symm | exact fun e => b e.symm | exact fun e => c e.symm
  have b6 : ∀ r, r ≠ T1 → r ≠ A0 → r ≠ A1 → r ≠ T2 → s6.reg r = s3.reg r := fun r a b c d => by
    rw [h6.kept r a b c d, k5 r b c d, r4]
  have hlowD : ∀ o, o < 4 * 70 → setF F0 DATA v o = F0 o := fun o ho => by
    simp only [setF, DATA, show ¬ (0x4c0 ≤ o ∧ o < 0x4c0 + 55) by omega, ↓reduceIte]
  have hc6 : CodeAt s6.mem base kernel := code_of_view hp hc0 hv0 mv6 hlowD
  -- s1 = m, s2 = the first block's place
  obtain ⟨s7, e7, p7, m7, r7⟩ := loadStep hp 13 (by rw [kernel_length]; decide) hc6 p6
    (rd := S1) (rs1 := S0) (imm := 0x400) rfl PAR
    (by rw [b6 S0 (by decide) (by decide) (by decide) (by decide), b0,
      show (0x400 : BitVec 12).signExtend 32 = BitVec.ofNat 32 PAR by decide]) (by decide) (by decide) hlen
  have hc7 : CodeAt s7.mem base kernel := by rw [m7]; exact hc6
  have e8 := run_line hp [.opi .addi S2 S0 0x600] (by decide) 14 s7 (by decide) (by rw [kernel_length]; decide) hc7 p7 hlen
  generalize hs8 : s7.line [.opi .addi S2 S0 0x600] = s8 at e8
  have hG0 : GInv env base F0 v m 0 s8.reg s8 := by
    refine ⟨by rw [← hs8, line_pc_at _ p7 (by decide)]; simp [show 0 < m by omega], ?_, ?_, ?_, fun _ _ _ _ _ _ _ _ _ _ _ _ => rfl⟩
    · rw [← hs8, line_mem, m7]; simp only [blocks, Nat.add_zero]; exact mv6
    · have : s8.reg S1 = s7.reg S1 := by rw [← hs8]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S1, S2, S0]
      rw [this, reg_wrote r7 (by decide), readLE_view hp.fit mv6 (by decide)]
      have : word (setF F0 DATA v) PAR = word F0 PAR := by
        simp only [word, setF, DATA, PAR, show ¬ (0x4c0 ≤ 0x400 ∧ 0x400 < 0x4c0 + 55) by decide,
          show ¬ (0x4c0 ≤ 0x400 + 1 ∧ 0x400 + 1 < 0x4c0 + 55) by decide,
          show ¬ (0x4c0 ≤ 0x400 + 2 ∧ 0x400 + 2 < 0x4c0 + 55) by decide,
          show ¬ (0x4c0 ≤ 0x400 + 3 ∧ 0x400 + 3 < 0x4c0 + 55) by decide, ↓reduceIte]
      rw [this, hm, Nat.sub_zero]
    · have : s8.reg S2 = s7.reg S0 + (0x600 : BitVec 12).signExtend 32 := by
        rw [← hs8]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S2, S0]
      rw [this, reg_kept r7 (by decide), b6 S0 (by decide) (by decide) (by decide) (by decide), b0]; rfl
  -- GEN, m times
  have k8 : ∀ r, r ≠ S2 → s8.reg r = s7.reg r := fun r a => by
    rw [← hs8]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have s80 : s8.reg S0 = base := by
    rw [k8 S0 (by decide), reg_kept r7 (by decide), b6 S0 (by decide) (by decide) (by decide) (by decide), b0]
  have s83 : s8.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k8 S3 (by decide), reg_kept r7 (by decide), b6 S3 (by decide) (by decide) (by decide) (by decide), b3, hcnt]
  obtain ⟨s9, e9, h9⟩ := gen_loop hp hc0 hv0 (fun _ _ => rfl) hone hm2 s80 hG0 m (Nat.le_refl _)
  have p9 : s9.pc = base + BitVec.ofNat 32 (4 * 26) := by rw [h9.pc]; simp
  have k9 : ∀ r, r ≠ T1 → r ≠ A4 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T2 → r ≠ A3 → r ≠ T0 → r ≠ RA → r ≠ S1 → r ≠ S2 →
      s9.reg r = s8.reg r := h9.kept
  have s90 : s9.reg S0 = base := by
    rw [k9 S0 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide), s80]
  have s93 : s9.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k9 S3 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
      (by decide) (by decide) (by decide), s83]
  generalize hFm : setF (blocks env F0 v m) DATA (v + m) = Fm
  have mv9 : View s9.mem base Fm := by rw [← hFm]; exact h9.mem
  have hFm0 : ∀ o, o < OUT → ¬ (DATA ≤ o ∧ o < DATA + 55) → Fm o = F0 o := fun o h1 h2 => by
    rw [← hFm]; simp only [setF, h2, ↓reduceIte]; exact blocks_low F0 v m o h1
  have hFmc : ∀ o, o < 4 * 70 → Fm o = F0 o := fun o ho => hFm0 o (by simp only [OUT]; omega)
    (by simp only [DATA]; omega)
  have hc9 : CodeAt s9.mem base kernel := code_of_view hp hc0 hv0 mv9 hFmc
  -- H = Hash(0x03 ‖ V), to 0x517
  have e10 := run_line hp [.opi .addi A0 S0 0x43f, .opi .addi A1 0 56, .opi .addi A2 S0 0x517, .opi .addi T0 0 2]
    (by decide) 26 s9 (by decide) (by rw [kernel_length]; decide) hc9 p9 hlen
  generalize hs10 : s9.line [.opi .addi A0 S0 0x43f, .opi .addi A1 0 56, .opi .addi A2 S0 0x517, .opi .addi T0 0 2]
    = s10 at e10
  have q0 : s10.reg A0 = base + BitVec.ofNat 32 PRE := by
    have : s10.reg A0 = s9.reg S0 + (0x43f : BitVec 12).signExtend 32 := by
      rw [← hs10]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0]
    rw [this, s90]; rfl
  have q1 : s10.reg A1 = BitVec.ofNat 32 56 := by
    rw [← hs10]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0]
  have q2 : s10.reg A2 = base + BitVec.ofNat 32 (HB + 23) := by
    have : s10.reg A2 = s9.reg S0 + (0x517 : BitVec 12).signExtend 32 := by
      rw [← hs10]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0]
    rw [this, s90]; rfl
  have q3 : s10.reg T0 = 2 := by
    rw [← hs10]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0]
  have k10 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T0 → s10.reg r = s9.reg r := fun r a b c d => by
    rw [← hs10]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => a e.symm | exact fun e => b e.symm | exact fun e => c e.symm | exact fun e => d e.symm
  have p10 : s10.pc = base + BitVec.ofNat 32 (4 * (26 + 4)) := by rw [← hs10]; exact line_pc_at _ p9 (by decide)
  have ms10 : s10.mem = s9.mem := by rw [← hs10, line_mem]
  have hrd : readBytes s10.mem (s10.reg A0) (s10.reg A1).toNat = BitVec.ofNat 8 3 :: digs v := by
    rw [q0, q1, BitVec.toNat_ofNat, ms10, readBytes_view hp.fit mv9 PRE (by decide), List.range_succ_eq_map,
      List.map_cons, List.map_map, Nat.add_zero, hFm0 PRE (by decide) (by decide), hpre3, digs]
    congr 1
    apply List.map_congr_left; intro d hd
    have hd' := List.mem_range.mp hd
    simp only [Function.comp]
    rw [show PRE + (d + 1) = VV + d by simp only [PRE, VV]; omega,
      hFm0 _ (by simp only [VV, OUT]; omega) (by simp only [VV, DATA]; omega), hV d hd']
  have e11 := stepK (prog := kernel) hp 30 (by rw [kernel_length]; decide) (by rw [ms10]; exact hc9) p10 rfl
    (exec_hashb (env := env) (s := s10) q3
      (by rw [q0, q1, BitVec.toNat_ofNat]; exact ok_off hp _ _ (by decide) (by decide))
      (by rw [q2]; exact ok_off hp _ _ (by decide) (by decide))) 0 hlen
  rw [run_zero] at e11
  generalize hs11 : ({ s10 with mem := writeBytes s10.mem (s10.reg A2) (env.hash (readBytes s10.mem (s10.reg A0) (s10.reg A1).toNat)) } : Machine).next = s11 at e11
  have p11 : s11.pc = base + BitVec.ofNat 32 (4 * 31) := by
    rw [← hs11, next_pc]; simp only; rw [p10]; exact pc_next hp.fit _ (by decide)
  have mv11 : View s11.mem base (setH Fm (HB + 23) (hpre env v)) := by
    rw [← hs11]; simp only [next_mem]; rw [hrd, q2, ms10]
    exact view_writeBytes hp.fit mv9 (by decide) _
  have r11 : ∀ r, s11.reg r = s10.reg r := fun r => by rw [← hs11]; rfl
  have s110 : s11.reg S0 = base := by rw [r11, k10 S0 (by decide) (by decide) (by decide) (by decide), s90]
  have s113 : s11.reg S3 = BitVec.ofNat 32 cnt := by
    rw [r11, k10 S3 (by decide) (by decide) (by decide) (by decide), s93]
  generalize hG1 : setH Fm (HB + 23) (hpre env v) = G1 at mv11
  have hG1c : ∀ o, o < 0x517 → G1 o = Fm o := fun o ho => by
    rw [← hG1]; simp only [setH, HB, show ¬ (0x500 + 23 ≤ o ∧ o < 0x500 + 23 + 32) by omega, ↓reduceDIte]
  have hG1lo : ∀ o, o < 0x517 → ¬ (DATA ≤ o ∧ o < DATA + 55) → G1 o = F0 o := fun o h1 h2 => by
    rw [hG1c o h1, hFm0 o (by simp only [OUT]; omega) h2]
  -- V += H
  have hVv : Holds G1 VV v := fun i hi => by
    rw [hG1lo _ (by simp only [VV]; omega) (by simp only [VV, DATA]; omega)]; exact hV i hi
  have hHB : Holds G1 HB (hnum (hpre env v)) := holds_hash
    (fun i hi => by rw [hG1lo _ (by simp only [HB]; omega) (by simp only [HB, DATA]; omega)]; exact hhb i hi)
    (fun d hd => by
      rw [← hG1]; simp only [setH, show HB + 23 ≤ HB + 23 + d ∧ HB + 23 + d < HB + 23 + 32 by omega, and_self,
        ↓reduceDIte, Nat.add_sub_cancel_left])
  have hG1code : ∀ o, o < 4 * 70 → G1 o = F0 o := fun o ho =>
    hG1lo o (by omega) (by simp only [DATA]; omega)
  obtain ⟨s12, e12, p12, mv12, k12⟩ := call_add hp hc0 hv0 hG1code ⟨by decide, by decide, Or.inl (by decide)⟩
    hVv hHB (xi := 0x440) (yi := 0x500) (by decide) (by decide) (k := 31) (by decide) (by decide)
    (off := BitVec.ofInt 20 (2 * (55 - 33 : Int))) rfl (by decide) p11 mv11 s110
  have s120 : s12.reg S0 = base := by
    rw [k12 S0 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s110]
  have s123 : s12.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k12 S3 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s113]
  -- V += C
  have hCc : Holds (setF G1 VV (v + hnum (hpre env v))) CC c := fun i hi => by
    simp only [setF, VV, CC, show ¬ (0x440 ≤ 0x480 + i ∧ 0x480 + i < 0x440 + 55) by omega, ↓reduceIte]
    rw [hG1lo _ (by omega) (by simp only [DATA]; omega)]; exact hC i hi
  obtain ⟨s13, e13, p13, mv13, k13⟩ := call_add hp hc0 hv0
    (fun o ho => by simp only [setF, VV, show ¬ (0x440 ≤ o ∧ o < 0x440 + 55) by omega, ↓reduceIte]; exact hG1code o ho)
    ⟨by decide, by decide, Or.inl (by decide)⟩ (setF_holds _ _ _) hCc (xi := 0x440) (yi := 0x480) (by decide) (by decide)
    (k := 34) (by decide) (by decide) (off := BitVec.ofInt 20 (2 * (55 - 36 : Int))) rfl (by decide)
    (by rw [p12]) mv12 s120
  rw [setF_setF] at mv13
  have s130 : s13.reg S0 = base := by
    rw [k13 S0 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s120]
  have s133 : s13.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k13 S3 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s123]
  -- the counter's bytes, big-endian, at 0x573
  have hcnt32 : cnt < 2 ^ 32 := hcnt ▸ word_lt _ _
  generalize hG2 : setF G1 VV (v + hnum (hpre env v) + c) = G2 at mv13
  have hG2c : ∀ o, o < 4 * 70 → G2 o = F0 o := fun o ho => by
    rw [← hG2]; simp only [setF, VV, show ¬ (0x440 ≤ o ∧ o < 0x440 + 55) by omega, ↓reduceIte]; exact hG1code o ho
  obtain ⟨s14, e14, p14, mv14, k14⟩ := shift_sb hp hc0 hv0 hG2c (k := 37) (by decide) (sh := 24) (imm := 0x573)
    rfl rfl (c := CB + 51) rfl (by decide) (by decide) hcnt32 (by rw [p13]) mv13 s130 s133
  obtain ⟨s15, e15, p15, mv15, k15⟩ := shift_sb hp hc0 hv0 (setB_low hG2c (by decide) _) (k := 39) (by decide)
    (sh := 16) (imm := 0x574) rfl rfl (c := CB + 52) rfl (by decide) (by decide) hcnt32 p14 mv14
    (by rw [k14 S0 (by decide), s130]) (by rw [k14 S3 (by decide), s133])
  obtain ⟨s16, e16, p16, mv16, k16⟩ := shift_sb hp hc0 hv0 (setB_low (setB_low hG2c (by decide) _) (by decide) _)
    (k := 41) (by decide) (sh := 8) (imm := 0x575) rfl rfl (c := CB + 53) rfl (by decide) (by decide) hcnt32 p15 mv15
    (by rw [k15 S0 (by decide), k14 S0 (by decide), s130]) (by rw [k15 S3 (by decide), k14 S3 (by decide), s133])
  have s160 : s16.reg S0 = base := by rw [k16 S0 (by decide), k15 S0 (by decide), k14 S0 (by decide), s130]
  have s163 : s16.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k16 S3 (by decide), k15 S3 (by decide), k14 S3 (by decide), s133]
  have hc16 : CodeAt s16.mem base kernel := code_of_view hp hc0 hv0 mv16
    (setB_low (setB_low (setB_low hG2c (by decide) _) (by decide) _) (by decide) _)
  obtain ⟨s17, e17, p17, m17, r17⟩ := sbStep hp 43 (by rw [kernel_length]; decide) hc16 p16
    (rs1 := S0) (rs2 := S3) (imm := 0x576) rfl (CB + 54) (by rw [s160]; rfl) (by decide) hlen
  have mv17 : View s17.mem base (setT G2 cnt) := by
    rw [m17, s163, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hcnt32, ← setT_bytes]
    exact view_writeByte hp.fit mv16 (by decide) _
  -- V += the counter
  have hTc : ∀ o, o < 4 * 70 → setT G2 cnt o = F0 o := fun o ho => by
    simp only [setT, CB, show ¬ (0x540 + 51 ≤ o ∧ o < 0x540 + 55) by omega, ↓reduceIte]; exact hG2c o ho
  have hTV : Holds (setT G2 cnt) VV (v + hnum (hpre env v) + c) := fun i hi => by
    simp only [setT, CB, VV, show ¬ (0x540 + 51 ≤ 0x440 + i ∧ 0x440 + i < 0x540 + 55) by omega, ↓reduceIte]
    rw [← hG2]; exact setF_holds G1 VV _ i hi
  have hTC : Holds (setT G2 cnt) CB cnt := holds_word hcnt32
    (fun i hi => by
      rw [← hG2, ← hG1]
      simp only [setT, setF, setH, CB, VV, HB, show ¬ (0x540 + 51 ≤ 0x540 + i ∧ 0x540 + i < 0x540 + 55) by omega,
        show ¬ (0x440 ≤ 0x540 + i ∧ 0x540 + i < 0x440 + 55) by omega,
        show ¬ (0x500 + 23 ≤ 0x540 + i ∧ 0x540 + i < 0x500 + 23 + 32) by omega, ↓reduceIte, ↓reduceDIte]
      rw [hFm0 _ (by simp only [OUT]; omega) (by simp only [DATA]; omega)]; exact hcb i hi)
    (fun d hd => by
      simp only [setT, show CB + 51 ≤ CB + 51 + d ∧ CB + 51 + d < CB + 55 by omega, and_self, ↓reduceIte,
        show CB + 54 - (CB + 51 + d) = 3 - d by omega])
  have s170 : s17.reg S0 = base := by rw [r17, s160]
  obtain ⟨s18, e18, p18, mv18, k18⟩ := call_add hp hc0 hv0 hTc ⟨by decide, by decide, Or.inl (by decide)⟩
    hTV hTC (xi := 0x440) (yi := 0x540) (by decide) (by decide) (k := 44) (by decide) (by decide)
    (off := BitVec.ofInt 20 (2 * (55 - 46 : Int))) rfl (by decide) p17 mv17 s170
  have s180 : s18.reg S0 = base := by
    rw [k18 S0 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), s170]
  have s183 : s18.reg S3 = BitVec.ofNat 32 cnt := by
    rw [k18 S3 (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), r17, s163]
  have hc18 : CodeAt s18.mem base kernel := code_of_view hp hc0 hv0 mv18 (fun o ho => by
    simp only [setF, VV, show ¬ (0x440 ≤ o ∧ o < 0x440 + 55) by omega, ↓reduceIte]; exact hTc o ho)
  -- the counter one more, stored
  have e19 := run_line hp [.opi .addi S3 S3 1] (by decide) 47 s18 (by decide) (by rw [kernel_length]; decide) hc18 p18 hlen
  generalize hs19 : s18.line [.opi .addi S3 S3 1] = s19 at e19
  have s193 : s19.reg S3 = BitVec.ofNat 32 (cnt + 1) := by
    have : s19.reg S3 = s18.reg S3 + (1 : BitVec 12).signExtend 32 := by
      rw [← hs19]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S3]
    rw [this, s183]; apply BitVec.eq_of_toNat_eq; simp [BitVec.toNat_add]
  have s190 : s19.reg S0 = s18.reg S0 := by rw [← hs19]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S3, S0]
  have p19 : s19.pc = base + BitVec.ofNat 32 (4 * (47 + 1)) := by rw [← hs19]; exact line_pc_at _ p18 (by decide)
  have ms19 : s19.mem = s18.mem := by rw [← hs19, line_mem]
  obtain ⟨s20, e20, p20, m20, r20⟩ := storeStep hp 48 (by rw [kernel_length]; decide) (by rw [ms19]; exact hc18) p19
    (rs1 := S0) (rs2 := S3) (imm := 0x408) rfl (PAR + 8) (by rw [s190, s180]; rfl) (by decide) (by decide) hlen
  have hcnt1 : cnt + 1 < 2 ^ 32 := by omega
  have mv20 : View s20.mem base (setW (setF (setT G2 cnt) VV (v + hnum (hpre env v) + c + cnt)) (PAR + 8) (cnt + 1)) := by
    rw [m20, ms19, s193, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hcnt1]
    exact view_writeLE hp.fit mv18 (by decide) _
  -- HALT 0
  have hc20 : CodeAt s20.mem base kernel := code_of_view hp hc0 hv0 mv20 (fun o ho => by
    simp only [setW, setF, PAR, VV, show ¬ (0x400 + 8 ≤ o ∧ o < 0x400 + 8 + 4) by omega,
      show ¬ (0x440 ≤ o ∧ o < 0x440 + 55) by omega, ↓reduceIte]; exact hTc o ho)
  have e21 := run_line hp [.opi .addi A0 0 0, .opi .addi T0 0 1] (by decide) 49 s20 (by decide)
    (by rw [kernel_length]; decide) hc20 p20 hlen
  generalize hs21 : s20.line [.opi .addi A0 0 0, .opi .addi T0 0 1] = s21 at e21
  have g0 : s21.reg A0 = 0 := by rw [← hs21]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have g5 : s21.reg T0 = 1 := by rw [← hs21]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have p21 : s21.pc = base + BitVec.ofNat 32 (4 * (49 + 2)) := by rw [← hs21]; exact line_pc_at _ p20 (by decide)
  have hc21 : CodeAt s21.mem base kernel := by rw [← hs21, line_mem]; exact hc20
  have e22 := haltStep hp 51 (by rw [kernel_length]; decide) hc21 p21 rfl g5 hlen 0
  rw [g0] at e22
  -- one instruction before the halt, still running: COST m is exact, not a bound
  have e5' : run env 3 s4 = .running s5 := e5
  have e8' : run env 1 s7 = .running s8 := e8
  have e10' : run env 4 s9 = .running s10 := e10
  have e19' : run env 1 s18 = .running s19 := e19
  have e21' : run env 2 s20 = .running s21 := e21
  have r21 : run env (COST m - 1) s = .running s21 := by
    rw [show COST m - 1 = 3 + (1 + (3 + (6 * 55 + (1 + (1 + (566 * m + (4 + ((0 + 1) + ((3 + ADD) + ((3 + ADD)
      + (2 + (2 + (2 + (1 + ((3 + ADD) + (1 + (1 + (2 + 0)))))))))))))))))) by simp only [COST, ADD]; omega,
      run_add_running e3, run_add_running e4, run_add_running e5', run_add_running e6, run_add_running e7,
      run_add_running e8', run_add_running e9, run_add_running e10', run_add_running e11, run_add_running e12,
      run_add_running e13, run_add_running e14, run_add_running e15, run_add_running e16, run_add_running e17,
      run_add_running e18, run_add_running e19', run_add_running e20, run_add_running e21', run_zero]
  refine ⟨s21, r21, ?_, ?_⟩
  · rw [show COST m = (COST m - 1) + (0 + 1) by simp only [COST]; omega, run_add_running r21, e22]
  · rw [← hs21, line_mem]
    simp only [after, vnext]; rw [hFm, hG1, ← setF_setT G1 (v + hnum (hpre env v) + c), hG2]; exact mv20

/-! ## What `after` holds -/

/-- Block `j`'s byte `d` is byte `d` of Hash(V + j): Hashgen, §10.1.1.4 step 2. -/
theorem blocks_out (F : Nat → Byte) (v : Nat) : ∀ m j d, j < m → ∀ (hd : d < 32),
    blocks env F v m (OUT + 32 * j + d) = env.hash (digs (v + j)) ⟨d, hd⟩ := by
  intro m
  induction m with
  | zero => intro j d hj; omega
  | succ m ih =>
    intro j d hj hd
    simp only [blocks, setH]
    by_cases hjm : j = m
    · subst hjm
      simp only [show OUT + 32 * j ≤ OUT + 32 * j + d ∧ OUT + 32 * j + d < OUT + 32 * j + 32 by omega, and_self,
        ↓reduceDIte, Nat.add_sub_cancel_left]
    · simp only [show ¬ (OUT + 32 * m ≤ OUT + 32 * j + d ∧ OUT + 32 * j + d < OUT + 32 * m + 32) by omega,
        ↓reduceDIte]
      exact ih j d (by omega) hd

/-- Away from what a Generate writes, `after` is the image. -/
theorem after_keeps (F0 : Nat → Byte) (v c cnt m : Nat) {o : Nat} (h1 : o < OUT) (h2 : ¬ (DATA ≤ o ∧ o < DATA + 55))
    (h3 : ¬ (HB + 23 ≤ o ∧ o < HB + 55)) (h4 : ¬ (CB + 51 ≤ o ∧ o < CB + 55)) (h5 : ¬ (VV ≤ o ∧ o < VV + 55))
    (h6 : ¬ (PAR + 8 ≤ o ∧ o < PAR + 8 + 4)) : after env F0 v c cnt m o = F0 o := by
  simp only [after, setW, setF, setT, setH, h6, h5, ↓reduceIte, show ¬ (CB + 51 ≤ o ∧ o < CB + 55) from h4,
    show ¬ (HB + 23 ≤ o ∧ o < HB + 23 + 32) by omega, ↓reduceDIte, h2]
  exact blocks_low F0 v m o h1

/-- The bytes Generate returns, as `after` holds them. -/
theorem after_out (F0 : Nat → Byte) (v c cnt : Nat) {m j d : Nat} (hj : j < m) (hd : d < 32) :
    after env F0 v c cnt m (OUT + 32 * j + d) = env.hash (digs (v + j)) ⟨d, hd⟩ := by
  simp only [after, setW, setF, setT, setH, PAR, VV, CB, HB, DATA, OUT,
    show ¬ (0x400 + 8 ≤ 0x600 + 32 * j + d ∧ 0x600 + 32 * j + d < 0x400 + 8 + 4) by omega,
    show ¬ (0x440 ≤ 0x600 + 32 * j + d ∧ 0x600 + 32 * j + d < 0x440 + 55) by omega,
    show ¬ (0x540 + 51 ≤ 0x600 + 32 * j + d ∧ 0x600 + 32 * j + d < 0x540 + 55) by omega,
    show ¬ (0x500 + 23 ≤ 0x600 + 32 * j + d ∧ 0x600 + 32 * j + d < 0x500 + 23 + 32) by omega,
    show ¬ (0x4c0 ≤ 0x600 + 32 * j + d ∧ 0x600 + 32 * j + d < 0x4c0 + 55) by omega, ↓reduceIte, ↓reduceDIte]
  exact blocks_out F0 v m j d hj hd

theorem word_setW (F : Nat → Byte) (c : Nat) {n : Nat} (hn : n < 2 ^ 32) : word (setW F c n) c = n := by
  simp only [word, setW, show c ≤ c ∧ c < c + 4 by omega, show c ≤ c + 1 ∧ c + 1 < c + 4 by omega,
    show c ≤ c + 2 ∧ c + 2 < c + 4 by omega, show c ≤ c + 3 ∧ c + 3 < c + 4 by omega, and_self, ↓reduceIte,
    BitVec.toNat_ofNat, Nat.sub_self, Nat.add_sub_cancel_left]
  simp only [Nat.pow_zero, Nat.div_one, show (256 : Nat) ^ 2 = 65536 by rfl,
    show (256 : Nat) ^ 3 = 16777216 by rfl, show (2 : Nat) ^ 8 = 256 by rfl]
  omega

/-! ## From boot -/

/-- The image's bytes, by offset; 0 past its end. -/
def imgF (img : ByteArray) : Nat → Byte := fun o => if h : o < img.size then BitVec.ofNat 8 (img.get o h).toNat else 0

theorem view_image (img : ByteArray) : View (memOfImage base img) base (imgF img) := by
  intro o ho; unfold memOfImage imgF; simp only [Ct.off_of base o (by omega)]

/-- An image that begins with the kernel's 280 bytes holds the kernel. -/
theorem code_of_image (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 280 ≤ img.size) (himg : ∀ d (h : d < 280), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) (toBytes_words kernel) img
    (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **Generate, from boot.** An image holding the kernel and a state (V, C,
reseed_counter) with the counter at most the interval: `COST m` instructions
later the kernel halts with 0, and not one sooner (it is still running at
`COST m - 1`), the region `after`: Hashgen's `m` blocks at 0x600
(`after_out`), V the next V, the counter one more. -/
theorem from_boot (hp : Placed env base) (img : ByteArray) (hsize : 280 ≤ img.size)
    (himg : ∀ d (h : d < 280), img.get d (by omega) = bytes.getD d 0)
    {v c m cnt : Nat} (hV : Holds (imgF img) VV v) (hC : Holds (imgF img) CC c) (hone : Holds (imgF img) ONE 1)
    (hpre3 : imgF img PRE = 3) (hhb : ∀ i, i < 23 → imgF img (HB + i) = 0)
    (hcb : ∀ i, i < 51 → imgF img (CB + i) = 0)
    (hm : word (imgF img) PAR = m) (hcnt : word (imgF img) (PAR + 8) = cnt) (hm1 : 1 ≤ m)
    (hm2 : OUT + 32 * m < 0x10000) (hiv : word (imgF img) (PAR + 4) < 2 ^ 32 - 1)
    (hok : cnt ≤ word (imgF img) (PAR + 4)) :
    ∃ s', run env (COST m - 1) (boot env.region img) = .running s'
      ∧ run env (COST m) (boot env.region img) = .halted 0 s'
      ∧ View s'.mem base (after env (imgF img) v c cnt m) := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  exact generate_run hp hpc (by rw [hmem]; exact view_image img)
    (by rw [hmem]; exact code_of_image hp.fit img hsize himg) hV hC hone hpre3 hhb hcb hm hcnt hm1 hm2 hiv hok

/-- **Reseed required, from boot**: the counter past the interval, HALT 1
after seven instructions, the region the image. -/
theorem reseed_boot (hp : Placed env base) (img : ByteArray) (hsize : 280 ≤ img.size)
    (himg : ∀ d (h : d < 280), img.get d (by omega) = bytes.getD d 0)
    (hgt : word (imgF img) (PAR + 4) < word (imgF img) (PAR + 8)) :
    ∃ s', run env 7 (boot env.region img) = .halted 1 s' ∧ s'.mem = memOfImage base img := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  rw [← hmem]
  exact reseed_run hp hpc (by rw [hmem]; exact view_image img)
    (by rw [hmem]; exact code_of_image hp.fit img hsize himg) hgt

/-- **The second Generate**, as the shell runs it for NIST's vectors: the
kernel started again on the region the first left, any registers. It halts
with 0 after exactly `COST m` more, its blocks Hashgen of the next V, the counter
two more, as long as one more is still at most the interval. -/
theorem generate_twice (hp : Placed env base) (img : ByteArray) (hsize : 280 ≤ img.size)
    (himg : ∀ d (h : d < 280), img.get d (by omega) = bytes.getD d 0)
    {v c m cnt : Nat} (hV : Holds (imgF img) VV v) (hC : Holds (imgF img) CC c) (hone : Holds (imgF img) ONE 1)
    (hpre3 : imgF img PRE = 3) (hhb : ∀ i, i < 23 → imgF img (HB + i) = 0)
    (hcb : ∀ i, i < 51 → imgF img (CB + i) = 0)
    (hm : word (imgF img) PAR = m) (hcnt : word (imgF img) (PAR + 8) = cnt) (hm1 : 1 ≤ m)
    (hm2 : OUT + 32 * m < 0x10000) (hiv : word (imgF img) (PAR + 4) < 2 ^ 32 - 1)
    (hok : cnt + 1 ≤ word (imgF img) (PAR + 4)) {s : Machine} (hs : s.pc = base)
    (hrun : ∃ s1, run env (COST m) (boot env.region img) = .halted 0 s1 ∧ s.mem = s1.mem) :
    ∃ s', run env (COST m - 1) s = .running s' ∧ run env (COST m) s = .halted 0 s'
      ∧ View s'.mem base (after env (after env (imgF img) v c cnt m) (vnext env v c cnt) c (cnt + 1) m) := by
  obtain ⟨s1, e1, ms⟩ := hrun
  obtain ⟨s1', -, e1', mv1⟩ := from_boot hp img hsize himg hV hC hone hpre3 hhb hcb hm hcnt hm1 hm2 hiv (by omega)
  rw [e1] at e1'; cases e1'
  rw [← ms] at mv1
  have hk : ∀ o, o < OUT → ¬ (DATA ≤ o ∧ o < DATA + 55) → ¬ (HB + 23 ≤ o ∧ o < HB + 55) →
      ¬ (CB + 51 ≤ o ∧ o < CB + 55) → ¬ (VV ≤ o ∧ o < VV + 55) → ¬ (PAR + 8 ≤ o ∧ o < PAR + 8 + 4) →
      after env (imgF img) v c cnt m o = imgF img o := fun o a b c' d e f => after_keeps _ v c cnt m a b c' d e f
  have hcnt32 : cnt < 2 ^ 32 := hcnt ▸ word_lt _ _
  have hw : ∀ c', c' + 4 ≤ PAR + 8 → word (after env (imgF img) v c cnt m) c' = word (imgF img) c' := by
    intro c' hc'
    simp only [word]
    rw [hk c' (by simp only [OUT, PAR] at *; omega) (by simp only [DATA, PAR] at *; omega)
        (by simp only [HB, PAR] at *; omega) (by simp only [CB, PAR] at *; omega) (by simp only [VV, PAR] at *; omega)
        (by omega),
      hk (c' + 1) (by simp only [OUT, PAR] at *; omega) (by simp only [DATA, PAR] at *; omega)
        (by simp only [HB, PAR] at *; omega) (by simp only [CB, PAR] at *; omega) (by simp only [VV, PAR] at *; omega)
        (by omega),
      hk (c' + 2) (by simp only [OUT, PAR] at *; omega) (by simp only [DATA, PAR] at *; omega)
        (by simp only [HB, PAR] at *; omega) (by simp only [CB, PAR] at *; omega) (by simp only [VV, PAR] at *; omega)
        (by omega),
      hk (c' + 3) (by simp only [OUT, PAR] at *; omega) (by simp only [DATA, PAR] at *; omega)
        (by simp only [HB, PAR] at *; omega) (by simp only [CB, PAR] at *; omega) (by simp only [VV, PAR] at *; omega)
        (by omega)]
  have hcode : ∀ o, o < 4 * 70 → after env (imgF img) v c cnt m o = imgF img o := fun o ho =>
    hk o (by simp only [OUT]; omega) (by simp only [DATA]; omega) (by simp only [HB]; omega)
      (by simp only [CB]; omega) (by simp only [VV]; omega) (by simp only [PAR]; omega)
  have hfield : ∀ X N, Holds (imgF img) X N → X + 55 ≤ HB + 23 ∨ (HB + 55 ≤ X ∧ X + 55 ≤ CB + 51) ∨
      (CB + 55 ≤ X ∧ X + 55 ≤ OUT) → ¬ (X < VV + 55 ∧ VV < X + 55) → ¬ (X < DATA + 55 ∧ DATA < X + 55) →
      PAR + 12 ≤ X → Holds (after env (imgF img) v c cnt m) X N := fun X N h hx h1 h2 h3 i hi => by
    rw [hk (X + i) (by simp only [OUT, HB, CB] at *; omega) (by simp only [DATA] at *; omega)
      (by simp only [HB, CB, OUT] at *; omega) (by simp only [HB, CB, OUT] at *; omega)
      (by simp only [VV] at *; omega) (by simp only [PAR] at *; omega)]
    exact h i hi
  refine generate_run hp hs mv1 (code_of_view hp (code_of_image hp.fit img hsize himg) (view_image img)
    mv1 hcode) ?_ (hfield CC c hC (by simp only [CC, HB]; omega) (by simp only [CC, VV]; omega)
      (by simp only [CC, DATA]; omega) (by simp only [CC, PAR]; omega))
    (hfield ONE 1 hone (by simp only [ONE, CB, OUT]; omega) (by simp only [ONE, VV]; omega)
      (by simp only [ONE, DATA]; omega) (by simp only [ONE, PAR]; omega))
    ?_ ?_ ?_ (by rw [hw PAR (by simp only [PAR]; omega), hm])
    (by simp only [after]; rw [word_setW _ _ (by omega)]) hm1 hm2
    (by rw [hw (PAR + 4) (by omega)]; exact hiv) (by rw [hw (PAR + 4) (by omega)]; exact hok)
  · intro i hi; simp only [after, setW, PAR, VV, show ¬ (0x400 + 8 ≤ 0x440 + i ∧ 0x440 + i < 0x400 + 8 + 4) by omega,
      ↓reduceIte]; exact setF_holds _ VV _ i hi
  · rw [hk PRE (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)]; exact hpre3
  · intro i hi
    rw [hk (HB + i) (by simp only [HB, OUT]; omega) (by simp only [HB, DATA]; omega) (by simp only [HB]; omega)
      (by simp only [HB, CB]; omega) (by simp only [HB, VV]; omega) (by simp only [HB, PAR]; omega)]; exact hhb i hi
  · intro i hi
    rw [hk (CB + i) (by simp only [CB, OUT]; omega) (by simp only [CB, DATA]; omega) (by simp only [CB, HB]; omega)
      (by simp only [CB]; omega) (by simp only [CB, VV]; omega) (by simp only [CB, PAR]; omega)]; exact hcb i hi

end Drbg
