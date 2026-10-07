/-
SPDX-License-Identifier: Apache-2.0

# exp220 — two PIO programs, and the order they are run in

exp217 proved exp214's `invert` against `lean/Pio/Machine.lean`. This is
the same program with its middle instruction as a parameter, `mov isr, o osr`
for any of `mov`'s three operations, proved once:

  0  pull block          OSR <- TX, waiting while it is empty
  1  mov isr, o osr      ISR <- o(OSR)
  2  push block          RX <- ISR       → wrap to 0

Two instances run on the chip: `invert` on PIO0 (`o` = `~`, exp214's three
words) and `reverse` on PIO1 (`o` = `::`). `either_order` says what the
experiment is about: a word through one and then the other comes back the
same whichever goes first.
-/
import Pio.Machine

namespace Exp220
open Pio

def pull : Instr := ⟨.pull false true, 0⟩
def push : Instr := ⟨.push false true, 0⟩
def middle (o : MovOp) : Instr := ⟨.mov .isr o .osr, 0⟩

/-- The program, as words: what the shell loads. -/
def prog (o : MovOp) : List (BitVec 16) := [encode pull, encode (middle o), encode push]

/-- Wrap from 2 to 0, everything else at reset. -/
def cfg : Config := { wrapBottom := 0, wrapTop := 2 }

/-- What `mov`'s operation does to a word. -/
def apply : MovOp → W → W
  | .plain, v => v
  | .invert, v => ~~~v
  | .reverse, v => reverse32 v

/-- The two instances' words: `invert` is exp214's, the three exp217's
theorems are about. -/
theorem words_invert : prog .invert = [0x80a0, 0xa0cf, 0x8020] := by decide
theorem words_reverse : prog .reverse = [0x80a0, 0xa0d7, 0x8020] := by decide

theorem dec0 (o : MovOp) : decode ((prog o).getD 0 0) = some pull := decode_encode _
theorem dec1 (o : MovOp) : decode ((prog o).getD 1 0) = some (middle o) := decode_encode _
theorem dec2 (o : MovOp) : decode ((prog o).getD 2 0) = some push := decode_encode _

def Top (s : Sm) : Prop := s.pc = 0 ∧ s.delay = 0 ∧ s.exec = none

theorem step0 (o : MovOp) (ext : W) (s : Sm) (hpc : s.pc = 0) (hd : s.delay = 0) (he : s.exec = none)
    (w : W) (rest : List W) (htx : s.tx = w :: rest) :
    step cfg (prog o) ext s = some { s with pc := 1, osr := w, osrCount := 0, tx := rest, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec0]
  simp [exe, htx, advance, cfg, pull]

theorem step1 (o : MovOp) (ext : W) (s : Sm) (hpc : s.pc = 1) (hd : s.delay = 0) (he : s.exec = none) :
    step cfg (prog o) ext s = some { s with pc := 2, isr := apply o s.osr, isrCount := 0, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec1]
  cases o <;> simp [exe, advance, cfg, middle, apply]

theorem step2 (o : MovOp) (ext : W) (s : Sm) (hpc : s.pc = 2) (hd : s.delay = 0) (he : s.exec = none)
    (hrx : s.rx.length < FIFO_DEPTH) :
    step cfg (prog o) ext s =
      some { s with pc := 0, rx := s.rx ++ [s.isr], isr := 0, isrCount := 0, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec2]
  simp [exe, advance, cfg, hrx, push]

theorem one_word (o : MovOp) (ext : W) (s : Sm) (hs : Top s) (w : W) (rest : List W) (htx : s.tx = w :: rest)
    (hrx : s.rx.length < 4) :
    ∃ s', run cfg (prog o) ext 3 s = some s' ∧ Top s' ∧ s'.tx = rest ∧ s'.rx = s.rx ++ [apply o w] := by
  obtain ⟨hpc, hd, he⟩ := hs
  refine ⟨{ s with pc := 0, osr := w, osrCount := 0, tx := rest, isr := 0, isrCount := 0, rx := s.rx ++ [apply o w], delay := 0, exec := none }, ?_, ⟨rfl, rfl, rfl⟩, rfl, rfl⟩
  simp only [run]
  rw [step0 o ext s hpc hd he w rest htx, Option.bind_some, step1 o ext _ (by rfl) (by rfl) (by rfl),
    Option.bind_some, step2 o ext _ (by rfl) (by rfl) (by rfl) (by simp only [FIFO_DEPTH]; exact hrx),
    Option.bind_some]

/-- **Every word, in order**, for either instance: from the top, with `ws`
in TX and room for them in RX, `3 |ws|` steps later TX is empty and RX holds
each word with `o` applied, in the order they went in. -/
theorem every_word (o : MovOp) (ext : W) : ∀ (ws : List W) (s : Sm), Top s → s.tx = ws →
    s.rx.length + ws.length ≤ 4 →
    ∃ s', run cfg (prog o) ext (3 * ws.length) s = some s' ∧ Top s' ∧ s'.tx = [] ∧
      s'.rx = s.rx ++ ws.map (apply o)
  | [], s, hs, htx, _ => ⟨s, rfl, hs, htx, by simp⟩
  | w :: rest, s, hs, htx, hlen => by
    obtain ⟨s1, e1, h1, t1, r1⟩ := one_word o ext s hs w rest htx (by simp at hlen; omega)
    obtain ⟨s2, e2, h2, t2, r2⟩ := every_word o ext rest s1 h1 t1 (by rw [r1]; simp at hlen ⊢; omega)
    refine ⟨s2, ?_, h2, t2, by rw [r2, r1]; simp⟩
    have hl : 3 * (w :: rest).length = 3 + 3 * rest.length := by simp only [List.length_cons]; omega
    rw [hl, run_add, e1]
    exact e2

/-- **And with nothing to do, it waits.** -/
theorem waits (o : MovOp) (ext : W) (s : Sm) (hs : Top s) (htx : s.tx = []) :
    step cfg (prog o) ext s = some s := by
  obtain ⟨hpc, hd, he⟩ := hs
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec0]
  simp only [exe, htx, pull, Bool.false_eq_true, ↓reduceIte]
  cases s; simp_all

/-- **The two operations commute**: complementing a word and reversing its
bits give the same word in either order. -/
theorem commute (w : W) : apply .reverse (apply .invert w) = apply .invert (apply .reverse w) := by
  ext i hi
  simp [apply, reverse32, BitVec.getElem_reverse, BitVec.getMsbD_not, hi]

/-- **Either order**: words through `invert` and then `reverse` come back as
the same list as through `reverse` and then `invert` — what the shell
checks on the chip, word by word. -/
theorem either_order (ws : List W) :
    (ws.map (apply .invert)).map (apply .reverse) = (ws.map (apply .reverse)).map (apply .invert) := by
  simp only [List.map_map]
  exact List.map_congr_left fun w _ => commute w

end Exp220

#print axioms Exp220.words_reverse
#print axioms Exp220.every_word
#print axioms Exp220.waits
#print axioms Exp220.either_order
