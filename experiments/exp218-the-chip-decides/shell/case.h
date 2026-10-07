// SPDX-License-Identifier: Apache-2.0
// exp218 — one case, as model/Cases.lean writes it into cases.h: a program,
// where it starts, its configuration, two batches of TX words, and what the
// model says the chip holds when it has stopped for the second time.
#pragma once
#include <stdint.h>

struct pio_want {
    uint32_t pc, x, y, isr, osr, irq, padout, padoe, txlevel;
    uint32_t nrx1, rx1[4];       // what RX held at the first stop
    uint32_t nrx2, rx2[4];       // and at the second
};

struct pio_case {
    uint32_t len;
    uint16_t words[32];          // at 0; the rest of instruction memory is 0, jmp 0
    uint16_t jmp;                // jmp to where it starts, executed before enabling
    uint32_t execctrl, shiftctrl, pinctrl;
    uint32_t ntx1, tx1[4];       // in TX before the first run
    uint32_t ntx2, tx2[4];       // and before the second
    struct pio_want want;
};
