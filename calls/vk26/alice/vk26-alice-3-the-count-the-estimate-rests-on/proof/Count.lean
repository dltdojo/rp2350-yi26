/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-3 — the count the estimate rests on

SP 800-90B's most common value estimate (§6.3.1) rests on one number: how
many times the commonest value occurs. This kernel counts it, for 4096
byte-sized samples over all 256 values, in a way whose trace the samples
cannot move: for each value b it reads every sample and adds 1 when the
sample is b, with no branch and no address that depends on a sample. Then
the largest count, also without a branch.

   0       s0 = base
   1-7     s1 = base + 0x400 (the samples), s2 = s1 + 4096 (their end, and
           the histogram), s3 = s2, s4 = 0 (the value), s5 = 0 (the most),
           s7 = 256
   8-9     BIN: a0 = s1, s6 = 0
   10-15   LOOP: t1 = byte at a0; t1 = (t1 xor s4) <u 1; s6 += t1; a0 += 1;
           bne a0, s2 → LOOP
   16      the count to the histogram, at s3
   17-21   s5 = max(s5, s6), branchless: mask = -(s5 <u s6),
           s5 ^= (s6 ^ s5) & mask
   22-24   s3 += 4; s4 += 1; bne s4, s7 → BIN
   25      the most to base + 0x1800
   26-28   HALT 0

4096 is `lui t1, 1`, not `addi` and `slli`: lean/Rv32/Ct.lean knows a
`lui`'s value and only that a shift's is public, and it needs the
histogram's place as a number to accept a store there.
-/
import Rv32.Health
import Rv32.Asm
import Rv32.Ct

set_option maxRecDepth 20000

namespace Count
open Rv32 Rv32.Health

def setup : List Instr := [
  .opi .addi S1 S0 0x400, .lui T1 1, .op .add S2 S1 T1,
  .opi .addi S3 S2 0, .opi .addi S4 0 0, .opi .addi S5 0 0, .opi .addi S7 0 256 ]

def binTop : List Instr := [ .opi .addi A0 S1 0, .opi .addi S6 0 0 ]

/-- One sample against the value in `s4`: `s6` += 1 if they are equal. -/
def look : List Instr := [ .ld .lbu T1 A0 0, .op .xor T1 T1 S4, .opi .sltiu T1 T1 1, .op .add S6 S6 T1,
  .opi .addi A0 A0 1 ]

/-- `s5` = max(`s5`, `s6`), unsigned, without a branch. -/
def most : List Instr := [ .op .sltu T1 S5 S6, .op .sub T1 0 T1, .op .xor T2 S6 S5, .op .and T2 T2 T1,
  .op .xor S5 S5 T2 ]

def next : List Instr := [ .opi .addi S3 S3 4, .opi .addi S4 S4 1 ]

def kernel : List Instr :=
  [.auipc S0 0] ++ setup ++ binTop ++ look ++ [.br .bne A0 S2 (BitVec.ofInt 12 (2 * (10 - 15 : Int)))]
  ++ [.st .sw S3 S6 0] ++ most ++ next ++ [.br .bne S4 S7 (BitVec.ofInt 12 (2 * (8 - 24 : Int)))]
  ++ [.st .sw S3 S5 0, .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall]

theorem kernel_length : kernel.length = 29 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-! ## Constant time

The kernel through lean/Rv32/Ct.lean's checker. Only the program is public:
the samples, the histogram and the most may differ between two runs. At BIN
the value s4 is 0 to 255 and s3 is the histogram's place for it,
base + 0x1400 + 4·s4; at LOOP, the same, and a0 is somewhere in the samples. -/

open Rv32.Ct

def known (o : List (Nat × AV)) : AState :=
  (List.range 32).map fun n => match o.find? (fun p => p.1 == n) with
    | some (_, v) => v
    | none => .sec

/-- What is known at both heads: the four places, the value, and 256. -/
def fixed : List (Nat × AV) :=
  [(8, .ptr 0 0), (9, .ptr 0x400 0x400), (18, .ptr 0x1400 0x1400), (19, .aff 20 4 0x1400), (20, .num 0 255),
   (23, .num 256 256)]

def heads : Heads := [(8, known fixed), (10, known ((10, .ptr 0x400 0x13ff) :: fixed))]

set_option maxRecDepth 100000 in
theorem accepted : check kernel [] heads = true := by decide

/-- An image that begins with the kernel's 116 bytes holds the kernel. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray)
    (hsize : 116 ≤ img.size) (himg : ∀ d (h : d < 116), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base kernel :=
  Rv32.code_of_image hfit (by rw [kernel_length]; decide) (toBytes_words kernel) img
    (by rw [kernel_length]; exact hsize)
    (fun d h => himg d (by rw [kernel_length] at h; exact h))

/-- **The trace does not depend on the samples.** Two images that begin
with the kernel — whatever samples they hold, and whatever else — run in
lock step: at every step the same `pc`, the same address loaded or stored,
and the same end. -/
theorem count_constant_time {env : Env} {base : Word} (hp : Placed env base) (img1 img2 : ByteArray)
    (hsize1 : 116 ≤ img1.size) (h1 : ∀ d (h : d < 116), img1.get d (by omega) = bytes.getD d 0)
    (hsize2 : 116 ≤ img2.size) (h2 : ∀ d (h : d < 116), img2.get d (by omega) = bytes.getD d 0) :
    ∀ n, trace env n (boot env.region img1) = trace env n (boot env.region img2)
      ∧ Same (run env n (boot env.region img1)) (run env n (boot env.region img2)) := by
  refine constant_time_boot hp accepted (by decide) img1 img2 (fun o ho hin => ?_)
    (code_of_image hp.fit img1 hsize1 h1)
  rcases hin with hin | ⟨_, hab, _⟩
  · rw [kernel_length] at hin
    have e : ∀ img : ByteArray, (h : 116 ≤ img.size) →
        (∀ d (h' : d < 116), img.get d (by omega) = bytes.getD d 0) →
        memOfImage base img (base + BitVec.ofNat 32 o) = BitVec.ofNat 8 (bytes.getD o 0).toNat := by
      intro img hs himg
      unfold memOfImage
      have hd : (base + BitVec.ofNat 32 o - base).toNat = o := off_of base o (by omega)
      simp only [hd, show o < img.size by omega, ↓reduceDIte]
      rw [himg o (by omega)]
    rw [e img1 hsize1 h1, e img2 hsize2 h2]
  · cases hab

end Count

#print axioms Count.accepted
#print axioms Count.count_constant_time

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Count.image
  | _ => pure ()
  for (i, k) in Count.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
