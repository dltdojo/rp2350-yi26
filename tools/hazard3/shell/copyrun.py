# SPDX-License-Identifier: Apache-2.0
"""tools/hazard3/shell — exp203's copy kernel, run on a message, for a shell
that puts the kernel beside something else on the chip. exp219 wrote this
for its gen.py; exp220 needed it second.

  run_copy(message, rv32run)   exp203's image with MESSAGE as its 64 source
                               bytes, the kernel checked against
                               kernel.sha256, the Lean model's run (it must
                               halt with 0 after exactly 105, the proved count,
                               with the message at the destination), and the
                               Hazard3 RTL's minstret: a dict
  write_copy(f, run)           what every such expect.h holds about the CPU
                               side: the image blocks, the kernel's length and
                               hash, the model's region hash, source,
                               destination and minstret
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP203 = os.path.join(HERE, "..", "..", "..", "experiments", "exp203-the-count-the-proof-promised")
sys.path.insert(0, EXP203)
sys.path.insert(0, HERE)
import images as exp203  # noqa: E402
from expect import CHIP_REGION, c_bytes, model, rtl  # noqa: E402


def run_copy(message, rv32run):
    if len(message) != 64:
        sys.exit("copyrun: the message must be 64 bytes")
    image = exp203.copy_image(message)
    kernel = open(os.path.join(EXP203, "kernel.bin"), "rb").read()
    want = open(os.path.join(EXP203, "kernel.sha256")).read().strip()
    if image[:len(kernel)] != kernel or hashlib.sha256(kernel).hexdigest() != want:
        sys.exit("copyrun: exp203's image does not start with the kernel.sha256 kernel")
    ran, region = model(rv32run, image, 1000)
    if ran != "halt code=00000000 count=105":
        sys.exit(f"copyrun: the model did not halt with 0 after 105 at {CHIP_REGION:#x}: {ran}")
    if region[exp203.DST:exp203.DST + 64] != message:
        sys.exit("copyrun: the model's destination is not the message")
    ran = rtl(image)
    if not ran.startswith("halt code=00000000 instret="):
        sys.exit(f"copyrun: the RTL did not halt with 0: {ran}")
    return dict(image=image, kernel=kernel, sha=want, region=region,
                instret=int(ran.split("instret=")[1].split()[0]))


def write_copy(f, run):
    image, region = run["image"], run["region"]
    blocks = [o for o in range(0, len(image), 64) if any(image[o:o + 64])]
    f.write(f"#define IMAGE_BLOCKS {len(blocks)}\n#define KERNEL_LEN {len(run['kernel'])}\n")
    f.write(f"#define SRC_OFF {exp203.SRC:#x}\n#define DST_OFF {exp203.DST:#x}\n")
    f.write(f"#define EXPECT_INSTRET {run['instret']}u   // the RTL harness's minstret for this image\n\n")
    f.write("static const uint16_t IMAGE_OFFSET[IMAGE_BLOCKS] = {" + ", ".join(hex(o) for o in blocks) + "};\n")
    f.write("static const uint8_t IMAGE_DATA[IMAGE_BLOCKS][64] = {\n")
    for o in blocks:
        f.write("    {" + c_bytes(image[o:o + 64].ljust(64, b"\0")) + "},\n")
    f.write("};\n\n")
    f.write("static const uint8_t KERNEL_SHA[32] = {" + c_bytes(bytes.fromhex(run["sha"])) + "};\n")
    f.write("// " + hashlib.sha256(region).hexdigest() + ": the region, as the model left it\n")
    f.write("static const uint8_t REGION_SHA[32] = {" + c_bytes(hashlib.sha256(region).digest()) + "};\n\n")
