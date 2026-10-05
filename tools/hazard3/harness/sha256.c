// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — SHA-256, FIPS 180-4, freestanding.
//
// The RTL harness's HASH (handler.c) and the chip shell (exp209) both use this
// one; it moved out of handler.c when the second caller arrived. hashlib and
// lean/Sha256.lean are the two it is held against (exp204).

#include <stddef.h>

#include "sha256.h"

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

// Freestanding code still gets memset calls from the compiler for zeroed
// arrays; this is the one it calls. The volatile store keeps clang from
// recognising the loop as memset and calling itself.
void *memset(void *d, int c, size_t n) {
    volatile uint8_t *p = d;
    while (n--) *p++ = (uint8_t)c;
    return d;
}

// And the memcpy it calls for a copy loop at -Os (exp209's shell is built for
// size, to fit in one flash sector).
void *memcpy(void *d, const void *s, size_t n) {
    volatile uint8_t *p = d;
    const uint8_t *q = s;
    while (n--) *p++ = *q++;
    return d;
}

static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void compress(uint32_t h[8], const uint8_t *b) {
    uint32_t w[64];
    for (int t = 0; t < 16; t++)
        w[t] = (uint32_t)b[4 * t] << 24 | (uint32_t)b[4 * t + 1] << 16 | (uint32_t)b[4 * t + 2] << 8 | b[4 * t + 3];
    for (int t = 16; t < 64; t++) {
        uint32_t s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
        uint32_t s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
        w[t] = w[t - 16] + s0 + w[t - 7] + s1;
    }
    uint32_t a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int t = 0; t < 64; t++) {
        uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[t] + w[t];
        uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
    }
    h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

// Any length. HASH's interface only ever asks for multiples of 64, which
// pad with one block of their own; exp209 asks for kernel.bin's 60 bytes.
void sha256(const uint8_t *in, uint32_t len, uint8_t out[32]) {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint32_t i = 0;
    for (; i + 64 <= len; i += 64) compress(h, in + i);
    uint8_t pad[128] = {0};
    uint32_t r = len - i;
    for (uint32_t j = 0; j < r; j++) pad[j] = in[i + j];
    pad[r] = 0x80;
    uint32_t n = r < 56 ? 64 : 128;
    uint64_t bits = (uint64_t)len * 8;
    for (int k = 0; k < 8; k++) pad[n - 1 - k] = (uint8_t)(bits >> (8 * k));
    compress(h, pad);
    if (n == 128) compress(h, pad + 64);
    for (int k = 0; k < 8; k++)
        for (int j = 0; j < 4; j++) out[4 * k + j] = (uint8_t)(h[k] >> (24 - 8 * j));
}
