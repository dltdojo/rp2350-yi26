// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the ring of 32 cells that exp232's trial lives on, as
// a shell needs it: one bit a cell, cell i + 1 above cell i, cell 0 above
// cell 31 (lean/Rv32/Ring.lean and lean/Rv32/Tissue.lean have it proved).
//
//   up1, dn1, spread   a cell's neighbour above, below, either
//   pc                 how many cells are set
//   lump(w, at)        w cells from cell `at` up
//   xorshift           xorshift32: the search's candidates and the world's masks
//   endpoint, outcome  the trial's stated endpoint and its three outcomes, on 64
//                      generations STRIDE words apart, tumour then tissue —
//                      the includer defines STRIDE, GENS, DAYS, DETECT and
//                      TISSUE_MIN (a macro, not an argument: exp232's UF2 is
//                      byte for byte what it was before this was extracted)
//
// up1, dn1 and spread are marked unused: a shell whose world is a kernel
// (exp234) needs none of them.
//
// exp232 wrote it, exp234 needed it second.
#pragma once
#include <stdint.h>

__attribute__((unused)) static uint32_t up1(uint32_t v) { return v << 1 | v >> 31; }
__attribute__((unused)) static uint32_t dn1(uint32_t v) { return v >> 1 | v << 31; }
__attribute__((unused)) static uint32_t spread(uint32_t v) { return up1(v) | dn1(v); }

static uint32_t pc(uint32_t v) {
    v = v - ((v >> 1) & 0x55555555u);
    v = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);
    v = (v + (v >> 4)) & 0x0f0f0f0fu;
    return (v * 0x01010101u) >> 24;
}

static uint32_t lump(uint32_t w, uint32_t at) {
    uint32_t v = (1u << w) - 1;
    return at ? (v << at | v >> (32 - at)) : v;
}

static uint32_t xorshift(uint32_t v) {
    v ^= v << 13;
    v ^= v >> 17;
    v ^= v << 5;
    return v;
}

// The stated endpoint, on 64 generations: generation g + 1's tumour at
// STRIDE * g and its tissue at STRIDE * g + 1. Met when no more than DETECT
// tumour cells are left after DAYS and there was never less than TISSUE_MIN
// tissue before.
static int endpoint(const uint32_t *h) {
    if (pc(h[STRIDE * (DAYS - 1)]) > DETECT) return 0;
    for (uint32_t g = 0; g < DAYS; g++)
        if (pc(h[STRIDE * g + 1]) < TISSUE_MIN) return 0;
    return 1;
}

// 0 the endpoint met and the tumour gone at 64, 1 met and back by 64, 2 missed.
static uint32_t outcome(const uint32_t *h) {
    if (!endpoint(h)) return 2;
    return h[STRIDE * (GENS - 1)] ? 1 : 0;
}
