// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the three sources of 1024 health-test samples a shell
// judges, one sample in bit 0 of each word:
//
//   0  the TRNG (board_trng): 32 words from it, each split into 32 samples
//   1  a source stuck at 1, which the repetition count must catch
//   2  nine ones then a zero, over and over: exp114's broken source, which
//      the adaptive proportion test must catch
//
// exp222 wrote it, exp223 needed it second. It is the includer's code, put
// here once: `gather` reads the includer's `source` and fills its
// `samples[N]`, and a silent TRNG is the includer's `report(V_SILENT, ...)`
// with its `struct result`, which must all be declared first.
#pragma once

// Source `source`'s samples, into `samples`.
static void gather(void) {
    if (source == 0) {
        uint32_t w[N / 32];
        if (!board_trng(w, N / 32)) {
            struct result res = {0};
            report(V_SILENT, &res);
        }
        for (uint32_t i = 0; i < N; i++) samples[i] = (w[i / 32] >> (i % 32)) & 1u;
    } else if (source == 1) {
        for (uint32_t i = 0; i < N; i++) samples[i] = 1;
    } else {
        for (uint32_t i = 0; i < N; i++) samples[i] = i % 10 < 9;
    }
}
