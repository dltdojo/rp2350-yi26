# The E6 core's hazard3_config.vh, with its three PMP defaults written as the pinned commit writes them: a zero-width
# replication when PMP_REGIONS is 0 is an error to Verilator 5.020. Only the defaults change; every value the RP2350's
# configuration passes in is the same.
s/^parameter PMP_HARDWIRED       = PMP_REGIONS > 0 ? {PMP_REGIONS{1'b0}} : 1'b0,$/parameter PMP_HARDWIRED       = {(PMP_REGIONS > 0 ? PMP_REGIONS : 1){1'b0}},/
s/^parameter PMP_HARDWIRED_ADDR  = PMP_REGIONS > 0 ? {PMP_REGIONS{32'h0}} : 1'b0,$/parameter PMP_HARDWIRED_ADDR  = {(PMP_REGIONS > 0 ? PMP_REGIONS : 1){32'h0}},/
s/^parameter PMP_HARDWIRED_CFG   = PMP_REGIONS > 0 ? {PMP_REGIONS{8'h00}} : 1'b0,$/parameter PMP_HARDWIRED_CFG   = {(PMP_REGIONS > 0 ? PMP_REGIONS : 1){8'h00}},/
