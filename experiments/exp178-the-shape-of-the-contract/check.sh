#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp178 quick check — non-interactive, and no board anywhere in it.
#
# There are two halves and they are checked differently. The stub is checked by
# **building it**: the compiler is the instrument, and an obligation that
# disappears from `Env` upstream makes this fail rather than quietly shrink the
# claim. The engine is checked by running it in a host process and ruling on
# every one of exp176's ten code differences — from exp176's own file, so that
# the two experiments cannot drift apart without something going red.
#
# It needs the network once, for ./setup.sh. After that it is offline.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

# No board, no person, nothing to look at: a machine and nothing else.
PRESENCE=0
presence_check

# No USB anywhere in it — the fourth experiment here with none, after exp102,
# exp103 and exp140. It is firmware-shaped, in that it builds an image for the
# board's own target, and that image is never flashed, so nothing is ever
# declared to a host.
USB_IFACE="none"
USB_CARRIES="none"
USB_HOST="none"
USB_RUNS_ON="none"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed to rule on exp176's list"; exit 1; }
command -v cargo > /dev/null && pass "cargo present" \
    || { fail "cargo present" "see exp102"; exit 1; }

# --- somebody else's tree, and the shape of that fact ---------------------
if [[ -d upstream/OpenSK/.git ]]; then
    pass "the engine is cloned (./setup.sh)"
else
    fail "the engine is cloned" "run ./setup.sh — it needs the network once"
    exit 1
fi

PINNED="$(grep -o 'UPSTREAM_SHA="[0-9a-f]*"' setup.sh | cut -d'"' -f2)"
HAVE="$(git -C upstream/OpenSK rev-parse HEAD)"
[[ "$HAVE" == "$PINNED" ]] \
    && pass "the clone is at the commit setup.sh pins ($PINNED)" \
    || fail "the clone is at the pinned commit" "got $HAVE; re-run ./setup.sh"

# Not vendored, and this is where that stops being an intention. `git ls-files`
# asks the index, so a stray `git add upstream/` is caught here and not in a
# review.
TRACKED="$(cd ../.. && git ls-files experiments/exp178-the-shape-of-the-contract/upstream | wc -l)"
[[ "$TRACKED" -eq 0 ]] \
    && pass "no upstream file is committed to this repository" \
    || fail "no upstream file is committed" "$TRACKED files under upstream/ are tracked"

# --- the three things Apache-2.0 asks of a reuser -------------------------
[[ -f upstream/OpenSK/LICENSE ]] \
    && pass "obligation 1 of 3: upstream's licence travels with its code" \
    || fail "upstream's LICENSE is present" "the clone is incomplete"
grep -q 'SPDX-License-Identifier: Apache-2.0' stub/src/main.rs driver/src/main.rs closes.py \
    && pass "obligation 2 of 3: this experiment's own files carry the same licence" \
    || fail "the new files are marked Apache-2.0" "add the SPDX line"
grep -qi 'not vendored\|written against OpenSK\|somebody else' README.md \
    && pass "obligation 3 of 3: the README says what is ours and what is theirs" \
    || fail "the README states the modification" "say which code is this repository's"

# --- half one: what the contract demands, asked of the compiler -----------
rustup target list --installed 2>/dev/null | grep -q thumbv8m.main-none-eabihf \
    && pass "the board's target is installed" \
    || fail "thumbv8m.main-none-eabihf is installed" "see exp102"

# Stable, and not nightly. Prior work on this chip used a nightly toolchain, so
# this is checked rather than assumed: the engine's `subtle` dependency asks for
# a feature called `nightly` and does not need one.
grep -q 'channel = "stable"' stub/rust-toolchain.toml \
    && pass "the stub declares stable Rust" \
    || fail "the stub is built on stable" "prior work needed nightly; this does not"

echo "      building both arms of the stub (this is the measurement) ..."
( cd stub && cargo build --release --quiet ) 2>/dev/null \
    && pass "the stub meets Env and links for the board's target" \
    || fail "the stub builds" "an obligation changed upstream — read the compiler's list"
WITH="$(size -B stub/target/thumbv8m.main-none-eabihf/release/exp178-stub | awk 'NR==2 {print $1}')"

( cd stub && cargo build --release --quiet --no-default-features ) 2>/dev/null \
    && pass "the same crate builds with no engine in it" \
    || fail "the engine-less arm builds" "the feature gate broke"
WITHOUT="$(size -B stub/target/thumbv8m.main-none-eabihf/release/exp178-stub | awk 'NR==2 {print $1}')"

ENGINE=$((WITH - WITHOUT))
echo "      with engine ${WITH} bytes, without ${WITHOUT}, engine ${ENGINE}"
[[ "$ENGINE" -gt 100000 ]] \
    && pass "full CTAP 2.1 costs ${ENGINE} bytes of flash on this chip" \
    || fail "the engine's size is measured, not folded away" \
            "only ${ENGINE} bytes — LTO deleted it; every stub must answer through black_box"

# The reason that number is trustworthy, checked rather than remembered.
[[ "$(grep -c 'hint::black_box' stub/src/main.rs)" -ge 10 ]] \
    && pass "every stub answers through black_box, so nothing is folded away" \
    || fail "the stubs are opaque to the optimiser" "see this file's git history for what happens"

# The heap. `Env` hands back Vec and Box, so this line is not a choice and the
# check exists to stop it being quietly removed as tidying.
grep -q 'global_allocator' stub/src/main.rs \
    && pass "the adapter carries a global allocator — the contract requires one" \
    || fail "the allocator is present" "Env returns Vec and Box; it cannot be met without one"

# Six obligations, each pointing at the experiment here that has the real thing.
OBLIGATIONS="$(grep -c 'The real one:' stub/src/main.rs)"
[[ "$OBLIGATIONS" -eq 6 ]] \
    && pass "all six obligations name the experiment that already implements them" \
    || fail "each obligation names its real implementation" "found $OBLIGATIONS of 6"

# --- the numbers in the README are counted, not typed --------------------
python3 obligations.py > /dev/null \
    && pass "the contract's shape is counted from the pinned source" \
    || fail "obligations.py runs" "upstream's api/ moved"

python3 - <<'NUMBERS'
import json, re, sys
ob = json.load(open("obligations.json"))["totals"]
readme = open("README.md").read()
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg); ok = ok and cond

# The README's table is the claim, so it is read back and compared rather than
# trusted. A trait that grows a method upstream turns this red.
row = re.search(r"\| \*\*total\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \|", readme)
check(row is not None, "the README carries the totals row")
if row:
    req, prov, _gated, types = (int(g) for g in row.groups())
    check(req == ob["required"],
          "the README's %d demanded signatures are what the source says" % req)
    check(prov == ob["provided"], "and its %d free ones" % prov)
    check(types == ob["associated_types"], "and its %d associated types" % types)

# And what the stub actually wrote, counted from the stub.
src = open("stub/src/main.rs").read()
methods = len(re.findall(r"^\s+fn \w+", src, re.M)) - 1   # less StubEnv::new
types = len(re.findall(r"^\s+type \w+ =", src, re.M))
check(methods == 25 and types == 10,
      "the adapter is %d methods and %d associated types" % (methods, types))
check("**%d methods and %d associated types**" % (methods, types) in readme,
      "and the README says the same numbers")
sys.exit(0 if ok else 1)
NUMBERS
[[ $? -eq 0 ]] || FAILED=1

# --- half two: what the engine answers, and exp176's list -----------------
echo "      running the engine in this process ..."
( cd driver && cargo run --release --quiet ) > engine.json 2>/dev/null \
    && pass "the engine answers CTAPHID in a host process, with no board" \
    || fail "the driver runs" "the TestEnv build broke"

python3 closes.py
[[ $? -eq 0 ]] || FAILED=1

python3 - <<'PY'
import json, sys
c = json.load(open("closes.json"))
ok = True
def check(cond, msg):
    global ok
    print(("PASS  " if cond else "FAIL  ") + msg); ok = ok and cond
n = c["counts"]
check(n["closed"] == n["code_in_exp176"] and n["open"] == 0,
      "all %d of exp176's code differences are closed by somebody else's engine"
      % n["code_in_exp176"])
check(c["certification"]["closed"] is False,
      "and the one exp176 called certification is not — no amount of code closes it")
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || FAILED=1

# --- the argument it makes ------------------------------------------------
grep -q 'exp176' README.md \
    && pass "the README rules on exp176's list rather than a list of its own" \
    || fail "the README names exp176" "the list has to be somebody else's"
grep -q 'exp175' README.md \
    && pass "the README ties the uncloseable gap to exp175" \
    || fail "the README names exp175" "the certification gap is exp175's gap"

exit "$FAILED"
