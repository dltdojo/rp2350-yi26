// SPDX-License-Identifier: Apache-2.0
//
// exp237 — enclave.c: the C shell that loads exp236's idea of a monitor onto a
// Pico 2 and finds out what the silicon does with it.
//
// 1. Copies monitor_chip.bin to SRAM at MONITOR_BASE (clear of the shell's own
//    .bss and stack), and for each run copies a payload to PAYLOAD_BASE.
// 2. Calls the monitor's launch_enclave through probe_launch, which loads s1..s11
//    with known values first and reads every caller-saved register the moment the
//    monitor returns.
// 3. Runs exp229's kernel three times (add, sub, mul), then four payloads that
//    test the monitor: a canary that leaves a secret in every register, one that
//    reads the monitor, one that writes it, one that makes a call it does not serve.
// 4. Reports what it read back (board_chip.c) and loops, re-sending the report,
//    so that a page opened late still sees all of it.
//
// What is checked against what the chip did, not against what was expected: the
// PMP registers as read back at boot, the result words the kernel left, the
// registers after the return, the monitor's bytes after the attacks.

#include <stddef.h>
#include <stdint.h>

#include "board.h"
#include "mem_layout.h"
#include "payload.h"

#define STR2(x) #x
#define STR(x) STR2(x)

// exp229's kernel instruction counts, from its Lean model. The monitor's own
// counting window adds a few (the csrwi that starts the counters, the mret, the
// ecall): the emulator says two. The chip and the RTL may say otherwise, so a run
// passes within FRAMING_MAX, and the capture is where the chip's number is written.
#define EXP229_ADD_INSTRET 331u
#define EXP229_SUB_INSTRET 238u
#define EXP229_MUL_INSTRET 1903u
#define FRAMING_MAX 8u

struct enclave_report report;

void trap(void) __attribute__((naked));
void trap(void) {
    __asm__ volatile ("1: j 1b");
}

// Calls the monitor like a C function, with a fence round it:
//   - s1..s11 hold distinct values going in; the number that did not come back is out[14]
//   - t0..t2, a1..a7, t3..t6 are stored at out[0..13] the moment the monitor returns
// The monitor must leave every one of the first 14 zero, and the last zero.
__attribute__((naked)) static uint32_t probe_launch(uint32_t out[15]) {
    __asm__ volatile (
        ".macro set reg, val\n li \\reg, \\val\n .endm\n"
        ".macro chk reg, val\n li t1, \\val\n xor t1, t1, \\reg\n snez t1, t1\n add t0, t0, t1\n .endm\n"
        "addi sp, sp, -64\n"
        "sw ra, 0(sp)\n sw s0, 4(sp)\n sw s1, 8(sp)\n sw s2, 12(sp)\n sw s3, 16(sp)\n sw s4, 20(sp)\n"
        "sw s5, 24(sp)\n sw s6, 28(sp)\n sw s7, 32(sp)\n sw s8, 36(sp)\n sw s9, 40(sp)\n sw s10, 44(sp)\n"
        "sw s11, 48(sp)\n"
        "mv s0, a0\n"
        "set s1, 0x51510001\n set s2, 0x51510002\n set s3, 0x51510003\n set s4, 0x51510004\n"
        "set s5, 0x51510005\n set s6, 0x51510006\n set s7, 0x51510007\n set s8, 0x51510008\n"
        "set s9, 0x51510009\n set s10, 0x5151000a\n set s11, 0x5151000b\n"
        "li t0, " STR(MONITOR_LAUNCH) "\n"
        "jalr t0\n"
        "sw t0, 0(s0)\n sw t1, 4(s0)\n sw t2, 8(s0)\n"
        "sw a1, 12(s0)\n sw a2, 16(s0)\n sw a3, 20(s0)\n sw a4, 24(s0)\n sw a5, 28(s0)\n sw a6, 32(s0)\n sw a7, 36(s0)\n"
        "sw t3, 40(s0)\n sw t4, 44(s0)\n sw t5, 48(s0)\n sw t6, 52(s0)\n"
        "li t0, 0\n"
        "chk s1, 0x51510001\n chk s2, 0x51510002\n chk s3, 0x51510003\n chk s4, 0x51510004\n"
        "chk s5, 0x51510005\n chk s6, 0x51510006\n chk s7, 0x51510007\n chk s8, 0x51510008\n"
        "chk s9, 0x51510009\n chk s10, 0x5151000a\n chk s11, 0x5151000b\n"
        "sw t0, 56(s0)\n"
        "lw ra, 0(sp)\n lw s0, 4(sp)\n lw s1, 8(sp)\n lw s2, 12(sp)\n lw s3, 16(sp)\n lw s4, 20(sp)\n"
        "lw s5, 24(sp)\n lw s6, 28(sp)\n lw s7, 32(sp)\n lw s8, 36(sp)\n lw s9, 40(sp)\n lw s10, 44(sp)\n"
        "lw s11, 48(sp)\n"
        "addi sp, sp, 64\n"
        "ret\n"
    );
}

static void copy_bytes(volatile void *dst, const void *src, size_t n) {
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static void zero_words(volatile void *dst, size_t words) {
    volatile uint32_t *d = (volatile uint32_t *)dst;
    for (size_t i = 0; i < words; i++) d[i] = 0;
}

static int monitor_intact(void) {
    volatile const uint8_t *m = (volatile const uint8_t *)MONITOR_BASE;
    for (size_t i = 0; i < MONITOR_BIN_LEN; i++)
        if (m[i] != MONITOR_BIN[i]) return 0;
    return 1;
}

struct run {
    uint32_t a0, tag, instret, cycle, mcause, mtval;
    uint32_t regs[15];       // probe_launch's out
    uint32_t pmpcfg, pmpaddr;
};

// Loads `img` into the sandbox (operands for the kernel, if given), launches, reads back.
static void run_payload(const uint8_t *img, size_t len, const uint32_t *operands, struct run *r) {
    zero_words((void *)PAYLOAD_BASE, PAYLOAD_SIZE / 4);
    copy_bytes((void *)PAYLOAD_BASE, img, len);
    volatile uint32_t *p = (volatile uint32_t *)PAYLOAD_BASE;
    if (operands) {
        p[0x900 / 4] = operands[0];
        for (int i = 0; i < 8; i++) p[0x904 / 4 + i] = operands[1 + i];
        for (int i = 0; i < 8; i++) p[0x924 / 4 + i] = operands[9 + i];
    }

    r->a0 = probe_launch(r->regs);

    const volatile struct monitor_report *rep = (const volatile struct monitor_report *)MONITOR_REPORT;
    r->tag = rep->tag;
    r->instret = rep->instret;
    r->cycle = rep->cycle;
    r->mcause = rep->mcause;
    r->mtval = rep->mtval;
    const volatile uint32_t *boot = (const volatile uint32_t *)MONITOR_BOOT;
    r->pmpcfg = boot[0];
    r->pmpaddr = boot[1];
}

static uint32_t nonzero(const struct run *r) {
    uint32_t n = 0;
    for (int i = 0; i < 14; i++) n += r->regs[i] != 0;
    return n;
}

static uint32_t kernel_result_matches(const uint32_t expected[8]) {
    const volatile uint32_t *p = (const volatile uint32_t *)PAYLOAD_BASE;
    for (int i = 0; i < 8; i++)
        if (p[0x944 / 4 + i] != expected[i]) return 0;
    return 1;
}

static void run_kernel_op(int idx, const uint32_t operands[17], const uint32_t expected[8], uint32_t model) {
    struct op_result *o = &report.ops[idx];
    struct run r, again;
    run_payload(KERNEL_BIN, KERNEL_BIN_LEN, operands, &r);
    uint32_t good = kernel_result_matches(expected);     // read before the second run overwrites it
    run_payload(KERNEL_BIN, KERNEL_BIN_LEN, operands, &again);

    o->a0 = r.a0;
    o->instret = r.instret;
    o->model = model;
    o->cycles = r.cycle;
    o->again = again.instret;
    o->ok = r.a0 == 0 && r.tag == TAG_HALT && good
         && r.instret >= model && r.instret - model <= FRAMING_MAX
         && again.instret == r.instret
         && nonzero(&r) == 0 && r.regs[14] == 0;
    if (!report.pmp_ok && idx == 0) {
        report.pmpcfg = r.pmpcfg;
        report.pmpaddr = r.pmpaddr;
        report.pmp_ok = r.pmpcfg == DOMAIN_PMPCFG0 && r.pmpaddr == DOMAIN_PMPADDR0;
    }
}

static void run_attack(struct test_result *t, const uint8_t *img, size_t len, uint32_t want_cause) {
    struct run r;
    run_payload(img, len, 0, &r);
    t->a0 = r.a0;
    t->mcause = r.mcause;
    t->mtval = r.mtval;
    t->tag_ok = r.tag == TAG_FAULT;
    t->caller_nonzero = nonzero(&r);
    t->callee_bad = r.regs[14];
    t->intact = (uint32_t)monitor_intact();
    // mtval is reported but not required: whether the core fills it for an access fault is the core's.
    t->ok = r.a0 == 1 && t->tag_ok && r.mcause == want_cause && t->intact
         && t->caller_nonzero == 0 && t->callee_bad == 0;
}

static void run_scrub(struct test_result *t) {
    struct run r;
    run_payload(CANARY_BIN, CANARY_BIN_LEN, 0, &r);
    t->a0 = r.a0;
    t->mcause = r.mcause;
    t->mtval = r.mtval;
    t->tag_ok = r.tag == TAG_HALT;
    t->caller_nonzero = nonzero(&r);
    t->callee_bad = r.regs[14];
    t->intact = (uint32_t)monitor_intact();
    t->ok = r.a0 == 0x5a && t->tag_ok && t->caller_nonzero == 0 && t->callee_bad == 0;
}

void shell_main(void) {
    board_init();

    zero_words((void *)MONITOR_BASE, MONITOR_SIZE / 4);
    copy_bytes((void *)MONITOR_BASE, MONITOR_BIN, MONITOR_BIN_LEN);
    report.monitor_bytes = MONITOR_BIN_LEN;
    report.monitor_words = MONITOR_WORDS;

    // 42 + 58, 100 - 42, and a product that wraps past 2^256's fold (checked against Python).
    static const uint32_t add_in[17] = {0, 42, 0, 0, 0, 0, 0, 0, 0, 58, 0, 0, 0, 0, 0, 0, 0};
    static const uint32_t sub_in[17] = {1, 100, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0};
    static const uint32_t mul_in[17] = {2, 0x12345678, 0, 0, 0, 0, 0, 0, 0, 0x87654321, 0, 0, 0, 0, 0, 0, 0};
    static const uint32_t add_r[8] = {100, 0, 0, 0, 0, 0, 0, 0};
    static const uint32_t sub_r[8] = {58, 0, 0, 0, 0, 0, 0, 0};
    static const uint32_t mul_r[8] = {0x70b88d78, 0x09a0cd05, 0, 0, 0, 0, 0, 0};
    run_kernel_op(0, add_in, add_r, EXP229_ADD_INSTRET);
    run_kernel_op(1, sub_in, sub_r, EXP229_SUB_INSTRET);
    run_kernel_op(2, mul_in, mul_r, EXP229_MUL_INSTRET);

    run_scrub(&report.scrub);
    run_attack(&report.faults[0], READ_BIN, READ_BIN_LEN, 5);
    run_attack(&report.faults[1], WRITE_BIN, WRITE_BIN_LEN, 7);
    run_attack(&report.faults[2], BADCALL_BIN, BADCALL_BIN_LEN, 8);

    // The first thing that did not hold, numbered for the LED: 1 a kernel op, 2 the PMP
    // readback, 3 the scrub, 4..6 the three attacks.
    report.fail = 0;
    if (!report.ops[0].ok || !report.ops[1].ok || !report.ops[2].ok) report.fail = 1;
    else if (!report.pmp_ok) report.fail = 2;
    else if (!report.scrub.ok) report.fail = 3;
    else if (!report.faults[0].ok) report.fail = 4;
    else if (!report.faults[1].ok) report.fail = 5;
    else if (!report.faults[2].ok) report.fail = 6;

    board_loop(&report);
}
