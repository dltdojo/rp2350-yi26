/-
SPDX-License-Identifier: Apache-2.0

# Addresses an `addi` moves

Two facts every one of alice's kernels needs about `addi` with a 12-bit
immediate: a small one counts up, and two `addi …, -2048` go 4096 back, which
is how a kernel points `a0` at the window it has just tested.
vk26-alice-1 proved them for itself; vk26-alice-2 is the second to need them.
-/
import Rv32.Blocks

namespace Alice.Addr
open Rv32

/-- `addi a0, s1, -2048; addi a0, a0, -2048`: 4096 back. -/
theorem back4096 {base : Word} (c : Nat) (h1 : 4096 ≤ c) (h2 : c < 0x10000) :
    base + BitVec.ofNat 32 c + (0x800 : BitVec 12).signExtend 32 + (0x800 : BitVec 12).signExtend 32
      = base + BitVec.ofNat 32 (c - 4096) := by
  rw [show (0x800 : BitVec 12) = BitVec.ofNat 12 2048 from rfl, se_neg 2048 (by decide) (by decide)]
  have hb := base.isLt
  bv_omega

/-- `addi r, r, d` for a small `d`. -/
theorem count_up (n d : Nat) (hd : d < 2048) :
    BitVec.ofNat 32 n + (BitVec.ofNat 12 d).signExtend 32 = BitVec.ofNat 32 (n + d) := by
  rw [se_small d hd, BitVec.ofNat_add]

#print axioms back4096
#print axioms count_up

end Alice.Addr
