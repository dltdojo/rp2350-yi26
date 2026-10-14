// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/shell — what alice's shells on the chip send the same way:
// HASH on the SHA-256 block, brought out of reset at its first use; a line
// sent with time for the host to take it; bytes as hex; samples as BITS
// lines, sixteen words to a line, sample i bit i % 32 of word i / 32, so that
// a page has a window's bytes from them alone. vk26-alice-1 wrote it,
// vk26-alice-2 is the second to need it.
//
// Included by a board_chip.c after speak.h (tools/hazard3/shell), whose
// line, at, put, put_hex, send, pwait and unit it uses.
#pragma once
#include <stdint.h>
#include "sha_chip.h"

static uint32_t sha_up;   // set by the first HASH: speak.h's board_init is the whole of board_init

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    if (!sha_up) {
        sha_chip_init();
        sha_up = 1;
    }
    return sha_hw(src, len, dst);
}

// A line, then long enough for the host to take it before the next: the
// queue is 1024 bytes and a BITS line about 180.
static void say(void) {
    send();
    pwait(unit / 4);
}

static void put_bytes(const uint8_t *b, uint32_t n) {
    put(" ");
    for (uint32_t i = 0; i < n; i++) {
        line[at++] = "0123456789abcdef"[b[i] >> 4];
        line[at++] = "0123456789abcdef"[b[i] & 15];
    }
}

// BITS round s k w0 … w15, for k from 0: `words` words of samples.
static void put_bits(uint32_t round, uint32_t s, const uint32_t *bits, uint32_t words) {
    for (uint32_t k = 0; k < words / 16; k++) {
        put("BITS");
        put_hex(round);
        put_hex(s);
        put_hex(k);
        for (uint32_t i = 0; i < 16; i++) put_hex(bits[16 * k + i]);
        say();
    }
}
