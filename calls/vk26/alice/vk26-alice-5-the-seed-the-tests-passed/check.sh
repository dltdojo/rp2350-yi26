#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# vk26-alice-5 quick check — everything that needs no board.
#
#   1. proof/Seed.lean checks, on Lean's own axioms: the Instantiate kernel
#      halts with 0 after exactly 241 instructions from any machine at base
#      whose region holds a seed material's length, m and the interval, V and
#      C then SP 800-90A's Hash_df of it, the region laid out as vk26-alice-4's
#      Generate asks (inst_run, inst_boot); and the chain: vk26-alice-2's
#      kernel halts with 0 exactly when its hash passed the KAT and both
#      windows their tests, and only then the Instantiate kernel and
#      vk26-alice-4's Generate run, each after the shell puts its bytes at the
#      region's start, and their bits are Hash(V + j) for V Hash_df of the
#      digest and the nonce (chain). Wrong kernels and wrong claims are
#      refused; kernel.bin is what the proof writes;
#   2. seed.py, from the standard's text, gives NIST's ReturnedBits through
#      its own Instantiate for all 120 cases; the Lean model and the Hazard3
#      RTL run the Instantiate kernel and two Generates on every case, and
#      the whole chain on 14 streams and three bad KAT digests, every region
#      and every bit seed.py's;
#   3. the shell builds for the chip, into the first 64 KiB of flash, and its
#      UF2 reads back as built — byte for byte the committed one when the
#      toolchain is the recorded one;
#   4. on the RTL the shell runs every NIST case and both chains, minstret the
#      RTL's for each of the eight kinds of run; wrong shells are caught;
#   5. seed.html, the page a phone shows the board on, built into one file:
#      it does every step again — the tests, the KAT, the digest, Hash_df,
#      Generate — and tells right cases and chains from wrong ones, each in
#      the way it is wrong, from logs fixtures.py writes from seed.py; its
#      constants are expect.h's; wrong pages are caught; in headless Chromium;
#   6. every log a phone gave back (board/*.txt): each NIST case against
#      NIST's vectors by name and each chain done again by seed.py, by
#      fixtures.py, and by the page; the mcycles printed as read, not judged.
#
# Needs Lean (tools/lean/setup.sh), the Hazard3 testbench
# (tools/hazard3/setup.sh), clang, lld, llvm-objcopy, cargo, python3 and node.
# Without Lean or the testbench it says SKIP. About eight minutes, most of it
# the RTL.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

TOOLS=../../../../tools
source ../../../../experiments/lib.sh
source "$TOOLS/pages/pagecheck.sh"
require_supported_platform

LEAN=$TOOLS/lean/lean.sh
$LEAN check proof/Seed.lean || FAILED=1
$LEAN mutants proof/Seed.lean || FAILED=1

if python3 seed.py > /dev/null; then
    pass "seed.py's Instantiate, then two Generates, give NIST's ReturnedBits for all 120 cases"
else
    fail "seed.py gives NIST's ReturnedBits" "$(python3 seed.py)"
fi

SIM=$TOOLS/hazard3/sim.sh
source "$TOOLS/hazard3/shell/shell.sh"
if [[ "$($LEAN version 2>&1)" != Lean* ]] || ! $SIM ready; then
    echo "SKIP  the differential and the shell: needs tools/lean/setup.sh and tools/hazard3/setup.sh"
    exit "$FAILED"
fi

if ./build.sh > /dev/null; then
    pass "the shell builds for the chip and for the RTL, the chip's in $(stat -c %s build/vk26-alice-5.bin) of the 65536 bytes it may use"
else
    fail "the shell builds"
    exit 1
fi
if cmp -s build/kernel.bin kernel.bin && [[ "$(sha256sum kernel.bin | cut -d' ' -f1)" == "$(cut -d' ' -f1 kernel.sha256)" ]]; then
    pass "kernel.bin is what proof/Seed.lean writes, $(stat -c %s kernel.bin) bytes, and kernel.sha256 is its hash; alice-2's and alice-4's, as alice's package writes them, are their committed kernel.bin"
else
    fail "kernel.bin is what proof/Seed.lean writes"
fi
python3 differential/differential.py "$($LEAN exe rv32run)" kernel.bin build/trust.bin build/drbg.bin || FAILED=1

python3 "$TOOLS/hazard3/shell/uf2check.py" build/vk26-alice-5.uf2 build/vk26-alice-5.bin \
    "$(llvm-nm build/chip.elf | awk '$3 == "_start" {print $1}')" 65536 || FAILED=1
if [[ "$(clang --version | head -1)" == "$(cat build-toolchain.txt)" ]]; then
    if [[ "$(sha256sum build/vk26-alice-5.uf2 | cut -d' ' -f1)" == "$(cat vk26-alice-5.uf2.sha256)" ]]; then
        pass "the UF2 is byte for byte the committed one: $(cut -c1-16 vk26-alice-5.uf2.sha256)…"
    else
        fail "the UF2 is byte for byte the committed one" "same toolchain, different bytes"
    fi
else
    echo "SKIP  the UF2 against the committed hash: built with $(clang --version | head -1), recorded with $(cat build-toolchain.txt)"
fi

# Every NIST case, then both chains, on the RTL: CASE i, minstret mcycle of its
# three runs; CHN s code minstret mcycle, with code 0 the Instantiate kernel's
# and Generate's too; then DONE 120.
got="$(shell_words build/sim.bin 600000000)"
if python3 - "$got" <<'PY'
import re, sys
words = sys.argv[1].split()
text = open("build/expect.h").read()
num = lambda name: int(re.search(rf"#define {name} (\d+)u?", text).group(1))
trust = [int(x) for x in re.search(r"INSTRET_TRUST\[4\] = \{([^}]*)\}", text).group(1).replace("u", "").split(",")]
inst, chain_inst, gen, n = num("INSTRET_INST"), num("INSTRET_INST_CHAIN"), num("INSTRET_GEN"), num("NCASES")
rows, i = [], 0
while i < len(words) and words[i] == "43415345":
    rows.append([int(w, 16) for w in words[i + 1:i + 8]])
    i += 8
ok = len(rows) == n and all(r[0] == k and r[1] == inst and r[3] == r[5] == gen for k, r in enumerate(rows))
chains = []
while i < len(words) and words[i] == "43484e00":
    s, code, tn, tc = (int(w, 16) for w in words[i + 1:i + 5])
    extra = [int(w, 16) for w in words[i + 5:i + 9]] if code == 0 else []
    chains.append((s, code, tn, extra))
    i += 5 + len(extra)
ok &= words[i:] == ["444f4e45", f"{n:08x}", "exit=0"]
ok &= [c[:2] for c in chains] == [(0, 0), (1, 2)] and chains[0][2] == trust[0] and chains[1][2] == trust[2]
ok &= chains[0][3][0] == chain_inst and chains[0][3][2] == gen
print(f"the RTL: {len(rows)} NIST cases at {inst} {gen} {gen}; chain 0 code {chains[0][1]} at {chains[0][2]} "
      f"{chains[0][3][0]} {chains[0][3][2]}; chain 1, the KAT spoiled, code {chains[1][1]} at {chains[1][2]}")
sys.exit(0 if ok else 1)
PY
then
    pass "on the RTL the shell runs all 120 NIST cases, each its state seed.py's and its bits NIST's, then the chain from the stand-in TRNG through all three kernels, then the chain with the KAT spoiled, stopped at the first with 2"
else
    fail "on the RTL the shell runs every case and both chains" "$got"
fi

# The page: one file, as a phone gets it; its verdicts on logs right and
# wrong; in a browser.
if ! command -v node > /dev/null; then
    echo "SKIP  the page: node is not installed"
else
    python3 ../pages/build.py seed.html build/seed.html
    python3 fixtures.py build/page build/expect.h
    page_parses build/seed.html build
    page_findcdc build/seed.html
    same=1
    for pair in SEED_INSTRET_INST:INSTRET_INST SEED_INSTRET_INST_CHAIN:INSTRET_INST_CHAIN SEED_INSTRET_GEN:INSTRET_GEN SEED_M:M; do
        mine="$(grep -oE "${pair%%:*} = [0-9]+" seed.html | grep -oE '[0-9]+$')"
        theirs="$(sed -n "s/^#define ${pair##*:} \([0-9]*\)u\{0,1\}$/\1/p" build/expect.h)"
        [[ -n "$mine" && "$mine" == "$theirs" ]] || same=0
    done
    python3 - <<'PY' || same=0
import re, sys
page, h = open("seed.html").read(), open("build/expect.h").read()
trust = re.search(r"SEED_INSTRET_TRUST = \[([^\]]*)\]", page).group(1).replace(" ", "")
kat = re.search(r"const SEED_KAT = '([^']*)';", page).group(1).encode()
want = bytes(int(x, 16) for x in re.search(r"KAT_MSG\[64\] = \{([^}]*)\}", h).group(1).split(","))
sys.exit(trust != re.search(r"INSTRET_TRUST\[4\] = \{([^}]*)\}", h).group(1).replace("u", "").replace(" ", "") or kat != want)
PY
    if (( same )); then
        pass "the page's minstrets, block count and KAT message are expect.h's"
    else
        fail "the page's minstrets, block count and KAT message are expect.h's"
    fi
    shopt -s nullglob
    node page_test.mjs build/seed.html build/page board/*.txt || FAILED=1
    # On the built page, as a phone runs it.
    page_mutant "Hash_df asks for 432 bits, not 440" 's/x.set(\[k, 0, 0, 1, 0xb8\]);/x.set([k, 0, 0, 1, 0xb0]);/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "C is Hash_df of V, the 0x00 before it left out" 's/return { v, c: await seedDf(z) };/return { v, c: await seedDf(v) };/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "the second Generate starts from Instantiate's V again" \
        's/g2 = await drbgGenerate(g1.v, c, g1.counter, SEED_M)/g2 = await drbgGenerate(v, c, g1.counter, SEED_M)/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "a NIST case's blocks are not compared" \
        's/if (!seedSame(p.block\[j\], g2.bits.subarray(32 \* j, 32 \* j + 32)))/if (false)/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "the nonce is the next round's" 's/seed.set(seedNonce(e.round), 32);/seed.set(seedNonce(e.round + 1), 32);/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "the digest is of the start-up window" 's/await drbgHash(healthWindowBytes(bits, 1));/await drbgHash(healthWindowBytes(bits, 0));/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "the shell's spoiling is not allowed for" 's/p.kat.k ? spoiled : right)/right)/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "a failed second window lets the chain go on" 's/\[1, 3, 0\]\[tests.passed\]/[1, 0, 0][tests.passed]/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "the chain's Instantiate is held to its minstret alone" \
        's/if (p.crun\[0\].minstret !== SEED_INSTRET_INST_CHAIN)/if (p.crun[0].minstret !== SEED_INSTRET_INST)/' \
        build/seed.html node page_test.mjs @ build/page
    page_mutant "an output from a stopped chain is not refused" 's/if (sent !== (code === 0)) {/if (false) {/' \
        build/seed.html node page_test.mjs @ build/page
    if page_playwright; then
        ID=(vk26-alice-5 "vk26-alice-5 the seed the tests passed")
        node ../pages/browser.mjs build/seed.html build/page/good.txt "240 of 240 NIST cases right" 2 "${ID[@]}" || FAILED=1
        node ../pages/browser.mjs build/seed.html build/page/stopped.txt "4 of 4 chains right" 2 "${ID[@]}" || FAILED=1
        node ../pages/browser.mjs build/seed.html build/page/cblock.txt "first wrong: round 0, chain 0" 2 "${ID[@]}" || FAILED=1
    else
        echo "SKIP  the page in a browser: Playwright is not installed"
    fi
fi

# Every log a phone gave back, against NIST's vectors and seed.py.
shopt -s nullglob
logs=(board/*.txt)
if (( ${#logs[@]} )); then
    python3 fixtures.py --board build/expect.h "${logs[@]}" || FAILED=1
else
    echo "SKIP  checking a phone's log: none recorded yet (board/*.txt)"
fi

# Wrong shells and wrong expectations: each is caught by the check it names.
side_by_side_begin
side_by_side shell_mutant "kernel.sha256 is not the Instantiate kernel's hash — check 1" expect.h \
    's/^static const uint8_t KERNEL_SHA\[32\] = {0x[0-9a-f][0-9a-f]/static const uint8_t KERNEL_SHA[32] = {0x00/' \
    "4641494c 00000001 00000001 "
side_by_side shell_mutant "HASHB is answered one byte short — check 4, the state after Instantiate" shell.c \
    's/board_hashb((const uint8_t \*)x\[10\], x\[11\], /board_hashb((const uint8_t *)x[10], x[11] - 1, /' \
    "4641494c 00000004 00000000 "
side_by_side shell_mutant "the seed material's length is given one long — check 4" shell.c \
    's/^    params(k->s);$/    params(k->s + 1);/' "4641494c 00000004 00000000 "
side_by_side shell_mutant "alice-4's kernel is never put in: Instantiate runs again — check 3" shell.c \
    's/^            load(DRBG, DRBG_LEN, DRBG_SHA, 2);$/            (void)0;/' "4641494c 00000003 00000104 "
side_by_side shell_mutant "the chip is asked to count one more instruction for a Generate — check 3" expect.h \
    's/^#define INSTRET_GEN \([0-9]*\)u$/#define INSTRET_GEN 4319u/' "4641494c 00000003 000010de "
side_by_side shell_mutant "the second chain's KAT is not spoiled after all — check 2" shell.c \
    's/            if (spoil) dst\[0\] ^= 1;/            if (0) dst[0] ^= 1;/' "*4641494c 00000002 00000000 *"
side_by_side shell_mutant "the shell itself traps in step 2 — a fault, not a check" shell.c \
    's/^    step = 2;$/    step = 2;\n    __asm__ volatile (".word 0");/' "4641554c 00000002 00000002 "
side_by_side_end

exit "$FAILED"
