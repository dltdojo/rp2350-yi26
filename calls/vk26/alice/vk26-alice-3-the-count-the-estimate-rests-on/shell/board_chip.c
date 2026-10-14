// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-3 — the Pico 2: the five streams shell.c runs, forever, the
// TRNG's two drawn again each round (tools/hazard3/shell/trng.h, its tests
// on; alice/shell/trng_raw.h, its tests bypassed), the region hashed on the
// chip's SHA-256 block (alice/shell/lines_chip.h), and each stream sent over
// USB (tools/hazard3/shell/speak.h) with what a page needs to count it again
// without the kernel.
//
// Lines, while a page holds the port open:
//
//   BITS round s k w0 … w15        words 16k to 16k + 15 of stream s's 1024:
//                                  sample i is byte i % 4 of word i / 4.
//                                  Sixty-four lines a stream
//   HIST round s k c0 … c15        the counts the kernel wrote for the values
//                                  16k to 16k + 15. Sixteen lines a stream
//   STREAM round s most want minstret mcycle name
//                                  the largest count the kernel wrote,
//                                  gen.py's (ffffffff for the TRNG's),
//                                  minstret, and the kernel's mcycle
//   ROUND round streams            every stream run and as it should be
//
// The LED, after each stream: one long light, then 2 s dark. A healthy round
// is five. And speak.h's stage and error counts: an error is 2 s of light
// first, then as many flashes as the check that failed.

#define SPEAK_NAME "vk26-alice-3"
#define SPEAK_PRODUCT "vk26-alice-3 the count the estimate rests on"
#define SPEAK_SERIAL "vk26-alice-3"
#include "speak.h"
#include "trng.h"
#include "trng_raw.h"
#include "lines_chip.h"

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *words, const uint32_t *counts,
                  uint32_t most, uint32_t want, uint32_t instret, uint32_t cycles) {
    last_instret = instret;
    lives = round;
    REG(SIO_OUT_CLR) = LED;
    put_bits(round, s, words, 1024);
    for (uint32_t k = 0; k < 16; k++) {
        put("HIST");
        put_hex(round);
        put_hex(s);
        put_hex(k);
        for (uint32_t i = 0; i < 16; i++) put_hex(counts[16 * k + i]);
        say();
    }
    put("STREAM");
    put_hex(round);
    put_hex(s);
    put_hex(most);
    put_hex(want);
    put_hex(instret);
    put_hex(cycles);
    put(" ");
    put(name);
    say();

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        count(usbdev.stage + 1u, 0);
        return;
    }
    flash(6 * unit, 2 * unit);
    pwait(11 * unit);
}

void board_round(uint32_t round, uint32_t streams) {
    put("ROUND");
    put_hex(round);
    put_hex(streams);
    say();
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
