# exp116-webusb-cdc-log — the log, in a browser

exp115 opened the board and described it. This one **claims** its interfaces,
performs by hand the two control transfers a CDC host has to perform, and
reads the endpoint the log comes out of.

Still one HTML file. Still no firmware changes — the board is printing exactly
what it always printed, and something else is listening.

Needs: any RP2350 board running any firmware from this repository, a Chromium
browser, and on Linux one command before you start.

## On Linux, run `yi26 detach` first

The kernel's `cdc_acm` driver owns these interfaces. That ownership *is*
`/dev/ttyACM0`, and a USB interface has exactly one owner.

**Chrome's WebUSB does not take it away for you.** That was measured rather
than assumed, because the failure gives no hint:

```
claim_interface(0):            FAILED  Busy, errno 16
detach_and_claim_interface(0): OK
```

The kernel is willing and the permission is sufficient. The browser simply
does not do the detach, so `claimInterface` fails with `NetworkError: Unable
to claim interface` and nothing in that sentence points anywhere.

```sh
yi26 detach     # take the interfaces from the kernel
yi26 attach     # give them back
```

Replugging the board or flashing anything also gives them back.

## What it costs while detached

There is no serial port. `yi26 log`, `screen`, `picocom` and every terminal
program stop seeing the board, because the thing they open no longer exists.

Flashing still works, and that took a change to make true. `yi26 bootsel` used
to need `/dev/ttyACM0` to set a baud rate on; it now sends the same
`SET_LINE_CODING` over a control transfer when there is no port. Verified: the
board reached BOOTSEL mode with no `/dev/ttyACM0` in existence. The firmware
cannot tell the difference, because `crates/usb-reboot` reads the line coding
and not the driver that set it.

Without that, detaching would have turned every reflash into a BOOTSEL press.
It did, once, during development.

## The two control transfers

A terminal program does these for you, which is the only reason they look
exotic.

**`SET_LINE_CODING`** carries seven bytes: the rate as a little-endian `u32`,
then stop bits, parity, data bits. For CDC-ACM the rate is nominal — the
firmware does not act on it — **with one exception that matters here**.
`crates/usb-reboot` watches for exactly **1200** and reboots into the
bootloader when it sees it. Sending 1200 from this page would drop the board
into BOOTSEL mid-stream. That is exp105's trick, reachable from a web page,
and it is why the rate in this file is a named constant rather than a number
in an argument list.

**`SET_CONTROL_LINE_STATE`** asserts DTR and RTS. This one is not politeness
and not optional: [`crates/usb-log`](../../crates/usb-log/src/lib.rs) waits
for DTR before it writes a single byte. Without this line the page connects
successfully, claims everything, and then receives nothing, forever.

That gate exists for a reason worth reading in `usb-log`'s own comment:
writing into an IN endpoint nobody is collecting from can wedge this chip hard
enough that `SET_LINE_CODING` stops completing — which means the 1200-baud
reflash stops working and only the button is left.

So the log appearing at all is the proof that DTR was asserted. It is not a
separate thing to check.

## Endpoints are found, not remembered

```js
const ep = alt.endpoints.find((e) => e.direction === 'in' && e.type === 'bulk');
```

exp115 printed interfaces 0 and 1 with the log on `0x82`, and it would have
been easy to write those numbers down. **exp118 adds a function to this
device and moves them.** Code that reads the descriptors keeps working; code
that remembers three numbers reads the wrong endpoint and shows nothing, with
no error.

## Expected output

Captured from a real Pico 2 on Ubuntu, with `exp114` on the board.

```
Streaming from exp114 health tests — interfaces 0 and 1, endpoint 2 IN.

[  339724 ms] broken: FAILED adaptive proportion at 922 after 1024 bits — OUTPUT WITHHELD
[  339725 ms] -> 1 of 2 real sources still permitted to emit; broken source correctly rejected
[  340736 ms] trng  : HEALTHY after 86016 bits (window 0/1024, 0 match ref)
[  340736 ms] adc   : FAILED repetition count at 21 after 23 bits — OUTPUT WITHHELD
[  340736 ms] broken: FAILED adaptive proportion at 922 after 1024 bits — OUTPUT WITHHELD
[  341746 ms] trng  : HEALTHY after 86272 bits (window 256/1024, 129 match ref)

148 lines, 12866 bytes, 41.1 s
```

That is exp114's live output — the same lines `yi26 log` would have shown,
arriving through a browser instead. While this is streaming:

```console
$ ls /dev/ttyACM0
ls: cannot access '/dev/ttyACM0': No such file or directory
```

Same device, two views, one at a time.

## The permission

Granted once per **browser session**, and inherited by every page from the
same `file://` origin — exp115's README works through what that means and what
it costs. If the browser restarts you will be asked again; a reload will not
ask.

## Make it yours

1. Press **Disconnect** and watch the log stop. Then run `yi26 attach` and
   `yi26 log --seconds 5`: the backlog that piled up while nobody held DTR is
   gone, and the count of dropped lines is exp107's design telling you so.
2. Change `BAUD` to `1200`, reload, and connect. The board drops into BOOTSEL
   and the stream dies. You have just triggered exp105 from a web page —
   `yi26 flash` any `.uf2` to come back.
3. Delete the `SET_CONTROL_LINE_STATE` call. Everything still succeeds:
   interfaces claimed, no errors, no output. That silence is what a missing
   DTR looks like, and it is why the call has a comment rather than a
   convenient default.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Unable to claim interface` | `cdc_acm` still owns it | `yi26 detach` |
| Connects, then nothing arrives | DTR was never asserted | The firmware waits for it — see above |
| `yi26 bootsel` says the interface is held | The page has it | Close the tab, then retry |
| `yi26 log` finds no board | You are still detached | `yi26 attach` |
| Board fell into BOOTSEL while streaming | `BAUD` is 1200 | That is exp105; flash anything |
| Blank page after an edit | `file://` caching | The build marker under the title says which; `Ctrl-Shift-R` |

## Next

**exp117** makes the page useful in the direction this track is actually
going: the host types, and the firmware reacts. Same bulk pair, other
direction, and the first time anything in this repository has waited on two
things at once.
