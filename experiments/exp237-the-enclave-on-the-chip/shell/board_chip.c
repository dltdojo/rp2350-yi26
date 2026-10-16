// SPDX-License-Identifier: Apache-2.0
//
// exp237 — board_chip.c: Pico 2 board layer reporting over USB CDC/WebUSB and LED.

#define SPEAK_NAME "exp237"
#define SPEAK_PRODUCT "exp237 the enclave on the chip"
#define SPEAK_SERIAL "237"

#include "board.h"
#include "speak.h"

void board_report_boot(void) {
    put("ENCLAVE boot=ok monitor=147_insts pmp=64k_napot");
    send();
}

void board_report_op(const struct enclave_result *res) {
    const char *op_str = (res->op == 0) ? "add" : (res->op == 1) ? "sub" : "mul";
    put("OP ");
    put(op_str);
    put(" a0=");
    put_dec(res->a0);
    put(" minstret=");
    put_dec(res->instret);
    put(" cycles=");
    put_dec(res->cycles);
    put(" status=");
    put(res->ok ? "OK" : "FAIL");
    send();
}

void board_report_summary(uint32_t pass) {
    if (pass) {
        put("STATUS PASS secrets_scrubbed=ok");
        send();
        flash(1, 0); // 1 flash: success
    } else {
        put("STATUS FAIL");
        send();
        flash(2, 1); // error flashes
    }
}

void board_loop(void) {
    for (;;) {
        pwait(unit);
        board_report_boot();
        pwait(unit);
    }
}
