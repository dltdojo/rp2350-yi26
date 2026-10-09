# SPDX-License-Identifier: Apache-2.0
"""exp224 — the judge's input and its verdict, in Python.

  RECORDS, SIZE           three records of 0x100 bytes from base + 0x1000
  record(...)             one record's bytes
  image(judge, records)   the judge at base, the records after it
  verdict(records)        what proof/Judge.lean's specification says the
                          judge halts with: verdict | source << 3 | failures << 6
  cases()                 name -> three records: the shell's three sources as
                          exp223's chip run had them, and each check made to
                          fail alone, in each source, and some together
"""
import random
import struct

RECORDS, SIZE = 0x1000, 0x100
PASS, FAIL = 334287, 17428


def record(cause=8, t0=1, a0=0, instret=PASS, shaok=1, kh=None, ksha=None, dig=None, want=None,
           after=None, before=None, pas=PASS, fail=FAIL):
    h = bytes(range(32))
    fields = struct.pack("<8I", cause, t0, a0, instret, pas, fail, shaok, 0)
    for v in (kh, ksha, dig, want, after, before):
        fields += h if v is None else v
    return fields + bytes(SIZE - len(fields))


def image(judge, records):
    img = bytearray(RECORDS + SIZE * len(records))
    img[:len(judge)] = judge
    for i, r in enumerate(records):
        img[RECORDS + SIZE * i:RECORDS + SIZE * (i + 1)] = r
    return bytes(img)


def words(r, off):
    return struct.unpack_from("<8I", r, off)


def failures(r):
    cause, t0, a0, instret, pas, fail, shaok = struct.unpack_from("<7I", r, 0)
    halted = cause == 8 and t0 == 1
    ok = [
        words(r, 0x20) == words(r, 0x40) and shaok != 0,
        halted and a0 <= 1,
        instret == (pas if a0 == 0 else fail),
        not (halted and a0 == 0) or words(r, 0x60) == words(r, 0x80),
        words(r, 0xa0) == words(r, 0xc0),
    ]
    return sum(1 << k for k, good in enumerate(ok) if not good), a0


def verdict(records):
    for s, r in enumerate(records):
        bad, a0 = failures(r)
        if bad:
            return 1 | s << 3 | bad << 6
        if s == 0 and a0 != 0:
            return 3
        if s != 0 and a0 != 1:
            return 4 | s << 3
    return 0


def cases():
    other = bytes(range(1, 33))
    good = [record(), record(a0=1, instret=FAIL), record(a0=1, instret=FAIL)]
    out = {"as on the chip: the TRNG passed, both broken sources withheld": good}
    wrong = {
        "the kernel's hash is not kernel.sha256's": dict(kh=other),
        "the SHA-256 block reported an error": dict(shaok=0),
        "it faulted, mcause 5": dict(cause=5),
        "an ecall that was not HALT, t0 0": dict(t0=0),
        "it halted with 2": dict(a0=2),
        "one instruction more than the RTL's": dict(delta=1),
        "the region's hash changed": dict(after=other),
    }
    for s in range(3):
        for what, change in wrong.items():
            rs = list(good)
            base = dict(a0=0, instret=PASS) if s == 0 else dict(a0=1, instret=FAIL)
            if "delta" in change:
                base["instret"] += change["delta"]
            else:
                base.update(change)
            rs[s] = record(**base)
            out[f"source {s}: {what}"] = rs
    out["source 0: the digest is not the samples' SHA-256"] = [record(dig=other)] + good[1:]
    out["source 1: a wrong digest, but it halted with 1, so check 4 does not apply"] = \
        [good[0], record(a0=1, instret=FAIL, dig=other), good[2]]
    out["source 0: the TRNG's samples withheld, HALT 1"] = [record(a0=1, instret=FAIL)] + good[1:]
    out["source 1: let through, HALT 0"] = [good[0], record(), good[2]]
    out["source 2: let through, HALT 0"] = good[:2] + [record()]
    out["source 0: withheld and a wrong count: the failure wins"] = \
        [record(a0=1, instret=FAIL + 1)] + good[1:]
    out["source 1 let through, source 2 faulted: the first one wins"] = \
        [good[0], record(), record(cause=5, a0=1, instret=FAIL)]
    out["source 0: every check fails"] = \
        [record(cause=8, t0=1, a0=0, instret=0, shaok=0, kh=other, dig=other, after=other)] + good[1:]
    r = random.Random(224)
    for k in range(30):
        recs = []
        for src in range(3):
            pick = lambda a, b: a if r.random() < 0.9 else b  # noqa: E731
            a0 = pick(0 if src == 0 else 1, r.choice([0, 1, 2]))
            recs.append(record(cause=pick(8, r.choice([0, 2, 5, 7, 9])), t0=pick(1, r.choice([0, 2, 3])),
                               a0=a0, instret=pick(PASS if a0 == 0 else FAIL, r.choice([PASS, FAIL, PASS + 1, 0])),
                               shaok=pick(1, 0), kh=pick(None, other), dig=pick(None, other),
                               after=pick(None, other)))
        out[f"random {k}"] = recs
    return out
