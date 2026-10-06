// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — writing a kernel's image into the region, byte by
// byte through volatile stores, and comparing bytes: what a shell does
// between runs. exp212 wrote these, exp211 needed them second. REGION is the
// build's; `struct fill { uint16_t at, len; }` is the includer's expect.h's,
// where gen.py writes it with the scratch to fill.
#pragma once
#include <stdint.h>

static inline int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static inline void put(uint32_t at, const uint8_t *b, uint32_t n) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < n; i++) r[at + i] = b[i];
}

// 0xee over each scratch area, before the kernel runs: the images' rule.
static inline void fill(const struct fill *f, uint32_t n) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t k = 0; k < n; k++)
        for (uint32_t i = 0; i < f[k].len; i++) r[f[k].at + i] = 0xee;
}
