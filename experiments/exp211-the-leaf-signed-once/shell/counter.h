// SPDX-License-Identifier: Apache-2.0
//
// exp211 — the leaf counter, in NOR flash. Pure: the includer supplies
//
//   uint32_t flash_word(uint32_t off)              read the word at off
//   void flash_erase_sector(uint32_t off)          4096 bytes back to all ones
//   void flash_program_word(uint32_t off, uint32_t v)
//                                                  clear the bits of the word
//                                                  at off that are 0 in v
//
// — the bootrom's flash functions on the chip, a RAM array on the RTL, and a
// fake that tears writes on the host (host/countertest.c). model/MssCounter.tla
// is this file's design, "unary", against power cuts at every step.
//
// Three sectors, far from any firmware image (exp181's record is at 3 MiB;
// this is at 3.5), so that flashing a UF2 again does not touch them:
//
//   CTR_MARK   word 0: CTR_MAGIC once formatted
//   CTR_CLAIM  page i, word 0: leaf i claimed — cleared BEFORE leaf i is signed
//   CTR_DONE   page i, word 0: leaf i signed and its signature verified
//
// Each word is programmed at most once and only ever loses bits, so every
// word reads one of two ways that matter: all ones (free), or anything else
// (used). A program cut short leaves some bits cleared, which reads as used:
// a leaf can be wasted by a power cut, never handed out twice. Each word sits
// in a page of its own, so no page is programmed twice.
#pragma once
#include <stdint.h>

#define CTR_LEAVES 16
#define CTR_FREE   0xffffffffu
#define CTR_MAGIC  0x4d535302u                      // "MSS", 2: this layout
#define CTR_MARK   0x00380000u                      // offsets from the start of flash
#define CTR_CLAIM  (CTR_MARK + 0x1000u)
#define CTR_DONE   (CTR_MARK + 0x2000u)
#define CTR_PAGE   256u

enum { CTR_SIGN = 0, CTR_EXHAUSTED, CTR_CORRUPT, CTR_UNWRITTEN };

struct ctr { uint32_t used, done, wasted; };

uint32_t flash_word(uint32_t off);
void flash_erase_sector(uint32_t off);
void flash_program_word(uint32_t off, uint32_t v);

static inline uint32_t ctr_claim_at(uint32_t i) { return CTR_CLAIM + CTR_PAGE * i; }
static inline uint32_t ctr_done_at(uint32_t i) { return CTR_DONE + CTR_PAGE * i; }

// A board that has never run this, or whose marker is not whole: erase all
// three, the marker's sector first, and write the marker last. A cut anywhere
// in here leaves no whole marker, so the next boot formats again; nothing has
// been claimed yet to lose.
static inline void ctr_format(void) {
    if (flash_word(CTR_MARK) == CTR_MAGIC) return;
    flash_erase_sector(CTR_MARK);
    flash_erase_sector(CTR_CLAIM);
    flash_erase_sector(CTR_DONE);
    flash_program_word(CTR_MARK, CTR_MAGIC);
}

// What the flash says: c->used leaves claimed, the claimed ones a prefix;
// c->done of them confirmed; c->wasted claimed and never confirmed. A claim
// after a free slot, or a confirmation without a claim, is not something
// this code writes: CTR_CORRUPT, and nothing is signed.
static inline uint32_t ctr_read(struct ctr *c) {
    c->used = c->done = c->wasted = 0;
    if (flash_word(CTR_MARK) != CTR_MAGIC) return CTR_CORRUPT;
    uint32_t gap = 0;
    for (uint32_t i = 0; i < CTR_LEAVES; i++) {
        uint32_t claimed = flash_word(ctr_claim_at(i)) != CTR_FREE;
        uint32_t done = flash_word(ctr_done_at(i)) != CTR_FREE;
        if (claimed) {
            if (gap) return CTR_CORRUPT;
            c->used++;
            if (done) c->done++;
            else c->wasted++;
        } else {
            gap = 1;
            if (done) return CTR_CORRUPT;
        }
    }
    return c->used == CTR_LEAVES ? CTR_EXHAUSTED : CTR_SIGN;
}

// Claim leaf c->used, and read it back: only a claim the flash shows may be
// signed under. CTR_SIGN: sign leaf c->used now, and nothing before this.
static inline uint32_t ctr_claim(const struct ctr *c) {
    flash_program_word(ctr_claim_at(c->used), 0);
    return flash_word(ctr_claim_at(c->used)) != CTR_FREE ? CTR_SIGN : CTR_UNWRITTEN;
}

// The signature of leaf i was made and verified.
static inline void ctr_confirm(uint32_t i) { flash_program_word(ctr_done_at(i), 0); }

// One boot, up to the signing: format if needed, read, claim. CTR_SIGN with
// c->used the leaf to sign; anything else, sign nothing.
static inline uint32_t ctr_begin(struct ctr *c) {
    ctr_format();
    uint32_t s = ctr_read(c);
    if (s != CTR_SIGN) return s;
    return ctr_claim(c);
}
