# exp161-one-port-four-doors — a URL starts meaning something

[exp150](../exp150-a-page-served-by-the-board/) served a page over the USB
link and read the request only to throw it away.
[exp151](../exp151-the-log-in-any-browser/) put the log on that page and threw
the request away just the same. Both said, in the same comment, why:

> Parsing a request line means parsing untrusted input in a firmware, and every
> path through this server returns the same page, so there is nothing a path
> could select. exp151 is where a URL starts to mean something, and that is
> where the parser belongs.

This is that experiment. Four paths on one port:

```text
  /          what is on this board, and links to the rest
  /log       the retained log — exp151's page, unchanged
  /status    the same facts as JSON, for something that is not a person
  /trng      bytes from the hardware random number generator
```

Needs: any RP2350 board, the exp102 toolchain, and a host that shares its
connection. No browser, no phone, and **nobody in the room** — see
[Which of these can I do right now](../README.md#which-of-these-can-i-do-right-now).
This is the first experiment on the network road that a shell can check
completely.

## What it is for

One USB cable, one TCP port, several services — chosen by URL rather than by
which device node you opened. That is the arrangement this experiment
demonstrates, and it is worth being precise about what it wins, because the
obvious summary is wrong.

**The obvious summary:** "USB CDC ports are scarce, so use HTTP paths instead."
This repository has not measured that and it is not true — a composite can
carry a second CDC function, and **five** USB interfaces is the most this
repository has enumerated at once ([exp152](../exp152-the-volume-that-waits/),
[exp155](../exp155-who-else-can-knock/)) with the host taking it — CDC-ACM two,
CDC-NCM two, mass storage one. Three experiments here said six until somebody
counted a mass-storage function's two endpoints and noticed they are one
interface.

**What this repository actually measured**, twice, on hardware:

| | CDC | HTTP over one NCM link |
| --- | --- | --- |
| Who may read it | **exactly one owner** — [exp122](../exp122-vendor-bulk/) established it, [exp131](../exp131-the-volume-is-the-app-drawer/) was stopped dead by it | as many clients at once as the stack has sockets — four here |
| How a second job is added | another function: two more interfaces, another device node, another thing to tell apart on the host | another path: a match arm |
| What the host must do | bind a driver, and you must know which `/dev/ttyACM*` is which | nothing — an address and a browser |
| Which browsers can reach it | Chromium only, behind a permission dialog (WebUSB) | any browser at all |
| What it costs the firmware | a queue | TCP/IP, DHCP, mDNS, an HTTP parser — a 149,504-byte image against exp147's 45,568 |
| What it costs you elsewhere | nothing | `http://` is not a secure context, so **this origin can never also use WebUSB** |

So the axis is **ownership against dispatch**. exp131 is the clearest case: its
appliance page held the only CDC pair, so the log page could not open at all,
and the fix cost a whole experiment ([exp133](../exp133-a-page-per-job/)). Here
two clients reading two different things is the default and takes no design at
all.

## The first thing this had to get right: a truncation is not a 404

A TCP read returns whatever has arrived. Nothing promises a whole request line
is in it, and a parser that treats `GET /sta` as a request for `/sta` gives an
answer that depends on how the host's stack split the packet.

So [`crates/http-route`](../../crates/http-route/) has three outcomes and not
two — complete, **incomplete**, refused — and the firmware waits when it is
told to wait. The two tests that matter cut a real request at every offset:

```text
  every_prefix_of_a_good_request_is_incomplete   0..32 bytes → Incomplete, always
  a_refusal_never_arrives_early                  a DELETE is refused when the line ends, not before
```

Measured on the board, with the request deliberately cut in half and the two
halves 600 ms apart:

```console
$ exec 3<>/dev/tcp/10.42.0.250/80
$ printf 'GET /sta' >&3 ; sleep 0.6 ; printf 'tus HTTP/1.1\r\n\r\n' >&3
$ cat <&3
{"chip":"9952f83a9b934884","up_ms":84024,"link":true,"address":"10.42.0.250",
 "gateway":"10.42.0.1","served":{"index":2,"log":2,"status":4,"trng":8,
 "refused":4},"log_lines_lost":0}
```

A half-line that never finishes is not held forever either — the worker gives
up after two seconds, says so, and goes back to listening:

```text
[  123859 ms] http: connection from Some(Endpoint { addr: Ipv4(10.42.0.1), port: 42800 })
[  125860 ms] http: no request line within 2 s
```

The parser refuses more than it accepts, and every refusal is a decision rather
than an omission: no percent-decoding (`/%6Cog` is **not** `/log`), no dot
segments, origin-form targets only, `GET` and `POST` only. It reads the request
line and stops — no headers at all, which means **no `Host:` validation**, and
that gap has a name (DNS rebinding) and belongs to the experiment that has
something worth rebinding to.

```console
$ curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.250/nope        # 404
$ curl -s -X POST -o /dev/null -w '%{http_code}\n' http://10.42.0.250/log # 405
$ curl -s --path-as-is 'http://10.42.0.250/%6Cog'
400 — path is too long or is not plain ASCII without % or ..
$ curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.250/log/        # 200
```

A well-formed path that names nothing is a **404**; a line that could not be
understood is a **400**. Keeping those apart is what makes the log worth
reading: one of them means "you asked for something that is not here" and the
other means "I could not tell what you asked".

## The second thing, and the one worth the experiment: multiplexing is free
## until something is shared

Four clients asking four different questions at the same instant, all served:

```console
$ for p in "" log status "trng?n=8"; do curl -s -o /dev/null \
      -w "%{http_code} %{time_total}s /$p\n" http://10.42.0.250/$p & done; wait
200 0.010249s /status
200 0.013747s /
200 0.015415s /trng?n=8
200 0.019695s /log
```

That is what an async executor is for, and it is the part that looks like magic
in a demo. Now ask three clients for the *same* thing — 1 KiB of hardware
randomness, from the one TRNG this chip has:

```console
$ for i in 1 2 3; do curl -s http://10.42.0.250/trng?n=1024 | sed -n 2p & done; wait
sampling took 220899 us; waiting for the one TRNG took      9 us
sampling took 225514 us; waiting for the one TRNG took 221259 us
sampling took 224486 us; waiting for the one TRNG took 450273 us
```

A queue, exactly one draw long each time. The sampling cost is constant; the
**waiting** is what the second and third client pay, and it is reported
separately from the work for precisely that reason — one "elapsed" number could
not tell those two apart.

And the door that shares nothing is not slowed by the door that does. `/status`
requested while a 1 KiB draw was in flight:

```console
$ curl -s -o /dev/null -w '%{time_total}s\n' http://10.42.0.250/status
0.003772s
```

**The URL space is not what runs out. The peripheral is.** Four paths cost four
match arms; a fifth client for one TRNG costs a queue. That is the thing worth
carrying out of this experiment, and it is invisible in any demonstration with
only one door in it.

> A number that corrected a prediction while this was being written: 8 bytes
> cost 5.8 ms and 1024 bytes cost 220 ms, so a kilobyte is **not** 128 times
> eight bytes. Most of the small draw is the cost of *asking* — 728 µs per byte
> in eights, 213 µs per byte in kilobytes. The estimate written into the source
> before it was measured said 0.7 s, and the board said 0.22 s.

## Running it

The board is a DHCP client — the same arrangement exp151, exp152 and exp153
use, and for the reason exp150 measured: a board that assigns itself an address
is unreachable from the browser it is trying to serve. So the host has to be
the one sharing.

```sh
cargo build --release
elf2flash convert -b rp2350 \
    target/thumbv8m.main-none-eabihf/release/exp161-one-port-four-doors \
    target/exp161.uf2
yi26 flash target/exp161.uf2

# the interface is named after the experiment
nmcli connection add type ethernet ifname enx022600000161 \
      con-name yi26-exp161 ipv4.method shared
nmcli connection up yi26-exp161

yi26 log --seconds 30        # it prints the address, and keeps printing it
./check.sh
```

`ipv4.method shared` is the whole of it: NetworkManager runs the DHCP server
and the masquerade, and **it needs no `sudo`**. Put it back with
`nmcli connection delete yi26-exp161`.

The address takes about 23 seconds to arrive on this host, and the board says
so while it waits. It then **pins itself** to `.250` on whatever subnet it was
given, which is exp151's trick and the reason a bookmark keeps working:

```text
[   23601 ms] pinning: was given 10.42.0.216/24, taking 10.42.0.250 instead
[   23601 ms]   the subnet is the stable part; the lease is not. Bookmark the new one.
[   23648 ms] 23602 ms  I am at http://10.42.0.250/ — 0 request(s) served
```

## The LED is untouched, and that was a decision

Four states, exactly as [exp153](../exp153-out-through-the-phone/) left them:
dark, slow, fast, solid. It would have been easy to let a page drive it — that
is the demonstration everybody builds first — and it would have spent the one
instrument this whole road is read with on a phone, where there is no log to
read and nothing to install
([`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md)).

**Nothing on this board changes because of an HTTP request.** Every door here
reads, and `check.sh` enforces it rather than trusting it. The moment one of
them writes, the question stops being *which path* and becomes *who is allowed
to ask* — and that question deserves a measurement, not a paragraph. It is
exp155's.

## Expected output

This experiment was renumbered from **exp154** on 2026-08-21, when the branch it
was written on met a different exp154 already on `main`. Four things carry the
number and all four moved: the USB product string, the USB serial, the first log
line, and the two MAC addresses — which is how the host names the interface, so
`enx022600000154` became `enx022600000161`. The last of those was found by
flashing and looking, not by reading: the board came up as exp161 and brought up
an interface still called `...154`.

`./check.sh`, captured on Ubuntu against a real Pico 2, 2026-08-21, on the
renumbered image:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  builds (150016 byte .uf2)
PASS  linked at 0x10000000 — an ordinary image
PASS  carries the 1200-baud reboot watcher — the next flash is hands-free
PASS  crates/http-route passes its own tests
PASS  crates/log-ring passes its own tests
PASS  crates/mdns passes its own tests
PASS  the request line is parsed, not discarded
PASS  no request is answered without being read
PASS  a request that has not finished arriving is waited for, not answered
PASS  ...and a host-side test cuts a real request at every offset to prove it
PASS  ...and the same for a request that will be refused
PASS  %-escapes and .. are refused rather than resolved
PASS  / has an arm of its own, and the table agrees
PASS  /log has an arm of its own, and the table agrees
PASS  /status has an arm of its own, and the table agrees
PASS  /trng has an arm of its own, and the table agrees
PASS  a well-formed path that names nothing is a 404, not a 400
PASS  no route changes anything on the board — every door reads
PASS  POST is refused with a 405 rather than silently treated as a GET
PASS  the one TRNG is shared behind a lock, not duplicated
PASS  the wait for the lock is reported apart from the sampling time
PASS  sample_count is 1000 — exp109's number, not the driver's 25
PASS  the LED still means what exp153 left it meaning
PASS  nothing the HTTP server says about itself is retained
PASS  ...including the /trng timings, which are the noisiest thing here
PASS  no script in any page — they are for whatever browser somebody has
PASS  log text is escaped before it becomes HTML
PASS  every page carries the same four links — a door is no use unnamed
PASS  the board asks for its address — exp150 measured that the other way is unreachable
NOTE  enumerated as: exp161 one port four doors
PASS  the board has an address and says so — http://10.42.0.250
PASS  four paths answered at once: 200 200 200 200
PASS  /status is JSON and carries a count per door — "served":{"index":1,"log":1,"status":2,"trng":1,"refused":0}
PASS  a lone /trng?n=1024: sampling took 228948 us; waiting for the one TRNG took 5 us
PASS  two at once both completed — one waited for the other, and neither failed
NOTE  /status while the TRNG was busy: 0.003013s
NOTE  what no script here can do: nothing. This is the first experiment on
      the network road whose whole claim a shell can check.
```

The image is 150016 bytes here and was 149504 when this was exp154. Three
strings and two MAC constants moved it by one flash page, which is worth
knowing before assuming a rename is free.

The `served` counts are lower than the 2026-08-06 run under the old number —
`{"index":4,"log":4,"status":10,"trng":13,"refused":4}` then, `{"index":1,...}`
now — because that board had been poked at by hand first and this one was
flashed minutes earlier. The counts are a tally of what this board has answered
since boot, not a property of the firmware, which is exactly what the `/status`
door is for. The TRNG numbers reproduced: 228948 us of sampling against 231095,
and a 5 us wait against 9 us, on the same one peripheral.

## What this experiment does not answer

- **Who else can reach these doors.** The responses carry
  `Access-Control-Allow-Origin: *`, inherited from exp151, so any page that can
  route here may read them. Everything readable is a chip ID, an uptime, a
  counter, this firmware's own log and some random bytes — which is why that is
  a loosening and not yet a problem. It becomes one the moment a route writes.
- **`Host:` validation**, and therefore DNS rebinding.
- **Two boards.** Nothing here has ever had two RP2350s on one link, and
  nothing claims to — see [Platform](../README.md#platform).
