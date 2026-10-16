// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
#include "mem_layout.h"

// What enclave.c found out, and what board_chip.c says about it. Every field is
// something that was read back from the machine; nothing here is a constant that
// is printed because it is expected.

struct op_result {
    uint32_t a0;
    uint32_t instret;       // the monitor's report: minstret from mret to the ecall
    uint32_t model;         // exp229's Lean model: the kernel's own instruction count
    uint32_t cycles;
    uint32_t again;         // minstret of a second, identical run
    uint32_t ok;
};

struct test_result {
    uint32_t a0;
    uint32_t mcause;
    uint32_t mtval;
    uint32_t tag_ok;
    uint32_t caller_nonzero;   // caller-saved registers (not a0) that were not zero afterwards
    uint32_t callee_bad;       // callee-saved registers that did not come back
    uint32_t intact;           // the monitor's bytes unchanged
    uint32_t ok;
};

struct enclave_report {
    uint32_t monitor_bytes, monitor_words;
    uint32_t pmpcfg, pmpaddr, pmp_ok;
    struct op_result ops[3];            // add, sub, mul
    struct test_result scrub;           // the canary payload
    struct test_result faults[3];       // read the monitor, write the monitor, unknown syscall
    uint32_t fail;                      // 0 = all passed, else the number of the first thing that did not
};

extern struct enclave_report report;

void board_init(void);
void board_report(const struct enclave_report *r);
void board_loop(const struct enclave_report *r);
