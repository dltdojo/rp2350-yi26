// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/shell — the RP2350's TRNG with its own tests bypassed:
// `board_trng_raw`, beside tools/hazard3/shell/trng.h's `board_trng`, whose
// configuration and block reader it uses. Included after trng.h.
//
// trng.h leaves the von Neumann balancer, the CRNGT and the autocorrelation
// test on, as embassy-rp does, so its words are the balancer's output.
// SP 800-90B estimates entropy on the noise source's raw samples, before any
// such processing, so this sets TRNG_DEBUG_CONTROL bits 1 to 3 (rp-pac 7.0.0:
// vnc_bypass, trng_crngt_bypass, auto_correlate_bypass) and reads the bits as
// the inverter chain gave them, sampled every SAMPLE_COUNT cycles. With the
// autocorrelation test bypassed, trng_block never resets the TRNG to its
// default, tested, configuration.
//
// Here rather than in tools/hazard3/shell because a proposal changes only
// its own directory (the call's S2). vk26-alice-3 is the first to need it.
#pragma once
#include <stdint.h>

#define TRNG_RAW_BYPASS 0xeu   // vnc_bypass | trng_crngt_bypass | auto_correlate_bypass

int board_trng_raw(uint32_t *words, uint32_t n) {
    REG(RESETS_RESET_CLR) = RESET_TRNG;
    while (!(REG(RESETS_RESET_DONE) & RESET_TRNG)) {}
    trng_configure();
    REG(RND_SOURCE_ENABLE) = 0;
    REG(TRNG_DEBUG_CONTROL) = TRNG_RAW_BYPASS;
    REG(RST_BITS_COUNTER) = 1;
    REG(RND_SOURCE_ENABLE) = 1;
    uint32_t six[6], have = 0;
    while (have < n) {
        if (!trng_block(six)) return 0;
        for (uint32_t i = 0; i < 6 && have < n; i++) words[have++] = six[i];
    }
    REG(RND_SOURCE_ENABLE) = 0;
    REG(TRNG_DEBUG_CONTROL) = 0;
    REG(RST_BITS_COUNTER) = 1;
    return 1;
}
