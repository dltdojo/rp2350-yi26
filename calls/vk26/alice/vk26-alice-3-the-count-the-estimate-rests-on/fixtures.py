#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-3 — what count.html is tested against, written from count.py,
which shares nothing with the page: the lines a board running vk26-alice-3
sends (shell/board_chip.c's formats), right and wrong in each of the ways
the page must tell apart.

  fixtures.py DIR EXPECT_H     writes DIR/*.txt, one log each, and
                               DIR/judge.txt: every stream in count_streams()
                               as words, with count.py's largest count and its
                               estimate per byte and per bit
  fixtures.py --board EXPECT_H LOG...
                               every STREAM line a phone gave back, counted
                               again by count.py from its BITS lines, against
                               its HIST lines and EXPECT_H's INSTRET; then the
                               mcycles, and the TRNG's two estimates;
                               prints PASS/FAIL

EXPECT_H is build/expect.h: the RTL's minstret, and the streams the shell
runs after the TRNG's two.
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from count import L, count_streams, from_words, histogram, mcv, per_bit  # noqa: E402  (count.py puts alice/tools on the path)
from lines import bits_lines, expect_names, logged_streams, status_line  # noqa: E402

SERIAL = "vk26-alice-3"
TRNG = 0xffffffff
WORDS = L // 4
# A board's mcycle for a run, made up; the first run after boot a little
# more, as exp212 found silicon's first run.
CYCLES, FIRST = 7348211, 7348977


def count_instret(path):
    """build/expect.h's INSTRET: one number."""
    return int(re.search(r"#define INSTRET (\d+)u", open(path).read()).group(1))


def as_words(samples):
    return list(struct.unpack(f"<{WORDS}I", bytes(samples)))


def count_lines(rnd, s, name, samples, want, instret, **change):
    """What board_stream sends for one stream; the counts, the largest,
    minstret and mcycle are the kernel's unless `change` gives them."""
    counts = change.get("counts", histogram(samples))
    most = change.get("most", max(counts))
    cycles = change.get("cycles", FIRST if (rnd, s) == (0, 0) else CYCLES)
    out = bits_lines(rnd, s, as_words(samples))
    for k in range(16):
        out.append(f"HIST {rnd:08x} {s:08x} {k:08x} " + " ".join(f"{c:08x}" for c in counts[16 * k:16 * k + 16]))
    out.append(f"STREAM {rnd:08x} {s:08x} {most:08x} {want:08x} {change.get('minstret', instret):08x} "
               f"{cycles:08x} {name}")
    return out


def count_rounds(instret, fixed, n=2, change=None):
    """n rounds as a board sends them, the TRNG's two played by count.py's
    random 1 and bits 1 three times in four; change(rnd, s) may return
    keyword arguments for count_lines."""
    every = count_streams()
    plays = [("trng", "random 1"), ("trng raw", "bits 1 three times in four")] + [(n, n) for n in fixed]
    out = []
    for r in range(n):
        out.append(status_line(SERIAL, r))
        for s, (name, play) in enumerate(plays):
            smp = every[play]
            want = TRNG if s < 2 else max(histogram(smp))
            out += count_lines(r, s, name, smp, want, instret, **((change and change(r, s)) or {}))
            if s == 2:
                out.append(status_line(SERIAL, r))
        out.append(f"ROUND {r:08x} {len(plays):08x}")
    return out


def write_count_fixtures(d, expect_h):
    os.makedirs(d, exist_ok=True)
    instret, fixed = count_instret(expect_h), expect_names(expect_h)
    every = count_streams()

    def save(name, lines):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for line in lines))

    with open(os.path.join(d, "judge.txt"), "w") as f:
        for name, smp in every.items():
            most = max(histogram(smp))
            _, _, h = mcv(most, L)
            _, _, hb = per_bit(smp)
            f.write(f"{most}|{h:.9f}|{hb:.9f}|{name}|{' '.join(f'{w:08x}' for w in as_words(smp))}\n")

    good = count_rounds(instret, fixed)
    save("good.txt", good)
    one = lambda which: count_rounds(instret, fixed, 1, which)  # noqa: E731
    raw = histogram(every["bits 1 three times in four"])
    # The kernel's count for the value 7 one short.
    save("count.txt", one(lambda r, s: s == 1 and {"counts": raw[:7] + [raw[7] - 1] + raw[8:]}))
    # The largest is not the largest of the counts.
    save("most.txt", one(lambda r, s: s == 1 and {"most": max(raw) - 1}))
    # minstret one more than the RTL's.
    save("minstret.txt", one(lambda r, s: s == 3 and {"minstret": instret + 1}))
    # Round 1's raw stream took 4 cycles more than the others.
    save("cycles.txt", count_rounds(instret, fixed, 2, lambda r, s: (r, s) == (1, 1) and {"cycles": CYCLES + 4}))
    # One BITS line, and one HIST line, never arrived.
    save("lost.txt", [x for x in good if not x.startswith("BITS 00000001 00000000 00000020 ")])
    save("histlost.txt", [x for x in good if not x.startswith("HIST 00000000 00000002 00000003 ")])
    # Joined at the tenth BITS line of round 0's first stream.
    first = next(i for i, x in enumerate(good) if x.startswith("BITS 00000000 00000000 00000009 "))
    save("midstream.txt", good[first:])


def count_board(expect_h, logs):
    """Each STREAM line of each log against count.py; the mcycles; the TRNG's estimates."""
    instret = count_instret(expect_h)
    failed = 0
    for log in logs:
        n, bad, cycles, est = 0, [], {}, {}
        for t, words, other in logged_streams(log, 64):
            hist = {int(h[3], 16): [int(c, 16) for c in h[4:]] for h in other.get("HIST", []) if len(h) == 20}
            if words is None or sorted(hist) != list(range(16)):
                continue
            n += 1
            rnd, s = int(t[1], 16), int(t[2], 16)
            most, want, minstret, cyc = (int(x, 16) for x in t[3:7])
            smp = from_words(words)
            counts = histogram(smp)
            ok = (sum((hist[k] for k in range(16)), []) == counts and most == max(counts)
                  and want in (TRNG, most) and minstret == instret)
            if not ok:
                bad.append(f"round {rnd} stream {s} ({' '.join(t[7:])}): most {most}, count.py {max(counts)}")
            cycles[(rnd, s)] = cyc
            if s < 2:
                est.setdefault(s, []).append((mcv(max(counts), L)[2], per_bit(smp)[2]))
        ok = n > 0 and not bad
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(log)}: {n} whole streams from a board, each of the 256 "
              f"counts and the largest as count.py gives them, minstret the RTL's"
              f"{'' if ok else ' — ' + (bad[0] if bad else 'none')}")
        failed |= not ok
        after = {c for k, c in cycles.items() if k != (0, 0)}
        print(f"{'PASS' if len(after) == 1 else 'FAIL'}  {os.path.basename(log)}: every stream took "
              f"{'the same mcycle, ' + str(next(iter(after))) if len(after) == 1 else 'one mcycle — ' + str(sorted(after))}"
              f"{', round 0 stream 0 aside' if (0, 0) in cycles else ''}")
        failed |= len(after) != 1
        for s, name in ((0, "the TRNG, its tests on"), (1, "the TRNG, raw")):
            if s in est:
                hs = ", ".join(f"{h:.3f} ({hb:.3f} a bit)" for h, hb in est[s])
                print(f"      {name}: H per byte {hs}")
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(count_board(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_count_fixtures(sys.argv[1], sys.argv[2])
