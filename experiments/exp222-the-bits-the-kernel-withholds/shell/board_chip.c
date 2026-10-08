// SPDX-License-Identifier: Apache-2.0
//
// exp222 — the Pico 2: the TRNG for real, and the verdict on the LED
// (tools/hazard3/shell/led.h): slow blinking for ok, a count of flashes for
// anything else.
//
// The TRNG driver is tools/hazard3/shell/trng.h.

#include "board.h"
#include "led.h"
#include "trng.h"

void board_init(void) { led_init(); }

#include "report_chip.h"
