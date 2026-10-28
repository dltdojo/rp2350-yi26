#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3 setup — fetch the Hazard3 RTL and build its Verilator
# testbench, once.
#
# Hazard3 is the RISC-V core in the RP2350, and its repository carries a
# cycle-accurate simulation of it. That makes it the third thing a kernel can
# run on — after the Lean model and before the chip — and the only one of the
# three that is not either our own model or a board somebody has to plug in.
#
# Pinned by commit, with the two submodules this needs pinned by the commits
# that commit names: `scripts` (the file-list tool the Makefile calls) and
# `riscv-tests` (the self-checking ISA suite exp202 runs). The third,
# `riscv-arch-test`, is not fetched: its tests need reference signatures made
# by a Sail model, which is a much larger thing to trust and to install.
#
# Needs `git`, `verilator` (Ubuntu's 5.020 is what this was verified with),
# `clang++` and `make`. Ubuntu's verilator with g++ trips over a precompiled
# header (verilator issue 4730) and writes a multi-gigabyte log while doing
# it, so the model is compiled with clang++, and linked with -latomic, which
# Ubuntu's clang needs for verilated code and does not add by itself.
#
#   ./setup.sh          fetch and build, or say what is already there

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

HAZARD3_COMMIT="8af992930f71a69b0e06c38734c1094f41a05ca0"
SCRIPTS_COMMIT="1e768865928782ec6b0c34e7a30c06857a02155c"
RISCV_TESTS_COMMIT="49a24d7f41e7b422cebeffdc3ba31c8daaf5aa5c"
TB=Hazard3/test/sim/tb_verilator/tb
TB_RP2350=Hazard3/test/sim/tb_verilator/tb-rp2350
TB_E6=Hazard3/test/sim/tb_verilator/tb_e6-rp2350
STAMP=Hazard3/.built
# The core the RP2350 was built from: the commit before upstream fixed erratum RP2350-E6 (7d37029's parent).
E6_COMMIT="fce1c087d49d9e3841689fae6aa8bffe64b9dc9e"
# Three testbenches: `tb`, Hazard3's own default configuration, which exp202 and every kernel since ran on;
# `tb-rp2350`, the configuration the RP2350 datasheet gives (config_rp2350.vh), which the monitors are held to; and
# `tb_e6-rp2350`, the same configuration on the core before the E6 fix (config_rp2350_e6.vh), with PMPCFG's R and
# X where the chip has them.
WANT="$HAZARD3_COMMIT $(cat config_rp2350.vh config_rp2350_e6.vh tb_e6.sed hdl_e6.sed | sha256sum | cut -c1-16)"

if [[ -x "$TB" && -x "$TB_RP2350" && -x "$TB_E6" && "$(cat "$STAMP" 2>/dev/null)" == "$WANT" ]]; then
    echo "already have the Hazard3 testbenches at $HAZARD3_COMMIT"
    exit 0
fi

for tool in git verilator clang++ make; do
    command -v "$tool" > /dev/null || { echo "needs $tool (Ubuntu: apt install $tool)" >&2; exit 1; }
done

if [[ ! -d Hazard3/.git ]]; then
    git init -q Hazard3
    git -C Hazard3 remote add origin https://github.com/Wren6991/Hazard3
fi
git -C Hazard3 fetch -q --depth 1 origin "$HAZARD3_COMMIT"
git -C Hazard3 checkout -q FETCH_HEAD
[[ "$(git -C Hazard3 rev-parse HEAD)" == "$HAZARD3_COMMIT" ]] || { echo "Hazard3 is not at the pinned commit" >&2; exit 1; }

git -C Hazard3 submodule update -q --init --depth 1 scripts test/sim/riscv-tests/riscv-tests
[[ "$(git -C Hazard3/scripts rev-parse HEAD)" == "$SCRIPTS_COMMIT" ]] \
    && [[ "$(git -C Hazard3/test/sim/riscv-tests/riscv-tests rev-parse HEAD)" == "$RISCV_TESTS_COMMIT" ]] \
    || { echo "a submodule is not at the commit this was verified with" >&2; exit 1; }

# The E6 core's HDL, beside the pinned one, and the testbench without the ports it does not have yet.
git -C Hazard3 fetch -q --depth 1 origin "$E6_COMMIT"
rm -rf Hazard3/hdl-e6 && mkdir -p Hazard3/hdl-e6
git -C Hazard3 archive "$E6_COMMIT" hdl | tar -x -C Hazard3/hdl-e6 --strip-components=1
sed -i -f hdl_e6.sed Hazard3/hdl-e6/hazard3_config.vh
cp config_rp2350.vh config_rp2350_e6.vh Hazard3/test/sim/tb_common/hdl/
sed -f tb_e6.sed Hazard3/test/sim/tb_common/hdl/tb.v > Hazard3/test/sim/tb_common/hdl/tb_e6.v
printf 'file tb_e6.v\nlist tb_common.f\n' > Hazard3/test/sim/tb_common/hdl/tb_e6.f
cd Hazard3/test/sim/tb_verilator
build() { # CONFIG OUT [DOTF HDL [VERILATOR]]
    local dotf="${3:-tb.f}"; local dir="build-${dotf%.f}"
    make CONFIG="$1" DOTF="$dotf" ${4:+HDL="$4"} ${5:+VERILATOR="$5"} vcc > /dev/null
    make -C "$dir/obj_dir" -f Vtb.mk CXX=clang++ OPT_FAST=-O2 -j"$(nproc)" > /dev/null
    clang++ -O3 -std=c++14 -I "$dir/obj_dir" -I "$(verilator --getenv VERILATOR_ROOT)/include" \
        -I ../tb_common/include "$dir"/obj_dir/*.o tb.cpp ../tb_common/*.cpp -o "$2" -latomic -lpthread
    # The objects are only for linking; the testbench is all that is used.
    rm -rf "$dir"
}
build default tb
build rp2350 tb-rp2350
# The older core lints with warnings the pinned one has since put right (widths, mostly); none is an error.
build rp2350_e6 tb_e6-rp2350 tb_e6.f "$(cd ../../.. && pwd)/hdl-e6" "verilator -Wno-fatal"
cd - > /dev/null
echo "$WANT" > "$STAMP"
echo "built the Hazard3 testbenches at $HAZARD3_COMMIT"
