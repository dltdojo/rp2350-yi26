#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp257 — `Rv32.PmpChip.chipCheck`, held to two Hazard3 cores, one access at a time.

A case is a PMP configuration -- PMPCFG0, PMPCFG1, PMPADDR0 to 7 and PMPCFGM0, as software writes them -- and one
access under it: a privilege, an address, a fetch or a load or store of 1, 2 or 4 bytes. On the RTL, an M-mode
driver writes a two-instruction stub (the access, then `ecall`), writes the configuration, and `mret`s to the stub
in the case's privilege; its trap handler prints `mcause`. The model's answer is three `chipCheck` questions, asked
of `privrun --pmp`: may the stub be fetched, may the access be made, may the `ecall` after it be fetched. From them
the `mcause` the RTL must print:

    1  the fetch refused          5, 7  the load, the store refused          8, 11  neither: U-mode's, M-mode's ecall

Each order is held to its core, and must agree on every case:

    chipCheck .e6        tb_e6-rp2350   the core the RP2350 was built from (fce1c08), Table 387's parameters
    chipCheck .standard  tb-rp2350      the pinned core, erratum E6 fixed, the same parameters

and each to the other core, which must not: a differential that cannot tell the two orders apart has not tested
either. Where the cases are:

  * every dynamic entry over a 1 MiB window at 0x80100000, NAPOT of 32 bytes to 256 KiB, or over all of memory, or
    any word at all; its configuration byte any A (TOR and NA4 are OFF on this core), any permissions, the two
    reserved bits any; PMPCFGM0 any word;
  * an entry that is locked, or that PMPCFGM0 binds to M-mode, lies in the window: the driver's own code and its
    print port must stay M-mode's. A lock outlives the case, so each locked case runs alone, from reset;
  * a load or store runs from a stub at 0x80080000 that entry 7 gives everything over 32 bytes (`0x1f`, the same in
    either order) -- so that U-mode reaches the access at all -- unless a lower entry decides first; a fetch runs
    from the address itself, and entry 7 is as random as the rest.

What this cannot reach: the hardwired regions 8 to 10 match the ROM, the peripherals and SIO, where the testbench
has no memory -- an access the PMP lets through is a bus fault there, and a bus fault's `mcause` is the PMP's.
probes.py reads their registers instead.

    pmpdiff.py [--cases N] [--locked N] [--seed S]
"""

import argparse
import collections
import os
import random
import subprocess
import sys
import tempfile
import types
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
sys.path.insert(0, os.path.join(REPO, "tools", "monitor"))
import harness  # noqa: E402
import privdiff  # noqa: E402
from monitor.emulator import BASE  # noqa: E402

TBDIR = os.path.join(REPO, "tools", "hazard3", "Hazard3", "test", "sim", "tb_verilator")
CORES = {"e6": os.path.join(TBDIR, "tb_e6-rp2350"), "std": os.path.join(TBDIR, "tb-rp2350")}

WINDOW, WINDOW_LEN = 0x80100000, 1 << 20
DATA_STUB = 0x80080000
STUB_ENTRY = 0x20000000 | (DATA_STUB >> 2) | 3       # NAPOT, 32 bytes at DATA_STUB
ALL = (0x3FFFFFFF, 0x7FFFFFFF, 0xFFFFFFFF)            # all of memory, the two top bits as written
KINDS = ["F", "lb", "lh", "lw", "sb", "sh", "sw"]
WIDTH = {"lb": 1, "lh": 2, "lw": 4, "sb": 1, "sh": 2, "sw": 4}
NOP, ECALL = 0x00000013, 0x00000073


def encode(kind: str) -> int:
    """The stub's first instruction: `nop` for a fetch, else the access, `t1` to or from `0(t2)`."""
    if kind == "F":
        return NOP
    f3 = {"b": 0, "h": 1, "w": 2}[kind[1]]
    if kind[0] == "l":
        return (7 << 15) | (f3 << 12) | (6 << 7) | 0x03
    return (6 << 20) | (7 << 15) | (f3 << 12) | 0x23


def napot_in_window(rng) -> tuple:
    k = rng.randint(5, 18)
    base = WINDOW + rng.randrange(WINDOW_LEN >> k) * (1 << k)
    v = (base + (1 << (k - 1)) - 1) >> 2
    if rng.random() < 0.3:
        v &= ~rng.randrange(4)          # the grain sets the two low bits back
    if rng.random() < 0.1:
        v |= rng.randrange(1, 4) << 30  # and the core drops the two top bits
    return v, (base, base + (1 << k))


def make_case(rng, locked: bool) -> dict:
    kind = rng.choice(KINDS)
    entries = []
    for i in range(8):
        if kind != "F" and i == 7:
            entries.append((STUB_ENTRY, 0x1f, None, False))
            continue
        r = rng.random()
        if r < 0.08:
            a, rgn, safe = rng.choice(ALL), None, False
        elif r < 0.12:
            a, rgn, safe = rng.getrandbits(32), None, False
        else:
            (a, rgn), safe = napot_in_window(rng), True
        amode = rng.choices([3, 0, 1, 2], [70, 10, 10, 10])[0]
        cfg = (amode << 3) | rng.getrandbits(3) | (rng.getrandbits(2) << 5)
        if safe and locked and rng.random() < 0.4:
            cfg |= 0x80
        entries.append((a, cfg, rgn, safe))
    m0 = rng.getrandbits(32) & ~0xff
    for i, (_, _, _, safe) in enumerate(entries):
        if safe and rng.random() < 0.2:
            m0 |= 1 << i
    if locked and not any(c & 0x80 for _, c, _, _ in entries):
        i = next(i for i, e in enumerate(entries) if e[3])
        a, c, r_, s = entries[i]
        entries[i] = (a, c | 0x80, r_, s)
    # the address: in an entry's region, at its edge, or anywhere in the window
    regions = [r_ for _, _, r_, _ in entries if r_]
    w = WIDTH.get(kind, 4)
    r = rng.random()
    if regions and r < 0.5:
        lo, hi = rng.choice(regions)
        addr = rng.randrange(lo, hi)
    elif regions and r < 0.75:
        lo, hi = rng.choice(regions)
        addr = rng.choice([lo - 4, lo, hi - 4, hi]) + rng.randrange(4)
    else:
        addr = WINDOW + rng.randrange(WINDOW_LEN)
    addr = min(max(addr, WINDOW), WINDOW + WINDOW_LEN - 32)
    if kind == "F":
        addr &= ~3
        if addr % 32 > 24:              # the stub's ecall in the same 32-byte grain as its first instruction
            addr -= 4
    else:
        addr &= ~(w - 1)
    cfg0 = sum(entries[i][1] << (8 * i) for i in range(4))
    cfg1 = sum(entries[4 + i][1] << (8 * i) for i in range(4))
    return {"cfg0": cfg0, "cfg1": cfg1, "addr": [e[0] for e in entries], "m0": m0,
            "mode": rng.choice("MU"), "kind": kind, "at": addr,
            "stub": addr if kind == "F" else DATA_STUB}


def program(cases: list) -> bytes:
    src = ["    la t0, handler", "    csrw mtvec, t0"]
    for n, c in enumerate(cases):
        src += [f"case{n}:",
                "    csrw pmpcfg0, zero", "    csrw pmpcfg1, zero", "    csrw 0xbd0, zero",
                f"    li t0, {c['stub']:#x}", f"    li t1, {encode(c['kind']):#x}", "    sw t1, 0(t0)",
                f"    li t1, {ECALL:#x}", "    sw t1, 4(t0)", "    fence.i"]
        for i, a in enumerate(c["addr"]):
            src += [f"    li t0, {a:#x}", f"    csrw {0x3b0 + i:#x}, t0"]
        src += [f"    li t0, {c['m0']:#x}", "    csrw 0xbd0, t0",
                f"    li t0, {c['cfg1']:#x}", "    csrw pmpcfg1, t0",
                f"    li t0, {c['cfg0']:#x}", "    csrw pmpcfg0, t0",
                f"    la s11, case{n + 1}", f"    li t2, {c['at']:#x}", "    li t1, 0x5a5a5a5a",
                f"    li t0, {c['stub']:#x}", "    csrw mepc, t0", "    li t0, 0x1800",
                f"    {'csrs' if c['mode'] == 'M' else 'csrc'} mstatus, t0", "    mret"]
    src += [f"case{len(cases)}:", "    li t0, 0xc0000008", "    sw zero, 0(t0)", "park:", "    j park",
            "handler:", "    csrr t0, mcause", "    li t1, 0xc0000004", "    sw t0, 0(t1)",
            "    csrw mepc, s11", "    li t0, 0x1800", "    csrs mstatus, t0", "    mret"]
    return bytes(0x40) + harness.assemble_at("\n".join(src), BASE + 0x40)


def on_rtl(core: str, cases: list) -> list:
    snap = types.SimpleNamespace(mem=program(cases))
    prints, code, _ = privdiff.rtl_run(snap, 60 * len(cases), CORES[core])
    return prints if code == 0 else prints + [None]


def queries(order: str, cases: list) -> list:
    """Each case's three questions, in order: the stub's fetch, the access, the ecall's fetch."""
    out = []
    for c in cases:
        regs = " ".join(f"{x:x}" for x in [c["cfg0"], c["cfg1"], *c["addr"], c["m0"]])
        k = c["kind"]
        acc = ("F", 4) if k == "F" else ("L" if k[0] == "l" else "S", WIDTH[k])
        for a, w, t in [(c["stub"], 4, "F"), (c["at"], acc[1], acc[0]), (c["stub"] + 4, 4, "F")]:
            out.append(f"{order} {regs} {c['mode']} {a:x} {w:x} {t}")
    return out


def on_model(order: str, cases: list, privrun: str = None) -> list:
    with tempfile.TemporaryDirectory() as tmp:
        q = os.path.join(tmp, "q")
        with open(q, "w") as f:
            f.write("\n".join(queries(order, cases)) + "\n")
        p = subprocess.run([privrun or privdiff.PRIVRUN, "--pmp", q], capture_output=True, text=True, check=True)
    bits = [ln == "1" for ln in p.stdout.split()]
    want = []
    for n, c in enumerate(cases):
        fetch, ok, fetch2 = bits[3 * n:3 * n + 3]
        if not fetch:
            want.append(1)
        elif c["kind"] != "F" and not ok:
            want.append(5 if c["kind"][0] == "l" else 7)
        elif not fetch2:
            want.append(1)
        else:
            want.append(8 if c["mode"] == "U" else 11)
    return want


def images(seed: int = 257, n: int = 4000, locked: int = 400) -> list:
    """The cases, a list per RTL image: a hundred at a time unlocked, each locked one alone."""
    rng = random.Random(seed)
    out = [[make_case(rng, False) for _ in range(100)] for _ in range(n // 100)]
    return out + [[make_case(rng, True)] for _ in range(locked)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=4000)
    ap.add_argument("--locked", type=int, default=400)
    ap.add_argument("--seed", type=int, default=257)
    args = ap.parse_args()
    images_ = images(args.seed, args.cases, args.locked)
    cases = [c for im in images_ for c in im]
    model = {o: on_model(o, cases) for o in CORES}
    with ThreadPoolExecutor(os.cpu_count()) as ex:
        rtl = {core: [w for r in ex.map(lambda im: on_rtl(core, im), images_) for w in r] for core in CORES}
    failed = 0
    for core in CORES:
        if len(rtl[core]) != len(cases):
            print(f"FAIL  {core}: the RTL printed {len(rtl[core])} causes for {len(cases)} cases")
            failed = 1
    if failed:
        return 1
    seen = collections.Counter((c["mode"], c["kind"][0] if c["kind"] != "F" else "F", w)
                               for c, w in zip(cases, rtl["e6"]))
    for order, core in [("e6", "e6"), ("std", "std")]:
        bad = [n for n in range(len(cases)) if model[order][n] != rtl[core][n]]
        name = os.path.basename(CORES[core])
        if bad:
            failed = 1
            print(f"FAIL  chipCheck .{'e6' if order == 'e6' else 'standard'} against {name}: "
                  f"{len(bad)} of {len(cases)} cases differ")
            for n in bad[:5]:
                print(f"      {cases[n]}  model {model[order][n]}  rtl {rtl[core][n]}")
        else:
            print(f"PASS  chipCheck .{'e6' if order == 'e6' else 'standard'} decides as {name} on all "
                  f"{len(cases)} cases ({args.locked} of them locked, each from reset)")
    for order, core in [("e6", "std"), ("std", "e6")]:
        n = sum(model[order][i] != rtl[core][i] for i in range(len(cases)))
        name = os.path.basename(CORES[core])
        if n == 0:
            failed = 1
            print(f"FAIL  chipCheck .{'e6' if order == 'e6' else 'standard'} is never told apart from {name}")
        else:
            print(f"PASS  chipCheck .{'e6' if order == 'e6' else 'standard'} differs from {name} on {n} cases")
    print("      what the cases came to on tb_e6-rp2350, by privilege, access and mcause:")
    for k in sorted(seen):
        print(f"        {k[0]} {k[1]} {k[2]:2}  {seen[k]}")
    return failed


if __name__ == "__main__":
    sys.exit(main())
