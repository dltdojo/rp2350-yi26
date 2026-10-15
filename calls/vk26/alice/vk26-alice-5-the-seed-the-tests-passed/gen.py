#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-5 — what the shell compiles in, computed here.

  gen.py OUT.h RV32RUN TRUST.bin DRBG.bin

  KERNEL, TRUST, DRBG  this experiment's Instantiate kernel (kernel.bin), and
                       vk26-alice-2's and vk26-alice-4's as alice's package
                       writes them (proof/Seed.lean's main), each with its
                       SHA-256, checked against the kernel.sha256 each
                       experiment commits
  KAT_MSG, KAT_WANT    vk26-alice-2's KAT: the message, and hashlib's digest
  CASES                every NIST case of ../tools/cavp/Hash_DRBG_SHA256.txt:
                       the seed material (entropy ‖ nonce ‖ personalization),
                       NIST's ReturnedBits, and the SHA-256 of the region's
                       0x400..0x600 after the Instantiate kernel, as seed.py
                       says it leaves them
  INSTRET_INST, INSTRET_INST_CHAIN, INSTRET_GEN, INSTRET_TRUST[4]
                       minstret for the Instantiate kernel, for it again in the
                       chain, for a Generate of M blocks, and for vk26-alice-2's
                       kernel by its halt code, as the Hazard3 RTL counts them.
                       The RTL counts one more when the word after the ecall a
                       kernel halts on decodes as an instruction: in the chain,
                       the Instantiate kernel's 244 bytes are followed by
                       alice-2's, which the shell leaves as Seed.lean's
                       `restart` does; alone, by zeros

Before writing anything: the Instantiate kernel on the model and the RTL for
the first NIST case, the model after exactly 241 instructions and the region
seed.py's; vk26-alice-2's kernel on the RTL for a stream of each halt code;
and the whole chain on the RTL for a fair stream, its bits seed.py's.
"""
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "tools", "hazard3", "shell"))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from expect import c_bytes, kernel_bin, model  # noqa: E402
from region import rtl_region  # noqa: E402
from hashdrbg import OUT, cavp_cases  # noqa: E402
from trustref import KAT, OUTPUT, bad_wants, image as trust_image, kat_want, trust_outcome, trust_streams  # noqa: E402
from seed import INTERVAL, NONCE, PI, inst_image, inst_region, load_code, nonce_of, seed_chain  # noqa: E402

M = 4
INST_COST = 241
STATE = (0x400, 0x600)   # what the Instantiate kernel lays out for Generate
SEED_MAX = 80


def rtl_code(img):
    said = rtl_region(img, 5000000)
    ran = said[0].split()
    if ran[:1] != ["halt"]:
        sys.exit(f"gen.py: the RTL said {said[0]}")
    return int(ran[1].split("=")[1], 16), int(ran[2].split("=")[1]), said[1]


def chain_image(trust, words, nonce):
    r = bytearray(trust_image(trust, words)) + bytes(0x10000 - OUTPUT)
    r[NONCE:NONCE + len(nonce)] = nonce
    r[PI:PI + 12] = struct.pack("<3I", M, INTERVAL, 32 + len(nonce))
    return bytes(r)


def committed(path, data):
    want = open(path).read().split()[0]
    if hashlib.sha256(data).hexdigest() != want:
        sys.exit(f"gen.py: {os.path.relpath(path, HERE)} does not hash what alice's package writes")
    return want


def write_seed_expect(out, rv32run, trust_bin, drbg_bin):
    inst, sha = kernel_bin(os.path.join(HERE, "kernel"))
    trust, drbg = open(trust_bin, "rb").read(), open(drbg_bin, "rb").read()
    tsha = committed(os.path.join(HERE, "..", "vk26-alice-2-the-hash-tested-first", "kernel.sha256"), trust)
    dsha = committed(os.path.join(HERE, "..", "vk26-alice-4-the-state-the-generator-keeps", "kernel.sha256"), drbg)
    cases = cavp_cases()

    # The Instantiate kernel, and a Generate after it, on the model and the RTL.
    c0 = cases[0]
    img = inst_image(load_code(b"", inst), c0["entropy"] + c0["nonce"] + c0["pers"], M)
    ran, region = model(rv32run, img, INST_COST + 10)
    if ran != f"halt code=00000000 count={INST_COST}" or region != inst_region(img):
        sys.exit(f"gen.py: {c0['name']}: the model {ran}")
    code, n_inst, region = rtl_code(img)
    if code != 0 or region != inst_region(img):
        sys.exit(f"gen.py: {c0['name']}: the RTL's Instantiate is not seed.py's")
    code, n_gen, _ = rtl_code(load_code(region, drbg))
    if code != 0:
        sys.exit("gen.py: the RTL's Generate after Instantiate did not halt with 0")

    # vk26-alice-2's kernel, a stream of each halt code; then the chain.
    every = trust_streams()
    n_trust = {}
    for name, want in (("fair", None), ("stuck at 1 from the start", None), ("seam 11+10", None),
                       ("fair", bad_wants()["first bit flipped"])):
        words = every[name]
        expect = trust_outcome(words, want)[0]
        code, n, _ = rtl_code(chain_image(trust, words, nonce_of(0)) if want is None else
                              bytes(bytearray(trust_image(trust, words, want)) + bytes(0x10000 - OUTPUT)))
        if code != expect:
            sys.exit(f"gen.py: {name}: the RTL halted with {code}, trustref.py says {expect}")
        n_trust[code] = n
    if sorted(n_trust) != [0, 1, 2, 3]:
        sys.exit(f"gen.py: alice-2's kernel halted with {sorted(n_trust)}, not every code")
    words, nonce = every["fair"], nonce_of(7)
    _, bits, _ = seed_chain(words, nonce, M)
    code, _, region = rtl_code(chain_image(trust, words, nonce))
    code_i, n_inst_chain, region = rtl_code(load_code(region, inst))
    code_g, _, region = rtl_code(load_code(region, drbg))
    if (code, code_i, code_g) != (0, 0, 0) or region[OUT:OUT + 32 * M] != bits:
        sys.exit("gen.py: the chain on the RTL is not seed.py's")

    with open(out, "w") as f:
        f.write("// Generated by vk26-alice-5/gen.py. Do not edit.\n#pragma once\n#include <stdint.h>\n\n")
        f.write(f"#define KERNEL_LEN {len(inst)}\n#define TRUST_LEN {len(trust)}\n#define DRBG_LEN {len(drbg)}\n")
        f.write(f"#define NCASES {len(cases)}\n#define M {M}\n#define INTERVAL {INTERVAL}\n")
        f.write(f"#define INSTRET_INST {n_inst}u\n#define INSTRET_INST_CHAIN {n_inst_chain}u\n"
                f"#define INSTRET_GEN {n_gen}u\n")
        f.write("static const uint32_t INSTRET_TRUST[4] = {" + ", ".join(f"{n_trust[k]}u" for k in range(4)) + "};\n")
        for name, data, h in (("KERNEL", inst, sha), ("TRUST", trust, tsha), ("DRBG", drbg, dsha)):
            f.write(f"static const uint8_t {name}[{name}_LEN] = {{{c_bytes(data)}}};\n")
            f.write(f"static const uint8_t {name}_SHA[32] = {{{c_bytes(bytes.fromhex(h))}}};\n")
        f.write("static const uint8_t KAT_MSG[64] = {" + c_bytes(KAT) + "};\n")
        f.write("static const uint8_t KAT_WANT[32] = {" + c_bytes(kat_want()) + "};\n")
        f.write(f"struct kcase {{ char name[16]; uint32_t s; uint8_t seed[{SEED_MAX}], want[32 * M], state[32]; }};\n")
        f.write("static const struct kcase CASES[NCASES] = {\n")
        for c in cases:
            seed = c["entropy"] + c["nonce"] + c["pers"]
            state = inst_region(inst_image(load_code(b"", inst), seed, M))[STATE[0]:STATE[1]]
            f.write(f'    {{"{c["name"]}", {len(seed)}, {{{c_bytes(seed)}}}, {{{c_bytes(c["want"])}}}, '
                    f'{{{c_bytes(hashlib.sha256(state).digest())}}}}},\n')
        f.write("};\n")
    print(f"{out}: Instantiate {sha[:16]}…, alice-2's {tsha[:16]}…, alice-4's {dsha[:16]}…, {len(cases)} NIST "
          f"cases; RTL minstret Instantiate {n_inst} (the proof's {INST_COST}; {n_inst_chain} in the chain), Generate {n_gen}, alice-2's "
          f"{' '.join(str(n_trust[k]) for k in range(4))} for codes 0 to 3")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    write_seed_expect(*sys.argv[1:])
