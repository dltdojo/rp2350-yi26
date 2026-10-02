// SPDX-License-Identifier: Apache-2.0
// exp202 probe — fetching outside the region is a fault, on both.
//
// The jump itself is fine; the fetch at its target is not. Both executors must
// report the target as where it stopped — the model's pc, the RTL's mepc.
#include "riscv_test.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
    li   t1, 0x80000100
    jalr x0, 0(t1)
    RVTEST_PASS
RVTEST_CODE_END
