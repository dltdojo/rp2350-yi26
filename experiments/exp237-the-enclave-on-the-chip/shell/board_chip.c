// SPDX-License-Identifier: Apache-2.0
//
// exp237 — board_chip.c: Pico 2 board layer. Says what enclave.c read back, over
// USB CDC / WebUSB, and on the LED.
//
// send() drops a line whole unless a page holds the port open, so a report
// printed once at boot is gone before anyone opens the page. board_loop therefore
// prints the whole report again and again, with the LED between; a page opened at
// any moment sees one complete report within a few seconds (it starts a new one at
// each ENCLAVE line).
//
// The LED: one flash, 3 s dark, repeated: every check held. 2 s on, then N flashes:
// the Nth check did not hold (1 a kernel op, 2 PMP readback, 3 scrub, 4 read the
// monitor, 5 write the monitor, 6 unknown syscall).

#define SPEAK_NAME "exp237"
#define SPEAK_PRODUCT "exp237 the enclave on the chip"
#define SPEAK_SERIAL "237"

#include "board.h"
#include "speak.h"

// A line, then a short wait with the USB answered so the queue drains before the next.
static void emit(void) {
    send();
    pwait(unit / 8);
}

static void put_hex8(uint32_t v) {
    put("0x");
    for (int i = 4; i >= 0; i -= 4) line[at++] = "0123456789abcdef"[(v >> i) & 15];
}

static void put_hex32(uint32_t v) {
    put("0x");
    for (int i = 28; i >= 0; i -= 4) line[at++] = "0123456789abcdef"[(v >> i) & 15];
}

static void test_line(const char *name, const struct test_result *t, int is_fault) {
    put("TEST ");
    put(name);
    if (is_fault) {
        field("mcause", t->mcause);
        put(" mtval=");
        put_hex32(t->mtval);
    } else {
        put(" exit=");
        put_hex8(t->a0);
    }
    if (is_fault) field("a0", t->a0);
    field("caller_saved_nonzero", t->caller_nonzero);
    field("callee_saved_bad", t->callee_bad);
    put(" monitor_intact=");
    put(t->intact ? "yes" : "no");
    put(" status=");
    put(t->ok ? "OK" : "FAIL");
    emit();
}

void board_report(const struct enclave_report *r) {
    static const char *const names[3] = {"add", "sub", "mul"};

    put("ENCLAVE");
    field("monitor_bytes", r->monitor_bytes);
    field("monitor_words", r->monitor_words);
    put(" pmpcfg0=");
    put_hex8(r->pmpcfg);
    put(" pmpaddr0=");
    put_hex32(r->pmpaddr);
    put(r->pmp_ok ? " pmp=64k_napot" : " pmp=BAD");
    emit();

    for (int i = 0; i < 3; i++) {
        const struct op_result *o = &r->ops[i];
        put("OP ");
        put(names[i]);
        field("a0", o->a0);
        field("minstret", o->instret);
        field("model", o->model);
        field("again", o->again);
        field("cycles", o->cycles);
        put(" status=");
        put(o->ok ? "OK" : "FAIL");
        emit();
    }

    test_line("scrub", &r->scrub, 0);
    test_line("fault_read", &r->faults[0], 1);
    test_line("fault_write", &r->faults[1], 1);
    test_line("fault_badcall", &r->faults[2], 1);

    if (r->fail) {
        put("STATUS FAIL");
        field("first", r->fail);
    } else {
        put("STATUS PASS");
    }
    emit();
}

void board_loop(const struct enclave_report *r) {
    last_instret = r->ops[2].instret;
    for (;;) {
        board_report(r);
        count(r->fail ? r->fail : 1, r->fail != 0);
    }
}
