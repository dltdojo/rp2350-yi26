// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-5 — the Pico 2: what shell.c runs, forever, the chains drawn
// afresh each round from the TRNG (tools/hazard3/shell/trng.h); HASH on the
// chip's SHA-256 block (alice/shell/lines_chip.h) and HASHB there too
// (alice/shell/hashb_chip.h); every run sent over USB
// (tools/hazard3/shell/speak.h) with what a page needs to do it all again
// without the kernels.
//
// Lines, while a page holds the port open (bytes in hex in the order they lie
// in the region; other fields eight hex digits):
//
//   SEED round i s bytes           a NIST case's seed material, s bytes
//   STATE round i k bytes          V (k = 0) and C (1) after Instantiate
//   BLOCK round i j bytes          block j of the second Generate
//   RUN round i n minstret mcycle  n = 0 Instantiate, 1 and 2 the Generates
//   CASE round i name              the case, every check passed
//
//   BITS round s k w0 … w15        chain s's samples 512k to 512k + 511,
//                                  sample i bit i % 32 of word i / 32
//   KAT round s spoil bytes        HASH's answer to the KAT, as alice-2's
//                                  kernel saw it, and whether it was spoiled
//   TRUST round s code minstret mcycle
//                                  alice-2's kernel; with code 0 only:
//   DIGEST round s bytes           its digest of window 1, at 0x2400
//   CSTATE round s k bytes         V (0) and C (1) after Instantiate
//   CBLOCK round s j bytes         block j of Generate
//   CRUN round s n minstret mcycle n = 0 Instantiate, 1 Generate
//   CHAIN round s code             the chain, every check passed; its nonce
//                                  is the round, 16 bytes little-endian
//   REVISION 1, ROUND round cases  every round
//
// The LED: a short blink as each NIST case ends; after each chain its code in
// flashes, one long light for 0, two for the spoiled KAT; then 2 s dark. And
// speak.h's stage and error counts: an error is 2 s of light first.

#define SPEAK_NAME "vk26-alice-5"
#define SPEAK_PRODUCT "vk26-alice-5 the seed the tests passed"
#define SPEAK_SERIAL "vk26-alice-5"
#include "speak.h"
#include "trng.h"
#include "lines_chip.h"
#include "hashb_chip.h"

static void line_bytes(const char *what, uint32_t round, uint32_t i, uint32_t k, int with_k, const uint8_t *b,
                       uint32_t n) {
    put(what);
    put_hex(round);
    put_hex(i);
    if (with_k) put_hex(k);
    put_bytes(b, n);
    say();
}

static void line_run(const char *what, uint32_t round, uint32_t i, uint32_t n, const uint32_t *run) {
    put(what);
    put_hex(round);
    put_hex(i);
    put_hex(n);
    put_hex(run[0]);
    put_hex(run[1]);
    say();
}

void board_nist(uint32_t round, uint32_t i, const char *name, const uint8_t *seed, uint32_t s, const uint8_t *v,
                const uint8_t *c, const uint8_t *blocks, const uint32_t *runs) {
    last_instret = runs[0];
    line_bytes("SEED", round, i, s, 1, seed, s);
    line_bytes("STATE", round, i, 0, 1, v, 55);
    line_bytes("STATE", round, i, 1, 1, c, 55);
    for (uint32_t j = 0; j < NBLOCKS; j++) line_bytes("BLOCK", round, i, j, 1, blocks + 32 * j, 32);
    for (uint32_t n = 0; n < 3; n++) line_run("RUN", round, i, n, runs + 2 * n);
    put("CASE");
    put_hex(round);
    put_hex(i);
    put(" ");
    put(name);
    say();
    flash(unit / 2, unit / 2);
}

void board_chain(uint32_t round, uint32_t s, const uint32_t *bits, uint32_t spoil, const uint8_t *kat, uint32_t code,
                 const uint32_t *trust, const uint8_t *digest, const uint8_t *v, const uint8_t *c,
                 const uint8_t *blocks, const uint32_t *runs) {
    lives = round;
    put_bits(round, s, bits, 64);
    line_bytes("KAT", round, s, spoil, 1, kat, 32);
    put("TRUST");
    put_hex(round);
    put_hex(s);
    put_hex(code);
    put_hex(trust[0]);
    put_hex(trust[1]);
    say();
    if (digest) {
        line_bytes("DIGEST", round, s, 0, 0, digest, 32);
        line_bytes("CSTATE", round, s, 0, 1, v, 55);
        line_bytes("CSTATE", round, s, 1, 1, c, 55);
        for (uint32_t j = 0; j < NBLOCKS; j++) line_bytes("CBLOCK", round, s, j, 1, blocks + 32 * j, 32);
        for (uint32_t n = 0; n < 2; n++) line_run("CRUN", round, s, n, runs + 2 * n);
    }
    put("CHAIN");
    put_hex(round);
    put_hex(s);
    put_hex(code);
    say();

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        count(usbdev.stage + 1u, 0);
        return;
    }
    if (code == 0) flash(6 * unit, 2 * unit);
    for (uint32_t i = 0; i < code; i++) flash(2 * unit, 2 * unit);
    pwait(11 * unit);
}

void board_round(uint32_t round, uint32_t cases) {
    put("REVISION");
    put_hex(1);
    say();
    put("ROUND");
    put_hex(round);
    put_hex(cases);
    say();
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
