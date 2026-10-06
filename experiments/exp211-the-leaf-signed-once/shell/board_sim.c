// SPDX-License-Identifier: Apache-2.0
//
// exp211 — the same shell on the Hazard3 RTL, booted again and again in one
// simulation. HASH in software, as the RTL harness's handler.c does it; the
// flash a RAM array that keeps its contents from one boot to the next and
// behaves as NOR (an erase sets bits, a program only clears them); and a
// script of what a person does to each boot — nothing, pull the power in
// the window, or pull it in the middle of a flash write, which tears it.
// A "boot" is a jump back to _start, which zeroes the shell's own state and
// nothing else: the flash and the script's place live outside it.
//
//   BOOT n outcome leaf used done wasted    each boot, as it ends
//   CUT_ n step                             the power went in boot n
//   REPT 0                                  the script ran out after a refusal
//   FAUL step mcause                        the shell itself trapped

#include "board.h"
#include "sha256.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

// Far above everything the shell and the region use, in the testbench's
// 16 MiB, and never zeroed by _start.
#define FLASH_ADDR(off) ((volatile uint32_t *)(0x80400000u + (off)))
#define BOOT            (*(volatile uint32_t *)0x80300000u)
#define FORMATTED_FAKE  (*(volatile uint32_t *)0x80300004u)

extern void _start(void) __attribute__((noreturn));

// What a person does to each boot, in order. The testbench's RAM starts at
// zero, which this code treats as a board fresh from the factory would be
// treated: no marker, so format.
enum { RUN, CUT_FORMAT, CUT_WINDOW, CUT_CLAIM };
static const uint32_t SCRIPT[] = {
    CUT_FORMAT,                 // boot 0: the power goes in the first erase
    RUN,                        // boot 1: formats again, signs leaf 0
    CUT_WINDOW,                 // boot 2: claims leaf 1, the power goes before it is signed
    CUT_CLAIM,                  // boot 3: the power goes while leaf 2's claim is written
    RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN, RUN,   // leaves 3 to 15
    RUN,                        // boot 17: every leaf used — refused
};
#define NSCRIPT (sizeof SCRIPT / sizeof SCRIPT[0])

static uint32_t act(void) { return BOOT < NSCRIPT ? SCRIPT[BOOT] : RUN; }

__attribute__((noreturn)) static void cut(uint32_t step) {
    IO_PRINT_U32 = 0x4355545fu;   // "CUT_"
    IO_PRINT_U32 = BOOT;
    IO_PRINT_U32 = step;
    BOOT = BOOT + 1;
    _start();
}

void board_init(void) {}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

uint32_t flash_word(uint32_t off) { return *FLASH_ADDR(off); }

void flash_erase_sector(uint32_t off) {
    for (uint32_t i = 0; i < 1024; i++) {
        // Cut in the middle of the first erase: half of it done.
        if (act() == CUT_FORMAT && i == 512) cut(2);
        FLASH_ADDR(off)[i] = 0xffffffffu;
    }
}

void flash_program_word(uint32_t off, uint32_t v) {
    if (act() == CUT_CLAIM && off >= CTR_CLAIM && off < CTR_DONE) {
        *FLASH_ADDR(off) &= v | 0xffff0000u;   // the low half written, then the cut
        cut(2);
    }
    *FLASH_ADDR(off) &= v;
}

void board_window(uint32_t leaf) {
    (void)leaf;
    if (act() == CUT_WINDOW) cut(3);
}

void board_report(uint32_t outcome, const struct ctr *c, uint32_t leaf) {
    IO_PRINT_U32 = 0x424f4f54u;   // "BOOT"
    IO_PRINT_U32 = BOOT;
    IO_PRINT_U32 = outcome;
    IO_PRINT_U32 = leaf;
    IO_PRINT_U32 = c->used;
    IO_PRINT_U32 = c->done;
    IO_PRINT_U32 = c->wasted;
    if (outcome == OUT_EXHAUSTED || BOOT + 1 >= NSCRIPT) {
        IO_PRINT_U32 = 0x52455054u;   // "REPT"
        IO_PRINT_U32 = outcome;
        IO_EXIT = outcome != OUT_EXHAUSTED;
        for (;;) {}
    }
    BOOT = BOOT + 1;
    _start();
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
