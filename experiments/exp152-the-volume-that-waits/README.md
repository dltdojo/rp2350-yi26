# exp152-the-volume-that-waits — a drive that does not exist until it knows what to say

[exp151](../exp151-the-log-in-any-browser/) put the board's log in **any**
browser and left one thing standing: finding the board still needed WebUSB,
because the address was read out of the log over CDC. A name did not fix it — a
Pixel 9a returns `NXDOMAIN` for `yi26.local`, and the board's own log shows the
question never arrives.

So the board carries the answer on a disk of its own. Plug it in, wait for the
LED, open the drive, tap one file. **No WebUSB, no typing, no bookmark, nothing
downloaded first.**

Six USB interfaces — CDC-ACM two, CDC-NCM two, MSC one — which makes this the
most complex composite in this repository, and the reason
`max-interface-count-8` is set rather than inherited.

## The objection that turned out to be half an objection

[exp137](../exp137-the-volume-that-changes/) measured that a host serving a
**mounted** volume answers file reads out of its own cache: the bytes moved on
the device and the host showed the old ones. An address that arrives ten seconds
after the drive appears would therefore be written into a file nobody ever sees.

That was used to rule the whole idea out, and the person running these
experiments pushed back. exp137 measured the other half too:

> **a fresh mount reads the new volume — the bytes really moved**

A volume that has never been mounted has no cache to answer from. So this
firmware never changes a mounted disk. It reports **NOT READY / MEDIUM NOT
PRESENT** until it has an address — a card reader with no card, which every host
knows what to do with: nothing. Only then does the medium exist, and whatever the
host does next is a **first mount**.

## What is on it

Three files, 64 KiB of SRAM, written once and never rewritten — so there is no
second version for a cache to be stale about.

| File | What it is |
| --- | --- |
| `OPEN.HTM` | one big link to `http://<address>/`, and nothing else. No script. |
| `ADDRESS.TXT` | the same address as plain text, for somebody who would rather read it |
| `README.TXT` | **leads with the order**, because that is the part people get wrong |

The address is **not** in the filename, and that is a constraint rather than a
preference: an IPv4 address needs up to fifteen characters, FAT12's 8.3 names
hold eight and the volume label eleven. Contorting it to fit would have made the
one thing a person reads harder to read.

## Two ways to do it

There is no `run.sh` here. From exp146 onward the interesting half of each
experiment moved into a browser or onto a phone, and a shell script cannot press
those buttons; the walkthrough moved into the README instead — see
[exp147](../exp147-two-firmwares-one-phone/README.md#the-code-is-the-walkthrough).
The desktop half below **is** scriptable — [exp148's `run.sh`](../exp148-a-wire-with-no-address/run.sh)
does the same `nmcli` dance — and a `run.sh` covering it would be welcome.

```sh
./check.sh    # verdict. Static half needs no board; with a board that already
              # has an address it also fetches the page and checks that reading
              # the log did not fill the log
```

### Rebuilding it, if you have the repository

```sh
cargo build --release
elf2flash convert -b rp2350 \
    target/thumbv8m.main-none-eabihf/release/exp152-the-volume-that-waits \
    target/exp152.uf2
yi26 flash target/exp152.uf2            # hands-free on a board already running
                                        # exp105 or later: the 1200-baud watcher
                                        # reboots it, no BOOTSEL press
```

Ubuntu's "shared to other computers" gives this board the same role assignment
Android's Ethernet tethering does — the host is the DHCP server and the router,
the board is a client — so the whole thing is testable on a desk before it costs
anybody a phone. That is why `ask-for-an-address` is not optional here:
[exp150](../exp150-a-page-served-by-the-board/README.md#android-a-wall-and-the-door-beside-it)
measured that a board which assigns itself an address is unreachable from the
browser it is trying to serve.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. `pack.sh` lifts this section verbatim into that zip, so
there is one copy of the procedure and it is this one.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A, LED on GPIO 25) and a USB data cable.
  * Ubuntu with NetworkManager — `nmcli`, which a desktop install already has.
  * `unzip`. `curl` is used once and can be skipped.
  * Any browser at all. Not Chromium in particular: that is the whole point.
  * Nothing else. No udev rule, no `input` group, no root.

1. UNPACK IT.

       unzip exp152-the-volume-that-waits.zip
       cd exp152-the-volume-that-waits

2. PUT THE FIRMWARE ON THE BOARD. Hold the BOOTSEL button down, plug the board
   in, then let go. A drive called `RP2350` appears.

       cp firmware/exp152.uf2 /media/$USER/RP2350/

   The board reboots by itself as the copy finishes, and the drive vanishes.
   That is success, not an error — some file managers report it as one.

3. FIND THE BOARD'S NETWORK INTERFACE. It is named after the experiment.

       nmcli -t -f DEVICE,TYPE,STATE device | grep enx

   Expect a line beginning `enx022600000152:ethernet:` — the name is what
   matters. What follows it may be `disconnected`, `connecting (getting IP
   configuration)` or `connected`, depending on how far NetworkManager has got
   with adopting the new wired device on its own. Step 4 overrides whatever it
   decided, so any of the three is fine.

4. BECOME ITS DHCP SERVER. The board asks for an address and will not invent
   one; until something answers, there is nothing to connect to.

       nmcli connection add type ethernet ifname enx022600000152 \
             con-name yi26-exp152 ipv4.method shared
       nmcli connection up yi26-exp152

   Expect: `Connection successfully activated`, in whatever language your
   machine is set to.

5. LOOK AT THE BOARD BEFORE IT HAS AN ADDRESS. This is the experiment.

       lsblk -o NAME,SIZE,LABEL,MODEL -d | grep sda

   Expect: `sda         0B       exp152 waiting` — a card reader with no card,
   and the LED blinking slowly, which means "still asking".

6. WAIT ABOUT FIFTEEN SECONDS, then look again.

       lsblk -o NAME,SIZE,LABEL,MODEL -d | grep sda

   Expect: `sda        64K YI26 BOARD exp152 waiting`, and the LED blinking
   fast. The medium did not change — it did not exist, and now it does.

7. OPEN THE DRIVE. A desktop Ubuntu has already mounted it. If not:

       udisksctl mount -b /dev/sda

   Note `/dev/sda` and not `/dev/sda1`: there is no partition table, which is
   what FAT12 on a floppy always looked like and what every host still accepts.

8. READ THE ADDRESS OFF THE DRIVE.

       cat "/media/$USER/YI26 BOARD/ADDRESS.TXT"

   Expect: `http://10.42.0.250/` — that exact address, on a machine with no
   other shared connection, because NetworkManager hands out `10.42.0.x` and
   the board pins itself to `.250` of whatever subnet it is given.

9. OPEN THE PAGE. Either double-click `OPEN.HTM` on the drive and tap the big
   blue link, or:

       curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://10.42.0.250/

   Expect: `200` and a few thousand bytes. In the browser you get the board's
   own log, dark background, refreshing itself every three seconds, headed
   `10.42.0.250 — chip 0x…` and `up N s, M request(s) answered`.

   **That page is the experiment.** It came off the board, over a USB cable,
   into a browser that was never asked for a permission and never needed
   WebUSB. The LED is solid now.

10. PUT THE MACHINE BACK.

       udisksctl unmount -b /dev/sda
       nmcli connection delete yi26-exp152

IF IT DOES NOT WORK
  * `sda` never leaves `0B` — nothing is answering DHCP. Check step 4 with
    `nmcli connection show --active`; `yi26-exp152` has to be listed.
  * No `enx…` device at all — the board is not running this firmware, or the
    cable is charge-only. A charge-only cable is the commonest single cause of
    everything here.
  * The drive appears but the link goes nowhere — you are on a machine with
    another shared connection, so the subnet is not `10.42.0.x`. `ADDRESS.TXT`
    is right and this text is wrong; believe the file.
  * The page loads but `request(s) answered` never rises — that is your
    browser's cache. The count is on the page precisely so this is visible.

### On a phone, which is the point

**The order matters, and it is not the obvious one.** Ethernet tethering is
greyed out until something is plugged in, so it cannot be turned on first:

1. plug the board in
2. turn on Ethernet tethering **straight away** — Settings › Network & internet
   › Hotspot & tethering › Ethernet tethering
3. wait for the LED to blink fast; the drive appears then
4. open it in the Files app and tap `OPEN.HTM`

Leaving a long gap at step 2 is what goes wrong. The board keeps asking forever,
but a host told "no medium" for long enough may stop looking. `README.TXT` on
the drive says all of this, because the person who needs it is holding a phone
and not this repository.

## Expected output

Captured on Ubuntu, 2026-08-05, on a Pico 2 flashed hands-free by
`yi26 flash` — no BOOTSEL press anywhere in this run.

**Before the address — a reader with no card:**

```console
$ lsblk -o NAME,SIZE,LABEL,TRAN,MODEL -d
NAME      SIZE LABEL      TRAN   MODEL
sda         0B            usb    exp152 waiting
```

**The board's own account of the same minute:**

```console
$ yi26 log --seconds 20
[      44 ms] exp152 up. A log over HTTP, and a disk that waits until it can point at it.
[      45 ms]   asking for an address — whoever is on the other end is the server here.
[      45 ms]   LED: dark=no link, slow=still asking, fast=I have an address, SOLID=page served.
[      45 ms] 0 ms  link DOWN — nothing has claimed the NCM interface
[     445 ms] 400 ms  link UP, still asking. TURN ON Ethernet tethering — Settings > Network &...
[    1472 ms] REQUEST SENSE  -> key 2 asc 3a
[   11710 ms] volume: laid down for 10.42.0.250, 125 clusters used — the medium exists now
[   11710 ms] REQUEST SENSE  -> key 6 asc 28
[   15597 ms] 15552 ms  I am at http://10.42.0.250/ — 0 request(s) served
[   15597 ms]         gateway 10.42.0.1 — there is a way out of here
```

Those two sense codes are the experiment. `key 2 asc 3a` is **NOT READY / MEDIUM
NOT PRESENT**, answered to every readiness poll for eleven seconds. `key 6 asc
28` is **UNIT ATTENTION / medium may have changed** — *something happened you
were not told about* — and it is what turns the host's next look into a first
mount.

**After the address:**

```console
$ lsblk -o NAME,SIZE,LABEL,TRAN,MODEL -d
NAME      SIZE LABEL      TRAN   MODEL
sda         64K YI26 BOARD usb    exp152 waiting

$ ls -l "/media/$USER/YI26 BOARD"
-rw-r--r-- 1 cyline cyline   21 ADDRESS.TXT
-rw-r--r-- 1 cyline cyline  762 OPEN.HTM
-rw-r--r-- 1 cyline cyline 1193 README.TXT

$ cat "/media/$USER/YI26 BOARD/ADDRESS.TXT"
http://10.42.0.250/

$ curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://10.42.0.250/
200 2871
```

Ubuntu mounted it read-only and unprompted, and following the drive's own link
gets the board's log in a browser.

**And the verdict, board attached and addressed:**

```console
$ ./check.sh
PASS  builds (154624 byte .uf2)
...
PASS  the board reports NOT READY / MEDIUM NOT PRESENT before it has an address
PASS  the volume is laid down exactly once — there is no second version
PASS  the address is in the contents, not squeezed into an 8.3 name
NOTE  enumerated as: exp152 the volume that waits
PASS  the board has an address and says so — http://10.42.0.250
PASS  it served its own log over HTTP (65 lines, 0 of them about serving)
PASS  and reading it did not fill it with the reading
```

38 static checks and 3 with the board, exit 0.

## The reader's own footsteps, for the third time

Reading the log over HTTP logs lines about reading the log over HTTP, and the
page refreshes itself. Measured in exp151: **58 of 64 retained lines were the
reader's own arrival.** The log had been erased by the act of reading it.

exp152 pays for the same pattern a third time, one layer lower. Opening the
drive costs about a hundred `READ(10)`s, and the first phone to run this saw its
own arrival and nothing else. So `usb-log` grew `log_transient!` — say it to the
serial port, do not keep it — and the per-command SCSI chatter, the per-query
mDNS chatter and the HTTP server's own lines all use it. `check.sh` guards all
three, in Python rather than `grep`, because the calls span lines.

The retained ring itself is behind a `retain` feature that is **off by default**,
so every other experiment's `usb-log` is byte-for-byte what it always was.

## What this experiment does not do

- **It does not verify anything about a browser without WebUSB.** `check.sh`
  says so in its last line. Opening that address on a phone whose browser has no
  WebUSB at all is the entire point, and no script here can do it.
- **It does not survive a re-plug into a different network** with the same
  address. The address is pinned into whatever subnet it is given — mask
  arithmetic, refusing the network and broadcast addresses — so the *subnet* is
  the stable part and the lease is not.
- **It never writes flash**, and the volume is declared read-only. A host that
  honours that never writes to it; one that tries gets DATA PROTECT.

## Make it yours

- Turn `retain` off and watch the page serve an empty ring — the 6 KiB that
  feature costs is visible in the UF2.
- Drop `MEDIUM_MAY_HAVE_CHANGED` and see how long your host takes to notice a
  disk it was told nothing about. That is exp137's finding from the other side.
- Put a second file on the volume. `crates/fat12` lays it down and runs
  `cargo test` on any machine, board or not.

## Troubleshooting

**`sda` stays at `0B` forever.** Nothing is handing out an address. On Ubuntu
that means the shared connection is not up — `nmcli connection show --active`
should list `yi26-exp152`. On a phone it means tethering was turned on too late,
or not at all.

**The drive appears but the link in `OPEN.HTM` goes nowhere.** Check the log for
`OPEN.HTM filled its buffer exactly` — a `Cursor` truncates in silence, and a cut
page renders as a working button with half an address on it. That happened once,
and the evidence was a directory listing saying `OPEN.HTM 640` against a buffer
declared as 640, which nobody compared.

**The page loads but the request count never rises.** That is a cache. The count
is on the page precisely so this is visible.

**The board is enumerated but `yi26 log` shows nothing.** `yi26 doctor`, and see
[the tools README](../../tools/README.md).

## Next

The road this finishes is [the network road](../README.md#the-network-road): a
person with a phone, no WebUSB and nothing installed can now read this board's
log. What is not solved is the browser *finding* the board without the drive —
`yi26.local` is answered by the firmware and not asked for by Android.
