#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — what script.html holds, and what it is tested against.

  page_cases.py --write PAGE        put the 33 cases in PAGE, between
                                    `// BEGIN cases` and `// END cases`: each
                                    case's name, script, starting stack and the
                                    minstret build/expect.h says the chip counts
  page_cases.py --check PAGE        the same, and fail if PAGE holds anything else
  page_cases.py --fixtures DIR      what page_test.mjs feeds the page:
      verdicts.jsonl   every hand case, 672 of arithmetic and 300 fuzzed, each
                       with script.py's code and the signatures it checks
      sha256.jsonl     hashlib's SHA-256 of every length from 0 to 200 bytes
      bip340.jsonl     BIP340's test vectors, and 40 signatures reference.py
                       made, every other one with a bit flipped
      good.txt         two rounds as board_chip.c prints them, with status lines
      *.txt            the same, wrong in one way each

The page's verdicts are its own: nothing here is in the page but the cases.
"""
import hashlib
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cases                                   # noqa: E402
from cases import bip340                       # noqa: E402
from script import script_verdict              # noqa: E402

STATUS = ("exp228 usb=6 setups=31 stalls=3 dropped={dropped} errors=0 ref=00000000 sys=00000000 xosc=00000000 "
          "pll=00000001 usb_khz=47989 sys_khz=10955 sys48_khz=47998 ref_khz=10954 sof_khz=47999 "
          "lives={round} minstret={minstret}")


def counted_verdict(script, stack):
    """script.py's code, and how many signatures it asked about and found valid."""
    asked = []

    def sig(pk, s):
        asked.append(cases.valid(pk, s))
        return asked[-1]

    code = script_verdict(script, stack, sig=sig, h=lambda b: hashlib.sha256(b).digest())
    return code, len(asked), sum(asked)


def expect_minstret(expect_h):
    out = {}
    for line in open(expect_h):
        m = re.match(r'    \{"(.*)", \d+, \d+, \d+, \d+, (\d+), (\d+)\},$', line)
        if m:
            out[m.group(1)] = int(m.group(3))
    return out


def cases_block():
    minstret = expect_minstret(os.path.join(HERE, "build", "expect.h"))
    lines = ["// BEGIN cases — written by page_cases.py from cases.py and build/expect.h; check.sh holds it to them",
             f"const MSG_HEX = '{cases.MSG.hex()}';",
             "const CASES = ["]
    for name, (script, stack, _) in cases.hand().items():
        elems = ", ".join(f"'{e.hex()}'" for e in stack)
        lines.append(f"  {{ name: {json.dumps(name)}, script: '{script.hex()}', stack: [{elems}], "
                     f"minstret: {minstret[name]} }},")
    lines += ["];", "// END cases"]
    return "\n".join(lines) + "\n"


def page_with_cases(page):
    html = open(page, encoding="utf-8").read()
    a = html.index("// BEGIN cases")
    b = html.index("// END cases\n") + len("// END cases\n")
    return html, html[:a] + cases_block() + html[b:]


def board_lines(rounds=(3, 4), every=3):
    """[(round, i, line)] as board_chip.c prints them, a status line every few cases."""
    minstret = expect_minstret(os.path.join(HERE, "build", "expect.h"))
    out = []
    for r in rounds:
        last = 0
        for i, (name, (script, stack, _)) in enumerate(cases.hand().items()):
            code, sigs, valid = counted_verdict(script, stack)
            out.append((r, i, f"CASE {r:08x} {i:08x} {code:08x} {code:08x} {minstret[name]:08x} "
                              f"{sigs:08x} {valid:08x} {name}"))
            last = minstret[name]
            if i % every == every - 1:
                out.append((r, None, STATUS.format(dropped=0, round=r, minstret=last)))
        out.append((r, None, f"ROUND {r:08x} {len(cases.hand()):08x}"))
    return out


def stream_fixtures(d):
    def save(name, items):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for _, _, line in items))

    def field(line, k, v):
        w = line.split(" ", 8)
        w[k] = f"{v:08x}"
        return " ".join(w)

    good = board_lines()
    save("good.txt", good)
    def one(r, i, change):
        return [(a, b, change(line) if (a, b) == (r, i) else line) for a, b, line in good]

    save("code.txt", one(3, 6, lambda l: field(l, 3, 1)))           # case 6 halts with 1
    save("want.txt", one(3, 11, lambda l: field(l, 4, 0)))          # case 11 carries the verdict 0
    save("minstret.txt", one(4, 12, lambda l: field(l, 5, int(l.split()[5], 16) + 1)))
    save("sigs.txt", one(3, 8, lambda l: field(l, 7, 0)))           # a valid signature said invalid
    save("name.txt", one(4, 2, lambda l: l.replace("7-9=-2", "7-9=2")))
    save("missing.txt", [x for x in good if (x[0], x[1]) != (3, 20)])
    first = next(k for k, (_, i, _) in enumerate(good) if i is None)
    save("dropped.txt", [(a, b, line.replace("dropped=0", "dropped=4") if k == first else line)
                         for k, (a, b, line) in enumerate(good)])
    save("fail.txt", good[:10] + [(3, None, "FAIL 00000003 0000006f")])


def verdict_fixtures(d):
    hand = [(s, st) for s, st, _ in cases.hand().values()]
    arith = [(s, []) for _, s in cases.arith()]
    with open(os.path.join(d, "verdicts.jsonl"), "w") as f:
        for script, stack in hand + arith + cases.fuzz(300):
            code, sigs, valid = counted_verdict(script, stack)
            f.write(json.dumps({"script": script.hex(), "stack": [e.hex() for e in stack],
                                "code": code, "sigs": sigs, "valid": valid}) + "\n")
    with open(os.path.join(d, "counts.txt"), "w") as f:
        f.write(f"{len(hand)} {len(arith)} 300\n")


def sha_fixtures(d):
    rng = random.Random(2281)
    with open(os.path.join(d, "sha256.jsonl"), "w") as f:
        for n in range(201):
            b = rng.randbytes(n)
            f.write(json.dumps({"in": b.hex(), "out": hashlib.sha256(b).hexdigest()}) + "\n")


def bip340_fixtures(d):
    rows = []
    for line in open(os.path.join(HERE, "bip340", "test-vectors.csv")).read().splitlines()[1:]:
        w = line.split(",")
        rows.append({"pk": w[2].lower(), "msg": w[4].lower(), "sig": w[5].lower(), "ok": w[6] == "TRUE",
                     "from": f"vector {w[0]}"})
    rng = random.Random(2280)
    for k in range(40):
        sk = rng.randbytes(32)
        msg = rng.randbytes(rng.choice([0, 1, 32, 100]))
        sig = bytearray(bip340.schnorr_sign(msg, sk, rng.randbytes(32)))
        if k % 2:
            sig[rng.randrange(64)] ^= 1 << rng.randrange(8)
        pk = bip340.pubkey_gen(sk)
        rows.append({"pk": pk.hex(), "msg": msg.hex(), "sig": bytes(sig).hex(),
                     "ok": bip340.schnorr_verify(msg, pk, bytes(sig)), "from": f"drawn {k}"})
    with open(os.path.join(d, "bip340.jsonl"), "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)


if __name__ == "__main__":
    what, arg = sys.argv[1], sys.argv[2]
    if what == "--write":
        old, new = page_with_cases(arg)
        open(arg, "w", encoding="utf-8").write(new)
    elif what == "--check":
        old, new = page_with_cases(arg)
        if old != new:
            print(f"FAIL  {arg} holds the 33 cases as cases.py and build/expect.h have them — it does not: "
                  "run page_cases.py --write")
            sys.exit(1)
        print(f"PASS  {arg} holds the 33 cases as cases.py and build/expect.h have them")
    elif what == "--fixtures":
        os.makedirs(arg, exist_ok=True)
        verdict_fixtures(arg)
        sha_fixtures(arg)
        bip340_fixtures(arg)
        stream_fixtures(arg)
    else:
        sys.exit(__doc__)
