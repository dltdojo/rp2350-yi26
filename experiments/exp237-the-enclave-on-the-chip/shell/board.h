// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>
#include "mem_layout.h"

struct enclave_result {
    uint32_t op;
    uint32_t a0;
    uint32_t instret;
    uint32_t cycles;
    uint32_t r[8];
    uint32_t ok;
};

void board_init(void);
void board_report_boot(void);
void board_report_op(const struct enclave_result *res);
void board_report_summary(uint32_t pass);
void board_loop(void);
