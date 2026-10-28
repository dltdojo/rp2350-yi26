/-
SPDX-License-Identifier: Apache-2.0

# exp257 — the bits the chip transposes

`Rv32/PmpChip.lean` is the RP2350's PMP: sixteen regions, erratum E6's bit order, the hardwired regions and
`PMPCFGM0`, held to two Hazard3 cores by differential/pmpdiff.py. Its `chip_eq_model` says when the chip decides
every access as `Priv.pmpCheck` does. This file asks two things of it.

**What exp240's box has to be on the chip.** exp240 writes `0x001b1b1d`: code `0x1d`, data and stack `0x1b`, read in
the specification's order. On the chip, `0x1b` is write and execute. The same box in the chip's order is data and
stack `0x1e`, and entry 4 over all of memory granting nothing: `exp240_chip` is bridged to exp240's model CSRs, so
on the chip it decides every access as the box exp240 proved. Round 3 writes it.

**That each of the bridge's conditions is needed.** Drop one, and an access the chip decides otherwise:

  * the bytes in the specification's order: exp240's own bytes, on the chip, refuse U-mode its data;
  * no entry 4: U-mode loads from the peripherals, which the hardwired region 9 grants;
  * entry 4 locked, or bound to M-mode by `PMPCFGM0`: M-mode cannot read its own memory.
-/
import Rv32.PmpBridge

namespace Exp257

open Rv32 Rv32.Priv Rv32.PmpChip

/-- exp240's PMP, as its boot writes it and its theorems are about. -/
def csrs240 : PrivCSRs :=
  { pmpcfg0 := 0x001b1b1d#32, pmpaddr0 := 0x2000400f#32, pmpaddr1 := 0x200041ff#32, pmpaddr2 := 0x20007dff#32 }

/-- exp240's box for the chip: code `0x1d`, data and stack `0x1e`; entry 4 NAPOT over all of memory, `0x18`. -/
def exp240_chip : ChipPmp :=
  { cfg0 := 0x001e1e1d, cfg1 := 0x18,
    addr := fun i => [0x2000400f, 0x200041ff, 0x20007dff, 0, 0x3fffffff, 0, 0, 0][i.val]!, cfgm0 := 0 }

theorem exp240_chip_bridged : Bridged .e6 exp240_chip csrs240 where
  cfg  := by decide
  addr := by decide
  deny := by decide
  all  := by decide
  m0   := by decide

/-- **exp240's box, on the chip.** Every access that fits in memory, by either privilege, is decided by
    `exp240_chip` on the chip as exp240's proved model decides it. -/
theorem exp240_on_the_chip (mode : PrivMode) (a : Word) (w : Nat) (acc : AccessType) (hw : 0 < w)
    (hfit : a.toNat + w ≤ 2^32) :
    chipCheck .e6 exp240_chip mode a w acc = pmpCheck csrs240 mode a w acc :=
  chip_eq_model exp240_chip_bridged mode a w acc hw hfit

/-- exp240's bytes as it writes them, on the chip: U-mode cannot load exp225's seed, which the model lets it. -/
theorem needs_order :
    chipCheck .e6 { exp240_chip with cfg0 := 0x001b1b1d } .U 0x80010100#32 4 .Load = false ∧
    pmpCheck csrs240 .U 0x80010100#32 4 .Load = true := by decide

/-- No entry 4: U-mode loads from the peripherals. -/
theorem needs_deny :
    chipCheck .e6 { exp240_chip with cfg1 := 0 } .U 0x40000000#32 4 .Load = true ∧
    pmpCheck csrs240 .U 0x40000000#32 4 .Load = false := by decide

/-- Entry 4 locked: M-mode cannot load from its own memory. -/
theorem needs_unlocked :
    chipCheck .e6 { exp240_chip with cfg1 := 0x98 } .M 0x80000000#32 4 .Load = false ∧
    pmpCheck csrs240 .M 0x80000000#32 4 .Load = true := by decide

/-- Entry 4 bound to M-mode by `PMPCFGM0`: the same. -/
theorem needs_m0 :
    chipCheck .e6 { exp240_chip with cfgm0 := 0x10 } .M 0x80000000#32 4 .Load = false ∧
    pmpCheck csrs240 .M 0x80000000#32 4 .Load = true := by decide

end Exp257

#print axioms Exp257.exp240_chip_bridged
#print axioms Exp257.exp240_on_the_chip
#print axioms Exp257.needs_order
#print axioms Exp257.needs_deny
#print axioms Exp257.needs_unlocked
#print axioms Exp257.needs_m0
