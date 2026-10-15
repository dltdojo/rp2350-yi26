#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-4 — what drbg.html is tested against, written from drbg.py,
which shares nothing with the page: the lines a board running vk26-alice-4
sends (shell/board_chip.c's formats), right and wrong in each of the ways
the page must tell apart.

  fixtures.py DIR EXPECT_H     writes DIR/*.txt, one log each, and DIR/edge.txt:
                               two blocks and V from V and C all ones
  fixtures.py --board EXPECT_H LOG...
                               every CASE a phone gave back, against NIST:
                               V and C as drbg.py instantiates them from
                               NIST's inputs, the first Generate's blocks and
                               V drbg.py's, the second's blocks NIST's
                               ReturnedBits, every halt code, counter and
                               minstret EXPECT_H's; PASS or FAIL. Then, as
                               measurements, each run's mcycles

EXPECT_H is build/expect.h: the RTL's minstret, the interval, the blocks.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from drbg import cavp_cases, drbg_generate, drbg_instantiate  # noqa: E402
from lines import spans, status_line  # noqa: E402

SERIAL = "vk26-alice-4"
COUNTER0 = 1
# A board's mcycle for each of a case's three runs, made up.
CYCLES = (61234, 61190, 40)


def expect(path):
    """build/expect.h's numbers, by name."""
    text = open(path).read()
    return {k: int(v) for k, v in re.findall(r"#define (\w+) (\d+)u?$", text, re.M)}


def case_lines(rnd, i, case, e, **change):
    """What the board sends for one case. `change` may give: state (k -> bytes),
    block ((n, j) -> bytes), run (n -> dict of fields), cycles (n -> mcycle)."""
    m, interval = e["M"], e["INTERVAL"]
    v, c, _ = drbg_instantiate(case["entropy"], case["nonce"], case["pers"])
    state, counter = (v, c, COUNTER0), COUNTER0
    out = []

    def st(k, b):
        b = change.get("state", {}).get(k, b)
        out.append(f"STATE {rnd:08x} {i:08x} {k:08x} {b.hex()}")

    def run(n, code, counter):
        f = {"code": code, "counter": counter, "minstret": e["INSTRET_GEN"] if code == 0 else e["INSTRET_RESEED"],
             "cycles": change.get("cycles", {}).get(n, CYCLES[n - 1])}
        f.update(change.get("run", {}).get(n, {}))
        out.append(f"RUN {rnd:08x} {i:08x} {n:08x} {f['code']:08x} {f['counter']:08x} {f['minstret']:08x} "
                   f"{f['cycles']:08x}")

    st(0, v)
    st(1, c)
    for n in (1, 2, 3):
        made = drbg_generate(state, 32 * m, interval)
        if made is None:
            run(n, 1, counter)
            continue
        bits, state = made
        for j in range(m):
            out.append(f"BLOCK {rnd:08x} {i:08x} {n:08x} {j:08x} "
                       f"{change.get('block', {}).get((n, j), bits[32 * j:32 * j + 32]).hex()}")
        st(n + 1, state[0])
        counter = state[2]
        run(n, 0, counter)
    out.append(f"CASE {rnd:08x} {i:08x} {case['name']}")
    return out


def drbg_rounds(e, n=2, change=None, cases=None):
    """n rounds as a board sends them; change(rnd, i) may return keyword
    arguments for case_lines."""
    every = cases or cavp_cases()
    out = []
    for r in range(n):
        out.append(status_line(SERIAL, r))
        for i, case in enumerate(every):
            out += case_lines(r, i, case, e, **((change and change(r, i)) or {}))
            if i == 3:
                out.append(status_line(SERIAL, r))
        out.append("REVISION 00000001")
        out.append(f"ROUND {r:08x} {len(every):08x}")
    return out


def flip(b, at=0):
    return b[:at] + bytes([b[at] ^ 1]) + b[at + 1:]


def write_drbg_fixtures(d, expect_h):
    os.makedirs(d, exist_ok=True)
    e = expect(expect_h)
    cases = cavp_cases()

    def save(name, lines):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for line in lines))

    def bits_of(i, n, j):
        state = drbg_instantiate(cases[i]["entropy"], cases[i]["nonce"], cases[i]["pers"])
        for _ in range(n):
            bits, state = drbg_generate(state, 32 * e["M"], e["INTERVAL"])
        return bits[32 * j:32 * j + 32], state

    # V and C all ones: data + 1 wraps to zero, and so does V + H + C + 1.
    ff = b"\xff" * 55
    bits, (v2, _, _) = drbg_generate((ff, ff, 1), 64)
    with open(os.path.join(d, "edge.txt"), "w") as f:
        f.write(f"{bits.hex()} {v2.hex()}\n")

    good = drbg_rounds(e)
    save("good.txt", good)
    one = lambda which: drbg_rounds(e, 1, which, cases[:12])  # noqa: E731
    # One bit of the second Generate's block 1, case 5.
    save("block.txt", one(lambda r, i: i == 5 and {"block": {(2, 1): flip(bits_of(5, 2, 1)[0], 7)}}))
    # One bit of V after the first Generate, case 2: what the second starts from is the page's own.
    save("vnext.txt", one(lambda r, i: i == 2 and {"state": {2: flip(bits_of(2, 1, 0)[1][0], 54)}}))
    # The first Generate leaves the counter at 3.
    save("counter.txt", one(lambda r, i: i == 4 and {"run": {1: {"counter": 3}}}))
    # The third run generates instead of refusing.
    save("reseed.txt", one(lambda r, i: i == 6 and {"run": {3: {"code": 0}}}))
    # The second Generate's minstret one more than the RTL's.
    save("minstret.txt", one(lambda r, i: i == 7 and {"run": {2: {"minstret": e["INSTRET_GEN"] + 1}}}))
    # One BLOCK line never arrived.
    short = drbg_rounds(e, 1, None, cases[:12])
    save("lost.txt", [x for x in short if not x.startswith("BLOCK 00000000 00000003 00000002 00000001 ")])
    # Joined in the middle of case 0's first Generate.
    at = next(k for k, x in enumerate(short) if x.startswith("BLOCK 00000000 00000000 00000001 00000002 "))
    save("midcase.txt", short[at:])
    # Round 1's case 9: its first Generate took 30 cycles more.
    save("cycles.txt", drbg_rounds(e, 2, lambda r, i: (r, i) == (1, 9) and {"cycles": {1: CYCLES[0] + 30}}, cases[:12]))


def log_cases(log):
    """Every case of a log, in order: (round, i, name, {line kind: [fields]})."""
    parts, out = {}, []
    for line in open(log, encoding="utf-8", errors="replace"):
        t = line.split()
        if len(t) < 3 or t[0] not in ("STATE", "BLOCK", "RUN", "CASE"):
            continue
        k = (t[1], t[2])
        if t[0] == "CASE":
            out.append((int(t[1], 16), int(t[2], 16), " ".join(t[3:]), parts.pop(k, {})))
        else:
            parts.setdefault(k, {}).setdefault(t[0], []).append(t[3:])
    return out


def drbg_board_notes(log):
    """What the README says of a log beyond each case's verdict, printed so
    that it is a check's output and not a reading of the log: where the page
    joined and saved, which cases never came whole, which first Generates
    and reseed checks were slow, the cases seen whole in both rounds, and
    the status lines' `dropped`."""
    runs, cases, ends, status, last = {}, set(), {}, [], None
    for n, line in enumerate(open(log, encoding="utf-8", errors="replace"), 1):
        t = line.split()
        if len(t) >= 3 and t[0] in ("STATE", "BLOCK", "RUN", "CASE") and re.fullmatch(r"[0-9a-f]{8}", t[1]):
            last = (int(t[1], 16), int(t[2], 16), n)
            ends[last[:2]] = n
            if t[0] == "RUN" and len(t) == 8:
                runs.setdefault(last[:2], {})[int(t[3], 16)] = int(t[7], 16)
            if t[0] == "CASE":
                cases.add(last[:2])
        m = re.search(r" usb=.* dropped=(\d+) ", line)
        if m:
            status.append((n, int(m.group(1))))
    whole = {k for k in cases if sorted(runs.get(k, {})) == [1, 2, 3]}
    print(f"      the log: from round {min(runs)[0]}'s case {min(runs)[1]} to round {last[0]}'s case {last[1]} (line {last[2]})")
    for r in sorted({k[0] for k in cases}):
        seen = [i for rr, i in cases if rr == r]
        lo, hi = min(seen), max(seen)
        gone = [i for i in range(lo, hi + 1) if (r, i) not in cases]
        print(f"      round {r}: CASE lines for {lo}–{hi}; none for {spans(gone)}"
              f"{f' (the first gap after line {ends[(r, gone[0] - 1)]})' if gone and (r, gone[0] - 1) in ends else ''}; "
              f"incomplete {spans(i for rr, i in cases if rr == r and (rr, i) not in whole)}")
    fast = min(runs[k][1] for k in whole)
    for r in sorted({k[0] for k in whole}):
        print(f"      round {r}: first Generate slower than {fast} in cases {spans(i for rr, i in whole if rr == r and runs[(rr, i)][1] != fast)}; "
              f"reseed check slower than its least in {spans(i for rr, i in whole if rr == r and runs[(rr, i)][3] != min(runs[k][3] for k in whole))}")
    both = [i for i in range(256) if (0, i) in whole and (1, i) in whole]
    print(f"      cases seen whole in rounds 0 and 1: {len(both)}; the first Generate's mcycle the same in both: "
          f"{sum(runs[(0, i)][1] == runs[(1, i)][1] for i in both)}")
    print(f"      status lines: {len(status)}, dropped {sorted({d for _, d in status})}, the last at line {status[-1][0] if status else '-'}")


def drbg_board(expect_h, logs):
    """Each CASE of each log against NIST and drbg.py; then the mcycles, as read."""
    e = expect(expect_h)
    nist = {c["name"]: c for c in cavp_cases()}
    failed = 0
    for log in logs:
        n, bad, incomplete, cycles = 0, [], 0, ({}, {}, {})
        for rnd, i, name, p in log_cases(log):
            state = {int(k, 16): bytes.fromhex(b) for k, b in p.get("STATE", [])}
            blocks = {(int(a, 16), int(b, 16)): bytes.fromhex(x) for a, b, x in p.get("BLOCK", [])}
            runs = {int(r[0], 16): [int(x, 16) for x in r[1:]] for r in p.get("RUN", []) if len(r) == 5}
            if name not in nist or sorted(state) != [0, 1, 2, 3] or len(blocks) != 2 * e["M"] or sorted(runs) != [1, 2, 3]:
                incomplete += 1
                continue
            n += 1
            case = nist[name]
            want = drbg_instantiate(case["entropy"], case["nonce"], case["pers"])
            why = []
            if (state[0], state[1]) != want[:2]:
                why.append("V or C is not drbg.py's instantiation of NIST's inputs")
            s = want
            for k in (1, 2, 3):
                made = drbg_generate(s, 32 * e["M"], e["INTERVAL"])
                code, counter, minstret, cyc = runs[k]
                cycles[k - 1].setdefault(cyc, []).append(f"{rnd}:{i}")
                if made is None:
                    if (code, counter, minstret) != (1, s[2], e["INSTRET_RESEED"]):
                        why.append(f"run {k}: halt {code}, counter {counter}, minstret {minstret}")
                    continue
                bits, s = made
                got = b"".join(blocks[(k, j)] for j in range(e["M"]))
                if got != bits or (k == 2 and got != case["want"]):
                    why.append(f"Generate {k}'s blocks are not {'NIST' if k == 2 else 'drbg.py'}'s")
                if state[k + 1] != s[0] or (code, counter, minstret) != (0, s[2], e["INSTRET_GEN"]):
                    why.append(f"Generate {k}: V, or halt {code}, counter {counter}, minstret {minstret}")
            if why:
                bad.append(f"round {rnd} case {i} ({name}): {'; '.join(why)}")
        ok = n > 0 and not bad
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(log)}: {n} whole cases from a board, {incomplete} "
              f"incomplete; V and C NIST's inputs instantiated, the second Generate's 1024 bits NIST's, the first's "
              f"drbg.py's, every halt, counter and minstret the RTL's{'' if ok else ' — ' + (bad[0] if bad else 'none')}")
        failed |= not ok
        for k, name in enumerate(("Generate 1", "Generate 2", "the reseed check")):
            if cycles[k]:
                print(f"      mcycle of {name}: " + "; ".join(f"{c} in {len(w)}" for c, w in sorted(cycles[k].items())))
        if n:
            drbg_board_notes(log)
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(drbg_board(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_drbg_fixtures(sys.argv[1], sys.argv[2])
