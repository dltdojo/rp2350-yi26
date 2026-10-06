/-
SPDX-License-Identifier: Apache-2.0

# exp207 — the trace the seed cannot move

exp213's key generator and signer, run through `lean/Rv32/Ct.lean`'s checker.
What is here is only what is this experiment's: which bytes are public for
each kernel, and the abstract state at each loop head. `check` is decided —
the kernel's 108 and 155 instructions, one by one — and `constant_time_boot`
turns its verdict into the theorem.
-/
import Rv32.Ct
import Rv32.MssKeygen
import Rv32.MssSign

open Rv32 Rv32.Ct Rv32.Wots Rv32.Mss

set_option maxRecDepth 100000

namespace Exp207

/-- A state: every register the same in both runs, but those named. -/
def mk (o : List (Reg × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1.toNat == n) with
    | some (_, v) => v
    | none => .pub

/-! ## The key generator

Nothing it reads is public but its own code: the seed, and everything made
from it, is secret. -/

namespace Keygen
open Rv32.Mss.Keygen

def P : List (Nat × Nat) := []

/-- At the top of a leaf: the pointers setup made, the leaf's tree node
`TREE + 32 l`, the count of leaves. -/
def leaf : List (Reg × AV) := [(S0, .ptr 0 0), (S1, .ptr SEED SEED), (S2, .ptr ENDS ENDS),
  (S3, .aff 23 32 TREE), (S4, .ptr PRF PRF), (S5, .ptr BUF BUF), (S6, .ptr (ENDS + 2144) (ENDS + 2144)),
  (S7, .num 0 15), (T0, .num 0 0), (T4, .sec)]

def heads : Heads := [
  (54, mk leaf),
  (57, mk (leaf ++ [(S8, .num 0 66), (S9, .aff 24 32 ENDS)])),
  (63, mk (leaf ++ [(S8, .num 0 66), (S9, .aff 24 32 ENDS), (A2, .ptr BUF BUF)])),
  (100, mk [(S0, .ptr 0 0), (T0, .num 0 0), (T4, .sec), (S8, .num 1 15), (A2, .aff 24 (-32) (TREE + 992))])]

theorem accepted : check Rv32.Mss.Keygen.kernel P heads = true := by decide

end Keygen

/-! ## The signer

Public: the message and the index, and the scratch where the digits made from
the message go. The seed, the tree and everything else may differ. -/

namespace Sign
open Rv32.Mss.Sign

def P : List (Nat × Nat) := [(MSG, IDX + 1), (SCR + 64, SCR + 131)]

def chain : List (Reg × AV) := [(S0, .ptr 0 0), (S3, .ptr MSG MSG), (S4, .ptr PRF PRF), (S5, .ptr SCR SCR),
  (S7, .ptr (SCR + 131) (SCR + 131)), (S1, .aff 14 32 ((SIG : Int) - 32 * (SCR + 64))),
  (A4, .ptr (SCR + 64) (SCR + 130)), (A2, .ptr SCR SCR), (T0, .num 0 0), (T4, .sec)]

def heads : Heads := [
  (22, mk [(S0, .ptr 0 0), (S3, .ptr MSG MSG), (S1, .ptr SIG SIG), (S5, .ptr SCR SCR),
    (A4, .ptr MSG (MSG + 31)), (A5, .aff 14 2 ((SCR + 64 : Int) - 2 * MSG)), (A6, .ptr (MSG + 32) (MSG + 32))]),
  (75, mk chain), (81, mk chain), (84, mk chain),
  (111, mk [(S0, .ptr 0 0), (T0, .num 0 0), (T4, .sec), (A6, .num 1 4), (S2, .aff 16 (-32) (AUTH + 128))])]

theorem accepted : check Rv32.Mss.Sign.kernel P heads = true := by decide

end Sign

/-- **The key generator's trace does not depend on the seed.** Two images
that begin with `keygen.bin` — whatever else they hold, the seed included —
run in lock step: at every step the same `pc`, the same address loaded or
stored, the same HASH arguments, and the same end. -/
theorem keygen_constant_time {env : Env} {base : Word} (hp : Placed env base) (img1 img2 : ByteArray)
    (hsize1 : 432 ≤ img1.size) (hsize2 : 432 ≤ img2.size)
    (h1 : ∀ d (h : d < 432), img1.get d (by omega) = Rv32.Mss.Keygen.bytes.getD d 0)
    (h2 : ∀ d (h : d < 432), img2.get d (by omega) = Rv32.Mss.Keygen.bytes.getD d 0) :
    ∀ n, trace env n (boot env.region img1) = trace env n (boot env.region img2)
      ∧ Same (run env n (boot env.region img1)) (run env n (boot env.region img2)) := by
  have fit := hp.fit
  have hc1 := Rv32.Mss.Keygen.code_of_image fit img1 hsize1 h1
  have hc2 := Rv32.Mss.Keygen.code_of_image fit img2 hsize2 h2
  refine constant_time_boot hp Keygen.accepted (by decide) img1 img2 (fun o ho hin => ?_) hc1
  rcases hin with hin | ⟨_, hab, _⟩
  · rw [Rv32.Mss.Keygen.kernel_length] at hin
    have e : ∀ img : ByteArray, (h : 432 ≤ img.size) →
        (∀ d (h' : d < 432), img.get d (by omega) = Rv32.Mss.Keygen.bytes.getD d 0) →
        memOfImage base img (base + BitVec.ofNat 32 o) = BitVec.ofNat 8 (Rv32.Mss.Keygen.bytes.getD o 0).toNat := by
      intro img hs himg
      unfold memOfImage
      have hd : (base + BitVec.ofNat 32 o - base).toNat = o := off_of base o (by omega)
      simp only [hd, show o < img.size by omega, ↓reduceDIte]
      rw [himg o (by omega)]
    rw [e img1 hsize1 h1, e img2 hsize2 h2]
  · cases hab

/-- **The signer's trace does not depend on the seed, nor on the tree.** Two
images that begin with `sign.bin` and hold the same message, index and digit
scratch — whatever seed and tree they hold — run in lock step. -/
theorem sign_constant_time {env : Env} {base : Word} (hp : Placed env base) (img1 img2 : ByteArray)
    (hsize1 : 620 ≤ img1.size) (h1 : ∀ d (h : d < 620), img1.get d (by omega) = Rv32.Mss.Sign.bytes.getD d 0)
    (hpub : ∀ o, o < 0x10000 → InP Rv32.Mss.Sign.kernel.length Sign.P o →
      memOfImage base img1 (base + BitVec.ofNat 32 o) = memOfImage base img2 (base + BitVec.ofNat 32 o)) :
    ∀ n, trace env n (boot env.region img1) = trace env n (boot env.region img2)
      ∧ Same (run env n (boot env.region img1)) (run env n (boot env.region img2)) :=
  constant_time_boot hp Sign.accepted (by decide) img1 img2 hpub
    (Rv32.Mss.Sign.code_of_image hp.fit img1 hsize1 h1)

end Exp207

#print axioms Rv32.Ct.rel_mono
#print axioms Rv32.Ct.regs_write
#print axioms Rv32.Ct.range_addr
#print axioms Rv32.Ct.rel_refine
#print axioms Rv32.Ct.step_lock
#print axioms Rv32.Ct.obs_eq
#print axioms Rv32.Ct.run_lock
#print axioms Rv32.Ct.constant_time
#print axioms Rv32.Ct.constant_time_boot
#print axioms Exp207.Keygen.accepted
#print axioms Exp207.Sign.accepted
#print axioms Exp207.keygen_constant_time
#print axioms Exp207.sign_constant_time
