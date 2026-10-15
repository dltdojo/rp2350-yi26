#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""vk26-alice-4 — the reference: Hash_DRBG from SP 800-90A Rev. 1's text
(§10.1.1, §10.3.1), with SHA-256 and seedlen = 440 bits, nothing like the
kernel's registers; and what the kernel's region must hold before and after.

  drbg.py            every case of ../tools/cavp/Hash_DRBG_SHA256.txt: instantiate,
                     Generate twice, the second's bits against NIST's

  drbg_instantiate(entropy, nonce, pers)   (V, C, reseed_counter), §10.1.1.2
  drbg_generate(state, nbytes)             (bits, new state), §10.1.1.4, no
                                      additional input; None when a reseed
                                      is required
  drbg_image(kernel, state, interval, m)
                     the region's image: the kernel, then the state where
                     the kernel keeps it (the header of proof/Drbg.lean)
  drbg_outcome(state, interval, m)
                     (halt code, {offset: bytes}): what Generate leaves
  drbg_region(img, state, interval, m)
                     (halt code, the whole 64 KiB region afterwards)
  cavp_cases()       the NIST cases, as dicts

Instantiate's Hash_df is here so that NIST's vectors can be used. It is not
the kernel's and is in no proof: vk26-alice-5 is where it is meant to be.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
# The reference itself is alice's, in ../tools/hashdrbg.py since vk26-alice-5
# became its second user; this file is what this experiment imports and runs.
from hashdrbg import (  # noqa: E402,F401
    SEEDLEN, PARAMS, PRE, V_AT, C_AT, DATA, HB, CB, ONE, OUT, MAX_BLOCKS,
    sha256, hash_df, drbg_instantiate, plus, hashgen, drbg_generate, drbg_image, drbg_outcome, drbg_region, cavp_cases, cavp_check)


if __name__ == "__main__":
    cavp_check()
