/-
SPDX-License-Identifier: Apache-2.0

# A window of SP 800-90B's health tests, the repetition count carried in

`lean/Rv32/Health.lean`'s `front` runs both tests over one window of 1024
samples, and starts the repetition count afresh: its setup sets the last
sample to 2 (none yet) and the run to 0. Over a stream of windows that is not
what SP 800-90B's repetition count is, nor what exp114's crate does: there the
run goes on across a window's edge, and 21 alike in a row fail even when 11 of
them end one window and 10 begin the next.

`win` is the same tests with the count carried in. Its setup takes the
window's reference and zeroes the adaptive proportion's count and the sample
counter, and touches nothing else; the 17-instruction loop over the samples
and the 3-instruction verdict are `Health.health` and `Health.verdictLine`,
unchanged. Whatever the last sample, the run and the failure flag were in
`s4`, `s5` and `s6` on the way in, they are the stream's on the way out.
-/
import Rv32.Health

namespace Alice.Window
open Rv32 Rv32.Health

/-- The window's setup: its reference bit, and its own two counts. `s4`,
`s5` and `s6` are left as the windows before left them. -/
def head : List Instr := [
  .ld .lw S7 S1 0, .opi .andi S7 S7 1, .opi .addi S8 0 0, .opi .addi S3 0 1024 ]

/-- The block: setup, 1024 samples, the verdict in `s6`. -/
def win : List Instr := head ++ health ++ verdictLine

theorem win_length : win.length = 24 := by decide

end Alice.Window
