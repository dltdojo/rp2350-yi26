// SPDX-License-Identifier: Apache-2.0
//
// exp211 — the Pico 2: HASH on the SHA-256 block (tools/hazard3/shell/
// sha_chip.h), the counter in the board's own flash through the bootrom
// (flash_rom.S), and the LED:
//
//   steady                working — or, after a minute, hung in a flash
//                         operation (XIP not back)
//   fast, about 6 s       the window: leaf claimed, not yet signed
//   slow, forever         this boot signed a leaf and the verifier accepted it
//   N flashes, pause      refused: every leaf used; N = 1 + the leaves
//                         claimed and never confirmed
//   fast, forever         refused or failed: the counter is corrupt, a claim
//                         did not read back, a kernel's hash, the signer,
//                         the verifier, or a trap in the shell

#include "board.h"
#include "led.h"
#include "sha_chip.h"

// The bootrom's function table (RP2350 datasheet 5.4, embassy-rp's
// rom_data/rp235x.rs): its version byte, and the lookup function's address
// at 0x7df8 on A1 (32 bits) or 0x7dfa from A2 (16 bits).
#define ROM_VERSION   (*(volatile uint8_t *)0x00000013u)
#define RT_FLAG_RISCV 0x0001u
#define XIP_BASE      0x10000000u

typedef uint32_t (*rom_lookup_fn)(uint32_t code, uint32_t mask);

static uint32_t rom_fn(char a, char b) {
    uint32_t f = ROM_VERSION == 1 ? *(volatile uint32_t *)0x00007df8u : *(volatile uint16_t *)0x00007dfau;
    return ((rom_lookup_fn)f)((uint32_t)(uint8_t)a | (uint32_t)(uint8_t)b << 8, RT_FLAG_RISCV);
}

struct flash_call { uint32_t connect, exit_xip, op, a0, a1, a2, a3, flush, enter_xip; };

extern const uint32_t flash_rom_call[], flash_rom_call_end[];
static uint32_t ram_call[32];          // flash_rom_call, copied to SRAM
static uint8_t page[256] __attribute__((aligned(4)));
static struct flash_call call;
static uint32_t fn_erase, fn_program;

void board_init(void) {
    led_init();
    sha_chip_init();
    call.connect = rom_fn('I', 'F');
    call.exit_xip = rom_fn('E', 'X');
    call.flush = rom_fn('F', 'C');
    call.enter_xip = rom_fn('C', 'X');
    fn_erase = rom_fn('R', 'E');
    fn_program = rom_fn('R', 'P');
    if (!call.connect || !call.exit_xip || !call.flush || !call.enter_xip || !fn_erase || !fn_program ||
        flash_rom_call_end - flash_rom_call > (int)(sizeof ram_call / 4))
        led_verdict(0);
    for (uint32_t i = 0; i < (uint32_t)(flash_rom_call_end - flash_rom_call); i++) ram_call[i] = flash_rom_call[i];
}

static void flash_op(uint32_t op, uint32_t a0, uint32_t a1, uint32_t a2, uint32_t a3) {
    call.op = op, call.a0 = a0, call.a1 = a1, call.a2 = a2, call.a3 = a3;
    ((void (*)(struct flash_call *))ram_call)(&call);
}

uint32_t flash_word(uint32_t off) { return *(volatile uint32_t *)(XIP_BASE + off); }

// One 4096-byte sector; no larger block erase (block size 1 << 31, as
// embassy-rp passes it).
void flash_erase_sector(uint32_t off) { flash_op(fn_erase, off, 4096, 1u << 31, 0); }

// The page holding the word, all ones except the word: a program clears only
// the 0 bits, so the rest of the page is untouched.
void flash_program_word(uint32_t off, uint32_t v) {
    for (uint32_t i = 0; i < sizeof page; i++) page[i] = 0xff;
    uint32_t at = off & 0xffu;
    page[at] = v, page[at + 1] = v >> 8, page[at + 2] = v >> 16, page[at + 3] = v >> 24;
    flash_op(fn_program, off & ~0xffu, (uint32_t)page, sizeof page, 0);
}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) { return sha_hw(src, len, dst); }

// About six seconds of fast blinking, then steady again while it signs.
void board_window(uint32_t leaf) {
    (void)leaf;
    __asm__ volatile ("csrwi mcountinhibit, 4");
    for (uint32_t i = 0; i < 16; i++) {
        REG(SIO_OUT_CLR) = LED;
        wait(1);
        REG(SIO_OUT_SET) = LED;
        wait(1);
    }
}

void board_report(uint32_t outcome, const struct ctr *c, uint32_t leaf) {
    (void)leaf;
    if (outcome == OUT_SIGNED) led_verdict(1);
    if (outcome == OUT_EXHAUSTED) led_count(1 + c->wasted);
    led_verdict(0);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_verdict(0);
}
