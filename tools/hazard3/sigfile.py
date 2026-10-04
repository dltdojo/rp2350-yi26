# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3 — reading what `sim.sh run --dump` wrote.

The testbench's --sigfile format: one little-endian 32-bit word per line, in
hex, from the region's first byte. `rv32run` writes the same format, so a dump
from either executor reads the same way. exp203 wrote this first; exp204
needed it second.
"""


def read_sig(path):
    """The dumped region, as bytes."""
    out = bytearray()
    for line in open(path):
        line = line.strip()
        if line:
            out += int(line, 16).to_bytes(4, "little")
    return bytes(out)
