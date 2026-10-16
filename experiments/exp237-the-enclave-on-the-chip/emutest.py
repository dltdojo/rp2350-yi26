#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
exp237 offline: run the monitor and every payload on tools/monitor/emulator.py,
placed where the chip places them (monitor 0x20040000, sandbox 0x20050000), with the
host's registers loaded with distinct values and a `wfi` where its return address
points. The same things enclave.c asks of the silicon are asked of the emulator,
and mutants of the monitor that break each of them must be caught.

  emutest.py              run the checks (exit 1 on any failure)
  emutest.py --lines      print the report the board would print, from this run

The emulator is a second reading of the specification, not the chip: it counts
every retired instruction as one cycle, and it has no USB. What it cannot say is
what the silicon does.
"""

import os
import struct
import subprocess
import sys

import gen
sys.path.insert(0, os.path.join(gen.REPO, "tools"))
from monitor import emulator
emulator.BASE = gen.MONITOR_BASE
M32 = 0xFFFFFFFF

HOST_RET = gen.MONITOR_BASE + 0x800          # a `wfi`: where the host's ra points
HOST_SP = 0x20030000
HOST_MCOUNTINHIBIT = 4                       # not the monitor's 5, so restoring it shows
CTX = 0x440
REPORT, BOOT = 0x400, 0x420
PMPADDR0 = (gen.PAYLOAD_BASE >> 2) | 0x1fff
CALLEE = ["gp", "tp", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11"]
CALLEE_X = [3, 4, 8, 9] + list(range(18, 28))
CALLER_X = [5, 6, 7] + list(range(11, 18)) + [28, 29, 30, 31]       # all but a0

# What the emulator counts on top of the kernel's own instructions: the `csrwi mcountinhibit, 0`
# that starts the counters, the `mret`, and the `ecall` it counts as it traps — and the two it
# does not count, the handler's first instruction (the counters are frozen by then) and the
# ecall's own retirement. The RTL and the chip may count these differently; enclave.c allows
# a window, and the pasted capture is where the chip's own number goes.
FRAMING = 2

KERNEL_OPS = [  # name, op, a, b, expected R, the kernel's instruction count in exp229's model
    ("add", 0, [42], [58], [100], 331),
    ("sub", 1, [100], [42], [58], 238),
    ("mul", 2, [0x12345678], [0x87654321], [0x70b88d78, 0x09a0cd05], 1903),
]


def pad8(v):
    return (v + [0] * 8)[:8]


def host_value(x):
    return 0x70000000 | (x << 8) | x


def run_on_emulator(monitor: bytes, payload: bytes, operands=None):
    img = bytearray(monitor.ljust(gen.PAYLOAD_BASE - gen.MONITOR_BASE, b"\0")) + bytearray(0x10000)
    struct.pack_into("<I", img, HOST_RET - gen.MONITOR_BASE, 0x10500073)      # wfi
    po = gen.PAYLOAD_BASE - gen.MONITOR_BASE
    img[po:po + len(payload)] = payload
    if operands:
        op, a, b = operands
        struct.pack_into("<I", img, po + 0x900, op)
        struct.pack_into("<8I", img, po + 0x904, *pad8(a))
        struct.pack_into("<8I", img, po + 0x924, *pad8(b))
    monitor_before = bytes(img[:len(monitor)])
    emu = emulator.SandboxEmulator(bytes(img), mem_size=0x20000)
    emu.pc = gen.MONITOR_BASE + 0x20
    for x in range(1, 32):
        emu.regs[x] = host_value(x)
    emu.regs[1], emu.regs[2] = HOST_RET, HOST_SP
    emu.mcountinhibit = HOST_MCOUNTINHIBIT
    emu.mscratch = 0
    emu.run(100000)
    mem = emu.mem
    word = lambda off: struct.unpack_from("<I", mem, off)[0]
    return {
        "emu": emu, "halted": emu.halted, "a0": emu.regs[10],
        "tag": word(REPORT), "exit": word(REPORT + 4), "instret": word(REPORT + 8),
        "cycle": word(REPORT + 12), "mcause": word(REPORT + 16), "mepc": word(REPORT + 20),
        "mtval": word(REPORT + 24), "pmpcfg": word(BOOT), "pmpaddr": word(BOOT + 4),
        "R": list(struct.unpack_from("<8I", mem, po + 0x944)),
        "monitor_intact": bytes(mem[:len(monitor)]) == monitor_before,
        "caller_nonzero": sum(1 for x in CALLER_X if emu.regs[x] != 0),
        "callee_bad": [x for x in CALLEE_X + [1, 2] if emu.regs[x] != host_value(x)
                       and not (x == 1 and emu.regs[1] == HOST_RET) and not (x == 2 and emu.regs[2] == HOST_SP)],
        "mscratch": emu.mscratch, "pmpcfg_after": emu.pmpcfg0, "inhibit_after": emu.mcountinhibit,
        "traps": emu.traps,
    }


def everything(monitor, imgs):
    """Every run enclave.c makes, as a list of (name, result)."""
    out = []
    for name, op, a, b, r, _ in KERNEL_OPS:
        out.append((name, run_on_emulator(monitor, imgs["KERNEL"], (op, a, b))))
    out.append(("canary", run_on_emulator(monitor, imgs["CANARY"])))
    out.append(("read", run_on_emulator(monitor, imgs["READ"])))
    out.append(("write", run_on_emulator(monitor, imgs["WRITE"])))
    out.append(("badcall", run_on_emulator(monitor, imgs["BADCALL"])))
    return out


def problems(runs):
    """What is wrong with this monitor, as a list of strings; empty is a pass."""
    bad = []
    byname = dict(runs)
    for name, op, a, b, r, instret in KERNEL_OPS:
        x = byname[name]
        if not x["halted"] or x["a0"] != 0 or x["tag"] != 0x48414C54:
            bad.append(f"{name}: no clean halt (a0={x['a0']} tag={x['tag']:#x} halted={x['halted']})")
        if x["R"] != pad8(r):
            bad.append(f"{name}: wrong result {x['R']}")
        if x["instret"] - instret != FRAMING:
            bad.append(f"{name}: minstret {x['instret']}, wanted the model's {instret} + {FRAMING}")
    c = byname["canary"]
    if c["a0"] != 0x5a or c["tag"] != 0x48414C54:
        bad.append(f"canary: a0={c['a0']:#x} tag={c['tag']:#x}")
    for name, x in runs:
        if x["caller_nonzero"]:
            bad.append(f"{name}: {x['caller_nonzero']} caller-saved registers not zero")
        if x["callee_bad"]:
            bad.append(f"{name}: callee-saved x{x['callee_bad']} not restored")
        if (x["pmpcfg"], x["pmpaddr"]) != (0x1f, PMPADDR0):
            bad.append(f"{name}: PMP readback {x['pmpcfg']:#x},{x['pmpaddr']:#x}")
        if x["mscratch"] or x["pmpcfg_after"] or x["inhibit_after"] != HOST_MCOUNTINHIBIT:
            bad.append(f"{name}: left mscratch={x['mscratch']:#x} pmpcfg0={x['pmpcfg_after']:#x} mcountinhibit={x['inhibit_after']}")
    for name, cause in (("read", 5), ("write", 7), ("badcall", 8)):
        x = byname[name]
        if x["tag"] != 0x4641554C or x["a0"] != 1 or x["mcause"] != cause:
            bad.append(f"{name}: tag={x['tag']:#x} a0={x['a0']} mcause={x['mcause']}, wanted FAULT 1 {cause}")
        if not x["monitor_intact"]:
            bad.append(f"{name}: the monitor's bytes changed")
    return bad


def report_lines(monitor, runs):
    """The lines enclave.c prints for these runs (cycles are the emulator's: one per instruction)."""
    byname = dict(runs)
    out = [f"ENCLAVE monitor_bytes={len(monitor)} monitor_words={gen.words_used(monitor)} "
           f"pmpcfg0=0x{byname['add']['pmpcfg']:02x} pmpaddr0=0x{byname['add']['pmpaddr']:08x} pmp=64k_napot"]
    for name, _, _, _, _, instret in KERNEL_OPS:
        x = byname[name]
        out.append(f"OP {name} a0={x['a0']} minstret={x['instret']} model={instret} again={x['instret']} cycles={x['cycle']} status=OK")
    c = byname["canary"]
    out.append(f"TEST scrub exit=0x5a caller_saved_nonzero={c['caller_nonzero']} callee_saved_bad=0 monitor_intact=yes status=OK")
    for name, cause in (("read", 5), ("write", 7), ("badcall", 8)):
        x = byname[name]
        out.append(f"TEST fault_{name} mcause={cause} mtval=0x{x['mtval']:08x} a0={x['a0']} caller_saved_nonzero=0 "
                   f"callee_saved_bad=0 monitor_intact=yes status=OK")
    out.append("STATUS PASS")
    return out


def mutants(src: str):
    """(name, source with one thing broken) — each must be refused by problems()."""
    def drop(line):
        i = src.rindex(line)                       # the last: the scrub's, not the boot's
        return src[:i] + src[i + len(line):]
    yield "s0 not restored", drop("    lw    s0, 16(t1)\n")
    yield "gp not restored", drop("    lw    gp,  8(t1)\n")
    yield "a caller-saved register left", drop("    li    x28, 0\n")
    yield "t1 left holding the context", drop("    li    x6, 0\n")
    yield "mscratch left", drop("    csrw  mscratch, zero\n")
    yield "counters left frozen", drop("    csrw  mcountinhibit, t0\n")
    yield "pmp wide open", src.replace("li    t0, DOMAIN_PMPADDR0", "li    t0, 0x1fffffff", 1)
    yield "pmp never set", drop("    csrw  pmpcfg0, t0\n")
    yield "every ecall is a halt", src.replace("bne   t0, t1, handle_fault", "nop", 1)


def probe_launch_bytes():
    """probe_launch's machine code, cut out of the built ELF (it is position independent), or None."""
    elf = os.path.join(gen.HERE, "build", "exp237.elf")
    if not os.path.exists(elf):
        return None
    sym = [l.split() for l in subprocess.run(["llvm-nm", "-S", elf], capture_output=True, text=True).stdout.splitlines()]
    addr, size = next((int(l[0], 16), int(l[1], 16)) for l in sym if len(l) == 4 and l[3] == "probe_launch")
    raw = os.path.join(gen.HERE, "build", "exp237.bin")
    with open(raw, "rb") as f:
        f.seek(addr - 0x10000000)
        return f.read(size)


def probe_launch_on_emulator(monitor, payload, probe):
    """enclave.c's probe_launch, as built for the chip, calling the monitor on the emulator."""
    img = bytearray(monitor.ljust(gen.PAYLOAD_BASE - gen.MONITOR_BASE, b"\0")) + bytearray(0x10000)
    struct.pack_into("<I", img, HOST_RET - gen.MONITOR_BASE, 0x10500073)
    img[0x1000:0x1000 + len(probe)] = probe
    po = gen.PAYLOAD_BASE - gen.MONITOR_BASE
    img[po:po + len(payload)] = payload
    emu = emulator.SandboxEmulator(bytes(img), mem_size=0x20000)
    emu.pc = gen.MONITOR_BASE + 0x1000
    emu.regs[1], emu.regs[2], emu.regs[10] = HOST_RET, gen.MONITOR_BASE + 0xf000, gen.MONITOR_BASE + 0x900
    for x in [5, 6, 7] + list(range(11, 18)) + [28, 29, 30, 31]:
        emu.regs[x] = 0x3000 + x
    emu.run(100000)
    out = list(struct.unpack_from("<15I", emu.mem, 0x900))
    return emu.halted, emu.regs[10], out


def exp237_offline_checks():
    import tempfile
    build = os.path.join(gen.HERE, "build")
    imgs = gen.build_images(build)
    mon = imgs["MONITOR"]
    runs = everything(mon, imgs)
    failed = 0

    def check(ok, what, detail=""):
        nonlocal failed
        print(f"{'PASS' if ok else 'FAIL'}  {what}" + ("" if ok or not detail else f" — {detail}"))
        failed += not ok

    if "--lines" in sys.argv:
        bad = problems(runs)
        if bad:
            sys.exit("\n".join(bad))
        print("\n".join(report_lines(mon, runs)))
        return

    bad = problems(runs)
    check(not bad, "the monitor, run on the emulator, does everything enclave.c asks of the chip", "; ".join(bad))
    probe = probe_launch_bytes()
    if probe is None:
        print("SKIP  probe_launch as built: build/exp237.elf is not there (run ./build.sh)")
    else:
        halted, a0, out = probe_launch_on_emulator(mon, imgs["CANARY"], probe)
        check(halted and a0 == 0x5a and out == [0] * 15,
              "probe_launch as built for the chip: the canary's registers come back zero, the callee-saved ones restored",
              f"halted={halted} a0={a0:#x} out={out}")
    src = open(os.path.join(gen.HERE, "shell", "monitor_chip.S")).read()
    if probe is not None:
        # and the probe must see it when the monitor does not give a callee-saved register back
        i = src.rindex("    lw    s5, 36(t1)\n")
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "monitor_chip.S")
            open(p, "w").write(src[:i] + src[i + len("    lw    s5, 36(t1)\n"):])
            m = gen.assemble_pp(p, gen.MONITOR_BASE, d)
        halted, a0, out = probe_launch_on_emulator(m, imgs["CANARY"], probe)
        check(halted and out[14] == 1, "probe_launch counts a callee-saved register the monitor did not restore", f"out[14]={out[14]}")
    for name, text in mutants(src):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "monitor_chip.S")
            open(p, "w").write(text)
            m = gen.assemble_pp(p, gen.MONITOR_BASE, d)
        bad = problems(everything(m, imgs))
        check(bool(bad), f"mutant refused: {name}", "the checks passed it")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    exp237_offline_checks()
