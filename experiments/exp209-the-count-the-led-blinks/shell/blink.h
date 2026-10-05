// SPDX-License-Identifier: Apache-2.0
// exp209 — what the LED says, as a sequence of holds. See blink.c.
#pragma once
#include <stdint.h>

// Hold the LED on or off for `units` time units.
typedef void (*led_hold)(int on, uint32_t units);

// One round of a report — `n` numbers — or of a fault; the board repeats it
// forever.
void blink_report(led_hold hold, const uint32_t *numbers, uint32_t n);
void blink_fault(led_hold hold, uint32_t step);
