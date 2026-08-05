# exp146-a-page-that-writes-flash — the last thing the phone could not do

> **Verified on hardware, 2026-08-05, on a Pixel 9a.** A phone opened a local
> HTML file, read a `.uf2` off its own storage, claimed the bootrom's PICOBOOT
> interface, erased six sectors, wrote 23,040 bytes, **read the first page back
> and compared it**, and rebooted the board — which then came up on that
> firmware and said so over its own log. No drive, no drag-and-drop, no
> toolchain, no second computer. And the board that came up is provably the
> board that was written: the chip ID it reports equals the serial number the
> bootrom gave the flashing page. See [Expected output](#expected-output).

[exp141](../exp141-two-doors-into-the-bootrom/) proved a browser can claim
PICOBOOT and drove it as far as `FLASH_ERASE` — a phone erased a board's flash
from a web page. It stopped there on purpose: erasing is recoverable and writing
is not. This is the other half, and it is the last thing on the whole road that
a phone with one cable still could not do.

The page is [`tools/pages/pflash.html`](../../tools/pages/pflash.html), because
it is a tool somebody uses repeatedly rather than a page you read once.

## Why a page that writes flash is not optional any more

It would be easy to file this under convenience. It is not, and
[exp144](../exp144-one-file-either-half/) is why:

> **A board that has a partition table takes nothing from its BOOTSEL drive.**

Not "takes it unreliably". Nothing — the copy appears to succeed, the file lists,
and it is gone on the next mount. Measured on Ubuntu with a control (erase the
table and the identical file flashes), and it is the same thing that made a
Pixel 9a look unreliable on 2026-08-04 when it was really facing a board that
had just been given a table.

So for a person whose only computer is a phone, the two facts together close a
door:

| | Board with no partition table | Board with a partition table |
| --- | --- | --- |
| Drag a `.uf2` onto the drive | works | **does nothing** |
| This page | works | works |

And a board with a partition table is exactly what a board that accepts field
updates is — exp142, exp143 and exp145 all leave one on. The road that taught
this repository how to update firmware safely is the same road that took the
phone's flashing method away, and this page is what gives it back.

## What it does, command for command

The browser port of `yi26 pflash`, and `check.sh` compares the two opcode by
opcode so they cannot drift:

```text
  IF_RESET            clear any half-finished command state
  EXCLUSIVE_ACCESS    take the flash from the drive
  EXIT_XIP            flash stops being memory and becomes a device
  FLASH_ERASE         the whole target range, sector-aligned
  WRITE × N           4 KiB at a time, padded to a 256-byte page
  READ                the first page back — and compare
  REBOOT2             NORMAL | NO_RETURN
```

Two of those lines are values that each cost a hardware debugging round, so the
check guards them rather than trusting anyone to remember:

- **Flash addresses are absolute**, from the XIP base `0x10000000`. A zero
  offset is what the bootrom STALLs on (exp141 found this by localising it in
  `picotool`'s own source).
- **REBOOT2, not REBOOT.** The RP2040-style reboot with `pc`/`sp` lands back in
  BOOTSEL on this chip even over a perfectly good image.

## What it refuses, and why refusing matters here

The person using this page may have no second computer and no way back. A
bricked board is not an inconvenience for them; it is the end. So the page
refuses before it writes, and refuses again before it reboots:

| Refusal | What it prevents |
| --- | --- |
| A `.uf2` whose lowest address is not `0x10000000` | Nothing at flash offset 0 — the board comes up dark, and **PICOBOOT cannot reach a dark board**. This is exp139's dark board, in a file |
| A `.uf2` with no boot block in the first 4 KiB | Same outcome: the ROM finds nothing to launch |
| A `.uf2` built for another chip | The bootrom ignores it silently, which looks exactly like a board that did not come back |
| A write whose read-back does not match | **The board is not rebooted.** It stays in BOOTSEL, where it can be tried again |

The one thing none of this catches is a well-formed image that crashes before it
brings USB up. That board goes dark, and only the BOOTSEL button brings it back
— which is why the pre-flight exists and why it is worth understanding rather
than clicking past.

## What can be checked without a browser, and what cannot

`check.sh` does two things no screenshot could:

1. **Compares the page's opcodes against `tools/yi26/src/picoboot.rs`.** The
   tool is the reference implementation; a page that drifts from it works until
   somebody compares them on a board they cannot reach.
2. **Runs the page's own parser**, extracted from the `<script>` block, under
   `node`, against three fixtures: a real firmware `.uf2`, the same image with
   every block shifted up a sector (valid, and would leave offset 0 empty), and
   a file that is not a UF2 at all. It has to accept the first and refuse the
   other two. exp116 established this pattern.

What it cannot reach is the USB half. `navigator.usb.requestDevice()` is behind
a native dialog and a required user gesture; headless Chrome has no USB backend
at all (established in exp115's work, do not retry it). So the last step of this
experiment is a person, a phone, and a board — and until that has happened the
header of this file says so.

## Two ways to do it

```sh
./check.sh    # verdict: opcodes against yi26, and the page's parser against
              # three fixtures. Touches no board and opens no browser
```

And the page itself, on the machine that has the board:

1. Put the board in BOOTSEL — [`flash.html`](../../tools/pages/flash.html) from
   a phone, `yi26 bootsel` from a desktop.
2. Open [`pflash.html`](../../tools/pages/pflash.html), choose a `.uf2`, press
   **Flash it**, and pick the board (**RP2350 Boot**) once.
3. Watch the board come back on the new firmware —
   [`log.html`](../../tools/pages/log.html) is where it says so.

## Expected output

`./check.sh`, captured **2026-08-05**:

```text
PASS  the page is in tools/pages/, where the maintained pages live
PASS  CMD_EXCLUSIVE_ACCESS = 0x1 — the page and yi26 agree
PASS  CMD_EXIT_XIP = 0x6 — the page and yi26 agree
PASS  CMD_FLASH_ERASE = 0x3 — the page and yi26 agree
PASS  CMD_WRITE = 0x5 — the page and yi26 agree
PASS  CMD_READ = 0x84 — the page and yi26 agree
PASS  CMD_REBOOT2 = 0xa — the page and yi26 agree
PASS  flash addresses are absolute from the XIP base (a zero dAddr STALLs)
PASS  REBOOT2 uses NORMAL | NO_RETURN (the RP2040-style REBOOT lands in BOOTSEL)
PASS  reads the write back and refuses to reboot if it does not match
PASS  pre-flight: refuses a .uf2 with no boot block at flash offset 0
PASS  pre-flight: refuses a .uf2 built for another chip
PASS  the page's script extracts (331 lines)
PASS  the page's script parses (node --check)
PASS  accepts a real firmware .uf2 (23040 bytes at 0x10000000)
PASS  refuses an image with nothing at flash offset 0 (the lowest flash address is 0x10001000, not 0x10000000)
PASS  refuses a file that is not a UF2 (no UF2 blocks — is this a .uf2 file?)
```

### The phone

Captured on a **Pixel 9a, Chrome on Android, 2026-08-05**, from
`pflash.html` opened as a `content://` URI out of the Files app. The board was
in BOOTSEL; the file was `exp138.uf2`, sitting on the phone's own storage.

The pre-flight, before anything was picked or written:

```text
exp138.uf2: 46080 bytes, 90 UF2 blocks
pre-flight: 23040 bytes at 0x10000000, boot block present
```

Those are the same numbers `check.sh` gets on a desktop from the same file,
which is the point of the parser being one implementation rather than two.

Then the flash:

```text
image: 23040 bytes at 0x10000000
picked: RP2350 Boot — 2e8a:000f, serial 7FCAF01F5613A90C
  interface 0: class 0x08
  interface 1: class 0xff  <- PICOBOOT
claimed PICOBOOT (interface 1, OUT ep 3, IN ep 4)
IF_RESET: interface cleared
EXCLUSIVE_ACCESS: the drive is ours now
EXIT_XIP: flash is a device again, not memory
FLASH_ERASE: 24576 bytes at 0x10000000 (6 sectors)
WRITE: 23040 bytes in 6 chunks
READ back 256 bytes at 0x10000000: matches
REBOOT2: NORMAL | NO_RETURN

=> The board is running the firmware you chose. Open log.html to watch it say so.
```

Both interfaces of the BOOTSEL composite are visible in that listing, which is
[exp141](../exp141-two-doors-into-the-bootrom/)'s finding arriving as a routine
line in a log: interface 0 is the mass-storage drive Chrome will not touch, and
interface 1 is the door this page went through.

### And the board came up on it

`log.html`, on the same phone, a few minutes later:

```text
Streaming from exp138 what the rom knows — interfaces 0 and 1, endpoint 2 IN.

[    3037 ms] get_sys_info(CHIP_INFO) -> 4
[    3037 ms]   word[0] = 0x00000001
[    3037 ms]   word[1] = 0x00000001
[    3037 ms]   word[2] = 0x5613a90c
[    3037 ms]   word[3] = 0x7fcaf01f
[    3037 ms] get_b_partition(0) -> -17
[    3037 ms]   negative: partition 0 has no B side, or there is no table
[    3037 ms] done. nothing was written; this firmware only reads.
[    8037 ms] idle: the answers above are all of them — see the README to decode
```

**The two halves name the same silicon.** The flashing page reported the
bootrom's serial as `7FCAF01F5613A90C`; the firmware that came up reports its
chip ID as `word[3] word[2]` = `0x7fcaf01f 0x5613a90c`. One number, read twice
by two different pieces of software over two different USB interfaces at two
different times — so the board that was written and the board that booted are
provably the same one, which is otherwise an assumption nobody had checked.

`get_b_partition(0) -> -17` also says this board has **no partition table**, so
its BOOTSEL drive would have accepted a dragged `.uf2` perfectly well. That is
the honest framing of this run: it proves the route works, not that the other
route was broken. exp144 is where the other route is measured.

### The thing that took three tries, and what it means

Android's chooser listed the **same board three times**. Two of those entries
failed at `open()`:

```text
exception: SecurityError: Failed to execute 'open' on 'USBDevice': Access denied.
```

The third made Android put up its own USB permission dialog, and after that it
worked. There is nothing in the names to tell them apart — **the live entry is
the one that asks for permission**. A dead entry costs nothing: the page has not
sent a command at that point, which is why it is safe to work down the list.

That cost two attempts to learn, and it exposed a flaw in this page's own
diagnostics: the line naming the picked device was logged *after* `open()`, so
it said nothing about exactly the attempts that failed. It is logged before the
open now, and a failed open explains what to do instead of quoting a
`SecurityError` at somebody holding a phone.

`docs/platforms.md` carries the same note, because that is where a person
troubleshooting a phone will look.

## Next

Nothing on the update road — [exp145](../exp145-a-drive-of-our-own/) closed it.
This closes the flashing road too, if the phone run confirms it: everything the
`yi26` tool can do to a board's flash, a page can now do from a phone.

**Signing and secure boot remain off both roads.** RP2350 can enforce signed
images, and turning that on burns OTP — irreversible, and that board runs
nothing unsigned ever again. With two boards in total that is a decision to take
deliberately and separately, not as the last step of a road about not bricking
things.
