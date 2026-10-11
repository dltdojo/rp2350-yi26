// SPDX-License-Identifier: Apache-2.0
//
// exp228 — BIP340 Schnorr verification, freestanding: no C library, no
// initialised data, 32-bit words only, so the same file builds for the
// Hazard3 shell (rv32im) and for the host test that holds it to BIP340's own
// test vectors (bip340/test-vectors.csv, check.sh).
//
// Verification only. Everything it handles is public — a key, a message, a
// signature — so nothing here tries to be constant-time.
//
// The algorithm is BIP340's Verify, step for step:
//
//   P = lift_x(pk)                        fail if pk ≥ p or no such point
//   r = sig[0:32], s = sig[32:64]         fail if r ≥ p or s ≥ n
//   e = H_challenge(r || pk || msg) mod n
//   R = s·G − e·P                         fail if R is infinity, R.y odd,
//                                         or R.x ≠ r
//
// Numbers are eight 32-bit words, least significant first. Field elements are
// kept reduced below p = 2^256 − 2^32 − 977. Points are Jacobian.

#include "bip340.h"
#include "sha256.h"

typedef struct { uint32_t w[8]; } u256;
typedef struct { u256 x, y, z; int inf; } jac;

static const u256 P_ = {{0xFFFFFC2Fu, 0xFFFFFFFEu, 0xFFFFFFFFu, 0xFFFFFFFFu,
                         0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu}};
static const u256 N_ = {{0xD0364141u, 0xBFD25E8Cu, 0xAF48A03Bu, 0xBAAEDCE6u,
                         0xFFFFFFFEu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu}};
static const u256 GX = {{0x16F81798u, 0x59F2815Bu, 0x2DCE28D9u, 0x029BFCDBu,
                         0xCE870B07u, 0x55A06295u, 0xF9DCBBACu, 0x79BE667Eu}};
static const u256 GY = {{0xFB10D4B8u, 0x9C47D08Fu, 0xA6855419u, 0xFD17B448u,
                         0x0E1108A8u, 0x5DA4FBFCu, 0x26A3C465u, 0x483ADA77u}};

// ---------- 256-bit words --------------------------------------------------------

static void from_be(u256 *a, const uint8_t *b) {
    for (int i = 0; i < 8; i++)
        a->w[i] = (uint32_t)b[31 - 4 * i] | (uint32_t)b[30 - 4 * i] << 8 | (uint32_t)b[29 - 4 * i] << 16 |
                  (uint32_t)b[28 - 4 * i] << 24;
}

static int cmp(const u256 *a, const u256 *b) {
    for (int i = 7; i >= 0; i--) {
        if (a->w[i] < b->w[i]) return -1;
        if (a->w[i] > b->w[i]) return 1;
    }
    return 0;
}

static int is_zero(const u256 *a) {
    uint32_t o = 0;
    for (int i = 0; i < 8; i++) o |= a->w[i];
    return o == 0;
}

static uint32_t add_raw(u256 *r, const u256 *a, const u256 *b) {
    uint64_t c = 0;
    for (int i = 0; i < 8; i++) {
        c += (uint64_t)a->w[i] + b->w[i];
        r->w[i] = (uint32_t)c;
        c >>= 32;
    }
    return (uint32_t)c;
}

static uint32_t sub_raw(u256 *r, const u256 *a, const u256 *b) {
    int64_t c = 0;
    for (int i = 0; i < 8; i++) {
        c += (int64_t)a->w[i] - b->w[i];
        r->w[i] = (uint32_t)c;
        c >>= 32;
    }
    return (uint32_t)(c & 1);   // 1 when it borrowed
}

static int bit(const u256 *a, int i) { return (a->w[i / 32] >> (i % 32)) & 1; }

// ---------- the field, mod p --------------------------------------------------------

static void fe_add(u256 *r, const u256 *a, const u256 *b) {
    uint32_t c = add_raw(r, a, b);
    if (c || cmp(r, &P_) >= 0) sub_raw(r, r, &P_);
}

static void fe_sub(u256 *r, const u256 *a, const u256 *b) {
    if (sub_raw(r, a, b)) add_raw(r, r, &P_);
}

// 2^256 ≡ 2^32 + 977 (mod p): fold the high half down, then what is left of it.
static void fe_mul(u256 *r, const u256 *a, const u256 *b) {
    uint32_t t[16] = {0};
    for (int i = 0; i < 8; i++) {
        uint64_t c = 0;
        for (int j = 0; j < 8; j++) {
            c += (uint64_t)a->w[i] * b->w[j] + t[i + j];
            t[i + j] = (uint32_t)c;
            c >>= 32;
        }
        t[i + 8] = (uint32_t)c;
    }
    // u = lo + hi·977 + hi·2^32, ten words
    uint32_t u[10];
    uint64_t c = 0;
    for (int i = 0; i < 10; i++) {
        if (i < 8) c += (uint64_t)t[i] + (uint64_t)t[8 + i] * 977u;
        if (i >= 1 && i <= 8) c += t[8 + i - 1];
        u[i] = (uint32_t)c;
        c >>= 32;
    }
    // h = u[8..9], small: u = u_lo + h·2^256 ≡ u_lo + h·977 + h·2^32
    uint64_t h = (uint64_t)u[8] | (uint64_t)u[9] << 32;
    uint64_t hl = h * 977u;
    c = 0;
    for (int i = 0; i < 8; i++) {
        c += u[i];
        if (i == 0) c += hl & 0xFFFFFFFFu;
        if (i == 1) c += (hl >> 32) + (h & 0xFFFFFFFFu);
        if (i == 2) c += h >> 32;
        r->w[i] = (uint32_t)c;
        c >>= 32;
    }
    if (c) {   // one more 2^256, at most: r < 2^33 then, so this cannot carry again
        uint64_t d = (uint64_t)r->w[0] + 977u;
        r->w[0] = (uint32_t)d;
        d = (d >> 32) + r->w[1] + 1u;
        r->w[1] = (uint32_t)d;
        d >>= 32;
        for (int i = 2; i < 8 && d; i++) {
            d += r->w[i];
            r->w[i] = (uint32_t)d;
            d >>= 32;
        }
    }
    if (cmp(r, &P_) >= 0) sub_raw(r, r, &P_);
}

static void fe_pow(u256 *r, const u256 *a, const u256 *e) {
    u256 x = *a, acc = {{1}};
    for (int i = 255; i >= 0; i--) {
        fe_mul(&acc, &acc, &acc);
        if (bit(e, i)) fe_mul(&acc, &acc, &x);
    }
    *r = acc;
}

static void fe_inv(u256 *r, const u256 *a) {
    u256 e = P_;
    e.w[0] -= 2;   // p − 2
    fe_pow(r, a, &e);
}

// ---------- points --------------------------------------------------------------

static void dbl(jac *r, const jac *p) {
    if (p->inf || is_zero(&p->y)) { r->inf = 1; return; }
    u256 a, b, c, d, e, f, t;
    fe_mul(&a, &p->x, &p->x);          // X²
    fe_mul(&b, &p->y, &p->y);          // Y²
    fe_mul(&c, &b, &b);                // Y⁴
    fe_add(&t, &p->x, &b);
    fe_mul(&t, &t, &t);
    fe_sub(&t, &t, &a);
    fe_sub(&t, &t, &c);
    fe_add(&d, &t, &t);                // D = 2((X+Y²)² − X² − Y⁴)
    fe_add(&e, &a, &a);
    fe_add(&e, &e, &a);                // E = 3X²
    fe_mul(&f, &e, &e);                // F = E²
    u256 x3, y3, z3;
    fe_sub(&x3, &f, &d);
    fe_sub(&x3, &x3, &d);              // X3 = F − 2D
    fe_sub(&t, &d, &x3);
    fe_mul(&y3, &e, &t);
    fe_add(&t, &c, &c);
    fe_add(&t, &t, &t);
    fe_add(&t, &t, &t);                // 8Y⁴
    fe_sub(&y3, &y3, &t);              // Y3 = E(D − X3) − 8Y⁴
    fe_mul(&z3, &p->y, &p->z);
    fe_add(&z3, &z3, &z3);             // Z3 = 2YZ
    r->x = x3; r->y = y3; r->z = z3; r->inf = 0;
}

static void add(jac *r, const jac *p, const jac *q) {
    if (p->inf) { *r = *q; return; }
    if (q->inf) { *r = *p; return; }
    u256 z1z1, z2z2, u1, u2, s1, s2, t;
    fe_mul(&z1z1, &p->z, &p->z);
    fe_mul(&z2z2, &q->z, &q->z);
    fe_mul(&u1, &p->x, &z2z2);
    fe_mul(&u2, &q->x, &z1z1);
    fe_mul(&t, &q->z, &z2z2);
    fe_mul(&s1, &p->y, &t);
    fe_mul(&t, &p->z, &z1z1);
    fe_mul(&s2, &q->y, &t);
    if (cmp(&u1, &u2) == 0) {
        if (cmp(&s1, &s2) == 0) { dbl(r, p); return; }
        r->inf = 1;
        return;
    }
    u256 h, hh, hhh, rr, v, x3, y3, z3;
    fe_sub(&h, &u2, &u1);
    fe_sub(&rr, &s2, &s1);
    fe_mul(&hh, &h, &h);
    fe_mul(&hhh, &hh, &h);
    fe_mul(&v, &u1, &hh);
    fe_mul(&x3, &rr, &rr);
    fe_sub(&x3, &x3, &hhh);
    fe_sub(&x3, &x3, &v);
    fe_sub(&x3, &x3, &v);              // X3 = R² − H³ − 2V
    fe_sub(&t, &v, &x3);
    fe_mul(&y3, &rr, &t);
    fe_mul(&t, &s1, &hhh);
    fe_sub(&y3, &y3, &t);              // Y3 = R(V − X3) − S1·H³
    fe_mul(&z3, &p->z, &q->z);
    fe_mul(&z3, &z3, &h);              // Z3 = Z1·Z2·H
    r->x = x3; r->y = y3; r->z = z3; r->inf = 0;
}

// ---------- BIP340 ---------------------------------------------------------------

static uint8_t buf[64 + 32 + 32 + 256];

static void tagged(const char *tag, uint32_t tag_len, const uint8_t *data, uint32_t len, uint8_t out[32]) {
    uint8_t th[32];
    sha256((const uint8_t *)tag, tag_len, th);
    for (int i = 0; i < 32; i++) buf[i] = buf[32 + i] = th[i];
    for (uint32_t i = 0; i < len; i++) buf[64 + i] = data[i];
    sha256(buf, 64 + len, out);
}

int bip340_verify(const uint8_t pk[32], const uint8_t *msg, uint32_t msg_len, const uint8_t sig[64]) {
    if (msg_len > 256) return 0;
    u256 px, r, s, e;
    from_be(&px, pk);
    from_be(&r, sig);
    from_be(&s, sig + 32);
    if (cmp(&px, &P_) >= 0 || cmp(&r, &P_) >= 0 || cmp(&s, &N_) >= 0) return 0;

    // lift_x: y² = x³ + 7, y = c^((p+1)/4), the even one
    u256 c, y, t, seven = {{7}};
    fe_mul(&c, &px, &px);
    fe_mul(&c, &c, &px);
    fe_add(&c, &c, &seven);
    u256 ex = P_;
    add_raw(&ex, &ex, &(u256){{1}});   // p + 1 (no carry out: p + 1 < 2^256)
    for (int i = 0; i < 8; i++) ex.w[i] = (ex.w[i] >> 2) | (i < 7 ? ex.w[i + 1] << 30 : 0);
    fe_pow(&y, &c, &ex);
    fe_mul(&t, &y, &y);
    if (cmp(&t, &c) != 0) return 0;
    if (y.w[0] & 1) sub_raw(&y, &P_, &y);

    // e = H_challenge(r || pk || msg) mod n
    uint8_t data[64 + 256], h[32];
    for (int i = 0; i < 32; i++) { data[i] = sig[i]; data[32 + i] = pk[i]; }
    for (uint32_t i = 0; i < msg_len; i++) data[64 + i] = msg[i];
    tagged("BIP0340/challenge", 17, data, 64 + msg_len, h);
    from_be(&e, h);
    if (cmp(&e, &N_) >= 0) sub_raw(&e, &e, &N_);
    u256 ne = {{0}};
    if (!is_zero(&e)) sub_raw(&ne, &N_, &e);   // n − e

    // R = s·G + (n − e)·P, both at once
    jac G = {GX, GY, {{1}}, 0}, Pj = {px, y, {{1}}, 0}, R = {{{0}}, {{0}}, {{0}}, 1};
    jac GP;
    add(&GP, &G, &Pj);
    for (int i = 255; i >= 0; i--) {
        dbl(&R, &R);
        int bs = bit(&s, i), be = bit(&ne, i);
        if (bs && be) add(&R, &R, &GP);
        else if (bs) add(&R, &R, &G);
        else if (be) add(&R, &R, &Pj);
    }
    if (R.inf) return 0;
    u256 zi, zi2, zi3, rx, ry;
    fe_inv(&zi, &R.z);
    fe_mul(&zi2, &zi, &zi);
    fe_mul(&zi3, &zi2, &zi);
    fe_mul(&rx, &R.x, &zi2);
    fe_mul(&ry, &R.y, &zi3);
    if (ry.w[0] & 1) return 0;
    return cmp(&rx, &r) == 0;
}
