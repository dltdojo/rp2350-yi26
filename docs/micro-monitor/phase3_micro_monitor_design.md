# Phase 3 Design Document: Verified RISC-V M-Mode Micro-Monitor Machine Code and Proofs (`monitor.bin` & `proof/Monitor.lean`)

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **Document Date**: 2026-10-15
* **Target Deliverables**: `monitor.bin` (assembled from `monitor.S` / embedded word array) and `proof/Monitor.lean`
* **Hardware Dependency**: Needs 0 (Pure `RV32I + Zicsr` machine code verification in Lean 4; no board or RTL required)
* **Upstream Prerequisites**: `lean/Rv32/Priv.lean` ([Phase 1 Design Document](./phase1_priv_machine_design.md)) and `lean/Rv32/Refinement.lean` ([Phase 2 Design Document](./phase2_refinement_design.md))
* **Parent Architecture Plan**: [RISC-V M-Mode Privileged Micro-Model and Verified Micro-Monitor Design Plan](./2026-10-14-0925-micro-monitor-in-lean4-design-zh-tw.md)

## 1. Executive Summary and Phase 3 Objective

### Replacing the Unverified C/Assembly Harness with a 120-Instruction Verified Micro-Monitor

In the legacy repository architecture, an unverified C and assembly harness (`shell.c` and `harness.S`) runs in Machine mode (`M-mode`) with unrestricted access to all physical SRAM, CSRs, and peripherals. Phase 3 eliminates this unverified `M-mode` shell entirely, replacing it with **`monitor.bin`**—a compact (~120 instructions, < 512 bytes) `RV32I + Zicsr` machine-code monitor—and **`proof/Monitor.lean`**, which formally proves its correctness, memory isolation, secret zeroization, and exact instruction counts against the Tier 2 `PrivMachine` semantics defined in Phase 1 and the `MonitorImplementsEnv` refinement interface defined in Phase 2.

| Security Dimension | Legacy `M-Mode` Harness (`shell.c` + `harness.S`) | Phase 3 Verified Micro-Monitor (`monitor.bin` + `proof/Monitor.lean`) |
| :--- | :--- | :--- |
| **`M-Mode` Code Footprint** | Thousands of lines of unverified C, compiler runtime, and assembly | **~120 instructions** (`RV32I + Zicsr` + `mret`), 100% formally verified in Lean 4 |
| **Domain Isolation** | Single sandbox; `M-mode` C code shares address space with I/O logic | Enforces hard `NAPOT` PMP boundaries between **Domain 1 (Cryptographic Core)** and **Domain 2 (Untrusted USB/Display Stack)** |
| **Secret Scrubbing on Exit** | Ad-hoc or absent; GP registers and scratch SRAM remain readable after return | **Formally proved zeroization** of `x1..x31` (except `a0`) and confidential scratch SRAM before any domain switch or halt |
| **Syscall Pointer Validation** | Unchecked pointers passed from `U-mode` to `M-mode` helpers | **Formally proved Confused-Deputy check** verifying `[ptr, ptr + len) ⊆ [lo, hi)` before any `M-mode` memory read or write |
| **Cycle/Instruction Accounting** | Empirical shell compensation constants (`+3` in `exp203`, `+4` in `exp228`) | **Formally proved constant instruction counts** gated by `csrwi mcountinhibit, 5` on trap entry and `csrwi mcountinhibit, 0` before `mret` |

## 2. Physical Memory Layout and PMP Domain Partitioning

### RP2350 SRAM Partitioning Across `M-Mode`, Domain 1, and Domain 2

The RP2350 provides 520 KB of on-chip SRAM starting at `0x20000000`. To isolate the Micro-Monitor, the secret-holding Cryptographic Enclave (Domain 1), and the untrusted USB/Display/Protocol stack (Domain 2) using only `pmpcfg0` (controlling PMP entries `0..3` with Hazard3's 32-byte `NAPOT` granularity), Phase 3 partitions physical memory into naturally aligned power-of-two `NAPOT` windows:

| Memory Region | Physical Address Range `[lo, hi)` | Size | Active Mode / Owner | PMP Configuration during `U-Mode` Execution |
| :--- | :--- | :--- | :--- | :--- |
| **Monitor Code & Trap Vector (`mtvec`)** | `0x20000000 .. 0x20000400` | 1 KB | `M-mode` Micro-Monitor (`monitor.bin`) | **Unmapped in PMP (`OFF`)**: Default-deny makes `M-mode` code completely invisible (`!R, !W, !X`) to all `U-mode` domains |
| **Monitor Frame & Report Block (`mscratch`)** | `0x20000400 .. 0x20000800` | 1 KB | `M-mode` Context & Syscall State | **Unmapped in PMP (`OFF`)**: Accessed exclusively by `M-mode` via `csrrw sp, mscratch, sp`; inaccessible to `U-mode` |
| **Domain 1: Cryptographic Enclave** | `0x20008000 .. 0x20010000` | 32 KB | `U-mode` Verified Kernels (`exp229`, `exp228`, `exp208`) | **PMP Entry 0 (`NAPOT`, `R/W/X`)** when Domain 1 is active (`pmpaddr0 = 0x08002FFF`, `pmpcfg0 = 0x0000001F`); **Zeroized & `OFF`** when Domain 2 runs |
| **Domain 2: Untrusted I/O & USB Stack** | `0x20010000 .. 0x20020000` | 64 KB | `U-mode` USB / Display / Protocol Driver | **PMP Entry 0 (`NAPOT`, `R/W/X`)** when Domain 2 is active (`pmpaddr0 = 0x08005FFF`, `pmpcfg0 = 0x0000001F`); cannot touch Domain 1 or Monitor |

### NAPOT Encoding Constants for `pmpaddr0` and `pmpcfg0`

In RISC-V `NAPOT` encoding, a region with base $B$ and power-of-two size $S = 2^k$ ($k \ge 5$) is encoded as:

$$\text{pmpaddr} = \left(\frac{B}{4}\right) \;\middle|\; \left(\frac{S}{8} - 1\right)$$

* **Domain 1 (`[0x20008000, 0x20010000)`, $S = 32\text{ KB} = 2^{15}$)**:
  * $B / 4 = \text{0x08002000}$, $S / 8 - 1 = \text{0x00000FFF}$
  * `DOMAIN1_PMPADDR0 = 0x08002FFF`
* **Domain 2 (`[0x20010000, 0x20020000)`, $S = 64\text{ KB} = 2^{16}$)**:
  * $B / 4 = \text{0x08004000}$, $S / 8 - 1 = \text{0x00001FFF}$
  * `DOMAIN2_PMPADDR0 = 0x08005FFF`
* **Active `U-Mode` Sandbox Configuration (`pmpcfg0`)**:
  * Entry 0 unlocked (`L = 0`), `NAPOT` (`A = 0b11`), `X = 1`, `W = 1`, `R = 1` $\implies \text{byte } 0 = \text{0x1F}$; Entries 1–3 disabled (`OFF = 0x00`) $\implies$ `ACTIVE_PMPCFG0 = 0x0000001F`.

## 3. Micro-Monitor Machine Code Architecture (`monitor.bin`)

### Instruction Budget and Control-Flow Decomposition (~120 Instructions)

The Micro-Monitor binary (`monitor.bin`) is assembled at base address `0x20000000` with `mtvec = 0x20000040` (Direct mode, 64-byte offset from monitor base). Every execution path is loop-free (or bounded by fixed compile-time unrolling for scratch zeroization) so symbolic execution in Lean 4 terminates deterministically in a fixed number of steps.

| Code Block | Offset Range | Instruction Count | Responsibilities and Key Instructions |
| :--- | :--- | :--- | :--- |
| **`boot_and_launch`** | `0x000 .. 0x03C` | 16 insts | Initializes `mcountinhibit = 5`, `mtvec = 0x20000040`, `mscratch = 0x20000400`, configures `pmpaddr0` and `pmpcfg0 = 0x1F` for Domain 1, sets `mstatus.MPP = .U`, `mepc = entry_pc`, clears `mcountinhibit = 0`, and executes `mret` |
| **`trap_entry`** | `0x040 .. 0x064` | 10 insts | First instruction at `mtvec`: `csrwi mcountinhibit, 5`; swaps `sp` (`x2`) with `mscratch` via `csrrw sp, mscratch, sp`; saves `t0..t2` and `a0..a3` into the `M-mode` context frame; reads `mcause` |
| **`trap_dispatch`** | `0x068 .. 0x08C` | 10 insts | Checks if `mcause == 8` (`CAUSE_ECALL_UMODE`). If not `8` (access fault `1, 5, 7` or illegal instruction `2`), branches directly to `fault_abort_and_zeroize`; otherwise dispatches on `t0` (`1` = `HALT`, `0/2` = `HASH`, `3` = `CHECKSIG`) |
| **`pmp_bounds_check`** | `0x090 .. 0x0C8` | 15 insts | Confused-Deputy guard for `HASH` and `CHECKSIG`: loads active domain `[lo, hi)` from monitor frame, checks `lo <= ptr`, `len <= hi - lo`, and `ptr <= hi - len` (unsigned `bltu` without 32-bit wraparound); branches to `fault_abort_and_zeroize` on violation |
| **`syscall_hash_checksig`** | `0x0CC .. 0x11C` | 20 insts | Invokes the verified SHA-256 / signature-check routine on validated in-bounds buffers, writes result to `U-mode` buffer / `a0`, advances `mepc ← mepc + 4`, and jumps to `trap_return` |
| **`halt_and_zeroize`** | `0x120 .. 0x1B0` | 37 insts | Latches `a0` exit status and final `minstret`/`mcycle` into the monitor report block (`0x20000400`), overwrites confidential scratch words with `sw x0, offset(t0)`, executes `li x1, 0` .. `li x31, 0` (preserving only `a0`), and halts / transitions domain |
| **`trap_return`** | `0x1B4 .. 0x1DC` | 11 insts | Restores caller registers from `M-mode` frame, swaps `sp` back via `csrrw sp, mscratch, sp`, executes `csrwi mcountinhibit, 0`, and executes `mret` |

### Critical Assembly Sequences and Silicon Quirk Defenses

#### 1. Trap Entry Counter Freeze (`exp203` & `exp228` Quirk Defense)
To prevent microarchitectural trap jitter and ensure that `minstret` reflects only `U-mode` execution plus a fixed, formally proved constant, `trap_entry` at `0x20000040` freezes counters on its first instruction and restores them immediately before `mret`:

```lean
-- Assembly sequence at mtvec (0x20000040):
-- 0x20000040: csrwi mcountinhibit, 5   (0x3202D073) -- Freeze CY (bit 0) and IR (bit 2)
-- 0x20000044: csrrw sp, mscratch, sp   (0x34011173) -- Switch to M-mode monitor stack
-- 0x20000048: sw    t0, 0(sp)          (0x00512023) -- Save U-mode t0 without clobbering
-- 0x2000004C: csrr  t0, mcause         (0x342022F3) -- Read trap cause

-- Assembly sequence at trap_return (0x200001D0):
-- 0x200001D0: lw    t0, 0(sp)          (0x00012283) -- Restore U-mode t0
-- 0x200001D4: csrrw sp, mscratch, sp   (0x34011173) -- Restore U-mode sp
-- 0x200001D8: csrwi mcountinhibit, 0   (0x32005073) -- Unfreeze CY and IR
-- 0x200001DC: mret                     (0x30200073) -- Return to U-mode at mepc
```

#### 2. Write-Only PMP Configuration Sequence (`exp209` Quirk Defense)
Per the `exp209` silicon observation modeled in Phase 1, reading `pmpaddr0` in `OFF` mode masks bits `[2:0]` to `0b000`, while reading it in `NAPOT` mode forces bits `[1:0]` to `0b11`. Accordingly, `boot_and_launch` configures PMP via a deterministic write-only sequence and never executes a readback comparison:

```lean
-- Configure Domain 1 [0x20008000, 0x20010000) in PMP Entry 0:
-- lui   t0, 0x08003          -- t0 = 0x08003000
-- addi  t0, t0, -1           -- t0 = 0x08002FFF (NAPOT encoding for [0x20008000, 0x20010000))
-- csrw  pmpaddr0, t0         -- Write pmpaddr0 (0x3B0)
-- li    t1, 0x1F             -- L=0, A=NAPOT(3), X=1, W=1, R=1; entries 1..3 = OFF
-- csrw  pmpcfg0, t1          -- Activate PMP Entry 0
```

#### 3. Overflow-Safe Confused-Deputy Pointer Check (`pmp_bounds_check`)
When a `U-mode` program invokes `ecall` with `t0 = 0/2` (`HASH`, passing `ptr` in `a0` and `len` in `a1`) or `t0 = 3` (`CHECKSIG`), a naive check `lo <= ptr && ptr + len <= hi` is vulnerable to 32-bit unsigned integer wraparound when `ptr + len >= 2^32`. The Micro-Monitor uses a wraparound-free 6-instruction check:

```lean
-- Inputs: a0 = ptr, a1 = len, t1 = domain_lo, t2 = domain_hi (where domain_lo < domain_hi)
-- 1. Check ptr >= domain_lo:
--    bltu  a0, t1, fault_abort_and_zeroize
-- 2. Compute remaining bytes in sandbox: t3 = domain_hi - a0 (guaranteed > 0 if a0 < domain_hi):
--    bltu  t2, a0, fault_abort_and_zeroize
--    sub   t3, t2, a0
-- 3. Check len <= domain_hi - a0 (cannot overflow 32-bit arithmetic):
--    bltu  t3, a1, fault_abort_and_zeroize
```

## 4. Formal Specification and Theorems in `proof/Monitor.lean`

`proof/Monitor.lean` embeds the concrete 32-bit machine words of `monitor.bin` into Lean 4 and proves the **Four Core Security Theorems** required by the master architecture plan, culminating in the instantiation of `MonitorImplementsEnv` from Phase 2 (`lean/Rv32/Refinement.lean`).

### Monitor Binary Embedding and Initial State Predicate (`MonitorLoaded`)

```lean
import Rv32.Priv
import Rv32.Refinement

namespace Rv32.MonitorProof

open Rv32
open Rv32.Priv
open Rv32.Refinement

/-- Base address of M-mode Micro-Monitor code in RP2350 SRAM. -/
def MONITOR_BASE   : UInt32 := 0x20000000
/-- Direct-mode trap vector entry address (mtvec). -/
def MONITOR_MTVEC  : UInt32 := 0x20000040
/-- M-mode monitor context/report block base address (mscratch). -/
def MONITOR_FRAME  : UInt32 := 0x20000400

/-- Domain 1 (Cryptographic Enclave) physical bounds [0x20008000, 0x20010000). -/
def DOM1_LO : UInt64 := 0x20008000
def DOM1_HI : UInt64 := 0x20010000

/-- Concrete machine-code array for monitor.bin (~120 32-bit words). -/
def monitorCode : Array UInt32 := #[
  -- 0x000: boot_and_launch
  0x3202D073, -- csrwi mcountinhibit, 5
  -- ... (complete assembled machine words of monitor.S)
  0x30200073  -- mret
]

/-- Predicate asserting that monitor.bin is loaded at MONITOR_BASE in s.core.mem
    and mtvec / mscratch point to MONITOR_MTVEC and MONITOR_FRAME. -/
def MonitorLoaded (s : PrivMachine) : Prop :=
  s.csrs.mtvec = MONITOR_MTVEC ∧
  (∀ (i : Nat) (h : i < monitorCode.size),
    fetchWord s.core.mem (MONITOR_BASE + (i * 4).toUInt32) = monitorCode[i]'h)
```

### Theorem 1: Domain Isolation Guarantee (`monitor_isolation_thm`)

Proves that executing the `boot_and_launch` sequence (`K_LAUNCH = 16` steps) from `M-mode` reset places `PrivMachine` into `U-mode` at the target domain entry PC while establishing the `UBoxed` invariant (`pmpcfg0 = 0x1F`, `decodeNapotRange pmpaddr0 = (DOM1_LO, DOM1_HI)`). Combined with `step_fault_containment` from Phase 2, this guarantees that `U-mode` cannot read or write any address outside `[DOM1_LO, DOM1_HI)`.

```lean
/-- Isolation Theorem:
    Running the Micro-Monitor launch sequence for K_LAUNCH (16) steps from M-mode
    initializes PMP Entry 0 to [DOM1_LO, DOM1_HI) in NAPOT mode, unfreezes counters,
    and enters U-mode via mret satisfying the Phase 2 UBoxed invariant. -/
theorem monitor_isolation_thm
    (s : PrivMachine) (entryPc : UInt32)
    (hMode   : s.mode = .M)
    (hPc     : s.core.pc = MONITOR_BASE)
    (hLoaded : MonitorLoaded s)
    (hEntry  : DOM1_LO ≤ entryPc.toUInt64 ∧ entryPc.toUInt64 + 4 ≤ DOM1_HI) :
    let s' := PrivMachine.run 16 s
    UBoxed s' DOM1_LO DOM1_HI ∧
    s'.core.pc = entryPc ∧
    s'.csrs.mcountinhibit = { cy := false, ir := false }
```

### Theorem 2: Context Switch and Halt Zeroization (`monitor_zeroization_thm`)

Proves that whenever a `U-mode` domain executes a halting `ecall` (`t0 = 1`) or triggers an access/instruction fault (`mcause ∈ {1, 2, 5, 7}`), the Micro-Monitor completes in `K_HALT` steps, preserves the exit code in `a0` (or sets an error code on fault), and wipes all other writable general-purpose registers `x1..x31` (`r ≠ .a0`) alongside the designated secret scratch SRAM buffer:

```lean
/-- Zeroization Theorem:
    Upon a halting ecall (t0 = 1) from U-mode, the trap entry + halt_and_zeroize
    path completes in K_HALT (48) steps, preserving the exit status in `a0` while
    zeroizing every other general-purpose register x1..x31 and the secret scratch range. -/
theorem monitor_zeroization_thm
    (s : PrivMachine)
    (hBox    : UBoxed s DOM1_LO DOM1_HI)
    (hLoaded : MonitorLoaded s)
    (hEcall  : fetchWord s.core.mem s.core.pc = 0x00000073)
    (hHalt   : s.core.regs.read .t0 = 1) :
    let s' := PrivMachine.run 48 s
    s'.mode = .M ∧
    s'.core.regs.read .a0 = s.core.regs.read .a0 ∧
    (∀ (r : Reg), r ≠ .a0 → s'.core.regs.read r = 0) ∧
    (∀ (addr : UInt32), SECRET_SCRATCH_LO ≤ addr ∧ addr < SECRET_SCRATCH_HI →
      s'.core.mem.readByte addr = 0)
```

### Theorem 3: Syscall ABI Forwarding and Confused-Deputy Prevention (`monitor_syscall_forwarding_thm`)

Proves both sides of syscall security:
1. **Valid In-Bounds Syscall (`t0 ∈ {0, 2, 3}` with `[ptr, ptr + len) ⊆ [lo, hi)`)**: The monitor validates the pointer range, executes the requested operation, sets `mepc ← mepc + 4`, restores `U-mode` registers, and executes `mret` so that `s'.core = Rv32.step env s.core` and `UBoxed s' lo hi` holds.
2. **Confused-Deputy Rejection (`[ptr, ptr + len) ⊈ [lo, hi)`)**: If a compromised `U-mode` task passes a pointer or length that straddles or escapes `[lo, hi)` (e.g., pointing into `MONITOR_BASE`, `MONITOR_FRAME`, or another domain's SRAM), `pmp_bounds_check` deterministically rejects the request and branches to `fault_abort_and_zeroize` before performing any memory read or write.

```lean
/-- Syscall Forwarding Theorem (Valid In-Bounds Call):
    For any in-bounds non-halting ecall (t0 ∈ {0, 2, 3}), the Micro-Monitor completes
    in K_SYS steps, returning to U-mode at mepc + 4 with s'.core = Rv32.step env s.core
    and UBoxed preserved. -/
theorem monitor_syscall_forwarding_thm
    (env : Rv32.Env) (s : PrivMachine)
    (hBox    : UBoxed s DOM1_LO DOM1_HI)
    (hLoaded : MonitorLoaded s)
    (hValid  : isInBoundsNonHaltingEcall s DOM1_LO DOM1_HI) :
    let s' := PrivMachine.run K_SYS s
    s'.core = Rv32.step env s.core ∧
    UBoxed s' DOM1_LO DOM1_HI ∧
    MonitorLoaded s'

/-- Confused-Deputy Prevention Theorem (Out-of-Bounds Syscall Pointer):
    If a U-mode ecall passes a buffer [ptr, ptr + len) not fully contained in [DOM1_LO, DOM1_HI),
    the Micro-Monitor aborts without modifying any memory outside MONITOR_FRAME. -/
theorem monitor_confused_deputy_reject_thm
    (s : PrivMachine)
    (hBox    : UBoxed s DOM1_LO DOM1_HI)
    (hLoaded : MonitorLoaded s)
    (hOob    : isOutOfBoundsSyscallPtr s DOM1_LO DOM1_HI) :
    let s' := PrivMachine.run K_FAULT s
    s'.mode = .M ∧
    (∀ (addr : UInt32), ¬(MONITOR_FRAME ≤ addr ∧ addr < MONITOR_FRAME + 0x400) →
      s'.core.mem.readByte addr = s.core.mem.readByte addr)
```

### Theorem 4: Exact Constant Instruction-Count Theorem (`monitor_instruction_count_thm`)

Because `PrivMachine.step` increments `minstret` on the `ecall` trap transition (`raiseTrap` runs while `mcountinhibit.ir = false`), freezes `minstret` on the first instruction at `mtvec` (`csrwi mcountinhibit, 5`), and unfreezes `minstret` on the instruction immediately before `mret` (`csrwi mcountinhibit, 0`), the net `minstret` delta across an entire trap-and-return cycle is proved as an exact architectural constant:

* **`ecall` instruction in `U-mode`**: `+1` (`mcountinhibit.ir = false`)
* **`csrwi mcountinhibit, 5` at `mtvec`**: `+0` (takes effect immediately in `execZicsr` before `bumpCounters`)
* **All intermediate Micro-Monitor instructions**: `+0` (`mcountinhibit.ir = true`)
* **`csrwi mcountinhibit, 0` before `mret`**: `+1` (`mcountinhibit.ir` becomes `false` before `bumpCounters`)
* **`mret` instruction**: `+1` (`mcountinhibit.ir = false`)

```lean
/-- Exact Instruction-Count Theorem:
    Across a complete U-mode ecall trap and M-mode Micro-Monitor return cycle,
    `csrs.minstret` advances by the exact constant `3` (1 for ecall + 1 for
    unfreezing mcountinhibit + 1 for mret), independent of the monitor's internal
    instruction count K_SYS. -/
theorem monitor_instruction_count_thm
    (env : Rv32.Env) (s : PrivMachine)
    (hBox    : UBoxed s DOM1_LO DOM1_HI)
    (hLoaded : MonitorLoaded s)
    (hNoInh  : s.csrs.mcountinhibit.ir = false)
    (hValid  : isInBoundsNonHaltingEcall s DOM1_LO DOM1_HI) :
    let s' := PrivMachine.run K_SYS s
    s'.csrs.minstret = s.csrs.minstret + 3 ∧
    s'.csrs.mcountinhibit.ir = false
```

### Discharging `MonitorImplementsEnv` to Complete End-to-End Verification

Finally, `proof/Monitor.lean` combines `monitor_syscall_forwarding_thm` and `monitor_zeroization_thm` to construct a term of type `MonitorImplementsEnv env DOM1_LO DOM1_HI s`, plugging directly into `run_complete_refines` from Phase 2 (`lean/Rv32/Refinement.lean`):

```lean
/-- Master Phase 3 Instantiation:
    Whenever monitor.bin is loaded in M-mode memory, PrivMachine satisfies the
    Phase 2 MonitorImplementsEnv contract for Domain 1. -/
theorem monitor_implements_env
    (env : Rv32.Env) (s : PrivMachine)
    (hBox    : UBoxed s DOM1_LO DOM1_HI)
    (hLoaded : MonitorLoaded s) :
    MonitorImplementsEnv env DOM1_LO DOM1_HI s :=
  { syscall_resume := fun hValid =>
      ⟨K_SYS - 1, monitor_syscall_forwarding_thm env s hBox hLoaded hValid⟩
    syscall_halt   := fun hHalt =>
      ⟨47, monitor_zeroization_thm s hBox hLoaded hHalt.isEcall hHalt.t0EqOne⟩ }
```

## 5. Proof Engineering Strategy for Symbolic Machine-Code Execution

To verify ~120 instructions of `M-mode` machine code in `proof/Monitor.lean` without triggering Lean 4 kernel timeouts, Phase 3 applies block-level compositional symbolic execution:

1. **Basic-Block Step Lemmas (`step_block_boot`, `step_block_entry`, `step_block_bounds`, `step_block_zeroize`, `step_block_return`)**:
   * Rather than executing `PrivMachine.run 48 s` as a single monolithic term, `proof/Monitor.lean` proves a separate lemma for each basic block of 8–16 instructions using `PrivMachine.run_add` from Phase 2 (`PrivMachine.run (m + n) s = PrivMachine.run n (PrivMachine.run m s)`).
2. **Concrete Fetch Simplification (`@[simp] theorem fetch_monitor_word`)**:
   * A precomputed lookup lemma maps every concrete PC offset `MONITOR_BASE + 4 * k` ($0 \le k < 120$) directly to its 32-bit instruction word in $O(1)$ rewrite steps, avoiding symbolic array bounds checks during `PrivMachine.step` unfolding.
3. **Unrolled Store Zeroization**:
   * The register clearing sequence (`li x1, 0` through `li x31, 0`, skipping `x10`/`a0`) and scratch SRAM zeroization are straight-line unrolled sequences in `monitor.bin`, allowing Lean's `simp only [PrivMachine.step, ...]` to discharge the entire 37-instruction `halt_and_zeroize` block in under 2 seconds.

## 6. Phase 3 Acceptance Criteria and Verification Checklist

Before advancing from Phase 3 (`monitor.bin` & `proof/Monitor.lean`) to Phase 4 (Verilator RTL End-to-End Integration Testing), the deliverables must pass the following verification gates:

* **Binary Reproducibility**: `riscv32-unknown-elf-objcopy -O binary monitor.elf monitor.bin` produces a byte-for-byte identical binary to the `monitorCode : Array UInt32` constant verified in `proof/Monitor.lean` (checked via an automated build check or `#eval` hash check).
* **Instruction Count Budget**: `monitor.bin` contains $\le 150$ instructions ($\le 600$ bytes) and uses exclusively `RV32I + Zicsr` and `mret`.
* **Zero `sorry` Declarations**: `lake build MonitorProof` compiles cleanly with zero `sorry` axioms in under 10 seconds.
* **Complete Discharge of the Four Security Properties**:
  * `monitor_isolation_thm` (PMP Entry 0 `NAPOT` lock-in before `mret`, respecting the `exp209` write-only rule).
  * `monitor_zeroization_thm` (Full clearing of `x1..x31` except `a0` and confidential scratch SRAM on halt/switch).
  * `monitor_syscall_forwarding_thm` and `monitor_confused_deputy_reject_thm` (Exact ABI preservation for `t0 ∈ {0, 1, 2, 3}` and overflow-safe rejection of out-of-bounds `U-mode` pointers).
  * `monitor_instruction_count_thm` (Exact constant `minstret` overhead via `csrwi mcountinhibit, 5`, replacing empirical compensation constants).
  * `monitor_implements_env` (Concrete instantiation of Phase 2's `MonitorImplementsEnv` interface).

## 7. What exp236 delivered, against this design

`experiments/exp236-the-wall-the-monitor-holds` is the Phase 3 monitor. Where it differs from the
design above:

| Design | exp236 |
| :--- | :--- |
| ~120 instructions | 143 instructions, 572 bytes (the register zeroing is written out twice: boot and scrub) |
| SRAM at `0x20000000`, two domains | the testbench map: monitor at `0x80000000`, one 64 KiB payload region at `0x80010000`, MMIO words at `0xc0000004/8` |
| the monitor returns to U-mode after a syscall (`trap_return`) | it does not: HALT or a fault, then scrub and park. There is no `trap_return` |
| `HASH`, `CHECKSIG` forwarded after a bounds check | not offered. Any `ecall` but HALT is a fault |
| `monitor_isolation_thm`, `monitor_zeroization_thm` over a `zeroizeRegs` helper | stated on `PrivMachine` running the monitor's own words: `monitor_boot`, `monitor_halt`, `monitor_fault_cause`, `monitor_fault_syscall`, `monitor_scrub`, `monitor_end_to_end`, with `umode_step`/`umode_run` in `lean/Rv32/Sandbox.lean` |
| `monitor_instruction_count_thm`: a trap-and-return costs a proved constant | not stated: there is no return. The monitor freezes the counters and parks |
| `monitor_implements_env` | not proved. The sandbox theorems hold for any `env`; the handler theorems assume `env.region = [0x80000000, 0xC0000100)` |
| the fault path reports and exits | it also scrubs: every register but `a0`, `mscratch` and the two saved words are zero when it parks |
| — | payload memory is not scrubbed |

The model limits in section 8 of `phase1_priv_machine_design.md` apply to every theorem.
