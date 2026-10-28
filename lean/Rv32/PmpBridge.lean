/-
SPDX-License-Identifier: Apache-2.0

# The RP2350's PMP and the model's

`chip_eq_model` says when `Rv32/PmpChip.lean`'s `chipCheck` decides every access as
`Priv.pmpCheck` does, so that a theorem about a monitor on the model is a theorem about it on the
chip:

  * the dynamic entries 0 to 3, read in the chip's order, are the model's four;
  * entry 4 matches every address and grants nothing, and is not locked -- so neither entries 5 to
    7 nor the hardwired regions ever decide;
  * `PMPCFGM0` binds none of entries 0 to 4 to M-mode.

And four facts about the chip that no reader here had before exp256: E6 makes `0x1b` -- the
specification's read and write -- write and execute; `0x1e` is what reads and writes on the chip;
exp240's box, as it configures it, cannot read its own data and can run it; and with no dynamic
entry over them, U-mode may load from the peripherals.
-/
import Rv32.PmpChip

namespace Rv32.PmpChip

open Rv32 Rv32.Priv

/-- `Priv.lean` reads in the specification's order. -/
theorem decodePmpCfgByte_standard (cfg : Word) (i : Fin 4) :
    decodePmpCfgByte cfg i = decodeCfg .standard ((cfg >>> (i.val * 8)) &&& 0xFF#32) := by
  simp [decodePmpCfgByte, decodeCfg]

theorem matchPmpEntry_eq (csrs : PrivCSRs) (i : Fin 4) (a : Word) (w : Nat) :
    matchPmpEntry csrs i a w =
      matchRange (decodePmpCfgByte csrs.pmpcfg0 i) (decodeNapotRange (pmpAddrVal csrs i)) a w := by
  simp only [matchPmpEntry, matchRange]

/-- When the chip's PMP is the model's: entries 0 to 3 read, in the chip's order, as the model reads its four;
    entry 4 over all of memory, granting nothing, not locked; `PMPCFGM0` binding none of 0 to 4. -/
structure Bridged (o : BitOrder) (p : ChipPmp) (csrs : PrivCSRs) : Prop where
  cfg   : ∀ i : Fin 4, decodeCfg o (byteOf p i.val) = decodePmpCfgByte csrs.pmpcfg0 i
  addr  : ∀ i : Fin 4, decodeNapotRange (addrOf p i.val) = decodeNapotRange (pmpAddrVal csrs i)
  deny  : decodeCfg o (byteOf p 4) = { mode := .NAPOT }
  all   : addrOf p 4 = 0x3FFFFFFF#32
  m0    : p.cfgm0 &&& 0x1F#32 = 0

theorem m0_bit {p : ChipPmp} (h : p.cfgm0 &&& 0x1F#32 = 0) (i : Nat) (hi : i < 5) :
    ((p.cfgm0 >>> i) &&& 1#32) ≠ 0 ↔ False := by
  constructor
  · intro hne
    apply hne
    apply BitVec.eq_of_toNat_eq
    have h' := congrArg BitVec.toNat h
    rw [BitVec.toNat_and, show (0x1F#32).toNat = 2^5 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod] at h'
    rw [BitVec.toNat_and, show (1#32).toNat = 2^1 - 1 from rfl, Nat.and_two_pow_sub_one_eq_mod,
      BitVec.toNat_ushiftRight, Nat.shiftRight_eq_div_pow]
    have z : (0 : Word).toNat = 0 := rfl
    rw [z] at h' ⊢
    have hi' : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3 ∨ i = 4 := by omega
    rcases hi' with rfl | rfl | rfl | rfl | rfl <;> omega
  · intro f; exact f.elim

/-- Entry 4 of a bridged chip matches every access that fits in memory, wholly. -/
theorem deny_matches {o : BitOrder} {p : ChipPmp} {csrs : PrivCSRs} (hb : Bridged o p csrs) (a : Word) (w : Nat)
    (hw : 0 < w) (hfit : a.toNat + w ≤ 2^32) :
    matchRange (decodeCfg o (byteOf p 4)) (decodeNapotRange (addrOf p 4)) a w = .FullMatch { mode := .NAPOT } := by
  rw [hb.deny, hb.all]
  have hr : decodeNapotRange 0x3FFFFFFF#32 = (0, 2^33) := by decide
  rw [hr]
  simp only [matchRange]
  have hne : ¬ (a.toNat + w ≤ 0 ∨ a.toNat ≥ 2^33) := by omega
  have hin : a.toNat ≥ 0 ∧ a.toNat + w ≤ 2^33 := ⟨Nat.zero_le _, by omega⟩
  have hoff : (({ mode := .NAPOT } : PmpCfgEntry).mode = .OFF) = False := by simp
  simp only [hoff, hne, hin, and_self, ↓reduceIte]

/-- **The chip decides as the model does, when bridged.** For every privilege, address, width and access that fits
    in memory, the RP2350's PMP -- sixteen regions, read in order `o` -- grants exactly what `Priv.pmpCheck` grants.
    A theorem about a monitor on the model holds on the chip for every configuration it keeps bridged. -/
theorem chip_eq_model {o : BitOrder} {p : ChipPmp} {csrs : PrivCSRs} (hb : Bridged o p csrs)
    (mode : PrivMode) (a : Word) (w : Nat) (acc : AccessType) (hw : 0 < w) (hfit : a.toNat + w ≤ 2^32) :
    chipCheck o p mode a w acc = pmpCheck csrs mode a w acc := by
  have hm : ∀ i : Fin 4, matchRange (decodeCfg o (byteOf p i.val)) (decodeNapotRange (addrOf p i.val)) a w =
      matchPmpEntry csrs i a w := fun i => by rw [matchPmpEntry_eq, hb.cfg i, hb.addr i]
  have hg : ∀ (c : PmpCfgEntry) (i : Nat), i < 5 →
      grants c (bindsM p i) mode acc = hasPermission c mode acc := by
    intro c i hi
    have hb0 : bindsM p i = false := by
      unfold bindsM; simp only [decide_eq_false_iff_not, not_and]; exact fun _ => (m0_bit hb.m0 i hi).mp
    unfold grants hasPermission
    rw [hb0]
    cases mode <;> cases acc <;> simp
  have h4 := deny_matches hb a w hw hfit
  have h0 := hm 0; have h1 := hm 1; have h2 := hm 2; have h3 := hm 3
  simp only [Fin.val_zero, Fin.val_one, Fin.val_two] at h0 h1 h2
  have h3' : matchRange (decodeCfg o (byteOf p 3)) (decodeNapotRange (addrOf p 3)) a w = matchPmpEntry csrs 3 a w := h3
  unfold chipCheck pmpCheck PMP_INDICES
  simp only [checkFrom, pmpCheckEntries]
  rw [h0]
  cases matchPmpEntry csrs 0 a w with
  | PartialMatch => rfl
  | FullMatch c => exact hg c 0 (by decide)
  | NoMatch =>
    dsimp only; rw [h1]
    cases matchPmpEntry csrs 1 a w with
    | PartialMatch => rfl
    | FullMatch c => exact hg c 1 (by decide)
    | NoMatch =>
      dsimp only; rw [h2]
      cases matchPmpEntry csrs 2 a w with
      | PartialMatch => rfl
      | FullMatch c => exact hg c 2 (by decide)
      | NoMatch =>
        dsimp only; rw [h3']
        cases matchPmpEntry csrs 3 a w with
        | PartialMatch => rfl
        | FullMatch c => exact hg c 3 (by decide)
        | NoMatch =>
          dsimp only; rw [h4]
          dsimp only
          rw [hg _ 4 (by decide)]
          cases mode <;> cases acc <;> rfl

/-! ## What the chip does that the model does not -/

/-- **Erratum E6 on the specification's read and write.** `0x1b` -- NAPOT, R and W in the specification's order -- is
    W and X on the chip, and not R. -/
theorem e6_0x1b : decodeCfg .standard 0x1B#32 = { r := true, w := true, mode := .NAPOT } ∧
    decodeCfg .e6 0x1B#32 = { w := true, x := true, mode := .NAPOT } := by decide

/-- On the chip, read and write without execute is `0x1e`. The code's read and execute, `0x1d`, reads the same
    either way. -/
theorem e6_0x1e_0x1d : decodeCfg .e6 0x1E#32 = { r := true, w := true, mode := .NAPOT } ∧
    decodeCfg .e6 0x1D#32 = decodeCfg .standard 0x1D#32 := by decide

/-- exp240's PMP as its boot writes it: code `0x1d`, data and stack `0x1b`, entry 3 inside the data. -/
def exp240 : ChipPmp :=
  { cfg0 := 0x001b1b1d, cfg1 := 0, addr := fun i => [0x2000400f, 0x200041ff, 0x20007dff, 0, 0, 0, 0, 0][i.val]!,
    cfgm0 := 0 }

/-- **exp240's box, on the chip.** U-mode cannot load the data -- exp225's seed, at `0x80010100` -- and can run it,
    past the code. In the model it is the other way round. -/
theorem exp240_on_chip :
    chipCheck .e6 exp240 .U 0x80010100#32 4 .Load = false ∧
    chipCheck .e6 exp240 .U 0x80010400#32 4 .Fetch = true ∧
    chipCheck .standard exp240 .U 0x80010100#32 4 .Load = true ∧
    chipCheck .standard exp240 .U 0x80010400#32 4 .Fetch = false := by decide

/-- **The hardwired regions.** With no dynamic entry over them, U-mode may load from the peripherals, which the model
    refuses. -/
theorem peripherals_open :
    chipCheck .e6 ⟨0, 0, fun _ => 0, 0⟩ .U 0x40000000#32 4 .Load = true ∧
    pmpCheck {} .U 0x40000000#32 4 .Load = false := by decide

end Rv32.PmpChip

#print axioms Rv32.PmpChip.chip_eq_model
#print axioms Rv32.PmpChip.e6_0x1b
#print axioms Rv32.PmpChip.e6_0x1e_0x1d
#print axioms Rv32.PmpChip.exp240_on_chip
#print axioms Rv32.PmpChip.peripherals_open
