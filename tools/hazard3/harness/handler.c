// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — what a trap from the payload means.
//
// The sig.golf interface, the same two calls as lean/Rv32/Machine.lean's
// `syscall`, and everything else a fault:
//
//   ecall, t0 = 1   HALT: the payload's a0 is its result
//   ecall, t0 = 0   HASH: SHA-256 of a1 bytes at a0, 32 bytes written at a2,
//                   back to the instruction after the ecall. The arguments are
//                   checked as the model checks them — a1 a multiple of 64, a0
//                   and a2 word-aligned, both inside the region — and anything
//                   else is a fault. The hash is computed here in software; on
//                   the chip it will be the SHA-256 block (exp210).
//   anything else   a fault, reported with mcause, mepc and mtval
//
// Results go to the testbench's print port as one tagged line of hex words,
// which tools/hazard3/sim.sh reads:
//
//   HALT  code instret cycles
//   FAULT mcause mepc mtval instret

#include <stdint.h>

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

#define TAG_HALT  0x48414c54u   // "HALT"
#define TAG_FAULT 0x4641554cu   // "FAUL"

#define REGION      0x80010000u
#define REGION_SIZE 0x00010000u

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))

// --- SHA-256, FIPS 180-4 ----------------------------------------------------

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
void *memset(void *d, int c, unsigned n) {
    volatile uint8_t *p = d;
    while (n--) *p++ = (uint8_t)c;
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

// `len` a multiple of 64, as the interface requires: the padding is one
// block of its own.
static void sha256(const uint8_t *in, uint32_t len, uint8_t out[32]) {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    for (uint32_t i = 0; i < len; i += 64) compress(h, in + i);
    uint8_t pad[64] = {0x80};
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) pad[63 - i] = (uint8_t)(bits >> (8 * i));
    compress(h, pad);
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 4; j++) out[4 * i + j] = (uint8_t)(h[i] >> (24 - 8 * j));
}

static int inside(uint32_t a, uint32_t n) {
    return a >= REGION && n <= REGION_SIZE && a - REGION <= REGION_SIZE - n;
}

static void halt(uint32_t code) {
    IO_EXIT = code;
    for (;;) {}
}

void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause);
    uint32_t instret = csrr(minstret);
    uint32_t cycles = csrr(mcycle);
    if (cause == 8 && x[5] == 0) {
        uint32_t src = x[10], len = x[11], dst = x[12];
        if (len % 64 == 0 && src % 4 == 0 && dst % 4 == 0 && inside(src, len) && inside(dst, 32)) {
            sha256((const uint8_t *)src, len, (uint8_t *)dst);
            csrw(mepc, csrr(mepc) + 4);
            return;
        }
    }
    if (cause == 8 && x[5] == 1) {
        IO_PRINT_U32 = TAG_HALT;
        IO_PRINT_U32 = x[10];
        IO_PRINT_U32 = instret;
        IO_PRINT_U32 = cycles;
        halt(x[10] == 0 ? 0 : 1);
    }
    IO_PRINT_U32 = TAG_FAULT;
    IO_PRINT_U32 = cause;
    IO_PRINT_U32 = csrr(mepc);
    IO_PRINT_U32 = csrr(mtval);
    IO_PRINT_U32 = instret;
    halt(2);
}
