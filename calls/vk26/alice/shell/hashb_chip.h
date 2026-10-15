// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/shell — HASHB (exp228's ecall, t0 = 2: SHA-256 of any
// length from any address) on the chip's SHA-256 block.
// tools/hazard3/shell/sha_hw.h takes whole 64-byte blocks from a word-aligned
// address, HASH's rule, and S2 keeps tools/ closed to a proposal, so the
// padding is here. vk26-alice-4 wrote it, in its board_chip.c; vk26-alice-5,
// whose Instantiate kernel hashes 53- to 85-byte inputs, is the second to
// need it.
//
// Included by a board_chip.c after lines_chip.h, whose sha_up it shares.
#pragma once
#include <stdint.h>

// HASHB on the block: any length, any start. sha_hw.h's sha_word takes words
// as little-endian reads of memory, so bytes are gathered four at a time in
// that order; then the padding, a byte at a time the same way: 0x80, zeros to
// 56 bytes into a block, and the length in bits as 8 bytes, big-endian.
static uint32_t acc, fed;

static void hashb_byte(uint8_t b) {
    acc |= (uint32_t)b << (8 * (fed % 4));
    if (++fed % 4 == 0) {
        sha_word(acc);
        acc = 0;
    }
}

int board_hashb(const uint8_t *src, uint32_t len, uint8_t *dst) {
    if (!sha_up) {
        sha_chip_init();
        sha_up = 1;
    }
    sha_wr(SHA_CSR, SHA_BSWAP | SHA_DMA_32 | SHA_ERR | SHA_START);
    acc = fed = 0;
    for (uint32_t i = 0; i < len; i++) hashb_byte(src[i]);
    hashb_byte(0x80);
    while (fed % 64 != 56) hashb_byte(0);
    for (int k = 7; k >= 0; k--) hashb_byte(k >= 4 ? 0 : (uint8_t)((8 * len) >> (8 * k)));
    while (!(sha_rd(SHA_CSR) & SHA_SUM_VLD)) {}
    for (uint32_t i = 0; i < 8; i++) {
        uint32_t v = sha_rd(SHA_SUM0 + 4 * i);
        dst[4 * i] = v >> 24;
        dst[4 * i + 1] = v >> 16;
        dst[4 * i + 2] = v >> 8;
        dst[4 * i + 3] = v;
    }
    return !(sha_rd(SHA_CSR) & SHA_ERR);
}
