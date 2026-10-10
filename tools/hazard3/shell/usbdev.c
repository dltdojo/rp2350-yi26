// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the USB CDC-ACM device's logic (usbdev.h says what it
// is and what it leaves to a board). No register is touched here, so all of it
// runs on this machine under usbdev_test.py before it runs on a chip.

#include "usbdev.h"

struct usbdev_state usbdev;

// ---------- descriptors ------------------------------------------------------

static const uint8_t DEVICE[18] = {
    18, 0x01,
    0x00, 0x02,          // bcdUSB 2.00
    0xef, 0x02, 0x01,    // miscellaneous, common class, interface association
    USBDEV_EP0_SIZE,
    0x09, 0x12,          // idVendor 0x1209
    0x01, 0x00,          // idProduct 0x0001
    0x10, 0x00,          // bcdDevice 0.10, embassy-usb's default
    1, 2, 3,             // manufacturer, product, serial
    1,
};

#define CONFIG_LEN 70
static const uint8_t CONFIG[CONFIG_LEN] = {
    9, 0x02, CONFIG_LEN, 0, 2, 1, 0, 0x80, 50,      // 70 bytes, 2 interfaces, bus powered, 100 mA
    8, 0x0b, 0, 2, 0x02, 0x02, 0x00, 0,             // association: interfaces 0-1, CDC ACM
    9, 0x04, 0, 0, 1, 0x02, 0x02, 0x00, 0,          // interface 0: communications, ACM
    5, 0x24, 0x00, 0x10, 0x01,                      //   header, CDC 1.10
    4, 0x24, 0x02, 0x02,                            //   ACM: line coding and serial state
    5, 0x24, 0x06, 0, 1,                            //   union: 0 controls 1
    7, 0x05, 0x81, 0x03, 8, 0, 255,                 //   EP 0x81 interrupt IN, 8 bytes
    9, 0x04, 1, 0, 2, 0x0a, 0x00, 0x00, 0,          // interface 1: data
    7, 0x05, 0x01, 0x02, USBDEV_BULK_SIZE, 0, 0,    //   EP 0x01 bulk OUT
    7, 0x05, 0x82, 0x02, USBDEV_BULK_SIZE, 0, 0,    //   EP 0x82 bulk IN
};

static const uint8_t LANGS[4] = {4, 0x03, 0x09, 0x04};   // English (US)

#define STRING_MAX 34
static uint8_t strings[3][2 + 2 * STRING_MAX];

static void make_string(uint8_t *d, const char *s) {
    uint32_t n = 0;
    while (s[n] && n < STRING_MAX) {
        d[2 + 2 * n] = (uint8_t)s[n];
        d[3 + 2 * n] = 0;
        n++;
    }
    d[0] = (uint8_t)(2 + 2 * n);
    d[1] = 0x03;
}

void usbdev_init(const char *product, const char *serial) {
    make_string(strings[0], "rp2350-yi26");
    make_string(strings[1], product);
    make_string(strings[2], serial);
    usbdev_reset();
    usbdev.stage = USBDEV_NONE;
    usbdev.line_coding[0] = 0x00;   // 115200, 8N1, until a host says otherwise
    usbdev.line_coding[1] = 0xc2;
    usbdev.line_coding[2] = 0x01;
    usbdev.line_coding[3] = 0x00;
    usbdev.line_coding[4] = 0;
    usbdev.line_coding[5] = 0;
    usbdev.line_coding[6] = 8;
}

const uint8_t *usbdev_descriptor(uint8_t type, uint8_t index, uint32_t *len) {
    if (type == 0x01 && index == 0) { *len = sizeof DEVICE; return DEVICE; }
    if (type == 0x02 && index == 0) { *len = CONFIG_LEN; return CONFIG; }
    if (type == 0x03 && index == 0) { *len = sizeof LANGS; return LANGS; }
    if (type == 0x03 && index >= 1 && index <= 3) {
        *len = strings[index - 1][0];
        return strings[index - 1];
    }
    *len = 0;
    return 0;   // device qualifier (a full-speed device has none), BOS, anything else: a stall
}

// ---------- EP0 --------------------------------------------------------------

enum { IDLE, DATA_IN, STATUS_OUT, DATA_OUT, STATUS_IN };

static uint8_t ep0;               // which of the above
static const uint8_t *tx;         // the IN data stage still to send
static uint32_t tx_left;
static uint8_t tx_zlp;            // it ends on a full packet short of what was asked: one empty packet more
static uint8_t pending_address;   // SET_ADDRESS takes effect after its status stage
static uint8_t has_pending_address;
static uint8_t reply[8];          // the short answers: GET_STATUS, GET_CONFIGURATION, GET_INTERFACE
static uint8_t out_request;       // what the OUT data stage is for

void usbdev_reset(void) {
    ep0 = IDLE;
    tx_left = 0;
    tx_zlp = 0;
    has_pending_address = 0;
    usbdev.configured = 0;
    usbdev.dtr = 0;
    usbdev.address = 0;
    if (usbdev.stage < USBDEV_RESET) usbdev.stage = USBDEV_RESET;
}

static void send_next(void) {
    uint32_t n = tx_left < USBDEV_EP0_SIZE ? tx_left : USBDEV_EP0_SIZE;
    usbhw_ep0_in(tx, n);
    tx += n;
    tx_left -= n;
}

static void data_in(const uint8_t *d, uint32_t len, uint32_t asked) {
    if (len > asked) len = asked;
    tx = d;
    tx_left = len;
    tx_zlp = len < asked && len % USBDEV_EP0_SIZE == 0 && len > 0;
    ep0 = DATA_IN;
    send_next();
}

static void status_in(void) {
    ep0 = STATUS_IN;
    usbhw_ep0_in(0, 0);
}

static void stall(void) {
    ep0 = IDLE;
    usbdev.stalls++;
    usbhw_ep0_stall();
}

static void standard(const uint8_t *s, uint8_t recipient, uint16_t value, uint16_t length) {
    uint8_t req = s[1];
    uint32_t len;
    const uint8_t *d;
    switch (req) {
    case 0x06:   // GET_DESCRIPTOR
        d = usbdev_descriptor((uint8_t)(value >> 8), (uint8_t)value, &len);
        if (d && recipient == 0) data_in(d, len, length); else stall();
        return;
    case 0x05:   // SET_ADDRESS
        if (recipient != 0) { stall(); return; }
        pending_address = (uint8_t)(value & 0x7f);
        has_pending_address = 1;
        status_in();
        return;
    case 0x09:   // SET_CONFIGURATION
        if (recipient != 0 || value > 1) { stall(); return; }
        usbdev.configured = (uint8_t)value;
        if (!value) usbdev.dtr = 0;
        usbhw_configure(value == 1);
        if (value == 1 && usbdev.stage < USBDEV_CONFIGURED) usbdev.stage = USBDEV_CONFIGURED;
        status_in();
        return;
    case 0x08:   // GET_CONFIGURATION
        reply[0] = usbdev.configured;
        data_in(reply, 1, length);
        return;
    case 0x00:   // GET_STATUS: not self-powered, no remote wakeup, no endpoint halted
        reply[0] = 0;
        reply[1] = 0;
        data_in(reply, 2, length);
        return;
    case 0x01:   // CLEAR_FEATURE
    case 0x03:   // SET_FEATURE: nothing here halts or wakes, so both are accepted and change nothing
        status_in();
        return;
    case 0x0a:   // GET_INTERFACE
        reply[0] = 0;
        data_in(reply, 1, length);
        return;
    case 0x0b:   // SET_INTERFACE: alternate setting 0 is the only one
        if (value == 0) status_in(); else stall();
        return;
    default:
        stall();
    }
}

static void class_request(const uint8_t *s, uint16_t value, uint16_t index, uint16_t length) {
    if (index != 0) { stall(); return; }   // the communications interface is 0
    switch (s[1]) {
    case 0x20:   // SET_LINE_CODING
        if (length != 7) { stall(); return; }
        out_request = 0x20;
        ep0 = DATA_OUT;
        usbhw_ep0_out();
        return;
    case 0x21:   // GET_LINE_CODING
        data_in(usbdev.line_coding, 7, length);
        return;
    case 0x22:   // SET_CONTROL_LINE_STATE: bit 0 is DTR
        usbdev.dtr = (uint8_t)(value & 1);
        if (usbdev.dtr && usbdev.stage < USBDEV_OPEN) usbdev.stage = USBDEV_OPEN;
        status_in();
        return;
    case 0x23:   // SEND_BREAK
        status_in();
        return;
    default:
        stall();
    }
}

void usbdev_setup(const uint8_t s[8]) {
    usbdev.setups++;
    ep0 = IDLE;
    tx_left = 0;
    tx_zlp = 0;
    uint8_t type = (s[0] >> 5) & 3, recipient = s[0] & 0x1f;
    uint16_t value = (uint16_t)(s[2] | s[3] << 8);
    uint16_t index = (uint16_t)(s[4] | s[5] << 8);
    uint16_t length = (uint16_t)(s[6] | s[7] << 8);
    if (type == 0) standard(s, recipient, value, length);
    else if (type == 1 && recipient == 1) class_request(s, value, index, length);
    else stall();
}

void usbdev_ep0_in_done(void) {
    switch (ep0) {
    case DATA_IN:
        if (tx_left > 0) {
            send_next();
        } else if (tx_zlp) {
            tx_zlp = 0;
            usbhw_ep0_in(0, 0);
        } else {
            ep0 = STATUS_OUT;     // the host's empty OUT packet ends it
            usbhw_ep0_out();
        }
        return;
    case STATUS_IN:
        ep0 = IDLE;
        if (has_pending_address) {
            has_pending_address = 0;
            usbdev.address = pending_address;
            usbhw_set_address(pending_address);
            if (pending_address && usbdev.stage < USBDEV_ADDRESSED) usbdev.stage = USBDEV_ADDRESSED;
        }
        return;
    default:
        return;
    }
}

void usbdev_ep0_out_done(const uint8_t *data, uint32_t len) {
    switch (ep0) {
    case DATA_OUT:
        if (out_request == 0x20 && len == 7)
            for (uint32_t i = 0; i < 7; i++) usbdev.line_coding[i] = data[i];
        status_in();
        return;
    case STATUS_OUT:
        ep0 = IDLE;
        return;
    default:
        return;
    }
}

// ---------- the bulk IN queue ------------------------------------------------

#define QUEUE 1024
static uint8_t queue[QUEUE];
static uint32_t head, count;

void usbdev_write(const char *s, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        if (count == QUEUE) { usbdev.dropped += n - i; return; }
        queue[(head + count) % QUEUE] = (uint8_t)s[i];
        count++;
    }
}

uint32_t usbdev_packet(uint8_t *out) {
    uint32_t n = count < USBDEV_BULK_SIZE ? count : USBDEV_BULK_SIZE;
    for (uint32_t i = 0; i < n; i++) out[i] = queue[(head + i) % QUEUE];
    head = (head + n) % QUEUE;
    count -= n;
    return n;
}
