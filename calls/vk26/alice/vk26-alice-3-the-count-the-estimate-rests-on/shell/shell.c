// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-3 — the shell: five streams of 4096 byte samples, each counted
// by proof/Count.lean's kernel in User mode under tools/hazard3/harness,
// forever on the chip, once on the RTL.
//
//   0     the TRNG, its own tests on: 1024 words, the von Neumann balancer's
//   1     the TRNG, its tests bypassed: 1024 words of raw bits
//         (alice/shell/trng_raw.h)
//   2-4   gen.py's FIXED: count.py's streams, each value 16 times, 0xa5 at
//         1000 places, and each bit 1 three times in four
//
// Sample i is byte i % 4 of word i / 4. For each: the 64 KiB region zeroed,
// kernel.bin's 116 bytes at its start (checked against kernel.sha256), the
// 4096 samples at 0x400; the region hashed. The kernel runs; it calls
// nothing. When it halts it runs again at once, on the same region: between
// the two, only the trap's way into handle() and back out through
// enter_payload. When the second halts, the checks board.h numbers, on both:
//
//   1 the kernel's bytes were kernel.sha256's
//   2 it halted with 0, by HALT
//   3 minstret is the RTL's count (gen.py): the same for every stream
//   4 the 256 words at 0x1400 are the shell's own count of the samples,
//     value by value; the word at 0x1800 is the largest of them, and gen.py's
//     for a fixed stream; and with those cleared the region hashes as it did
//     before the run
//
// mcycle is read and sent for both runs, not checked: the proof says no
// sample can move it, and exp212 found silicon's cycles are not the RTL's,
// so the page compares the streams with each other. Revision 1 ran each
// stream once and saw three numbers, the same samples moving between rounds;
// the second run is revision 2's question: does a run straight after another
// take one number?
//
// Revision 3 sets what the XIP cache holds when the first run's window
// opens. On the chip, two harness instructions inside the window are
// fetched from flash: `mret` and the trap entry, the word at `trap`. Revision
// 2's board was slow only after the copy of FIXED[0] or FIXED[2], whose
// addresses share the cache's sets with them (offsets modulo 8 KiB, the two
// ways of the 16 KiB cache); FIXED[1]'s do not. So, last before the window:
//
//   streams 2, 4   the two words at `trap` - 4 and `trap` read, back into
//                  the cache
//   stream 3       FIXED[0] and FIXED[2] read through, over both ways of
//                  those sets
//   streams 0, 1   nothing, as before
//
// On the RTL there is no cache, and these are reads of RAM.
//
// A step counter is written before each step, for a trap in the shell itself
// to be named.

#include <stdint.h>

#ifndef REGION_SIZE
#define REGION_SIZE 0x10000u
#endif
#include "board.h"
#include "expect.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define SAMPLES  0x400u
#define HIST     0x1400u
#define MOST     0x1800u
#define NSTREAMS (2u + NFIXED)
#define TRNG_WANT 0xffffffffu

extern void enter_payload(void) __attribute__((noreturn));
extern const uint32_t trap[];

static volatile uint32_t step;
static uint32_t round, si, kernel_ok, run;
static uint32_t first_cause, first_x5, first_a0, first_instret, first_cycles;
static uint32_t words[WORDS], counts[256], mine[256];
static uint8_t before[32];
static volatile uint32_t sink;

static void read_through(const uint32_t *p, uint32_t n) {
    uint32_t x = 0;
    for (uint32_t i = 0; i < n; i++) x += ((const volatile uint32_t *)p)[i];
    sink = x;
}

static int same(const volatile uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

__attribute__((noreturn)) static void next_stream(void) {
    step = 2;
    if (si == 0) {
        if (!board_trng(words, WORDS)) board_fail(10, round);
    } else if (si == 1) {
        if (!board_trng_raw(words, WORDS)) board_fail(10, round);
    } else {
        for (uint32_t k = 0; k < WORDS; k++) words[k] = FIXED[si - 2].words[k];
    }

    step = 3;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    for (uint32_t k = 0; k < WORDS; k++) w[SAMPLES / 4 + k] = words[k];

    step = 4;
    uint8_t d[32];
    sha256((const uint8_t *)REGION, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    if (!board_hash((const uint8_t *)REGION, REGION_SIZE, before)) board_fail(4, si);
    run = 0;
    if (si == 3) {
        read_through(FIXED[0].words, WORDS);
        read_through(FIXED[2].words, WORDS);
    } else if (si >= 2) {
        read_through(trap - 1, 2);
    }
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    round = 0;
    si = 0;
    next_stream();
}

// Every trap: the kernel's ecall, a kernel fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret), cycles = csrr(mcycle);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the TRNG's wait needs it

    // The first run straight into the second: nothing else between them.
    if (run == 0) {
        run = 1;
        first_cause = cause;
        first_x5 = x[5];
        first_a0 = x[10];
        first_instret = instret;
        first_cycles = cycles;
        enter_payload();
    }

    step = 5;
    if (first_cause != 8 || first_x5 != 1) board_fail(2, first_cause);
    if (cause != 8 || x[5] != 1) board_fail(2, cause);
    if (!kernel_ok) board_fail(1, si);
    if (first_a0 != 0) board_fail(2, first_a0);
    if (x[10] != 0) board_fail(2, x[10]);
    if (first_instret != INSTRET) board_fail(3, first_instret);
    if (instret != INSTRET) board_fail(3, instret);

    step = 6;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t v = 0; v < 256; v++) mine[v] = 0;
    for (uint32_t i = 0; i < 4 * WORDS; i++) mine[r[SAMPLES + i]]++;
    uint32_t most = w[MOST / 4], top = 0;
    for (uint32_t v = 0; v < 256; v++) {
        counts[v] = w[HIST / 4 + v];
        if (counts[v] != mine[v]) board_fail(4, v);
        if (mine[v] > top) top = mine[v];
    }
    uint32_t want = si < 2 ? TRNG_WANT : FIXED[si - 2].most;
    if (most != top || (si >= 2 && most != want)) board_fail(4, most);
    for (uint32_t i = HIST / 4; i <= MOST / 4; i++) w[i] = 0;
    uint8_t d[32];
    if (!board_hash((const uint8_t *)REGION, REGION_SIZE, d) || !same(d, before, 32)) board_fail(4, si);

    step = 7;
    board_stream(round, si, si == 0 ? "trng" : si == 1 ? "trng raw" : FIXED[si - 2].name, words, counts, most,
                 want, first_instret, first_cycles, instret, cycles);
    si++;
    if (si == NSTREAMS) {
        board_round(round, NSTREAMS);
        round++;
        si = 0;
    }
    next_stream();
}
