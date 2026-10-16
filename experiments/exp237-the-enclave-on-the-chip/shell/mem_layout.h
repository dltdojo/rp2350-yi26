// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>

// RP2350 Physical Memory Layout for exp237 Micro-Monitor & Hardware Enclave
#define MONITOR_BASE     0x20000000u
#define MONITOR_SIZE     0x00010000u  // 64 KiB
#define MONITOR_ENTRY    0x20000040u
#define MONITOR_STACK    0x20008000u
#define MONITOR_REPORT   0x20000400u
#define MONITOR_HOST_SP  0x20000420u
#define MONITOR_HOST_RA  0x20000424u

#define PAYLOAD_BASE     0x20010000u
#define PAYLOAD_SIZE     0x00010000u  // 64 KiB
#define PAYLOAD_STACK    0x20020000u

#define HOST_STACK       0x20030000u

#define TAG_HALT         0x48414c54u  // "HALT"
#define TAG_FAULT        0x4641554cu  // "FAUL"

// PMP Configuration constants for 64 KiB NAPOT at 0x20010000
// (0x20010000 >> 2) | ((0x10000 >> 3) - 1) = 0x08004000 | 0x1fff = 0x08005fff
#define DOMAIN_PMPADDR0  0x08005fffu
#define DOMAIN_PMPCFG0   0x0000001fu  // NAPOT, RWX, unlocked

struct monitor_report {
    uint32_t tag;        // TAG_HALT or TAG_FAULT
    uint32_t exit_code;  // a0
    uint32_t instret;    // payload minstret
    uint32_t cycle;      // payload mcycle
    uint32_t mcause;
    uint32_t mepc;
    uint32_t mtval;
};
