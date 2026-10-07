#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp217 — hold lean/Pio/Machine.lean against two PIO emulators written by others.

  differential.py CASES LEAN JS PY     PASS/FAIL lines; exit 0 = all pass

Any of the traces may be `-`, stdin: gap.sh runs Run.lean against each wrong
model and pipes it here, against the emulators' traces made once.

CASES is what cases.py printed; LEAN, JS and PY are the traces Run.lean,
rp2040js_run.js and pioemu_run.py printed for it: per case, the state after
each step.

Each case is followed until the first step where an emulator and the model
part, on the fields that emulator has (rp2040-pio-emulator has no IRQ flags,
and its pin values are the inputs, so `pinr`'s pins are not compared). That
step's instruction, and the state before it, must then be one of the
deviations below, each the emulator's and each with the datasheet's reason
the model does not follow it. A disagreement no deviation explains is a
FAIL: either the model is wrong, or a new deviation has to be named here,
with its reason. So is a step the model refuses, since every case is drawn
from what the model has.

Both emulators model the RP2040, and the RP2350's additions are left out of
the cases. The model keeps all 32 bits of pin state, which rp2040js does not.
"""
import collections
import sys

FIELDS = ["pc", "x", "y", "isr", "isrc", "osr", "osrc", "pins", "dirs", "irq", "tx", "rx"]


def parse(line):
    f = line.split()
    d = dict(zip(FIELDS, f))
    for k in FIELDS[:10]:
        d[k] = int(d[k])
    for k in ("tx", "rx"):
        d[k] = [w for w in d[k][1:-1].split(",") if w]
    return d


def traces(path):
    out, cur = {}, None
    for line in (sys.stdin if path == "-" else open(path)):
        line = line.rstrip("\n")
        if line.startswith("case "):
            cur = int(line[5:])
            out[cur] = []
        else:
            out[cur].append(line)
    return out


# (name, the datasheet's reason) — the order is the order they are printed in.
DEVIATIONS = {
    "js": [
        ("push iffull and pull ifempty are ignored without autopush and autopull",
         "IfFull and IfEmpty compare the shift count with the threshold whatever autopush and autopull are"),
        ("a pull block that waits empties OSR's count",
         "a blocking pull on an empty FIFO stalls, and a stalled instruction changes nothing"),
        ("a push block that waits empties ISR",
         "a blocking push on a full FIFO stalls, and a stalled instruction changes nothing"),
        ("out of 32 bits leaves OSR as it was",
         "a bit count of 0 means 32, and OSR shifts by it like any other"),
        ("pin writes past GPIO31 stop there",
         "the OUT and SET pin ranges wrap from 31 to 0"),
        ("only GPIO0 to GPIO29 are kept",
         "a state machine's pin state is 32 bits on either chip; how many of them reach a pad is the package's (30 on an RP2040 or an RP2350A)"),
    ],
    "py": [
        ("mov's bit-reverse is a plain copy",
         "operation 2 reverses the bit order"),
        ("push iffull and pull ifempty compare the count with 32, not the threshold",
         "IfFull and IfEmpty compare the shift count with PUSH_THRESH and PULL_THRESH"),
        ("jmp !osre compares the count with 32, not the threshold",
         "!OSRE is the output shift count below PULL_THRESH"),
        ("a wrap top of 0 is taken as the end of the program",
         "WRAP_TOP is any instruction, 0 included"),
        ("in, mov and wait read pins from GPIO0 whatever IN_BASE is",
         "IN, MOV and WAIT PIN read from IN_BASE"),
        ("pin writes past GPIO31 stop there",
         "the OUT and SET pin ranges wrap from 31 to 0"),
        ("mov pins writes 32 pins from GPIO0",
         "MOV to PINS uses the OUT pin mapping"),
    ],
}


def past31(op, a, cfg, top):
    """A write to pins or pindirs through a mapping that runs past `top`."""
    out_end, set_end = cfg[3] + cfg[4], cfg[5] + cfg[6]
    return ((op == 7 and (a >> 5) in (0, 4) and set_end > top)
            or (op == 3 and (a >> 5) in (0, 4) and out_end > top)
            or (op == 5 and (a >> 5) in (0, 3) and out_end > top))


def deviation(emu, w, pre, cfg):
    """Which of DEVIATIONS[emu] explains a disagreement at instruction `w`,
    from state `pre`; None if none does."""
    op, a = w >> 13, w & 0xFF
    push_t, pull_t = cfg[10], cfg[11]
    is_pull, if_flag, block = a & 0x80, a & 0x40, a & 0x20
    names = [n for n, _ in DEVIATIONS[emu]]
    if emu == "js":
        if op == 4 and if_flag and (pre["osrc"] < pull_t if is_pull else pre["isrc"] < push_t):
            return names[0]
        if op == 4 and is_pull and block and not pre["tx"]:
            return names[1]
        if op == 4 and not is_pull and block and len(pre["rx"]) >= 4:
            return names[2]
        if op == 3 and a & 31 == 0:
            return names[3]
        if past31(op, a, cfg, 32):
            return names[4]
        if past31(op, a, cfg, 30):
            return names[5]
    if emu == "py":
        if op == 5 and (a >> 3) & 3 == 2:
            return names[0]
        if op == 4 and if_flag and (pull_t if is_pull else push_t) != 32 \
                and (pre["osrc"] if is_pull else pre["isrc"]) != 32:
            return names[1]
        if op == 0 and a >> 5 == 7 and pull_t != 32:
            return names[2]
        if cfg[1] == 0 and pre["pc"] == 0 and not (op == 0 and a >> 5 == 0):
            return names[3]
        reads = (op == 2 and a >> 5 == 0) or (op == 5 and a & 7 == 0) or (op == 1 and (a >> 5) & 3 == 1)
        if cfg[2] != 0 and reads:
            return names[4]
        if op == 5 and a >> 5 == 0:
            return names[6]
        if past31(op, a, cfg, 32):
            return names[5]
    return None


def compare(cases, lean, emu, other):
    """Counter of (family, outcome), and the first case of each."""
    counts, first = collections.Counter(), {}
    skip_all = {"irq"} if emu == "py" else set()
    for k, line in enumerate(cases):
        family, rest = line.split(" # ")
        parts = rest.split("|")
        cfg = [int(t) for t in parts[0].split()]
        prog = [int(t) for t in parts[1].split()]
        st = [int(t) for t in parts[2].split()]
        skip = skip_all | ({"pins"} if emu == "py" and family == "pinr" else set())
        prev = (f"{st[0]} {st[1]} {st[2]} {st[3]} {st[4]} {st[5]} {st[6]} 0 0 0 "
                f"[{','.join(parts[3].split())}] []")
        outcome = "agree on every step"
        for i, (a, b) in enumerate(zip(lean[k], other[k])):
            if a == "NONE":
                outcome = "UNEXPLAINED: the model refuses an instruction it has"
                break
            if b == "NONE":
                outcome = "the emulator has no emulation for an instruction"
                break
            fa, fb = a.split(), b.split()
            diff = [FIELDS[j] for j in range(12) if fa[j] != fb[j] and FIELDS[j] not in skip]
            if diff:
                pre = parse(prev)
                w = prog[pre["pc"]] if pre["pc"] < len(prog) else 0
                outcome = deviation(emu, w, pre, cfg) or \
                    f"UNEXPLAINED: {','.join(diff)} differ at step {i}, {w:04x}"
                break
            prev = a
        else:
            if len(lean[k]) != len(other[k]):
                outcome = f"UNEXPLAINED: {len(lean[k])} steps against {len(other[k])}"
        counts[(family, outcome)] += 1
        first.setdefault(outcome, k)
    return counts, first


def main():
    cases = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
    lean = traces(sys.argv[2])
    failed = False
    families = list(dict.fromkeys(l.split(" # ")[0] for l in cases))
    for emu, path, title in (("js", sys.argv[3], "rp2040js 1.4.0"),
                             ("py", sys.argv[4], "rp2040-pio-emulator 0.88.0")):
        counts, first = compare(cases, lean, emu, traces(path))
        per = collections.Counter()
        for (fam, outcome), n in counts.items():
            per[outcome] += n
        bad = {o: n for o, n in per.items() if o.startswith("UNEXPLAINED")}
        agree = per["agree on every step"]
        sizes = ", ".join(f"{f} {sum(1 for l in cases if l.startswith(f + ' #'))}" for f in families)
        print(f">>> {title}: {len(cases)} cases, {len(lean[0])} steps each ({sizes})")
        print(f"  {agree:4d}  agree with the model on every step")
        reasons = dict(DEVIATIONS[emu])
        for name in [n for n, _ in DEVIATIONS[emu]] + ["the emulator has no emulation for an instruction"]:
            if per[name]:
                print(f"  {per[name]:4d}  part at a deviation: {name}" if name in reasons
                      else f"  {per[name]:4d}  stop comparing where {name}")
                if name in reasons:
                    print(f"        the datasheet: {reasons[name]}; e.g. case {first[name]}")
        for o, n in sorted(bad.items()):
            print(f"  {n:4d}  {o}; e.g. case {first[o]}")
        if bad:
            failed = True
            print(f"FAIL  every disagreement with {title} is one of its named deviations — "
                  f"{sum(bad.values())} of {len(cases)} cases are not")
        else:
            print(f"PASS  every disagreement with {title} is one of its named deviations, "
                  f"and {agree} of {len(cases)} cases agree on every step")
        if agree * 4 < len(cases):
            failed = True
            print(f"FAIL  at least a quarter of the cases agree with {title} throughout — only {agree}")
        unused = [n for n, _ in DEVIATIONS[emu] if not per[n]]
        if unused:
            failed = True
            print(f"FAIL  every deviation named for {title} is seen — not: {'; '.join(unused)}")
        print()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
