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
//                is 5 to 9 flashes and a pause, forever, as led.h counts.
//   board_play   before each life: how far the host got with the device, as
//                quick flashes — 1 bus reset, 2 addressed, 3 configured,
//                4 a page opened the port — then the life, as exp225 plays it.
//                Every wait keeps the USB answered.
//   board_fail   exp225's check 1 to 4 as that many flashes, and over USB a
//                FAIL line, forever.
//
// While a page holds the port open (DTR), it gets a line per life and a
// status line about once a second:
//
//   LIFE round minstret gen1 gen256 centre-column           as the RTL prints it
//   exp226 usb=… setups=… stalls=… dropped=… ref=… sys=… xosc=… pll=… sys_khz=… lives=… minstret=…
//
// sys_khz is clk_sys measured against the host's 1 ms frames — the first time
// the clock led.h assumes is measured — and ref, sys, xosc and pll are the
// clock registers as the bootrom left them, read before anything changed.

#include "board.h"
#include "led.h"
#include "usb_chip.h"
#include "usbdev.h"

#define CENTRE 16

// led.h's one-bit verdict is not used here; a life is not a verdict.
static void (*const unused_blink)(uint32_t) __attribute__((unused)) = blink;

static uint32_t lives, last_instret, last_status, sof_frame, sof_cycle, sys_khz;

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
    field_hex("ref", usb_boot.clk_ref_ctrl);
    field_hex("sys", usb_boot.clk_sys_ctrl);
    field_hex("xosc", usb_boot.xosc_status);
    field_hex("pll", usb_boot.pll_usb_cs);
    field("sys_khz", sys_khz);
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
        sys_khz = (c - sof_cycle) / frames;
        sof_frame = f;
        sof_cycle = c;
    }
}

static void pwait(uint32_t cycles) {
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < cycles) {
        usb_poll();
        measure();
        if (csrr(mcycle) - last_status > 5 * UNIT) {
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

// ---------- the four calls exp225's shell makes -------------------------------

void board_init(void) {
    led_init();
    int step = usb_clock_start();
    if (!step) step = usb_start("exp226 the shell that speaks", "226");
    if (step) led_count((uint32_t)step);
}

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    last_instret = instret;
    REG(SIO_OUT_CLR) = LED;
    if (round == 0)   // give a host that is there a few seconds to find the device
        for (uint32_t i = 0; i < 30 && usbdev.stage < USBDEV_CONFIGURED; i++) pwait(UNIT);
    pwait(3 * UNIT);
    for (uint32_t i = 0; i < usbdev.stage; i++) flash(UNIT / 3, UNIT / 3);
    pwait(5 * UNIT);

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

    for (uint32_t g = 0; g < N; g++) {
        if ((life[g] >> CENTRE) & 1) flash(UNIT, UNIT);
        else pwait(2 * UNIT);
    }
}

void board_fail(uint32_t check, uint32_t got) {
    REG(SIO_OUT_CLR) = LED;
    for (;;) {
        for (uint32_t i = 0; i < check; i++) flash(2 * UNIT, 2 * UNIT);
        put("FAIL");
        put_hex(check);
        put_hex(got);
        send();
        pwait(10 * UNIT);
    }
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
