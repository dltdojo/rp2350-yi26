// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-2 — the Pico 2: the five streams shell.c runs, forever, the
// TRNG's drawn again each round (tools/hazard3/shell/trng.h), HASH on the
// chip's SHA-256 block (alice/shell/lines_chip.h), and each stream sent over
// USB (tools/hazard3/shell/speak.h) with what a page needs to judge it again
// without the kernel.
//
// Lines, while a page holds the port open:
//
//   BITS round s k w0 … w15        samples 512k to 512k + 511 of stream s,
//                                  sample i bit i % 32 of word i / 32. Four
//                                  lines a stream: the start-up window, then
//                                  the one whose digest is the output
//   KAT round s spoil <64 hex>     HASH's answer to the KAT, as the kernel saw
//                                  it, and whether the shell spoiled it
//   DIGEST round s 0 <64 hex>      the output, with code 0 only
//   STREAM round s code want minstret digests name
//                                  the halt code, trust.py's code for it
//                                  (ffffffff for the TRNG's), minstret, 1 if
//                                  an output was written
//   ROUND round streams            every stream run and as it should be
//
// The LED, after each stream: the halt code in flashes — 1 the start-up
// window failed, 2 HASH failed its KAT, 3 the next window failed — or one long
// light for 0; then 2 s dark. A healthy round: long, two, three, long, one.
// And speak.h's stage and error counts: an error is 2 s of light first.

#define SPEAK_NAME "vk26-alice-2"
#define SPEAK_PRODUCT "vk26-alice-2 the hash tested first"
#define SPEAK_SERIAL "vk26-alice-2"
#include "speak.h"
#include "trng.h"
#include "lines_chip.h"

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *bits, uint32_t code,
                  uint32_t want, uint32_t instret, uint32_t spoil, const uint8_t *kat, const uint8_t *output) {
    last_instret = instret;
    lives = round;
    REG(SIO_OUT_CLR) = LED;
    put_bits(round, s, bits, 64);   // two windows of 1024 samples
    put("KAT");
    put_hex(round);
    put_hex(s);
    put_hex(spoil);
    put_bytes(kat, 32);
    say();
    if (output) {
        put("DIGEST");
        put_hex(round);
        put_hex(s);
        put_hex(0);
        put_bytes(output, 32);
        say();
    }
    put("STREAM");
    put_hex(round);
    put_hex(s);
    put_hex(code);
    put_hex(want);
    put_hex(instret);
    put_hex(output ? 1u : 0u);
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
