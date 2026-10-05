// SPDX-License-Identifier: Apache-2.0
//
// exp210 — HASH on the RP2350's SHA-256 block (SHA256, 0x400f8000), the thing
// this experiment puts under the proved kernels. The includer defines
//
//   uint32_t sha_rd(uint32_t off)          read the register at off
//   void sha_wr(uint32_t off, uint32_t v)  write it
//
// — volatile accesses on the chip (board_chip.c), and a fake made from the
// datasheet's description on the host (host/shafake.c), which is all the
// cloud can hold this against. Offsets and bits are rp-pac's for the RP235x.
//
// The block compresses 512-bit blocks; padding is ours. HASH's input is always
// a multiple of 64 bytes, so the padding is one more whole block: 0x80, zeros,
// and the length in bits as a 64-bit big-endian number.
#pragma once
#include <stdint.h>

#define SHA_CSR       0x00u
#define SHA_WDATA     0x04u
#define SHA_SUM0      0x08u
#define SHA_START     (1u << 0)    // reset the sums and counters for a new hash
#define SHA_WDATA_RDY (1u << 1)    // a word may be written
#define SHA_SUM_VLD   (1u << 2)    // SUM0..7 hold the digest of every block so far
#define SHA_ERR       (1u << 4)    // ERR_WDATA_NOT_RDY: written while not ready; write 1 to clear
#define SHA_DMA_32    (2u << 8)    // DMA_SIZE: 32-bit, its reset value; no DMA is used
#define SHA_BSWAP     (1u << 12)   // the first byte in memory is the most significant

static void sha_word(uint32_t w) {
    while (!(sha_rd(SHA_CSR) & SHA_WDATA_RDY)) {}
    sha_wr(SHA_WDATA, w);
}

// SHA-256 of len bytes at src (len a multiple of 64, below 2^29; src word-
// aligned) to dst. Returns 0 if the block says a word was written while it
// was not ready.
static int sha_hw(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha_wr(SHA_CSR, SHA_BSWAP | SHA_DMA_32 | SHA_ERR | SHA_START);
    const uint32_t *w = (const uint32_t *)src;
    for (uint32_t i = 0; i < len / 4; i++) sha_word(w[i]);
    // Words are little-endian reads of memory, so the padding's bytes are
    // given the same way: 80 00 00 00 is 0x00000080.
    sha_word(0x80);
    for (uint32_t i = 0; i < 13; i++) sha_word(0);
    sha_word(0);                                  // the bit length's high word
    sha_word(__builtin_bswap32(len * 8));         // and its low word, big-endian
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
