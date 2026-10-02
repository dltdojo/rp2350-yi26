// SPDX-License-Identifier: Apache-2.0
// exp202 probe — jalr clears the target's low bit.
//
// riscv-tests' jalr cases only ever jump to even addresses, so a model that
// forgot `& ~1` passes all of them. Here the target is odd on purpose: the
// specification lands on `target`, a model without the rule faults on a
// misaligned fetch one byte past it.
#include "riscv_test.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
    li   gp, 2
    la   t1, target
    addi t1, t1, 1
    jalr x0, 0(t1)
    j    fail
target:
    RVTEST_PASS
fail:
    RVTEST_FAIL
RVTEST_CODE_END
