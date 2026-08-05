# exp123-bot-framing — what a host asks a disk

The board declares a mass-storage interface and declines every command it
receives, printing each one first. **Nothing here pretends to be a disk.** The
point is to read the interrogation before answering any of it.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## Three phases and two structures

USB mass storage has almost no protocol of its own:

```text
  CBW   'USBC'  tag  length  flags  lun  cblen   [ 16 bytes of SCSI ]
  data  (maybe, in whichever direction the flags say)
  CSW   'USBS'  tag  residue  status
```

Thirty-one bytes out, an optional data phase, thirteen bytes back. That is
Bulk-Only Transport in full. The interesting part is the payload: a **SCSI**
command block, the same SCSI that talks to a hard disk over a cable that has
nothing to do with USB. USB is carrying somebody else's protocol, and mass
storage is mostly the envelope.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. This experiment
declares a disk and then refuses every command about it, so that you can read
how your host decides whether a disk is there.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable.
  * Ubuntu. `cat`, `stty`, `lsblk` and `ls` are already there. No `yi26`.

1. UNPACK IT.

       unzip exp123-bot-framing.zip
       cd exp123-bot-framing

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go:

       cp firmware/exp123-bot-framing.uf2 /media/$USER/RP2350/

3. CHECK THAT NO DISK APPEARED.

       sleep 7
       lsblk -o NAME,SIZE,LABEL,MODEL -d | grep -v loop

   Expect **your own disks and nothing else** — no `sda`, no drive icon, no
   dialog. Good. The board declared a mass-storage interface and your host
   decided against it.

4. CHECK THAT THE HOST TRIED ANYWAY.

       ls /sys/bus/usb/drivers/usb-storage/

   Expect a device among the entries, something like `1-7:1.2`. **The driver
   bound.** Your host did not ignore the board; it attached its storage driver,
   asked questions, disliked the answers, and stopped short of creating a block
   device. Those are two different outcomes and only the log tells them apart.

5. READ WHAT IT ASKED.

       stty -F /dev/ttyACM0 -icrnl
       timeout 6 cat /dev/ttyACM0

   Expect:

       [      37 ms] exp123 up. A disk is declared. Nothing here is a disk.
       [    1422 ms] cbw #1: tag 00000001 lun 0 IN  36 bytes
       [    1422 ms]    12 00 00 00 24 00  <- INQUIRY
       [    1423 ms] cbw #2: tag 00000002 lun 0 IN  18 bytes
       [    1423 ms]    03 00 00 00 12 00  <- REQUEST SENSE

6. COUNT WHAT IT DID AND DID NOT ASK. In six seconds this host sent eight
   command blocks, and only two kinds:

       4 x INQUIRY          "what are you"
       4 x REQUEST SENSE    "why did that fail"

   **It never asked TEST UNIT READY, never READ CAPACITY, never READ.** It
   asked what the device was, was refused, asked why, was refused, and gave
   up — four times, because that is how many retries this driver allows.

   That is the shape of the negotiation, and you now have it from both ends at
   once: the host's decision in step 3, the driver's attachment in step 4, and
   the actual conversation in step 5. A disk exists when the host says it
   does, and the host says so only after being answered.

IF IT DOES NOT WORK
  * A disk DOES appear — you are not running this firmware. Check the first
    log line.
  * `/sys/bus/usb/drivers/usb-storage/` is empty or missing — your host binds
    something other than `usb-storage` to mass storage. The experiment still
    works; the names in step 4 are your system's, not this firmware's.
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * The log shows no `cbw` lines at all — read sooner. The whole negotiation
    is over within two seconds of plugging in, and the kernel buffer only
    holds the last little while.

## Expected output

Captured from a real Pico 2 on Ubuntu, in the two seconds after the board
re-enumerated:

```text
[      37 ms] exp123 up. A disk is declared. Nothing here is a disk.
[    1454 ms] cbw #1: tag 00000001 lun 0 IN  36 bytes
[    1454 ms]    12 00 00 00 24 00  <- INQUIRY
[    1455 ms] cbw #2: tag 00000002 lun 0 IN  18 bytes
[    1455 ms]    03 00 00 00 12 00  <- REQUEST SENSE
[    1709 ms] cbw #3: tag 00000003 lun 0 IN  36 bytes
[    1709 ms]    12 00 00 00 24 00  <- INQUIRY
[    1710 ms] cbw #4: tag 00000004 lun 0 IN  18 bytes
[    1710 ms]    03 00 00 00 12 00  <- REQUEST SENSE
...
[   20037 ms] idle: 8 commands received, all refused
```

**INQUIRY, then REQUEST SENSE, four times over, then silence.**

That pairing is how an operating system thinks. It asks *what are you*; the
answer fails; it asks *why did that fail*; that fails too, so it learns
nothing and tries again. After four rounds it concludes there is no usable
medium and stops. The whole exchange takes under a second.

Notice what it never asks. No READ CAPACITY, no READ(10), no MODE SENSE —
those come later, and only to a device that got past INQUIRY. The order is
not arbitrary: each question is asked because the previous one was answered.

## What the kernel did about it

The firmware's account is not evidence. This is the operating system's:

```text
1-7:1.0      class=0x02  cdc_acm
1-7:1.1      class=0x0a  cdc_acm
1-7:1.2      class=0x08  usb-storage

host2 exists, with 0 targets under it
```

A SCSI host with nothing under it is the whole result in one number.
Declaring the **class** was enough for the kernel to load its storage driver
and build a host; answering nothing was enough for it to find no disk to put
in it.

Compare exp122, where the vendor interface is left with `(no driver bound)`.
A class is an invitation.

The kernel log says the same thing in its own words:

```text
usb-storage 1-7:1.2: USB Mass Storage device detected
scsi host2: usb-storage 1-7:1.2
```

and then nothing. No `Direct-Access`, no `[sdX] Attached SCSI removable disk`
— both of which appear a few lines earlier for the RP2350 bootloader, which
*is* a disk and answers when asked.

## "Answer nothing" needed defining

The plan for this experiment said *answer nothing*. Taken literally that is
dangerous rather than minimal.

A host whose bulk transfer never completes waits, times out, issues a
Bulk-Only Mass Storage Reset, retries, and eventually resets the whole USB
device — **taking the CDC interface with it**, on a loop, and turning
reflashing into a matter of catching a gap. The experiment would have made
itself hard to escape from.

Stalling the endpoint is the specification's answer for "I cannot do that",
and this driver does not offer it: `endpoint_set_stalled` lives on the `Bus`,
which `UsbDevice::run()` owns.

So the reply here is a **well-formed refusal**:

- the data phase is ended immediately with a zero-length packet, which is a
  short transfer and tells the host to stop waiting;
- the status wrapper says `Command Failed` with the full requested length as
  residue — *I did none of it*, stated precisely rather than by silence.

Every phase completes, nothing waits, and the host gives up politely. The
evidence that it worked is in the timings above — four rounds inside a second
rather than a timeout storm — and in the CDC port still being there
afterwards.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the interface is built by hand out of
  `builder.function()`, exactly as exp122's vendor interface was. `embassy-usb`
  has no MSC class, which is why this track is four experiments rather than
  one.

## Two ways to do it

```sh
./run.sh      # guided: flash, read the interrogation, ask the kernel what it did
./check.sh    # verdict: driver bound, host built, zero targets, port intact
```

## Make it yours

1. Change `CSW_COMMAND_FAILED` to `0x00` — Command Passed — and watch the host
   accept a successful INQUIRY that returned no data, then get further and
   fail somewhere less obvious. Wrong answers are worse than refusals.
2. Delete the zero-length packet in the data phase and reflash. This is the
   failure this experiment was designed around, so do it with the board in
   front of you and `yi26 bootsel` ready.
3. Add opcodes to `opcode_name` and plug the board into a different operating
   system. The sequence a host uses to decide a disk exists is not standard
   and is worth seeing more than one of.
4. Count the milliseconds between retries. Four attempts, then it stops — that
   number is a policy decision inside `usb-storage`, not a specification.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No `cbw` lines at all | Nothing re-enumerated the board since boot | Flash it again; the interrogation happens at enumeration |
| `/dev/ttyACM0` keeps disappearing | The host is resetting the device | The refusal is malformed — check the CSW tag and residue |
| A block device appeared | Something answered | Not this experiment's firmware; check `yi26 port --json` |
| `not a CBW: N bytes` | The host lost phase | Usually follows a malformed reply to the previous command |

## Next

**exp124** starts answering — enough INQUIRY and READ CAPACITY for the host to
agree a disk is there. No filesystem yet: an unformatted volume is the goal,
and the host complaining that it cannot read a partition table is what success
looks like.
