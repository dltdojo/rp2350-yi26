// SPDX-License-Identifier: Apache-2.0
#ifndef MEM_LAYOUT_H
#define MEM_LAYOUT_H

#include <stdint.h>

// Physical memory layout for exp236 Micro-Monitor & Sandbox
#define MONITOR_BASE   0x80000000u
#define MONITOR_SIZE   0x00010000u  // 64 KiB
#define MONITOR_STACK  0x80008000u
#define TRAP_HANDLER   0x80000040u

#define PAYLOAD_BASE   0x80010000u
#define PAYLOAD_SIZE   0x00010000u  // 64 KiB
#define PAYLOAD_STACK  0x80020000u

// Hazard3 testbench MMIO control ports
#define IO_PRINT_U32   0xc0000004u
#define IO_EXIT        0xc0000008u

#define TAG_HALT       0x48414c54u  // "HALT"
#define TAG_FAULT      0x4641554cu  // "FAUL"

// PMP Configuration constants for 64 KiB NAPOT at 0x80010000
// (0x80010000 >> 2) | ((0x10000 >> 3) - 1)
#define DOMAIN_PMPADDR0 0x20005fffu
#define DOMAIN_PMPCFG0  0x0000001fu  // NAPOT, RWX, unlocked

#endif // MEM_LAYOUT_H

