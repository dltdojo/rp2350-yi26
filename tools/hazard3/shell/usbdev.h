// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a USB CDC-ACM device for a shell, the part that does
// not touch a register: the descriptors, what each request on EP0 is answered
// with, and the queue of bytes going out on the bulk IN endpoint. exp226 wrote
// it, the first shell to have a USB port.
//
// It is the same device the repository's Rust firmwares are (crates/cdc-console
// over embassy-usb 0.6): VID:PID 1209:0001, class EF/02/01 with an interface
// association, a communications interface with one interrupt IN endpoint
// (0x81) and a data interface with a bulk OUT (0x01) and a bulk IN (0x82), 64
// bytes each, endpoint numbers as embassy-rp hands them out. One difference:
// bcdUSB is 2.00, not 2.10, so no host asks for a BOS descriptor this device
// would have to build. tools/pages/log.html and inspect.html read it as they
// read any firmware here.
//
// Everything that touches the controller is a board's, through five calls
// this file declares and does not define (usb_chip.c on the chip, a recorder
// in usbdev_test.py on this machine):
//
//   usbhw_ep0_in(data, len)   send len bytes (at most 64, 0 for a status
//                             stage) as the next IN packet on EP0
//   usbhw_ep0_out()           take the next OUT packet on EP0
//   usbhw_ep0_stall()         stall EP0 both ways until the next SETUP
//   usbhw_set_address(a)      answer at address a from now on
//   usbhw_configure(on)       the CDC endpoints enabled, or not
//
// and the board calls back with what happened on EP0: usbdev_setup,
// usbdev_ep0_in_done, usbdev_ep0_out_done, and usbdev_reset on a bus reset.
#pragma once
#include <stdint.h>

#define USBDEV_EP0_SIZE 64
#define USBDEV_BULK_SIZE 64

// How far the host has got with the device, the highest so far. A shell shows
// it on the LED, so that a device that never enumerates still says how far it
// got.
enum {
    USBDEV_NONE = 0,
    USBDEV_RESET = 1,        // the host reset the bus: the pull-up is seen
    USBDEV_ADDRESSED = 2,    // SET_ADDRESS, and its status stage completed
    USBDEV_CONFIGURED = 3,   // SET_CONFIGURATION 1
    USBDEV_OPEN = 4,         // SET_CONTROL_LINE_STATE with DTR: a page or a terminal opened the port
};

struct usbdev_state {
    uint8_t stage;        // the highest of the above reached
    uint8_t configured;   // now, not ever
    uint8_t dtr;          // now
    uint8_t address;
    uint32_t setups;      // SETUP packets seen
    uint32_t stalls;      // requests answered with a stall
    uint32_t dropped;     // bytes the queue had no room for
    uint8_t line_coding[7];
};

extern struct usbdev_state usbdev;

// The strings: product and serial, ASCII. Manufacturer is "rp2350-yi26", as
// crates/cdc-console has it.
void usbdev_init(const char *product, const char *serial);
void usbdev_reset(void);
void usbdev_setup(const uint8_t setup[8]);
void usbdev_ep0_in_done(void);
void usbdev_ep0_out_done(const uint8_t *data, uint32_t len);

// The bulk IN queue. usbdev_write takes what fits and counts the rest as
// dropped — a log nobody reads must not stop the shell. usbdev_packet fills
// one packet, at most 64 bytes, and returns its length; 0 when there is none.
void usbdev_write(const char *s, uint32_t n);
uint32_t usbdev_packet(uint8_t *out);

// The descriptors, for usbdev_test.py to compare byte for byte.
const uint8_t *usbdev_descriptor(uint8_t type, uint8_t index, uint32_t *len);

// What a board provides.
void usbhw_ep0_in(const uint8_t *data, uint32_t len);
void usbhw_ep0_out(void);
void usbhw_ep0_stall(void);
void usbhw_set_address(uint8_t a);
void usbhw_configure(int on);
