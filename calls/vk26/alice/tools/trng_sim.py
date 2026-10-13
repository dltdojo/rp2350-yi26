# SPDX-License-Identifier: Apache-2.0
"""calls/vk26/alice/tools — tools/hazard3/shell/trng_sim.h's stand-in for
the TRNG, in Python: the words an alice shell built for the RTL draws, for a
check.sh to judge them ahead. vk26-alice-2's check.sh is the second to need
it, after vk26-alice-1's. (exp232's cure.py has a copy too, lcg_words; this
one is here, not beside trng_sim.h, because a proposal changes only its own
directory.)

  stand_in_words(n, device=0)   the n words board_trng gives with -DDEVICE=
                                device: 0 the LCG's, 1 all ones; None for 2,
                                the TRNG giving nothing
"""


def stand_in_words(n, device=0):
    if device == 2:
        return None
    x, out = 222, []
    for _ in range(n):
        x = (x * 1664525 + 1013904223) & 0xffffffff
        out.append(0xffffffff if device == 1 else x)
    return out
