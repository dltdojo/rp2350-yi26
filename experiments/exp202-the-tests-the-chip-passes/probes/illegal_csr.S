// SPDX-License-Identifier: Apache-2.0
// exp202 probe — an instruction outside the subset is refused, on both.
//
// `csrr` is Zicsr, which the model has no constructor for. On the RTL, User
// mode reading a Machine-mode CSR is an illegal instruction too. The two agree
// here for different reasons, and that is said rather than hidden: the model
// would refuse `csrr cycle` as well, where the RTL would — with mcounteren set
// — allow it.
#include "riscv_test.h"
RVTEST_RV32U
RVTEST_CODE_BEGIN
    csrr a0, mstatus
    RVTEST_PASS
RVTEST_CODE_END
