// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-4 — the Pico 2: the NIST cases shell.c runs, forever; HASHB and
// the region's hash on the chip's SHA-256 block (alice/shell/lines_chip.h,
// and below for HASHB's lengths); each run sent over USB
// (tools/hazard3/shell/speak.h) with what a page needs to generate it again
// without the kernel.
//
// Lines, while a page holds the port open (hex bytes in the order they lie in
// the region; the other fields eight hex digits):
//
//   STATE round i k bytes          V (k = 0) and C (k = 1) as the shell put
//                                  them there, before the first run; V after
//                                  the first Generate (k = 2) and the second
//                                  (k = 3)
//   BLOCK round i n j bytes        block j of Generate n's M, at 0x600 + 32j
//   RUN round i n code counter minstret mcycle
//                                  run n of three: the halt code, the counter
//                                  word afterwards, minstret, mcycle
//   CASE round i name              every run of the case as it should be
//   REVISION 1                     which firmware this is, every round
//   ROUND round cases              every case run and as it should be
//
// The LED: a short blink as each case ends, about one a second; after the
// 120th, one long light and then 2 s dark. And speak.h's stage and error
// counts: an error is 2 s of light first, then as many flashes as the check
// that failed.

#define SPEAK_NAME "vk26-alice-4"
#define SPEAK_PRODUCT "vk26-alice-4 the state the generator keeps"
#define SPEAK_SERIAL "vk26-alice-4"
#include "speak.h"
#include "lines_chip.h"
#include "hashb_chip.h"

// lines_chip.h's BITS lines carry samples; this experiment has none.
static void (*const unused_bits)(uint32_t, uint32_t, const uint32_t *, uint32_t) __attribute__((unused)) = put_bits;

void board_state(uint32_t round, uint32_t i, const uint8_t *v, const uint8_t *c) {
    for (uint32_t k = 0; k < 2; k++) {
        put("STATE");
        put_hex(round);
        put_hex(i);
        put_hex(k);
        put_bytes(k ? c : v, 55);
        say();
    }
}

void board_run(uint32_t round, uint32_t i, uint32_t n, uint32_t code, uint32_t counter, uint32_t instret,
               uint32_t cycles, const uint8_t *blocks, uint32_t nblocks, const uint8_t *v) {
    last_instret = instret;
    if (blocks) {
        for (uint32_t j = 0; j < nblocks; j++) {
            put("BLOCK");
            put_hex(round);
            put_hex(i);
            put_hex(n);
            put_hex(j);
            put_bytes(blocks + 32 * j, 32);
            say();
        }
        put("STATE");
        put_hex(round);
        put_hex(i);
        put_hex(n + 1);
        put_bytes(v, 55);
        say();
    }
    put("RUN");
    put_hex(round);
    put_hex(i);
    put_hex(n);
    put_hex(code);
    put_hex(counter);
    put_hex(instret);
    put_hex(cycles);
    say();
}

void board_case(uint32_t round, uint32_t i, const char *name) {
    put("CASE");
    put_hex(round);
    put_hex(i);
    put(" ");
    put(name);
    say();
    flash(unit / 2, unit / 2);
}

void board_round(uint32_t round, uint32_t cases) {
    lives = round;
    put("REVISION");
    put_hex(1);
    say();
    put("ROUND");
    put_hex(round);
    put_hex(cases);
    say();
    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        count(usbdev.stage + 1u, 0);
        return;
    }
    flash(6 * unit, 2 * unit);
    pwait(11 * unit);
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
