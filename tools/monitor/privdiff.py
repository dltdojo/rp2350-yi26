#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
privdiff — the Tier 2 model against the emulator, one instruction at a time, on every run a suite makes.

`lean/Rv32/Priv.lean` and `emulator.py` are two readings of the same documents, by the same hands: a monitor suite
checks the emulator, and a monitor proof is about the model, and until now neither was held against the other.
This holds them together.

    privdiff.py SUITE.py [ARGS...]      run SUITE.py as it is, then replay every emulator run it made against the
                                        model; print one JSON line of what was compared, and exit 1 on a difference

While the suite runs, `SandboxEmulator.step` is wrapped: the first time a machine steps, a copy of it is kept, and
every step it takes is counted. The suite is not changed and does not know. When it exits, each copy is run again,
as many steps as the original took, and the same machine is given to `privrun` -- `PrivMachine.step`, compiled,
from `lean/PrivExec.lean`. After every step the two must agree on everything software can read: `pc`, the mode,
the 31 registers, the 13 CSRs as a `csrr` returns them; on every byte the instruction could have written; on every
word stored to a port. At the end, the whole RAM.

What is not compared, and why:
  * runs of a `ReferenceEmulator`: those are the Tier 1 shell, M-mode with `ecall` answered in place -- the model
    of that is `rv32run`, which exp202 holds against the RTL;
  * the step that executes `wfi`, and every step after it: the model has no `wfi`, and the monitor theorems end
    with `pc` at it;
  * the host: what a port load returns, and the digest a hash request writes back, are the host's, not the
    machine's. The model is given the emulator's host's answers, keyed as the model keys them, by how many port
    words have been stored.

    privdiff.py --runs SUITE.py ...     only count the runs and steps, compare nothing
    privdiff.py --rtl SUITE.py ...      the same runs on the Hazard3 RTL instead (tools/hazard3/setup.sh's
                                        `tb-rp2350`, or the testbench PRIVDIFF_TB names): every run that starts
                                        from a reset -- `pc` at the reset vector, M-mode, every CSR 0 -- is run
                                        from the same RAM until it writes the exit word, and must print the same
                                        words, exit with the same code and leave the same RAM as the emulator;
                                        a run that calls the service port is counted and not compared: the
                                        testbench has no host behind it

The RTL is held at the end only: the testbench prints what the program writes to the print port and dumps the
RAM, and that is all it shows. Its registers start at 0 where the emulator's start at junk (to catch a monitor
that trusts them), so for the RTL the emulator starts at 0 too.
"""

import atexit
import copy
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../.."))
TB = os.environ.get("PRIVDIFF_TB", os.path.join(REPO, "tools", "hazard3", "Hazard3", "test", "sim", "tb_verilator",
                                                "tb-rp2350"))
PRIVRUN = os.environ.get("PRIVRUN", os.path.join(REPO, "lean", ".lake", "build", "bin", "privrun"))
sys.path.insert(0, os.path.join(REPO, "tools"))

from monitor import emulator as E  # noqa: E402

PORTS = (0xC0000000, 0xC0000020)
SVC_REQUEST = 0xC000001C
CSRS = [E.MSTATUS, E.MTVEC, E.MCOUNTINHIBIT, E.MSCRATCH, E.MEPC, E.MCAUSE, E.PMPCFG0,
        E.PMPADDR0, E.PMPADDR0 + 1, E.PMPADDR0 + 2, E.PMPADDR0 + 3, E.MCYCLE, E.MINSTRET]
CSR_NAMES = ["mstatus", "mtvec", "mcountinhibit", "mscratch", "mepc", "mcause", "pmpcfg0",
             "pmpaddr0", "pmpaddr1", "pmpaddr2", "pmpaddr3", "mcycle", "minstret"]
FIELDS = ["pc", "mode", "halted"] + [f"x{i}" for i in range(1, 32)] + CSR_NAMES


def line(emu) -> str:
    return " ".join(["S", f"{emu.pc:08x}", emu.mode, "0"] + [f"{r & E.M32:08x}" for r in emu.regs[1:]]
                    + [f"{emu.csr_read(n) & E.M32:08x}" for n in CSRS])


def is_reference(emu) -> bool:
    return any("Reference" in c.__name__ for c in type(emu).__mro__)


# ---- capture ---------------------------------------------------------------------------------------

RUNS = []          # [snapshot, steps]


def _wrap(cls):
    step = cls.step

    def counted(self):
        rec = self.__dict__.get("_privdiff")
        if rec is None:
            rec = [None, 0]
            self.__dict__["_privdiff"] = rec
            if not is_reference(self):
                rec[0] = copy.deepcopy(self)
                RUNS.append(rec)
        rec[1] += 1
        return step(self)

    cls.step = counted


# ---- replay ----------------------------------------------------------------------------------------

def replay(snap, steps):
    """Run a copy of `snap` for `steps` steps. Returns (lines, writes, ios, answers, digests, final emulator):
    per step the line, the RAM after it, and the port words it stored; the host's answers and digests."""
    emu = copy.deepcopy(snap)
    emu.__dict__["_privdiff"] = [None, 0]
    stored, answers, digests = [], [], []
    store, load = emu.store, emu.load

    def st(addr, width, val):
        store(addr, width, val)
        if PORTS[0] <= addr < PORTS[1] and width == 4:
            stored.append((addr, val & E.M32))

    def ld(addr, width):
        v = load(addr, width)
        if PORTS[0] <= addr < PORTS[1] and width == 4:
            answers.append((len(stored), addr, v & E.M32))
        return v

    emu.store, emu.load = st, ld
    lines, ios = [], []
    for _ in range(steps):
        if emu.halted:
            break
        n = len(stored)
        emu.step()
        if emu.halted:            # `wfi`: the model has none
            break
        new = stored[n:]
        for i, (a, v) in enumerate(new):
            if a == SVC_REQUEST and v == 2 and emu.mode == "M":
                out = emu.__dict__.get("host")
                req = out.requests[-1] if out is not None and getattr(out, "requests", None) else None
                if req is not None:
                    off = req[3] - E.BASE
                    digests.append((n + i + 1, bytes(emu.mem[off:off + 32]) if 0 <= off < len(emu.mem) else bytes(32)))
        lines.append(line(emu))
        ios.append(new)
    return lines, ios, answers, digests, emu


def scenario(snap, steps, answers, digests, path):
    ram = path + ".ram"
    with open(ram, "wb") as f:
        f.write(bytes(snap.mem))
    # Tier 1's region: the monitor theorems' `monRegion`, reaching down to the RAM when it starts lower (exp237's)
    out = [f"ram {E.BASE:x} {ram}", f"region {min(E.BASE, 0x80000000):x} c0000100", f"pc {snap.pc:x}",
           f"mode {snap.mode}", "halted 0"]
    out += [f"reg {i:x} {snap.regs[i] & E.M32:x}" for i in range(1, 32)]
    raw = {"mstatus": snap.mstatus, "mtvec": snap.mtvec, "mscratch": snap.mscratch, "mepc": snap.mepc,
           "mcause": snap.mcause, "mcountinhibit": snap.mcountinhibit, "pmpcfg0": snap.pmpcfg0,
           "mcycle": snap.mcycle, "minstret": snap.minstret}
    raw.update({f"pmpaddr{i}": snap.pmpaddr[i] for i in range(4)})
    out += [f"csr {k} {v & E.M32:x}" for k, v in raw.items()]
    out += [f"answer {k:x} {a:x} {v:x}" for k, a, v in answers]
    out += [f"digest {k:x} {d.hex()}" for k, d in digests]
    out.append(f"steps {steps:x}")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def differ(a: str, b: str) -> str:
    fa, fb = a.split()[1:], b.split()[1:]
    return ", ".join(f"{FIELDS[i]}: emulator {fa[i]}, model {fb[i]}" for i in range(len(FIELDS)) if fa[i] != fb[i])


def at_step(snap, k):
    """The instruction the `k`th step ran, and the address a load or store in it touched."""
    emu = copy.deepcopy(snap)
    emu.__dict__["_privdiff"] = [None, 0]
    for _ in range(k - 1):
        emu.step()
    off = emu.pc - E.BASE
    w = int.from_bytes(emu.mem[off:off + 4], "little") if 0 <= off <= len(emu.mem) - 4 else None
    out = {"insn": f"{w:08x}" if w is not None else "none", "mode": emu.mode}
    if w is not None and w & 0x7F in (0x03, 0x23):
        imm = (w >> 20) if w & 0x7F == 0x03 else ((w >> 25) << 5) | ((w >> 7) & 31)
        out["addr"] = f"{(emu.regs[(w >> 15) & 31] + E.sext(imm, 12)) & E.M32:08x}"
    return out


def compare(snap, steps):
    """None if the model agrees with the emulator on this run, else what differs first."""
    lines, ios, answers, digests, emu = replay(snap, steps)
    with tempfile.TemporaryDirectory() as tmp:
        sc = os.path.join(tmp, "scenario")
        scenario(snap, len(lines), answers, digests, sc)
        ram_out = os.path.join(tmp, "ram.out")
        p = subprocess.run([PRIVRUN, sc, ram_out], capture_output=True, text=True)
        if p.returncode:
            return {"step": 0, "what": f"privrun failed: {p.stderr.strip()}"}
        model = p.stdout.splitlines()
        k, step = 0, 0
        for step, want in enumerate(lines):
            got = model[k] if k < len(model) else ""
            k += 1
            if got != want:
                return {"step": step + 1, "pc": snap_pc(lines, step, snap), "what": differ(want, got) or got,
                        **at_step(snap, step + 1)}
            mio = []
            while k < len(model) and not model[k].startswith("S "):
                kind, a, v = model[k].split()
                if kind == "IO":           # the bytes written (`W`) are held against the RAM at the end
                    mio.append((int(a, 16), int(v, 16)))
                k += 1
            if mio != ios[step]:
                return {"step": step + 1, "pc": snap_pc(lines, step, snap),
                        "what": f"port words: emulator {[(hex(a), hex(v)) for a, v in ios[step]]}, "
                                f"model {[(hex(a), hex(v)) for a, v in mio]}"}
        with open(ram_out, "rb") as f:
            ram = f.read()
        if ram != bytes(emu.mem):
            at = next(i for i in range(min(len(ram), len(emu.mem))) if ram[i] != emu.mem[i]) if len(ram) == len(emu.mem) else 0
            return {"step": len(lines), "what": f"RAM differs at the end, first at {E.BASE + at:#x}: "
                                                f"emulator {emu.mem[at]:02x}, model {ram[at]:02x}"}
    return None


def snap_pc(lines, step, snap):
    """The pc the differing step started from."""
    return f"{int(lines[step - 1].split()[1], 16) if step else snap.pc:#010x}"


# ---- the RTL ---------------------------------------------------------------------------------------

def from_reset(snap) -> bool:
    return (snap.pc == E.BASE + 0x40 and snap.mode == "M" and not snap.halted and
            not any([snap.mstatus, snap.mtvec, snap.mscratch, snap.mepc, snap.mcause, snap.mcountinhibit,
                     snap.pmpcfg0, snap.mcycle, snap.minstret, *snap.pmpaddr]))


SVC = (0xC0000010, 0xC0000020)


def rtl_run(snap, steps, tb=None):
    """The testbench `tb` run from `snap`'s RAM until it writes the exit word: (words printed, exit code or None,
    the RAM afterwards)."""
    with tempfile.TemporaryDirectory() as tmp:
        img, sig = os.path.join(tmp, "image.bin"), os.path.join(tmp, "sig")
        with open(img, "wb") as f:
            f.write(bytes(snap.mem))
        end = E.BASE + len(snap.mem)
        p = subprocess.run([tb or TB, "--bin", img, "--cycles", str(20 * steps + 10000),
                            "--dump", f"{E.BASE:#x}", f"{end:#x}", "--sigfile", sig],
                           capture_output=True, text=True)
        # the testbench prints each word stored to the print port on a line of its own
        prints = [int(ln, 16) for ln in (l.strip() for l in p.stdout.splitlines())
                  if len(ln) == 8 and all(c in "0123456789abcdef" for c in ln)]
        code = None
        for ln in (p.stdout + p.stderr).splitlines():
            if "CPU requested halt" in ln:
                code = int(ln.rsplit(" ", 1)[1]) & E.M32
        words = [int(w, 16) for w in open(sig).read().split()] if os.path.exists(sig) else []
    return prints, code, b"".join(w.to_bytes(4, "little") for w in words)


def model_run(snap, steps):
    """privrun from `snap` for `steps` steps, the host the emulator's: (words printed, exit code or None)."""
    lines, _, answers, digests, _ = replay(snap, steps)
    with tempfile.TemporaryDirectory() as tmp:
        sc = os.path.join(tmp, "scenario")
        scenario(snap, max(len(lines), 1), answers, digests, sc)
        p = subprocess.run([PRIVRUN, sc, os.path.join(tmp, "ram.out")], capture_output=True, text=True)
    io = [ln.split()[1:] for ln in p.stdout.splitlines() if ln.startswith("IO ")]
    prints = [int(v, 16) for a, v in io if int(a, 16) == E.IO_PRINT]
    exits = [int(v, 16) for a, v in io if int(a, 16) == E.IO_EXIT]
    return prints, (exits[0] if exits else None)


def on_rtl(snap, steps):
    """None if the RTL ends this run as the emulator does, "service" if the run calls the host, which the testbench
    does not have, else what differs. The emulator starts from registers 0, as the RTL does."""
    snap = copy.deepcopy(snap)
    snap.regs = [0] * 32
    _, ios, _, _, emu = replay(snap, steps)
    stored = [w for step in ios for w in step]
    if any(SVC[0] <= a < SVC[1] for a, _ in stored):
        return "service"
    exits = [v for a, v in stored if a == E.IO_EXIT]
    emu_exit = exits[0] if exits else None
    prints, code, ram = rtl_run(snap, steps)
    got = {}
    if code != emu_exit:
        got["exit"] = f"emulator {emu_exit if emu_exit is not None else 'none'}, RTL {code if code is not None else 'none'}"
    if prints != emu.prints:
        got["prints"] = {"emulator": [f"{w:08x}" for w in emu.prints], "RTL": [f"{w:08x}" for w in prints]}
    if ram != bytes(emu.mem):
        at = [i for i in range(min(len(ram), len(emu.mem))) if ram[i] != emu.mem[i]]
        got["ram"] = f"{len(at)} bytes differ, first at {E.BASE + at[0]:#x}" if at else f"{len(ram)} bytes dumped"
    if got and emu.traps:          # what the emulator trapped on first, to say what the RTL did instead
        tr = emu.traps[0]
        off = tr["mepc"] - E.BASE
        w = int.from_bytes(emu.mem[off:off + 4], "little") if 0 <= off <= len(emu.mem) - 4 else None
        got["trap"] = {"cause": tr["cause"], "mode": tr["mode"], "insn": f"{w:08x}" if w is not None else "none"}
    return got or None


# ---- main ------------------------------------------------------------------------------------------

def report(suite, mode):
    runs = [(s, n) for s, n in RUNS if s is not None]
    total = sum(n for _, n in runs)
    res = {"suite": suite, "runs": len(runs), "steps": total}
    if mode == "rtl":
        reset = [(i, s, n) for i, (s, n) in enumerate(runs) if from_reset(s)]
        diffs, service = [], 0
        for i, s, n in reset:
            d = on_rtl(s, n)
            if d == "service":
                service += 1
            elif d is not None:
                d["run"] = i
                diffs.append(d)
        res.update({"tb": os.path.basename(TB), "from_reset": len(reset), "service": service, "differ": len(diffs),
                    "all": diffs})
    elif mode == "model":
        diffs = []
        for i, (s, n) in enumerate(runs):
            d = compare(s, n)
            if d is not None:
                d["run"] = i
                diffs.append(d)
        res["differ"] = len(diffs)
        res["all"] = diffs
    out = os.environ.get("PRIVDIFF_OUT")
    text = json.dumps(res)
    if out:
        with open(out, "a") as f:
            f.write(text + "\n")
    print(text, file=sys.stderr)
    if res.get("differ"):
        os._exit(1)


def main():
    args = sys.argv[1:]
    mode = {"--runs": "count", "--rtl": "rtl"}.get(args[0] if args else "", "model")
    if mode != "model":
        args = args[1:]
    if not args:
        print(__doc__)
        return 2
    suite = os.path.abspath(args[0])
    _wrap(E.SandboxEmulator)
    atexit.register(report, suite, mode)
    sys.argv = [suite] + args[1:]
    sys.path.insert(0, os.path.dirname(suite))
    # the suite as its check.sh runs it: from its experiment's directory
    exp = os.path.dirname(suite)
    while exp != "/" and not os.path.basename(exp).startswith("exp"):
        exp = os.path.dirname(exp)
    os.chdir(exp if exp != "/" else os.path.dirname(suite))
    import runpy
    runpy.run_path(suite, run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main())
