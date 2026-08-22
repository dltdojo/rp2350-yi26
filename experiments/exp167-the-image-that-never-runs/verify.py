#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check exp167's transcript against itself, off the board.

    python3 verify.py < capture.txt

Prints OK, DISAGREE or INCOMPLETE on the last line.

Two voices: `>>> host:` lines from the machine that built and signed each
request, and `[ ms]` lines from the board. Neither is trusted about the other.
What is derived here:

  - the board's digest equals the host's, for every request the board could
    read. A verifier that reports only pass or fail can be trusted and cannot
    be checked.
  - the board read the region the host named.
  - every verdict matches what the host expected, and the refusals come from
    the right layer: a truncated frame and an unreadable region are the
    plumbing's business, a bad signature is the cryptography's.
  - **the unreadable request produced no digest at all.** That is the whole
    guard: the board refused an address it could not reach without
    dereferencing it. A digest there would mean it read first and checked
    afterwards, which on this chip is a bus error and a board you cannot
    reflash.
  - exactly one request started a trial, it is the one the host signed
    correctly, and slot B ran only after it.
  - slot B was provisional, did not buy, and the board came back to slot A.

What it does not derive: the rule that maps a virtual XIP offset to a QMI
aperture. The register values are printed and checked for self-consistency;
turning them into a translation rule needs the RP2350 datasheet, and this
prints OPEN rather than guessing.
"""

import re
import sys

HOST = re.compile(
    r"^>>> host: mode=(?P<mode>\S+) expect=(?P<expect>ACCEPTED|REFUSED) "
    r"trial=(?P<trial>true|false) virtual=(?P<virt>0x[0-9a-f]+) len=(?P<len>0x[0-9a-f]+) "
    r"physical=(?P<phys>0x[0-9a-f]+) sha256=(?P<sha>[0-9a-f]{64})\s*$"
)
REQ = re.compile(r"^--- request #(?P<n>\d+): (?P<len>\d+) byte frame\s*$")
REGION = re.compile(r"^\s*region: offset=(?P<off>0x[0-9a-f]+) len=(?P<len>\d+) ")
SHA = re.compile(r"^\s*sha256 = (?P<sha>[0-9a-f]{64})\s*$")
OK_ = re.compile(r"^\s*ACCEPTED: ")
NO_ = re.compile(r"^\s*REFUSED \((?P<layer>plumbing|cryptography)\): (?P<why>.+?)\s*$")
ATRANS = re.compile(
    r"^\s*ATRANS(?P<n>\d): base=(?P<base>0x[0-9a-f]+) size=(?P<size>0x[0-9a-f]+) "
    r"-> phys (?P<lo>0x[0-9a-f]+)\.\.(?P<hi>0x[0-9a-f]+), (?P<kib>\d+) KiB\s*$"
)
PROBE = re.compile(
    r"^\s{2}(?P<what>\S.*?)\s+(?P<off>0x[0-9a-f]{7})\s+(?:READ\s+(?P<digest>[0-9a-f]{24})|REFUSED: (?P<why>.+?))\s*$"
)


def strip(line):
    return re.sub(r"^\[\s*\d+ ms\]\s?", "", line.rstrip("\n"))


def main():
    lines = [strip(x) for x in sys.stdin]
    problems, notes = [], []

    if not any("waiting for a signature" in l for l in lines):
        print("slot A never reached the point of waiting for a signature")
        print("INCOMPLETE")
        return 1
    if any("lines lost" in l for l in lines):
        problems.append("the log has a gap: usb-log dropped lines")

    # ---- the aperture map has to be self-consistent -----------------------
    apertures = {}
    for l in lines:
        m = ATRANS.match(l)
        if not m:
            continue
        n, base, size = int(m.group("n")), int(m.group("base"), 16), int(m.group("size"), 16)
        apertures[n] = (base, size)
        if base * 4096 != int(m.group("lo"), 16):
            problems.append(f"ATRANS{n}: the decoded base does not follow from BASE")
        if (base + size) * 4096 != int(m.group("hi"), 16):
            problems.append(f"ATRANS{n}: the decoded top does not follow from BASE+SIZE")
        if size * 4 != int(m.group("kib")):
            problems.append(f"ATRANS{n}: the KiB figure does not follow from SIZE")
    if len(apertures) != 8:
        problems.append(f"{len(apertures)} apertures printed; QMI has eight")
    else:
        a0 = apertures[0]
        notes.append(f"aperture 0: {a0[1] * 4} KiB onto flash from {a0[0] * 4096:#x}")
        closed = [n for n, (_, s) in apertures.items() if s == 0]
        notes.append(f"apertures sized to zero: {closed or 'none'}")

    # ---- the probes must agree with the apertures they were checked against
    for l in lines:
        m = PROBE.match(l)
        if not m:
            continue
        off = int(m.group("off"), 16)
        idx = off // 0x400000
        if idx not in apertures:
            continue
        size_bytes = apertures[idx][1] * 4096
        reachable = (off % 0x400000) + 0x1000 <= size_bytes
        got_read = m.group("digest") is not None
        if reachable != got_read:
            problems.append(
                f"probe {off:#x}: aperture {idx} says reachable={reachable}, "
                f"the board {'read' if got_read else 'refused'} it"
            )

    # ---- the exchanges ----------------------------------------------------
    exchanges, pending, cur = [], None, None
    for l in lines:
        m = HOST.match(l)
        if m:
            if pending is not None:
                problems.append(f"request '{pending['mode']}' got no reply")
            pending, cur = m.groupdict(), None
            continue
        m = REQ.match(l)
        if m:
            if pending is None:
                continue
            cur = {"host": pending, "n": int(m.group("n"))}
            exchanges.append(cur)
            pending = None
            continue
        if cur is None:
            continue
        for pat, key in ((REGION, "region"), (SHA, "sha")):
            mm = pat.match(l)
            if mm:
                cur[key] = mm.groupdict()
        if OK_.match(l):
            cur["verdict"] = "ACCEPTED"
        mm = NO_.match(l)
        if mm:
            cur["verdict"] = "REFUSED"
            cur["layer"] = mm.group("layer")
        if "starting the trial" in l:
            cur["trial"] = True

    if len(exchanges) < 4:
        print(f"only {len(exchanges)} exchanges in this transcript")
        print("INCOMPLETE")
        return 1

    for e in exchanges:
        h, tag = e["host"], f"#{e['n']} {e['host']['mode']}"
        if "verdict" not in e:
            # A reply with no verdict is not a pass with a missing line: it is a
            # request whose answer nobody can name, and it must fail loudly
            # rather than raise. An earlier version of this indexed straight in
            # and crashed on exactly that transcript, which is a check that
            # stops checking the moment it finds something wrong.
            problems.append(f"{tag}: the board printed no verdict")
            continue
        if e["verdict"] != h["expect"]:
            problems.append(f"{tag}: host expected {h['expect']}, board said {e['verdict']}")
        if e["verdict"] == "REFUSED":
            want = "cryptography" if h["mode"] in ("wrong-key", "flip-sig") else "plumbing"
            if e.get("layer") != want:
                problems.append(f"{tag}: refused by {e.get('layer')}, expected {want}")
        # The guard's whole point: an address the board cannot reach is refused
        # without being read, so there is no digest to print.
        if h["mode"] in ("unreadable", "truncated"):
            if "sha" in e:
                problems.append(f"{tag}: a request refused by the plumbing still hashed something")
            continue
        if "sha" not in e:
            problems.append(f"{tag}: the board printed no digest")
        elif e["sha"]["sha"] != h["sha"]:
            problems.append(f"{tag}: board hashed {e['sha']['sha'][:16]}..., host {h['sha'][:16]}...")
        if "region" not in e:
            problems.append(f"{tag}: the board printed no region")
        elif int(e["region"]["off"], 16) != int(h["virt"], 16) or int(e["region"]["len"]) != int(h["len"], 16):
            problems.append(f"{tag}: the board read a different region than the host named")

    trials = [e for e in exchanges if e.get("trial")]
    expected = [e for e in exchanges if e["host"]["trial"] == "true"]
    if len(trials) != 1:
        problems.append(f"{len(trials)} requests started a trial; exactly one should")
    elif trials != expected:
        problems.append("the request that started a trial is not the one the host signed")
    if not any(e.get("verdict") == "REFUSED" for e in exchanges):
        problems.append("nothing was refused: this run cannot show the gate closing")

    # ---- and the other half: the ROM's, not this firmware's ---------------
    ran_b = any(l.startswith("exp167 up. slot B") for l in lines)
    provisional = any("TBYB set (provisional)" in l for l in lines)
    refused_buy = any("not buying" in l for l in lines)
    came_back = any("board is back on: exp167 slot A" in l for l in lines)
    if not ran_b:
        problems.append("slot B never ran, so the accepted request proved nothing")
    if not provisional:
        problems.append("slot B did not report itself provisional")
    if not refused_buy:
        problems.append("slot B never said whether it would buy")
    if not came_back:
        problems.append("the board did not come back to slot A")

    for n in notes:
        print(f"note: {n}")
    print("OPEN: the rule mapping a virtual offset to a QMI aperture needs the RP2350 datasheet")

    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
