#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3/shell — usbdev.c on this machine, before any chip sees it.

  usbdev_test.py PRODUCT SERIAL [EXP115_README]

Builds usbdev.c (or $USBDEV_C, for check.sh's wrong versions) for this
machine with a recorder in place of the controller, drives it through what a
host does, and prints PASS or FAIL per claim:

  - its descriptors, field by field, as a host parses them;
  - the same tree as exp115 recorded from a real Pico 2 running one of this
    repository's Rust firmwares (EXP115_README), apart from the strings and
    bcdUSB 2.00 instead of 2.10;
  - an enumeration as Linux does it, then tools/pages/log.html's own
    requests (SET_LINE_CODING, SET_CONTROL_LINE_STATE with DTR), each
    answered on EP0 with the packets, status stages and stalls it should;
  - the bulk IN queue, packet by packet, and what it drops when full.

What it cannot reach is the controller: usb_chip.c's registers are the
board's to try.
"""
import ctypes
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

RECORDER = r"""
#include <stdint.h>
#include <string.h>
#include "usbdev.h"
struct ev { uint32_t kind, len; uint8_t data[64]; };
struct ev evs[256];
uint32_t nev;
static void rec(uint32_t kind, const uint8_t *d, uint32_t len) {
    if (nev == 256) return;
    evs[nev].kind = kind; evs[nev].len = len;
    if (d && len) memcpy(evs[nev].data, d, len > 64 ? 64 : len);
    nev++;
}
void usbhw_ep0_in(const uint8_t *data, uint32_t len) { rec(1, data, len); }
void usbhw_ep0_out(void) { rec(2, 0, 0); }
void usbhw_ep0_stall(void) { rec(3, 0, 0); }
void usbhw_set_address(uint8_t a) { rec(4, 0, a); }
void usbhw_configure(int on) { rec(5, 0, (uint32_t)on); }
void clear(void) { nev = 0; }
uint8_t stage(void) { return usbdev.stage; }
uint8_t dtr(void) { return usbdev.dtr; }
uint32_t dropped(void) { return usbdev.dropped; }
const uint8_t *line_coding(void) { return usbdev.line_coding; }
"""

KIND = {1: "IN", 2: "OUT", 3: "STALL", 4: "ADDRESS", 5: "CONFIGURE"}
failed = 0


def check(ok, claim, detail=""):
    global failed
    print(("PASS  " if ok else "FAIL  ") + claim + ("" if ok or not detail else f" — {detail}"))
    failed += not ok


class Ev(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("len", ctypes.c_uint32), ("data", ctypes.c_uint8 * 64)]


def build(work):
    open(os.path.join(work, "rec.c"), "w").write(RECORDER)
    lib = os.path.join(work, "usbdev.so")
    subprocess.run(["cc", "-shared", "-fPIC", "-O1", "-Wall", "-Werror", "-I", HERE, "-o", lib,
                    os.environ.get("USBDEV_C", os.path.join(HERE, "usbdev.c")), os.path.join(work, "rec.c")], check=True)
    return ctypes.CDLL(lib)


class Device:
    def __init__(self, lib, product, serial):
        self.lib = lib
        lib.line_coding.restype = ctypes.POINTER(ctypes.c_uint8)
        lib.usbdev_init(product.encode(), serial.encode())

    def events(self):
        evs = (Ev * 256).in_dll(self.lib, "evs")
        n = ctypes.c_uint32.in_dll(self.lib, "nev").value
        out = [(KIND[e.kind], bytes(e.data[:e.len]) if e.kind == 1 else e.len) for e in evs[:n]]
        self.lib.clear()
        return out

    def setup(self, *b):
        self.lib.usbdev_setup(bytes(b))
        return self.events()

    def in_done(self):
        self.lib.usbdev_ep0_in_done()
        return self.events()

    def out_done(self, data=b""):
        self.lib.usbdev_ep0_out_done(data, len(data))
        return self.events()

    def control_in(self, *setup):
        """A whole IN control transfer, as a host sees it: the data, then the status stage."""
        evs = self.setup(*setup)
        data = b""
        while evs and evs[0][0] == "IN":
            data += evs[0][1]
            evs = self.in_done()
        status = evs == [("OUT", 0)] and self.out_done() == []
        return data, status, evs

    def control_out(self, *setup, data=b""):
        evs = self.setup(*setup)
        if data:
            if evs != [("OUT", 0)]:
                return False, evs
            evs = self.out_done(data)
        if evs != [("IN", b"")]:
            return False, evs
        return True, self.in_done()


def get_descriptor(dev, dtype, index, length):
    return dev.control_in(0x80, 0x06, index, dtype, 0, 0, length & 0xff, length >> 8)


def string(d):
    return d[2:d[0]].decode("utf-16-le")


def tree(config):
    """The configuration as exp115's page prints it: interfaces, then endpoints."""
    out, i = [], 0
    while i < len(config):
        n, t = config[i], config[i + 1]
        if n < 2:
            raise ValueError(f"a descriptor of length {n} at byte {i}")
        if t == 0x04:
            out.append(("interface", config[i + 2], config[i + 5], config[i + 6], config[i + 7]))
        elif t == 0x05:
            kind = {2: "bulk", 3: "interrupt"}[config[i + 3] & 3]
            out.append(("endpoint", config[i + 2], kind, config[i + 4] | config[i + 5] << 8))
        i += n
    return out


def exp115_tree(readme):
    text = open(readme).read()
    block = text.split("## Expected output", 1)[1].split("```", 2)[1]
    out = []
    for line in block.splitlines():
        m = re.match(r"\s+interface (\d+)\s+alt", line)
        if m:
            out.append(["interface", int(m.group(1))])
        m = re.match(r"\s+(class|subclass|protocol)\s+0x([0-9a-f]+)", line)
        if m and out and out[-1][0] == "interface":
            out[-1].append(int(m.group(2), 16))
        m = re.match(r"\s+endpoint (0x[0-9a-f]+)\s+(IN|OUT)\s+(\w+)\s+(\d+) bytes", line)
        if m:
            out.append(("endpoint", int(m.group(1), 16), m.group(3), int(m.group(4))))
    head = re.search(r"device\s+0x([0-9a-f]+):0x([0-9a-f]+)", block)
    cls = [int(re.search(rf"\b{k}\s+0x([0-9a-f]+)", block).group(1), 16) for k in ("class", "subclass", "protocol")]
    return (int(head.group(1), 16), int(head.group(2), 16), cls), [tuple(x) for x in out]


def run_tests(product, serial, readme=None):
    with tempfile.TemporaryDirectory() as work:
        dev = Device(build(work), product, serial)
        lib = dev.lib

        # -- an enumeration, as Linux does it -----------------------------------
        lib.usbdev_reset()
        check(lib.stage() == 1, "a bus reset is the first stage the LED can show")
        evs = dev.setup(0x80, 0x06, 0, 1, 0, 0, 64, 0)
        check(lib.stage() == 2, "a SETUP packet is stage 2, before anything is sent")
        dev.in_done()
        check(lib.stage() == 3, "the host taking the first packet is stage 3")
        dev.out_done()
        d, st, _ = get_descriptor(dev, 1, 0, 64)
        check(len(d) == 18 and st, "GET_DESCRIPTOR device, 64 asked: 18 bytes in one packet, then the status stage",
              f"{d.hex()} status={st}")
        dev_desc = d
        evs = dev.setup(0x00, 0x05, 7, 0, 0, 0, 0, 0)
        check(evs == [("IN", b"")], "SET_ADDRESS 7 is answered with an empty IN packet", str(evs))
        check(dev.in_done() == [("ADDRESS", 7)] and lib.stage() == 4,
              "the address is taken only after that status stage, and the stage is 4")
        d, st, _ = get_descriptor(dev, 1, 0, 18)
        check(d == dev_desc and st, "GET_DESCRIPTOR device again, at the new address: the same 18 bytes")
        d9, st9, _ = get_descriptor(dev, 2, 0, 9)
        total = d9[2] | d9[3] << 8
        config, stc, _ = get_descriptor(dev, 2, 0, 255)
        check(len(d9) == 9 and len(config) == total == 70 and stc,
              "GET_DESCRIPTOR configuration: 9 bytes, then all 70 in two packets, 64 and 6, no empty packet",
              f"{len(d9)} {len(config)} {total}")
        c64, st64, _ = get_descriptor(dev, 2, 0, 64)
        check(c64 == config[:64] and st64, "asked for exactly 64, it sends exactly 64 and no empty packet after")
        langs, _, _ = get_descriptor(dev, 3, 0, 255)
        check(langs == bytes([4, 3, 0x09, 0x04]), "string 0: English (US)")
        strs = [string(get_descriptor(dev, 3, i, 255)[0]) for i in (1, 2, 3)]
        check(strs == ["rp2350-yi26", product, serial], f"strings 1-3: {strs}")
        _, _, evs = get_descriptor(dev, 6, 0, 10)
        check(evs == [("STALL", 0)], "the device qualifier is stalled: a full-speed device has none", str(evs))
        _, _, evs = get_descriptor(dev, 0x0f, 0, 5)
        check(evs == [("STALL", 0)], "so is BOS: bcdUSB 2.00 does not promise one", str(evs))
        evs = dev.setup(0x00, 0x09, 1, 0, 0, 0, 0, 0)
        check(evs == [("CONFIGURE", 1), ("IN", b"")] and lib.stage() == 5,
              "SET_CONFIGURATION 1 enables the endpoints, then its status stage; the stage is 5", str(evs))
        dev.in_done()
        d, st, _ = dev.control_in(0x80, 0x08, 0, 0, 0, 0, 1, 0)
        check(d == b"\x01" and st, "GET_CONFIGURATION: 1")
        d, st, _ = dev.control_in(0x80, 0x00, 0, 0, 0, 0, 2, 0)
        check(d == b"\x00\x00" and st, "GET_STATUS: bus powered, no remote wakeup")

        # -- the descriptors, field by field ------------------------------------
        check(dev_desc == bytes([18, 1, 0x00, 0x02, 0xef, 0x02, 0x01, 64, 0x09, 0x12, 0x01, 0x00, 0x10, 0x00,
                                 1, 2, 3, 1]),
              "the device: USB 2.00, EF/02/01, EP0 64 bytes, 1209:0001, bcdDevice 0.10, strings 1-3, one configuration",
              dev_desc.hex())
        check(config[:9] == bytes([9, 2, 70, 0, 2, 1, 0, 0x80, 50]),
              "the configuration: 70 bytes, 2 interfaces, bus powered, 100 mA", config[:9].hex())
        check(config[9:17] == bytes([8, 0x0b, 0, 2, 2, 2, 0, 0]),
              "an interface association over interfaces 0 and 1, CDC ACM", config[9:17].hex())
        got = tree(config)
        check(got == [("interface", 0, 2, 2, 0), ("endpoint", 0x81, "interrupt", 8),
                      ("interface", 1, 0x0a, 0, 0), ("endpoint", 0x01, "bulk", 64), ("endpoint", 0x82, "bulk", 64)],
              "interface 0 ACM with 0x81 interrupt 8; interface 1 data with 0x01 and 0x82 bulk 64", str(got))
        heads = bytes(config[26:40])
        check(heads == bytes([5, 0x24, 0, 0x10, 0x01, 4, 0x24, 2, 2, 5, 0x24, 6, 0, 1]),
              "the CDC functional descriptors: header 1.10, ACM capabilities 0x02, union 0 -> 1", heads.hex())
        if readme:
            (vid, pid, cls), want = exp115_tree(readme)
            check((vid, pid) == (0x1209, 0x0001) and list(dev_desc[4:7]) == cls and got == want,
                  "the same device and tree exp115 recorded from a real Pico 2 running a Rust firmware here",
                  f"{want}")

        # -- tools/pages/log.html's own requests --------------------------------
        coding = bytes([0x00, 0xc2, 0x01, 0x00, 0, 0, 8])
        ok, evs = dev.control_out(0x21, 0x20, 0, 0, 0, 0, 7, 0, data=coding)
        check(ok and bytes(lib.line_coding()[:7]) == coding, "SET_LINE_CODING: 7 bytes taken, then its status stage",
              str(evs))
        ok, evs = dev.control_out(0x21, 0x22, 3, 0, 0, 0, 0, 0)
        check(ok and lib.dtr() == 1 and lib.stage() == 6, "SET_CONTROL_LINE_STATE 3: DTR, the port is open, stage 6")
        d, st, _ = dev.control_in(0xa1, 0x21, 0, 0, 0, 0, 7, 0)
        check(d == coding and st, "GET_LINE_CODING gives back what was set")
        ok, evs = dev.control_out(0x21, 0x22, 2, 0, 0, 0, 0, 0)
        check(ok and lib.dtr() == 0, "SET_CONTROL_LINE_STATE 2, RTS alone: DTR is bit 0, so the port is not open")
        ok, evs = dev.control_out(0x21, 0x22, 1, 0, 0, 0, 0, 0)
        check(ok and lib.dtr() == 1, "SET_CONTROL_LINE_STATE 1, DTR alone: open")
        ok, evs = dev.control_out(0x21, 0x22, 0, 0, 0, 0, 0, 0)
        check(ok and lib.dtr() == 0 and lib.stage() == 6,
              "SET_CONTROL_LINE_STATE 0 when the page closes: DTR off, the stage stays 6")
        evs = dev.setup(0x21, 0x22, 3, 0, 1, 0, 0, 0)
        check(evs == [("STALL", 0)], "a class request to interface 1 is stalled: 0 is the communications interface")
        evs = dev.setup(0x40, 0x01, 0, 0, 0, 0, 0, 0)
        check(evs == [("STALL", 0)], "a vendor request is stalled")

        # -- a bus reset in the middle ------------------------------------------
        dev.setup(0x80, 0x06, 0, 2, 0, 0, 255, 0)
        lib.usbdev_reset()
        check(lib.stage() == 6 and dev.in_done() == [],
              "a bus reset in the middle of a transfer abandons it; the stage reached is kept")

        # -- an answer that ends on a full packet, short of what was asked -------
        # A 31-character product string is a 64-byte descriptor: asked for 255,
        # the host must be told it has ended, by an empty packet after the 64.
        lib.usbdev_init(b"x" * 31, serial.encode())
        lib.usbdev_reset()
        evs = dev.setup(0x80, 0x06, 2, 3, 0x09, 0x04, 255, 0)
        n64 = evs and evs[0][0] == "IN" and len(evs[0][1]) == 64
        evs = dev.in_done()
        check(n64 and evs == [("IN", b"")] and dev.in_done() == [("OUT", 0)],
              "a 64-byte descriptor asked for with 255: one full packet, then an empty one, then the status stage",
              str(evs))

        # -- the bulk IN queue --------------------------------------------------
        buf = (ctypes.c_uint8 * 64)()
        lib.usbdev_write(b"x" * 100, 100)
        sizes = [lib.usbdev_packet(buf) for _ in range(3)]
        check(sizes == [64, 36, 0], f"100 bytes go out as 64 and 36: {sizes}")
        lib.usbdev_write(b"y" * 1100, 1100)
        check(lib.dropped() == 1100, f"1100 bytes into a 1024-byte queue: all 1100 dropped, the shell not stopped ({lib.dropped()})")
        for _ in range(10):
            lib.usbdev_write(b"z" * 99 + b"\n", 100)
        lib.usbdev_write(b"w" * 30, 30)
        out = bytearray()
        while (k := lib.usbdev_packet(buf)):
            out += bytes(buf[:k])
        check(lib.dropped() == 1130 and out == (b"z" * 99 + b"\n") * 10,
              f"ten 100-byte lines fit and the 30 bytes after them do not: whole lines out, none cut ({lib.dropped()} dropped, {len(out)} out)")
        lib.usbdev_write(b"v" * 1024, 1024)
        n = sum(iter(lambda: lib.usbdev_packet(buf), 0))
        check(n == 1024, f"a write of exactly the queue fits and comes out: {n}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    sys.exit(1 if run_tests(*sys.argv[1:]) else 0)
