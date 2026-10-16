/-
SPDX-License-Identifier: Apache-2.0

# RISC-V M-Mode Privileged Micro-Model Semantics

Privileged state, CSRs, PMP access enforcement, and trap transitions for
RP2350 Hazard3, in about 440 lines. Models two silicon facts measured on the
chip or its RTL: the PMP_GRAIN = 3 readback (exp209) and that a trapping
instruction still bumps `minstret` (exp203: `ecall` and an illegal instruction
are counted).

What it does not model, so no theorem about it is a claim about the chip:
  * `mcounteren` — U-mode `Zicsr` always traps here, which is true of the chip
    only while `mcounteren` is 0;
  * the C extension — fetch is always 4 bytes at a 4-aligned pc;
  * CSR access checks — a write to a read-only CSR, a write to `mcycle` or
    `minstret`, and any access to an unimplemented CSR neither trap nor write;
  * exp203's frontend effect: the same instructions are counted 5 or 4 times
    depending on what was fetched behind an `mret`.
-/
import Rv32.Isa
import Rv32.Machine

namespace Rv32.Priv

open Rv32

/-- RP2350 Hazard3 supported privilege modes (no S-mode). -/
inductive PrivMode where
  | U : PrivMode  -- Encoding 0b00: Unprivileged User mode
  | M : PrivMode  -- Encoding 0b11: Privileged Machine mode
  deriving DecidableEq, Repr, Inhabited

def PrivMode.toBits : PrivMode → BitVec 2
  | .U => 0#2
  | .M => 3#2

def PrivMode.ofBits (bits : BitVec 2) : PrivMode :=
  if bits = 3#2 then .M else .U

/-- Modeled fields of mstatus (CSR 0x300). -/
structure MStatus where
  mie  : Bool     := false
  mpie : Bool     := false
  mpp  : PrivMode := .U
  deriving DecidableEq, Repr, Inhabited

/-- Modeled fields of mcountinhibit (CSR 0x320). -/
structure MCountInhibit where
  cy : Bool := false  -- Bit 0: Inhibit mcycle
  ir : Bool := false  -- Bit 2: Inhibit minstret
  deriving DecidableEq, Repr, Inhabited

/-- Privileged CSR bank for RP2350 Hazard3 micro-model. -/
structure PrivCSRs where
  mstatus       : MStatus       := {}
  mtvec         : Word          := 0
  mscratch      : Word          := 0
  mepc          : Word          := 0
  mcause        : Word          := 0
  pmpcfg0       : Word          := 0
  pmpaddr0      : Word          := 0
  pmpaddr1      : Word          := 0
  pmpaddr2      : Word          := 0
  pmpaddr3      : Word          := 0
  mcountinhibit : MCountInhibit := {}
  minstret      : Word          := 0
  mcycle        : Word          := 0
  deriving DecidableEq, Repr, Inhabited

/-- Complete Tier 2 Privileged Machine State. -/
structure PrivMachine where
  core   : Rv32.Machine
  mode   : PrivMode := .M
  csrs   : PrivCSRs := {}
  halted : Bool     := false

/-- Address-matching modes supported by RP2350 Hazard3 PMP hardware. -/
inductive PmpAddrMode where
  | OFF   : PmpAddrMode  -- 0b00: Null region (disabled)
  | NAPOT : PmpAddrMode  -- 0b11: Naturally aligned power-of-2 region (>= 32 bytes)
  deriving DecidableEq, Repr, Inhabited

/-- Decoded single-entry PMP configuration byte. -/
structure PmpCfgEntry where
  r    : Bool        := false
  w    : Bool        := false
  x    : Bool        := false
  mode : PmpAddrMode := .OFF
  lock : Bool        := false
  deriving DecidableEq, Repr, Inhabited

/-- Extract the i-th configuration byte (i ∈ 0..3) from pmpcfg0. -/
def decodePmpCfgByte (pmpcfg0 : Word) (idx : Fin 4) : PmpCfgEntry :=
  let shift := idx.val * 8
  let byte  := (pmpcfg0 >>> shift) &&& 0xFF#32
  let aBits := (byte >>> 3) &&& 3#32
  { r    := (byte &&& 1#32) ≠ 0
    w    := (byte &&& 2#32) ≠ 0
    x    := (byte &&& 4#32) ≠ 0
    mode := if aBits = 3#32 then .NAPOT else .OFF
    lock := (byte &&& 0x80#32) ≠ 0 }

/-- Physical address register value for entry idx (definitionally direct). -/
def pmpAddrVal (csrs : PrivCSRs) : Fin 4 → Word
  | ⟨0, _⟩ => csrs.pmpaddr0
  | ⟨1, _⟩ => csrs.pmpaddr1
  | ⟨2, _⟩ => csrs.pmpaddr2
  | ⟨3, _⟩ => csrs.pmpaddr3

/-- Hazard3 silicon-accurate readback for pmpaddr_i (models exp209 quirk). -/
def readPmpAddr (csrs : PrivCSRs) (idx : Fin 4) : Word :=
  let raw := pmpAddrVal csrs idx
  if (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .NAPOT then
    raw ||| 3#32     -- Bits [1:0] read as 11 when NAPOT (G=3)
  else
    raw &&& ~~~7#32  -- Bits [2:0] read as 000 when OFF

/-- Access type requested by instruction fetch, load, or store. -/
inductive AccessType where
  | Fetch : AccessType  -- Requires X permission; faults with mcause = 1
  | Load  : AccessType  -- Requires R permission; faults with mcause = 5
  | Store : AccessType  -- Requires W permission; faults with mcause = 7
  deriving DecidableEq, Repr, Inhabited

/-- Count trailing ones in a 32-bit word (bounded by 32). -/
def countTrailingOnes32 (w : Word) : Nat :=
  let rec loop (n : Nat) (acc : Nat) : Nat :=
    match n with
    | 0 => acc
    | n' + 1 =>
      if ((w >>> acc) &&& 1#32) = 1#32 then
        loop n' (acc + 1)
      else
        acc
  loop 32 0

/-- Decode a Hazard3 NAPOT pmpaddr word into a [lo, hi) Nat byte range. -/
def decodeNapotRange (rawAddr : Word) : (Nat × Nat) :=
  let eff := rawAddr ||| 3#32
  let t   := countTrailingOnes32 eff
  let mask : Nat := 1 <<< (t + 1)
  let alignedAddr : Nat := (eff.toNat / mask) * mask
  let base : Nat := alignedAddr * 4
  let size : Nat := 1 <<< (t + 3)
  (base, base + size)

/-- Check whether entry `idx` matches any byte or all bytes of [addr, addr + width). -/
inductive PmpMatchStatus where
  | NoMatch      : PmpMatchStatus
  | PartialMatch : PmpMatchStatus
  | FullMatch    : PmpCfgEntry → PmpMatchStatus
  deriving DecidableEq, Repr

def matchPmpEntry (csrs : PrivCSRs) (idx : Fin 4) (addr : Word) (width : Nat) : PmpMatchStatus :=
  let cfg := decodePmpCfgByte csrs.pmpcfg0 idx
  if cfg.mode = .OFF then .NoMatch
  else
    let (lo, hi) := decodeNapotRange (pmpAddrVal csrs idx)
    let reqLo : Nat := addr.toNat
    let reqHi : Nat := reqLo + width
    if reqHi ≤ lo ∨ reqLo ≥ hi then
      .NoMatch
    else if reqLo ≥ lo ∧ reqHi ≤ hi then
      .FullMatch cfg
    else
      .PartialMatch

def hasPermission (cfg : PmpCfgEntry) (mode : PrivMode) (acc : AccessType) : Bool :=
  if mode = .M ∧ ¬ cfg.lock then
    true
  else
    match acc with
    | .Fetch => cfg.x
    | .Load  => cfg.r
    | .Store => cfg.w

def pmpCheckEntries (csrs : PrivCSRs) (mode : PrivMode) (addr : Word) (width : Nat) (acc : AccessType) : List (Fin 4) → Bool
  | [] => mode = .M
  | idx :: rest =>
    match matchPmpEntry csrs idx addr width with
    | .NoMatch       => pmpCheckEntries csrs mode addr width acc rest
    | .PartialMatch  => false
    | .FullMatch cfg => hasPermission cfg mode acc

def PMP_INDICES : List (Fin 4) := [0, 1, 2, 3]

def pmpCheck (csrs : PrivCSRs) (mode : PrivMode) (addr : Word) (width : Nat) (acc : AccessType) : Bool :=
  pmpCheckEntries csrs mode addr width acc PMP_INDICES

def CAUSE_FETCH_ACCESS_FAULT : Word := 1
def CAUSE_ILLEGAL_INSTR      : Word := 2
def CAUSE_LOAD_MISALIGNED    : Word := 4
def CAUSE_LOAD_ACCESS_FAULT  : Word := 5
def CAUSE_STORE_MISALIGNED   : Word := 6
def CAUSE_STORE_ACCESS_FAULT : Word := 7
def CAUSE_ECALL_UMODE        : Word := 8
def CAUSE_ECALL_MMODE        : Word := 11

def bumpCounters (csrs : PrivCSRs) : PrivCSRs :=
  { csrs with
    mcycle   := if csrs.mcountinhibit.cy then csrs.mcycle   else csrs.mcycle + 1
    minstret := if csrs.mcountinhibit.ir then csrs.minstret else csrs.minstret + 1 }

def raiseTrap (s : PrivMachine) (cause : Word) : PrivMachine :=
  let mstatus' : MStatus :=
    { mpp  := s.mode
      mpie := s.csrs.mstatus.mie
      mie  := false }
  let csrs' := bumpCounters
    { s.csrs with
      mstatus := mstatus'
      mepc    := s.core.pc
      mcause  := cause }
  { s with
    mode := .M
    csrs := csrs'
    core := { s.core with pc := s.csrs.mtvec &&& ~~~3#32 } }

def execMret (s : PrivMachine) : PrivMachine :=
  if s.mode ≠ .M then
    raiseTrap s CAUSE_ILLEGAL_INSTR
  else
    let targetMode := s.csrs.mstatus.mpp
    let mstatus' : MStatus :=
      { mie  := s.csrs.mstatus.mpie
        mpie := true
        mpp  := .U }
    let csrs' := bumpCounters { s.csrs with mstatus := mstatus' }
    { s with
      mode := targetMode
      csrs := csrs'
      core := { s.core with pc := s.csrs.mepc } }

def readCSR (csrs : PrivCSRs) (csrNum : Word) : Word :=
  if csrNum = 0x300 then
    let m := csrs.mstatus
    (if m.mie then 0x8#32 else 0#32) |||
    (if m.mpie then 0x80#32 else 0#32) |||
    ((m.mpp.toBits.zeroExtend 32) <<< 11)
  else if csrNum = 0x305 then csrs.mtvec
  else if csrNum = 0x320 then
    (if csrs.mcountinhibit.cy then 1#32 else 0#32) |||
    (if csrs.mcountinhibit.ir then 4#32 else 0#32)
  else if csrNum = 0x340 then csrs.mscratch
  else if csrNum = 0x341 then csrs.mepc
  else if csrNum = 0x342 then csrs.mcause
  else if csrNum = 0x3A0 then csrs.pmpcfg0
  else if csrNum = 0x3B0 then readPmpAddr csrs ⟨0, by decide⟩
  else if csrNum = 0x3B1 then readPmpAddr csrs ⟨1, by decide⟩
  else if csrNum = 0x3B2 then readPmpAddr csrs ⟨2, by decide⟩
  else if csrNum = 0x3B3 then readPmpAddr csrs ⟨3, by decide⟩
  else if csrNum = 0xB00 ∨ csrNum = 0xC00 then csrs.mcycle
  else if csrNum = 0xB02 ∨ csrNum = 0xC02 then csrs.minstret
  else 0

def writeCSR (csrs : PrivCSRs) (csrNum : Word) (val : Word) : PrivCSRs :=
  if csrNum = 0x300 then
    let mie  := (val &&& 0x8#32) ≠ 0
    let mpie := (val &&& 0x80#32) ≠ 0
    let mpp  := PrivMode.ofBits ((val >>> 11).extractLsb' 0 2)
    { csrs with mstatus := { mie := mie, mpie := mpie, mpp := mpp } }
  else if csrNum = 0x305 then
    { csrs with mtvec := val &&& ~~~3#32 }
  else if csrNum = 0x320 then
    let cy := (val &&& 1#32) ≠ 0
    let ir := (val &&& 4#32) ≠ 0
    { csrs with mcountinhibit := { cy := cy, ir := ir } }
  else if csrNum = 0x340 then { csrs with mscratch := val }
  else if csrNum = 0x341 then { csrs with mepc := val }
  else if csrNum = 0x342 then { csrs with mcause := val }
  else if csrNum = 0x3A0 then
    let old := csrs.pmpcfg0
    let b0 := if (decodePmpCfgByte old ⟨0, by decide⟩).lock then old &&& 0xFF#32 else val &&& 0xFF#32
    let b1 := if (decodePmpCfgByte old ⟨1, by decide⟩).lock then old &&& 0xFF00#32 else val &&& 0xFF00#32
    let b2 := if (decodePmpCfgByte old ⟨2, by decide⟩).lock then old &&& 0xFF0000#32 else val &&& 0xFF0000#32
    let b3 := if (decodePmpCfgByte old ⟨3, by decide⟩).lock then old &&& 0xFF000000#32 else val &&& 0xFF000000#32
    { csrs with pmpcfg0 := b0 ||| b1 ||| b2 ||| b3 }
  else if csrNum = 0x3B0 then
    if (decodePmpCfgByte csrs.pmpcfg0 ⟨0, by decide⟩).lock then csrs else { csrs with pmpaddr0 := val }
  else if csrNum = 0x3B1 then
    if (decodePmpCfgByte csrs.pmpcfg0 ⟨1, by decide⟩).lock then csrs else { csrs with pmpaddr1 := val }
  else if csrNum = 0x3B2 then
    if (decodePmpCfgByte csrs.pmpcfg0 ⟨2, by decide⟩).lock then csrs else { csrs with pmpaddr2 := val }
  else if csrNum = 0x3B3 then
    if (decodePmpCfgByte csrs.pmpcfg0 ⟨3, by decide⟩).lock then csrs else { csrs with pmpaddr3 := val }
  else
    csrs

def isEcall (w : Word) : Bool := w = 0x00000073
def isMret  (w : Word) : Bool := w = 0x30200073
def isZicsr (w : Word) : Bool :=
  let opcode := w &&& 0x7F#32
  let funct3 := (w >>> 12) &&& 7#32
  opcode = 0x73#32 ∧ (funct3 = 1#32 ∨ funct3 = 2#32 ∨ funct3 = 3#32 ∨
                      funct3 = 5#32 ∨ funct3 = 6#32 ∨ funct3 = 7#32)

def execZicsr (s : PrivMachine) (w : Word) : PrivMachine :=
  if s.mode ≠ .M then
    raiseTrap s CAUSE_ILLEGAL_INSTR
  else
    let rd : Reg := (w >>> 7).extractLsb' 0 5
    let funct3 := (w >>> 12) &&& 7#32
    let rs1Val := s.core.reg ((w >>> 15).extractLsb' 0 5)
    let uimm : Word := ((w >>> 15) &&& 0x1F#32)
    let csrNum : Word := w >>> 20
    let oldVal := readCSR s.csrs csrNum
    let writeVal := match funct3 with
      | 1 => rs1Val
      | 2 => oldVal ||| rs1Val
      | 3 => oldVal &&& ~~~rs1Val
      | 5 => uimm
      | 6 => oldVal ||| uimm
      | 7 => oldVal &&& ~~~uimm
      | _ => oldVal
    let shouldWrite := match funct3 with
      | 1 | 5 => true
      | 2 | 3 => ((w >>> 15).extractLsb' 0 5) ≠ 0
      | 6 | 7 => uimm ≠ 0
      | _ => false
    let csrs' := if shouldWrite then writeCSR s.csrs csrNum writeVal else s.csrs
    let core' := s.core.setReg rd oldVal
    let csrs'' := bumpCounters csrs'
    { s with csrs := csrs'', core := core'.next }

/-- Factorized trap cause evaluation for U-mode / M-mode single step. -/
def uModeTrapCause (s : PrivMachine) (w : Word) : Option Word :=
  if ¬ pmpCheck s.csrs s.mode s.core.pc 4 .Fetch then
    some CAUSE_FETCH_ACCESS_FAULT
  else if isEcall w then
    some (if s.mode = .U then CAUSE_ECALL_UMODE else CAUSE_ECALL_MMODE)
  else if s.mode = .U ∧ (isMret w ∨ isZicsr w) then
    some CAUSE_ILLEGAL_INSTR
  else
    match Rv32.decode w with
    | none => if isMret w ∨ isZicsr w then none else some CAUSE_ILLEGAL_INSTR
    | some (.ld op _ rs1 imm) =>
      let a := s.core.reg rs1 + imm.signExtend 32
      if a.toNat % op.size ≠ 0 then some CAUSE_LOAD_MISALIGNED
      else if ¬ pmpCheck s.csrs s.mode a op.size .Load then some CAUSE_LOAD_ACCESS_FAULT
      else none
    | some (.st op rs1 _ imm) =>
      let a := s.core.reg rs1 + imm.signExtend 32
      if a.toNat % op.size ≠ 0 then some CAUSE_STORE_MISALIGNED
      else if ¬ pmpCheck s.csrs s.mode a op.size .Store then some CAUSE_STORE_ACCESS_FAULT
      else none
    | some _ => none

def PrivMachine.step (env : Rv32.Env) (s : PrivMachine) : PrivMachine :=
  if s.halted then s
  else
    let w := BitVec.ofNat 32 (readLE s.core.mem s.core.pc 4)
    match uModeTrapCause s w with
    | some cause => raiseTrap s cause
    | none =>
      if isMret w then execMret s
      else if isZicsr w then execZicsr s w
      else
        match Rv32.decode w with
        | some instr =>
          match Rv32.exec env s.core instr with
          | .running core' =>
            let csrs' := bumpCounters s.csrs
            { s with core := core', csrs := csrs' }
          | .halted _ core' =>
            let csrs' := bumpCounters s.csrs
            { s with core := core', csrs := csrs', halted := true }
          | .fault _ _ => raiseTrap s CAUSE_ILLEGAL_INSTR
        | none => raiseTrap s CAUSE_ILLEGAL_INSTR

def PrivMachine.run (env : Rv32.Env) : Nat → PrivMachine → PrivMachine
  | 0, s => s
  | n + 1, s =>
    if s.halted then s
    else PrivMachine.run env n (PrivMachine.step env s)

structure UBoxed (s : PrivMachine) (lo hi : Nat) : Prop where
  isUMode     : s.mode = .U
  notHalted   : s.halted = false
  cfg0Mode    : (decodePmpCfgByte s.csrs.pmpcfg0 0).mode = .NAPOT
  cfg0Read    : (decodePmpCfgByte s.csrs.pmpcfg0 0).r = true
  cfg0Write   : (decodePmpCfgByte s.csrs.pmpcfg0 0).w = true
  cfg0Exec    : (decodePmpCfgByte s.csrs.pmpcfg0 0).x = true
  addr0Range  : decodeNapotRange s.csrs.pmpaddr0 = (lo, hi)
  otherOff    : ∀ (i : Fin 4), i.val > 0 → (decodePmpCfgByte s.csrs.pmpcfg0 i).mode = .OFF

/-! ## Unit Theorems (Phase 1 Acceptance Criteria) -/

theorem matchPmpEntry_off (csrs : PrivCSRs) (idx : Fin 4) (addr : Word) (width : Nat)
    (h : (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .OFF) :
    matchPmpEntry csrs idx addr width = .NoMatch := by
  unfold matchPmpEntry
  simp [h]

theorem pmp_readback_napot_low_bits (csrs : PrivCSRs) (idx : Fin 4)
    (h : (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .NAPOT) :
    (readPmpAddr csrs idx &&& 3#32) = 3#32 := by
  unfold readPmpAddr
  simp only [h, ite_true]
  ext i
  simp
  intro h3
  exact Or.inr h3

theorem umode_default_deny (csrs : PrivCSRs) (addr : Word) (width : Nat) (acc : AccessType)
    (h : ∀ idx : Fin 4, (decodePmpCfgByte csrs.pmpcfg0 idx).mode = .OFF) :
    pmpCheck csrs .U addr width acc = false := by
  unfold pmpCheck PMP_INDICES pmpCheckEntries
  have h0 : matchPmpEntry csrs 0 addr width = .NoMatch := matchPmpEntry_off csrs 0 addr width (h 0)
  have h1 : matchPmpEntry csrs 1 addr width = .NoMatch := matchPmpEntry_off csrs 1 addr width (h 1)
  have h2 : matchPmpEntry csrs 2 addr width = .NoMatch := matchPmpEntry_off csrs 2 addr width (h 2)
  have h3 : matchPmpEntry csrs 3 addr width = .NoMatch := matchPmpEntry_off csrs 3 addr width (h 3)
  rw [h0]; dsimp only
  unfold pmpCheckEntries
  rw [h1]; dsimp only
  unfold pmpCheckEntries
  rw [h2]; dsimp only
  unfold pmpCheckEntries
  rw [h3]; dsimp only
  rfl

theorem umode_zicsr_traps (s : PrivMachine) (w : Word) (hU : s.mode = .U) :
    execZicsr s w = raiseTrap s CAUSE_ILLEGAL_INSTR := by
  unfold execZicsr
  have hNotM : s.mode ≠ .M := by rw [hU]; decide
  simp [hNotM]

theorem umode_mret_traps (s : PrivMachine) (hU : s.mode = .U) :
    execMret s = raiseTrap s CAUSE_ILLEGAL_INSTR := by
  unfold execMret
  have hNotM : s.mode ≠ .M := by rw [hU]; decide
  simp [hNotM]

theorem mcountinhibit_holds_mcycle (csrs : PrivCSRs) (hCY : csrs.mcountinhibit.cy = true) :
    (bumpCounters csrs).mcycle = csrs.mcycle := by
  unfold bumpCounters
  simp [hCY]

theorem mcountinhibit_holds_minstret (csrs : PrivCSRs) (hIR : csrs.mcountinhibit.ir = true) :
    (bumpCounters csrs).minstret = csrs.minstret := by
  unfold bumpCounters
  simp [hIR]

theorem bumpCounters_minstret_step (csrs : PrivCSRs) (hIR : csrs.mcountinhibit.ir = false) :
    (bumpCounters csrs).minstret = csrs.minstret + 1 := by
  unfold bumpCounters
  simp [hIR]

end Rv32.Priv
