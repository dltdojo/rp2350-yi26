/-
SPDX-License-Identifier: Apache-2.0

# A flat image, and the state a kernel starts in

`boot` is the calling convention, stated once: the image's first byte at the
region's base, `pc` there, every register zero but `sp`, which is the top of
the region, and nothing but zeros in memory past the image. The shell —
`tools/hazard3/harness` on the RTL, the Rust shell on the chip — is written to
produce exactly this state, and the proofs about a kernel begin from it.
-/
import Rv32.Machine

namespace Rv32

/-- Byte `k` of the image at `base + k`, zero everywhere else. -/
def memOfImage (base : Word) (img : ByteArray) : Word → Byte := fun a =>
  let d := (a - base).toNat
  if h : d < img.size then BitVec.ofNat 8 (img.get d h).toNat else 0

def boot (r : Region) (img : ByteArray) : Machine where
  pc := BitVec.ofNat 32 r.lo
  regs := fun x => if x = 2 then BitVec.ofNat 32 r.hi else 0
  mem := memOfImage (BitVec.ofNat 32 r.lo) img

end Rv32
