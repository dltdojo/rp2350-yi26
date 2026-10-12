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
//   PATIENT n=… word=… arm=… width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
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
#include "trial_chip.h"
