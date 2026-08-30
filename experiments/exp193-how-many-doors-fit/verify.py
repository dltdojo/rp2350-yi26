#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""exp193 verification — rules on a capture.txt written by drop.sh.

Every rule here is about a number the **host** produced. The board's own log is
read for exactly one thing: what it declared. The whole point of the comparison
is that a composite bring-up which quietly drops an interface reports the number
it meant to build, so asking the board twice would prove nothing.

The experiment set out to measure one wall and found two, in this order, which
is why the rules below are about *both* and about which is first. See the
README: the first wall is not a byte count at all.
"""

import re
import sys

# The console's own two interfaces, from crates/cdc-console. CDC-ACM is a
# control interface and a data interface wearing one IAD.
CONSOLE_INTERFACES = 2

# What the console alone costs, measured on exp190 before this experiment
# existed. If a step disagrees with this, the crate changed underneath.
CONSOLE_BYTES = 70

# crates/cdc-console's configuration descriptor buffer. The budget this
# experiment set out to measure, and the one that turned out not to be first.
DESCRIPTOR_BYTES = 256

# embassy-usb's MAX_INTERFACE_COUNT with no feature set. Not a number this
# repository chose — a default nothing here had ever needed to change.
NARROW_INTERFACES = 4


def steps(text, lane):
    """(n, body) for each `-- <lane> hid N --` section, in order."""
    for m in re.finditer(rf"^-- {lane} hid (\d+) --$(.*?)(?=^-- |\Z)", text, re.S | re.M):
        yield int(m.group(1)), m.group(2)


def wall(text, lane):
    """The first shape that did not fit in this lane, or None."""
    m = re.search(
        rf"^-- {lane} wall --$\s*first shape that did not fit: (?:hid (\d+)|none)", text, re.M
    )
    return int(m.group(1)) if m and m.group(1) else None


def measured(body):
    m = re.search(r"wTotalLength=(\d+) bNumInterfaces=(\d+)", body)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def declared(body):
    m = re.search(r"declaring (\d+) of \d+ interfaces", body)
    return int(m.group(1)) if m else None


def verify(text):
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    lanes = {}
    for lane in ("narrow", "wide"):
        walked = list(steps(text, lane))
        lanes[lane] = {
            "fitted": [(n, b) for n, b in walked if "did not enumerate" not in b],
            "failed": [(n, b) for n, b in walked if "did not enumerate" in b],
            "wall": wall(text, lane),
        }

    # --- the control ---------------------------------------------------------
    narrow = lanes["narrow"]["fitted"]
    rule(
        bool(narrow) and narrow[0][0] == 0,
        "the walk started at hid 0 — a console and nothing else",
        "the walk did not start at hid 0, so there is no control",
    )

    if narrow:
        total, ifaces = measured(narrow[0][1])
        rule(
            ifaces == CONSOLE_INTERFACES,
            f"and the host claimed its {CONSOLE_INTERFACES} console interfaces",
            f"the console did not enumerate as {CONSOLE_INTERFACES} interfaces (host said {ifaces})",
        )
        rule(
            total == CONSOLE_BYTES,
            f"and it cost the {CONSOLE_BYTES} descriptor bytes exp190 measured",
            f"the console now costs {total} bytes, not the {CONSOLE_BYTES} exp190 measured "
            "— crates/cdc-console changed underneath this experiment",
        )

    # --- the composite path is real -----------------------------------------
    rule(
        len(narrow) >= 2,
        f"the builder came back and interfaces were added to it ({len(narrow)} shapes fitted)",
        "no shape past the console fitted, so the composite path was never exercised",
    )

    # --- the one that can fail in the expensive direction --------------------
    #
    # A board that drops an interface still enumerates, still logs, still answers
    # the 1200-baud touch. This is the only rule that catches it.
    disagreements = [
        (lane, n, declared(b), measured(b)[1])
        for lane in lanes
        for n, b in lanes[lane]["fitted"]
        if declared(b) != measured(b)[1]
    ]
    rule(
        not disagreements,
        "every shape enumerated exactly the interfaces it declared",
        f"declared and enumerated disagree at {disagreements} — an interface was "
        "silently dropped, which looks like success from the board's side",
    )

    # --- the descriptor grows, and by a constant ----------------------------
    costs = []
    for lane in lanes:
        f = lanes[lane]["fitted"]
        for (n1, b1), (n2, b2) in zip(f, f[1:]):
            t1, t2 = measured(b1)[0], measured(b2)[0]
            if t1 is not None and t2 is not None and n2 == n1 + 1:
                costs.append(t2 - t1)
    rule(
        bool(costs) and len(set(costs)) == 1,
        f"each added interface cost the same {costs[0] if costs else '?'} descriptor bytes, "
        "in both lanes",
        f"the per-interface cost was not constant: {costs}",
    )

    # --- wall one: not a byte count -----------------------------------------
    #
    # The finding this experiment exists for. `narrow` is embassy-usb as every
    # firmware in this repository has ever built it, and it stops at four
    # interfaces because MAX_INTERFACE_COUNT is 4 — with the descriptor buffer
    # not yet half spent.
    nw, ww = lanes["narrow"]["wall"], lanes["wide"]["wall"]
    rule(
        nw is not None,
        f"the narrow lane hit a wall, at hid {nw}",
        "the narrow lane never hit a wall — the ceiling is too low to measure anything",
    )
    if nw is not None and lanes["narrow"]["fitted"]:
        widest_total = measured(lanes["narrow"]["fitted"][-1][1])[0]
        rule(
            CONSOLE_INTERFACES + nw > NARROW_INTERFACES,
            f"and it is the interface list, not the bytes: {CONSOLE_INTERFACES + nw} interfaces "
            f"is past MAX_INTERFACE_COUNT={NARROW_INTERFACES}, with only {widest_total} of "
            f"{DESCRIPTOR_BYTES} descriptor bytes spent",
            f"the narrow wall at hid {nw} is not where MAX_INTERFACE_COUNT={NARROW_INTERFACES} "
            "predicts it",
        )
        rule(
            widest_total is not None and widest_total < DESCRIPTOR_BYTES,
            f"**the first wall is not a byte count** — {widest_total} bytes of "
            f"{DESCRIPTOR_BYTES} were still free when the board stopped fitting interfaces",
            "the narrow lane ran out of descriptor bytes, so there is only one wall after all",
        )

    # --- wall two: the byte count, once the first is moved ------------------
    rule(
        ww is not None and nw is not None and ww > nw,
        f"raising the compile-time setting moved the wall: hid {nw} -> hid {ww}",
        f"the wide lane's wall ({ww}) is not past the narrow lane's ({nw})",
    )
    if ww is not None and lanes["wide"]["fitted"]:
        widest_total = measured(lanes["wide"]["fitted"][-1][1])[0]
        would_be = widest_total + costs[0] if costs and widest_total else None
        rule(
            would_be is not None and would_be > DESCRIPTOR_BYTES,
            f"and the second wall IS the byte count: hid {ww} would need {would_be} bytes "
            f"of the {DESCRIPTOR_BYTES} crates/cdc-console gives it",
            f"the wide lane's wall is not the descriptor budget either "
            f"({widest_total} spent, next would be {would_be} of {DESCRIPTOR_BYTES})",
        )

    # --- neither wall costs a person ----------------------------------------
    for lane in ("narrow", "wide"):
        failed = lanes[lane]["failed"]
        if not failed:
            continue
        body = failed[0][1]
        m = re.search(r"bootsel after: (\S+) s", body)
        reached = m.group(1) if m else "never"
        rule(
            reached != "never",
            f"the {lane} board that hit its wall put itself in the bootloader after "
            f"{reached} s, with nobody touching it",
            f"the {lane} board that hit its wall did not reach the bootloader — "
            "that is a walk to a bench",
        )
        rule(
            "drive present: yes" in body,
            f"and the {lane} board presents its drive, so a host can reflash it",
            f"the {lane} board reached the bootloader but presented no drive",
        )

    # --- and it is still a board ---------------------------------------------
    restored = re.search(r"^-- restored --$(.*)\Z", text, re.S | re.M)
    body = restored.group(1) if restored else ""
    rule(
        "final state: running" in body,
        "a working image flashed afterwards runs — a wall is not a state the board stays in",
        "the board did not come back after the walk",
    )
    total, ifaces = measured(body.replace("final host says: ", "host says: "))
    rule(
        ifaces == CONSOLE_INTERFACES,
        "and the host sees the console again",
        f"the restored board did not enumerate as the console (host said {ifaces})",
    )

    return ok


if __name__ == "__main__":
    text = open(sys.argv[1]).read()
    sys.exit(0 if verify(text) else 1)
