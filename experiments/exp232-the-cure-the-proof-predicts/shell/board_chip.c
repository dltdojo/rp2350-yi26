// SPDX-License-Identifier: Apache-2.0
//
// exp232 — the Pico 2: the search and the trial shell.c ran, shown on the LED
// and sent over exp226's USB port (tools/hazard3/shell/speak.h), with the
// RP2350's TRNG (tools/hazard3/shell/trng.h) drawing the patients.
//
// Lines, while a page holds the port open (tools/pages/log.html will do):
//
//   SEARCH tried=… accepted=… relapsing=… answer=… doses=… loophole=… minstret=…
//   PLAN sha256=…                       the protocol, fixed before patient 1
//   PATIENT n=… arm=… width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
//   TRIAL treated=… cured=… relapsed=… missed=… predicted=… control=… control_missed=…
//
// SEARCH and PLAN go out again before every patient, so a page that opens
// late still sees what the trial is testing. model and world are cured,
// relapsed or missed: the endpoint met and the tumour gone at 64, met and
// back by 64, or not met.
//
// The LED:
//
//   on, steady                 the search, about a second
//   then, for each patient     treated: one flash cured, two relapsed, three
//                              missed — in the world; control: dark. Then 2 s
//                              dark before the next.
//
// And speak.h's stage and error counts, as exp231 has them: an error is 2 s
// of light first.

#define SPEAK_NAME "exp232"
#define SPEAK_PRODUCT "exp232 the cure the proof predicts"
#define SPEAK_SERIAL "232"
#include "speak.h"
#include "trng.h"

static const char *const WORD[3] = {"cured", "relapsed", "missed"};

void board_tick(void) {
    REG(SIO_OUT_SET) = LED;
    usb_poll();
}

static void header(const struct search *s, const uint8_t plan[32]) {
    put("SEARCH");
    field("tried", s->tried);
    field("accepted", s->accepted);
    field("relapsing", s->relapsing);
    field_hex("answer", s->answer);
    uint32_t doses = 0;
    for (uint32_t i = 0; i < 32; i++) doses += (s->answer >> i) & 1;
    field("doses", doses);
    field_hex("loophole", s->loophole);
    field("minstret", s->instret);
    send();
    put("PLAN sha256=");
    for (uint32_t i = 0; i < 32; i++) {
        line[at++] = "0123456789abcdef"[plan[i] >> 4];
        line[at++] = "0123456789abcdef"[plan[i] & 15];
    }
    send();
}

void board_searched(const struct search *s, const uint8_t plan[32]) {
    last_instret = s->instret;
    REG(SIO_OUT_CLR) = LED;
    header(s, plan);
    pwait(8 * unit);
}

void board_patient(const struct search *s, const uint8_t plan[32], const struct patient *p, const struct tally *t) {
    lives = p->n;
    header(s, plan);
    put("PATIENT");
    field("n", p->n);
    put(p->arm ? " arm=treated" : " arm=control");
    field("width", p->width);
    field("at", p->at);
    put(" model=");
    put(WORD[p->model]);
    put(" world=");
    put(WORD[p->world]);
    field("resistant", p->resistant);
    field("t24", p->t24);
    field("tissue", p->tissue);
    field("t64", p->t64);
    send();
    put("TRIAL");
    field("treated", t->arm[1]);
    field("cured", t->outcome[1][0]);
    field("relapsed", t->outcome[1][1]);
    field("missed", t->outcome[1][2]);
    field("predicted", t->predicted[1]);
    field("control", t->arm[0]);
    field("control_missed", t->outcome[0][2]);
    send();

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        count(usbdev.stage + 1u, 0);
        return;
    }
    if (p->arm)
        for (uint32_t i = 0; i <= p->world; i++) flash(2 * unit, 2 * unit);
    else
        pwait(4 * unit);
    pwait(11 * unit);
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
