/-
SPDX-License-Identifier: Apache-2.0

# The RP2350's PMP

`Rv32/Priv.lean`'s PMP has four entries, reads a configuration byte's bits in the RISC-V
specification's order, and refuses U-mode an access no entry matches. The RP2350's Hazard3 is
something else (its datasheet, sections 3.8.3 and 3.8.8.1, and erratum RP2350-E6):

  * sixteen regions, tried lowest first: 0 to 7 dynamic, 8 to 10 hardwired -- U-mode RWX over
    the ROM, the peripherals and SIO -- and 11 to 15 OFF;
  * a configuration byte's R in bit 2 and X in bit 0, transposed from the specification's: erratum
    RP2350-E6, `BitOrder.e6`. The RTL tools/hazard3/setup.sh pins has it fixed, `.standard`;
    the core the RP2350 was built from (its `tb_e6-rp2350`) has it;
  * NAPOT and OFF only (a write of TOR or NA4 is OFF), and a 32-byte grain: a write to an address
    register keeps its two low bits set (`Priv.decodeNapotRange` sets them, as the model's does) and
    its two top bits zero;
  * `PMPCFGM0`: a bit per dynamic region that binds M-mode to it, as the lock does, without
    locking it. Its bits for the hardwired regions are not kept.

Each of these is what `hazard3_pmp.v` does with a write, read off the source of both cores -- E6 the
older one's alone -- and exp257's differential holds `chipCheck` to both, one order to each.

`chipCheck` is that PMP. It is a model only: `Rv32/PmpBridge.lean` proves when it decides as
`Priv.pmpCheck` does, and privrun runs it (`--pmp`) without the proofs, so that a wrong chip model
builds and is refused by exp257's differential rather than by a theorem.
-/
import Rv32.Priv

namespace Rv32.PmpChip

open Rv32 Rv32.Priv

/-- The order a configuration byte's permission bits are read in. -/
inductive BitOrder where
  | standard  -- the RISC-V specification's: X, W, R from bit 2 down
  | e6        -- erratum RP2350-E6, the RP2350's: R, W, X from bit 2 down
  deriving DecidableEq, Repr

/-- A configuration byte, in a word's low eight bits, read in order `o`. -/
def decodeCfg (o : BitOrder) (b : Word) : PmpCfgEntry :=
  { r    := if o = .e6 then (b &&& 4#32) ≠ 0 else (b &&& 1#32) ≠ 0
    w    := (b &&& 2#32) ≠ 0
    x    := if o = .e6 then (b &&& 1#32) ≠ 0 else (b &&& 4#32) ≠ 0
    mode := if ((b >>> 3) &&& 3#32) = 3#32 then .NAPOT else .OFF
    lock := (b &&& 0x80#32) ≠ 0 }

/-- The PMP's registers, as software last wrote them: `PMPCFG0` and `PMPCFG1` (entries 0 to 7),
    `PMPADDR0` to `PMPADDR7`, and `PMPCFGM0`. `PMPCFG2` and `PMPCFG3`, and the address registers
    from 8, are hardwired. What the core keeps of a write is `byteOf`'s, `addrOf`'s and `bindsM`'s. -/
structure ChipPmp where
  cfg0  : Word
  cfg1  : Word
  addr  : Fin 8 → Word
  cfgm0 : Word

/-- The hardwired regions' address registers: ROM, the peripherals, SIO. -/
def hwAddr : Nat → Word
  | 8 => 0x01ffffff
  | 9 => 0x13ffffff
  | 10 => 0x35ffffff
  | _ => 0

/-- Region `i`'s configuration byte: as written for 0 to 7, `0x1f` (NAPOT, RWX, not locked) for the
    hardwired 8 to 10, OFF from 11. -/
def byteOf (p : ChipPmp) (i : Nat) : Word :=
  if i < 4 then (p.cfg0 >>> (i * 8)) &&& 0xFF#32
  else if i < 8 then (p.cfg1 >>> ((i - 4) * 8)) &&& 0xFF#32
  else if i < 11 then 0x1F#32
  else 0

/-- Region `i`'s address register, the two top bits zero. Its two low bits, which the 32-byte grain sets, are
    `decodeNapotRange`'s. -/
def addrOf (p : ChipPmp) (i : Nat) : Word :=
  if h : i < 8 then p.addr ⟨i, h⟩ &&& 0x3FFFFFFF#32 else hwAddr i

/-- Whether `PMPCFGM0` binds M-mode to region `i`: its bit, for a dynamic region. -/
def bindsM (p : ChipPmp) (i : Nat) : Bool := i < 8 ∧ ((p.cfgm0 >>> i) &&& 1#32) ≠ 0

/-- Whether an access matches a region with this configuration over this range: `Priv.lean`'s rule. -/
def matchRange (cfg : PmpCfgEntry) (r : Nat × Nat) (addr : Word) (width : Nat) : PmpMatchStatus :=
  if cfg.mode = .OFF then .NoMatch
  else
    if addr.toNat + width ≤ r.1 ∨ addr.toNat ≥ r.2 then .NoMatch
    else if addr.toNat ≥ r.1 ∧ addr.toNat + width ≤ r.2 then .FullMatch cfg
    else .PartialMatch

/-- What a region grants: M-mode everything, unless the region is locked or `PMPCFGM0` binds M-mode
    to it. -/
def grants (cfg : PmpCfgEntry) (m0 : Bool) (mode : PrivMode) (acc : AccessType) : Bool :=
  if mode = .M ∧ ¬ cfg.lock ∧ ¬ m0 then true
  else match acc with
    | .Fetch => cfg.x
    | .Load  => cfg.r
    | .Store => cfg.w

/-- The regions from `i`, for `n` of them, the first that touches the access deciding. -/
def checkFrom (o : BitOrder) (p : ChipPmp) (mode : PrivMode) (addr : Word) (width : Nat) (acc : AccessType) :
    Nat → Nat → Bool
  | 0, _ => mode = .M
  | n + 1, i =>
    let cfg := decodeCfg o (byteOf p i)
    match matchRange cfg (decodeNapotRange (addrOf p i)) addr width with
    | .NoMatch       => checkFrom o p mode addr width acc n (i + 1)
    | .PartialMatch  => false
    | .FullMatch c   => grants c (bindsM p i) mode acc

/-- **The RP2350's PMP**: all sixteen regions, from 0. -/
def chipCheck (o : BitOrder) (p : ChipPmp) (mode : PrivMode) (addr : Word) (width : Nat) (acc : AccessType) : Bool :=
  checkFrom o p mode addr width acc 16 0

end Rv32.PmpChip
