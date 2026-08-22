#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check exp166's transcript against itself, off the board, with nothing installed.

    python3 verify.py < capture.txt

Prints OK, DISAGREE or INCOMPLETE on the last line.

The transcript interleaves two voices: `>>> host:` lines, written by the
machine that built and signed each request, and `[ ms]` lines written by the
board.  **Neither is trusted about the other.**  What is derived here:

  - the board hashed the bytes the host named, because the two SHA-256s must
    match.  A verifier that only reports pass/fail can be trusted but not
    checked; this is what makes the verdict checkable.
  - the board's region matches the region the host named, so a digest cannot
    match by having been taken over something else.
  - every verdict matches what the host expected of that request.
  - a refusal names which layer said no, and the layers are not
    interchangeable: a truncated frame must be refused by the plumbing and a
    bad signature by the cryptography.  exp136 is why -- a reader who cannot
    tell them apart blames the cryptography for what the framing did.
  - the transcript contains at least one of each verdict.  A run that only
    ever accepts, or only ever refuses, demonstrates nothing.
  - the last request is accepted, so the board survived every refusal before
    it.  A verifier that stops working after it says no once is a verifier
    that can be switched off by being lied to.
  - the running totals add up.
"""

import re
import sys

HOST = re.compile(
    r"^>>> host: mode=(?P<mode>\S+) expect=(?P<expect>ACCEPTED|REFUSED) "
    r"named=(?P<off>0x[0-9a-f]+)\+(?P<len>\d+) sha256=(?P<sha>[0-9a-f]{64})\s*$"
)
REQ = re.compile(r"^--- request #(?P<n>\d+): (?P<len>\d+) byte frame, (?P<disc>\d+) discarded\s*$")
REGION = re.compile(r"^\s*region: offset=(?P<off>0x[0-9a-f]+) len=(?P<len>\d+) ")
SHA = re.compile(r"^\s*sha256 = (?P<sha>[0-9a-f]{64})\s*$")
TIME = re.compile(r"^\s*hashed in (?P<h>\d+) us, verified in (?P<v>\d+) us\s*$")
OK_ = re.compile(r"^\s*ACCEPTED: ")
NO_ = re.compile(r"^\s*REFUSED \((?P<layer>plumbing|cryptography)\): (?P<why>.+?)\s*$")
TOT = re.compile(
    r"^\s*totals: (?P<a>\d+) asked, (?P<ok>\d+) accepted, (?P<no>\d+) refused, (?P<mal>\d+) malformed\s*$"
)


def strip(line):
    return re.sub(r"^\[\s*\d+ ms\]\s?", "", line.rstrip("\n"))


def main():
    lines = [strip(x) for x in sys.stdin]
    problems = []
    notes = []

    # A transcript driven from a shell begins at the first request, because the
    # banner was printed before the shell attached. That is a legitimate log and
    # everything in it is checked just as hard; only the banner's own claims are
    # skipped, and their absence is said out loud rather than passed over.
    booted = any(l.startswith("exp166 ") for l in lines)
    if booted:
        # The ceiling has to be in the transcript, not only in the README.
        xip = next((l for l in lines if "ACCESSCTRL.XIP_MAIN" in l), None)
        keyat = next((l for l in lines if "trusted key lives at" in l), None)
        if xip is None or keyat is None:
            problems.append("the banner does not say where the key is or how open its flash is")
        else:
            notes.append(keyat.strip())
            notes.append(xip.strip())
    else:
        notes.append("no banner in this window: the board booted before the log was opened")

    # Walk the transcript as a sequence of exchanges: one host line, then the
    # board's reply to it.  Anything else between them is a desynchronised log
    # and is reported rather than skipped past.
    exchanges = []
    pending = None
    cur = None
    for l in lines:
        m = HOST.match(l)
        if m:
            if pending is not None:
                problems.append(f"request '{pending['mode']}' got no reply before the next one")
            pending = m.groupdict()
            cur = None
            continue
        m = REQ.match(l)
        if m:
            if pending is None:
                problems.append(f"board answered request #{m.group('n')} that no host line asked for")
                continue
            cur = {"host": pending, "n": int(m.group("n")), "frame": int(m.group("len"))}
            exchanges.append(cur)
            pending = None
            continue
        if cur is None:
            continue
        for pat, key in ((REGION, "region"), (SHA, "sha"), (TIME, "time"), (TOT, "tot")):
            m = pat.match(l)
            if m:
                cur[key] = m.groupdict()
        if OK_.match(l):
            cur["verdict"] = "ACCEPTED"
        m = NO_.match(l)
        if m:
            cur["verdict"] = "REFUSED"
            cur["layer"] = m.group("layer")
            cur["why"] = m.group("why")

    if len(exchanges) < 2:
        print(f"only {len(exchanges)} exchanges in this log")
        print("INCOMPLETE")
        return 1

    for e in exchanges:
        h, tag = e["host"], f"#{e['n']} {e['host']['mode']}"
        if "verdict" not in e:
            problems.append(f"{tag}: the board printed no verdict")
            continue
        if e["verdict"] != h["expect"]:
            problems.append(f"{tag}: host expected {h['expect']}, board said {e['verdict']}")

        # A refusal by the wrong layer is still the wrong answer for the right
        # reason, and it is the failure this experiment is most able to hide.
        if e["verdict"] == "REFUSED":
            want = "plumbing" if h["mode"] == "truncated" else "cryptography"
            if e.get("layer") != want:
                problems.append(f"{tag}: refused by {e.get('layer')}, expected {want}")

        # The plumbing refuses before it reads a region, so a truncated frame
        # legitimately has no digest.  Everything else must have one.
        if h["mode"] == "truncated":
            if "sha" in e:
                problems.append(f"{tag}: a frame refused for its length still hashed a region")
            continue

        if "sha" not in e:
            problems.append(f"{tag}: the board printed no digest")
        elif e["sha"]["sha"] != h["sha"]:
            problems.append(f"{tag}: board hashed {e['sha']['sha'][:16]}..., host {h['sha'][:16]}...")
        if "region" not in e:
            problems.append(f"{tag}: the board printed no region")
        else:
            if int(e["region"]["off"], 16) != int(h["off"], 16) or e["region"]["len"] != h["len"]:
                problems.append(f"{tag}: board read a different region than the host named")

    verdicts = [e.get("verdict") for e in exchanges]
    if "ACCEPTED" not in verdicts:
        problems.append("nothing was ever accepted: this run cannot show the check passing")
    if "REFUSED" not in verdicts:
        problems.append("nothing was ever refused: this run cannot show the check failing")
    if verdicts and verdicts[-1] != "ACCEPTED":
        problems.append("the last request was not accepted: the board may not have survived a refusal")

    layers = {e.get("layer") for e in exchanges if e.get("verdict") == "REFUSED"}
    if len(layers) < 2:
        problems.append(f"only {layers} refused anything: the two layers are not distinguished")

    # The board's totals are cumulative since **boot**, and a transcript driven
    # from a shell is usually taken against a board that has already answered
    # other questions. So the check is relative, which is also the stronger one:
    # the counter must advance by exactly one per exchange, with no request
    # counted twice and none lost between two lines of the same log.
    #
    # The first version of this compared the final total against the number of
    # exchanges, passed on a fresh capture, and failed the moment check.sh drove
    # a board that had been running — correctly, about the wrong thing.
    tots = [(int(e["tot"]["a"]), int(e["tot"]["ok"]), int(e["tot"]["no"]), int(e["tot"]["mal"]))
            for e in exchanges if "tot" in e]
    if len(tots) != len(exchanges):
        problems.append(f"{len(exchanges) - len(tots)} exchanges printed no running total")
    for (a, ok, no, mal) in tots:
        if ok + no + mal != a:
            problems.append(f"totals do not add up: {ok}+{no}+{mal} != {a}")
            break
    for prev, cur in zip(tots, tots[1:]):
        if cur[0] != prev[0] + 1:
            problems.append(f"the request counter went {prev[0]} -> {cur[0]}, not by one")
            break
    if tots:
        a, ok, no, mal = tots[-1]
        notes.append(f"{a} asked since boot, {ok} accepted, {no} refused, {mal} malformed")
        notes.append(f"{len(exchanges)} exchanges in this transcript")

    times = [(int(e["time"]["h"]), int(e["time"]["v"])) for e in exchanges if "time" in e]
    if times:
        notes.append(
            "hash %d-%d us, verify %d-%d us"
            % (min(t[0] for t in times), max(t[0] for t in times),
               min(t[1] for t in times), max(t[1] for t in times))
        )

    for n in notes:
        print(f"note: {n}")
    print("OPEN: nothing here stops somebody rewriting the key this board trusts")

    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
