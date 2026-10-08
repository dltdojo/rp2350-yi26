// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a stand-in for the TRNG on the Hazard3 RTL, which has
// none: `board_trng`, as the includer's board.h declares it, chosen with
// -DDEVICE=:
//
//   0  words from a fixed LCG, whose 1024 bits pass both health tests
//   1  words that are all ones: the TRNG's own samples withheld
//   2  no words at all: the TRNG gave nothing
//
// Not a model of the TRNG: it shows that a shell takes each verdict where it
// should. exp222 wrote it, exp223 needed it second.
#pragma once
#include <stdint.h>

#ifndef DEVICE
#define DEVICE 0
#endif

int board_trng(uint32_t *words, uint32_t n) {
    if (DEVICE == 2) return 0;
    uint32_t x = 222;
    for (uint32_t i = 0; i < n; i++) {
        x = x * 1664525u + 1013904223u;
        words[i] = DEVICE == 1 ? 0xffffffffu : x;
    }
    return 1;
}
