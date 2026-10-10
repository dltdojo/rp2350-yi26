// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the RP2350's USB controller under usbdev.c: its clock,
// its registers, and a poll a shell calls whenever it waits. exp226 wrote it.
//
// Every register write here is one embassy-rp 0.10 makes, in the order it
// makes it (src/usb.rs and src/clocks.rs), with addresses and bits from
// rp-pac 7.0.0's rp235x tables. Nothing in this file has a simulator: the
// Hazard3 RTL has no USB controller, so the first test of it is a board.
//
// No interrupts: the shell runs with none, so usb_poll() is called from every
// wait loop. A control transfer has the host retrying for hundreds of
// milliseconds; a poll every few milliseconds is plenty.
//
// The system clock is not touched. The bootrom's clk_sys and clk_ref stay as
// they are, so led.h's beat is what it was; only clk_usb is new: XOSC (12 MHz
// on a Pico 2) into PLL_USB, 12 x 120 / 6 / 5 = 48 MHz, as embassy-rp
// configures it. Each wait for the hardware is bounded and, past its bound,
// returns the step that did not finish.

#include <stdint.h>

#include "usb_chip.h"
#include "usbdev.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define SET(a) REG((a) + 0x2000u)   // atomic set alias
#define CLR(a) REG((a) + 0x3000u)   // atomic clear alias

#define RESETS          0x40020000u
#define RESETS_DONE     (RESETS + 0x08u)
#define RESET_PLL_USB   (1u << 15)
#define RESET_USBCTRL   (1u << 28)

#define XOSC_CTRL       0x40048000u
#define XOSC_STATUS     0x40048004u
#define XOSC_STARTUP    0x4004800cu
#define XOSC_STABLE     (1u << 31)

#define PLL_USB         0x40058000u
#define PLL_CS          (PLL_USB + 0x0u)
#define PLL_PWR         (PLL_USB + 0x4u)
#define PLL_FBDIV       (PLL_USB + 0x8u)
#define PLL_PRIM        (PLL_USB + 0xcu)
#define PLL_LOCK        (1u << 31)
#define PWR_PD          (1u << 0)
#define PWR_DSMPD       (1u << 2)
#define PWR_POSTDIVPD   (1u << 3)
#define PWR_VCOPD       (1u << 5)

#define CLOCKS          0x40010000u
#define CLK_REF_CTRL    (CLOCKS + 0x30u)
#define CLK_SYS_CTRL    (CLOCKS + 0x3cu)
#define CLK_USB_CTRL    (CLOCKS + 0x60u)
#define CLK_USB_DIV     (CLOCKS + 0x64u)
#define CLK_ENABLE      (1u << 11)
#define CLK_ENABLED     (1u << 28)
#define FC0_REF_KHZ     (CLOCKS + 0x8cu)
#define FC0_MIN_KHZ     (CLOCKS + 0x90u)
#define FC0_MAX_KHZ     (CLOCKS + 0x94u)
#define FC0_INTERVAL    (CLOCKS + 0x9cu)
#define FC0_SRC         (CLOCKS + 0xa0u)
#define FC0_STATUS      (CLOCKS + 0xa4u)
#define FC0_RESULT      (CLOCKS + 0xa8u)
#define FC0_DONE        (1u << 4)
#define FC0_RUNNING     (1u << 8)
#define FC_CLK_REF      0x08u
#define FC_CLK_SYS      0x09u
#define FC_XOSC         0x05u
#define FC_CLK_USB      0x0bu

#define USB             0x50110000u
#define ADDR_ENDP       (USB + 0x00u)
#define MAIN_CTRL       (USB + 0x40u)
#define SOF_RD          (USB + 0x48u)
#define SIE_CTRL        (USB + 0x4cu)
#define SIE_STATUS      (USB + 0x50u)
#define BUFF_STATUS     (USB + 0x58u)
#define EP_STALL_ARM    (USB + 0x68u)
#define USB_MUXING      (USB + 0x74u)
#define USB_PWR         (USB + 0x78u)

#define ST_SETUP_REC    (1u << 17)
#define ST_BUS_RESET    (1u << 19)
#define ST_ERRORS       ((1u << 24) | (1u << 25) | (1u << 26) | (1u << 27))   // CRC, bit stuff, overflow, timeout

#define DPRAM           0x50100000u
#define EP_IN_CTRL(n)   (DPRAM + 0x08u + 8u * ((n) - 1))    // n >= 1
#define EP_OUT_CTRL(n)  (DPRAM + 0x0cu + 8u * ((n) - 1))
#define IN_BUF(n)       (DPRAM + 0x80u + 8u * (n))
#define OUT_BUF(n)      (DPRAM + 0x84u + 8u * (n))
#define EP0_BUF         (DPRAM + 0x100u)
#define EP1_IN_BUF      0x180u                               // offsets in DPRAM, 64-byte aligned
#define EP1_OUT_BUF     0x1c0u
#define EP2_IN_BUF      0x200u

#define BUF_LEN(n)      ((n) & 0x3ffu)
#define BUF_AVAIL       (1u << 10)
#define BUF_STALL       (1u << 11)
#define BUF_PID         (1u << 13)
#define BUF_FULL        (1u << 15)

#define EPC_ENABLE      (1u << 31)
#define EPC_PER_BUFF    (1u << 29)
#define EPC_BULK        (2u << 26)
#define EPC_INTERRUPT   (3u << 26)

struct usb_boot usb_boot;

static uint8_t in0_busy, out0_busy, out1_armed, in2_busy, configured;
static uint8_t out_data[64];

static int wait_for(uint32_t addr, uint32_t mask) {
    for (uint32_t i = 0; i < 4000000u; i++)
        if ((REG(addr) & mask) == mask) return 1;
    return 0;
}

// The two-step write the controller asks for: everything but AVAILABLE, a
// moment, then AVAILABLE as well.
static void arm(uint32_t buf, uint32_t value) {
    REG(buf) = value;
    __asm__ volatile ("nop; nop; nop; nop");
    REG(buf) = value | BUF_AVAIL;
}

static uint32_t next_pid(uint32_t buf) { return (REG(buf) & BUF_PID) ^ BUF_PID; }

static void copy_in(uint32_t at, const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t w = 0;
        for (uint32_t k = 0; k < 4 && i + k < len; k++) w |= (uint32_t)data[i + k] << (8 * k);
        REG(DPRAM + at + i) = w;
    }
}

// The chip's frequency counter, as pico-sdk's frequency_count_khz uses it.
// The reference is clk_ref, whose frequency nobody here knows — so every
// result is taken against the crystal's, measured the same way: a ratio, in
// which clk_ref cancels.
static uint32_t count_khz(uint32_t src) {
    for (uint32_t i = 0; i < 4000000u && (REG(FC0_STATUS) & FC0_RUNNING); i++) {}
    REG(FC0_REF_KHZ) = 12000;
    REG(FC0_INTERVAL) = 10;
    REG(FC0_MIN_KHZ) = 0;
    REG(FC0_MAX_KHZ) = 0x1ffffffu;
    REG(FC0_SRC) = src;
    if (!wait_for(FC0_STATUS, FC0_DONE)) return 0;
    return REG(FC0_RESULT) >> 5;
}

// raw x 12000 / xosc, in 32 bits: a raw count up to 350 MHz fits.
static uint32_t against_xosc(uint32_t raw, uint32_t xosc) {
    if (!xosc) return 0;
    return raw < 350000u ? raw * 12000u / xosc : raw / xosc * 12000u;
}

int usb_clock_start(void) {
    usb_boot.clk_ref_ctrl = REG(CLK_REF_CTRL);
    usb_boot.clk_sys_ctrl = REG(CLK_SYS_CTRL);
    usb_boot.xosc_status = REG(XOSC_STATUS);
    usb_boot.pll_usb_cs = REG(PLL_CS);

    // PLL_USB is about to be reset. If the bootrom left clk_ref or clk_sys
    // running from it, that would stop the clock this code runs on: stop
    // here and say so instead.
    uint32_t ref = usb_boot.clk_ref_ctrl, sys = usb_boot.clk_sys_ctrl;
    if (((ref & 3u) == 1 && ((ref >> 5) & 3u) == 0) || ((sys & 1u) == 1 && ((sys >> 5) & 7u) == 1))
        return USB_STEP_PLL_IN_USE;

    // XOSC, as embassy-rp's start_xosc: 1-15 MHz range, startup delay for a
    // 12 MHz crystal with a multiplier of 64, enable, wait for STABLE.
    REG(XOSC_STARTUP) = ((12000u * 64u) + 128u) / 256u;
    REG(XOSC_CTRL) = 0x0aa0u | (0xfabu << 12);
    if (!wait_for(XOSC_STATUS, XOSC_STABLE)) return USB_STEP_XOSC;

    // PLL_USB, as embassy-rp's configure_pll with refdiv 1, fbdiv 120, 6, 5.
    SET(RESETS) = RESET_PLL_USB;
    CLR(RESETS) = RESET_PLL_USB;
    if (!wait_for(RESETS_DONE, RESET_PLL_USB)) return USB_STEP_PLL;
    REG(PLL_PWR) = PWR_PD | PWR_VCOPD | PWR_POSTDIVPD | PWR_DSMPD;
    REG(PLL_CS) = 1;
    REG(PLL_FBDIV) = 120;
    REG(PLL_PWR) = PWR_POSTDIVPD | PWR_DSMPD;
    if (!wait_for(PLL_CS, PLL_LOCK)) return USB_STEP_PLL;
    REG(PLL_PRIM) = (6u << 16) | (5u << 12);
    REG(PLL_PWR) = PWR_DSMPD;

    // clk_usb from PLL_USB, divided by 1.
    REG(CLK_USB_DIV) = 1u << 16;
    REG(CLK_USB_CTRL) = CLK_ENABLE | (0u << 5);
    if (!wait_for(CLK_USB_CTRL, CLK_ENABLED)) return USB_STEP_CLK_USB;

    // Measured, not assumed: clk_usb must be 48 MHz against the crystal.
    uint32_t xosc = count_khz(FC_XOSC);
    usb_boot.usb_khz = against_xosc(count_khz(FC_CLK_USB), xosc);
    usb_boot.sys_khz = against_xosc(count_khz(FC_CLK_SYS), xosc);
    usb_boot.ref_khz = against_xosc(count_khz(FC_CLK_REF), xosc);
    if (usb_boot.usb_khz < 47760 || usb_boot.usb_khz > 48240) return USB_STEP_CLK_USB;   // 0.5%
    return 0;
}

int usb_start(const char *product, const char *serial) {
    SET(RESETS) = RESET_USBCTRL;
    CLR(RESETS) = RESET_USBCTRL;
    if (!wait_for(RESETS_DONE, RESET_USBCTRL)) return USB_STEP_CONTROLLER;

    // As embassy-rp's Driver::new and start: the registers and the first 256
    // bytes of DPRAM zeroed, the PHY, VBUS forced present, the controller on
    // (which clears PHY_ISO), EP0 interrupting per buffer, the pull-up.
    for (uint32_t i = 0; i < 0x9cu; i += 4) REG(USB + i) = 0;
    for (uint32_t i = 0; i < 0x100u; i += 4) REG(DPRAM + i) = 0;
    REG(USB_MUXING) = (1u << 0) | (1u << 3);        // TO_PHY, SOFTCON
    REG(USB_PWR) = (1u << 2) | (1u << 3);           // VBUS_DETECT, its override
    REG(MAIN_CTRL) = 1u << 0;                       // CONTROLLER_EN
    usbdev_init(product, serial);
    REG(SIE_CTRL) = (1u << 29) | (1u << 16);        // EP0_INT_1BUF, PULLUP_EN
    return 0;
}

uint32_t usb_frame(void) { return REG(SOF_RD) & 0x7ffu; }

// ---------- what usbdev.c asks of the controller ------------------------------

void usbhw_ep0_in(const uint8_t *data, uint32_t len) {
    if (len) copy_in(EP0_BUF - DPRAM, data, len);
    arm(IN_BUF(0), next_pid(IN_BUF(0)) | BUF_FULL | BUF_LEN(len));
    in0_busy = 1;
}

void usbhw_ep0_out(void) {
    arm(OUT_BUF(0), next_pid(OUT_BUF(0)) | BUF_LEN(USBDEV_EP0_SIZE));
    out0_busy = 1;
}

void usbhw_ep0_stall(void) {
    REG(EP_STALL_ARM) = 3;
    REG(OUT_BUF(0)) = BUF_STALL;
    REG(IN_BUF(0)) = BUF_STALL;
    in0_busy = out0_busy = 0;
}

void usbhw_set_address(uint8_t a) { REG(ADDR_ENDP) = a; }

void usbhw_configure(int on) {
    configured = (uint8_t)on;
    if (!on) {
        REG(EP_IN_CTRL(1)) = 0;
        REG(EP_OUT_CTRL(1)) = 0;
        REG(EP_IN_CTRL(2)) = 0;
        in2_busy = out1_armed = 0;
        return;
    }
    REG(EP_IN_CTRL(1)) = EPC_ENABLE | EPC_PER_BUFF | EPC_INTERRUPT | EP1_IN_BUF;
    REG(EP_OUT_CTRL(1)) = EPC_ENABLE | EPC_PER_BUFF | EPC_BULK | EP1_OUT_BUF;
    REG(EP_IN_CTRL(2)) = EPC_ENABLE | EPC_PER_BUFF | EPC_BULK | EP2_IN_BUF;
    REG(IN_BUF(2)) = BUF_PID;           // flipped before the first packet: DATA0
    REG(OUT_BUF(1)) = 0;
    arm(OUT_BUF(1), BUF_LEN(USBDEV_BULK_SIZE));   // DATA0 expected; what arrives is read and dropped
    in2_busy = 0;
    out1_armed = 1;
}

// ---------- the poll ----------------------------------------------------------

void usb_poll(void) {
    uint32_t st = REG(SIE_STATUS);
    if (st & ST_ERRORS) {
        usb_boot.sie_errors++;
        REG(SIE_STATUS) = st & ST_ERRORS;
    }
    // A reset and the SETUP after it can both be waiting when the shell has
    // been busy: the reset is handled, and the SETUP is kept, not cleared.
    if (st & ST_BUS_RESET) {
        REG(SIE_STATUS) = ST_BUS_RESET;
        REG(BUFF_STATUS) = 0xffffffffu;
        REG(ADDR_ENDP) = 0;
        usbhw_configure(0);
        in0_busy = out0_busy = 0;
        usbdev_reset();
        st = REG(SIE_STATUS);
    }
    if (st & ST_SETUP_REC) {
        uint32_t w0 = REG(DPRAM + 0), w1 = REG(DPRAM + 4);
        uint8_t s[8];
        for (uint32_t k = 0; k < 4; k++) {
            s[k] = (uint8_t)(w0 >> (8 * k));
            s[4 + k] = (uint8_t)(w1 >> (8 * k));
        }
        REG(SIE_STATUS) = ST_SETUP_REC;
        REG(IN_BUF(0)) = 0;              // PID 0, so that the first packet after is DATA1
        REG(OUT_BUF(0)) = 0;
        in0_busy = out0_busy = 0;
        usbdev_setup(s);
        return;
    }
    REG(BUFF_STATUS) = REG(BUFF_STATUS);   // completion is read from AVAILABLE; these are only cleared
    if (in0_busy && !(REG(IN_BUF(0)) & BUF_AVAIL)) {
        in0_busy = 0;
        usbdev_ep0_in_done();
    }
    if (out0_busy && !(REG(OUT_BUF(0)) & BUF_AVAIL)) {
        uint32_t len = REG(OUT_BUF(0)) & 0x3ffu;
        if (len > 64) len = 64;
        for (uint32_t i = 0; i < len; i++) out_data[i] = (uint8_t)(REG(EP0_BUF + (i & ~3u)) >> (8 * (i & 3)));
        out0_busy = 0;
        usbdev_ep0_out_done(out_data, len);
    }
    if (!configured) return;
    if (out1_armed && !(REG(OUT_BUF(1)) & BUF_AVAIL))
        arm(OUT_BUF(1), next_pid(OUT_BUF(1)) | BUF_LEN(USBDEV_BULK_SIZE));
    if (in2_busy && !(REG(IN_BUF(2)) & BUF_AVAIL)) in2_busy = 0;
    if (!in2_busy) {
        uint8_t pkt[USBDEV_BULK_SIZE];
        uint32_t n = usbdev_packet(pkt);
        if (n) {
            copy_in(EP2_IN_BUF, pkt, n);
            arm(IN_BUF(2), next_pid(IN_BUF(2)) | BUF_FULL | BUF_LEN(n));
            in2_busy = 1;
        }
    }
}
