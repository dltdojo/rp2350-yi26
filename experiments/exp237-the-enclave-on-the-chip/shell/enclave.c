// SPDX-License-Identifier: Apache-2.0
//
// exp237 — enclave.c: Pure C hardware enclave controller on Pico 2 (RP2350).
//
// Replaces the unverified C/asm test harness with the formally proved
// Micro-Monitor (monitor_chip.bin).
//
// 1. Copies monitor_chip.bin to SRAM Domain 0 (0x20000000).
// 2. Loads exp229 secp256k1 arithmetic kernel into Domain 1 (0x20010000).
// 3. Launches the monitor, which enforces 64 KiB NAPOT PMP sandbox, enters U-mode,
//    executes field operations, intercepts HALT ecall, and scrubs all secret registers.
// 4. Reads report block and verifies exact minstret counts (331, 238, 1903).
// 5. Streams verification log over USB CDC / WebUSB and blinks LED.

#include <stdint.h>
#include <stddef.h>

#include "board.h"
#include "mem_layout.h"
#include "payload.h"

void trap(void) __attribute__((naked));
void trap(void) {
    __asm__ volatile ("1: j 1b");
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

static int run_enclave_op(uint32_t op, const uint32_t a[8], const uint32_t b[8],
                          const uint32_t expected_r[8], uint32_t expected_instret) {
    // 1. Zero the 64 KiB payload region
    zero_words((void *)PAYLOAD_BASE, PAYLOAD_SIZE / 4);

    // 2. Copy exp229 kernel into payload base
    copy_bytes((void *)PAYLOAD_BASE, KERNEL_BIN, KERNEL_BIN_LEN);

    // 3. Set up inputs at payload offsets
    volatile uint32_t *p = (volatile uint32_t *)PAYLOAD_BASE;
    p[0x900 / 4] = op;
    for (int i = 0; i < 8; i++) p[0x904 / 4 + i] = a[i];
    for (int i = 0; i < 8; i++) p[0x924 / 4 + i] = b[i];

    // 4. Launch enclave via verified monitor entry at 0x20000020
    typedef uint32_t (*launcher_t)(void);
    launcher_t launch = (launcher_t)(MONITOR_BASE + 0x20);
    uint32_t ret = launch();

    // 5. Inspect monitor report mailbox at 0x20000400
    const struct monitor_report *rep = (const struct monitor_report *)MONITOR_REPORT;

    struct enclave_result res;
    res.op = op;
    res.a0 = ret;
    res.instret = rep->instret;
    res.cycles = rep->cycle;

    int r_ok = 1;
    for (int i = 0; i < 8; i++) {
        res.r[i] = p[0x944 / 4 + i];
        if (res.r[i] != expected_r[i]) r_ok = 0;
    }

    res.ok = (ret == 0) && (rep->tag == TAG_HALT) && (rep->instret == expected_instret) && r_ok;
    board_report_op(&res);
    return res.ok;
}

void shell_main(void) {
    board_init();
    board_report_boot();

    // Copy verified monitor binary into SRAM Domain 0
    zero_words((void *)MONITOR_BASE, MONITOR_SIZE / 4);
    copy_bytes((void *)MONITOR_BASE, MONITOR_BIN, MONITOR_BIN_LEN);

    int all_ok = 1;

    // Case 1: Addition (42 + 58 = 100 mod p)
    uint32_t a1[8] = {42, 0, 0, 0, 0, 0, 0, 0};
    uint32_t b1[8] = {58, 0, 0, 0, 0, 0, 0, 0};
    uint32_t r1[8] = {100, 0, 0, 0, 0, 0, 0, 0};
    if (!run_enclave_op(0, a1, b1, r1, EXP229_ADD_INSTRET)) all_ok = 0;

    // Case 2: Subtraction (100 - 42 = 58 mod p)
    uint32_t a2[8] = {100, 0, 0, 0, 0, 0, 0, 0};
    uint32_t b2[8] = {42, 0, 0, 0, 0, 0, 0, 0};
    uint32_t r2[8] = {58, 0, 0, 0, 0, 0, 0, 0};
    if (!run_enclave_op(1, a2, b2, r2, EXP229_SUB_INSTRET)) all_ok = 0;

    // Case 3: Multiplication (0x12345678 * 0x87654321 mod p)
    uint32_t a3[8] = {0x12345678, 0, 0, 0, 0, 0, 0, 0};
    uint32_t b3[8] = {0x87654321, 0, 0, 0, 0, 0, 0, 0};
    uint32_t r3[8] = {0x6beaa588, 0x009a835a, 0, 0, 0, 0, 0, 0};
    if (!run_enclave_op(2, a3, b3, r3, EXP229_MUL_INSTRET)) all_ok = 0;

    board_report_summary(all_ok);
    board_loop();
}

