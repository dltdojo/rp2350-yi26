#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp165 quick check — non-interactive.
#
# Eight candidates in one boot. exp164's central guard was that the firmware
# **never writes** the SAU; this one has to write it, so the guard is the
# complementary one: every region it writes lands on a range this firmware
# neither executes from nor keeps anything in, and it hands the map back
# afterwards. That fact is checked here from the source and again on the board.
#
# What is deliberately NOT asserted is any particular attribution. Three of the
# eight candidates are ungraded on purpose, because they are the ones the
# experiment was written to find out.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=1   # flash it and read the log; nothing here needs a hand on the board
presence_check

USB_IFACE="cdc"
USB_CARRIES="log"
USB_HOST="cdc_acm"
USB_RUNS_ON="own"
usb_check

TARGET=thumbv8m.main-none-eabihf
ELF=target/$TARGET/release/exp165-who-gets-the-last-word
UF2=target/exp165.uf2

if command -v cargo > /dev/null && command -v elf2flash > /dev/null; then
    pass "toolchain present (cargo, elf2flash)"
else
    fail "toolchain present" "run exp102 first"
    exit 1
fi

if cargo build --release --quiet 2>/dev/null && [[ -f "$ELF" ]]; then
    pass "firmware compiles ($(stat -c%s "$ELF") byte ELF)"
else
    fail "firmware compiles" "run: cargo build --release"
    exit 1
fi

if elf2flash convert -b rp2350 "$ELF" "$UF2" > /dev/null 2>&1 && [[ -f "$UF2" ]]; then
    pass "converts to UF2 ($(stat -c%s "$UF2") bytes)"
else
    fail "converts to UF2" "run: elf2flash convert -b rp2350 $ELF $UF2"
    exit 1
fi
FAMILY="$(od -An -tx4 -j28 -N4 "$UF2" | tr -d ' ')"
[[ "$FAMILY" == "e48bff59" ]] \
    && pass "UF2 family ID is e48bff59 (rp2350-arm-s)" \
    || fail "UF2 family ID is e48bff59 (rp2350-arm-s)" "got: $FAMILY"

CODE="$(grep -vE '^\s*(///|//!|//)' src/main.rs)"

# **The guard this experiment exists behind.** Marking memory Non-secure is
# harmless to Secure code that only reads it. Marking memory a Secure core is
# *fetching instructions from* is a SecureFault on the next fetch and a dark
# board with no log to say why. So the ranges this firmware is willing to write
# a region over are compared, numerically, against the ranges it is running out
# of — here, and again at runtime by `may_write`.
python3 - <<'PY'
import re, sys
src = open("src/main.rs").read()

def rows(const, pat):
    body = re.search(r"const %s:[^=]*=\s*\[(.*?)\n\];" % const, src, re.S)
    return re.findall(pat, body.group(1)) if body else []

probes = rows("PROBES", r"base:\s*(0x[0-9a-f_]+),\s*limit:\s*(0x[0-9a-f_]+)")
forbid = rows("FORBIDDEN", r"\(\s*(0x[0-9a-f_]+),\s*(0x[0-9a-f_]+)")
h = lambda s: int(s.replace("_", ""), 16)

if not probes or not forbid:
    print("PARSE-FAILED"); sys.exit(0)

bad = []
for pb, pl in probes:
    for fb, fl in forbid:
        if h(pb) <= h(fl) and h(pl) >= h(fb):
            bad.append(f"{pb}..{pl} overlaps {fb}..{fl}")
    if h(pb) & 0x1f or h(pl) & 0x1f != 0x1f:
        bad.append(f"{pb}..{pl} is not 32-byte aligned")
print("OVERLAP " + "; ".join(bad) if bad else f"CLEAR {len(probes)} probes vs {len(forbid)} ranges")
PY
GEOM="$(python3 - <<'PY'
import re
src = open("src/main.rs").read()
def rows(const, pat):
    body = re.search(r"const %s:[^=]*=\s*\[(.*?)\n\];" % const, src, re.S)
    return re.findall(pat, body.group(1)) if body else []
probes = rows("PROBES", r"base:\s*(0x[0-9a-f_]+),\s*limit:\s*(0x[0-9a-f_]+)")
forbid = rows("FORBIDDEN", r"\(\s*(0x[0-9a-f_]+),\s*(0x[0-9a-f_]+)")
h = lambda s: int(s.replace("_", ""), 16)
if not probes or not forbid:
    print("PARSE-FAILED"); raise SystemExit
bad = []
for pb, pl in probes:
    for fb, fl in forbid:
        if h(pb) <= h(fl) and h(pl) >= h(fb):
            bad.append(f"{pb}..{pl} overlaps {fb}..{fl}")
    if h(pb) & 0x1f or h(pl) & 0x1f != 0x1f:
        bad.append(f"{pb}..{pl} is not 32-byte aligned")
print("OVERLAP " + "; ".join(bad) if bad else f"CLEAR {len(probes)} probes, {len(forbid)} forbidden ranges")
PY
)"
case "$GEOM" in
    CLEAR*)  pass "no probe overlaps memory this firmware runs out of ($GEOM)" ;;
    *)       fail "no probe overlaps memory this firmware runs out of" "$GEOM" ;;
esac

# Every configuring write goes through one of two functions, both of which end
# in the barriers the architecture requires. A stray `sau_write(SAU_RLAR, ...)`
# anywhere else is a region written without a guard and without a DSB.
RBAR_W="$(grep -cE '^\s+sau_write\(SAU_RBAR' <<< "$CODE")"
RLAR_W="$(grep -cE '^\s+sau_write\(SAU_RLAR' <<< "$CODE")"
if [[ "$RBAR_W" == 2 && "$RLAR_W" == 2 ]]; then
    pass "the only RBAR/RLAR writes are region_write's and region_off's"
else
    fail "the only RBAR/RLAR writes are region_write's and region_off's" \
         "found $RBAR_W RBAR and $RLAR_W RLAR writes; expected 2 and 2"
fi

# Without DSB+ISB a TT issued straight afterwards may be answered from the old
# configuration, and "the SAU's word was not honoured" would be indistinguishable
# from "it had not landed yet" — which is the most interesting of the three
# outcomes this experiment can report.
DSB="$(grep -cE '^\s+cortex_m::asm::dsb\(\)' <<< "$CODE")"
ISB="$(grep -cE '^\s+cortex_m::asm::isb\(\)' <<< "$CODE")"
[[ "$DSB" == 2 && "$ISB" == 2 ]] \
    && pass "every region configuration is followed by DSB and ISB" \
    || fail "every region configuration is followed by DSB and ISB" "$DSB dsb, $ISB isb"

# Region 7 is the bootrom's and is the subject, not the instrument. A firmware
# that rewrote it would be changing the thing exp164 measured.
if grep -qE 'region_write\(\s*BOOTROM_REGION|sau_write\(SAU_RNR,\s*7' <<< "$CODE"; then
    fail "region 7 is never written" "the bootrom's own region is the subject here"
else
    pass "region 7 (the bootrom's) is never written"
fi

# Nothing is read or written *through* a region this firmware moves. The only
# volatile accesses in the file are the SAU register block itself.
VOL="$(grep -cE '(read|write)_volatile' <<< "$CODE")"
VOL_SAU="$(grep -cE '(read|write)_volatile\(\(SAU \+ off\)' <<< "$CODE")"
[[ "$VOL" == "$VOL_SAU" && "$VOL" -gt 0 ]] \
    && pass "every volatile access targets the SAU block ($VOL of $VOL)" \
    || fail "every volatile access targets the SAU block" \
            "$VOL accesses, $VOL_SAU of them to the SAU: something reads through a moved region"

# Candidate 7 is about ACCESSCTRL *not* moving. A firmware that can write it is
# a worse witness to that, so it has no key constant at all.
if grep -qiE '0xACCE|force_core_ns|write_value' <<< "$CODE"; then
    fail "the firmware never writes ACCESSCTRL" "$(grep -oiE '0xACCE[_0-9a-f]*|force_core_ns|write_value' <<< "$CODE" | head -1)"
else
    pass "the firmware never writes ACCESSCTRL (candidate 7 only reads it)"
fi

if grep -qE '\b(otp|flash)\s*\.\s*(write|program)|write_ecc|erase' <<< "$CODE"; then
    fail "the firmware writes nothing permanent" "found a flash or OTP write"
else
    pass "the firmware writes nothing permanent (no flash, no OTP)"
fi

if grep -q 'SAU == cortex_m::peripheral::SAU::PTR as usize' <<< "$CODE" \
   && grep -q 'agrees && sregion() > 0' <<< "$CODE"; then
    pass "the base address is checked against cortex-m's SAU::PTR, on the board"
else
    fail "the base address is checked against cortex-m's SAU::PTR" \
         "then every register value is a number from an address somebody typed"
fi

# Three candidates are ungraded because they are the open questions. If any of
# them ever acquires an expected outcome, the experiment stops being able to
# contradict the thing it was written to find out — exp162's lesson.
UNGRADED=0
for n in 2 5 7; do
    grep -qE "outcome\[$n\] = Outcome::Measured" <<< "$CODE" && UNGRADED=$((UNGRADED + 1))
done
[[ "$UNGRADED" == 3 ]] \
    && pass "candidates 3, 6 and 8 are ungraded: they are the open questions" \
    || fail "candidates 3, 6 and 8 are ungraded" "only $UNGRADED of 3 are Outcome::Measured"

# **The check this experiment's first run paid for.** That run left the region
# enabled at the end of candidate 2, so every later "baseline" was taken through
# a map the firmware had already changed, and the verdict came out backwards.
if grep -q 'let handed_back = tt(BANK9).raw == base_raw\[BANK9_IDX\];' <<< "$CODE" \
   && grep -q 'landed && handed_back' <<< "$CODE"; then
    pass "candidate 2 is graded on handing the map back, not just on writing it"
else
    fail "candidate 2 is graded on handing the map back" \
         "a candidate that changes the map and keeps it poisons every later baseline"
fi

# Later candidates compare against candidate 1's reading, taken before this
# firmware wrote anything, rather than against one taken mid-run.
BASE_USES="$(grep -cE 'base_raw\[BANK9_IDX\]' <<< "$CODE")"
[[ "$BASE_USES" -ge 4 ]] \
    && pass "the baseline is candidate 1's, taken before any write ($BASE_USES uses)" \
    || fail "the baseline is candidate 1's" "only $BASE_USES uses of base_raw[BANK9_IDX]"

grep -q 'assert!(MAP\[BANK9_IDX\].addr == BANK9' src/main.rs \
    && pass "the baseline index is asserted at compile time, not counted by hand" \
    || fail "the baseline index is asserted at compile time" "an off-by-one would be silent"

grep -q 'assert!(' src/main.rs && grep -q 'PRODUCT.len()' src/main.rs \
    && pass "the product string is bounded at build time" \
    || fail "the product string is bounded at build time" "it can overflow the control buffer"

if [[ "$(grep -n 'spawner.spawn(heartbeat' <<< "$CODE" | cut -d: -f1)" \
      -lt "$(grep -n 'Driver::new' <<< "$CODE" | cut -d: -f1)" ]]; then
    pass "the LED heartbeat starts before the USB stack"
else
    fail "the LED heartbeat starts before the USB stack" "a board that dies in USB init is dark"
fi

# Nothing here arms a watchdog, so "still reflashable" has to be true by
# construction rather than by disarming: the run ends in an idle loop.
if grep -q 'Timer::after(Duration::from_secs(REPEAT_GAP_S)).await' <<< "$CODE" \
   && ! grep -q 'breadcrumb' <<< "$CODE"; then
    pass "the run ends in a repeating report, with no watchdog to disarm"
else
    fail "the run ends in a repeating report" "an armed watchdog would keep rebooting"
fi

# The report repeats so that a reader who plugs in late is not looking at an
# idle board, and it reprints the readings its verdict rests on rather than
# only the verdict. check.sh is one of those late readers.
if grep -q 'tt_line("bank 9, ours NSC", BANK9, b9_nsc)' <<< "$CODE"; then
    pass "the repeated report carries the evidence its verdict rests on"
else
    fail "the repeated report carries its evidence" \
         "a conclusion whose readings scrolled past is one a reader must take on trust"
fi

if [[ -f capture.txt ]]; then
    REPLAY="$(python3 ./verify.py < capture.txt 2>&1 | tail -1)"
    [[ "$REPLAY" == "OK" ]] \
        && pass "verify.py replays the recorded capture" \
        || fail "verify.py replays the recorded capture" "got: $REPLAY"

    # A check that cannot fail has not passed. Three different corruptions,
    # because verify.py derives three different things and one of them passing
    # would hide the other two.
    declare -A CORRUPTIONS=(
        ["a self-contradictory attribution"]='0,/S=yes nsr=no /s//S=yes nsr=yes/'
        ["a raw response word that disagrees with its fields"]='0,/raw=0x003e0100/s//raw=0x004c0000/'
        ["a sweep verdict that contradicts its own readings"]='s/nsr yes sau=1 MOVED/nsr yes sau=1 unmoved/'
    )
    for WHAT in "${!CORRUPTIONS[@]}"; do
        MUTANT="$(sed "${CORRUPTIONS[$WHAT]}" capture.txt)"
        if [[ "$MUTANT" == "$(cat capture.txt)" ]]; then
            fail "the corruption test for $WHAT changes something" "the line it edits is not in capture.txt"
            continue
        fi
        BROKEN="$(printf '%s\n' "$MUTANT" | python3 ./verify.py 2>&1 | tail -1)"
        [[ "$BROKEN" != "OK" ]] \
            && pass "verify.py rejects $WHAT (got $BROKEN)" \
            || fail "verify.py rejects $WHAT" "it still said OK"
    done
else
    fail "a recorded capture is checked in" "capture.txt is missing; verify.py is unreplayed"
fi

if ! exp_running 165; then
    echo "SKIP  board is not running exp165 — flash it (not an error)"
    exit "$FAILED"
fi
pass "board enumerated as 1209:0001"

OUT=""
for _ in $(seq 20); do
    OUT="$(exp_read_log 12 2>/dev/null)"
    grep -q 'VERDICT' <<< "$OUT" && break
    sleep 3
done

FINAL="$(sed -n '/exp165 done/,$p' <<< "$OUT" | sed 's/^\[[^]]*\] //')"

# The recorded capture is the artefact and must be whole. A live read joins a
# board that has been printing to nobody, so a gap there is the reader's
# lateness rather than a defect in the firmware's pacing.
grep -q 'lines lost' capture.txt \
    && fail "the recorded capture has no gaps" "usb-log dropped lines; raise PACE_MS" \
    || pass "the recorded capture has no gaps"

grep -q 'not reached' <<< "$FINAL" \
    && fail "every candidate was attempted" "the final report lists one as not reached" \
    || pass "every candidate was attempted"

grep -q 'NOT as expected' <<< "$FINAL" \
    && fail "all five graded candidates behaved as expected" \
            "$(grep -o '[0-9] [^-]* - NOT as expected' <<< "$FINAL" | tail -1)" \
    || pass "all five graded candidates behaved as expected"

grep -q 'no SecureFault recorded' <<< "$FINAL" \
    && pass "SFSR is unchanged: this firmware caused no SecureFault" \
    || fail "SFSR is unchanged" "$(grep -o 'SFSR.*' <<< "$FINAL" | tail -1)"

grep -qE 'our region r1 left RBAR=0x00000000 RLAR=0x00000000 en=0' <<< "$FINAL" \
    && pass "the board is left with our region switched off" \
    || fail "the board is left with our region switched off" "$(grep -o 'our region.*' <<< "$FINAL" | tail -1)"

# The finding, stated as the shape it has to have rather than as the answer:
# the sweep must disagree with itself across ranges. Four ranges all moving, or
# none moving, would both be consistent with an instrument that is not
# measuring anything.
SWEEP="$(grep -oE '[0-9]+ of [0-9]+ probed ranges honoured our word' <<< "$OUT" | tail -1)"
N="$(cut -d' ' -f1 <<< "$SWEEP")"
T="$(cut -d' ' -f3 <<< "$SWEEP")"
if [[ -n "$N" && "$N" -gt 0 && "$N" -lt "${T:-0}" ]]; then
    pass "the sweep separates the address space ($SWEEP)"
else
    fail "the sweep separates the address space" \
         "got '$SWEEP' — all or nothing means the probe distinguishes nothing"
fi

VERIFY="$(python3 ./verify.py <<< "$OUT" 2>&1 | tail -1)"
case "$VERIFY" in
    OK)         pass "every reading re-derives off the board from its own raw words" ;;
    DISAGREE)   fail "every reading re-derives off the board" "the log disagrees with itself" ;;
    INCOMPLETE) fail "the window holds the whole run" "the window may be too short" ;;
    *)          fail "off-board verification ran" "unexpected result: $VERIFY" ;;
esac

exit "$FAILED"
