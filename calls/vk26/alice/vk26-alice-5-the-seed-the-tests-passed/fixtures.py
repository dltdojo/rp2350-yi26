#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-5 — what seed.html is tested against, written from seed.py,
hashdrbg.py and trustref.py, which share nothing with the page: the lines a
board running vk26-alice-5 sends (shell/board_chip.c's formats), right and
wrong in each of the ways the page must tell apart.

  fixtures.py DIR EXPECT_H     writes DIR/*.txt, one log each
  fixtures.py --board EXPECT_H LOG...
                               every CASE a phone gave back, against NIST by
                               its name: V and C hashdrbg.py's Instantiate of
                               NIST's inputs, the second Generate's blocks
                               NIST's ReturnedBits; every CHAIN, done again
                               by seed.py from its BITS lines: the KAT's
                               answer hashlib's (one bit flipped when the
                               shell says it spoiled it), the code, and with 0
                               the digest, V and C and the blocks; every
                               minstret EXPECT_H's; PASS or FAIL. Then, as
                               measurements, each kind of run's mcycles

EXPECT_H is build/expect.h: the RTL's minstret, the interval, the blocks.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from seed import INTERVAL, nonce_of, seed_chain  # noqa: E402  (seed.py has put alice/tools on the path)
from hashdrbg import cavp_cases, drbg_generate, drbg_instantiate  # noqa: E402
from health import pack, unpack, window_bytes  # noqa: E402
from lines import bits_lines, spans, status_line  # noqa: E402
from trustref import OUTPUT, kat_want, sha256, trust_outcome, trust_streams  # noqa: E402

SERIAL = "vk26-alice-5"
# A board's mcycle for each kind of run, made up: Instantiate, Generate,
# alice-2's kernel, and in the chain Instantiate and Generate.
CYCLES = {"inst": 9100, "gen": 61234, "trust": 404000, "cinst": 9150, "cgen": 61300}


def seed_numbers(path):
    """build/expect.h's numbers, by name, and INSTRET_TRUST as a list."""
    text = open(path).read()
    e = {k: int(v) for k, v in re.findall(r"#define (\w+) (\d+)u?$", text, re.M)}
    e["INSTRET_TRUST"] = [int(x) for x in re.search(r"INSTRET_TRUST\[4\] = \{([^}]*)\}", text).group(1)
                          .replace("u", "").split(",")]
    return e


def one_bit(b, at=0):
    return b[:at] + bytes([b[at] ^ 1]) + b[at + 1:]


def spoiled_kat():
    return one_bit(kat_want())


def nist_lines(rnd, i, case, e, **change):
    """What board_nist sends for one case. `change` may give: state (k ->
    bytes), block (j -> bytes), run (n -> dict of fields), seed (bytes)."""
    seed = case["entropy"] + case["nonce"] + case["pers"]
    v, c, counter = drbg_instantiate(case["entropy"], case["nonce"], case["pers"])
    _, state = drbg_generate((v, c, counter), 32 * e["M"], INTERVAL)
    bits, _ = drbg_generate(state, 32 * e["M"], INTERVAL)
    sent = change.get("seed", seed)
    out = [f"SEED {rnd:08x} {i:08x} {len(sent):08x} {sent.hex()}"]
    for k, b in enumerate((v, c)):
        out.append(f"STATE {rnd:08x} {i:08x} {k:08x} {change.get('state', {}).get(k, b).hex()}")
    for j in range(e["M"]):
        out.append(f"BLOCK {rnd:08x} {i:08x} {j:08x} {change.get('block', {}).get(j, bits[32 * j:32 * j + 32]).hex()}")
    for n, (minstret, cyc) in enumerate(((e["INSTRET_INST"], CYCLES["inst"]), (e["INSTRET_GEN"], CYCLES["gen"]),
                                         (e["INSTRET_GEN"], CYCLES["gen"]))):
        f = {"minstret": minstret, "cycles": cyc}
        f.update(change.get("run", {}).get(n, {}))
        out.append(f"RUN {rnd:08x} {i:08x} {n:08x} {f['minstret']:08x} {f['cycles']:08x}")
    out.append(f"CASE {rnd:08x} {i:08x} {case['name']}")
    return out


def chain_lines(rnd, s, samples, e, **change):
    """What board_chain sends for chain s: the second has the KAT's answer
    spoiled. `change` may give: kat, code, digest (what was hashed, or the
    bytes sent), nonce, state (k -> bytes), block (j -> bytes), trust, run
    (n -> dict of fields), output (whether the output lines are sent)."""
    spoil = s
    kat = change.get("kat", spoiled_kat() if spoil else kat_want())
    code, writes, _ = trust_outcome(samples, None, lambda b: kat if len(b) == 64 else sha256(b))
    code = change.get("code", code)
    out = bits_lines(rnd, s, pack(samples))
    out.append(f"KAT {rnd:08x} {s:08x} {spoil:08x} {kat.hex()}")
    t = {"minstret": e["INSTRET_TRUST"][code], "cycles": CYCLES["trust"]}
    t.update(change.get("trust", {}))
    out.append(f"TRUST {rnd:08x} {s:08x} {code:08x} {t['minstret']:08x} {t['cycles']:08x}")
    if change.get("output", code == 0):
        digest = change.get("digest", writes.get(OUTPUT) or sha256(window_bytes(samples, 1)))
        v, c, counter = drbg_instantiate(digest, change.get("nonce", nonce_of(rnd)))
        bits, _ = drbg_generate((v, c, counter), 32 * e["M"], INTERVAL)
        out.append(f"DIGEST {rnd:08x} {s:08x} {change.get('sent', digest).hex()}")
        for k, b in enumerate((v, c)):
            out.append(f"CSTATE {rnd:08x} {s:08x} {k:08x} {change.get('state', {}).get(k, b).hex()}")
        for j in range(e["M"]):
            out.append(f"CBLOCK {rnd:08x} {s:08x} {j:08x} "
                       f"{change.get('block', {}).get(j, bits[32 * j:32 * j + 32]).hex()}")
        for n, (minstret, cyc) in enumerate(((e["INSTRET_INST_CHAIN"], CYCLES["cinst"]),
                                             (e["INSTRET_GEN"], CYCLES["cgen"]))):
            f = {"minstret": minstret, "cycles": cyc}
            f.update(change.get("run", {}).get(n, {}))
            out.append(f"CRUN {rnd:08x} {s:08x} {n:08x} {f['minstret']:08x} {f['cycles']:08x}")
    out.append(f"CHAIN {rnd:08x} {s:08x} {code:08x}")
    return out


def fair_samples(name="fair"):
    return [x & 1 for x in trust_streams()[name]]


def seed_rounds(e, n=2, cases=None, nist=None, chain=None, streams=None):
    """n rounds as a board sends them; nist(rnd, i) and chain(rnd, s) may
    return keyword arguments for nist_lines and chain_lines, and
    streams(rnd) the TRNG's samples for the round (trustref's fair stream
    when not)."""
    every = cases or cavp_cases()
    out = []
    for r in range(n):
        out.append(status_line(SERIAL, r))
        for i, case in enumerate(every):
            out += nist_lines(r, i, case, e, **((nist and nist(r, i)) or {}))
            if i == 3:
                out.append(status_line(SERIAL, r))
        samples = (streams and streams(r)) or fair_samples()
        for s in range(2):
            out += chain_lines(r, s, samples, e, **((chain and chain(r, s)) or {}))
        out.append("REVISION 00000001")
        out.append(f"ROUND {r:08x} {len(every):08x}")
    return out


def write_seed_fixtures(d, expect_h):
    os.makedirs(d, exist_ok=True)
    e = seed_numbers(expect_h)
    cases = cavp_cases()
    some = cases[:12]

    def save(name, lines):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for line in lines))

    def one(nist=None, chain=None, streams=None):
        return seed_rounds(e, 1, some, nist, chain, streams)

    def case_v(i):
        return drbg_instantiate(some[i]["entropy"], some[i]["nonce"], some[i]["pers"])

    def case_bits(i):
        _, state = drbg_generate(case_v(i), 32 * e["M"], INTERVAL)
        return drbg_generate(state, 32 * e["M"], INTERVAL)[0]

    fair = fair_samples()
    digest = sha256(window_bytes(fair, 1))
    v0, c0, _ = drbg_instantiate(digest, nonce_of(0))
    cbits = drbg_generate((v0, c0, 1), 32 * e["M"], INTERVAL)[0]

    save("good.txt", seed_rounds(e))
    # NIST: one bit of V after Instantiate, case 3.
    save("state.txt", one(nist=lambda r, i: i == 3 and {"state": {0: one_bit(case_v(3)[0], 54)}}))
    # NIST: one bit of the second Generate's block 2, case 5.
    save("block.txt", one(nist=lambda r, i: i == 5 and {"block": {2: one_bit(case_bits(5)[64:96], 9)}}))
    # NIST: the seed material sent one byte short, the rest the case's.
    short = some[6]["entropy"] + some[6]["nonce"] + some[6]["pers"]
    save("seed.txt", one(nist=lambda r, i: i == 6 and {"seed": short[:-1]}))
    # NIST: the Instantiate kernel's minstret one more than the RTL's.
    save("minstret.txt", one(nist=lambda r, i: i == 7 and {"run": {0: {"minstret": e["INSTRET_INST"] + 1}}}))
    # The chain: the digest of the start-up window, not the next one, and the
    # rest made from it.
    save("startup.txt", one(chain=lambda r, s: s == 0 and {"digest": sha256(window_bytes(fair, 0))}))
    # The chain: the digest right, one bit of it flipped on the way.
    save("digest.txt", one(chain=lambda r, s: s == 0 and {"sent": one_bit(digest, 31)}))
    # The chain: the nonce left out, Instantiate on the digest alone.
    save("nonce.txt", one(chain=lambda r, s: s == 0 and {"nonce": b""}))
    # The chain: one bit of C.
    save("cstate.txt", one(chain=lambda r, s: s == 0 and {"state": {1: one_bit(c0, 20)}}))
    # The chain: one bit of block 3.
    save("cblock.txt", one(chain=lambda r, s: s == 0 and {"block": {3: one_bit(cbits[96:], 0)}}))
    # The chain: Instantiate's minstret the one it has alone, not the chain's.
    save("cminstret.txt", one(chain=lambda r, s: s == 0 and {"run": {0: {"minstret": e["INSTRET_INST"]}}}))
    # The spoiled chain going on to 0: a kernel that never asked HASH the KAT.
    save("unchecked.txt", one(chain=lambda r, s: s == 1 and {"code": 0}))
    # The chip's SHA-256 block answering the KAT wrong, unspoiled: the chain is
    # right to stop, the board is not right.
    save("chip.txt", one(chain=lambda r, s: s == 0 and {"kat": spoiled_kat()}))
    # The TRNG stuck at 1 in round 0 and the run across the seam in round 1:
    # both chains stopped by the tests, with 1 and with 3, and nothing wrong.
    save("stopped.txt", seed_rounds(e, 2, some[:2], streams=lambda r: fair_samples(
        ("stuck at 1 from the start", "seam 11+10")[r])))
    # A BLOCK line of case 3 and a BITS line of chain 0 never arrived.
    lost = one()
    save("lost.txt", [x for x in lost if not x.startswith(("BLOCK 00000000 00000003 00000001 ",
                                                           "BITS 00000000 00000000 00000002 "))])
    # Joined in the middle of case 0.
    at = next(k for k, x in enumerate(lost) if x.startswith("BLOCK 00000000 00000000 00000002 "))
    save("midcase.txt", lost[at:])
    # Round 1's case 9: its first Generate took 30 cycles more.
    save("cycles.txt", seed_rounds(e, 2, some, nist=lambda r, i: (r, i) == (1, 9) and {
        "run": {1: {"cycles": CYCLES["gen"] + 30}}}))


def seed_log(log):
    """Every CASE and CHAIN of a log, in order: (kind, round, i, the line's
    other fields, {line kind: [fields]})."""
    parts, out = {}, []
    for line in open(log, encoding="utf-8", errors="replace"):
        t = line.split()
        if len(t) < 3 or not re.fullmatch(r"[0-9a-f]{8}", t[1]) or not re.fullmatch(r"[0-9a-f]{8}", t[2]):
            continue
        if t[0] in ("CASE", "CHAIN"):
            k = (t[0] == "CHAIN", t[1], t[2])
            out.append((t[0], int(t[1], 16), int(t[2], 16), t[3:], parts.pop(k, {})))
        elif t[0] in ("SEED", "STATE", "BLOCK", "RUN"):
            parts.setdefault((False, t[1], t[2]), {}).setdefault(t[0], []).append(t[3:])
        elif t[0] in ("BITS", "KAT", "TRUST", "DIGEST", "CSTATE", "CBLOCK", "CRUN"):
            parts.setdefault((True, t[1], t[2]), {}).setdefault(t[0], []).append(t[3:])
    return out


def seed_nist(e, nist, name, p):
    """A CASE's lines against NIST: why it is wrong, None if a line is missing."""
    state = {int(k, 16): bytes.fromhex(b) for k, b in p.get("STATE", [])}
    blocks = {int(j, 16): bytes.fromhex(b) for j, b in p.get("BLOCK", [])}
    runs = {int(r[0], 16): [int(x, 16) for x in r[1:]] for r in p.get("RUN", []) if len(r) == 3}
    if name not in nist or not p.get("SEED") or sorted(state) != [0, 1] or len(blocks) != e["M"] or sorted(runs) != [0, 1, 2]:
        return None
    case, why = nist[name], []
    if bytes.fromhex(p["SEED"][0][1]) != case["entropy"] + case["nonce"] + case["pers"]:
        why.append("the seed material is not NIST's")
    want = drbg_instantiate(case["entropy"], case["nonce"], case["pers"])
    if (state[0], state[1]) != want[:2]:
        why.append("V or C is not hashdrbg.py's instantiation of NIST's inputs")
    if b"".join(blocks[j] for j in range(e["M"])) != case["want"]:
        why.append("the second Generate's blocks are not NIST's ReturnedBits")
    if [runs[n][0] for n in range(3)] != [e["INSTRET_INST"], e["INSTRET_GEN"], e["INSTRET_GEN"]]:
        why.append(f"minstret {[runs[n][0] for n in range(3)]}")
    return why


def seed_again(e, rnd, code, p):
    """A CHAIN's lines against seed.py: why it is wrong, None if a line is missing."""
    bits = {int(k, 16): [int(x, 16) for x in w] for k, *w in p.get("BITS", []) if len(w) == 16}
    kat = [k for k in p.get("KAT", []) if len(k) == 2]
    trust = [[int(x, 16) for x in t] for t in p.get("TRUST", []) if len(t) == 3]
    if sorted(bits) != [0, 1, 2, 3] or not kat or not trust:
        return None
    samples = unpack(sum((bits[k] for k in range(4)), []))
    spoil, answer = int(kat[0][0], 16), bytes.fromhex(kat[0][1])
    why = []
    if answer != (spoiled_kat() if spoil else kat_want()):
        why.append("HASH's answer to the KAT is not hashlib's" + (" with the one bit flipped" if spoil else ""))
    due, want, _ = seed_chain(samples, nonce_of(rnd), e["M"], kat_want() if answer == kat_want() else spoiled_kat())
    if code != due or trust[0][0] != due or trust[0][1] != e["INSTRET_TRUST"][due]:
        why.append(f"code {code}, minstret {trust[0][1]}: seed.py says {due}")
    if due != 0:
        if p.get("DIGEST") or p.get("CBLOCK"):
            why.append("an output sent for a chain that stopped")
        return why
    state = {int(k, 16): bytes.fromhex(b) for k, b in p.get("CSTATE", [])}
    blocks = {int(j, 16): bytes.fromhex(b) for j, b in p.get("CBLOCK", [])}
    runs = {int(r[0], 16): int(r[1], 16) for r in p.get("CRUN", []) if len(r) == 3}
    if not p.get("DIGEST") or sorted(state) != [0, 1] or len(blocks) != e["M"] or sorted(runs) != [0, 1]:
        return None
    digest = sha256(window_bytes(samples, 1))
    if bytes.fromhex(p["DIGEST"][0][0]) != digest:
        why.append("the digest is not SHA-256 of window 1")
    if (state[0], state[1]) != drbg_instantiate(digest, nonce_of(rnd))[:2]:
        why.append("V or C is not Instantiate of the digest and the round's nonce")
    if b"".join(blocks[j] for j in range(e["M"])) != want:
        why.append("the blocks are not seed.py's")
    if (runs[0], runs[1]) != (e["INSTRET_INST_CHAIN"], e["INSTRET_GEN"]):
        why.append(f"minstret {runs[0]} {runs[1]}")
    return why


def seed_board_notes(log):
    """What the README says of a log beyond each verdict, as a check's output:
    where the page joined and saved; for the whole NIST cases only, each
    run's mcycle by the seed material's length, which cases had a run slower
    than the least for its kind, and those seen whole in both rounds."""
    seed, runs, cases, last, status = {}, {}, set(), None, []
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.search(r" usb=.* dropped=(\d+) errors=(\d+) ", line)
        if m:
            status.append((int(m.group(1)), int(m.group(2))))
        t = line.split()
        if len(t) < 3 or not re.fullmatch(r"[0-9a-f]{8}", t[1]) or not re.fullmatch(r"[0-9a-f]{8}", t[2]):
            continue
        k = (int(t[1], 16), int(t[2], 16))
        if t[0] in ("SEED", "STATE", "BLOCK", "RUN", "CASE"):
            last = k
        if t[0] == "SEED" and len(t) == 5:
            seed[k] = int(t[3], 16)
        elif t[0] == "RUN" and len(t) == 6:
            runs.setdefault(k, {})[int(t[3], 16)] = int(t[5], 16)
        elif t[0] == "CASE":
            cases.add(k)
    whole = sorted(k for k in cases if k in seed and sorted(runs.get(k, {})) == [0, 1, 2])
    print(f"      the log: from round {min(runs)[0]}'s case {min(runs)[1]} to round {last[0]}'s case {last[1]}; "
          f"whole NIST cases {len(whole)}")
    least = {}
    for s in sorted({seed[k] for k in whole}):
        mine = [k for k in whole if seed[k] == s]
        for n, name in enumerate(("Instantiate", "Generate 1", "Generate 2")):
            got = sorted(runs[k][n] for k in mine)
            least[(s, n)] = got[0]
            print(f"      seed material {s} bytes, {len(mine)} cases: {name} {got[0]} in {got.count(got[0])}, "
                  f"up to {got[-1]}")
    slow = {k for k in whole if any(runs[k][n] != least[(seed[k], n)] for n in range(3))}
    for r in sorted({k[0] for k in whole}):
        print(f"      round {r}: a run slower than its least in cases {spans(i for rr, i in slow if rr == r)}")
    both = [i for i in range(256) if (0, i) in whole and (1, i) in whole]
    print(f"      cases whole in rounds 0 and 1: {len(both)}; slow in both: {sum((0, i) in slow and (1, i) in slow for i in both)}")
    print(f"      status lines: {len(status)}, dropped {sorted({d for d, _ in status})}, errors {sorted({e for _, e in status})}")


def seed_board(expect_h, logs):
    """Each CASE and CHAIN of each log against NIST and seed.py; then the mcycles, as read."""
    e = seed_numbers(expect_h)
    nist = {c["name"]: c for c in cavp_cases()}
    failed = 0
    for log in logs:
        n, chains, codes, bad, incomplete = 0, 0, {}, [], 0
        cycles = {k: {} for k in ("Instantiate", "Generate", "alice-2's kernel", "Instantiate in the chain",
                                  "Generate in the chain")}

        def saw(kind, x):
            cycles[kind][x] = cycles[kind].get(x, 0) + 1

        for kind, rnd, i, tail, p in seed_log(log):
            if kind == "CASE":
                why = seed_nist(e, nist, " ".join(tail), p)
                if why is None:
                    incomplete += 1
                    continue
                n += 1
                for r in p["RUN"]:
                    saw("Instantiate" if int(r[0], 16) == 0 else "Generate", int(r[2], 16))
            else:
                why = seed_again(e, rnd, int(tail[0], 16) if tail else -1, p)
                if why is None:
                    incomplete += 1
                    continue
                chains += 1
                code = int(tail[0], 16)
                codes[code] = codes.get(code, 0) + 1
                if code == 0:
                    saw("alice-2's kernel", int(p["TRUST"][0][2], 16))
                    for r in p["CRUN"]:
                        saw("Instantiate in the chain" if int(r[0], 16) == 0 else "Generate in the chain", int(r[2], 16))
            if why:
                bad.append(f"round {rnd} {kind.lower()} {i}: {'; '.join(why)}")
        ok = n > 0 and chains > 0 and not bad
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(log)}: {n} whole NIST cases and {chains} whole chains "
              f"from a board (codes {' '.join(f'{c}×{k}' for c, k in sorted(codes.items()))}), {incomplete} incomplete; "
              f"every case NIST's, every chain seed.py's from its samples, every minstret the RTL's"
              f"{'' if ok else ' — ' + (bad[0] if bad else 'none')}")
        failed |= not ok
        for kind, seen in cycles.items():
            if seen:
                print(f"      mcycle of {kind}: " + "; ".join(f"{c} in {k}" for c, k in sorted(seen.items())))
        if n:
            seed_board_notes(log)
    return failed


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--board":
        sys.exit(seed_board(sys.argv[2], sys.argv[3:]))
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_seed_fixtures(sys.argv[1], sys.argv[2])
