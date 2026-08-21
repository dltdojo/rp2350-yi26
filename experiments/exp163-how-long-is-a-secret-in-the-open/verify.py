#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Re-derive exp163's finding from a pasted log, off the board.

    python3 verify.py < capture.txt
    yi26 log --seconds 60 | python3 verify.py

exp162's verifier re-did the board's arithmetic in another language. There is
no arithmetic here — the board counts sightings — so this one does something
else, and it is worth being exact about what.

**Every number in this run is recorded twice, by two paths that do not meet.**
Each candidate logs its own numbers over USB at the moment it measures them,
and then writes them into SRAM bank 9, where they sit through six watchdog
resets until the final report prints all seven records together. This file
parses both and requires them to agree, so a wrong record layout, a bank that
did not survive a reset, or a report reading the wrong offsets shows up as a
disagreement instead of as a plausible-looking table.

It also checks four things the board does not check about itself:

1. **The controls held.** Candidate 1 says the wall refuses a demoted core;
   candidate 2 says that core cannot read a clock either. Candidate 3 is the one
   that makes every sighting below mean something: the watcher runs for a second
   and a half with nothing signing and must see **nothing**.
2. **The four signatures are the same signature.** Fixed message, fixed seed,
   FIPS-204 deterministic signing: candidates 4, 5, 6 and 7 must print identical
   fingerprints. Different ones mean they did different work and none of the
   timings can be compared; identical ones also mean the signature was really
   computed, which the first build of this firmware did not manage.
3. **The remedy is the only difference.** Candidate 4 and candidate 5 run the
   same code up to one call. If 4 does not see the key afterwards, 5's silence
   is not the wipe's doing.
4. **The price.** Reported, not asserted: what the wipe costs against what the
   signature costs, and what the watcher costs the thing it is watching.

Exit line, machine-readable, always the last line printed:

    OK          controls held, records agree, the remedy did what it claims
    BAD         a control did not hold
    DISAGREE    the two records of the same run do not match
    INCOMPLETE  fewer than seven candidates in the capture

No dependencies, no network, no board.
"""

import re
import sys

CANDIDATES = 7
NAMES = {
    1: "Non-secure reads bank 8, DENIED",
    2: "Non-secure reads the clock, DENIED",
    3: "the watcher runs, nothing signs",
    4: "the watcher watches one signature",
    5: "the same, and the region is wiped",
    6: "only the signing frame is wiped",
    7: "the price, with nobody watching",
}
SIGNERS = (4, 5, 6, 7)

STAMP = re.compile(r"^\[\s*\d+ ms\]\s?")
CAND = re.compile(r"^candidate (\d) (.+)$")
FINAL = re.compile(r"^\s*(\d) stale=(\d+) quiet=(\d+) during=(\d+) after=(\d+) sweep=(\d+)\s*$")
FINAL2 = re.compile(r"^\s*sign=(\d+) us wipe=(\d+) us expand=(\d+) us depth=(\d+) B\s*$")
# The report matrix, which is the only record of an outcome in a capture
# taken after the run finished.
MATRIX = re.compile(r"^\s*(\d) .+ - (as expected|NOT as expected|not reached|KILLED CORE 0)$")


def strip(ln):
    return STAMP.sub("", ln).rstrip()


def parse(text):
    """(what each candidate logged at the time, what bank 9 said at the end)."""
    live, final, order, outcomes = {}, {}, [], {}
    cur = None
    for raw in text.splitlines():
        ln = strip(raw)

        m = CAND.match(ln)
        if m and "->" not in ln:
            cur = int(m.group(1))
            live[cur] = {"name": m.group(2)}
            continue

        if cur is not None:
            d = live[cur]
            m = re.match(r"\s*core 1: done=(\w+) faulted=(\w+) read=(\S+)", ln)
            if m:
                d["done"], d["faulted"] = m.group(1) == "true", m.group(2) == "true"
            m = re.match(r"\s*inherited copies still in SRAM: (\d+)", ln)
            if m:
                d["stale"] = int(m.group(1))
            m = re.match(r"\s*watcher up: (\d+) passes, (\d+) sightings", ln)
            if m:
                d["quiet"] = int(m.group(2))
            m = re.match(r"\s*(SGHD|PKHD) ([0-9a-f]{64})", ln)
            if m:
                d[m.group(1)] = m.group(2)
            m = re.match(r"\s*signed in (\d+) us, (\d+) bytes deep; watcher saw it (\d+) times", ln)
            if m:
                d["sign_us"], d["depth"], d["during"] = (int(x) for x in m.groups())
            m = re.match(r"\s*sign_once's own frame measured (\d+) bytes", ln)
            if m:
                d["frame"] = int(m.group(1))
            m = re.match(r"\s*wiped in (\d+) us; afterwards the watcher saw it (\d+) times", ln)
            if m:
                d["wipe_us"], d["after"] = int(m.group(1)), int(m.group(2))
            m = re.match(r"\s*the byte-granular sweep of all 512 KB found (\d+)", ln)
            if m:
                d["sweep"] = int(m.group(1))
            # Candidate 7 has no watcher, so it reports in its own shape.
            m = re.match(r"\s*expand (\d+) us, sign (\d+) us, wipe (\d+) us", ln)
            if m:
                d["expand_us"], d["sign_us"], d["wipe_us"] = (int(x) for x in m.groups())
                d["during"] = d["after"] = d["quiet"] = 0
            m = re.match(r"\s*stack went (\d+) bytes deep; copies left afterwards: (\d+)", ln)
            if m:
                d["depth"], d["sweep"] = int(m.group(1)), int(m.group(2))
            m = re.match(r"candidate (\d) -> (.+)$", ln)
            if m:
                d["outcome"] = m.group(2)
                cur = None
                continue

        m = MATRIX.match(ln)
        if m:
            outcomes[int(m.group(1))] = m.group(2)
            continue

        m = FINAL.match(ln)
        if m:
            n = int(m.group(1))
            final[n] = dict(
                zip(("stale", "quiet", "during", "after", "sweep"),
                    (int(x) for x in m.groups()[1:])))
            order.append(n)
            continue
        m = FINAL2.match(ln)
        if m and order:
            final[order[-1]].update(
                zip(("sign_us", "wipe_us", "expand_us", "depth"),
                    (int(x) for x in m.groups())))
    return live, final, outcomes


def main():
    live, final, outcomes = parse(sys.stdin.read())
    for n, o in outcomes.items():
        live.setdefault(n, {}).setdefault("outcome", o)

    if any(n not in final for n in range(1, CANDIDATES + 1)):
        print(f"bank 9 records missing from the capture: "
              f"{[n for n in range(1, CANDIDATES + 1) if n not in final]}")
        print("INCOMPLETE")
        return

    # A capture taken after the run is over holds the final report, repeating,
    # and none of the seven candidate boots — that is what `check.sh` has in
    # front of it, and it is a legitimate thing to hand this file. Say which
    # checks are being skipped rather than passing quietly on a smaller claim.
    # `outcome` alone comes from the report matrix, which a post-run capture
    # has. `done` and `SGHD` only exist in the boots themselves.
    full = "done" in live.get(1, {}) and "SGHD" in live.get(4, {})
    if not full:
        print("this capture holds bank 9's records but not the seven boots that "
              "made them:")
        print("  the log-against-bank-9 reconciliation and the four-signature "
              "check are SKIPPED")
        live = {n: live.get(n, {}) for n in range(1, CANDIDATES + 1)}

    for n in range(1, CANDIDATES + 1):
        f = final[n]
        print(f"  {n} {NAMES[n]}: {live[n].get('outcome', '?')}")
        print(f"      stale={f['stale']} quiet={f['quiet']} during={f['during']} "
              f"after={f['after']} sweep={f['sweep']}")

    # 1. The two records of the same run.
    bad = []
    if not full:
        bad = None
    for n in range(1, CANDIDATES + 1):
        for k in ("stale", "quiet", "during", "after", "sweep", "sign_us", "wipe_us", "depth"):
            if k in live[n] and k in final[n] and live[n][k] != final[n][k]:
                bad.append(f"candidate {n} logged {k}={live[n][k]}, bank 9 says {final[n][k]}")
    if bad:
        for b in bad:
            print(b)
        print("DISAGREE")
        return
    if full:
        print("the log and bank 9 agree on every number they both carry")

    # 2. The controls.
    for n in (1, 2):
        if full and not (live[n].get("faulted") and not live[n].get("done")):
            print(f"control {n} did not refuse: done={live[n].get('done')} "
                  f"faulted={live[n].get('faulted')}")
            print("BAD")
            return
        if not full and live[n].get("outcome") != "as expected":
            print(f"control {n} is recorded as {live[n].get('outcome')}")
            print("BAD")
            return
    quiet = final[3]
    if any(quiet[k] for k in ("stale", "quiet", "during", "after", "sweep")):
        print(f"control 3 saw something with nothing signing: {quiet}")
        print("BAD")
        return
    off = [n for n in range(1, CANDIDATES + 1)
           if live[n].get("outcome") != "as expected"]
    if off:
        print(f"candidates not marked as expected: "
              f"{[(n, live[n].get('outcome')) for n in off]}")
        print("BAD")
        return
    print("controls 1, 2 and 3 held: the wall refuses, the clock refuses, and a "
          "watcher with nothing to find finds nothing")

    # 3. Four signings, one signature.
    if full:
        sigs = {live[n].get("SGHD") for n in SIGNERS}
        pks = {live[n].get("PKHD") for n in SIGNERS}
        if len(sigs) != 1 or None in sigs or len(pks) != 1 or None in pks:
            print(f"the four signings did not produce one signature: "
                  f"{sorted(x or '-' for x in sigs)}")
            print("BAD")
            return
        print(f"candidates 4-7 all produced signature {sigs.pop()[:16]}... : same "
              f"message, same seed, same work")

    # 4. The finding.
    if not (final[4]["during"] > 0 and final[4]["after"] > 0 and final[4]["sweep"] > 0):
        print("candidate 4 did not see the key it was handed; nothing below is readable")
        print("BAD")
        return
    if not (final[5]["during"] > 0 and final[5]["after"] == 0 and final[5]["sweep"] == 0):
        print(f"candidate 5 did not behave as a wipe: {final[5]}")
        print("BAD")
        return

    w, s = final[5]["wipe_us"], final[5]["sign_us"]
    print()
    print(f"a Non-secure core saw the key {final[4]['during']} times while it was in use")
    print(f"and {final[4]['after']} more times afterwards when nothing wiped it")
    print(f"the wipe cost {w} us against {s} us of signing - {100.0 * w / s:.1f}%")
    print(f"and after it, {final[5]['after']} sightings and {final[5]['sweep']} copies in 512 KB")
    if "frame" in live[6]:
        print(f"wiping only sign_once's {live[6]['frame']}-byte frame left "
              f"{final[6]['sweep']} copies, though the stack went "
              f"{final[6]['depth']} bytes deep")
    watched, alone = final[4]["sign_us"], final[7]["sign_us"]
    print(f"being watched cost the signature {watched - alone:+d} us "
          f"({100.0 * (watched - alone) / alone:+.1f}%)")
    print(f"turning 32 bytes back into a key cost {final[7]['expand_us']} us of that")
    print("OK")


if __name__ == "__main__":
    main()
