/-
SPDX-License-Identifier: Apache-2.0

# exp206 — an MSS verify kernel: WOTS under a Merkle tree of height 4, proved

The kernel, as data; its bytes, which are `kernel.bin`; and what they do,
for every message, signature, index, authentication path, root and HASH.
-/
import Rv32.Wots
import Rv32.Asm

set_option maxRecDepth 20000

namespace Exp206
open Rv32 Rv32.Wots

def A7 : Reg := 17

/-- After chain `i`'s walk: its end, from the buffer to `KEY + 32 i`. -/
def store : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T4 S5 (BitVec.ofNat 12 (4 * j)), .st .sw S2 T4 (BitVec.ofNat 12 (4 * j))]

/-- On to the next chain: back to the copy at 46, or past the last. -/
def advance : List Instr := [
  .opi .addi S1 S1 32, .opi .addi S2 S2 32, .opi .addi A4 A4 1, .br .bne A4 S7 0xfac ]

/-- 32 zeros after the 67 ends, so that they are a whole number of blocks. -/
def pad : List Instr := (List.range 8).map fun j => .st .sw S2 0 (BitVec.ofNat 12 (4 * j))

/-- The leaf: HASH of the 2176 bytes from `KEY`, into the node at `KEY + 0x880`. -/
def leaf : List Instr := [
  .lui T1 3, .op .add A0 S0 T1, .opi .addi A1 0 1088, .op .add A1 A1 A1, .opi .addi A2 S2 32, .ecall ]

/-- The tree: HASH's input at `KEY + 0x8c0`, 64 bytes, and its second half;
the path; the index; four levels. -/
def climb : List Instr := [
  .opi .addi A0 S2 96, .opi .addi A7 S2 128, .opi .addi A1 0 64, .lui T1 4, .op .add S4 S0 T1,
  .ld .lbu A3 S3 32, .opi .addi A6 0 4 ]

/-- One level. Bit `j` of the index picks which side the node goes on, with
no branch: `t2` is the two pointers' difference where the bit is set, so
`a4` and `a5` are the node and the path's node, in one order or the other. -/
def level : List Instr := [
  .opi .andi T1 A3 1, .op .sub T1 0 T1, .op .xor T2 A2 S4, .op .and T2 T2 T1,
  .op .xor A4 A2 T2, .op .xor A5 S4 T2 ] ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 A4 (BitVec.ofNat 12 (4 * j)), .st .sw A0 T4 (BitVec.ofNat 12 (4 * j))]) ++
  ((List.range 8).flatMap fun j =>
    [.ld .lw T4 A5 (BitVec.ofNat 12 (4 * j)), .st .sw A7 T4 (BitVec.ofNat 12 (4 * j))]) ++
  [ .ecall, .opi .addi S4 S4 32, .sh .srli A3 A3 1, .opi .addi A6 A6 0xfff, .br .bne A6 0 0xfac ]

def compare : List Instr :=
  (List.range 8).flatMap fun j =>
    [.ld .lw T2 A2 (BitVec.ofNat 12 (4 * j)), .ld .lw T3 S4 (BitVec.ofNat 12 (4 * j)),
     .op .xor T2 T2 T3, .op .or S6 S6 T2]

def finish : List Instr := [ .op .sltu A0 0 S6, .opi .addi T0 0 1, .ecall ]

def kernel : List Instr :=
  Wots.head ++ store ++ advance ++ pad ++ leaf ++ climb ++ level ++ compare ++ finish

/-- The kernel as bytes. This is `kernel.bin`, and the only thing on the chip
the theorems are about. -/
def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

theorem kernel_length : kernel.length = 188 := by rfl

/-- The kernel starts with `head`, so everything `lean/Rv32/Wots.lean` proves
of the first 69 instructions holds of it. -/
theorem starts : Starts kernel where
  pre := fun k hk => by
    simp only [kernel, List.append_assoc, List.getD_eq_getElem?_getD,
      List.getElem?_append_left (show k < head.length by rw [head_length]; exact hk)]
  long := by rw [kernel_length]; decide
  below := by rw [kernel_length]; decide

/-! ## Where everything is

Offsets from `base`, as in exp205 (`lean/Rv32/Wots.lean`), and these. -/

/-- The leaf's index: one byte, of which the low four bits are read. -/
def IDX : Nat := 0x1020
/-- The authentication path: level `j`'s sibling at `AUTH + 32 j`, `j < 4`. -/
def AUTH : Nat := 0x4000
/-- The root: the public key. -/
def ROOT : Nat := 0x4080
/-- The node, at `KEY + 0x880`: the leaf, then each level's. -/
def CUR : Nat := 0x3880
/-- A tree step's HASH input, 64 bytes, at `KEY + 0x8c0`. -/
def NODE : Nat := 0x38c0

/-! ## What is proved: MSS verification

`H` is `env.hash`, and nothing is assumed about it. The chains are exp205's;
their ends, instead of being compared with a public key, make a leaf, and the
leaf climbs the tree. -/

/-- HASH, as a list. -/
def hashL (H : List Byte → Fin 32 → Byte) (x : List Byte) : List Byte := List.ofFn (H x)

/-- Chain `i`'s end: `15 - dᵢ` steps from the signature. -/
def endAt (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) : List Byte :=
  chain H (sigAt m base i) (15 - digit m base i)

/-- The first `n` chain ends, one after another. -/
def endsTo (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Nat → List Byte
  | 0 => []
  | n + 1 => endsTo H m base n ++ endAt H m base n

/-- The leaf: HASH of the 67 ends and 32 zeros, 2176 bytes. -/
def leafOf (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : List Byte :=
  hashL H (endsTo H m base 67 ++ List.replicate 32 0)

def idx (m : Word → Byte) (base : Word) : Nat := (m (base + BitVec.ofNat 32 IDX)).toNat

def authAt (m : Word → Byte) (base : Word) (j : Nat) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 (AUTH + 32 * j)) 32

def rootAt (m : Word → Byte) (base : Word) : List Byte :=
  readBytes m (base + BitVec.ofNat 32 ROOT) 32

/-- One level up: the node on the left when bit `j` of the index is 0, on
the right when it is 1. -/
def up (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (j : Nat) (node : List Byte) :
    List Byte :=
  if idx m base / 2 ^ j % 2 = 0 then hashL H (node ++ authAt m base j) else hashL H (authAt m base j ++ node)

/-- The node after `j` levels. -/
def climbTo (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Nat → List Byte
  | 0 => leafOf H m base
  | j + 1 => up H m base j (climbTo H m base j)

/-- **The signature verifies**: four levels up from the leaf is the root. -/
def Verifies (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Prop :=
  climbTo H m base 4 = rootAt m base

instance (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    Decidable (Verifies H m base) := by unfold Verifies; infer_instance

/-! ## Lists and memory -/

theorem chain_length (H : List Byte → Fin 32 → Byte) {x : List Byte} (hx : x.length = 32) :
    ∀ k, (chain H x k).length = 32
  | 0 => hx
  | k + 1 => by simp [chain, F]

theorem endAt_length (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (i : Nat) :
    (endAt H m base i).length = 32 :=
  chain_length H (readBytes_length _ _ _) _

/-- `n` bytes from `a` of an overlay that starts there are the overlay's. -/
theorem readBytes_overlay {m : Word → Byte} {a : Word} {n : Nat} {l : List Byte} (hl : l.length = n)
    (hn : n < 2 ^ 32) : readBytes (overlay m a n (fun d => l.getD d 0)) a n = l := by
  apply List.ext_getElem (by rw [readBytes_length, hl])
  intro d h1 h2
  have hd : d < n := by rw [readBytes_length] at h1; exact h1
  rw [readBytes_getElem _ _ _ _ hd]
  unfold overlay
  have : (a + BitVec.ofNat 32 d - a).toNat = d := by
    rw [BitVec.add_comm, BitVec.add_sub_cancel, BitVec.toNat_ofNat]; omega
  simp only [this, hd, ↓reduceIte, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h2, Option.getD_some]

/-- Two overlays of the same place agree when what they put there does. -/
theorem overlay_congr {m : Word → Byte} {a : Word} {n : Nat} {f g : Nat → Byte}
    (h : ∀ d < n, f d = g d) : overlay m a n f = overlay m a n g := by
  funext x; unfold overlay; split
  · exact h _ (by assumption)
  · rfl

/-- Memory that changed only in scratch, overlaid in the same place: still
changed only in scratch. -/
theorem keeps_overlay_both {S : Word} {N : Nat} {M m : Word → Byte} (h : Keeps S N M m) (a : Word) (n : Nat)
    (f : Nat → Byte) : Keeps S N (overlay M a n f) (overlay m a n f) := by
  intro x hx; unfold overlay; split
  · rfl
  · exact h x hx

/-- What the input is, outside scratch, once `i` chain ends are written at
`KEY`. -/
def endsMem (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) : Nat → Word → Byte
  | 0 => m
  | i + 1 => overlay (endsMem H m base i) (base + BitVec.ofNat 32 (KEY + 32 * i)) 32
      (fun d => (endAt H m base i).getD d 0)

theorem endsMem_off {H : List Byte → Fin 32 → Byte} {m : Word → Byte} {base : Word}
    (hfit : base.toNat + 0x10000 ≤ 2^32) {c : Nat} (hc : c < 0x10000) :
    ∀ i ≤ 67, (c < KEY ∨ KEY + 32 * i ≤ c) → endsMem H m base i (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c)
  | 0, _, _ => rfl
  | i + 1, hi, hout => by
    simp only [endsMem]
    rw [overlay_off_out hfit _ _ (by simp only [KEY]; omega) hc (by simp only [KEY] at hout ⊢; omega)]
    exact endsMem_off hfit hc i (by omega) (by simp only [KEY] at hout ⊢; omega)

theorem endsMem_keeps {H : List Byte → Fin 32 → Byte} {m : Word → Byte} {base : Word}
    (hfit : base.toNat + 0x10000 ≤ 2^32) : ∀ i ≤ 67, Keeps (base + BitVec.ofNat 32 KEY) 0x900 m (endsMem H m base i)
  | 0, _ => Keeps.refl _ _ _
  | i + 1, hi => (endsMem_keeps hfit i (by omega)).trans
      (keeps_overlay hfit _ _ (by omega) (by simp only [KEY]; omega) (by simp only [KEY]; omega))

theorem readBytes_ends {H : List Byte → Fin 32 → Byte} {m : Word → Byte} {base : Word}
    (hfit : base.toNat + 0x10000 ≤ 2^32) :
    ∀ i ≤ 67, readBytes (endsMem H m base i) (base + BitVec.ofNat 32 KEY) (32 * i) = endsTo H m base i
  | 0, _ => rfl
  | i + 1, hi => by
    rw [show 32 * (i + 1) = 32 * i + 32 by omega, readBytes_append, off_add hfit _ _ (by simp only [KEY]; omega)]
    simp only [endsTo]
    congr 1
    · rw [← readBytes_ends hfit i (by omega)]
      apply readBytes_congr
      intro d hd
      simp only [endsMem]
      rw [off_add hfit _ _ (by simp only [KEY]; omega),
        overlay_off_out hfit _ _ (by simp only [KEY]; omega) (by simp only [KEY]; omega) (by left; omega)]
    · simp only [endsMem]
      exact readBytes_overlay (endAt_length H m base i) (by decide)

/-- The signature is where it was: chain ends are written elsewhere. -/
theorem sigAt_ends {H : List Byte → Fin 32 → Byte} {m : Word → Byte} {base : Word}
    (hfit : base.toNat + 0x10000 ≤ 2^32) {i j : Nat} (hi : i ≤ 67) (hj : j < 67) :
    sigAt (endsMem H m base i) base j = sigAt m base j := by
  unfold sigAt
  apply readBytes_congr
  intro d hd
  rw [off_add hfit _ _ (by simp only [SIG]; omega)]
  exact endsMem_off hfit (by simp only [SIG]; omega) i hi (by left; simp only [SIG, KEY]; omega)

/-! ## The bytes are the kernel, instruction by instruction -/

theorem at_store : ∀ j < 8, kernel.getD (69 + 2 * j) .ecall = .ld .lw T4 S5 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (69 + 2 * j + 1) .ecall = .st .sw S2 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_pad : ∀ j < 8, kernel.getD (89 + j) .ecall = .st .sw S2 0 (BitVec.ofNat 12 (0 + 4 * j)) := by
  decide
theorem at_left : ∀ j < 8, kernel.getD (116 + 2 * j) .ecall = .ld .lw T4 A4 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (116 + 2 * j + 1) .ecall = .st .sw A0 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_right : ∀ j < 8, kernel.getD (132 + 2 * j) .ecall = .ld .lw T4 A5 (BitVec.ofNat 12 (4 * j))
    ∧ kernel.getD (132 + 2 * j + 1) .ecall = .st .sw A7 T4 (BitVec.ofNat 12 (4 * j)) := by
  decide
theorem at_cmp : ∀ j < 8, kernel.getD (153 + 4 * j) .ecall = .ld .lw T2 A2 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (153 + 4 * j + 1) .ecall = .ld .lw T3 S4 (BitVec.ofNat 12 (0 + 4 * j))
    ∧ kernel.getD (153 + 4 * j + 2) .ecall = .op .xor T2 T2 T3
    ∧ kernel.getD (153 + 4 * j + 3) .ecall = .op .or S6 S6 T2 := by
  decide

/-! ## The chains -/

/-- At the top of chain `i` — or, once `i` is 67, at the padding: what
`Chains` says, with the first `i` ends written at `KEY` outside scratch, and
`s2` where the next end goes. -/
structure CInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (i : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 67 then 46 else 89))
  ch : Chains base (endsMem H m0 base i) m0 i s
  s2 : s.reg S2 = base + BitVec.ofNat 32 (KEY + 32 * i)
  rg : Regs base s
  s6 : s.reg S6 = 0

/-- **One chain**: `40 + 3 (15 - dᵢ)` instructions — the copy, the walk, its
end stored at `KEY + 32 i`, and on to the next. -/
theorem chain_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {i : Nat} (hi : i < 67) {s : Machine} (h : CInv env.hash base m0 i s) :
    ∃ s', run env (40 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
  have fit := hp.fit
  have hd := digit_lt m0 base i
  have hcM : CodeAt (endsMem env.hash m0 base i) base kernel :=
    (endsMem_keeps fit i (by omega)).code fit (by simp only [KEY]; omega) (by rw [kernel_length]; decide) hc0
  obtain ⟨sf, ef, pf, tf, bf, of, lf, df, kf⟩ :=
    fetch starts hp hcM hi (by rw [h.pc]; simp [hi]) h.ch
  rw [sigAt_ends fit (by omega) hi] at bf
  obtain ⟨sw, ew, pw, ww, kw⟩ := skip_or_walk starts hp hcM (x := sigAt m0 base i) (15 - digit m0 base i)
    (by omega) pf tf (by rw [kf _ (by decide) (by decide) (by decide), h.ch.t0])
    (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a0])
    (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a1])
    (by rw [kf _ (by decide) (by decide) (by decide), h.ch.a2]) ⟨by rw [bf]; rfl, of, lf, df⟩
  have kfw : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → sw.reg r = s.reg r := fun r a b c => (kw r b).trans (kf r a b c)
  have hcw : CodeAt sw.mem base kernel :=
    ww.out.code fit (by simp only [SCR]; omega) (by rw [kernel_length]; decide) hcM
  -- the end, from the buffer to `KEY + 32 i`
  obtain ⟨sq, eq, pq, mq, kq⟩ := (copy_words (prog := kernel) hp (k0 := 69) (rs := S5) (rd := S2) (t := T4)
    (src := SCR) (dst := KEY + 32 * i) at_store (by rw [kernel_length]; decide) (by decide) (by decide)
    (by decide) (by decide) (by simp only [KEY]; omega) (by decide) (by simp only [KEY]; omega)
    (by rw [kernel_length]; simp only [KEY]; omega) (by right; simp only [SCR, KEY]; omega)
    pw hcw (by rw [kfw _ (by decide) (by decide) (by decide), h.ch.s5])
    (by rw [kfw _ (by decide) (by decide) (by decide), h.s2])) 8 (Nat.le_refl _)
  have kwq : ∀ r, r ≠ T4 → r ≠ T3 → r ≠ T2 → sq.reg r = s.reg r :=
    fun r a b c => (kq r a).trans (kfw r a b c)
  have hcq : CodeAt sq.mem base kernel := by
    rw [mq]; exact code_of_overlay fit hcw (by rw [kernel_length]; simp only [KEY]; omega)
      (by simp only [KEY]; omega) _
  -- addi s1, s1, 32; addi s2, s2, 32; addi a4, a4, 1
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 85 (by decide) hcq pq
    (i := .opi .addi S1 S1 32) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 86 (by decide) (by rw [m1]; exact hcq) p1
    (i := .opi .addi S2 S2 32) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 87 (by decide) (by rw [m2, m1]; exact hcq) p2
    (i := .opi .addi A4 A4 1) (by decide) rfl
  have hc3 : CodeAt s3.mem base kernel := by rw [m3, m2, m1]; exact hcq
  have k3 : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → s3.reg r = s.reg r :=
    fun r a b c d e f => by rw [reg_kept r3 c, reg_kept r2 b, reg_kept r1 a, kwq r d e f]
  have v_a4 : s3.reg A4 = base + BitVec.ofNat 32 (SCR + 64 + (i + 1)) := by
    rw [reg_wrote r3 (by decide), reg_kept r2 (by decide), reg_kept r1 (by decide),
      kwq _ (by decide) (by decide) (by decide), h.ch.a4]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide,
      off_add fit _ _ (by simp only [SCR]; omega), Nat.add_assoc]
  have v_s7 : s3.reg S7 = base + BitVec.ofNat 32 (SCR + 64 + 67) := by
    rw [k3 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.s7]
  have ht : taken .bne (s3.reg A4) (s3.reg S7) = decide (i + 1 < 67) := by
    rw [v_a4, v_s7]; simp only [taken]
    by_cases hl : i + 1 < 67
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [toNat_off fit _ (by simp only [SCR]; omega), toNat_off fit _ (by simp only [SCR]; omega)] at this
      omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show i + 1 = 67 by omega]
  -- the memory: the end, written over what was there
  have hbuf : ∀ d < 32, sw.mem (base + BitVec.ofNat 32 (SCR + d)) = (endAt env.hash m0 base i).getD d 0 := by
    intro d hd'
    have hl : d < (endAt env.hash m0 base i).length := by rw [endAt_length]; exact hd'
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hl, Option.getD_some,
      ← off_add fit SCR d (by simp only [SCR]; omega), ← readBytes_getElem sw.mem (base + BitVec.ofNat 32 SCR) 32 d hd']
    exact List.getElem_of_eq ww.buf _
  have mem3 : s3.mem = overlay sw.mem (base + BitVec.ofNat 32 (KEY + 32 * i)) 32
      (fun d => (endAt env.hash m0 base i).getD d 0) := by
    rw [m3, m2, m1, mq]; exact overlay_congr (fun d hd' => hbuf d hd')
  -- What the branch leaves, whichever way it goes.
  have finish : ∀ s4 : Machine, run env 1 s3 = .running s4 → (∀ r, s4.reg r = s3.reg r) →
      s4.mem = s3.mem → s4.pc = base + BitVec.ofNat 32 (4 * (if i + 1 < 67 then 46 else 89)) →
      ∃ s', run env (40 + 3 * (15 - digit m0 base i)) s = .running s' ∧ CInv env.hash base m0 (i + 1) s' := by
    intro s4 e4 b4 m4 p4
    have kept : ∀ r, r ≠ S1 → r ≠ S2 → r ≠ A4 → r ≠ T4 → r ≠ T3 → r ≠ T2 → s4.reg r = s.reg r :=
      fun r a b c d e f => by rw [b4, k3 r a b c d e f]
    have mm : s4.mem = overlay sw.mem (base + BitVec.ofNat 32 (KEY + 32 * i)) 32
        (fun d => (endAt env.hash m0 base i).getD d 0) := by rw [m4, mem3]
    have far : ∀ c, SCR ≤ c → c < 0x10000 → s4.mem (base + BitVec.ofNat 32 c) = sw.mem (base + BitVec.ofNat 32 c) := by
      intro c h1 h2
      rw [mm, overlay_off_out fit _ _ (by simp only [KEY]; omega) h2 (by right; simp only [KEY, SCR] at h1 ⊢; omega)]
    refine ⟨s4, ?_, p4, ⟨?_, by rw [b4, v_a4], ?_, by rw [b4, v_s7], ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_, ?_, ?_⟩
    · rw [show 40 + 3 * (15 - digit m0 base i) = 19 + ((1 + 3 * (15 - digit m0 base i)) + (16 + (1 + (1 + (1 + 1)))))
        by omega, run_add_running ef, run_add_running ew, run_add_running eq]
      exact run_cons e1 (run_cons e2 (run_cons e3 e4))
    · rw [b4, reg_kept r3 (by decide), reg_kept r2 (by decide), reg_wrote r1 (by decide),
        kwq _ (by decide) (by decide) (by decide), h.ch.s1]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [SIG]; omega)]
      congr 2
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.s5]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.ch.a2]
    · rw [mm]; simp only [endsMem]; exact keeps_overlay_both ww.out _ _ _
    · intro d hd'
      rw [Nat.add_assoc, far _ (by simp only [SCR]; omega) (by simp only [SCR]; omega), ← Nat.add_assoc]
      exact ww.tail d hd'
    · intro d hd'
      rw [Nat.add_assoc, far _ (by simp only [SCR]; omega) (by simp only [SCR]; omega), ← Nat.add_assoc]
      exact ww.dig d hd'
    · rw [b4, reg_kept r3 (by decide), reg_wrote r2 (by decide), reg_kept r1 (by decide),
        kwq _ (by decide) (by decide) (by decide), h.s2]
      simp only [aluI]
      rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [KEY]; omega)]
      congr 2
    · exact ⟨by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s0],
        by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s3],
        by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.rg.s5]⟩
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s6]
  by_cases hl : i + 1 < 67
  · have e4 : run env 1 s3 = .running (s3.setPc (s3.pc + ((0xfac : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 88 (by decide) hc3 p3 (i := .br .bne A4 S7 0xfac) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, p3]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 s3 = .running s3.next :=
      (stepK (prog := kernel) hp 88 (by decide) hc3 p3 (i := .br .bne A4 S7 0xfac) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, p3]
    exact pc_next fit 88 (by decide)

/-- The instructions the first `n` chains take: each `40 + 3 (15 - dᵢ)`. -/
def loopCount (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 40 + 3 * (15 - digit m base i)).sum

def stepsTo (m : Word → Byte) (base : Word) (n : Nat) : Nat :=
  ((List.range n).map fun i => 15 - digit m base i).sum

theorem loopCount_eq (m : Word → Byte) (base : Word) (n : Nat) :
    loopCount m base n = 40 * n + 3 * stepsTo m base n := by
  induction n with
  | zero => simp [loopCount, stepsTo]
  | succ n ih =>
    simp only [loopCount, stepsTo, List.range_succ, List.map_append, List.sum_append, List.map_cons,
      List.map_nil, List.sum_cons, List.sum_nil] at *
    rw [ih]; omega

/-- 67 chains, by induction: after `j` of them, the invariant holds for `j`. -/
theorem chain_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 0 s) :
    ∀ j ≤ 67, ∃ s', run env (loopCount m0 base j) s = .running s' ∧ CInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := chain_iter hp hc0 (by omega) hs'
    refine ⟨s'', ?_, hs''⟩
    rw [show loopCount m0 base (j + 1) = loopCount m0 base j + (40 + 3 * (15 - digit m0 base j)) by
      simp [loopCount, List.range_succ, List.sum_append], run_add_running e, e']

/-! ## Writing only in two places

From here on memory changes inside the `0x900` bytes from `KEY` — the ends,
the node, a tree step's input — or inside exp205's 131 bytes of scratch. -/

/-- `m'` is `m` outside the two places the kernel writes. -/
def Writes (base : Word) (m m' : Word → Byte) : Prop :=
  ∀ x, ¬ (x - (base + BitVec.ofNat 32 KEY)).toNat < 0x900 → ¬ (x - (base + BitVec.ofNat 32 SCR)).toNat < 131 →
    m' x = m x

theorem Writes.of {base : Word} {m E S : Word → Byte} (hK : Keeps (base + BitVec.ofNat 32 KEY) 0x900 m E)
    (hS : Keeps (base + BitVec.ofNat 32 SCR) 131 E S) : Writes base m S :=
  fun x h1 h2 => (hS x h2).trans (hK x h1)

theorem Writes.then {base : Word} {m S S' : Word → Byte} (h : Writes base m S)
    (hK : Keeps (base + BitVec.ofNat 32 KEY) 0x900 S S') : Writes base m S' :=
  fun x h1 h2 => (hK x h1).trans (h x h1 h2)

/-- An address `c` past `base`, not among the `N` from `S`. -/
theorem outside {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {S N c : Nat} (hSN : S + N < 0x10000)
    (hc : c < 0x10000) (hout : c < S ∨ S + N ≤ c) :
    ¬ (base + BitVec.ofNat 32 c - (base + BitVec.ofNat 32 S)).toNat < N := by
  rw [toNat_sub_off hfit _ S (by omega), toNat_off hfit c hc]
  have := base.isLt
  rw [wrapdist _ _ (by omega) (by omega)]
  split <;> omega

theorem Writes.off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte}
    (h : Writes base m m') {c : Nat} (hc : c < 0x10000)
    (hout : c < KEY ∨ (KEY + 0x900 ≤ c ∧ c < SCR) ∨ SCR + 131 ≤ c) :
    m' (base + BitVec.ofNat 32 c) = m (base + BitVec.ofNat 32 c) := by
  apply h
  · exact outside hfit (by simp only [KEY]; omega) hc (by simp only [KEY, SCR] at hout ⊢; omega)
  · exact outside hfit (by simp only [SCR]; omega) hc (by simp only [KEY, SCR] at hout ⊢; omega)

theorem Writes.code {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte}
    (h : Writes base m m') (hc : CodeAt m base kernel) : CodeAt m' base kernel := by
  refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => ?_) hc
  have hx : x = base + BitVec.ofNat 32 (x.toNat - base.toNat) := by
    apply BitVec.eq_of_toNat_eq; rw [toNat_off hfit _ (by rw [kernel_length] at h2; omega)]; omega
  rw [kernel_length] at h2
  rw [hx]; exact (h.off hfit (by omega) (by left; simp only [KEY]; omega)).symm

theorem Writes.bytes {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {m m' : Word → Byte}
    (h : Writes base m m') {c : Nat} (hc : c + 32 ≤ 0x10000)
    (hout : c + 32 ≤ KEY ∨ (KEY + 0x900 ≤ c ∧ c + 32 ≤ SCR)) :
    readBytes m' (base + BitVec.ofNat 32 c) 32 = readBytes m (base + BitVec.ofNat 32 c) 32 := by
  apply readBytes_congr
  intro d hd
  rw [off_add hfit _ _ (by omega)]
  exact h.off hfit (by omega) (by simp only [KEY, SCR] at hout ⊢; omega)

/-! ## The words the tree needs -/

/-- `andi 1`: the low bit. -/
theorem and1 (b : Nat) (hb : b < 2^32) :
    BitVec.ofNat 32 b &&& BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 (b % 2) := by
  rw [show BitVec.signExtend 32 (1 : BitVec 12) = BitVec.ofNat 32 1 by decide]
  apply BitVec.eq_of_toNat_eq
  simp only [BitVec.toNat_and, BitVec.toNat_ofNat]
  rw [show (1 : Nat) % 2^32 = 2^1 - 1 by decide, Nat.and_two_pow_sub_one_eq_mod]
  omega

/-- The branch-free choice: with `t = 0 - bit`, `x ^ ((x ^ y) & t)` is `x`
when the bit is 0 and `y` when it is 1, and `y ^ ((x ^ y) & t)` the other. -/
theorem sel (x y : Word) (b : Nat) (hb : b < 2) :
    x ^^^ ((x ^^^ y) &&& (0 - BitVec.ofNat 32 b)) = (if b = 0 then x else y)
      ∧ y ^^^ ((x ^^^ y) &&& (0 - BitVec.ofNat 32 b)) = (if b = 0 then y else x) := by
  rcases (by omega : b = 0 ∨ b = 1) with rfl | rfl
  · simp
  · have : (0 : Word) - BitVec.ofNat 32 1 = BitVec.allOnes 32 := by decide
    simp only [this, BitVec.and_allOnes, Nat.one_ne_zero, ↓reduceIte]
    constructor
    · rw [← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]
    · rw [BitVec.xor_comm x y, ← BitVec.xor_assoc, BitVec.xor_self, BitVec.zero_xor]

/-! ## The leaf, and the start of the climb -/

/-- At the top of level `k` — or, once `k` is 4, at the compare: the index
shifted `k` times, the path's pointer at level `k`, the node at `CUR`
`k` levels up from the leaf, and memory the input outside the two places. -/
structure LInv (H : List Byte → Fin 32 → Byte) (base : Word) (m0 : Word → Byte) (k : Nat)
    (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if k < 4 then 110 else 153))
  a3 : s.reg A3 = BitVec.ofNat 32 (idx m0 base / 2 ^ k)
  s4 : s.reg S4 = base + BitVec.ofNat 32 (AUTH + 32 * k)
  a6 : s.reg A6 = BitVec.ofNat 32 (4 - k)
  a2 : s.reg A2 = base + BitVec.ofNat 32 CUR
  a0 : s.reg A0 = base + BitVec.ofNat 32 NODE
  a7 : s.reg A7 = base + BitVec.ofNat 32 (NODE + 32)
  a1 : s.reg A1 = BitVec.ofNat 32 64
  t0 : s.reg T0 = 0
  s6 : s.reg S6 = 0
  cur : readBytes s.mem (base + BitVec.ofNat 32 CUR) 32 = climbTo H m0 base k
  out : Writes base m0 s.mem

/-- The 2176 bytes the leaf is HASH of: the 67 ends, then the padding's zeros. -/
theorem leaf_input {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 m : Word → Byte} (h : Keeps (base + BitVec.ofNat 32 SCR) 131 (endsMem H m0 base 67) m) :
    readBytes (overlay m (base + BitVec.ofNat 32 (KEY + 32 * 67 + 0)) (4 * 8) (fun _ => 0))
      (base + BitVec.ofNat 32 KEY) 2176 = endsTo H m0 base 67 ++ List.replicate 32 0 := by
  rw [show (2176 : Nat) = 32 * 67 + 32 by rfl, readBytes_append, off_add hfit _ _ (by simp only [KEY]; omega)]
  refine app_congr ?_ ?_
  · rw [← readBytes_ends hfit 67 (Nat.le_refl _)]
    apply readBytes_congr
    intro d hd
    rw [off_add hfit _ _ (by simp only [KEY]; omega),
      overlay_off_out hfit _ _ (by simp only [KEY]; omega) (by simp only [KEY]; omega) (by left; omega)]
    exact h.off hfit (by simp only [SCR]; omega) (by simp only [KEY]; omega) (by left; simp only [KEY, SCR]; omega)
  · apply readBytes_const
    intro d hd
    rw [show KEY + 32 * 67 = KEY + 32 * 67 + 0 by rfl, off_add hfit _ _ (by simp only [KEY]; omega),
      overlay_off_in hfit _ _ (by simp only [KEY]; omega) (by omega) (by omega)]

/-- Eight instructions of padding, six for the leaf, seven to start the
climb: from the end of the chains to the invariant for level 0. -/
theorem to_tree {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : CInv env.hash base m0 67 s) :
    ∃ s', run env 21 s = .running s' ∧ LInv env.hash base m0 0 s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 89) := by rw [h.pc]; rfl
  have hW : Writes base m0 s.mem := Writes.of (endsMem_keeps fit 67 (Nat.le_refl _)) h.ch.out
  have hcode : CodeAt s.mem base kernel := hW.code fit hc0
  -- the padding
  obtain ⟨s8, e8, p8, m8, r8⟩ := (zero_words (prog := kernel) hp (k0 := 89) (rd := S2) (o := 0)
    (a := KEY + 32 * 67) at_pad (by rw [kernel_length]; decide) (by decide) (by simp only [KEY]; omega)
    (by decide) (by rw [kernel_length]; decide) hpc hcode h.s2) 8 (Nat.le_refl _)
  have hc8 : CodeAt s8.mem base kernel := by
    rw [m8]; exact code_of_overlay fit hcode (by rw [kernel_length]; simp only [KEY]; omega)
      (by simp only [KEY]; omega) _
  have hW8 : Writes base m0 s8.mem := by
    rw [m8]; exact hW.then (keeps_overlay fit _ _ (by simp only [KEY]; omega) (by simp only [KEY]; omega)
      (by simp only [KEY]; omega))
  -- the leaf: lui t1, 3; add a0, s0, t1; addi a1, x0, 1088; add a1, a1, a1; addi a2, s2, 32; ecall
  obtain ⟨t1, f1, q1, n1, u1⟩ := regStep (prog := kernel) hp 97 (by decide) hc8 p8 (i := .lui T1 3) (by decide) rfl
  obtain ⟨t2, f2, q2, n2, u2⟩ := regStep (prog := kernel) hp 98 (by decide) (by rw [n1]; exact hc8) q1
    (i := .op .add A0 S0 T1) (by decide) rfl
  obtain ⟨t3, f3, q3, n3, u3⟩ := regStep (prog := kernel) hp 99 (by decide) (by rw [n2, n1]; exact hc8) q2
    (i := .opi .addi A1 0 1088) (by decide) rfl
  obtain ⟨t4, f4, q4, n4, u4⟩ := regStep (prog := kernel) hp 100 (by decide) (by rw [n3, n2, n1]; exact hc8) q3
    (i := .op .add A1 A1 A1) (by decide) rfl
  obtain ⟨t5, f5, q5, n5, u5⟩ := regStep (prog := kernel) hp 101 (by decide) (by rw [n4, n3, n2, n1]; exact hc8) q4
    (i := .opi .addi A2 S2 32) (by decide) rfl
  have mem5 : t5.mem = s8.mem := by rw [n5, n4, n3, n2, n1]
  have hc5 : CodeAt t5.mem base kernel := by rw [mem5]; exact hc8
  have k5 : ∀ r, r ≠ T1 → r ≠ A0 → r ≠ A1 → r ≠ A2 → t5.reg r = s.reg r := by
    intro r a b c d
    rw [reg_kept u5 d, reg_kept u4 c, reg_kept u3 c, reg_kept u2 b, reg_kept u1 a, r8]
  have v_a0 : t5.reg A0 = base + BitVec.ofNat 32 KEY := by
    rw [reg_kept u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide), reg_wrote u2 (by decide),
      reg_wrote u1 (by decide), reg_kept u1 (by decide), r8, h.rg.s0]
    simp only [aluR]; rfl
  have v_a1 : t5.reg A1 = BitVec.ofNat 32 2176 := by
    rw [reg_kept u5 (by decide), reg_wrote u4 (by decide), reg_wrote u3 (by decide)]
    simp only [aluR, aluI, reg_zero]; decide
  have v_a2 : t5.reg A2 = base + BitVec.ofNat 32 CUR := by
    rw [reg_wrote u5 (by decide), reg_kept u4 (by decide), reg_kept u3 (by decide), reg_kept u2 (by decide),
      reg_kept u1 (by decide), r8, h.s2]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
      off_add fit _ _ (by simp only [KEY]; omega)]; rfl
  have v_t0 : t5.reg T0 = 0 := by rw [k5 _ (by decide) (by decide) (by decide) (by decide), h.ch.t0]
  have hexec := exec_hash (env := env) (s := t5) v_t0 (by rw [v_a1]; rfl)
    (by rw [v_a0]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [v_a2]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [v_a0, v_a1]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [v_a2]; exact ok_off hp _ _ (by decide) (by decide))
  obtain ⟨t6, f6, ht6⟩ : ∃ t6, run env 1 t5 = .running t6 ∧
      t6 = ({ t5 with mem := writeBytes t5.mem (t5.reg A2) (env.hash (readBytes t5.mem (t5.reg A0) (t5.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 102 (by decide) hc5 q5 (i := .ecall) (by decide) hexec 0).trans (run_zero _ _), rfl⟩
  have mem6 : t6.mem = writeBytes s8.mem (base + BitVec.ofNat 32 CUR)
      (env.hash (endsTo env.hash m0 base 67 ++ List.replicate 32 0)) := by
    rw [ht6, next_mem, v_a0, v_a1, v_a2, mem5, show (BitVec.ofNat 32 2176).toNat = 2176 from rfl, m8,
      leaf_input fit h.ch.out]
  have q6 : t6.pc = base + BitVec.ofNat 32 (4 * 103) := by
    rw [ht6]; simp only [next_pc]; rw [q5]; exact pc_next fit 102 (by decide)
  have k6 : ∀ r, t6.reg r = t5.reg r := fun r => by rw [ht6]; rfl
  have hc6 : CodeAt t6.mem base kernel := by
    rw [mem6]
    refine CodeAt.congr (by rw [kernel_length]; omega) (fun x h1 h2 => ?_) hc8
    rw [kernel_length] at h2
    have hx : x = base + BitVec.ofNat 32 (x.toNat - base.toNat) := by
      apply BitVec.eq_of_toNat_eq; rw [toNat_off fit _ (by omega)]; omega
    rw [hx, writeBytes_apply]
    have : ¬ (base + BitVec.ofNat 32 (x.toNat - base.toNat) - (base + BitVec.ofNat 32 CUR)).toNat < 32 :=
      outside fit (by simp only [CUR]; omega) (by omega) (by left; simp only [CUR]; omega)
    simp only [this, ↓reduceDIte]
  have hW6 : Writes base m0 t6.mem := by
    rw [mem6]; exact hW8.then (keeps_writeBytes fit _ _ (by simp only [KEY, CUR]; omega)
      (by simp only [KEY, CUR]; omega) (by simp only [KEY]; omega))
  -- the climb: a0 = NODE, a7 = NODE + 32, a1 = 64, s4 = AUTH, a3 = the index, a6 = 4
  obtain ⟨w1, g1, o1, l1, v1⟩ := regStep (prog := kernel) hp 103 (by decide) hc6 q6
    (i := .opi .addi A0 S2 96) (by decide) rfl
  obtain ⟨w2, g2, o2, l2, v2⟩ := regStep (prog := kernel) hp 104 (by decide) (by rw [l1]; exact hc6) o1
    (i := .opi .addi A7 S2 128) (by decide) rfl
  obtain ⟨w3, g3, o3, l3, v3⟩ := regStep (prog := kernel) hp 105 (by decide) (by rw [l2, l1]; exact hc6) o2
    (i := .opi .addi A1 0 64) (by decide) rfl
  obtain ⟨w4, g4, o4, l4, v4⟩ := regStep (prog := kernel) hp 106 (by decide) (by rw [l3, l2, l1]; exact hc6) o3
    (i := .lui T1 4) (by decide) rfl
  obtain ⟨w5, g5, o5, l5, v5⟩ := regStep (prog := kernel) hp 107 (by decide) (by rw [l4, l3, l2, l1]; exact hc6) o4
    (i := .op .add S4 S0 T1) (by decide) rfl
  have mw5 : w5.mem = t6.mem := by rw [l5, l4, l3, l2, l1]
  have kw5 : ∀ r, r ≠ A0 → r ≠ A7 → r ≠ A1 → r ≠ T1 → r ≠ S4 → w5.reg r = t6.reg r := by
    intro r a b c d e
    rw [reg_kept v5 e, reg_kept v4 d, reg_kept v3 c, reg_kept v2 b, reg_kept v1 a]
  have s3_5 : w5.reg S3 = base + BitVec.ofNat 32 MSG := by
    rw [kw5 _ (by decide) (by decide) (by decide) (by decide) (by decide), k6,
      k5 _ (by decide) (by decide) (by decide) (by decide), h.rg.s3]
  obtain ⟨w6, g6, o6, l6, v6⟩ := lbuStep (prog := kernel) hp 108 (by decide) (by rw [mw5]; exact hc6) o5
    (rd := A3) (rs1 := S3) (imm := 32) (by decide) IDX
    (by rw [s3_5, show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [MSG]; omega)]; rfl)
    (by simp only [IDX]; omega)
  obtain ⟨w7, g7, o7, l7, v7⟩ := regStep (prog := kernel) hp 109 (by decide) (by rw [l6, mw5]; exact hc6) o6
    (i := .opi .addi A6 0 4) (by decide) rfl
  have mw7 : w7.mem = t6.mem := by rw [l7, l6, mw5]
  have kw7 : ∀ r, r ≠ A0 → r ≠ A7 → r ≠ A1 → r ≠ T1 → r ≠ S4 → r ≠ A3 → r ≠ A6 → w7.reg r = t6.reg r := by
    intro r a b c d e f g
    rw [reg_kept v7 g, reg_kept v6 f, kw5 r a b c d e]
  have s2_6 : t6.reg S2 = base + BitVec.ofNat 32 (KEY + 32 * 67) := by
    rw [k6, k5 _ (by decide) (by decide) (by decide) (by decide), h.s2]
  refine ⟨w7, ?_, ⟨by rw [o7]; rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, by rw [mw7]; exact hW6⟩⟩
  · rw [show 21 = 8 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + 1)))))))))))) by rfl,
      run_add_running e8]
    exact run_cons f1 (run_cons f2 (run_cons f3 (run_cons f4 (run_cons f5 (run_cons f6
      (run_cons g1 (run_cons g2 (run_cons g3 (run_cons g4 (run_cons g5 (run_cons g6 g7)))))))))))
  · rw [reg_kept v7 (by decide), reg_wrote v6 (by decide), mw5,
      hW6.off fit (by simp only [IDX]; omega) (by left; simp only [IDX, KEY]; omega)]
    simp [idx]
  · rw [reg_kept v7 (by decide), reg_kept v6 (by decide), reg_wrote v5 (by decide), reg_wrote v4 (by decide),
      reg_kept v4 (by decide), reg_kept v3 (by decide), reg_kept v2 (by decide), reg_kept v1 (by decide), k6,
      k5 _ (by decide) (by decide) (by decide) (by decide), h.rg.s0]
    simp only [aluR]; rfl
  · rw [reg_wrote v7 (by decide)]; simp only [aluI, reg_zero]; decide
  · rw [kw7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), k6, v_a2]
  · rw [reg_kept v7 (by decide), reg_kept v6 (by decide), reg_kept v5 (by decide), reg_kept v4 (by decide),
      reg_kept v3 (by decide), reg_kept v2 (by decide), reg_wrote v1 (by decide), s2_6]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (96 : BitVec 12) = BitVec.ofNat 32 96 by decide,
      off_add fit _ _ (by simp only [KEY]; omega)]; rfl
  · rw [reg_kept v7 (by decide), reg_kept v6 (by decide), reg_kept v5 (by decide), reg_kept v4 (by decide),
      reg_kept v3 (by decide), reg_wrote v2 (by decide), reg_kept v1 (by decide), s2_6]
    simp only [aluI]
    rw [show BitVec.signExtend 32 (128 : BitVec 12) = BitVec.ofNat 32 128 by decide,
      off_add fit _ _ (by simp only [KEY]; omega)]; rfl
  · rw [reg_kept v7 (by decide), reg_kept v6 (by decide), reg_kept v5 (by decide), reg_kept v4 (by decide),
      reg_wrote v3 (by decide)]
    simp only [aluI, reg_zero]; decide
  · rw [kw7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), k6, v_t0]
  · rw [kw7 _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), k6,
      k5 _ (by decide) (by decide) (by decide) (by decide), h.s6]
  · rw [mw7, mem6, readBytes_writeBytes]; rfl

/-! ## The tree -/

theorem idx_lt (m : Word → Byte) (base : Word) : idx m base < 256 := (m (base + BitVec.ofNat 32 IDX)).isLt

/-- **One level**: 43 instructions, from the invariant for `k` to the
invariant for `k + 1` — the node and the path's node put in order by bit `k`
of the index, with no branch, then HASH of the two into the node. -/
theorem level_iter {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {k : Nat} (hk : k < 4) {s : Machine} (h : LInv env.hash base m0 k s) :
    ∃ s', run env 43 s = .running s' ∧ LInv env.hash base m0 (k + 1) s' := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 110) := by rw [h.pc]; simp [hk]
  have hcode : CodeAt s.mem base kernel := h.out.code fit hc0
  have hq : idx m0 base / 2 ^ k < 256 := Nat.lt_of_le_of_lt (Nat.div_le_self _ _) (idx_lt m0 base)
  generalize hqd : idx m0 base / 2 ^ k = q at hq
  have hb2 : q % 2 < 2 := Nat.mod_lt _ (by omega)
  generalize hbd : q % 2 = b at hb2
  -- andi t1, a3, 1; sub t1, x0, t1; xor t2, a2, s4; and t2, t2, t1; xor a4, a2, t2; xor a5, s4, t2
  obtain ⟨x1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 110 (by decide) hcode hpc
    (i := .opi .andi T1 A3 1) (by decide) rfl
  obtain ⟨x2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 111 (by decide) (by rw [m1]; exact hcode) p1
    (i := .op .sub T1 0 T1) (by decide) rfl
  obtain ⟨x3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 112 (by decide) (by rw [m2, m1]; exact hcode) p2
    (i := .op .xor T2 A2 S4) (by decide) rfl
  obtain ⟨x4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 113 (by decide) (by rw [m3, m2, m1]; exact hcode) p3
    (i := .op .and T2 T2 T1) (by decide) rfl
  obtain ⟨x5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 114 (by decide)
    (by rw [m4, m3, m2, m1]; exact hcode) p4 (i := .op .xor A4 A2 T2) (by decide) rfl
  obtain ⟨x6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 115 (by decide)
    (by rw [m5, m4, m3, m2, m1]; exact hcode) p5 (i := .op .xor A5 S4 T2) (by decide) rfl
  have mx6 : x6.mem = s.mem := by rw [m6, m5, m4, m3, m2, m1]
  have hc6 : CodeAt x6.mem base kernel := by rw [mx6]; exact hcode
  have kx6 : ∀ r, r ≠ T1 → r ≠ T2 → r ≠ A4 → r ≠ A5 → x6.reg r = s.reg r := by
    intro r a b c d
    rw [reg_kept r6 d, reg_kept r5 c, reg_kept r4 b, reg_kept r3 b, reg_kept r2 a, reg_kept r1 a]
  have v_t1 : x2.reg T1 = 0 - BitVec.ofNat 32 b := by
    rw [reg_wrote r2 (by decide)]; simp only [aluR, reg_zero]
    rw [reg_wrote r1 (by decide)]; simp only [aluI]
    rw [h.a3, hqd, and1 q (by omega), hbd]
  have v_t2 : x4.reg T2 = (base + BitVec.ofNat 32 CUR ^^^ (base + BitVec.ofNat 32 (AUTH + 32 * k)))
      &&& (0 - BitVec.ofNat 32 b) := by
    rw [reg_wrote r4 (by decide)]; simp only [aluR]
    rw [reg_wrote r3 (by decide), reg_kept r3 (r := T1) (by decide), v_t1]; simp only [aluR]
    rw [reg_kept r2 (r := A2) (by decide), reg_kept r1 (r := A2) (by decide), reg_kept r2 (r := S4) (by decide),
      reg_kept r1 (r := S4) (by decide), h.a2, h.s4]
  have hsel := sel (base + BitVec.ofNat 32 CUR) (base + BitVec.ofNat 32 (AUTH + 32 * k)) b hb2
  let Lo := if b = 0 then CUR else AUTH + 32 * k
  let Ro := if b = 0 then AUTH + 32 * k else CUR
  have hLo : x6.reg A4 = base + BitVec.ofNat 32 Lo := by
    rw [reg_kept r6 (by decide), reg_wrote r5 (by decide)]; simp only [aluR]
    rw [reg_kept r4 (r := A2) (by decide), reg_kept r3 (r := A2) (by decide), reg_kept r2 (r := A2) (by decide),
      reg_kept r1 (r := A2) (by decide), h.a2, v_t2, hsel.1]
    show _ = base + BitVec.ofNat 32 (if b = 0 then CUR else AUTH + 32 * k)
    split <;> rfl
  have hRo : x6.reg A5 = base + BitVec.ofNat 32 Ro := by
    rw [reg_wrote r6 (by decide)]; simp only [aluR]
    rw [reg_kept r5 (r := S4) (by decide), reg_kept r4 (r := S4) (by decide), reg_kept r3 (r := S4) (by decide),
      reg_kept r2 (r := S4) (by decide), reg_kept r1 (r := S4) (by decide), h.s4, reg_kept r5 (r := T2) (by decide),
      v_t2, hsel.2]
    show _ = base + BitVec.ofNat 32 (if b = 0 then AUTH + 32 * k else CUR)
    split <;> rfl
  have hLo1 : Lo + 32 ≤ 0x10000 := by show (if b = 0 then CUR else AUTH + 32 * k) + 32 ≤ _; split <;> simp only [CUR, AUTH] <;> omega
  have hRo1 : Ro + 32 ≤ 0x10000 := by show (if b = 0 then AUTH + 32 * k else CUR) + 32 ≤ _; split <;> simp only [CUR, AUTH] <;> omega
  have hLo4 : Lo % 4 = 0 := by show (if b = 0 then CUR else AUTH + 32 * k) % 4 = 0; split <;> simp only [CUR, AUTH] <;> omega
  have hRo4 : Ro % 4 = 0 := by show (if b = 0 then AUTH + 32 * k else CUR) % 4 = 0; split <;> simp only [CUR, AUTH] <;> omega
  have hLos : Lo + 32 ≤ NODE ∨ NODE + 32 + 32 ≤ Lo := by
    show (if b = 0 then CUR else AUTH + 32 * k) + 32 ≤ NODE ∨ NODE + 32 + 32 ≤ (if b = 0 then CUR else AUTH + 32 * k)
    split <;> simp only [CUR, AUTH, NODE] <;> omega
  have hRos : Ro + 32 ≤ NODE ∨ NODE + 32 + 32 ≤ Ro := by
    show (if b = 0 then AUTH + 32 * k else CUR) + 32 ≤ NODE ∨ NODE + 32 + 32 ≤ (if b = 0 then AUTH + 32 * k else CUR)
    split <;> simp only [CUR, AUTH, NODE] <;> omega
  -- the two halves of HASH's input
  obtain ⟨y1, f1, o1, n1, u1⟩ := (copy_words (prog := kernel) hp (k0 := 116) (rs := A4) (rd := A0) (t := T4)
    (src := Lo) (dst := NODE) at_left (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    hLo1 (by decide) hLo4 (by decide) (by rw [kernel_length]; decide)
    (hLos.imp id (fun h' => by omega))
    p6 hc6 hLo (by rw [kx6 _ (by decide) (by decide) (by decide) (by decide), h.a0])) 8 (Nat.le_refl _)
  have hcy1 : CodeAt y1.mem base kernel := by
    rw [n1]; exact code_of_overlay fit hc6 (by rw [kernel_length]; decide) (by decide) _
  obtain ⟨y2, f2, o2, n2, u2⟩ := (copy_words (prog := kernel) hp (k0 := 132) (rs := A5) (rd := A7) (t := T4)
    (src := Ro) (dst := NODE + 32) at_right (by rw [kernel_length]; decide) (by decide) (by decide) (by decide)
    hRo1 (by decide) hRo4 (by decide) (by rw [kernel_length]; decide)
    (hRos.imp (fun h' => by omega) id)
    o1 hcy1 (by rw [u1 _ (by decide), hRo])
    (by rw [u1 _ (by decide), kx6 _ (by decide) (by decide) (by decide) (by decide), h.a7])) 8 (Nat.le_refl _)
  have hcy2 : CodeAt y2.mem base kernel := by
    rw [n2]; exact code_of_overlay fit hcy1 (by rw [kernel_length]; decide) (by decide) _
  have ky2 : ∀ r, r ≠ T4 → r ≠ T1 → r ≠ T2 → r ≠ A4 → r ≠ A5 → y2.reg r = s.reg r :=
    fun r a b c d e => by rw [u2 r a, u1 r a, kx6 r b c d e]
  -- the input, as the two halves it was copied from
  have hS : ∀ c, c + 32 ≤ NODE ∨ NODE + 64 ≤ c → c < 0x10000 →
      y2.mem (base + BitVec.ofNat 32 c) = s.mem (base + BitVec.ofNat 32 c) := by
    intro c hc hc'
    rw [n2, overlay_off_out fit _ _ (by simp only [NODE]; omega) hc' (by simp only [NODE] at hc ⊢; omega), n1,
      overlay_off_out fit _ _ (by simp only [NODE]; omega) hc' (by simp only [NODE] at hc ⊢; omega), mx6]
  have hin : readBytes y2.mem (base + BitVec.ofNat 32 NODE) 64
      = readBytes s.mem (base + BitVec.ofNat 32 Lo) 32 ++ readBytes s.mem (base + BitVec.ofNat 32 Ro) 32 := by
    rw [show (64 : Nat) = 32 + 32 from rfl, readBytes_append, off_add fit _ _ (by simp only [NODE]; omega)]
    refine app_congr ?_ ?_
    · apply readBytes_shift
      intro d hd
      rw [off_add fit _ _ (by simp only [NODE]; omega), n2,
        overlay_off_out fit _ _ (by simp only [NODE]; omega) (by simp only [NODE]; omega)
          (by left; simp only [NODE]; omega), n1,
        overlay_off_in fit _ _ (by simp only [NODE]; omega) (by omega) (by omega),
        show NODE + d - NODE = d by omega, mx6, off_add fit _ _ (by omega)]
    · apply readBytes_shift
      intro d hd
      rw [off_add fit _ _ (by simp only [NODE]; omega), n2,
        overlay_off_in fit _ _ (by simp only [NODE]; omega) (by omega) (by omega),
        show NODE + 32 + d - (NODE + 32) = d by omega, n1,
        overlay_off_out fit _ _ (by simp only [NODE]; omega) (by omega)
          (hRos.imp (fun h' => by omega) (fun h' => by omega)),
        mx6, off_add fit _ _ (by omega)]
  have hcurS : readBytes s.mem (base + BitVec.ofNat 32 CUR) 32 = climbTo env.hash m0 base k := h.cur
  have hauthS : readBytes s.mem (base + BitVec.ofNat 32 (AUTH + 32 * k)) 32 = authAt m0 base k :=
    h.out.bytes fit (by simp only [AUTH]; omega) (by right; simp only [AUTH, KEY, SCR]; omega)
  have hinput : readBytes y2.mem (base + BitVec.ofNat 32 NODE) 64
      = if idx m0 base / 2 ^ k % 2 = 0 then climbTo env.hash m0 base k ++ authAt m0 base k
        else authAt m0 base k ++ climbTo env.hash m0 base k := by
    rw [hin, hqd, hbd]
    show readBytes s.mem (base + BitVec.ofNat 32 (if b = 0 then CUR else AUTH + 32 * k)) 32
      ++ readBytes s.mem (base + BitVec.ofNat 32 (if b = 0 then AUTH + 32 * k else CUR)) 32 = _
    split <;> rw [hcurS, hauthS]
  -- ecall: HASH of the 64 bytes into the node
  have y_t0 : y2.reg T0 = 0 := by
    rw [ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.t0]
  have y_a0 : y2.reg A0 = base + BitVec.ofNat 32 NODE := by
    rw [ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.a0]
  have y_a1 : y2.reg A1 = BitVec.ofNat 32 64 := by
    rw [ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.a1]
  have y_a2 : y2.reg A2 = base + BitVec.ofNat 32 CUR := by
    rw [ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.a2]
  have hexec := exec_hash (env := env) (s := y2) y_t0 (by rw [y_a1]; rfl)
    (by rw [y_a0]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [y_a2]; exact align_off hp.align fit _ (by decide) (by decide))
    (by rw [y_a0, y_a1]; exact ok_off hp _ _ (by decide) (by decide))
    (by rw [y_a2]; exact ok_off hp _ _ (by decide) (by decide))
  obtain ⟨y3, f3, hy3⟩ : ∃ y3, run env 1 y2 = .running y3 ∧
      y3 = ({ y2 with mem := writeBytes y2.mem (y2.reg A2) (env.hash (readBytes y2.mem (y2.reg A0) (y2.reg A1).toNat)) } : Machine).next :=
    ⟨_, (stepK (prog := kernel) hp 148 (by decide) hcy2 o2 (i := .ecall) (by decide) hexec 0).trans (run_zero _ _), rfl⟩
  have my3 : y3.mem = writeBytes y2.mem (base + BitVec.ofNat 32 CUR)
      (env.hash (readBytes y2.mem (base + BitVec.ofNat 32 NODE) 64)) := by
    rw [hy3, next_mem, y_a0, y_a1, y_a2]; rfl
  have o3 : y3.pc = base + BitVec.ofNat 32 (4 * 149) := by
    rw [hy3]; simp only [next_pc]; rw [o2]; exact pc_next fit 148 (by decide)
  have ky3 : ∀ r, y3.reg r = y2.reg r := fun r => by rw [hy3]; rfl
  have hW3 : Writes base m0 y3.mem := by
    rw [my3, n2, n1, mx6]
    exact ((h.out.then (keeps_overlay fit _ _ (by simp only [KEY, NODE]; omega) (by simp only [KEY, NODE]; omega)
      (by simp only [KEY]; omega))).then (keeps_overlay fit _ _ (by simp only [KEY, NODE]; omega)
      (by simp only [KEY, NODE]; omega) (by simp only [KEY]; omega))).then
      (keeps_writeBytes fit _ _ (by simp only [KEY, CUR]; omega) (by simp only [KEY, CUR]; omega)
        (by simp only [KEY]; omega))
  have hcy3 : CodeAt y3.mem base kernel := hW3.code fit hc0
  -- addi s4, s4, 32; srli a3, a3, 1; addi a6, a6, -1; bne a6, x0
  obtain ⟨z1, g1, q1, l1, v1⟩ := regStep (prog := kernel) hp 149 (by decide) hcy3 o3
    (i := .opi .addi S4 S4 32) (by decide) rfl
  obtain ⟨z2, g2, q2, l2, v2⟩ := regStep (prog := kernel) hp 150 (by decide) (by rw [l1]; exact hcy3) q1
    (i := .sh .srli A3 A3 1) (by decide) rfl
  obtain ⟨z3, g3, q3, l3, v3⟩ := regStep (prog := kernel) hp 151 (by decide) (by rw [l2, l1]; exact hcy3) q2
    (i := .opi .addi A6 A6 0xfff) (by decide) rfl
  have hcz3 : CodeAt z3.mem base kernel := by rw [l3, l2, l1]; exact hcy3
  have kz3 : ∀ r, r ≠ S4 → r ≠ A3 → r ≠ A6 → r ≠ T4 → r ≠ T1 → r ≠ T2 → r ≠ A4 → r ≠ A5 → z3.reg r = s.reg r :=
    fun r a b c d e f g i => by rw [reg_kept v3 c, reg_kept v2 b, reg_kept v1 a, ky3, ky2 r d e f g i]
  have v_a6 : z3.reg A6 = BitVec.ofNat 32 (4 - (k + 1)) := by
    rw [reg_wrote v3 (by decide)]; simp only [aluI]
    rw [reg_kept v2 (by decide), reg_kept v1 (by decide), ky3,
      ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.a6,
      show 4 - k = (4 - (k + 1)) + 1 by omega]
    exact dec_one _ (by omega)
  have ht : taken .bne (z3.reg A6) (z3.reg 0) = decide (k + 1 < 4) := by
    rw [v_a6, reg_zero]; simp only [taken]
    by_cases hl : k + 1 < 4
    · simp only [hl, decide_true, bne_iff_ne, ne_eq]
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; simp at this; omega
    · simp only [hl, decide_false, bne_eq_false_iff_eq]
      rw [show 4 - (k + 1) = 0 by omega]; rfl
  have finish : ∀ z4 : Machine, run env 1 z3 = .running z4 → (∀ r, z4.reg r = z3.reg r) →
      z4.mem = z3.mem → z4.pc = base + BitVec.ofNat 32 (4 * (if k + 1 < 4 then 110 else 153)) →
      ∃ s', run env 43 s = .running s' ∧ LInv env.hash base m0 (k + 1) s' := by
    intro z4 ez b4 mz4 p4
    have kept : ∀ r, r ≠ S4 → r ≠ A3 → r ≠ A6 → r ≠ T4 → r ≠ T1 → r ≠ T2 → r ≠ A4 → r ≠ A5 → z4.reg r = s.reg r :=
      fun r a b c d e f g i => by rw [b4, kz3 r a b c d e f g i]
    have mz : z4.mem = y3.mem := by rw [mz4, l3, l2, l1]
    refine ⟨z4, ?_, ⟨p4, ?_, ?_, by rw [b4, v_a6], ?_, ?_, ?_, ?_, ?_, ?_, ?_, by rw [mz]; exact hW3⟩⟩
    · rw [show 43 = 1 + (1 + (1 + (1 + (1 + (1 + (16 + (16 + (1 + (1 + (1 + (1 + 1))))))))))) by rfl]
      refine run_cons e1 (run_cons e2 (run_cons e3 (run_cons e4 (run_cons e5 (run_cons e6 ?_)))))
      show run env (2 * 8 + (2 * 8 + (1 + (1 + (1 + (1 + 1)))))) x6 = _
      rw [run_add_running f1, run_add_running f2]
      exact run_cons f3 (run_cons g1 (run_cons g2 (run_cons g3 ez)))
    · rw [b4, reg_kept v3 (by decide), reg_wrote v2 (by decide)]; simp only [shiftI]
      rw [reg_kept v1 (by decide), ky3, ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.a3,
        show ((1 : BitVec 5)).toNat = 1 from rfl, shr _ 1 (Nat.lt_of_le_of_lt (Nat.div_le_self _ _)
          (Nat.lt_of_lt_of_le (idx_lt m0 base) (by decide))),
        Nat.pow_one, Nat.div_div_eq_div_mul, ← Nat.pow_succ]
    · rw [b4, reg_kept v3 (by decide), reg_kept v2 (by decide), reg_wrote v1 (by decide)]; simp only [aluI]
      rw [ky3, ky2 _ (by decide) (by decide) (by decide) (by decide) (by decide), h.s4,
        show BitVec.signExtend 32 (32 : BitVec 12) = BitVec.ofNat 32 32 by decide,
        off_add fit _ _ (by simp only [AUTH]; omega)]
      congr 2
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a2]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a7]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.a1]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.t0]
    · rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide), h.s6]
    · rw [mz, my3, readBytes_writeBytes, hinput]
      simp only [climbTo, up]
      split <;> rfl
  by_cases hl : k + 1 < 4
  · have e4 : run env 1 z3 = .running (z3.setPc (z3.pc + ((0xfac : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK (prog := kernel) hp 152 (by decide) hcz3 q3 (i := .br .bne A6 0 0xfac) (by decide)
        (exec_br_taken (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => setPc_reg _ _ r) (setPc_mem _ _) ?_
    simp only [hl, ↓reduceIte, setPc_pc, q3]
    rw [BitVec.add_assoc]
    congr 1
  · have e4 : run env 1 z3 = .running z3.next :=
      (stepK (prog := kernel) hp 152 (by decide) hcz3 q3 (i := .br .bne A6 0 0xfac) (by decide)
        (exec_br_not (by rw [ht]; simp [hl])) 0).trans (run_zero _ _)
    refine finish _ e4 (fun r => next_reg _ r) (next_mem _) ?_
    simp only [hl, ↓reduceIte, next_pc, q3]
    exact pc_next fit 152 (by decide)

/-- Four levels, by induction: after `j` of them, the invariant holds for `j`. -/
theorem level_loop {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : LInv env.hash base m0 0 s) :
    ∀ j ≤ 4, ∃ s', run env (43 * j) s = .running s' ∧ LInv env.hash base m0 j s' := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, h⟩
  | succ j ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := level_iter hp hc0 (by omega) hs'
    exact ⟨s'', by rw [show 43 * (j + 1) = 43 * j + 43 by omega, run_add_running e, e'], hs''⟩

/-! ## The verdict -/

/-- **What the compare decided is the definition.** With the node four
levels up at `CUR` and the root where the input put it, the eight words
matching is exactly `Verifies`. -/
theorem root_iff {H : List Byte → Fin 32 → Byte} {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32)
    {m0 M : Word → Byte} (hout : Writes base m0 M)
    (hcur : readBytes M (base + BitVec.ofNat 32 CUR) 32 = climbTo H m0 base 4) :
    (∀ j < 8, readLE M (base + BitVec.ofNat 32 (CUR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (ROOT + 0 + 4 * j)) 4) ↔ Verifies H m0 base := by
  have e : ∀ j < 8, (readLE M (base + BitVec.ofNat 32 (CUR + 0 + 4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 (ROOT + 0 + 4 * j)) 4)
      = (readLE M (base + BitVec.ofNat 32 CUR + BitVec.ofNat 32 (4 * j)) 4
        = readLE M (base + BitVec.ofNat 32 ROOT + BitVec.ofNat 32 (4 * j)) 4) := by
    intro j hj
    rw [Nat.add_zero, Nat.add_zero, off_add hfit _ _ (by simp only [CUR]; omega),
      off_add hfit _ _ (by simp only [ROOT]; omega)]
  rw [show (∀ j < 8, _) ↔ (∀ j < 8, _) from forall_congr' fun j => imp_congr_right fun hj => by rw [e j hj],
    words_iff_bytes, bytes_iff_readBytes, hcur,
    hout.bytes hfit (by simp only [ROOT]; omega) (by right; simp only [ROOT, KEY, SCR]; omega)]
  rfl

/-- After the fourth level: the compare, the verdict, and HALT — 35
instructions. -/
theorem halt {env : Env} {base : Word} (hp : Placed env base) {m0 : Word → Byte}
    (hc0 : CodeAt m0 base kernel) {s : Machine} (h : LInv env.hash base m0 4 s) :
    ∃ s1 s2, run env 34 s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash m0 base then 0 else 1) s2 ∧ s2.mem = s.mem := by
  have fit := hp.fit
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 153) := by rw [h.pc]; rfl
  have hcode : CodeAt s.mem base kernel := h.out.code fit hc0
  obtain ⟨sq, eq, pq, mq, zq, kq⟩ := (compare_words (prog := kernel) hp (k0 := 153) (ra := A2) (rb := S4)
    (acc := S6) (t := T2) (u := T3) (oa := 0) (ob := 0) (a := CUR) (b := ROOT) at_cmp
    (by rw [kernel_length]; decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) hpc hcode h.a2 (by rw [h.s4]; rfl)) 8 (Nat.le_refl _)
  have hcq : CodeAt sq.mem base kernel := by rw [mq]; exact hcode
  have s6q : sq.reg S6 = 0 ↔ Verifies env.hash m0 base := by
    rw [zq, h.s6, root_iff fit h.out h.cur]; simp
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 185 (by decide) hcq pq
    (i := .op .sltu A0 0 S6) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 186 (by decide) (by rw [m1]; exact hcq) p1
    (i := .opi .addi T0 0 1) (by decide) rfl
  have t0 : s2.reg T0 = 1 := by rw [reg_wrote r2 (by decide)]; simp only [aluI, reg_zero]; decide
  have a0 : s2.reg A0 = if Verifies env.hash m0 base then 0 else 1 := by
    rw [reg_kept r2 (by decide), reg_wrote r1 (by decide)]
    simp only [aluR, reg_zero]
    rw [sltu_zero]
    by_cases hv : Verifies env.hash m0 base
    · simp [hv, s6q.mpr hv]
    · have hn : ¬ sq.reg S6 = 0 := fun e => hv (s6q.mp e)
      rw [ite_eq_right_of_eq_false _ _ (eq_false hn), ite_eq_right_of_eq_false _ _ (eq_false hv)]
  refine ⟨s2, s2, ?_, ?_, by rw [m2, m1, mq]⟩
  · rw [show 34 = 4 * 8 + (1 + 1) by rfl, run_add_running eq]; exact run_cons e1 e2
  rw [← a0]
  exact (step_of_code (k := 187) (by rw [kernel_length]; decide) (by rw [m2, m1]; exact hcq)
      (by rw [p2])
      (by rw [p2]; exact align_off hp.align hp.fit _ (by decide) (by decide))
      (by rw [p2]; exact ok_off hp _ 4 (by decide) (by decide)) |> fun e => by
        rw [run, e, show kernel[187]'(by rw [kernel_length]; decide) = .ecall by decide, exec_halt t0])

/-! ## The whole kernel -/

/-- Everything up to the `ecall` that halts: `3294 + 3 · steps` instructions. -/
theorem to_the_ecall {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1 s2, run env (3294 + 3 * steps s.mem base) s = .running s1
      ∧ run env 1 s1 = .halted (if Verifies env.hash s.mem base then 0 else 1) s2
      ∧ Writes base s.mem s2.mem := by
  obtain ⟨s22, e22, dinv, rg, h1, h2, h6⟩ := front starts hp s hpc hcode
  obtain ⟨sd, ed, dinv'⟩ := digits_loop starts hp
    (keeps_overlay hp.fit _ _ (by omega) (by simp only [SCR]; omega) (by simp only [SCR]; omega))
    (code_of_overlay hp.fit hcode (by rw [kernel_length]; decide) (by decide) _) dinv 32 (Nat.le_refl _)
  obtain ⟨sm, em, pm, chm, frm⟩ := middle starts hp hcode dinv' rg h1
  have kept : ∀ r, r ≠ A3 → r ≠ A4 → r ≠ A5 → r ≠ T1 → r ≠ T2 → r ≠ S7 → r ≠ T0 → r ≠ A0 → r ≠ A1 → r ≠ A2 →
      sm.reg r = s22.reg r := frm
  have cinv : CInv env.hash base s.mem 0 sm :=
    ⟨by rw [pm]; rfl, chm,
     by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide), h2]; rfl,
     ⟨by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide), rg.s0],
      by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide), rg.s3],
      by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide), rg.s5]⟩,
     by rw [kept _ (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
          (by decide) (by decide) (by decide), h6]⟩
  obtain ⟨sl, el, cinv'⟩ := chain_loop hp hcode cinv 67 (Nat.le_refl _)
  obtain ⟨st, et, linv⟩ := to_tree hp hcode cinv'
  obtain ⟨sv, ev, linv'⟩ := level_loop hp hcode linv 4 (Nat.le_refl _)
  obtain ⟨s1, s2, e2, e1, hm⟩ := halt hp hcode linv'
  refine ⟨s1, s2, ?_, e1, by rw [hm]; exact linv'.out⟩
  rw [show 3294 + 3 * steps s.mem base
      = 22 + (11 * 32 + (13 + (loopCount s.mem base 67 + (21 + (43 * 4 + 34))))) by
    rw [loopCount_eq]; unfold steps stepsTo; omega,
    run_add_running e22, run_add_running ed, run_add_running em, run_add_running el, run_add_running et,
    run_add_running ev, e2]

/-- **The kernel verifies an MSS signature.** From `base`, with the kernel's
752 bytes there, it halts with 0 if the 67 chains' ends make a leaf that the
authentication path and the index lift to the root, and with 1 if they do
not — for every message, signature, index, path, root and `HASH` — and it
writes nothing outside its two places: the `0x900` bytes from `KEY` and the
131 of scratch. It takes `3295 + 3 · steps` instructions, where
`steps = Σ (15 - dᵢ)` is the number of HASH calls the chains make; the leaf
and the tree add five more, which cost no extra instructions in the count. -/
theorem verifies {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s', run env (3295 + 3 * steps s.mem base) s
        = .halted (if Verifies env.hash s.mem base then 0 else 1) s'
      ∧ Writes base s.mem s'.mem := by
  obtain ⟨s1, s2, e, e1, hm⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s2, by rw [show 3295 + 3 * steps s.mem base = 3294 + 3 * steps s.mem base + 1 by omega,
    run_add_running e, e1], hm⟩

/-- **And in exactly that many.** After one fewer it is still running, for
every input: the count is not a bound. -/
theorem exactly {env : Env} {base : Word} (hp : Placed env base) (s : Machine)
    (hpc : s.pc = base) (hcode : CodeAt s.mem base kernel) :
    ∃ s1, run env (3294 + 3 * steps s.mem base) s = .running s1 := by
  obtain ⟨s1, -, e, -, -⟩ := to_the_ecall hp s hpc hcode
  exact ⟨s1, e⟩

/-! ## The bytes are the kernel -/

/-- Word `k` of `bytes`, put back together, is the encoding of instruction
`k`. A hundred and eighty-eight cases, each computed. -/
theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 752 ≤ img.size)
    (himg : ∀ d (h : d < 752), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) bytes_words img (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **From the state the shell builds**: any image that begins with the
kernel's 752 bytes. -/
theorem from_boot {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 752 ≤ img.size) (himg : ∀ d (h : d < 752), img.get d (by omega) = bytes.getD d 0) :
    (∃ s1, run env (3294 + 3 * steps (memOfImage base img) base) (boot env.region img) = .running s1) ∧
    ∃ s', run env (3295 + 3 * steps (memOfImage base img) base) (boot env.region img)
        = .halted (if Verifies env.hash (memOfImage base img) base then 0 else 1) s'
      ∧ Writes base (memOfImage base img) s'.mem := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hcode : CodeAt (boot env.region img).mem base kernel := by
    rw [hmem]; exact code_of_image hp.fit img hsize himg
  obtain ⟨s1, e1⟩ := exactly hp _ hpc hcode
  obtain ⟨s', e, h⟩ := verifies hp _ hpc hcode
  rw [hmem] at e1 e h
  exact ⟨⟨s1, e1⟩, s', e, h⟩

/-! ## Completeness: what a signer produces, the kernel accepts

The reference scheme, on lists, for any `H`: secret keys from a seed, the
tree over the 16 leaves, and what signing leaf `l` puts in the image. First
the two facts completeness rests on — a WOTS chain walked `d` steps by the
signer and `15 - d` by the verifier is walked 15, and the path from a leaf
climbs to its ancestor — then the binary: given an image holding such a
signature, the kernel halts with 0. -/

/-- `n` lists, one after another. -/
def cat (e : Nat → List Byte) : Nat → List Byte
  | 0 => []
  | n + 1 => cat e n ++ e n

theorem endsTo_cat (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    ∀ n, endsTo H m base n = cat (endAt H m base) n
  | 0 => rfl
  | n + 1 => by simp only [endsTo, cat, endsTo_cat H m base n]

theorem cat_congr {e f : Nat → List Byte} : ∀ n, (∀ i < n, e i = f i) → cat e n = cat f n
  | 0, _ => rfl
  | n + 1, h => by
    simp only [cat]; rw [cat_congr n (fun i hi => h i (by omega)), h n (by omega)]

/-- Key `l`'s chain `i`: 32 bytes of HASH of the seed, `l`, `i` and zeros —
the seed is 32 bytes, so the input is one block. -/
def secret (H : List Byte → Fin 32 → Byte) (seed : List Byte) (l i : Nat) : List Byte :=
  hashL H (seed ++ [BitVec.ofNat 8 l, BitVec.ofNat 8 i] ++ List.replicate 30 0)

/-- Leaf `l`: the ends of its 67 chains, each walked 15 steps, and 32 zeros. -/
def leafRef (H : List Byte → Fin 32 → Byte) (seed : List Byte) (l : Nat) : List Byte :=
  hashL H (cat (fun i => chain H (secret H seed l i) 15) 67 ++ List.replicate 32 0)

/-- The tree: node `k` of level `j`. Level 0 is the leaves, level 4 the root. -/
def node (H : List Byte → Fin 32 → Byte) (seed : List Byte) : Nat → Nat → List Byte
  | 0, k => leafRef H seed k
  | j + 1, k => hashL H (node H seed j (2 * k) ++ node H seed j (2 * k + 1))

/-- The public key. -/
def rootRef (H : List Byte → Fin 32 → Byte) (seed : List Byte) : List Byte := node H seed 4 0

/-- The other child of a node's parent. -/
def sib (n : Nat) : Nat := if n % 2 = 0 then n + 1 else n - 1

/-- Leaf `l`'s authentication path: at level `j`, the sibling of its ancestor. -/
def authRef (H : List Byte → Fin 32 → Byte) (seed : List Byte) (l j : Nat) : List Byte :=
  node H seed j (sib (l / 2 ^ j))

/-- Climbing from `leaf` with path `auth` and index `l`, as the verifier does. -/
def climbRef (H : List Byte → Fin 32 → Byte) (leaf : List Byte) (auth : Nat → List Byte) (l : Nat) :
    Nat → List Byte
  | 0 => leaf
  | j + 1 => if l / 2 ^ j % 2 = 0 then hashL H (climbRef H leaf auth l j ++ auth j)
      else hashL H (auth j ++ climbRef H leaf auth l j)

/-- `a` steps, then `b` more, is `a + b`. -/
theorem chain_add (H : List Byte → Fin 32 → Byte) (x : List Byte) (a : Nat) :
    ∀ b, chain H (chain H x a) b = chain H x (a + b)
  | 0 => rfl
  | b + 1 => by simp only [chain, chain_add H x a b]; rfl

/-- **WOTS is complete**: what the signer reveals for digit `d`, walked
`15 - d` more steps, is the chain's end. -/
theorem wots_complete (H : List Byte → Fin 32 → Byte) (x : List Byte) {d : Nat} (hd : d < 16) :
    chain H (chain H x d) (15 - d) = chain H x 15 := by
  rw [chain_add, show d + (15 - d) = 15 by omega]

/-- **The path climbs to the ancestor**: after `j` levels from leaf `l`, with
`l`'s own path, the node is `l`'s ancestor at level `j`. -/
theorem path_climbs (H : List Byte → Fin 32 → Byte) (seed : List Byte) (l : Nat) :
    ∀ j, climbRef H (leafRef H seed l) (authRef H seed l) l j = node H seed j (l / 2 ^ j)
  | 0 => by simp [climbRef, node]
  | j + 1 => by
    simp only [climbRef, path_climbs H seed l j, authRef, sib, node]
    have hq : l / 2 ^ (j + 1) = l / 2 ^ j / 2 := by rw [Nat.pow_succ, Nat.div_div_eq_div_mul]
    rw [hq]
    generalize l / 2 ^ j = q
    by_cases h : q % 2 = 0
    · simp only [h, ↓reduceIte]
      rw [show 2 * (q / 2) = q by omega]
    · simp only [h, ↓reduceIte]
      rw [show 2 * (q / 2) = q - 1 by omega, show q - 1 + 1 = q by omega]

/-- The kernel's climb is the reference climb, read from memory. -/
theorem climbTo_ref (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) :
    ∀ j, climbTo H m base j = climbRef H (leafOf H m base) (authAt m base) (idx m base) j
  | 0 => rfl
  | j + 1 => by simp only [climbTo, climbRef, up, climbTo_ref H m base j]

/-- Bits 0 to 3 of an index are those of the index mod 16. -/
theorem low_bits (n : Nat) {j : Nat} (hj : j < 4) : n / 2 ^ j % 2 = n % 16 / 2 ^ j % 2 := by
  rcases (by omega : j = 0 ∨ j = 1 ∨ j = 2 ∨ j = 3) with rfl | rfl | rfl | rfl <;> simp <;> omega

theorem climbRef_congr (H : List Byte → Fin 32 → Byte) (leaf : List Byte) (a b : Nat → List Byte) (l l' : Nat)
    (hab : ∀ j < 4, a j = b j) (hl : l % 16 = l' % 16) :
    ∀ j ≤ 4, climbRef H leaf a l j = climbRef H leaf b l' j
  | 0, _ => rfl
  | j + 1, hj => by
    simp only [climbRef, climbRef_congr H leaf a b l l' hab hl j (by omega), hab j (by omega),
      low_bits l (show j < 4 by omega), low_bits l' (show j < 4 by omega), hl]

/-- **Completeness, on memory.** An image that holds a signature of its own
message under leaf `l < 16` of the key `seed` gives — chain `i` the secret
walked `dᵢ` steps, the path `l`'s, the root `seed`'s, the index `l` in its
low four bits — verifies, for every `H`. -/
theorem accepts_signed (H : List Byte → Fin 32 → Byte) (m : Word → Byte) (base : Word) (seed : List Byte)
    {l : Nat} (hl : l < 16) (hidx : idx m base % 16 = l)
    (hsig : ∀ i < 67, sigAt m base i = chain H (secret H seed l i) (digit m base i))
    (hauth : ∀ j < 4, authAt m base j = authRef H seed l j)
    (hroot : rootAt m base = rootRef H seed) : Verifies H m base := by
  have hleaf : leafOf H m base = leafRef H seed l := by
    unfold leafOf leafRef
    rw [endsTo_cat, cat_congr 67 (fun i hi => by
      show chain H (sigAt m base i) (15 - digit m base i) = _
      rw [hsig i hi, wots_complete H _ (digit_lt m base i)])]
  unfold Verifies
  rw [climbTo_ref, hleaf, climbRef_congr H _ (authAt m base) (authRef H seed l) (idx m base) l hauth
    (by rw [hidx, Nat.mod_eq_of_lt hl]) 4 (Nat.le_refl _), path_climbs, hroot, rootRef,
    Nat.div_eq_of_lt (show l < 2 ^ 4 by omega)]

/-- **Completeness, on the bytes.** The kernel, run from the state the shell
builds on such an image, halts with 0 — accept — after exactly
`3295 + 3 · steps` instructions. -/
theorem signed_halts_with_zero {env : Env} {base : Word} (hp : Placed env base) (img : ByteArray)
    (hsize : 752 ≤ img.size) (himg : ∀ d (h : d < 752), img.get d (by omega) = bytes.getD d 0)
    (seed : List Byte) {l : Nat} (hl : l < 16) (hidx : idx (memOfImage base img) base % 16 = l)
    (hsig : ∀ i < 67, sigAt (memOfImage base img) base i
      = chain env.hash (secret env.hash seed l i) (digit (memOfImage base img) base i))
    (hauth : ∀ j < 4, authAt (memOfImage base img) base j = authRef env.hash seed l j)
    (hroot : rootAt (memOfImage base img) base = rootRef env.hash seed) :
    ∃ s', run env (3295 + 3 * steps (memOfImage base img) base) (boot env.region img) = .halted 0 s' := by
  obtain ⟨-, s', e, -⟩ := from_boot hp img hsize himg
  have hv := accepts_signed env.hash _ base seed hl hidx hsig hauth hroot
  rw [ite_eq_left_of_eq_true _ _ (eq_true hv)] at e
  exact ⟨s', e⟩

#print axioms bytes_words
#print axioms code_of_image
#print axioms chain_iter
#print axioms chain_loop
#print axioms to_tree
#print axioms level_iter
#print axioms level_loop
#print axioms root_iff
#print axioms halt
#print axioms verifies
#print axioms exactly
#print axioms from_boot
#print axioms wots_complete
#print axioms path_climbs
#print axioms accepts_signed
#print axioms signed_halts_with_zero

end Exp206

/-- `lean --run Mss.lean OUT` writes `image` to OUT — that is `kernel.bin` —
and prints the listing: offset, word, instruction. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp206.image
  | _ => pure ()
  for (i, k) in Exp206.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
