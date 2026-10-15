#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/tools — the lines an alice board sends
(alice/shell/lines_chip.h and speak.h), from Python: written into a page's
fixtures, and read back out of a log a phone saved. vk26-alice-1 wrote
these; vk26-alice-2 is the second to need them.

  bits_lines(rnd, s, words)  one stream's BITS lines, 16 words a line
  status_line(serial, rnd)   a speak.h status line, as a board sends one
  expect_instret(path)       build/expect.h's INSTRET, by halt code
  expect_names(path)         build/expect.h's FIXED names, in the shell's order
  spans(xs)                  1, 2, 3, 5 -> "1–3, 5": the cases a --board check
                             names, as a README quotes them
  logged_streams(log, n)     each STREAM line in a log, in order, with what
                             came before it for the same stream:
                             (fields, words, other) — the STREAM line split
                             on spaces, the stream's samples packed 32 to a
                             word (None unless all n of its BITS lines
                             arrived), and its other lines split, by kind
"""
import re

STATUS = ("{} usb=6 setups=31 stalls=3 dropped=0 errors=0 ref=00000000 sys=00000000 xosc=00000000 "
          "pll=00000001 usb_khz=48000 sys_khz=48000 sys48_khz=48000 ref_khz=12000 sof_khz=47999 "
          "lives={} minstret=69719")


def bits_lines(rnd, s, words):
    return [f"BITS {rnd:08x} {s:08x} {k:08x} " + " ".join(f"{w:08x}" for w in words[16 * k:16 * k + 16])
            for k in range(len(words) // 16)]


def status_line(serial, rnd):
    return STATUS.format(serial, rnd)


def expect_instret(path):
    return [int(x) for x in re.search(r"INSTRET\[\d+\] = \{([^}]*)\}", open(path).read()).group(1).split(",")]


def expect_names(path):
    return re.findall(r'^    \{"([^"]+)", \d+, ', open(path).read(), re.M)


def logged_streams(log, n):
    bits, other = {}, {}
    for line in open(log, encoding="utf-8", errors="replace"):
        t = line.strip().split(" ")
        if len(t) < 3 or not re.fullmatch(r"[0-9a-f]{8}", t[1]) or not re.fullmatch(r"[0-9a-f]{8}", t[2]):
            continue
        key = (t[1], t[2])
        if t[0] == "BITS" and len(t) == 20:
            bits.setdefault(key, {})[int(t[3], 16)] = [int(x, 16) for x in t[4:]]
        elif t[0] == "STREAM" and len(t) >= 8:
            parts = bits.pop(key, {})
            words = sum((parts[k] for k in range(n)), []) if sorted(parts) == list(range(n)) else None
            yield t, words, other.pop(key, {})
        elif t[0] not in ("BITS", "STREAM", "ROUND"):
            other.setdefault(key, {}).setdefault(t[0], []).append(t)


def spans(xs):
    """1, 2, 3, 5 -> '1–3, 5'."""
    out, xs = [], sorted(xs)
    for x in xs:
        if out and x == out[-1][1] + 1:
            out[-1][1] = x
        else:
            out.append([x, x])
    return ", ".join(f"{a}" if a == b else f"{a}–{b}" for a, b in out) or "none"
