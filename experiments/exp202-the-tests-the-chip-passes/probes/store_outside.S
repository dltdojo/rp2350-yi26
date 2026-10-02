// SPDX-License-Identifier: Apache-2.0
// exp202 probe — a store outside the region is a fault, on both.
//
// On the RTL it is PMP that refuses it: the harness gives User mode its 64 KiB
// and nothing else. In the model it is `Region.ok`. Every riscv-tests store
// stays inside its own data, so neither rule is exercised by the suite.
#include "riscv_test.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
    li   t1, 0x80000000
    sw   zero, 0(t1)
    RVTEST_PASS
RVTEST_CODE_END
