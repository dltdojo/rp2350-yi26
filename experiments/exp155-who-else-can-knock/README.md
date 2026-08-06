# exp155-who-else-can-knock — the first request that changes something

[exp154](../exp154-one-port-four-doors/) put four doors on one port and every
one of them read something. It said why it stopped there:

> The moment one of them writes, the question stops being *which path* and
> becomes *who is allowed to ask* — and that question deserves a measurement,
> not a paragraph.

This is the measurement. The board's LED can now be set over HTTP, two ways,
and the difference between them is the whole experiment.

```text
  GET|POST /led/<on|off|slow|fast|auto>          nothing is consulted
  POST     /control/led/<…>  + X-Yi26-Control    and an Origin that is mine
  OPTIONS  /control/led/<…>                      the question a browser asks first
  GET      /probe                                the same three knocks, from here
```

Needs: any RP2350 board, the exp102 toolchain, a host that shares its
connection, and — for the second half — a browser. Nobody has to be in the
room: the board reports the LED's state in `/status`, so **the subject is a
browser and the instrument is the board**.

## And a drive, because a page nobody can find controls nothing

[exp154](../exp154-one-port-four-doors/) could do without one. This experiment
cannot, and the reason is the whole point of the road: **its audience is
somebody holding a phone.** Three things this repository measured make the
address undiscoverable there otherwise —

- `yi26.local` **does not resolve on the phone** (exp151: the responder is
  correct, answers on Ubuntu, and the query never arrives).
- A phone's address bar **searches for what you type**, `http://` and all.
- A `content://` page may not `fetch` or `<iframe>` an `http://` URL — mixed
  content — so a page out of a zip cannot reach the board. **Only a navigation
  goes through** (exp150).

So the address has to arrive already tappable, and [exp152](../exp152-the-volume-that-waits/)'s
mechanism is carried over unchanged: a 64 KiB read-only volume that **does not
exist until the board has an address**, with `OPEN.HTM` (one link), `ADDRESS.TXT`
(the same thing as text) and `README.TXT` on it.

```console
$ lsblk -no LABEL,MODEL /dev/sda
YI26 BOARD exp155 knocking

$ ls "/media/cyline/YI26 BOARD"
ADDRESS.TXT  OPEN.HTM  README.TXT

$ cat "/media/cyline/YI26 BOARD/ADDRESS.TXT"
http://10.42.0.250/
```

`check.sh` compares the address written on the drive with the address the board
actually answers at. Nobody had checked that before, and it is exactly the class
of thing a phone cannot be asked about afterwards.

### Five interfaces, and it took a question to count them

```console
$ lsusb -d 1209:0001 -v | grep -E 'bNumInterfaces|bInterfaceClass'
    bNumInterfaces          5
      bInterfaceClass         2 Communications     ┐ CDC-ACM: the log, and the
      bInterfaceClass        10 CDC Data           ┘ 1200-baud reboot watcher
      bInterfaceClass         2 Communications     ┐ CDC-NCM: the network
      bInterfaceClass        10 CDC Data           ┘
      bInterfaceClass         8 Mass Storage         one interface, two endpoints
```

Three experiments in this repository said **six**, in three places — exp152's
index row, and a code comment in exp152 and exp153 reading *"the fifth and sixth
interfaces"*. A mass-storage function's two **endpoints** had been counted as
two interfaces. All three are corrected, and the number above is `lsusb`'s
rather than anybody's arithmetic.

The CDC pair is worth defending while we are counting: it is not there for
comparison. It carries the 1200-baud reboot watcher — which is why every flash
in this repository since exp105 needs nobody at the BOOTSEL button — and it is
what `yi26 log` reads, which `AGENTS.md` requires an agent to use instead of a
browser.

## What most people expect, and what a browser actually does

The worry about putting control on HTTP is usually stated as "somebody else on
the network could do it". The real answer is narrower, closer to home, and much
more useful: **the danger is the browser the owner is already running**, and the
thing that stops it is not the method and not the network.

The same page — byte for byte, `/probe`, copied off the board — was served from
a local origin (`http://127.0.0.1:8000` by hand, `:8155` when `check.sh` does it)
and opened in Chrome. Three knocks:

| | from another origin | from the board's own origin |
| --- | --- | --- |
| `<img src="…/led/fast">` | **the LED changed** | the LED changed |
| cross-site form `POST …/led/slow` | **the LED changed** | the LED changed |
| `fetch` `POST …/control/led/off` with `X-Yi26-Control` | **refused, nothing moved** | the LED changed |

Measured on Ubuntu, 2026-08-06, with the board's own log as the witness:

```text
[   69309 ms] led: now fast — asked over GET by no stated origin
[   69334 ms] led: now slow — asked over POST by http://127.0.0.1:8000
[   69344 ms] led: refused a preflight from http://127.0.0.1:8000
```

Three lines, three lessons:

**1. CORS never stopped the request.** It governs whether a page may *read* the
reply. An `<img>` does not need to read anything — it needs the request to be
sent, and it was. A board whose state can be changed by a `GET` can be changed
by any page anywhere that can route to it, and the page does not even have to
be able to see whether it worked.

**2. The first line says `no stated origin`, and that is worse than it looks.**
A browser does not send `Origin` on a plain no-CORS `<img>` GET. So the open
door cannot refuse its caller *and cannot even name it*. There is no log line
to go back to afterwards. The form `POST` on the next line does carry an
origin — so a guard could have refused that one — but the open door does not
look, which is what makes it the open door.

**3. What stopped the third knock was being asked first.** `X-Yi26-Control` is
not a secret; its value is `1` and it is written in this README. Its *name* is
the mechanism: a header outside the handful CORS calls "simple" makes the
browser send an `OPTIONS` preflight before anything happens, and a preflight is
a question the board gets to answer. It answered by saying nothing — no
`Access-Control-Allow-Origin` — and the browser treated silence as no.

```console
$ curl -s -i -X OPTIONS -H "Origin: http://elsewhere.example" \
       http://10.42.0.250/control/led/on | head -3
HTTP/1.0 403 Forbidden
Content-Type: text/plain; charset=utf-8
Content-Length: 90

$ curl -s -i -X OPTIONS -H "Origin: http://10.42.0.250" \
       http://10.42.0.250/control/led/on | head -5
HTTP/1.0 204 No Content
Content-Type: text/plain; charset=utf-8
Content-Length: 0
Access-Control-Allow-Origin: http://10.42.0.250
Vary: Origin
```

## The honest limit, said before somebody discovers it

**An origin check is worth exactly what the browser enforcing it is worth.**
`curl` will send any `Origin` you like, and so will any program on the host:

```console
$ curl -s -X POST -H "X-Yi26-Control: 1" -H "Origin: http://10.42.0.250" \
       http://10.42.0.250/control/led/off
led: off
```

That is not a hole to patch here, it is the shape of the thing. The guard
defends against *a page in a browser*, which is the attacker that arrives
without anybody choosing it. It does not defend against a program on the
machine — and neither does a USB CDC port, which any process can open with no
gesture at all. This repository has never had a transport that did.

What would go further — a token the page is given and a program cannot guess,
`Host:` validation, TLS — is a different experiment and a much larger binary.
TLS in particular is [off this road](../README.md#the-network-road) and stays
there.

## The guard is two conditions, and either alone is nothing

```console
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
       -H "X-Yi26-Control: 1" -H "Origin: http://elsewhere.example" \
       http://10.42.0.250/control/led/off
403                       # the right header, the wrong origin

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
       -H "Origin: http://10.42.0.250" http://10.42.0.250/control/led/off
403                       # the right origin, no header — so no preflight, so no question
```

The second one matters more than it looks. Without the header there is no
preflight, and without a preflight the board is *told* rather than *asked* —
so refusing that request is refusing the shape of it, not the origin in it.

### A `null` that was nearly granted

The first version echoed the origin back on every allowed response, and for a
request with no `Origin` at all it wrote:

```text
Access-Control-Allow-Origin: null
```

`null` is not "no origin". It is the origin a sandboxed iframe and a `file://`
page carry — so that line granted precisely the callers least able to say who
they are. Caught by reading what `curl` was actually sent rather than what the
code meant. A request with no `Origin` is not a cross-origin request and now
gets no such header at all.

## The LED, and the cost of handing over an instrument

The LED is what this whole road is read with on a phone, where there is no log
and nothing to install
([`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md)). exp154
refused to spend it. This experiment spends it, on one condition:

**The handover does not start until the board has an address.** Until then,
*dark = no link* and *slow = still asking* are the only instrument anybody has,
and a page that could overwrite them would be taking the instrument away at the
exact moment it is the only one. Once a browser can reach the board at all,
those two states have already been proven by the request arriving.

And the cost is stated rather than hidden: **a page can now set the LED to
something indistinguishable from a network state.** `slow` looks like "still
asking"; `off` looks like "no link". That is what handing over an instrument
means. `/led/auto` gives it back, and `check.sh` gives it back when it is done.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. `pack.sh` lifts this section verbatim into that zip, so
there is one copy of the procedure and it is this one.

There are two routes and they end in the same place. **The phone route is the
point of the experiment**; the Ubuntu route is how the numbers in this README
were measured.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A, LED on GPIO 25) and a USB data cable.
  * EITHER an Android phone with an OTG cable and Chrome,
    OR Ubuntu with NetworkManager — `nmcli`, which a desktop install has.
  * Nothing installed on either. No udev rule, no root, no toolchain.
  * For the last two steps on Ubuntu only: `google-chrome` and `python3`.

### On a phone

1. UNPACK THE ZIP on the phone, with the Files app. You need `pages/` and
   `firmware/` out of it.

2. FLASH THE BOARD FROM THE PHONE. **[HUMAN STEP]** Open `pages/bootsel.html`
   in Chrome and use it to put the board into BOOTSEL, then open
   `pages/pflash.html` and give it `firmware/exp155.uf2`. Do those two without
   a pause — a board left in BOOTSEL while somebody reads the next step may
   not still be there when they get back.

   If the board is already running exp105 or later, `bootsel.html` needs no
   button. If it is dark or refuses, hold BOOTSEL while plugging it in.

3. TURN ON ETHERNET TETHERING, STRAIGHT AWAY. Settings → Network & internet →
   Hotspot & tethering → Ethernet tethering. **The switch is greyed out until
   something is plugged in**, which is why this is step 3 and not step 1.

   Do not leave a gap here. The board goes on asking forever, but a host that
   has been told "no medium" for long enough may stop looking. exp153 measured
   the drive still appearing 30.5 s after boot, so this is *sooner is better*
   rather than a cliff.

4. WAIT FOR THE LED TO BLINK FAST. **[HUMAN STEP]**

       dark    no link — nothing has claimed the network interface
       slow    link up, still asking for an address
       fast    it has an address; the drive appears now

5. OPEN THE DRIVE — **the one the board is serving**, which appears in the
   Files app under a name like `YI26 BOARD`. It is not the zip you unpacked,
   and it did not exist until step 4.

6. TAP `OPEN.HTM`, THEN TAP THE BIG BLUE LINK ON IT. Tap it; do not type the
   address. A phone's address bar searches for what you type, `http://` and
   all — measured.

   You are now on a page the board served over the USB cable. Nothing was
   installed and no app claimed the device.

7. TAP **fast**. **[HUMAN STEP]** The LED on the board in your hand blinks
   fast. That is a web page controlling hardware over one USB cable, with
   nothing installed at either end.

8. TAP **/log**. The firmware's own log, including a line about the request
   you just made — `led: now fast — asked over GET by no stated origin`.

9. TAP **give it back**. The LED returns to reporting the network, and the
   log says so.

### On Ubuntu

1. UNPACK IT.

       unzip exp155-who-else-can-knock.zip
       cd exp155-who-else-can-knock

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug the
   board in, let go. A drive called `RP2350` appears.

       cp firmware/exp155.uf2 /media/$USER/RP2350/

   The board reboots as the copy finishes and the drive vanishes. That is
   success, not an error — some file managers report it as one.

3. FIND THE BOARD'S NETWORK INTERFACE. It is named after the experiment.

       nmcli -t -f DEVICE,TYPE,STATE device | grep enx

   Expect a line beginning `enx022600000155:ethernet:`. Whatever state follows
   is fine; step 4 overrides it.

4. BECOME ITS DHCP SERVER. The board asks and will not invent an address.

       nmcli connection add type ethernet ifname enx022600000155 \
             con-name yi26-exp155 ipv4.method shared
       nmcli connection up yi26-exp155

   Expect: `Connection successfully activated`. This needs no `sudo`.

5. WAIT FOR THE DRIVE. About twenty-five seconds on this machine.

       lsblk -o NAME,SIZE,LABEL,MODEL -d | grep sda

   Expect: `sda        64K YI26 BOARD exp155 knocking`, and the LED blinking
   fast. Before the address arrives the same command shows `0B` and no label:
   a card reader with no card.

6. READ THE ADDRESS OFF THE DRIVE. Ubuntu mounts it on its own; if not,
   `udisksctl mount -b /dev/sda` first.

       cat "/media/$USER/YI26 BOARD/ADDRESS.TXT"

   Expect: `http://10.42.0.250/` — that exact address on a machine with no
   other shared connection, because NetworkManager hands out `10.42.0.x` and
   the board pins itself to `.250` of whatever subnet it is given.

7. CHANGE THE BOARD FROM A URL. This is the open door.

       curl -s http://10.42.0.250/led/fast
       curl -s http://10.42.0.250/status

   Expect `led: fast`, then JSON containing `"led":"fast"`. **[HUMAN STEP]**
   The LED is blinking fast because a URL was fetched. Nothing was asked, no
   header was consulted, and any page in any browser that can route here could
   have done the same with an `<img>` tag.

8. KNOCK ON THE GUARDED DOOR, WRONGLY AND THEN RIGHTLY.

       curl -s -o /dev/null -w '%{http_code}\n' -X POST \
            -H "X-Yi26-Control: 1" -H "Origin: http://elsewhere.example" \
            http://10.42.0.250/control/led/off
       curl -s -X POST -H "X-Yi26-Control: 1" http://10.42.0.250/control/led/off

   Expect `403`, then `led: off`. The first was refused for its origin; the
   second stated none, and `curl` is not a browser — which is the honest limit
   of this guard and is why the README says so before you find it.

9. WATCH A PAGE FROM SOMEWHERE ELSE PULL THE OPEN DOOR. Needs `google-chrome`
   and `python3`.

       curl -s http://10.42.0.250/led/auto > /dev/null
       mkdir -p /tmp/foreign && curl -s http://10.42.0.250/probe > /tmp/foreign/index.html
       python3 -m http.server 8155 --directory /tmp/foreign > /dev/null 2>&1 &
       google-chrome --headless=new --disable-gpu --virtual-time-budget=6000 \
            --dump-dom http://127.0.0.1:8155/ > /dev/null 2>&1
       sleep 3; curl -s http://10.42.0.250/status
       pkill -f "http.server 8155"

   Expect `"led":"slow"`, `"led_is_auto":false` and `"turned_away"` one higher
   than before. That page
   came from `127.0.0.1:8155`, not from the board, and it changed the board
   twice — with an `<img>` and with a cross-site form POST. Its third attempt,
   at the guarded door, was refused before it was answered.

   **That is the experiment.** CORS never stopped the request; it only governs
   whether the reply may be read. What stopped the third one was a preflight.

10. PUT IT BACK.

       curl -s http://10.42.0.250/led/auto
       nmcli connection delete yi26-exp155

## From a checkout

```sh
cargo build --release
elf2flash convert -b rp2350 \
    target/thumbv8m.main-none-eabihf/release/exp155-who-else-can-knock \
    target/exp155.uf2
yi26 flash target/exp155.uf2      # hands-free; no BOOTSEL button
yi26 log --seconds 30             # it prints the address, and keeps printing it
./check.sh                        # 46 checks: board half and browser half
```


## Expected output

`./check.sh`, captured on Ubuntu against a real Pico 2 with Chrome present and
the board's own drive mounted, 2026-08-06.

```console
PASS  toolchain present (cargo, elf2flash)
PASS  builds (182784 byte .uf2)
PASS  linked at 0x10000000 — an ordinary image
PASS  carries the 1200-baud reboot watcher — the next flash is hands-free
PASS  crates/http-route passes its own tests
PASS  crates/log-ring passes its own tests
PASS  crates/mdns passes its own tests
PASS  crates/fat12 passes its own tests
PASS  the drive carries a link to tap and the address as plain text
PASS  the address is in the contents, not squeezed into an 8.3 name
PASS  the volume is laid down exactly once — there is no second version
PASS  a page that fills its buffer says so — silence is what hid exp153's truncation
PASS  the interface count is stated as five, which is what lsusb says
PASS  the parser can find a named header — the whole of what exp154 was missing
PASS  an unfinished header block is never read as an empty one
PASS  the worker waits for the whole header block before deciding anything
PASS  a header value that could forge a log line is not a value
PASS  /led/… changes the board and consults nothing — the thing being measured
PASS  /control/led/… needs the header AND an origin that is this board's
PASS  the header's name is the mechanism — a non-simple header forces a preflight
PASS  the preflight answers and does nothing — asking is not acting
PASS  a request with no Origin is answered with no Origin header, not with 'null'
PASS  a refusal sends no CORS header at all — a browser reads silence as no
PASS  the LED is only the caller's once there is an address
PASS  ...and the cost of handing it over is written down where it happens
PASS  asking for the state it is already in is transient, not retained
PASS  the only retained http: line is the one that should never happen
PASS  every retained log line fits in 96 bytes, stamp included
PASS  an Origin too long to record is marked, not silently shortened
PASS  no script in the index or the log page
PASS  /probe is named as the exception, and as an instrument rather than a page
NOTE  enumerated as: exp155 who else can knock
PASS  the board has an address and says so — http://10.42.0.250
PASS  GET /led/fast changed the board — no header, no permission, no question
PASS  POST /led/on did the same — the method was never the boundary
PASS  the guarded door opens for a request with the header and no stated origin
PASS  a foreign Origin is refused even with the header — 403, and nothing moved
PASS  the right origin without the header is refused too — both halves are needed
PASS  a preflight from elsewhere gets 403 and no Allow-Origin — and the LED did not move
PASS  a preflight from this board's own origin is answered 204 with that one origin echoed
PASS  /probe is served, and points at this board by absolute address
PASS  a page from http://127.0.0.1:8155 changed this board's LED — twice, by <img> and by form POST
PASS  ...and its fetch to the guarded door was turned away (4 → 5)
PASS  the guarded door was never opened by a page that did not come from here
PASS  the identical page served from this board opened the guarded door — only the origin differed
PASS  a 'YI26 BOARD' volume is present, and its SCSI model names exp155
PASS  the address on the drive is the address the board answers at — http://10.42.0.250
PASS  ADDRESS.TXT and README.TXT are on it too — three files, no toolchain needed
PASS  OPEN.HTM is 881 bytes — short of its 1024-byte buffer, so it is whole
NOTE  the LED has been given back to the network reporter.
NOTE  what this script cannot see: that the pin lights an LED. exp103 and
      exp127 established that, and this experiment does not re-establish it.
```

## What the phone found that Ubuntu could not

The walkthrough was followed on a Pixel 9a on 2026-08-06, on the **other** board
— chip `0x7fcaf01f 0x5613a90c`, flashed from the phone over PICOBOOT (90,880
bytes, 23 sectors, read back and matched). It worked: the drive appeared, the
link on `OPEN.HTM` opened the index at `http://10.206.115.250/`, the five LED
links were there, and the log rendered.

**And two defects showed up that no desktop run could have shown.**

**1. Two log lines were being cut mid-word.** `usb-log` truncates at
`LINE_CAPACITY = 96` bytes **including the `[   45 ms] ` stamp**, and says
nothing when it does. Two banner lines were 88 characters of text and came out
of the phone's `/log` ending in `…needs a header an` and `…After that i`.

Two things came out of fixing it. The lines are shorter, and `check.sh` now
computes the static width of every retained line so this cannot come back. And
the more interesting half: **the line that records who knocked can be pushed
over 96 by its own runtime value.** A long `Origin` would have had its tail
silently eaten — a security log losing the end of *who asked* is worse than one
that admits it. So the origin is now truncated where it can be marked:

```text
[   39120 ms]   it said it was http://a-very-long-hostname-that-will-not-fit.e~
```

That `~` is the whole point. exp153 learned the same lesson one layer down, when
a phone showed a button labelled `http://10`.

**2. `/trng` ran off the right edge of the phone and never came back.** Chrome
does not wrap `text/plain`, so a single long header line and 32 bytes of hex per
line meant the reader saw `waiting for the one TRNG took` with the number
missing. There is no stylesheet to fix that afterwards — a plain-text body has
none — so **the wrapping has to be in the bytes**. Everything `/trng` emits is
now inside 32 columns, and the two costs are on separate lines because they are
two different facts:

```console
$ curl -s http://10.42.0.250/trng?n=16
16 bytes from the RP2350 TRNG
sampling: 5104 us
waiting for the one TRNG: 10 us

02 dd 12 ab e9 42 74 4f
e3 28 e9 7c 90 63 70 dd
```

A third thing, which is not a defect but a second data point: the phone's board
took **10,785 µs for 32 bytes** where this one takes 5,822 µs for 8 and 220 ms
for 1024. Per byte that is 337 µs against 728 and 213 — the same shape, on a
different chip: most of a small draw is the cost of asking.

## Two things the harness taught, both worth keeping

**A page is not a witness to what a board received.** `/probe` prints what its
own browser told it, and `--dump-dom` returns before the third knock has been
answered — the DOM says `starting…` while the requests are still in flight. The
check polls `/status` instead. That is `AGENTS.md`'s rule about reading the log
with `yi26` rather than with a browser, in a new place: *the thing under test
cannot be the measuring instrument.*

**A leaked server looks exactly like a failed experiment.** The first version
started the foreign origin in a subshell, so the trap killed the subshell and
not the `python` under it; the next run got a 404 from a server still holding
the port over a deleted directory, and three checks failed as though the finding
had not reproduced. `--directory` instead of a `cd`, so the thing killed is the
thing started.

## What this does not answer

- **`Host:` validation**, and therefore DNS rebinding. The parser can now read a
  header, so this is no longer blocked by the parser — it is simply not what
  this experiment measured.
- **Any defence against a program on the host.** Stated above, and it applies to
  every transport in this repository.
- **Whether another browser agrees.** These are Chrome's CORS and Private
  Network Access rules. They are the same everywhere Chromium is; Firefox and
  Safari have not been tried here.
