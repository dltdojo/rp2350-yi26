// SPDX-License-Identifier: Apache-2.0
//
// exp211 — the shell: one boot, one leaf. Read the counter in flash, claim
// the next leaf there, and only then sign: exp213's signer in User mode under
// tools/hazard3/harness/harness.S, then exp206's verifier on the region the
// signer left — the three_binaries theorem's copying, with the code replaced
// and nothing else. If the verifier accepts, the leaf is confirmed in flash.
//
// The order is the whole point (model/MssCounter.tla, design "unary"):
//
//   1  board_init           the LED on
//   2  ctr_begin            format if needed, read, claim, read the claim back
//   3  board_window         claimed and not signed: where a person may cut
//   4  the signer           HASH answered by board_hash
//   5  the verifier
//   6  ctr_confirm          and report
//
// Nothing is signed under a leaf the flash does not already show as used.
// A step counter is written before each step and never after, so a trap in
// the shell itself names the step that did not come back (on the RTL).

#include <stdint.h>

#define REGION_SIZE 0x10000u   // REGION is the build's: 0x20070000 on the chip

#include "board.h"
#include "expect.h"
#include "hashcall.h"
#include "region.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))

extern void enter_payload(void) __attribute__((noreturn));

enum { SIGNING, VERIFYING };

static volatile uint32_t step;
static uint32_t phase, leaf, hash_ok;
static struct ctr c;

// The kernel's bytes as they sit in SRAM, against its .sha256 — the shell's
// own SHA-256, never the block.
static void enter(const uint8_t *sha, uint32_t len) {
    uint8_t d[32];
    sha256((const uint8_t *)REGION, len, d);
    if (!same(d, sha, 32)) board_report(OUT_KERNEL, &c, leaf);
    hash_ok = 1;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    board_init();

    step = 2;
    uint32_t s = ctr_begin(&c);
    if (s == CTR_EXHAUSTED) board_report(OUT_EXHAUSTED, &c, CTR_LEAVES);
    if (s == CTR_CORRUPT) board_report(OUT_CORRUPT, &c, CTR_LEAVES);
    if (s != CTR_SIGN) board_report(OUT_UNWRITTEN, &c, c.used);
    leaf = c.used;

    step = 3;
    board_window(leaf);

    step = 4;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    put(0, SIGN_BIN, SIGN_LEN);
    put(S_MSG, MSG[leaf], 32);
    ((volatile uint8_t *)REGION)[S_IDX] = (uint8_t)leaf;
    put(S_SEED, SEED, 32);
    put(S_TREE, TREE, TREE_LEN);
    fill(S_FILL, sizeof S_FILL / sizeof S_FILL[0]);
    phase = SIGNING;
    enter(SIGN_SHA, SIGN_LEN);
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);

    // HASH: back into the payload, as the model's syscall does.
    if (cause == 8 && x[5] == 0 && hash_args_ok(x[10], x[11], x[12])) {
        hash_ok &= board_hash((const uint8_t *)x[10], x[11], (uint8_t *)x[12]);
        csrw(mepc, csrr(mepc) + 4);
        return;
    }

    uint32_t halted = cause == 8 && x[5] == 1 && x[10] == 0 && hash_ok;
    if (phase == SIGNING) {
        if (!halted) board_report(OUT_SIGN_FAILED, &c, leaf);
        step = 5;
        put(0, VERIFY_BIN, VERIFY_LEN);
        phase = VERIFYING;
        enter(VERIFY_SHA, VERIFY_LEN);
    }
    if (!halted) board_report(OUT_REJECTED, &c, leaf);
    step = 6;
    ctr_confirm(leaf);
    board_report(OUT_SIGNED, &c, leaf);
}
