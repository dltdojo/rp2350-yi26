// SPDX-License-Identifier: Apache-2.0
//
// exp237 — the SRAM map, shared by the C shell, the monitor and the payloads.
// Plain #defines only (no u suffixes) outside the C-only block, so that
// monitor_chip.S and the payload sources can include it too.
//
// Everything the shell itself uses (code in flash, .bss from 0x20000000, its
// stack growing down from 0x20030000) sits below 0x20040000; the monitor and
// the sandbox are above it, so loading them cannot overwrite the shell.
#pragma once

#define MONITOR_BASE     0x20040000
#define MONITOR_SIZE     0x10000          // 64 KiB window, zeroed before the monitor is copied in
#define MONITOR_LAUNCH   (MONITOR_BASE + 0x20)
#define MONITOR_STACK    (MONITOR_BASE + 0x8000)
#define MONITOR_REPORT   (MONITOR_BASE + 0x400)   // 7 words, written by the trap handler
#define MONITOR_BOOT     (MONITOR_BASE + 0x420)   // pmpcfg0, pmpaddr0 as read back at boot
#define MONITOR_HOST_CTX (MONITOR_BASE + 0x440)   // sp ra gp tp s0..s11 mcountinhibit

#define PAYLOAD_BASE     0x20050000       // 64 KiB, 64 KiB aligned: one NAPOT entry
#define PAYLOAD_SIZE     0x10000
#define PAYLOAD_STACK    (PAYLOAD_BASE + PAYLOAD_SIZE)

#define HOST_STACK       0x20030000

#define TAG_HALT         0x48414c54       // "HALT"
#define TAG_FAULT        0x4641554c       // "FAUL"

// pmpaddr0 for 64 KiB NAPOT at PAYLOAD_BASE: (base >> 2) | ((size >> 3) - 1)
#define DOMAIN_PMPADDR0  ((PAYLOAD_BASE >> 2) | 0x1fff)
#define DOMAIN_PMPCFG0   0x1f             // NAPOT, RWX, unlocked (M-mode is not restricted)

#ifndef __ASSEMBLER__
#include <stdint.h>

struct monitor_report {
    uint32_t tag;        // TAG_HALT or TAG_FAULT
    uint32_t exit_code;  // a0 (1 for a fault)
    uint32_t instret;    // payload minstret
    uint32_t cycle;      // payload mcycle
    uint32_t mcause;
    uint32_t mepc;
    uint32_t mtval;
};
#endif
