// SPDX-License-Identifier: Apache-2.0
//
// exp234 — the Pico 2: exp232's board layer (tools/hazard3/shell/trial_chip.h),
// unchanged, so that the lines, the LED and the page are exp232's and only the
// name and the USB serial say the world under them is now a proved kernel.
//
//   SEARCH tried=… accepted=… relapsing=… answer=… doses=… loophole=… minstret=…
//   PLAN sha256=…
//   PATIENT n=… word=… arm=… width=… at=… model=… world=… resistant=… t24=… tissue=… t64=…
//   TRIAL treated=… cured=… relapsed=… missed=… predicted=… control=… control_missed=…
//
// The LED: on through the search, about a second; then for each treated
// patient one flash cured, two relapsed, three missed in the world, a control
// dark, and 2 s dark before the next. A failed check is 2 s of light and then
// its number in flashes: 10 and 12 are the theorems W0 and M6 held to the
// chip.

#define SPEAK_NAME "exp234"
#define SPEAK_PRODUCT "exp234 the rate the proof predicts"
#define SPEAK_SERIAL "234"
#include "trial_chip.h"
