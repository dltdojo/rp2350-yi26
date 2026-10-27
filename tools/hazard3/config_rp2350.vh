// SPDX-License-Identifier: Apache-2.0
//
// Hazard3 as the RP2350 configures it, for the Verilator testbench: the values of the RP2350 datasheet's
// Table 387 (section 3.8.8, "Configuration") and its hardwired PMP regions (section 3.8.8.1), at the commit
// setup.sh pins. setup.sh copies this into the testbench as config_rp2350.vh and builds `tb-rp2350`.
//
// Three kinds of line, and which is which:
//   * the datasheet's: every parameter Table 387 names, with its value -- the PMP's eleven regions, three of them
//     hardwired; its 32-byte grain; the extensions;
//   * the testbench's: where the core starts and where its trap vector starts (the testbench's memory is at
//     0x80000000, the chip's is not), and the interrupt wiring (the testbench drives 32 lines; nothing here takes
//     an interrupt);
//   * not in the table, because the RP2350's Hazard3 predates them: RV32E and the extensions added since
//     (Zbkx, Zclsd, Zilsd) are off, and TOR matching is off -- the datasheet says the RP2350 supports OFF and
//     NAPOT only.
//
// What this cannot be is the chip's RTL. The RP2350's Hazard3 is older than the pinned commit: erratum RP2350-E6
// (PMPCFG's R and X transposed) was fixed upstream in commit 7d37029, so this core reads the standard bit order.

// the testbench's
localparam RESET_VECTOR        = 32'h80000040;
localparam MTVEC_INIT          = 32'h80000000;

// the datasheet's: Table 387
localparam EXTENSION_A         = 1;
localparam EXTENSION_C         = 1;
localparam EXTENSION_M         = 1;
localparam EXTENSION_ZBA       = 1;
localparam EXTENSION_ZBB       = 1;
localparam EXTENSION_ZBC       = 0;
localparam EXTENSION_ZBKB      = 1;
localparam EXTENSION_ZBS       = 1;
localparam EXTENSION_ZCB       = 1;
localparam EXTENSION_ZCMP      = 1;
localparam EXTENSION_ZIFENCEI  = 1;
localparam EXTENSION_XH3BEXTM  = 1;
localparam EXTENSION_XH3IRQ    = 1;
localparam EXTENSION_XH3PMPM   = 1;
localparam EXTENSION_XH3POWER  = 1;
localparam CSR_M_MANDATORY     = 1;
localparam CSR_M_TRAP          = 1;
localparam CSR_COUNTER         = 1;
localparam U_MODE              = 1;
localparam PMP_REGIONS         = 11;
localparam PMP_GRAIN           = 3;
localparam PMP_HARDWIRED       = 11'h700;
// regions 8, 9, 10: ROM 0x00000000-0x0fffffff, peripherals 0x40000000-0x5fffffff, SIO 0xd0000000-0xdfffffff,
// NAPOT, U-mode RWX, not locked (PMPADDR8..10 and PMPCFG2's reset values)
localparam PMP_HARDWIRED_ADDR  = {32'h35ffffff, 32'h13ffffff, 32'h01ffffff, {8{32'h0}}};
localparam PMP_HARDWIRED_CFG   = {8'h1f, 8'h1f, 8'h1f, {8{8'h00}}};
localparam DEBUG_SUPPORT       = 1;
localparam BREAKPOINT_TRIGGERS = 4;
localparam IRQ_PRIORITY_BITS   = 4;
localparam MVENDORID_VAL       = 32'h00000493;
localparam MCONFIGPTR_VAL      = 32'h0;
localparam REDUCED_BYPASS      = 0;
localparam MULDIV_UNROLL       = 2;
localparam MUL_FAST            = 1;
localparam MUL_FASTER          = 1;
localparam MULH_FAST           = 1;
localparam FAST_BRANCHCMP      = 1;
localparam RESET_REGFILE       = 1;
localparam BRANCH_PREDICTOR    = 1;
localparam MTVEC_WMASK         = 32'hfffffffd;

// the testbench's interrupt wiring
localparam NUM_IRQS            = 32;
localparam IRQ_INPUT_BYPASS    = {NUM_IRQS{1'b0}};

// not in Table 387: off on the RP2350
localparam EXTENSION_E         = 0;
localparam EXTENSION_ZBKX      = 0;
localparam EXTENSION_ZCLSD     = 0;
localparam EXTENSION_ZILSD     = 0;
localparam PMP_MATCH_NAPOT     = 1;
localparam PMP_MATCH_TOR       = 0;
