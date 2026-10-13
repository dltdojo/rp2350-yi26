#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-2 — what trust.html is tested against, written from trust.py and
hashlib, which share nothing with the page: the lines a board running
vk26-alice-2 sends (shell/board_chip.c's formats), right and wrong in each of
the ways the page must tell apart.

  fixtures.py DIR EXPECT_H     writes DIR/*.txt, one stream of lines each, and
                               DIR/judge.txt: every stream in trust_streams(),
                               bit 0 of each sample packed as the board packs
                               them, with trust.py's code for it
  fixtures.py --board EXPECT_H LOG...
                               every STREAM line a phone gave back, judged
                               again by trust.py from its BITS and KAT lines,
                               its output by hashlib, its minstret against
                               EXPECT_H's INSTRET; prints PASS/FAIL

EXPECT_H is build/expect.h: the RTL's minstret for each halt code, and the
streams the shell runs after the TRNG's, with whether it spoils HASH's answer
to the KAT for each.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from trust import KAT, KAT_GOT, OUTPUT, bad_wants, kat_want, sha256, trust_outcome, trust_streams  # noqa: E402
from health import pack, unpack, window_bytes  # noqa: E402  (trust.py has put alice/tools on the path)
from lines import bits_lines, expect_instret, logged_streams, status_line  # noqa: E402

SERIAL = "vk26-alice-2"
TRNG = 0xffffffff
# What the shell hands the kernel as HASH's answer to the KAT when it spoils it.
SPOILED = bad_wants()["first bit flipped"]


def answering(kat):
    """HASH as the kernel meets it: `kat` for the KAT's message, SHA-256 otherwise."""
    return lambda b: kat if b == KAT else sha256(b)


def fixed_spoil(path):
    """build/expect.h's FIXED: (name, whether the shell spoils the KAT's answer), in order."""
    return [(n, int(sp)) for n, sp in re.findall(r'^    \{"([^"]+)", (\d+), \d+, \{', open(path).read(), re.M)]


def trust_lines(rnd, s, name, bits, want, instret, spoil, **change):
    """What board_stream sends for one stream: HASH's answer to the KAT, the
    code, the output and minstret are the shell's and trust.py's unless
    `change` gives them otherwise (kat, code, output, minstret)."""
    kat = change.get("kat", SPOILED if spoil else kat_want())
    code, writes, _ = trust_outcome(bits, None, answering(kat))
    code = change.get("code", code)
    output = change.get("output", writes.get(OUTPUT))
    minstret = change.get("minstret", instret[code])
    out = bits_lines(rnd, s, pack(bits))
    out.append(f"KAT {rnd:08x} {s:08x} {spoil:08x} {writes[KAT_GOT].hex()}")
    if output is not None:
        out.append(f"DIGEST {rnd:08x} {s:08x} 00000000 {output.hex()}")
    out.append(f"STREAM {rnd:08x} {s:08x} {code:08x} {want:08x} {minstret:08x} {int(output is not None):08x} {name}")
    return out


def trust_rounds(instret, fixed, n=2, change=None):
    """n rounds as a board sends them, the TRNG's stream played by trust.py's
    fair one, unspoiled; change(rnd, s) may return keyword arguments for
    trust_lines."""
    every = trust_streams()
    out = []
    for r in range(n):
        out.append(status_line(SERIAL, r))
        for s, (name, spoil) in enumerate([("trng", 0)] + fixed):
            bits = [x & 1 for x in every["fair" if s == 0 else name]]
            want = TRNG if s == 0 else trust_outcome(bits, None, answering(SPOILED if spoil else kat_want()))[0]
            out += trust_lines(r, s, name, bits, want, instret, spoil, **((change and change(r, s)) or {}))
            if s == 2:
                out.append(status_line(SERIAL, r))
        out.append(f"ROUND {r:08x} {len(fixed) + 1:08x}")
    return out


def write_trust_fixtures(d, expect_h):
    os.makedirs(d, exist_ok=True)
    instret, fixed = expect_instret(expect_h), fixed_spoil(expect_h)
    every = trust_streams()
    names = [n for n, _ in fixed]

    def save(name, lines):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for line in lines))

    def at(name):
        return names.index(name) + 1

    def output(name, w):
        return sha256(window_bytes([x & 1 for x in every[name]], w))

    with open(os.path.join(d, "judge.txt"), "w") as f:
        for name, words in every.items():
            bits = [x & 1 for x in words]
            f.write(f"{trust_outcome(words)[0]}|{name}|{' '.join(f'{w:08x}' for w in pack(bits))}\n")

    good = trust_rounds(instret, fixed)
    save("good.txt", good)
    one = lambda which: trust_rounds(instret, fixed, 1, which)  # noqa: E731
    # A kernel that never asks HASH the KAT: the spoiled stream goes on to code 0.
    save("unchecked.txt", one(lambda r, s: s == at("fair") and {"code": 0, "output": output("fair", 1)}))
    # The chip's SHA-256 block answering the KAT wrong, unspoiled: the kernel
    # is right to stop, the board is not right.
    save("chip.txt", one(lambda r, s: s == 0 and {"kat": SPOILED, "code": 2, "output": None}))
    # A kernel that skips the start-up test: stuck at 1 goes on to code 0.
    save("skipped.txt", one(lambda r, s: s == at("stuck at 1 from the start") and {
        "code": 0, "output": output("stuck at 1 from the start", 1)}))
    # A kernel that resets the run at the start-up window's edge.
    save("reset.txt", one(lambda r, s: s == at("seam 11+10") and {"code": 0, "output": output("seam 11+10", 1)}))
    # A kernel that hashes the start-up window it should have discarded.
    save("startup.txt", one(lambda r, s: s == 0 and {"output": output("fair", 0)}))
    # One byte of an output flipped on the way.
    flipped = bytes([output("seam 10+10", 1)[0] ^ 1]) + output("seam 10+10", 1)[1:]
    save("digest.txt", one(lambda r, s: s == at("seam 10+10") and {"output": flipped}))
    # minstret one more than the RTL's for the spoiled stream.
    save("minstret.txt", one(lambda r, s: s == at("fair") and {"minstret": instret[2] + 1}))
    # One BITS line of the TRNG's stream in round 1 never arrived.
    save("lost.txt", [x for x in good if not x.startswith("BITS 00000001 00000000 00000002 ")])
    # The KAT line of round 0's spoiled stream never arrived.
    save("katlost.txt", [x for x in good if not x.startswith(f"KAT 00000000 {at('fair'):08x} ")])
    # Joined at the third BITS line of round 0's first stream.
    first = next(i for i, x in enumerate(good) if x.startswith("BITS 00000000 00000000 00000002 "))
    save("midstream.txt", good[first:])


def trust_board(expect_h, logs):
    """Each STREAM line of each log against trust.py and hashlib."""
    instret = expect_instret(expect_h)
    failed = 0
    for log in logs:
        n, bad = 0, []
        for t, words, other in logged_streams(log, 4):
            kat = [k for k in other.get("KAT", []) if len(k) == 5]
            if words is None or not kat:
                continue
            n += 1
            code, want, minstret, nd = (int(x, 16) for x in t[3:7])
            spoil, answer = int(kat[0][3], 16), bytes.fromhex(kat[0][4])
            sent = [d[4] for d in other.get("DIGEST", []) if len(d) == 5]
            c, writes, _ = trust_outcome(unpack(words), None, answering(answer))
            out = writes.get(OUTPUT)
            ok = (answer == (SPOILED if spoil else kat_want()) and code == c and want in (TRNG, c)
                  and minstret == instret[c] and nd == int(out is not None) and sent == ([out.hex()] if out else []))
            if not ok:
                bad.append(f"round {int(t[1], 16)} stream {int(t[2], 16)} ({' '.join(t[7:])}): "
                           f"code {code} minstret {minstret}, trust.py {c} and {instret[c]}")
        ok = n > 0 and not bad
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(log)}: {n} whole streams from a board, each KAT answer, "
              f"code, minstret and output as trust.py and hashlib give them{'' if ok else ' — ' + (bad[0] if bad else 'none')}")
        failed |= not ok
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(trust_board(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_trust_fixtures(sys.argv[1], sys.argv[2])
