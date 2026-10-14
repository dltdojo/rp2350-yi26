// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-1 — the Pico 2: the six streams shell.c runs, forever, the TRNG's
// drawn again each round (tools/hazard3/shell/trng.h), HASH on the chip's
// SHA-256 block (alice/shell/lines_chip.h), and each stream sent over USB
// (tools/hazard3/shell/speak.h) with everything a page needs to judge it
// again without the kernel: the samples, the code, the digests.
//
// Lines, while a page holds the port open:
//
//   BITS round s k w0 … w15        samples 512k to 512k + 511 of stream s,
//                                  packed 32 to a word: sample i is bit i % 32
//                                  of word i / 32. Eight lines a stream.
//   DIGEST round s w <64 hex>      the 32 bytes the kernel wrote for window w
//   STREAM round s code want minstret digests name
//                                  the halt code, seam.py's code for it
//                                  (ffffffff for the TRNG's: nothing computed
//                                  it ahead), minstret, how many digests
//   ROUND round streams            every stream run and as it should be
//
// A window is the 4096 bytes HASH reads: its 1024 samples as little-endian
// words, each 0 or 1. So a page has the window's bytes from BITS alone.
//
// The LED, after each stream: the halt code in flashes — 1 to 4, the window
// the kernel stopped at — or one long light for 0, every window passed; then
// 2 s dark. And speak.h's stage and error counts, as exp228 has them: an
// error is 2 s of light first.

#define SPEAK_NAME "vk26-alice-1"
#define SPEAK_PRODUCT "vk26-alice-1 the run across the seam"
#define SPEAK_SERIAL "vk26-alice-1"
#include "speak.h"
#include "trng.h"
#include "lines_chip.h"

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *bits, uint32_t code,
                  uint32_t want, uint32_t instret, const uint8_t (*digest)[32], uint32_t ndigests) {
    last_instret = instret;
    lives = round;
    REG(SIO_OUT_CLR) = LED;
    put_bits(round, s, bits, 128);   // four windows of 1024 samples
    for (uint32_t w = 0; w < ndigests; w++) {
        put("DIGEST");
        put_hex(round);
        put_hex(s);
        put_hex(w);
        put_bytes(digest[w], 32);
        say();
    }
    put("STREAM");
    put_hex(round);
    put_hex(s);
    put_hex(code);
    put_hex(want);
    put_hex(instret);
    put_hex(ndigests);
    put(" ");
    put(name);
    say();

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        count(usbdev.stage + 1u, 0);
        return;
    }
    if (code == 0) flash(6 * unit, 2 * unit);
    for (uint32_t i = 0; i < code; i++) flash(2 * unit, 2 * unit);
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
