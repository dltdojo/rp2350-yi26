# exp228 — the script the kernel runs

<!-- SPDX-License-Identifier: Apache-2.0 -->

**A Bitcoin Script interpreter, a subset of tapscript, in 881 RV32IM
instructions, proved in Lean to halt with the specification's verdict for
every script of up to 1020 bytes and every starting stack of up to 32
elements of up to 80 bytes. The subset is stack operations, arithmetic on
4-byte numbers, `OP_SHA256` and `OP_CHECKSIG`. The proof needs no
assumption about the hash or the signature check: the shell answers both,
and the theorem holds whatever it answers. Writing the proof of `ENCODE`
found a bug that 3000 fuzzed scripts had not: the kernel wrote −128 as
`80 00`, which is +128, and did the same to every negative result whose top
magnitude byte had its high bit set. The shell, in C on the Pico 2's RISC-V
cores, runs 33 hand-written scripts through the proved kernel forever. It
answers `CHECKSIG` with a BIP340 verifier of its own, held here to BIP340's
test vectors, and says over USB what the kernel halted with for each.**

Needs: a **Pico 2**, a hand on **BOOTSEL** once to copy `exp228.uf2` on, and a
**phone with Chrome** to open `tools/pages/log.html`, tap the USB permission,
and **Copy** the log back.

## The subset

| | Opcodes |
| --- | --- |
| pushes | `OP_0`, 1 to 75 bytes, `OP_1NEGATE`, `OP_1`…`OP_16` |
| stack | `OP_DROP`, `OP_DUP`, `OP_NIP`, `OP_OVER`, `OP_SWAP` |
| flow | `OP_NOP`, `OP_VERIFY`, `OP_EQUAL`, `OP_EQUALVERIFY` |
| arithmetic | `OP_1ADD`, `OP_1SUB`, `OP_ADD`, `OP_SUB`, on minimally encoded numbers of at most 4 bytes |
| crypto | `OP_SHA256`, `OP_CHECKSIG` (BIP340, at most one signature a script) |
| everything else | the script fails: `OP_IF`, `OP_PUSHDATA1/2/4`, `OP_RETURN`, … |

The subset is *strict* wherever tapscript would be lenient. An opcode outside
it fails the script, where tapscript's `OP_SUCCESS` opcodes would accept it.
A key that is not 32 bytes fails, where tapscript treats an unknown key type
as valid. A second signature fails, where tapscript counts a budget. A script
this subset accepts is one tapscript would accept with the same stack. The
converse does not hold, and the specification says so in its own comments.

The end is tapscript's: exactly one element left, and true by `CastToBool`.
The exit code says which way a script failed: 0 accepted, then 1 a bad opcode,
2 a push past the end, 3 too few elements, 4 too many (more than 32), 5 not a
4-byte minimal number, 6 `OP_VERIFY` false, 7 a key or signature the wrong
size, 8 a signature invalid, 9 a second signature, 10 not exactly one element
left, 11 false left, 12 `OP_EQUALVERIFY` unequal.

## Three versions of the same thing

| | What it is | Held to |
| --- | --- | --- |
| `proof/Script.lean`'s `verdict` | the specification, in Lean | itself, by the proof |
| `script.py` | the specification again, in Python, with BIP340 by `bip340/reference.py` | the Lean specification, run, on every case (`differential/spec.py`) |
| `kernel.bin` | the interpreter, 881 RV32IM instructions and a 256-word table | the Lean specification, by the proof; script.py, on the Lean model and the Hazard3 RTL (`differential/differential.py`) |

`kernel.py` writes the kernel from labels and puts it in `proof/Script.lean`
between two markers, each label's instruction number beside it, so the proof
names places rather than counting them. `check.sh` runs it again and requires
no difference.

## The region

```
0x0000  the kernel                    0x1800  DEPTH   the stack's depth
0x1000  TABLE   a handler per opcode  0x1804  STACK   32 slots of 84 bytes:
0x1400  SLEN    the script's length                   the length, the element,
0x1404  SCRIPT  at most 1020 bytes                    zeros to the end
                                      0x2284  TMP     one more slot
```

Every slot the kernel writes is zeroed first, so a slot is a function of its
element alone. That is what lets two elements be compared a word at a time,
and a number be read from one word.

## What is proved

```lean
theorem kernel_verdict (hp : Placed env base) (hin : Input m0 base scr st0) {s : Machine}
    (hpc : s.pc = base) (hmem : s.mem = m0) :
    ∃ k s', run env k s = .halted (BitVec.ofNat 32 (verdict env scr st0)) s'
```

`Input` is what the shell puts in the region before the kernel runs: the
kernel and its table, the script and its length, the stack in its slots and
its depth, within the limits. `env.hash` and `env.sig` are the shell's two
calls, and nothing about them is assumed. The kernel's verdict is the
specification's for any hash and any answer to `CHECKSIG`, so the proof
neither needs nor uses a theory of SHA-256 or of secp256k1. Those are the
shell's to get right (below).

It rests on `propext`, `Classical.choice` and `Quot.sound` only: no `sorry`, no
`native_decide`, no Mathlib (`docs/2026-10-10-1236-mathlib-for-checksig-zh-tw.md`
says why not yet).

The proof follows the kernel. `init` covers the fifteen instructions before
the loop. `dispatch` covers the eight that take a script byte to its handler.
Then there is one theorem per handler, each concluding that the machine either
halts with the code the specification's `stepOp` names or comes back to the
top of the loop holding the invariant for the configuration `stepOp` names.
`the_end` covers the depth check and `CastToBool`, and `runs` is induction on
the specification's fuel. The handlers stand on shared blocks:

| Block | What it is shown to compute |
| --- | --- |
| `cast_block` | `CastToBool`, as the kernel does it: clear the last byte's sign bit, then any bit left (`cast_false_iff`) |
| `slots_equal` | two elements equal exactly when their 21 words are |
| `dec_block` | `DECODE`: the specification's `decode`, which is `kdec` on the length and first word (`decode_k`) |
| `core_block` | signed magnitudes added (`kcore_val`) |
| `enc_block` | `ENCODE`: the specification's `encode` — Bitcoin Core's `CScriptNum::serialize` — which is `kenc` (`encode_k`) |
| `copy_slot`, `push_loop` | a slot copied whole; a push's bytes |

`proof/mutants.txt` has seven wrong versions, each refused. The first
ENCODE is one of them. So are a `DECODE` that takes non-minimal numbers, a
`CastToBool` for which negative zero is true, a push that reads past the end,
a specification that allows a second signature, and a verdict given too
little fuel.

## What the proof found

`ENCODE` builds a result's bytes in a zeroed slot. When the magnitude's top
byte has its high bit set, the sign needs a byte of its own. The first kernel
stored that sign byte at offset 4 + n, and then stored the magnitude's whole
word at offset 4. Whenever the magnitude had fewer than four bytes, that word
overwrote the sign byte with zero. So −128 came out as `80 00`, which is +128.
The same happened to −129…−255, −32768…−65535 and −0x800000…−0xffffff.

The model and the RTL had agreed with `script.py` on all 3000 fuzzed scripts.
A random script almost never compares such a sum with a constant. The proof
could not get past the store order. `cases.arith()` is the test that should
have existed first: 1ADD and 1SUB of every number at the edge of a byte count,
ADD and SUB of every pair of a smaller set, and each result compared with
`script.py`'s encoding of it. That is 672 scripts. The old kernel fails 110 of
them on the model; the fixed one fails none.

## The calls

The kernel is the model's (`lean/Rv32/Machine.lean`), with two calls added for
this experiment:

```
ecall t0 = 2   HASHB     SHA-256 of a1 bytes at a0, 32 bytes written at a2
ecall t0 = 3   CHECKSIG  a0 := 1 or 0, the shell's answer for the 32 bytes at a0
                         (a key) and the 64 at a1 (a signature)
```

Both are checked as the model checks them: inside the region, or a fault.
`tools/hazard3/harness/handler.c` gives the RTL the same two calls. Its
`checksig` says no to everything unless a shell links one in, which matches
the model's runner without `RV32RUN_SIGS`.

## The shell

`shell/shell.c` runs every hand case in `cases.py`, 33 scripts that between
them reach every opcode and every way to fail. For each case it zeroes the
region, writes the kernel (checked against `kernel.sha256`), the script and
the stack, and enters the kernel in User mode. It answers `HASHB` with
SHA-256. It answers `CHECKSIG` with `shell/bip340.c` against a fixed message,
the one `cases.py` signs; it stands where tapscript's signature hash would
stand. When the kernel halts, the shell checks:

1. the kernel's bytes were `kernel.sha256`'s
2. the exit code is the case's verdict, `script.py`'s, which `gen.py` confirmed
   the Lean model gives too
3. minstret is the model's count, plus four for the harness, plus four for
   each call
4. it halted at all, and not by some other trap

Then it goes on to the next case, and from the last case back to the first.

`shell/bip340.c` is BIP340's `Verify`, freestanding, 32-bit words, Jacobian
points, with no attempt at constant time: everything it handles is public. It
is not proved. It is held to BIP340's 19 test vectors and to 200 signatures
that `reference.py` made, half of them with one bit flipped, and it gives
every one of them the result BIP340 says. The kernel's theorem does not
depend on it.

### The lines

```
CASE round i code want minstret sigs valid name   one case: what it halted with, its verdict,
                                                  minstret, signatures checked and valid
ROUND round cases                                 every case as it should be, this round
exp228 usb=… … lives=… minstret=…                 exp226's status line, about once a second
FAIL …                                            a check failed (speak.h's)
```

### The LED

Each case gets one beat. A script the kernel accepts gets one unit on and one
unit off; a script it rejects gets two units dark. That is 33 beats, about 12
seconds a round, with 1.5 seconds dark between rounds. Fourteen of the 33 are
accepted; `build/expect.h` lists them in order, with a verdict of 0.

While a host is part way through enumerating the board (a stage from 2 to 5),
the LED shows that stage, as exp226 does. A 2-second light first is an error,
and the board stops there: 1 to 4 are the four checks above, 5 to 9
`speak.h`'s clocks and USB.

## Running it on a board, from a phone

1. Hold **BOOTSEL**, plug the Pico 2 into the phone, and copy `exp228.uf2` onto
   the drive that appears. The board restarts by itself.
2. Watch the LED for a few seconds: a pattern of beats and pauses, repeating
   every 13 or so seconds. A long light first means a check failed; count the
   flashes after it.
3. Open `tools/pages/log.html` in Chrome, tap the button, pick the board, and
   let it run through a round or two (the `ROUND` line). Then **Copy** and
   paste the log back.

Every `CASE` line should have `code` equal to `want`, and each round should
end in `ROUND` with `00000021`: 33 cases, in hex, as every number on these
lines is.

## What is checked without a board

`check.sh`: the proof and its seven refusals; `kernel.py` against the proof's
kernel; `kernel.bin` against what the proof writes; the specification run
against `script.py` on every hand case, the 672 of arithmetic and 300 fuzzed;
the model and the RTL against `script.py` on all of those; `bip340.c` on this
machine; the UF2's bytes; on the RTL the whole shell, BIP340 and all, each of
the 33 cases halting with its verdict and the model's count; and seven wrong
shells, each caught by the check it names.

`run.sh` also runs the differentials with 3000 fuzzed scripts.

## What it does not say

- **Not consensus.** A subset, strict where tapscript is lenient. There is no
  `OP_IF`, no `OP_CHECKSIGADD`, no annex, no signature hash. The message is
  the shell's constant, and BIP341's signature hash over a transaction is not
  computed anywhere.
- **The shell's BIP340 is tested, not proved.** The theorem holds for any
  answer the shell gives, so a wrong verifier gives wrong verdicts that the
  theorem still covers. Test vectors are what stand between `bip340.c` and
  that.
- **Limits.** 1020 bytes of script, 32 elements, 80 bytes each: the proof's
  `Input`. Tapscript allows more.
- **No timing.** The theorem says the kernel halts, not when. minstret is
  checked against the model's count case by case, and nothing is claimed
  about it in general. Nothing here is constant-time, and nothing needs to
  be.
- **The chip.** Nothing here has run on a Pico 2 yet.

## Running it

```sh
./check.sh   # everything that needs no board, about half an hour
./run.sh     # the same, recorded to capture.txt
```

## Expected output

Recorded by `./run.sh` from a clean commit, on this machine with no board
attached. The board's half is not yet captured. `capture.txt` is the whole
record; below are its sections, with the hand cases' per-case lines left out
here (they are in `capture.txt`) and the 3000-script differential cut to its
summary.

```
=== exp228 — the script the kernel runs ===
recorded at 2026-10-11T02:35:36Z from commit f2a7803

>>> the theorems, and what they rest on
'Exp228.decode_k' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.encode_k' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.iter' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.init' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.the_end' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.runs' depends on axioms: [propext, Classical.choice, Quot.sound]
'Exp228.kernel_verdict' depends on axioms: [propext, Classical.choice, Quot.sound]
exit 0

>>> wrong kernels and wrong claims: each must be refused
enc_tail        ENCODE stores the sign byte before the magnitude's word, which then writes over it — -128 comes out as 80 00, as it did in this experiment's first kernel   refused in enc_tail
dec_block       DECODE never asks whether a bare sign byte was needed: 00 80 and 80 are numbers                                                                               refused in dec_block
h_verify        CastToBool keeps the last byte's sign bit: negative zero is true                                                                                              refused in h_verify
h_push          a push's check of the script's end is turned around                                                                                                           refused in h_push
h_checksig      the specification lets a script check a second signature, and the kernel does not                                                                             refused in h_checksig
the_end         the specification accepts a false element left on the stack                                                                                                   refused in the_end
kernel_verdict  the verdict is given the fuel for one opcode fewer than the script holds                                                                                      refused in kernel_verdict

>>> the specification, run, against script.py; the model and the RTL against script.py, 3000 fuzzed
PASS  proof/Script.lean's specification, run, agrees with script.py on all 3705 cases: 33 by hand, 672 of arithmetic at the edges and 3000 fuzzed
PASS  672 scripts of arithmetic at the edges and 3000 fuzzed, model and RTL against script.py: accept 738, bad opcode 837, push past the end 251, too few elements 558, too many elements 2, not a 4-byte minimal number 492, OP_VERIFY false 38, key or signature the wrong size 229, signature invalid 4, a second signature 1, not exactly one element left 356, false 9, OP_EQUALVERIFY unequal 190

>>> on the RTL, every case: CASE i code want minstret sigs valid, then DONE cases
43415345 00000000 00000000 00000000 0000006f 00000000 00000000
43415345 00000001 00000000 00000000 000001a2 00000000 00000000
43415345 00000002 00000000 00000000 000001ab 00000000 00000000
43415345 00000003 00000000 00000000 0000019a 00000000 00000000
43415345 00000004 00000000 00000000 00000199 00000000 00000000
43415345 00000005 00000000 00000000 000002b9 00000000 00000000
43415345 00000006 00000000 00000000 000001cd 00000000 00000000
43415345 00000007 00000000 00000000 000001ed 00000000 00000000
43415345 00000008 00000000 00000000 00000226 00000001 00000001
43415345 00000009 00000000 00000000 00000149 00000001 00000001
43415345 0000000a 00000000 00000000 000001da 00000000 00000000
43415345 0000000b 00000006 00000006 00000053 00000000 00000000
43415345 0000000c 00000000 00000000 0000007f 00000000 00000000
43415345 0000000d 00000000 00000000 00000155 00000000 00000000
43415345 0000000e 00000001 00000001 00000043 00000000 00000000
43415345 0000000f 00000001 00000001 0000001f 00000000 00000000
43415345 00000010 00000002 00000002 00000021 00000000 00000000
43415345 00000011 00000003 00000003 00000048 00000000 00000000
43415345 00000012 00000004 00000004 000004a0 00000000 00000000
43415345 00000013 00000004 00000004 0000005c 00000000 00000000
43415345 00000014 00000005 00000005 00000069 00000000 00000000
43415345 00000015 00000005 00000005 00000066 00000000 00000000
43415345 00000016 00000005 00000005 0000005d 00000000 00000000
43415345 00000017 00000006 00000006 00000045 00000000 00000000
43415345 00000018 00000007 00000007 000000e6 00000000 00000000
43415345 00000019 00000007 00000007 000000f0 00000000 00000000
43415345 0000001a 00000008 00000008 000000fa 00000001 00000000
43415345 0000001b 00000009 00000009 00000265 00000001 00000001
43415345 0000001c 0000000a 0000000a 00000063 00000000 00000000
43415345 0000001d 0000000a 0000000a 0000001b 00000000 00000000
43415345 0000001e 0000000b 0000000b 0000003d 00000000 00000000
43415345 0000001f 0000000c 0000000c 000000c5 00000000 00000000
43415345 00000020 00000000 00000000 000001de 00000000 00000000 444f4e45 00000021 exit=0 

>>> the checks
PASS  no lifeline, and it says why: a C shell, not crates/lifeline — BOOTSEL by hand is the way back
PASS  Script.lean checks, with no errors and no warnings
PASS  all 7 theorems it prints rest on Lean's own axioms only — no sorryAx, no native_decide
PASS  enc_tail: the proof refuses a version where ENCODE stores the sign byte before the magnitude's word, which then writes over it — -128 comes out as 80 00, as it did in this experiment's first kernel
PASS  dec_block: the proof refuses a version where DECODE never asks whether a bare sign byte was needed: 00 80 and 80 are numbers
PASS  h_verify: the proof refuses a version where CastToBool keeps the last byte's sign bit: negative zero is true
PASS  h_push: the proof refuses a version where a push's check of the script's end is turned around
PASS  h_checksig: the proof refuses a version where the specification lets a script check a second signature, and the kernel does not
PASS  the_end: the proof refuses a version where the specification accepts a false element left on the stack
PASS  kernel_verdict: the proof refuses a version where the verdict is given the fuel for one opcode fewer than the script holds
PASS  proof/Script.lean's kernel is what kernel.py writes from its labels
PASS  kernel.bin is what proof/Script.lean writes, 5120 bytes, and kernel.sha256 is its hash
PASS  proof/Script.lean's specification, run, agrees with script.py on all 1005 cases: 33 by hand, 672 of arithmetic at the edges and 300 fuzzed
PASS  672 scripts of arithmetic at the edges and 300 fuzzed, model and RTL against script.py: accept 690, bad opcode 99, push past the end 22, too few elements 54, too many elements 2, not a 4-byte minimal number 57, OP_VERIFY false 4, key or signature the wrong size 33, signature invalid 2, a second signature 1, not exactly one element left 24, false 3, OP_EQUALVERIFY unequal 14
PASS  bip340.c gives 19 of 19 of BIP340's test vectors the result the CSV says
PASS  bip340.c gives 200 of 200 signatures reference.py made, half of them with a bit flipped, the result the CSV says
PASS  the shell builds for the chip and for the RTL, the chip's in 26664 of the 32768 bytes it may use
PASS  all 105 blocks carry family 0xe48bff57, absolute
PASS  every block lies in the first 32 KiB of flash, 0x10000000..0x10008000
PASS  together they are exactly the 26664-byte image
PASS  the image starts with a jump to _start at 0x10000024
PASS  the IMAGE_DEF block: RISC-V EXE for RP2350, entry _start, stack 0x20070000
PASS  the UF2 is byte for byte the committed one: 14c86684235f6e94…
PASS  on the RTL the shell runs all 33 cases, SHA-256 and BIP340 answering the calls, each halting with script.py's verdict and the model's count
PASS  the shell catches a version where kernel.sha256 is not kernel.bin's hash — check 1
PASS  the shell catches a version where the first case is said to be rejected — check 2
PASS  the shell catches a version where the chip is asked to count one more for the first case — check 3
PASS  the shell catches a version where HASHB hashes one byte too few — check 2, where a hash is compared
PASS  the shell catches a version where CHECKSIG says yes to every signature — check 2, at the invalid one
PASS  the shell catches a version where BIP340's challenge leaves the key out — check 2, at the first valid signature
PASS  the shell catches a version where the shell itself traps in step 3 — a fault, not a check
```

The run took 44m42s, of which the mutants are 13 minutes and the
differentials' 3000 fuzzed scripts 11.
