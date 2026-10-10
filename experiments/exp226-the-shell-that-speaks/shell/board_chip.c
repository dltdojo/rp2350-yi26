// SPDX-License-Identifier: Apache-2.0
//
// exp226 — the Pico 2: exp225's shell and kernel, unchanged, with a USB port.
//
// exp225's shell calls four functions to show what it found; this file is a
// second set of them. Everything else on the chip — the proved kernel, the
// four checks, the lives — is exp225's own source, compiled in as it is.
//
// The USB port, the status line, the waits and the LED's two shapes are
// tools/hazard3/shell/speak.h, which was this file until exp227 needed them
// too. What is left here is how exp226 shows a life:
//
//   board_play   the life goes out over USB as one LIFE line, as the RTL prints
//                it; the LED says only how far the host has got with the
//                device, for as long as exp225 would have played the life
//
//   LIFE round minstret gen1 gen256 centre-column
//
// Revision 1 played the life on the LED and showed the stage between lives,
// and on a board it could not be read; revision 2 on, the LED is the stage.

#define SPEAK_NAME "exp226"
#define SPEAK_PRODUCT "exp226 the shell that speaks"
#define SPEAK_SERIAL "226"
#include "speak.h"

#define CENTRE 16

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    last_instret = instret;
    REG(SIO_OUT_CLR) = LED;

    uint32_t col = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((life[g] >> CENTRE) & 1) << g;
    put("LIFE");
    put_hex(round);
    put_hex(instret);
    put_hex(life[0]);
    put_hex(life[N - 1]);
    put_hex(col);
    send();
    lives = round + 1;

    // As long as exp225 would have played it: 256 beats of two units.
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < N * 2 * unit) count(usbdev.stage + 1u, 0);
}

// speak_fail is forced inline, so this image is the one revision 5 was before
// speak.h existed: check.sh holds it to the committed hash.
void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
