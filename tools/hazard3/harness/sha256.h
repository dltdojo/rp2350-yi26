// SPDX-License-Identifier: Apache-2.0
// tools/hazard3/harness — SHA-256, FIPS 180-4, freestanding. See sha256.c.
#pragma once
#include <stdint.h>

// Any length; HASH's callers check its multiple-of-64 rule themselves.
void sha256(const uint8_t *in, uint32_t len, uint8_t out[32]);
