// SPDX-License-Identifier: Apache-2.0
//
// exp226 — the Pico 2: exp225's shell and kernel, unchanged, with a USB port.
//
// exp225's shell calls four functions to show what it found; this file is a
// second set of them. Everything else on the chip — the proved kernel, the
// four checks, the lives — is exp225's own source, compiled in as it is.
//
//   board_init   the LED on; then clk_usb and the USB controller
//                (tools/hazard3/shell/usb_chip.c). A step that does not finish
//                is an error on the LED, forever.
//   board_play   the life goes out over USB; the LED says only how far the host
//                has got with the device, for as long as the life lasts.
//   board_fail   exp225's check 1 to 4 as an error on the LED, then the stage,
//                in turn, and over USB a FAIL line, forever.
//
// The LED is the debug channel here, so it says one thing at a time, in one
// shape a person can count (revision 2: revision 1 played the life and showed
// the stage between lives, and on a board it could not be read):
//
//   N flashes, 3 s dark, repeated      the stage: N = 1 nothing from the host,
//                                      2 bus reset, 3 a SETUP packet arrived,
//                                      4 the host took a packet, 5 addressed,
//                                      6 configured, 7 a page opened the port
//   2 s on, then N flashes, 3 s dark   an error: 1-4 exp225's checks, 5 XOSC,
//                                      6 PLL_USB, 7 clk_usb not enabled or not
//                                      48 MHz against the crystal, 8 the
//                                      controller's reset, 9 clk_sys would not
//                                      move onto PLL_USB (revision 4)
//
// Revision 3 split stage 2 in three after round 2 stopped there, and measures
// clk_usb before using it. Revision 4 moves clk_sys onto PLL_USB too (see
// usb_chip.c), and after an error shows the stage as well, in turn.
//
// The long light first is what makes an error not a stage.
//
// While a page holds the port open (DTR), it gets a line per life and a
// status line about once a second:
//
//   LIFE round minstret gen1 gen256 centre-column           as the RTL prints it
//   exp226 usb=… setups=… stalls=… dropped=… errors=… ref=… sys=… xosc=… pll=… usb_khz=… sys_khz=… sys48_khz=… ref_khz=… sof_khz=… lives=… minstret=…
//
// usb_khz, sys_khz and ref_khz are the chip's frequency counter against the
// crystal; sof_khz is clk_sys counted again against the host's 1 ms frames —
// the first measurements of the clock led.h assumes. ref, sys, xosc and pll are
// the clock registers as the bootrom left them, read before anything changed.

#include "board.h"
#include "led.h"
#include "usb_chip.h"
#include "usbdev.h"

#define CENTRE 16

// led.h's one-bit verdict is not used here; a life is not a verdict.
static void (*const unused_blink)(uint32_t) __attribute__((unused)) = blink;

static uint32_t lives, last_instret, last_status, sof_frame, sof_cycle, sof_khz;

// led.h's unit, about 0.18 s, in cycles of the clk_sys this board runs at:
// led.h's assumption until the clock is moved, then the measured one.
static uint32_t unit;   // set in board_init: the shell has no initialised data

// ---------- text, without a C library -----------------------------------------

static char line[192];
static uint32_t at;

static void put(const char *s) { while (*s && at < sizeof line - 2) line[at++] = *s++; }

static void put_hex(uint32_t v) {
    put(" ");
    for (int i = 28; i >= 0; i -= 4) line[at < sizeof line - 2 ? at++ : at] = "0123456789abcdef"[(v >> i) & 15];
}

static void put_dec(uint32_t v) {
    char d[11];
    int n = 0;
    do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) line[at < sizeof line - 2 ? at++ : at] = d[--n];
}

static void field(const char *name, uint32_t v) { put(" "); put(name); put("="); put_dec(v); }
static void field_hex(const char *name, uint32_t v) {
    put(" "); put(name); put("=");
    for (int i = 28; i >= 0; i -= 4) line[at < sizeof line - 2 ? at++ : at] = "0123456789abcdef"[(v >> i) & 15];
}

static void send(void) {
    line[at++] = '\r';
    line[at++] = '\n';
    if (usbdev.dtr) usbdev_write(line, at);
    at = 0;
}

static void status(void) {
    put("exp226");
    field("usb", usbdev.stage);
    field("setups", usbdev.setups);
    field("stalls", usbdev.stalls);
    field("dropped", usbdev.dropped);
    field("errors", usb_boot.sie_errors);
    field_hex("ref", usb_boot.clk_ref_ctrl);
    field_hex("sys", usb_boot.clk_sys_ctrl);
    field_hex("xosc", usb_boot.xosc_status);
    field_hex("pll", usb_boot.pll_usb_cs);
    field("usb_khz", usb_boot.usb_khz);
    field("sys_khz", usb_boot.sys_khz);
    field("sys48_khz", usb_boot.sys48_khz);
    field("ref_khz", usb_boot.ref_khz);
    field("sof_khz", sof_khz);
    field("lives", lives);
    field("minstret", last_instret);
    send();
}

// ---------- waiting, with the USB answered ------------------------------------

// clk_sys against the host's frames: mcycle over 500 of them.
static void measure(void) {
    if (usbdev.stage < USBDEV_CONFIGURED) return;
    uint32_t f = usb_frame(), c = csrr(mcycle);
    if (!sof_cycle) { sof_frame = f; sof_cycle = c; return; }
    uint32_t frames = (f - sof_frame) & 0x7ffu;
    if (frames >= 500) {
        sof_khz = (c - sof_cycle) / frames;
        sof_frame = f;
        sof_cycle = c;
    }
}

static void pwait(uint32_t cycles) {
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < cycles) {
        usb_poll();
        measure();
        if (csrr(mcycle) - last_status > 5 * unit) {
            last_status = csrr(mcycle);
            status();
        }
    }
}

static void flash(uint32_t on, uint32_t off) {
    REG(SIO_OUT_SET) = LED;
    pwait(on);
    REG(SIO_OUT_CLR) = LED;
    pwait(off);
}

// One count on the LED: 2 s on first if it is an error, then n flashes of
// about 0.36 s, then 3 s dark.
static void count(uint32_t n, int error) {
    if (error) flash(11 * unit, 4 * unit);
    for (uint32_t i = 0; i < n; i++) flash(2 * unit, 2 * unit);
    pwait(16 * unit);
}

// Before USB is up there is nothing to poll: the same shape, with led.h's wait.
__attribute__((noreturn)) static void error_forever(uint32_t n) {
    __asm__ volatile ("csrwi mcountinhibit, 4");
    for (;;) {
        REG(SIO_OUT_SET) = LED;
        wait(11);
        REG(SIO_OUT_CLR) = LED;
        wait(4);
        for (uint32_t i = 0; i < n; i++) {
            REG(SIO_OUT_SET) = LED;
            wait(2);
            REG(SIO_OUT_CLR) = LED;
            wait(2);
        }
        wait(16);
    }
}

// ---------- the four calls exp225's shell makes -------------------------------

void board_init(void) {
    unit = UNIT;
    led_init();
    int step = usb_clock_start();
    if (!step) {
        unit = (usb_boot.sys48_khz ? usb_boot.sys48_khz : 48000u) * 180u;
        step = usb_start("exp226 the shell that speaks", "226");
    }
    if (step) error_forever((uint32_t)step);
    // A host that is there finds the device in its first seconds: be there to
    // answer, before the shell goes on to the kernel and the checks.
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < 16 * unit && usbdev.stage < USBDEV_CONFIGURED) usb_poll();
}

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    last_instret = instret;
    REG(SIO_OUT_CLR) = LED;

    uint32_t col = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((life[g] >> CENTRE) & 1) << g;
    put("LIFE");
    put_hex(round);
    put_hex(instret);
    put_hex(life[0]);
    put_hex(life[N - 1]);
    put_hex(col);
    send();
    lives = round + 1;

    // As long as exp225 would have played it: 256 beats of two units.
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < N * 2 * unit) count(usbdev.stage + 1u, 0);
}

void board_fail(uint32_t check, uint32_t got) {
    REG(SIO_OUT_CLR) = LED;
    for (;;) {
        count(check, 1);
        count(usbdev.stage + 1u, 0);   // and how far USB got, in between
        put("FAIL");
        put_hex(check);
        put_hex(got);
        send();
    }
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
