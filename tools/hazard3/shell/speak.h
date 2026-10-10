// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a shell that speaks over USB as well as on the LED:
// exp226's board layer, everything in it but how a life is shown, so that a
// second experiment builds on it instead of copying it (exp227 is that one).
// Included by one file of each shell, its board_chip.c, after led.h, like
// led.h; so everything here is static, and that file defines first
//
//   SPEAK_NAME      the first word of the status line, the experiment ("exp226")
//   SPEAK_PRODUCT   the USB product string
//   SPEAK_SERIAL    the USB serial, the experiment's number
//
// What it gives that file:
//
//   board_init()             one of the four calls exp225's shell makes: the
//                            LED on, then clk_usb, clk_sys and the controller
//                            (usb_chip.c); a step that does not finish is an
//                            error on the LED, forever. Then a few seconds of
//                            answering a host that is there.
//   speak_fail(check, got)   board_fail's body: the check as an error count,
//                            the USB stage in between, a FAIL line, forever;
//                            forced inline, so a one-line board_fail calling
//                            it compiles to what it was when it was the body
//   put, put_hex, put_dec, field, field_hex, send
//                            a line of text without a C library, sent while a
//                            page holds the port open (DTR) and dropped whole
//                            otherwise
//   pwait(cycles)            a wait that answers USB, measures clk_sys against
//                            the host's frames, and sends a status line about
//                            once a second
//   flash, count(n, error)   the LED's two shapes: N flashes and 3 s dark, and
//                            the same after 2 s of light for an error
//   unit                     led.h's unit, about 0.18 s, in cycles of the clk_sys
//                            the board runs at once board_init has moved it
//
// The LED is the debug channel, so it says one thing at a time, in one shape a
// person can count:
//
//   N flashes, 3 s dark, repeated      the stage: N = 1 nothing from the host,
//                                      2 bus reset, 3 a SETUP packet arrived,
//                                      4 the host took a packet, 5 addressed,
//                                      6 configured, 7 a page opened the port
//   2 s on, then N flashes, 3 s dark   an error: 1-4 exp225's checks, 5 XOSC,
//                                      6 PLL_USB, 7 clk_usb not enabled or not
//                                      48 MHz against the crystal, 8 the
//                                      controller's reset, 9 clk_sys would not
//                                      move onto PLL_USB
//
// The long light first is what makes an error not a stage.
//
// The status line, about once a second while the port is open:
//
//   NAME usb=… setups=… stalls=… dropped=… errors=… ref=… sys=… xosc=… pll=… usb_khz=… sys_khz=… sys48_khz=… ref_khz=… sof_khz=… lives=… minstret=…
//
// usb_khz, sys_khz and ref_khz are the chip's frequency counter against the
// crystal; sof_khz is clk_sys counted again against the host's 1 ms frames.
// ref, sys, xosc and pll are the clock registers as the bootrom left them,
// read before anything changed. `lives` and `last_instret` are the including
// file's to keep up to date.
//
// This file was exp226's board_chip.c, moved, and exp226's UF2 is byte for
// byte what it was: check.sh holds it to the committed hash.
#pragma once
#include "board.h"
#include "led.h"
#include "usb_chip.h"
#include "usbdev.h"

// led.h's one-bit verdict is not used here; a life is not a verdict.
static void (*const unused_blink)(uint32_t) __attribute__((unused)) = blink;

static uint32_t lives, last_instret, last_status, sof_frame, sof_cycle, sof_khz;

// led.h's unit, about 0.18 s, in cycles of the clk_sys this board runs at:
// led.h's assumption until the clock is moved, then the measured one.
static uint32_t unit;   // set in board_init: the shell has no initialised data

// ---------- text, without a C library -----------------------------------------

static char line[256];   // a status line is at most 252 bytes: 192 cut minstret off (round 4)
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
    put(SPEAK_NAME);
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
        // A count across a gap in the host's frames is not a clock: round 4's
        // last line said 7877451, about 80 s for 500 frames, as if the bus
        // had been suspended. Only a count that could be 1 ms frames is kept.
        uint32_t khz = (c - sof_cycle) / frames;
        if (frames < 1000 && khz < 200000u) sof_khz = khz;
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
        step = usb_start(SPEAK_PRODUCT, SPEAK_SERIAL);
    }
    if (step) error_forever((uint32_t)step);
    // A host that is there finds the device in its first seconds: be there to
    // answer, before the shell goes on to the kernel and the checks.
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < 16 * unit && usbdev.stage < USBDEV_CONFIGURED) usb_poll();
}

__attribute__((noreturn, always_inline)) static inline void speak_fail(uint32_t check, uint32_t got) {
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

