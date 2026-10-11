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
the 33 cases halting with its verdict and the model's count; and six wrong
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
./check.sh   # everything that needs no board, about fifteen minutes
./run.sh     # the same, recorded to capture.txt
```

## Expected output

Not yet captured.
