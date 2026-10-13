/* SPDX-License-Identifier: Apache-2.0
 *
 * exp230 — T3 by brute force: for every one of the 2^32 rings, one generation
 * of Rule 30, what moved up and what moved down. The proof says none moves
 * down more than up; this counts, apart from it, written cell by cell rather
 * than with the proof's rotations. And T2's exception: the rings that moved
 * two cells are themselves, which the README says are exactly four.
 *
 * The rings are split into one range per core, each counted in a child of its
 * own: five minutes on one core was most of run.sh. The counts are summed, and
 * the rings found are kept in the order of the ranges, so what is printed is
 * what counting them one after another prints.
 */
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

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

struct tally {
    uint64_t more_down, even, more_up, period2;
    uint32_t found[8];
};

static void scan(uint64_t from, uint64_t to, struct tally *t)
{
    for (uint64_t v = from; v < to; v++) {
        uint32_t x = (uint32_t)v, y = rule30(x);
        uint32_t below = (x << 1) | (x >> 31), above = (x >> 1) | (x << 31);
        int r = count(below & y) - count(above & y);
        if (r < 0) t->more_down++; else if (r == 0) t->even++; else t->more_up++;
        uint32_t two = (x << 2) | (x >> 30);
        if (two == x) {
            if (t->period2 < 8) t->found[t->period2] = x;
            t->period2++;
        }
    }
}

#define MAX_PARTS 16

int main(void)
{
    const uint64_t all = (uint64_t)1 << 32;
    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    int parts = cores < 1 ? 1 : cores > MAX_PARTS ? MAX_PARTS : (int)cores;
    struct tally part[MAX_PARTS] = {{0}};
    int fd[MAX_PARTS];
    pid_t pid[MAX_PARTS];

    for (int p = 0; p < parts; p++) {
        uint64_t from = all * p / parts, to = all * (p + 1) / parts;
        int pipefd[2];
        pid[p] = -1;
        if (pipe(pipefd) == 0 && (pid[p] = fork()) == 0) {
            close(pipefd[0]);
            scan(from, to, &part[p]);
            _exit(write(pipefd[1], &part[p], sizeof part[p]) == sizeof part[p] ? 0 : 1);
        }
        if (pid[p] < 0) {               /* no child: count this range here */
            scan(from, to, &part[p]);
            fd[p] = -1;
        } else {
            close(pipefd[1]);
            fd[p] = pipefd[0];
        }
    }

    struct tally t = {0};
    int lost = 0;
    for (int p = 0; p < parts; p++) {
        if (fd[p] >= 0) {
            int status = 0;
            if (read(fd[p], &part[p], sizeof part[p]) != sizeof part[p]) lost = 1;
            close(fd[p]);
            if (waitpid(pid[p], &status, 0) != pid[p] || !WIFEXITED(status) || WEXITSTATUS(status)) lost = 1;
        }
        t.more_down += part[p].more_down;
        t.even += part[p].even;
        t.more_up += part[p].more_up;
        for (uint64_t i = 0; i < part[p].period2 && i < 8; i++)
            if (t.period2 + i < 8) t.found[t.period2 + i] = part[p].found[i];
        t.period2 += part[p].period2;
    }
    if (lost) {
        printf("FAIL  a range of rings was not counted\n");
        return 1;
    }
    uint64_t more_down = t.more_down, even = t.even, more_up = t.more_up, period2 = t.period2;
    uint32_t *found = t.found;
    printf("%s  all 4294967296 rings: %llu seen moving down, %llu not moving, %llu moving up\n",
           more_down ? "FAIL" : "PASS", (unsigned long long)more_down, (unsigned long long)even,
           (unsigned long long)more_up);
    printf("%s  rings that moved two cells are themselves: %llu —", period2 == 4 ? "PASS" : "FAIL",
           (unsigned long long)period2);
    for (uint64_t i = 0; i < period2 && i < 8; i++) printf(" %08x", found[i]);
    printf("\n");
    return more_down != 0 || period2 != 4;
}
