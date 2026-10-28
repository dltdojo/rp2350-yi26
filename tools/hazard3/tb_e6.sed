# The pinned testbench's tb.v, for the core of the commit before the E6 fix, which does not have these five ports
# yet: the fence handshake, and the hart ID and ECO version inputs (its hart ID is the MHARTID_VAL parameter).
/^\t\.fence_i_vld  *(fence_i_vld),$/d
/^\t\.fence_d_vld  *(fence_d_vld),$/d
/^\t\.fence_rdy  *(fence_rdy),$/d
/^\t\.mhartid_val  *(32'd0),$/d
/^\t\.eco_version  *(4'ha),$/d
