/-
SPDX-License-Identifier: Apache-2.0

# exp217 — exp214's program, proved against the model

exp214's `invert.pio` — `pull block; mov isr, ~osr; push block`, wrapped —
ran on a Pico 2 and handed back eight words complemented. Here it is run on
`lean/Pio/Machine.lean`, for every word and every list of them that fits
the FIFOs.
-/
import Pio.Machine

namespace Exp217
open Pio

/-- exp214's three words, as loaded at 0. -/
def prog : List (BitVec 16) := [0x80a0, 0xa0cf, 0x8020]

/-- exp214's configuration: wrap from 2 to 0, everything else at reset. -/
def cfg : Config := { wrapBottom := 0, wrapTop := 2 }

theorem dec0 : decode (prog.getD 0 0) = some ⟨.pull false true, 0⟩ := by decide
theorem dec1 : decode (prog.getD 1 0) = some ⟨.mov .isr .invert .osr, 0⟩ := by decide
theorem dec2 : decode (prog.getD 2 0) = some ⟨.push false true, 0⟩ := by decide

/-- At the top of the loop, nothing pending. -/
def Top (s : Sm) : Prop := s.pc = 0 ∧ s.delay = 0 ∧ s.exec = none

/-- `pull block` with a word in TX: OSR takes it, on to 1. -/
theorem step0 (ext : W) (s : Sm) (hpc : s.pc = 0) (hd : s.delay = 0) (he : s.exec = none)
    (w : W) (rest : List W) (htx : s.tx = w :: rest) :
    step cfg prog ext s = some { s with pc := 1, osr := w, osrCount := 0, tx := rest, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec0]
  simp [exe, htx, advance, cfg]

/-- `mov isr, ~osr`: ISR takes the complement, its count empties, on to 2. -/
theorem step1 (ext : W) (s : Sm) (hpc : s.pc = 1) (hd : s.delay = 0) (he : s.exec = none) :
    step cfg prog ext s = some { s with pc := 2, isr := ~~~s.osr, isrCount := 0, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec1]
  simp [exe, advance, cfg]

/-- `push block` with room in RX: ISR goes in last and empties, and the wrap
takes the machine back to 0. -/
theorem step2 (ext : W) (s : Sm) (hpc : s.pc = 2) (hd : s.delay = 0) (he : s.exec = none)
    (hrx : s.rx.length < FIFO_DEPTH) :
    step cfg prog ext s =
      some { s with pc := 0, rx := s.rx ++ [s.isr], isr := 0, isrCount := 0, delay := 0, exec := none } := by
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec2]
  simp [exe, advance, cfg, hrx]

/-- **One word**: from the top, with `w` first in TX and room in RX, three
steps later `w` is gone from TX, `~w` is last in RX, and the machine is back
at the top. -/
theorem one_word (ext : W) (s : Sm) (hs : Top s) (w : W) (rest : List W) (htx : s.tx = w :: rest)
    (hrx : s.rx.length < FIFO_DEPTH) :
    ∃ s', run cfg prog ext 3 s = some s' ∧ Top s' ∧ s'.tx = rest ∧ s'.rx = s.rx ++ [~~~w] := by
  obtain ⟨hpc, hd, he⟩ := hs
  refine ⟨{ s with pc := 0, osr := w, osrCount := 0, tx := rest, isr := 0, isrCount := 0, rx := s.rx ++ [~~~w], delay := 0, exec := none }, ?_, ⟨rfl, rfl, rfl⟩, rfl, rfl⟩
  simp only [run]
  rw [step0 ext s hpc hd he w rest htx, Option.bind_some, step1 ext _ (by rfl) (by rfl) (by rfl),
    Option.bind_some, step2 ext _ (by rfl) (by rfl) (by rfl) (by exact hrx), Option.bind_some]

/-- **Every word, in order**: from the top with RX empty and `ws` in TX —
no more than the FIFO holds — `3 |ws|` steps later TX is empty and RX holds
the complement of each word, in the order they went in. -/
theorem every_word (ext : W) : ∀ (ws : List W) (s : Sm), Top s → s.tx = ws →
    s.rx.length + ws.length ≤ FIFO_DEPTH →
    ∃ s', run cfg prog ext (3 * ws.length) s = some s' ∧ Top s' ∧ s'.tx = [] ∧
      s'.rx = s.rx ++ ws.map (~~~·)
  | [], s, hs, htx, _ => ⟨s, rfl, hs, htx, by simp⟩
  | w :: rest, s, hs, htx, hlen => by
    obtain ⟨s1, e1, h1, t1, r1⟩ := one_word ext s hs w rest htx (by simp at hlen; omega)
    obtain ⟨s2, e2, h2, t2, r2⟩ := every_word ext rest s1 h1 t1 (by rw [r1]; simp at hlen ⊢; omega)
    refine ⟨s2, ?_, h2, t2, by rw [r2, r1]; simp⟩
    have hl : 3 * (w :: rest).length = 3 + 3 * rest.length := by simp only [List.length_cons]; omega
    rw [hl, run_add, e1]
    exact e2

/-- **And with nothing to do, it waits**: at the top with TX empty, a step
changes nothing — `pull block` stalls. -/
theorem waits (ext : W) (s : Sm) (hs : Top s) (htx : s.tx = []) : step cfg prog ext s = some s := by
  obtain ⟨hpc, hd, he⟩ := hs
  simp only [step, hd, he, hpc, Option.isSome_none, Option.orElse_none, Nat.lt_irrefl, ↓reduceIte]
  rw [dec0]
  simp only [exe, htx, Bool.false_eq_true, ↓reduceIte]
  cases s; simp_all

end Exp217

#print axioms Exp217.one_word
#print axioms Exp217.every_word
#print axioms Exp217.waits
