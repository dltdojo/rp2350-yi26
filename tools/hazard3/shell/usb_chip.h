// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the RP2350's USB controller for a shell (usb_chip.c),
// under the device usbdev.c describes. exp226 wrote it.
//
//   usb_clock_start()          XOSC, PLL_USB at 48 MHz, clk_usb, and clk_sys
//                              moved onto it as well; 0, or the step that did
//                              not finish
//   usb_start(product, serial) the controller reset and enabled, the pull-up
//                              on: the host sees a device; 0, or the step
//   usb_poll()                 everything the controller has to say, answered;
//                              call it from every wait
//   usb_frame()                the host's frame number, a millisecond each
//
// The steps are numbered after the four checks exp225's shell makes, so one
// count on the LED never means two things.
#pragma once
#include <stdint.h>

enum {
    USB_STEP_XOSC = 5,          // the crystal oscillator did not become stable
    USB_STEP_PLL = 6,           // PLL_USB did not come out of reset or did not lock
    USB_STEP_CLK_USB = 7,       // clk_usb did not report enabled, or is not 48 MHz against the crystal
    USB_STEP_CONTROLLER = 8,    // the USB controller did not come out of reset
    USB_STEP_SYS_CLOCK = 9,     // clk_sys: already on PLL_USB, or would not move to it
};

// What the bootrom left, read before anything is changed; and the clocks as
// the chip's frequency counter measures them against the 12 MHz crystal, in
// kHz (0 when the counter did not finish).
struct usb_boot {
    uint32_t clk_ref_ctrl, clk_sys_ctrl, xosc_status, pll_usb_cs;
    uint32_t usb_khz, sys_khz, ref_khz;   // sys_khz: as the bootrom left it
    uint32_t sys48_khz;                   // clk_sys once moved onto PLL_USB
    uint32_t sie_errors;        // CRC, bit-stuff, receive timeout and overflow errors seen on the bus
};
extern struct usb_boot usb_boot;

int usb_clock_start(void);
int usb_start(const char *product, const char *serial);
void usb_poll(void);
uint32_t usb_frame(void);
