#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-2 — the reference: what a kernel that tests its hash first must
leave, for any hash function, written from the plan and alice/tools/health.py,
and nothing like the kernel's registers.

  trust.py           print every stream in trust_streams() and what it gives

The order is the plan's:

  1. the known-answer test: H of the 64-byte KAT message, written to the
     KAT's scratch; if it is not the expected digest the image carries,
     stop with 2;
  2. the start-up test: SP 800-90B section 4.3 item 4, the continuous tests
     over at least 1024 consecutive samples; one window of 1024. Its samples
     are discarded, which item 4 allows ("or may be discarded at any time").
     If it fails, stop with 1;
  3. one more window, the repetition count carried on from the start-up
     window (health.py's tests over both); if it fails, stop with 3;
  4. H of that window's 4096 bytes is the output; stop with 0.

  trust_outcome(words, want, H)
                     (code, writes, why): the halt code, and every byte the
                     kernel writes as {offset: bytes} — the KAT's answer
                     always, the output only with code 0
  image(kernel, words, want)
                     the region's image: the kernel, the KAT message and its
                     expected digest, the samples

A sample is the word the shell writes; the tests see its bit 0.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
# The reference itself is alice's, in ../tools/trustref.py since vk26-alice-5
# became its second user; this file is what this
# experiment imports and runs.
from trustref import (  # noqa: E402,F401
    IMAGE_END, KAT, KAT_GOT, KAT_MSG, KAT_WANT, OUTPUT, SAMPLES, WINDOWS, bad_wants, image, kat_want, sha256,
    trust_outcome, trust_streams)


if __name__ == "__main__":
    for name, words in trust_streams().items():
        code, writes, why = trust_outcome(words)
        print(f"{name:34} halt {code}  {'output written' if OUTPUT in writes else 'no output':14}  "
              f"{why or 'both windows passed'}")
    for name, want in bad_wants().items():
        code, _, why = trust_outcome(trust_streams()["fair"], want)
        print(f"KAT: {name:28} halt {code}  {why}")
