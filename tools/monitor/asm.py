#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Micro-Monitor assembly and Lean extraction tool.

Assembles monitor.S using clang and llvm-objcopy into a flat binary monitor.bin,
computes its SHA-256 hash, and verifies or emits its words as Lean 4 array syntax.
"""

import hashlib
import os
import struct
import subprocess
import sys

def assemble(src_path: str, out_bin: str, text_addr: int = 0x80000000):
    elf_path = out_bin + ".elf"
    cmd = [
        "clang",
        "--target=riscv32-unknown-elf",
        "-march=rv32im_zicsr",
        "-mabi=ilp32",
        "-O2",
        "-nostdlib",
        "-ffreestanding",
        "-fno-pic",
        "-mno-relax",
        "-fuse-ld=lld",
        f"-Wl,-Ttext=0x{text_addr:x}",
        "-o", elf_path,
        src_path,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.stderr.write(f"Assembly failed:\n{res.stderr}\n")
        sys.exit(res.returncode)

    res2 = subprocess.run(["llvm-objcopy", "-O", "binary", elf_path, out_bin], capture_output=True, text=True)
    if res2.returncode != 0:
        sys.stderr.write(f"llvm-objcopy failed:\n{res2.stderr}\n")
        sys.exit(res2.returncode)
    if os.path.exists(elf_path):
        os.remove(elf_path)

def read_words(bin_path: str):
    with open(bin_path, "rb") as f:
        data = f.read()
    assert len(data) % 4 == 0, f"Binary size {len(data)} is not a multiple of 4"
    words = [struct.unpack("<I", data[i:i+4])[0] for i in range(0, len(data), 4)]
    return words

def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def format_lean_words(words, var_name: str = "monitorCode") -> str:
    lines = [f"def {var_name} : List Word := ["]
    for i, w in enumerate(words):
        comma = "," if i < len(words) - 1 else ""
        lines.append(f"  0x{w:08x}#32{comma}")
    lines.append("]")
    return "\n".join(lines)

def main():
    if len(sys.argv) < 3:
        print("Usage: asm.py assemble <monitor.S> <monitor.bin> [text_addr_hex]")
        print("       asm.py emit-lean <monitor.bin> [var_name]")
        print("       asm.py sha256 <monitor.bin>")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "assemble":
        src = sys.argv[2]
        dst = sys.argv[3]
        addr = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x80000000
        assemble(src, dst, addr)
        words = read_words(dst)
        print(f"Assembled {len(words)} instructions ({len(words)*4} bytes) -> {dst}")
    elif cmd == "emit-lean":
        bin_path = sys.argv[2]
        var_name = sys.argv[3] if len(sys.argv) > 3 else "monitorCode"
        words = read_words(bin_path)
        print(format_lean_words(words, var_name))
    elif cmd == "sha256":
        bin_path = sys.argv[2]
        print(sha256_file(bin_path))
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()

