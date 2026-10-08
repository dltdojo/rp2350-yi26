// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the RP2350's TRNG, for a shell on the chip:
// `board_trng`, as the includer's board.h declares it. exp222 wrote it, exp223
// needed it second. The includer includes led.h first, for REG and RESETS.
//
// The driver is embassy-rp 0.10's blocking path, register by register
// (rp-pac 7.0.0's addresses and fields), with exp109's sample count of 1000
// rather than the upstream default of 25, which exp109 measured taking up to
// half a minute for 64 bits. Its own tests (autocorrelation, CRNGT, the von
// Neumann balancer) are left on, as embassy-rp leaves them.
#pragma once
#include <stdint.h>

#define TRNG               0x400f0000u
#define RNG_IMR            (TRNG + 0x100u)
#define RNG_ISR            (TRNG + 0x104u)
#define TRNG_CONFIG        (TRNG + 0x10cu)
#define TRNG_VALID         (TRNG + 0x110u)
#define EHR_DATA(n)        (TRNG + 0x114u + 4u * (n))
#define RND_SOURCE_ENABLE  (TRNG + 0x12cu)
#define SAMPLE_CNT1        (TRNG + 0x130u)
#define TRNG_DEBUG_CONTROL (TRNG + 0x138u)
#define TRNG_SW_RESET      (TRNG + 0x140u)
#define TRNG_BUSY          (TRNG + 0x1b8u)
#define RST_BITS_COUNTER   (TRNG + 0x1bcu)
#define RESET_TRNG         (1u << 25)
#define SAMPLE_COUNT       1000u
#define PATIENCE           20000000u   // mcycle ticks for one block of 192 bits: ~2 s at ~11 MHz

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })

static void trng_configure(void) {
    REG(RNG_IMR) = 0;
    REG(TRNG_CONFIG) = 0;              // the shortest inverter chain, as embassy-rp's default
    REG(SAMPLE_CNT1) = SAMPLE_COUNT;
    REG(TRNG_DEBUG_CONTROL) = 0;       // no test bypassed
    REG(RND_SOURCE_ENABLE) = 1;
}

// One block of six words, once the TRNG says it has one; 0 on timeout.
static int trng_block(uint32_t *six) {
    uint32_t start = csrr(mcycle);
    for (;;) {
        while (REG(TRNG_BUSY) & 1u)
            if (csrr(mcycle) - start > PATIENCE) return 0;
        if (REG(TRNG_VALID) & 1u) break;
        if (REG(RNG_ISR) & 2u) {       // an autocorrelation error: reset and start again
            REG(TRNG_SW_RESET) = 1;
            (void)REG(TRNG_SW_RESET);
            trng_configure();
        }
        if (csrr(mcycle) - start > PATIENCE) return 0;
    }
    for (uint32_t i = 0; i < 6; i++) six[i] = REG(EHR_DATA(i));   // reading EHR_DATA5 last clears them
    return 1;
}

int board_trng(uint32_t *words, uint32_t n) {
    REG(RESETS_RESET_CLR) = RESET_TRNG;
    while (!(REG(RESETS_RESET_DONE) & RESET_TRNG)) {}
    trng_configure();
    uint32_t six[6], have = 0;
    while (have < n) {
        if (!trng_block(six)) return 0;
        for (uint32_t i = 0; i < 6 && have < n; i++) words[have++] = six[i];
    }
    REG(RND_SOURCE_ENABLE) = 0;
    REG(RST_BITS_COUNTER) = 1;
    return 1;
}
