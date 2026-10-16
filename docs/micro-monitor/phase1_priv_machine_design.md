# Phase 1 Design Document: RISC-V M-Mode Privileged Micro-Model Semantics in Lean 4 (`lean/Rv32/Priv.lean`)

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **Document Date**: 2026-10-15
* **Target Deliverable**: `lean/Rv32/Priv.lean`
* **Hardware Dependency**: Needs 0 (Pure formal specification in Lean 4; no board or RTL required)
* **Parent Architecture Plan**: [RISC-V M-Mode Privileged Micro-Model and Verified Micro-Monitor Design Plan](./2026-10-14-0925-micro-monitor-in-lean4-design-zh-tw.md)
* **Upstream Motivation**: [Hardware Wallet Verified Bytes Assessment](../2026-10-11-0610-verified-bytes-for-a-hardware-wallet-zh-tw.md)

## 1. Executive Summary and Architectural Objective

### Reversing the Privilege Boundary Inversion on RP2350

Current formal verification artifacts in this repository (`exp229` modular arithmetic, `exp228` Script interpreter, and `exp208` SHA-256) run inside User mode (`U-mode`) under Physical Memory Protection (`PMP`) constraints, while an unverified C and assembly harness (`shell.c` and `harness.S`) executes in Machine mode (`M-mode`) with unrestricted access to all SRAM, CSRs, and peripherals. This layout models a sandbox for untrusted code rather than a secure enclave for a hardware wallet: existing proofs guarantee that the cryptographic core never steps out of bounds, but they do not prevent a compromised `M-mode` shell or USB stack from reading private keys.

To uphold the hardware wallet invariant that **seed material never leaves the device**, the system architecture flips this boundary by shrinking `M-mode` to a minimal, formally verified **Micro-Monitor** (~100–150 instructions) and demoting the USB stack, communication protocol, and display drivers into an isolated `U-mode` domain.

| Architectural State | Machine Mode (`M-mode`, Highest Privilege) | User Mode (`U-mode`, Restricted Domains) | Security Guarantee |
| :--- | :--- | :--- | :--- |
| **Current Baseline** | Unverified C/Assembly shell (`shell.c`, `harness.S`) with full memory, CSR, and peripheral control | Formally verified cryptographic kernels (`exp229` mod-$p$, `exp228` Script, `exp208` SHA-256) | Kernels cannot exceed memory bounds, but any vulnerability in the C shell compromises all secrets |
| **Target End-State** | Formally verified **Micro-Monitor** handling only PMP configuration, trap forwarding, and zeroization | **Domain 1**: Cryptographic core holding private keys<br>**Domain 2**: Untrusted USB, display, and protocol stack | Hardware PMP guarantees that even a fully compromised USB stack cannot read Domain 1 private keys |

### Why Path B (Lean 4 Micro-Model) Enables Fast Verification and Silicon Fidelity

Phase 1 implements **Path B (Micro-Model in Lean 4)** in `lean/Rv32/Priv.lean` rather than importing an automated Sail-to-Lean translation (`opencompl/sail-riscv-lean`, Path A) for three engineering reasons:

1. **Minimal Trusted Computing Base (TCB < 300 Lines)**: Full Sail models target RV64 and pull in tens of thousands of lines covering `S-mode`, `Sv39`/`Sv48` virtual memory, floating-point, and vector extensions absent on the RP2350 Hazard3 core. Scoping `lean/Rv32/Priv.lean` strictly to the `RV32IM + Zicsr` subset implemented by Hazard3 keeps the formal specification under 300 lines of auditable Lean 4 code.
2. **Preventing Lean Kernel Out-of-Memory (OOM) Failures**: Prior experiments (`exp201`, `exp229`) demonstrated that symbolic evaluation (`simp`, `decide`) over bloated state records exhausts memory. A compact state record allows multi-step symbolic execution to complete in seconds.
3. **Exact Modeling of Hazard3 Silicon Quirks**: Generic RISC-V specifications do not capture hardware-specific behaviors observed on RP2350 silicon, such as the 32-byte PMP granularity readback mutations documented in `exp209` and the trap instruction counting behaviors measured in `exp203`.

## 2. Two-Tiered Refinement Architecture and Backward Compatibility

### Layer Separation Between Tier 2 (`PrivMachine`) and Tier 1 (`Rv32.Machine`)

Phase 1 defines **Tier 2 (`lean/Rv32/Priv.lean`)** as a privileged wrapper around the existing **Tier 1 (`lean/Rv32/Machine.lean`)** unprivileged model. Tier 1 remains untouched so that every existing kernel binary (`kernel.bin`) and correctness proof remains valid without modification.

| Architectural Tier | Lean 4 Module | Modeled State and Semantics | Verified Properties and Deliverables |
| :--- | :--- | :--- | :--- |
| **Tier 2: Privileged Micro-Model** | `lean/Rv32/Priv.lean` *(Phase 1 Target)* | Privilege mode (`M`/`U`), privileged CSRs (`mstatus`, `mtvec`, `mepc`, `mcause`, `mscratch`, `pmpcfg0`, `pmpaddr0..3`, `mcountinhibit`), PMP access enforcement, `Zicsr`, `mret`, and architectural traps | Micro-Monitor memory isolation, context zeroization (`x1..x31` and scratch SRAM), safe syscall forwarding, and exact instruction-count theorems |
| **Refinement Bridge** | `lean/Rv32/Refinement.lean` *(Phase 2 Target)* | State projection `PrivMachine.toUMachine` and sandbox invariant `UBoxed s lo hi` | Theorem proving that single-step and multi-step execution in `U-mode` within a locked PMP region `[lo, hi)` is strictly equivalent to `Rv32.step` and `Rv32.run` |
| **Tier 1: Unprivileged Core Model** | `lean/Rv32/Machine.lean` *(Unchanged)* | Unprivileged `RV32IM` registers, flat/bounded memory projection, `(env : Env)`, and `(s : Machine)` | Existing verified cryptographic and consensus kernels (`exp229` mod-$p$, `exp228` Script interpreter, `exp208` SHA-256) and unaltered `kernel.bin` binaries |

### Guarantees of 100% Backward Compatibility

* **Binary ABI Compatibility**: All existing `kernel.bin` payloads are pure `RV32IM` `U-mode` binaries that issue zero privileged instructions and interact with the host environment exclusively through `ecall` (`t0 = 1` for halt with exit status in `a0`, `t0 = 0/2` for SHA-256 hashing, and `t0 = 3` for signature verification). Because the Micro-Monitor preserves this exact `ecall` ABI, no existing `kernel.bin` requires recompilation.
* **Proof Reuse via State Projection**: In Tier 1 `Machine.lean`, `(env : Env)` and `(s : Machine)` represent the mathematical projection of `PrivMachine` when executing in `U-mode` inside an active PMP window `[lo, hi)`. Once Phase 2 discharges the bridge theorem showing that `U-mode` transitions commute with this projection, all existing Tier 1 theorems import directly as lemmas into the end-to-end system proof.

## 3. Privileged State and CSR Specification provide Minimal Hazard3 Coverage

### Privilege Modes and Architectural State (`PrivMachine`)

The RP2350 Hazard3 processor implements only Machine mode (`M-mode`) and User mode (`U-mode`), omitting Supervisor mode (`S-mode`). `lean/Rv32/Priv.lean` models the privilege level as a two-variant inductive type and embeds the unprivileged register/memory state alongside the privileged CSR bank.

```lean
namespace Rv32.Priv

/-- RP2350 Hazard3 supported privilege modes (no S-mode). -/
inductive PrivMode where
  | U : PrivMode  -- Encoding 0b00: Unprivileged User mode
  | M : PrivMode  -- Encoding 0b11: Privileged Machine mode
  deriving DecidableEq, Repr, Inhabited

/-- Encode PrivMode into its 2-bit architectural representation (for mstatus.MPP). -/
def PrivMode.toBits : PrivMode → UInt32
  | .U => 0b00
  | .M => 0b11

/-- Decode 2-bit mstatus.MPP field; defaults to .U on unsupported encodings. -/
def PrivMode.ofBits (bits : UInt32) : PrivMode :=
  if (bits &&& 0b11) == 0b11 then .M else .U
```

### Minimal Privileged CSR Subset (`PrivCSRs`)

Although the RP2350 Hazard3 hardware provides 8 PMP regions (`pmp0..pmp7`), isolating the Micro-Monitor, Cryptographic Enclave (Domain 1), and Untrusted I/O Stack (Domain 2) requires modeling only the first 4 PMP entries controlled by a single configuration register (`pmpcfg0`) and four address registers (`pmpaddr0..pmpaddr3`).

| CSR Name | CSR Address | Modeled Fields / Bit Positions | Semantic Role in `lean/Rv32/Priv.lean` |
| :--- | :--- | :--- | :--- |
| `mstatus` | `0x300` | `MIE` (bit 3), `MPIE` (bit 7), `MPP` (bits 12:11) | Tracks global interrupt enable, prior interrupt state, and target privilege mode restored by `mret` |
| `mtvec` | `0x305` | `BASE` (bits 31:2), `MODE = 0b00` (bits 1:0, Direct) | Fixed in Direct mode; provides the target PC (`mtvec &&& ~~~0x3`) when any trap or `ecall` enters `M-mode` |
| `mscratch` | `0x340` | Full 32-bit word | Holds the `M-mode` monitor context/stack pointer so trap entry can swap pointers via `csrrw` without clobbering `U-mode` GP registers |
| `mepc` | `0x341` | Full 32-bit word (2-byte/4-byte aligned) | Latches the faulting or `ecall` instruction PC on trap entry; incremented by 4 (`mepc + 4`) before `mret` on non-halting syscalls |
| `mcause` | `0x342` | `Interrupt` (bit 31 = 0), `ExceptionCode` (bits 30:0) | Identifies `U-mode` `ecall` (`8`) and memory/instruction faults (`1`, `2`, `5`, `7`) |
| `pmpcfg0` | `0x3A0` | `pmp0cfg..pmp3cfg` (4 bytes: `L` [7], `A` [4:3], `X` [2], `W` [1], `R` [0]) | Configures R/W/X permissions, lock bit, and addressing mode (`OFF = 0` or 32-byte `NAPOT = 3`) for regions 0–3 |
| `pmpaddr0..3` | `0x3B0..0x3B3` | 32-bit physical address word (`addr >> 2` in NAPOT format) | Encodes physical memory boundaries `[lo, hi)` for PMP regions 0–3 |
| `mcountinhibit` | `0x320` | `CY` (bit 0), `IR` (bit 2) | Freezes `mcycle` (`CY = 1`) and `minstret` (`IR = 1`) on monitor entry (`csrwi mcountinhibit, 5`) to preserve constant-time proofs |

```lean
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

/-- Privileged CSR bank for the RP2350 Hazard3 micro-model. -/
structure PrivCSRs where
  mstatus       : MStatus       := {}
  mtvec         : UInt32        := 0
  mscratch      : UInt32        := 0
  mepc          : UInt32        := 0
  mcause        : UInt32        := 0
  pmpcfg0       : UInt32        := 0
  pmpaddr0      : UInt32        := 0
  pmpaddr1      : UInt32        := 0
  pmpaddr2      : UInt32        := 0
  pmpaddr3      : UInt32        := 0
  mcountinhibit : MCountInhibit := {}
  minstret      : UInt32        := 0
  mcycle        : UInt32        := 0
  deriving DecidableEq, Repr, Inhabited

/-- Complete Tier 2 Privileged Machine State. -/
structure PrivMachine where
  core   : Rv32.Machine  -- Underlying Tier 1 unprivileged state (pc, regs, mem, halted)
  mode   : PrivMode      := .M
  csrs   : PrivCSRs      := {}
  deriving Repr
```

## 4. Hazard3 Silicon Quirks and CSR Read/Write Semantics

### Modeling the `exp209` PMP Granularity Readback Quirk (`PMP_GRAIN = 3`)

The RP2350 Hazard3 core hardwires PMP granularity to **32 bytes (`PMP_GRAIN = 3`, $2^{3+2} = 32$ bytes)** and supports only the `OFF` (`0b00`) and `NAPOT` (`0b11`) address-matching modes (ignoring `TOR` and `NA4`). As observed in hardware experiment `exp209`, reading `pmpaddr0..3` back via `csrr` does **not** return the raw 32-bit value previously written via `csrw`:

* When the corresponding `pmpcfg_i.A` field is `OFF` (`0b00`), hardware readback forces bits `[2:0]` of `pmpaddr_i` to `0b000` (`raw_addr &&& ~~~0x7`).
* When the corresponding `pmpcfg_i.A` field is `NAPOT` (`0b11`), hardware readback forces bits `[1:0]` of `pmpaddr_i` to `0b11` (`raw_addr ||| 0x3`), because any NAPOT region on a `PMP_GRAIN = 3` core is at least 32 bytes wide.

To ensure 100% fidelity with silicon and prevent unsound monitor self-checks:

1. **CSR Storage vs. Readback Projection**: `PrivCSRs` stores the written register word in `pmpaddr0..3` (masked to valid physical address bits), while `readCSR` applies the mode-dependent Hazard3 bit-masking transformation dynamically based on the active `pmpcfg0` byte.
2. **Verification Rule for Phase 3**: The Micro-Monitor implementation and its Lean 4 proof must **never** verify PMP configuration by checking whether `csrr pmpaddr_i` equals the raw written value bit-for-bit. Instead, the proof establishes that the instruction sequence writing `pmpaddr_i` and `pmpcfg0` transitions `PrivMachine` into a state satisfying the effective `pmpCheck` boundary predicate.

```lean
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

/-- Extract the i-th configuration byte (i ∈ 0..3) from pmpcfg0.
    Hazard3 forces unsupported A modes (TOR=1, NA4=2) to OFF. -/
def decodePmpCfgByte (pmpcfg0 : UInt32) (idx : Fin 4) : PmpCfgEntry :=
  let shift := (idx.val.toUInt32) * 8
  let byte  := (pmpcfg0 >>> shift) &&& 0xFF
  let aBits := (byte >>> 3) &&& 0x3
  { r    := (byte &&& 0x01) != 0
    w    := (byte &&& 0x02) != 0
    x    := (byte &&& 0x04) != 0
    mode := if aBits == 0b11 then .NAPOT else .OFF
    lock := (byte &&& 0x80) != 0 }

/-- Hazard3 silicon-accurate readback for pmpaddr_i (models exp209 quirk). -/
def readPmpAddr (csrs : PrivCSRs) (idx : Fin 4) : UInt32 :=
  let raw := match idx.val with
    | 0 => csrs.pmpaddr0
    | 1 => csrs.pmpaddr1
    | 2 => csrs.pmpaddr2
    | _ => csrs.pmpaddr3
  let cfg := decodePmpCfgByte csrs.pmpcfg0 idx
  match cfg.mode with
  | .OFF   => raw &&& (~~~0x7 : UInt32)  -- Bits [2:0] read as 000 when OFF
  | .NAPOT => raw ||| (0x3 : UInt32)     -- Bits [1:0] read as 11 when NAPOT (G=3)
```

### Modeling the `exp203` and `exp228` Counter-Inhibit Quirk (`mcountinhibit`)

Hardware experiments `exp203` and `exp228` revealed that uninhibited trap entry/exit boundaries introduce microarchitectural cycle/instruction counting offsets (`+3` in `exp203`, `+4` in `exp228`). In `lean/Rv32/Priv.lean`:

* `mcountinhibit` bit 0 (`CY`) and bit 2 (`IR`) directly gate whether `PrivMachine.step` increments `csrs.mcycle` and `csrs.minstret`.
* The Micro-Monitor trap entry point begins immediately with `csrwi mcountinhibit, 5` (setting `CY = 1` and `IR = 1`) and clears `mcountinhibit` immediately prior to `mret`.
* By modeling `mcountinhibit` explicitly in `PrivMachine.step`, Phase 3 upgrades the empirical compensation constants into formally proved constant-instruction-count theorems over the monitor's entry and exit paths.

### Lock Bit (`L`) Write-Protection Semantics

In accordance with the RISC-V Privileged Specification, once `pmpcfg_i.L` is set (`lock = true`), writes to both `pmpaddr_i` and the corresponding byte in `pmpcfg0` are ignored by `writeCSR` until a full hardware reset. When the Micro-Monitor configures non-locked dynamic `U-mode` windows (`L = 0`), `M-mode` can reconfigure `pmpcfg0` and `pmpaddr0..3` freely across domain switches between Domain 1 (Cryptographic Core) and Domain 2 (Untrusted USB/Display Stack).

## 5. Physical Memory Protection (PMP) Access Determination Semantics

### NAPOT Range Decoding with 32-Byte Granularity

In RISC-V `NAPOT` encoding, `pmpaddr_i` stores physical address bits `[33:2]`. With Hazard3's `PMP_GRAIN = 3` (minimum 32-byte region), hardware forces bits `[1:0]` of the effective `NAPOT` pattern to `0b11`. If the number of contiguous trailing ones in `(raw_pmpaddr ||| 0x3)` is $t \ge 2$, then:

* The region size in bytes is $2^{t + 3}$ (so $t = 2$ yields $2^5 = 32\text{ bytes}$, $t = 3$ yields $64\text{ bytes}$, etc.).
* The base physical address `lo` is obtained by clearing the lowest $t + 1$ bits of `(raw_pmpaddr ||| 0x3)` and shifting left by 2: `lo = ((eff >>> (t + 1)) <<< (t + 3))`.
* The upper bound `hi` is `lo + (1 <<< (t + 3))`.

```lean
/-- Access type requested by instruction fetch, load, or store. -/
inductive AccessType where
  | Fetch : AccessType  -- Requires X permission; faults with mcause = 1
  | Load  : AccessType  -- Requires R permission; faults with mcause = 5
  | Store : AccessType  -- Requires W permission; faults with mcause = 7
  deriving DecidableEq, Repr, Inhabited

/-- Count trailing ones in a 32-bit word (bounded by 32 for total evaluation). -/
def countTrailingOnes32 (w : UInt32) : Nat :=
  let rec loop (n : Nat) (acc : Nat) : Nat :=
    match n with
    | 0 => acc
    | n' + 1 =>
      if ((w >>> acc.toUInt32) &&& 1) == 1 then
        loop n' (acc + 1)
      else
        acc
  loop 32 0

/-- Decode a Hazard3 NAPOT pmpaddr word into a 64-bit [lo, hi) physical byte range
    (using UInt64 to avoid 32-bit overflow when hi = 2^32). -/
def decodeNapotRange (rawAddr : UInt32) : (UInt64 × UInt64) :=
  let eff := rawAddr ||| (0x3 : UInt32)  -- Enforce G=3 (minimum 32-byte region)
  let t   := countTrailingOnes32 eff     -- t >= 2 guaranteed by ||| 0x3
  let maskBits : UInt64 := (1 : UInt64) <<< (t + 1).toUInt64
  let alignedAddr : UInt64 := (eff.toUInt64) &&& (~~~(maskBits - 1))
  let base : UInt64 := alignedAddr <<< 2
  let size : UInt64 := (1 : UInt64) <<< (t + 3).toUInt64
  (base, base + size)
```

### Priority Matching and Partial-Overlap Rejection (`pmpCheck`)

Per the RISC-V Privileged Specification, PMP entries are statically prioritized from `0` to `3`: the **lowest-numbered entry** that matches *any* byte of a memory access `[addr, addr + width)` determines whether the access succeeds.

* **Partial Overlap Fault**: If a multi-byte access (such as a 4-byte `lw`/`sw` or instruction fetch) partially overlaps the boundary of the highest-priority matching PMP entry without being completely contained within `[lo, hi)`, the access is unconditionally denied and triggers an access fault trap.
* **Privilege Mode Enforcement**:
  * **In `U-mode` (`mode == .U`)**: Default deny. If no PMP entry matches `[addr, addr + width)`, the access fails. If entry `i` matches completely, the access succeeds if and only if the requested `R`, `W`, or `X` bit is set in `pmpcfg_i`.
  * **In `M-mode` (`mode == .M`)**: Default allow unless locked. If no PMP entry matches, or if the matching entry has `lock == false`, the access succeeds. If the matching entry has `lock == true`, the entry's `R/W/X` permissions are enforced against `M-mode` as well.

```lean
/-- Check whether entry `idx` matches any byte or all bytes of `[addr, addr + width)`. -/
inductive PmpMatchStatus where
  | NoMatch      : PmpMatchStatus
  | PartialMatch : PmpMatchStatus  -- Straddles boundary -> immediate access fault
  | FullMatch    : PmpCfgEntry → PmpMatchStatus
  deriving DecidableEq, Repr

def matchPmpEntry (csrs : PrivCSRs) (idx : Fin 4) (addr : UInt32) (width : UInt32) : PmpMatchStatus :=
  let cfg := decodePmpCfgByte csrs.pmpcfg0 idx
  match cfg.mode with
  | .OFF => .NoMatch
  | .NAPOT =>
    let raw := match idx.val with
      | 0 => csrs.pmpaddr0 | 1 => csrs.pmpaddr1 | 2 => csrs.pmpaddr2 | _ => csrs.pmpaddr3
    let (lo, hi) := decodeNapotRange raw
    let reqLo : UInt64 := addr.toUInt64
    let reqHi : UInt64 := reqLo + width.toUInt64
    if reqHi <= lo || reqLo >= hi then
      .NoMatch
    else if reqLo >= lo && reqHi <= hi then
      .FullMatch cfg
    else
      .PartialMatch

/-- Check if `cfg` grants permission for `acc` under current privilege `mode`. -/
def hasPermission (cfg : PmpCfgEntry) (mode : PrivMode) (acc : AccessType) : Bool :=
  if mode == .M && !cfg.lock then
    true
  else
    match acc with
    | .Fetch => cfg.x
    | .Load  => cfg.r
    | .Store => cfg.w

/-- Evaluate PMP access across priority-ordered entries 0..3. -/
def pmpCheck (csrs : PrivCSRs) (mode : PrivMode) (addr : UInt32) (width : UInt32) (acc : AccessType) : Bool :=
  let entries : List (Fin 4) := [⟨0, by decide⟩, ⟨1, by decide⟩, ⟨2, by decide⟩, ⟨3, by decide⟩]
  let rec go : List (Fin 4) → Bool
    | [] => mode == .M  -- Default allow for M-mode; default deny for U-mode
    | idx :: rest =>
      match matchPmpEntry csrs idx addr width with
      | .NoMatch       => go rest
      | .PartialMatch  => false
      | .FullMatch cfg => hasPermission cfg mode acc
  go entries
```

## 6. Trap Entry, Return, and Step Transition Semantics

### Exception Cause Codes and Architectural Trap Transition (`raiseTrap`)

When an instruction in either `U-mode` or `M-mode` triggers a synchronous exception or environment call, `PrivMachine` transitions atomically to the Micro-Monitor entry point configured in `mtvec`.

| Exception Event | `mcause` Code | Triggering Condition in `PrivMachine.step` | `mepc` Value Latched |
| :--- | :--- | :--- | :--- |
| **Instruction Access Fault** | `1` (`0x00000001`) | `pmpCheck s.csrs s.mode s.core.pc 4 .Fetch == false` | Faulting fetch `s.core.pc` |
| **Illegal Instruction** | `2` (`0x00000002`) | Decoding fails, or a privileged instruction (`mret`, `Zicsr`) is executed when `s.mode == .U`, or an M-mode `Zicsr` access to a CSR the model does not have, or a write to a read-only CSR (address bits `[11:10] = 11`) — `csrIllegal` in `Priv.lean` | Faulting instruction `s.core.pc` |
| **Load Address Misaligned** | `4` (`0x00000004`) | `lh`/`lhu`/`lw` with `addr % width ≠ 0` (the RISC-V cause for a misaligned access; Tier 1 faults it too; checked before PMP) | Faulting load `s.core.pc` |
| **Load Access Fault** | `5` (`0x00000005`) | `lb`/`lh`/`lw`/`lbu`/`lhu` target `[addr, addr + width)` fails `pmpCheck ... .Load` | Faulting load `s.core.pc` |
| **Store Address Misaligned** | `6` (`0x00000006`) | `sh`/`sw` with `addr % width ≠ 0` (checked before PMP) | Faulting store `s.core.pc` |
| **Store/AMO Access Fault** | `7` (`0x00000007`) | `sb`/`sh`/`sw` target `[addr, addr + width)` fails `pmpCheck ... .Store` | Faulting store `s.core.pc` |
| **Environment Call from U-mode** | `8` (`0x00000008`) | `ecall` executed when `s.mode == .U` | `ecall` instruction `s.core.pc` |
| **Environment Call from M-mode** | `11` (`0x0000000B`) | `ecall` executed when `s.mode == .M` | `ecall` instruction `s.core.pc` |

```lean
/-- Exception cause constants modeled in Phase 1. -/
def CAUSE_FETCH_ACCESS_FAULT : UInt32 := 1
def CAUSE_ILLEGAL_INSTR      : UInt32 := 2
def CAUSE_LOAD_MISALIGNED    : UInt32 := 4
def CAUSE_LOAD_ACCESS_FAULT  : UInt32 := 5
def CAUSE_STORE_MISALIGNED   : UInt32 := 6
def CAUSE_STORE_ACCESS_FAULT : UInt32 := 7
def CAUSE_ECALL_UMODE        : UInt32 := 8
def CAUSE_ECALL_MMODE        : UInt32 := 11

/-- Update performance counters for one retired instruction if not inhibited. -/
def bumpCounters (csrs : PrivCSRs) : PrivCSRs :=
  { csrs with
    mcycle   := if csrs.mcountinhibit.cy then csrs.mcycle   else csrs.mcycle + 1
    minstret := if csrs.mcountinhibit.ir then csrs.minstret else csrs.minstret + 1 }

/-- Synchronous trap transition into M-mode (Direct mode mtvec). -/
def raiseTrap (s : PrivMachine) (cause : UInt32) : PrivMachine :=
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
    core := { s.core with pc := s.csrs.mtvec &&& (~~~0x3 : UInt32) } }
```

### `mret` and `Zicsr` Execution Rules

1. **Privilege Check**: Executing `mret` (`0x30200073`) or any `Zicsr` instruction (`csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci`) when `s.mode == .U` immediately invokes `raiseTrap s CAUSE_ILLEGAL_INSTR` without modifying any CSR or general-purpose register.
2. **`mret` State Restoration**: When `s.mode == .M`, executing `mret` restores the privilege mode and program counter:
   * `s'.mode ← s.csrs.mstatus.mpp`
   * `s'.core.pc ← s.csrs.mepc`
   * `s'.csrs.mstatus.mie ← s.csrs.mstatus.mpie`
   * `s'.csrs.mstatus.mpie ← true`
   * `s'.csrs.mstatus.mpp ← .U` (lowest supported privilege mode on Hazard3)
3. **Atomic Read-Modify-Write `Zicsr` Semantics**:
   * `CSRRW` / `CSRRWI`: Reads the old CSR value via `readCSR` (writing it to `rd` if `rd != 0`), and writes the new value (`rs1` or 5-bit zero-extended immediate `uimm`) via `writeCSR`.
   * `CSRRS` / `CSRRSI`: Reads the old CSR value into `rd`; if `rs1 != 0` (or `uimm != 0`), writes `old ||| mask` via `writeCSR`.
   * `CSRRC` / `CSRRCI`: Reads the old CSR value into `rd`; if `rs1 != 0` (or `uimm != 0`), writes `old &&& ~~~mask` via `writeCSR`.
   * **Special Case for `mcountinhibit`**: When a `Zicsr` instruction updates `mcountinhibit` (such as `csrwi mcountinhibit, 5` at trap entry), the new `mcountinhibit` state takes effect deterministically so that subsequent monitor instructions do not increment `minstret` or `mcycle`.

```lean
/-- Execute mret in M-mode; trap with Illegal Instruction if called from U-mode. -/
def execMret (s : PrivMachine) : PrivMachine :=
  if s.mode != .M then
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
```

### Unified Single-Step Function (`PrivMachine.step`) and Multi-Step Runner (`PrivMachine.run`)

`PrivMachine.step` integrates instruction fetch verification, privileged instruction handling, memory protection checks, and Tier 1 unprivileged execution in four sequential stages:

1. **Stage 1 (Fetch PMP Verification)**: Check `pmpCheck s.csrs s.mode s.core.pc 4 .Fetch`. If `false`, return `raiseTrap s CAUSE_FETCH_ACCESS_FAULT`.
2. **Stage 2 (Fetch and Decode)**: Fetch the 32-bit instruction word at `s.core.pc` from `s.core.mem`.
3. **Stage 3 (Privileged vs. Unprivileged Dispatch)**:
   * If the instruction is `ecall`: return `raiseTrap s (if s.mode == .U then CAUSE_ECALL_UMODE else CAUSE_ECALL_MMODE)`.
   * If the instruction is `mret`: return `execMret s`.
   * If the instruction is in the `Zicsr` encoding space (`opcode == 0b1110011` and `funct3 ∈ {1, 2, 3, 5, 6, 7}`): if `s.mode != .M` or `csrIllegal w`, return `raiseTrap s CAUSE_ILLEGAL_INSTR`; otherwise execute the atomic CSR read-modify-write, update `rd`, advance `pc ← pc + 4`, and update counters.
4. **Stage 4 (Tier 1 Unprivileged `RV32IM` Delegation with Load/Store PMP Gate)**:
   * If the decoded instruction is a memory load (`lb`, `lh`, `lw`, `lbu`, `lhu`), compute the effective address `addr` and transfer size `width ∈ {1, 2, 4}`. If `addr % width ≠ 0`, return `raiseTrap s CAUSE_LOAD_MISALIGNED`; else if `pmpCheck s.csrs s.mode addr width .Load == false`, return `raiseTrap s CAUSE_LOAD_ACCESS_FAULT`.
   * If the decoded instruction is a memory store (`sb`, `sh`, `sw`), compute `addr` and `width ∈ {1, 2, 4}`. If `addr % width ≠ 0`, return `raiseTrap s CAUSE_STORE_MISALIGNED`; else if `pmpCheck s.csrs s.mode addr width .Store == false`, return `raiseTrap s CAUSE_STORE_ACCESS_FAULT`.
   * Otherwise, step `s.core` using the existing Tier 1 `Rv32.step` transition and apply `bumpCounters s.csrs`.

```lean
/-- Multi-step execution fuel loop for PrivMachine. -/
def PrivMachine.run (fuel : Nat) (s : PrivMachine) : PrivMachine :=
  match fuel with
  | 0 => s
  | fuel' + 1 =>
    if s.core.halted then
      s
    else
      PrivMachine.run fuel' (PrivMachine.step s)
```

## 7. Readiness for Phase 2 Refinement and Phase 3 Micro-Monitor Proofs

### Sandbox Predicate (`UBoxed`) for the Phase 2 Bridge Theorem

To make Phase 2 (`lean/Rv32/Refinement.lean`) seamless, `lean/Rv32/Priv.lean` exports the structural invariant `UBoxed` characterizing when `PrivMachine` is executing an isolated `U-mode` workload inside a NAPOT region `[lo, hi)`:

```lean
/-- Predicate asserting that PrivMachine is in U-mode with PMP entry 0 configured
    as an active NAPOT sandbox covering [lo, hi) with R/W/X permissions. -/
def UBoxed (s : PrivMachine) (lo hi : UInt64) : Prop :=
  s.mode = .U ∧
  let cfg0 := decodePmpCfgByte s.csrs.pmpcfg0 ⟨0, by decide⟩
  cfg0.mode = .NAPOT ∧
  cfg0.r = true ∧ cfg0.w = true ∧ cfg0.x = true ∧
  decodeNapotRange s.csrs.pmpaddr0 = (lo, hi)
```

Under `UBoxed s lo hi`, Phase 2 proves two foundational bridge theorems:

1. **In-Bounds Unprivileged Equivalence**: For any unprivileged `RV32IM` instruction (excluding `ecall`) whose fetch address `[s.core.pc, s.core.pc + 4)` and any load/store address `[addr, addr + width)` lie within `[lo, hi)`, `(PrivMachine.step s).core = Rv32.step env s.core`.
2. **Out-of-Bounds Trap Guarantee**: For any instruction when `s.mode = .U` whose fetch, load, or store touches any byte outside the active PMP entries, `PrivMachine.step s` leaves `s.core.mem` and `s.core.regs` unmodified and transitions to `s'.mode = .M` with `s'.core.pc = s.csrs.mtvec &&& ~~~0x3` and `s'.csrs.mcause ∈ {1, 5, 7}`.

### Phase 1 Acceptance Criteria and Verification Checklist

Before advancing from Phase 1 (`lean/Rv32/Priv.lean`) to Phase 2 (`lean/Rv32/Refinement.lean`), the implementation must satisfy the following verification criteria:

* **Zero Modification to Tier 1**: `git diff lean/Rv32/Machine.lean` is completely empty; all existing proofs (`exp208`, `exp228`, `exp229`) compile without changes.
* **Compact TCB Budget**: `lean/Rv32/Priv.lean` remains under 300 lines of Lean 4 code with zero `sorry` axioms.
* **Decidable Execution**: `PrivMachine.step` and `pmpCheck` evaluate concretely via `#eval` and `decide` without triggering kernel timeouts.
* **Unit Validation Theorems in `Priv.lean`**:
  * `theorem pmp_readback_napot_low_bits`: Proves that reading `pmpaddr0` in `NAPOT` mode always returns bits `[1:0] == 0b11` (`exp209` quirk).
  * `theorem umode_default_deny`: Proves that when all 4 PMP entries are `OFF`, `pmpCheck csrs .U addr width acc = false` for all `addr`, `width`, and `acc`.
  * `theorem umode_zicsr_traps`: Proves that executing any `Zicsr` or `mret` instruction with `s.mode = .U` transitions to `s'.mode = .M` with `s'.csrs.mcause = 2` and leaves all CSRs (other than `mstatus`, `mepc`, `mcause`, and counters) and general-purpose registers unchanged.

## 8. Model Scope and Assumptions (as implemented in `lean/Rv32/Priv.lean`)

A theorem about `PrivMachine` is a theorem about the model. These are the places where the
model and the chip are known to differ, or where the model's behaviour comes from the RISC-V
rule rather than from a measurement. They are also listed in the header of `Priv.lean`.

| Topic | What the model does | What the chip does | What it means for a proof |
| :--- | :--- | :--- | :--- |
| **`mcounteren`** | No such CSR. Every U-mode `Zicsr` traps (`umode_zicsr_traps`). | A RISC-V core with U-mode may let M-mode open `cycle`/`instret` to U-mode through `mcounteren`. Whether and how Hazard3 does so was not checked in this repository. | "U-mode `Zicsr` always traps" holds on the chip only while `mcounteren` is 0. The Micro-Monitor never writes it, so it keeps its reset value; that is an assumption to confirm against the Hazard3 documentation, not a theorem. |
| **C extension** | Fetch is 4 bytes at a 4-aligned `pc`; Tier 1 is `RV32IM`. | Not checked in this repository. The RISC-V C extension, if the image uses it, makes `pc` 2-aligned and instructions 2 or 4 bytes. | Holds for code built without C (`-march=rv32im`). Nothing in the repository checks the build flags of a given image. |
| **CSR access checks** | `csrImplemented` lists 15 CSRs; any other number traps. A write to a CSR whose address bits `[11:10]` are `11` traps (`priv_zicsr_unimplemented_traps`, `priv_zicsr_readonly_write_traps`). `csrrs`/`csrrc` with `rs1 = x0` and `csrrsi`/`csrrci` with a zero immediate only read. | Not measured. A core normally has more CSRs than this list (`misa`, `mhartid`, ...) and does not trap on reading them. | Stricter than the chip: code that reads `mhartid` is illegal in the model and fine on the chip. The monitor reads none of them. |
| **Counter writes** | A `Zicsr` write to `mcycle` (`0xB00`) or `minstret` (`0xB02`) lands and is not overwritten by that instruction's own increment. | The RISC-V rule says the same; not measured on the chip. | No theorem states it; it is code only. |
| **Trap and `minstret`** | A trapping instruction is counted (`raiseTrap` calls `bumpCounters`). | exp203 measured `ecall` and an illegal instruction counted on Hazard3. | Matches exp203, with one exception below. |
| **Frontend effect** | None: one step, one count. | exp203: the same four instructions were counted 5 or 4 times depending on what the frontend had fetched behind an `mret`. | A model count and a chip count can differ by a constant that belongs to the shell code; Phase 3's constants must be measured, not derived. |
| **Misaligned access** | Traps with cause 4 (load) or 6 (store), before the PMP check. | Not measured here. The RISC-V rule gives 4 and 6; Tier 1 faults the same accesses (`loadMisaligned`, `storeMisaligned`). | The cause codes are written down; no theorem proves them. |

