#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp256 — every run of every monitor suite, on the model and on the RTL, and every difference accounted for.

tools/monitor/privdiff.py runs a suite as its check.sh does and replays each emulator run it made: against the model
(`privrun`), step by step, and -- for a run that starts from reset -- against the Hazard3 RTL as the RP2350 configures
it, at the end. This runs it on every suite here that runs a monitor, and sorts what it finds.

A difference is one of the kinds below, or it is a failure:

  the model, against the emulator
    wfi_sleeps      a U-mode `wfi` with mstatus.TW clear: the model sleeps on it, as the RTL does, and with no
                    interrupt it stays where it is; the emulator traps it as illegal (2)

    Until exp257 there were two more, the model's own mistakes, fixed there: `ebreak` trapped as illegal (2) where
    it is a breakpoint (3), and a load or store outside Tier 1's region as illegal where it is an access fault.

  the RTL, against the emulator (which agrees with the model everywhere else)
    counters        only the counts in a report differ: minstret, and mcycle, which the emulator counts as minstret
    wfi_sleeps      the RTL never reports, where the emulator trapped a U-mode `wfi` as illegal
    mpp_reset       a monitor that does not write mstatus.MPP before its `mret`: the emulator resets MPP to U-mode,
                    Hazard3 to M-mode (hazard3_csr.v), so on the RTL the payload runs in M-mode and its `ecall` is
                    reported as M-mode's (11), not U-mode's (8)

    differential.py           both, every suite
    differential.py --model   the model only (no RTL needed)
"""

import collections
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
EXPS = os.path.join(REPO, "experiments")
PRIVDIFF = os.path.join(REPO, "tools", "monitor", "privdiff.py")

SUITES = [os.path.join(EXPS, s) for s in """
exp236-the-wall-the-monitor-holds/cases/normal_cases.py
exp236-the-wall-the-monitor-holds/cases/attack_cases.py
exp236-the-wall-the-monitor-holds/cases/broken_monitors.py
exp237-the-enclave-on-the-chip/emutest.py
exp238-the-call-the-monitor-checks/suite/kernel_cases.py
exp238-the-call-the-monitor-checks/suite/attack_cases.py
exp238-the-call-the-monitor-checks/suite/broken_monitors.py
exp239-the-scratch-the-monitor-scrubs/suite/kernel_cases.py
exp239-the-scratch-the-monitor-scrubs/suite/attack_cases.py
exp239-the-scratch-the-monitor-scrubs/suite/broken_monitors.py
exp240-the-code-the-box-forbids-writing/suite/rounds.py
exp240-the-code-the-box-forbids-writing/suite/wx_attacks.py
exp240-the-code-the-box-forbids-writing/suite/broken_monitors.py
exp245-the-bytes-the-proof-blesses/suite/charms_audit.py
exp246-the-run-the-charms-do-not-change/suite/same_rounds.py
exp247-the-remainder-behind-the-wall/suite/behind_the_wall.py
exp250-the-digest-the-wall-keeps/suite/digest_behind_the_wall.py
exp252-the-verdict-the-wall-reports/suite/verdict.py
exp254-the-life-the-box-lets-through/suite/life.py
exp255-the-lives-round-after-round/suite/forever.py
""".split()]

HALT, FAULT = "48414c54", "4641554c"
WFI = "10500073"


def privdiff(suite, mode):
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out.jsonl")
        args = [sys.executable, PRIVDIFF] + ([mode] if mode else []) + [suite]
        subprocess.run(args, env=dict(os.environ, PRIVDIFF_OUT=out), capture_output=True)
        if not os.path.exists(out):
            return {"suite": suite, "error": "no result"}
        return json.loads(open(out).read().splitlines()[-1])


def model_kind(d):
    what, insn = d["what"], d.get("insn", "")
    if insn == WFI and what.startswith(f"pc: emulator ") and f", model {int(d['pc'], 16):08x}," in what \
            and "mode: emulator M, model U" in what and "mcause: emulator 00000002, model" in what:
        return "wfi_sleeps"
    return None


def counter_words(p):
    """Positions of the counts in a run's reports: HALT's minstret and mcycle, FAULT's minstret."""
    pos = {}
    for i, w in enumerate(p):
        if w == HALT:
            pos[i + 2], pos[i + 3] = "minstret", "mcycle"
        if w == FAULT:
            pos[i + 4] = "minstret"
    return pos


def rtl_kind(d, deltas):
    if set(d) - {"run", "trap", "prints"} == set() and "prints" in d:
        e, r = d["prints"]["emulator"], d["prints"]["RTL"]
        pos = counter_words(e)
        if len(e) == len(r) and all(i in pos for i in range(len(e)) if e[i] != r[i]):
            for i in range(len(e)):
                if e[i] != r[i] and pos[i] == "minstret":
                    deltas[int(r[i], 16) - int(e[i], 16)] += 1
            return "counters"
    t = d.get("trap", {})
    if t.get("insn") == WFI and t.get("mode") == "U" and d.get("prints", {}).get("RTL") == [] \
            and set(d) - {"run", "trap", "prints", "exit"} == set() \
            and ("exit" not in d or d["exit"].endswith("RTL none")):
        return "wfi_sleeps"
    p = d.get("prints", {})
    if t.get("cause") == 8 and t.get("mode") == "U" and p.get("RTL", [])[:2] == [FAULT, "0000000b"]:
        return "mpp_reset"
    return None


def main():
    rtl = "--model" not in sys.argv
    status = 0
    with ThreadPoolExecutor(4) as pool:
        models = list(pool.map(lambda s: privdiff(s, None), SUITES))
        rtls = list(pool.map(lambda s: privdiff(s, "--rtl"), SUITES)) if rtl else []
    runs = sum(m.get("runs", 0) for m in models)
    steps = sum(m.get("steps", 0) for m in models)
    kinds, odd = collections.Counter(), []
    for m in models:
        if "error" in m:
            odd.append(f"{os.path.relpath(m['suite'], EXPS)}: {m['error']}")
        for d in m.get("all", []):
            k = model_kind(d)
            if k:
                kinds[k] += 1
            else:
                odd.append(f"{os.path.relpath(m['suite'], EXPS)} run {d['run']}: {json.dumps(d)[:300]}")
    agree = runs - sum(kinds.values())
    if odd:
        status = 1
        for o in odd[:10]:
            print(f"FAIL  the model: {o}")
    else:
        print(f"PASS  the model against the emulator: {len(SUITES)} suites, {runs} runs, {steps} steps, every one")
        print(f"      compared after every step; {agree} runs agree at every step, and the {sum(kinds.values())} "
              f"that do not are {kinds['wfi_sleeps']} wfi_sleeps")
    if not rtl:
        return status
    kinds, odd, deltas = collections.Counter(), [], collections.Counter()
    reset = sum(r.get("from_reset", 0) for r in rtls)
    service = sum(r.get("service", 0) for r in rtls)
    for r in rtls:
        if "error" in r:
            odd.append(f"{os.path.relpath(r['suite'], EXPS)}: {r['error']}")
        for d in r.get("all", []):
            k = rtl_kind(d, deltas)
            if k:
                kinds[k] += 1
            else:
                odd.append(f"{os.path.relpath(r['suite'], EXPS)} run {d['run']}: {json.dumps(d)[:300]}")
    compared = reset - service
    if odd:
        status = 1
        for o in odd[:10]:
            print(f"FAIL  the RTL: {o}")
    else:
        same = compared - sum(kinds.values())
        print(f"PASS  the RTL (tb-rp2350) against the emulator: {reset} runs from reset, {service} of them calling the")
        print(f"      service port, which the testbench has no host for; of the {compared} compared, {same} end the same,")
        print(f"      every word, exit code and byte of RAM; {kinds['counters']} differ only in a report's counts and "
              f"{kinds['wfi_sleeps']} are wfi_sleeps,")
        print(f"      {kinds['mpp_reset']} mpp_reset")
        print(f"      minstret, RTL less emulator, in the reports that differ: "
              + ", ".join(f"+{k} in {v}" for k, v in sorted(deltas.items())))
    return status


if __name__ == "__main__":
    sys.exit(main())
