// SPDX-License-Identifier: Apache-2.0
//
// Hazard3 as the RP2350 configures it, for the core the RP2350 was built from: the commit before upstream fixed
// erratum RP2350-E6 (fce1c08, 2024-04-27, the parent of 7d37029), whose parameters are Table 387's, one for one.
// setup.sh builds it as `tb_e6-rp2350`, with the testbench of the commit it pins, less the five ports this core
// does not have yet (tb_e6.v). Its PMP reads PMPCFG's R from bit 2 and X from bit 0, as the chip's does.
//
// Every parameter here is the datasheet's Table 387 (section 3.8.8) and its hardwired regions (3.8.8.1), but for
// the testbench's: where the core starts and its trap vector (the testbench's RAM is at 0x80000000), and the
// interrupt wiring (the testbench drives 32 lines; nothing here takes an interrupt).

// the testbench's
localparam RESET_VECTOR        = 32'h80000040;
localparam MTVEC_INIT          = 32'h80000000;
localparam NUM_IRQS            = 32;
localparam IRQ_INPUT_BYPASS    = {NUM_IRQS{1'b0}};

// the datasheet's: Table 387
localparam EXTENSION_A         = 1;
localparam EXTENSION_C         = 1;
localparam EXTENSION_M         = 1;
localparam EXTENSION_ZBA       = 1;
localparam EXTENSION_ZBB       = 1;
localparam EXTENSION_ZBC       = 0;
localparam EXTENSION_ZBS       = 1;
localparam EXTENSION_ZBKB      = 1;
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
// regions 8, 9, 10: ROM, peripherals, SIO; NAPOT, U-mode RWX, not locked
localparam PMP_HARDWIRED_ADDR  = {32'h35ffffff, 32'h13ffffff, 32'h01ffffff, {8{32'h0}}};
localparam PMP_HARDWIRED_CFG   = {8'h1f, 8'h1f, 8'h1f, {8{8'h00}}};
localparam DEBUG_SUPPORT       = 1;
localparam BREAKPOINT_TRIGGERS = 4;
localparam IRQ_PRIORITY_BITS   = 4;
localparam MVENDORID_VAL       = 32'h00000493;
localparam MIMPID_VAL          = 32'h86fc4e3f;
localparam MHARTID_VAL         = 32'h00000000;
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
