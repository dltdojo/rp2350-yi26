// SPDX-License-Identifier: Apache-2.0
// exp202 probe — a misaligned load is a fault, on both.
//
// Hazard3 has no misaligned access; the model says so with a fault. The suite
// keeps its own misaligned test (ma_data) behind a trap handler built from CSR
// instructions, which this model refuses, so it is not built — and nothing
// else in it misaligns anything. This ends in a fault, and the claim is that
// both executors end it with the same fault at the same instruction.
#include "riscv_test.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
    la   t1, word
    lw   a0, 1(t1)
    RVTEST_PASS
RVTEST_CODE_END
    .data
RVTEST_DATA_BEGIN
word: .word 0x11223344
      .word 0x55667788
RVTEST_DATA_END
