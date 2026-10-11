// SPDX-License-Identifier: Apache-2.0
//
// exp228 — bip340.c on this machine, held to a CSV in BIP340's test-vector
// format (index,secret key,public key,aux_rand,message,signature,verification
// result,comment): every line's result must be the CSV's.
//
//   bip340_test FILE.csv [LABEL]   PASS/FAIL; exit 0 = every line agrees
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "bip340.h"
static int unhex(const char *s, unsigned char *out) {
    int n = 0;
    while (s[0] && s[1] && s[0] != ',') { unsigned v; sscanf(s, "%2x", &v); out[n++] = v; s += 2; }
    return n;
}
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "r");
    char line[4096];
    int pass = 0, fail = 0;
    if (!fgets(line, sizeof line, f)) return 1;
    while (fgets(line, sizeof line, f)) {
        char *fld[8]; int k = 0; char *p = line;
        fld[k++] = p;
        while (*p && k < 8) { if (*p == ',') { *p = 0; fld[k++] = p + 1; } p++; }
        unsigned char pk[64], msg[512], sig[128];
        int pkn = unhex(fld[2], pk), mn = unhex(fld[4], msg), sn = unhex(fld[5], sig);
        int want = strncmp(fld[6], "TRUE", 4) == 0;
        int got = (pkn == 32 && sn == 64) ? bip340_verify(pk, msg, mn, sig) : 0;
        if (got == want) pass++; else { fail++; printf("FAIL vector %s: want %d got %d\n", fld[0], want, got); }
    }
    printf("%s  bip340.c gives %d of %d %s the result the CSV says\n", fail ? "FAIL" : "PASS", pass, pass + fail,
           argc > 2 ? argv[2] : "lines");
    return fail != 0;
}
