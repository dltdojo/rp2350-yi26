/* SPDX-License-Identifier: Apache-2.0
 *
 * exp230 — T3 by brute force: for every one of the 2^32 rings, one generation
 * of Rule 30, what moved up and what moved down. The proof says none moves
 * down more than up; this counts, apart from it, written cell by cell rather
 * than with the proof's rotations. And T2's exception: the rings that moved
 * two cells are themselves, which the README says are exactly four.
 */
#include <stdint.h>
#include <stdio.h>

static uint32_t rule30(uint32_t x)
{
    uint32_t y = 0;
    for (int i = 0; i < 32; i++) {
        uint32_t left = (x >> ((i + 1) & 31)) & 1, centre = (x >> i) & 1, right = (x >> ((i + 31) & 31)) & 1;
        y |= (left ^ (centre | right)) << i;
    }
    return y;
}

static int count(uint32_t x)
{
    int n = 0;
    for (; x; x &= x - 1) n++;
    return n;
}

int main(void)
{
    uint64_t more_down = 0, even = 0, more_up = 0, period2 = 0;
    uint32_t found[8];
    for (uint64_t v = 0; v <= 0xffffffffu; v++) {
        uint32_t x = (uint32_t)v, y = rule30(x);
        uint32_t below = (x << 1) | (x >> 31), above = (x >> 1) | (x << 31);
        int r = count(below & y) - count(above & y);
        if (r < 0) more_down++; else if (r == 0) even++; else more_up++;
        uint32_t two = (x << 2) | (x >> 30);
        if (two == x) {
            if (period2 < 8) found[period2] = x;
            period2++;
        }
    }
    printf("%s  all 4294967296 rings: %llu seen moving down, %llu not moving, %llu moving up\n",
           more_down ? "FAIL" : "PASS", (unsigned long long)more_down, (unsigned long long)even,
           (unsigned long long)more_up);
    printf("%s  rings that moved two cells are themselves: %llu —", period2 == 4 ? "PASS" : "FAIL",
           (unsigned long long)period2);
    for (uint64_t i = 0; i < period2 && i < 8; i++) printf(" %08x", found[i]);
    printf("\n");
    return more_down != 0 || period2 != 4;
}
