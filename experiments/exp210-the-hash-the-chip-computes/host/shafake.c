// SPDX-License-Identifier: Apache-2.0
//
// exp210 — sha_hw.h, compiled for this machine against a fake SHA-256 block.
//
//   shafake HEXDIGEST < INPUT     prints two lines:
//     the message the block was fed, in hex, as the block would read it
//     the 32 bytes sha_hw wrote, in hex, and whether it returned ok
//
// The fake is the datasheet's description as rp-pac carries it, and nothing
// more — it does not compute SHA-256. host/shatest.py compares the message it
// was fed with the padded message SHA-256 defines, and hands it the digest to
// put in SUM0..7, so what is tested is everything sha_hw.h does around the
// compression: the order and form of the words, the padding, the waits, and
// how the sums become bytes. Behaviour the fake encodes, each from rp-pac's
// field descriptions:
//
//   START       clears the counters; WDATA_RDY and SUM_VLD go high
//   WDATA       with BSWAP set, the first byte of the message is the low byte
//               of the word written; a write while WDATA_RDY is low sets ERR
//               and is dropped
//   SUM_VLD     low from the first word of a block until the block is done
//   a block     after its 16th word, WDATA_RDY stays low for BUSY reads of
//               CSR, as the compression takes cycles; then it and SUM_VLD
//               go high
//   SUM0..7     garbage while SUM_VLD is low

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUSY 3

static uint32_t csr, words, busy, started, sums[8];
static uint8_t fed[1 << 20];
static uint32_t nfed;

static uint32_t sha_rd(uint32_t off);
static void sha_wr(uint32_t off, uint32_t v);

#include "sha_hw.h"

static uint32_t sha_rd(uint32_t off) {
    if (off == SHA_CSR) {
        if (busy && --busy == 0) csr |= SHA_WDATA_RDY | SHA_SUM_VLD;
        return csr;
    }
    if (off >= SHA_SUM0 && off < SHA_SUM0 + 32) return (csr & SHA_SUM_VLD) ? sums[(off - SHA_SUM0) / 4] : 0xdeadbeef;
    fprintf(stderr, "read of an unknown register %#x\n", off);
    exit(2);
}

static void sha_wr(uint32_t off, uint32_t v) {
    if (off == SHA_CSR) {
        if (v & SHA_ERR) csr &= ~SHA_ERR;
        csr = (csr & ~(SHA_BSWAP | (3u << 8))) | (v & (SHA_BSWAP | (3u << 8)));
        if (v & SHA_START) {
            csr |= SHA_WDATA_RDY | SHA_SUM_VLD;
            words = busy = nfed = 0;
            started = 1;
        }
        return;
    }
    if (off == SHA_WDATA) {
        if (!started) {
            fprintf(stderr, "WDATA written before START\n");
            exit(2);
        }
        if (!(csr & SHA_WDATA_RDY)) {
            csr |= SHA_ERR;
            return;
        }
        for (int i = 0; i < 4; i++)
            fed[nfed++] = (csr & SHA_BSWAP) ? (uint8_t)(v >> (8 * i)) : (uint8_t)(v >> (24 - 8 * i));
        csr &= ~SHA_SUM_VLD;
        if (++words % 16 == 0) {
            csr &= ~SHA_WDATA_RDY;
            busy = BUSY;
        }
        return;
    }
    fprintf(stderr, "write to an unknown register %#x\n", off);
    exit(2);
}

int main(int argc, char **argv) {
    if (argc != 2 || strlen(argv[1]) != 64) {
        fprintf(stderr, "usage: shafake HEXDIGEST < INPUT\n");
        return 2;
    }
    for (int i = 0; i < 8; i++) {
        char w[9] = {0};
        memcpy(w, argv[1] + 8 * i, 8);
        sums[i] = (uint32_t)strtoul(w, NULL, 16);
    }
    static uint32_t in[1 << 16];
    size_t len = fread(in, 1, sizeof in, stdin);
    csr = SHA_BSWAP | (2u << 8) | SHA_WDATA_RDY | SHA_SUM_VLD;   // the reset value
    uint8_t out[32];
    int ok = sha_hw((const uint8_t *)in, (uint32_t)len, out);
    for (uint32_t i = 0; i < nfed; i++) printf("%02x", fed[i]);
    printf("\n");
    for (int i = 0; i < 32; i++) printf("%02x", out[i]);
    printf(" %s\n", ok ? "ok" : "error");
    return 0;
}
