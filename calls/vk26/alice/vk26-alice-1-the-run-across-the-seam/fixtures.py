#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-1 — what seam.html is tested against, written from seam.py and
hashlib, which share nothing with the page: the lines a board running
vk26-alice-1 sends (shell/board_chip.c's formats), right and wrong in each
of the ways the page must tell apart.

  fixtures.py DIR EXPECT_H     writes DIR/*.txt, one stream of lines each, and
                               DIR/judge.txt: every stream in seam.streams(),
                               bit 0 of each sample packed as the board packs
                               them, with seam.py's code
  fixtures.py --board EXPECT_H LOG...
                               every STREAM line a phone gave back, judged
                               again by seam.py from its BITS lines, its
                               digests by hashlib, its minstret against
                               EXPECT_H's INSTRET; prints PASS/FAIL

EXPECT_H is build/expect.h: the RTL's minstret for each halt code, and the
streams the shell runs after the TRNG's.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from seam import WINDOWS, seam_outcome, streams  # noqa: E402
from health import pack, unpack, window_bytes  # noqa: E402  (seam.py has put alice/tools on the path)
from lines import bits_lines, expect_instret, expect_names, logged_streams, status_line  # noqa: E402

TRNG = 0xffffffff


def stream_lines(rnd, s, name, bits, want, instret, code=None, digests=None, minstret=None):
    """What board_stream sends for one stream; code, digests and minstret are
    the kernel's, seam.py's unless given otherwise."""
    words = pack(bits)
    c, ds, _ = seam_outcome(bits)
    code = c if code is None else code
    digests = ds if digests is None else digests
    minstret = instret[code] if minstret is None else minstret
    out = bits_lines(rnd, s, words)
    for w, d in enumerate(digests):
        out.append(f"DIGEST {rnd:08x} {s:08x} {w:08x} {d.hex()}")
    out.append(f"STREAM {rnd:08x} {s:08x} {code:08x} {want:08x} {minstret:08x} {len(digests):08x} {name}")
    return out


def board_rounds(instret, names, n=2, change=None):
    """n rounds as a board sends them, the TRNG's stream played by seam.py's
    fair one; change(rnd, s) may return keyword arguments for stream_lines."""
    every = streams()
    out = []
    for r in range(n):
        out.append(status_line("vk26-alice-1", r))
        for s, name in enumerate(["trng"] + names):
            bits = [x & 1 for x in every["fair throughout" if s == 0 else name]]
            want = TRNG if s == 0 else seam_outcome(bits)[0]
            out += stream_lines(r, s, name, bits, want, instret, **((change and change(r, s)) or {}))
            if s == 2:
                out.append(status_line("vk26-alice-1", r))
        out.append(f"ROUND {r:08x} {len(names) + 1:08x}")
    return out


def write_seam_fixtures(d, expect_h):
    os.makedirs(d, exist_ok=True)
    instret, names = expect_instret(expect_h), expect_names(expect_h)
    every = streams()

    def save(name, lines):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for line in lines))

    with open(os.path.join(d, "judge.txt"), "w") as f:
        for name, words in every.items():
            bits = [x & 1 for x in words]
            f.write(f"{seam_outcome(words)[0]}|{name}|{' '.join(f'{w:08x}' for w in pack(bits))}\n")

    good = board_rounds(instret, names)
    save("good.txt", good)
    seam = names.index("seam 11+10") + 1
    stuck = names.index("stuck at 1, window 1") + 1
    seam_bits = [x & 1 for x in every["seam 11+10"]]
    stuck_bits = [x & 1 for x in every["stuck at 1, window 1"]]
    # One byte of the seam stream's first digest flipped on the way.
    save("digest.txt", board_rounds(instret, names, 1, lambda r, s: s == seam and {
        "digests": [bytes([seam_outcome(seam_bits)[1][0][0] ^ 1]) + seam_outcome(seam_bits)[1][0][1:]]}))
    # A kernel that resets the run at each window's edge passes the seam stream:
    # code 0, four digests, each SHA-256 of its window.
    save("reset.txt", board_rounds(instret, names, 1, lambda r, s: s == seam and {
        "code": 0, "digests": [hashlib.sha256(window_bytes(seam_bits, w)).digest() for w in range(WINDOWS)]}))
    # A kernel that writes the next window after the first failure: stuck at
    # 1 stops at window 1, and window 2's digest is written anyway.
    save("latch.txt", board_rounds(instret, names, 1, lambda r, s: s == stuck and {
        "code": 2, "digests": [hashlib.sha256(window_bytes(stuck_bits, 0)).digest()]}))
    # minstret one more than the RTL's for one stream.
    save("minstret.txt", board_rounds(instret, names, 1, lambda r, s: s == 1 and {"minstret": instret[2] + 1}))
    # One BITS line of the TRNG's stream in round 1 never arrived.
    save("lost.txt", [x for x in good if not x.startswith("BITS 00000001 00000000 00000005 ")])
    # Joined at the fourth BITS line of round 0's first stream.
    first = next(i for i, x in enumerate(good) if x.startswith("BITS 00000000 00000000 00000003 "))
    save("midstream.txt", good[first:])


def board(expect_h, logs):
    """Each STREAM line of each log against seam.py and hashlib."""
    instret = expect_instret(expect_h)
    failed = 0
    for log in logs:
        n, bad = 0, []
        for t, words, other in logged_streams(log, 8):
            if words is None:
                continue
            n += 1
            code, want, minstret, nd = (int(x, 16) for x in t[3:7])
            sent = {int(d[3], 16): d[4] for d in other.get("DIGEST", []) if len(d) == 5}
            c, ds, _ = seam_outcome(unpack(words))
            ok = (code == c and want in (TRNG, c) and minstret == instret[c] and nd == len(ds)
                  and [sent.get(w) for w in range(len(ds))] == [d.hex() for d in ds])
            if not ok:
                bad.append(f"round {int(t[1], 16)} stream {int(t[2], 16)} ({' '.join(t[7:])}): "
                           f"code {code} minstret {minstret}, seam.py {c} and {instret[c]}")
        ok = n > 0 and not bad
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(log)}: {n} whole streams from a board, each code, "
              f"minstret and digest as seam.py and hashlib give them{'' if ok else ' — ' + (bad[0] if bad else 'none')}")
        failed |= not ok
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(board(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_seam_fixtures(sys.argv[1], sys.argv[2])
