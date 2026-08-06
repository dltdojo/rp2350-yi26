# exp153-out-through-the-phone — the board asks the internet a question

Every experiment on the network road so far has the board being **reached**.
[exp150](../exp150-a-page-served-by-the-board/) made it serve a page,
[exp151](../exp151-the-log-in-any-browser/) made that page its log, and
[exp152](../exp152-the-volume-that-waits/) made the address findable without
typing. This one points the same stack the other way and asks whether the board
can reach anything itself.

## The claim being tested is one this repository wrote down and never checked

The plan for this experiment, in [`../README.md`](../README.md), says it is
**desktop only, and deliberately so**:

> It needs the host to route and NAT for it, which a laptop can be told to do
> and a phone cannot — there is no such UI.

That was written before exp150 measured what Android's **Ethernet tethering**
actually does. Tethering is not a setting that hands out addresses; it is a
setting that *shares a connection* — the phone becomes the DHCP server, the
router **and the NAT**. exp150 watched the board come up with a gateway and
never asked what was on the other side of it.

So the UI the plan says does not exist is the switch exp150, exp151 and exp152
all already require somebody to turn on. That is worth stating plainly: the
prediction was not refuted by new hardware or a clever workaround. It was
refuted by reading what the last three experiments had already needed.

## Three measurements, all of them free once the board is plugged in

### 1. What was offered

The lease's gateway and DNS servers, logged **as received**, before anything is
tried with them.

```text
lease: 10.206.115.122/24
  gateway 10.206.115.1 — a claim that there is a way out
  DNS 10.206.115.1
```

A log that only ever prints what worked cannot tell an offer that was never made
from an offer that did not work. exp152 printed the gateway and called it *"there
is a way out of here"*. It is not one. It is an offer, and this experiment exists
because nobody had checked.

### 2. Whether the way out goes anywhere

A TCP connection to a **literal address** — no DNS anywhere in the path — and one
HTTP request over it, twice:

| request | what it should answer |
| --- | --- |
| `GET /` with `Host: 1.1.1.1` | `301 Moved Permanently`, to `https://` |
| `GET /generate_204` with `Host: cp.cloudflare.com` | `204 No Content` |

Both go to the same address over separate connections, so a difference between
them cannot be a routing difference — the only variable is the name the server is
asked to answer as.

**The difference between those two answers is the finding.** A device that cannot
speak TLS is redirected off almost everything on today's internet. What it can
still have is the captive-portal endpoint, a URL that exists precisely because it
has to work *before* a network is trusted, and is therefore close to the last
plain-HTTP thing left.

That is the honest shape of "an embedded device on the internet" in 2026, and it
is worth a reader meeting it as a measurement rather than as a warning. TLS is
not on this road — a different curriculum and a much larger binary — so this is
where the cost of not having it becomes a number.

### 3. Whether a name can become an address

One DNS query, through the resolver the lease named, for the name the second
request already uses — so a resolver that works can be seen to agree with the
literal address.

It runs **after** the other two and never in front of them. A client that fails at
resolution and a client that fails at routing look identical from a bench and are
not the same failure; putting the query first would have made one of them
unmeasurable.

## A literal address, on purpose, and it will still be there in a year

`1.1.1.1` is anycast, it is the shortest address anybody can check by hand, and it
serves both URLs above on port 80.

An experiment here is **frozen once made** — see
[`docs/pack-verification.md`](../../docs/pack-verification.md) — so a target that
can be renumbered is a walkthrough that will one day describe something that no
longer happens. Naming an address rather than a name, and getting both answers
from one operator, is what keeps this readable later.

## What was taken out of exp152, and why

Two things, and both removals are the experiment rather than a tidy-up.

**The pinned address.** exp152 moves to host `.250` of whatever subnet it is
given, so a bookmark outlives a lease. That is right for a board being reached and
wrong for a board reaching out: **a NAT translates the addresses it handed out**,
and sending from one the server never leased would be a second variable in a
one-variable measurement. exp153 keeps the address it was given.

**The mDNS responder.** `yi26.local` is exp151's and exp152's finding — correct,
and measured never to be asked for by the phone. Carrying it here would be a
second story in a firmware meant to tell one. The DHCP hostname stays, because it
costs one line and it is what the board is called.

## A rule a board taught this experiment

**A state change is history; saying the same thing again is the reader's own
waiting.**

exp152 repeats its address line on every idle tick so it cannot have scrolled
away before somebody looks. That is right for exp152, where the result was the
page existing at all. It is wrong here, and a board showed it: two retained lines
every five seconds fill the 64-line ring in under three minutes, and what they
push out is `out: … 301` and `Location: https://1.1.1.1/` — which in *this*
experiment are the evidence.

So the periodic report is `log_transient!` and only a genuine state change is
kept. Nothing is lost: the address is in the page's own heading and on the drive,
and the answers are in the table above the log.

That is the fourth time this repository has paid for the same rule — HTTP
requests in exp151, mDNS chatter in exp151, a hundred `READ(10)`s in exp152, and
now a status line that was correct and simply said too often.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. `pack.sh` lifts this section verbatim into that zip, so
there is one copy of the procedure and it is this one.

There are two routes and they measure the same thing. **The phone is the point**;
the desktop is where it can be checked without anybody holding anything.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A, LED on GPIO 25) and a USB data cable.
  * Either an Android phone with an OTG cable and Chromium — **or** Ubuntu with
    NetworkManager (`nmcli`, which a desktop install already has).
  * On a phone, `pages/log.html` is the instrument. Nothing else in this zip
    can tell you why something did not happen, and every step below has a
    failure whose only witness is the board's own log.
  * `unzip`. No udev rule, no `input` group, no root, no `sudo`.
  * The host must be able to reach the internet, because that is what is being
    borrowed.

1. UNPACK IT.

       unzip exp153-out-through-the-phone.zip
       cd exp153-out-through-the-phone

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold the BOOTSEL button
   down, plug the board in, then let go. A drive called `RP2350` appears.

       cp firmware/exp153.uf2 /media/$USER/RP2350/

   The board reboots by itself as the copy finishes and the drive vanishes.
   That is success, not an error — some file managers report it as one.

   *Without hands:* a board already running exp105 or later reboots itself when
   its port is opened at 1200 baud, so `yi26 flash exp153.uf2` does the whole
   thing — but `yi26` needs the repository.

   *On a phone:* open `pages/bootsel.html`, then `pages/pflash.html`, and pick
   `firmware/exp153.uf2`. Android lists the same board several times and only
   one entry is live — **the live one is the entry that makes Android ask for
   USB permission**, nothing in the names says which, and picking a dead one
   costs nothing. Do this immediately after the previous step: a board does not
   sit in BOOTSEL safely on a phone, because a sleeping screen power-cycles the
   port and a reset boots a firmware rather than waiting.

3. GIVE IT A WAY OUT. This board asks for an address and will not invent one,
   and an address alone is not the point — it needs the host to **share its
   connection**, which is the same thing as routing and NAT.

   *On a phone:* turn on Ethernet tethering — Settings → Network & internet →
   Hotspot & tethering. That switch is greyed out until something is plugged in,
   which is why it cannot be done in advance.

   **No replug is needed after flashing, and that is measured rather than
   assumed.** exp152's rule is that the medium has to arrive at a host still
   asking — this firmware reports no medium at all until it has an address, and
   a host told that for long enough stops polling. The worry was that flashing
   from the phone spends that patience before the address arrives. On a Pixel
   9a, 2026-08-06, it does not: the lease landed at **30.5 seconds** after boot,
   thirty seconds of `NOT READY / MEDIUM NOT PRESENT`, and the drive appeared
   anyway. Sooner is still better and there is no reason to dawdle, but a flash
   in front of the switch does not cost the experiment.

   *On Ubuntu:* the interface is named after the experiment.

       nmcli -t -f DEVICE,TYPE,STATE device | grep enx022600000153
       nmcli connection add type ethernet ifname enx022600000153 \
             con-name yi26-exp153 ipv4.method shared
       nmcli connection up yi26-exp153

   Expect: `Connection successfully activated`. `ipv4.method shared` is the
   whole of it — NetworkManager runs the DHCP server and the masquerade itself,
   and **it needs no `sudo`**.

4. WAIT ABOUT FIFTEEN SECONDS. **[HUMAN STEP]** The LED says where you are
   without your having to read anything:

       dark    no link
       slow    link up, still asking for an address
       fast    address in hand, nobody has read the page
       solid   a browser got the page

   *Without eyes:* step 5 answers the only question that matters anyway.

5. READ THE ANSWER. It is on a drive the **board** provides, not in this zip.

   *On a phone:* **`OPEN.HTM` is not in this zip.** Nothing you unpacked
   contains it and no amount of looking in `Downloads` will find it. The board
   *makes* it: 64 KiB of FAT12 assembled in the firmware's own RAM and served
   over USB, so it is a **separate storage device**, one the phone did not have
   until the board had an address.

   Open the **system** Files app — third-party file managers get `Permission
   denied` on `/mnt/media_rw/…` and never reach the device at all. Go to where
   it lists storage, beside Internal storage, and look for a drive called:

       YI26 BOARD

   Tap it, tap `OPEN.HTM`, tap the link. There are three files on it and that is
   the whole volume.

   *On Ubuntu the same drive is* `/media/$USER/YI26 BOARD/`.

   **If no drive appears, open `pages/log.html` and read the board's own log.**
   That page is the instrument in this zip: it claims the CDC interface over
   WebUSB and shows every line the firmware has printed, including the one that
   says what it is waiting for. There is no drive *because* there is no address,
   and the log says which of the two reasons it is — `link DOWN` means nothing
   claimed the interface, `still asking` means nothing offered an address. Do
   not re-flash and do not guess: this experiment ships an instrument precisely
   so nobody has to.

   *On Ubuntu:* the board pins nothing, so read the address off the log, or take
   NetworkManager's word for its subnet and ask:

       curl -s http://10.42.0.215/ | sed -n 's/.*<table>//; s|</table>.*||p'

   Either way the **top of the page** is the result: three rows, above the log
   rather than inside it.

       GET http://1.1.1.1/                        301
       GET http://cp.cloudflare.com/generate_204  204
       cp.cloudflare.com resolves to              104.16.133.229

   **That pair is the experiment.** Same address, separate connections, one
   header apart: the plain request is redirected to a protocol this board cannot
   speak, and the captive-portal endpoint answers. The log below carries the raw
   first line of each response and the `Location` header verbatim, so the parsed
   codes are a convenience and never the only evidence.

6. PUT THE MACHINE BACK (Ubuntu only).

       nmcli connection delete yi26-exp153

IF IT DOES NOT WORK

  **Ask the board first.** On a phone that means `pages/log.html`; on a desktop
  it means `yi26 log`. Every entry below is something the log already says in
  words, and reading it costs one tap.

  * **`OPEN.HTM` is nowhere in the unpacked zip.** Correct — it is not supposed
    to be. It exists only on the drive the board serves, which is called
    `YI26 BOARD` and sits with the phone's other storage, not under `Downloads`.
    This is the first thing to rule out and it costs one look, because a drive
    that is present and a drive that is looked for in the wrong place are
    indistinguishable from the far end of a message.

  * **No `YI26 BOARD` drive at all**, and the flash reported success. Two
    different causes, and `log.html` tells them apart in one line.

    `still asking` — nothing offered an address. Tethering is off, or the switch
    was found too late.

    `I am at http://…` — **the board has an address and the drive still did not
    appear**, which would mean the host stopped polling before the medium
    existed. Not seen on a Pixel 9a even after thirty seconds of no medium, but
    if it happens: unplug, plug back in, tethering on immediately. Do not
    re-flash — nothing is wrong with the board, and the address on that log line
    is itself the answer, so tap it and skip the drive entirely.
  * No `enx…` device at all — the board is not running this firmware, or the
    cable is charge-only. A charge-only cable is the commonest single cause of
    everything in this repository.
  * `no gateway in the lease, so there is nothing to try` — something handed out
    an address without a route. **Nothing was sent**, which is a different
    finding from a request that went out and got nothing, and the log says so on
    purpose.
  * Both rows say `no answer` — the gateway was an offer and not a way out.
    Check that the host itself can reach the internet.
  * Both rows say `still trying` — give it twenty seconds; there are three
    attempts, five seconds apart.
  * The LED never goes fast — nothing offered an address. On a phone that is
    tethering not being on in time: unplug, replug, turn it on immediately.

## Expected output

Captured on Ubuntu, 2026-08-06, on a Pico 2 flashed hands-free by `yi26 flash`,
with `nmcli … ipv4.method shared` as step 3.

```console
$ curl -s http://10.42.0.215/
GET http://1.1.1.1/                        301
GET http://cp.cloudflare.com/generate_204  204
cp.cloudflare.com resolves to              104.16.133.229
```

And the board's own log underneath it, complete — twenty-one lines, none of them
repeated:

```text
[      45 ms] exp153 up. The same stack as exp152, pointed the other way.
[     445 ms] 400 ms  link UP, still asking. Nothing has offered an address: ...
[   10796 ms] lease: 10.42.0.215/24
[   10796 ms]   gateway 10.42.0.1 — a claim that there is a way out
[   10796 ms]   DNS 10.42.0.1
[   10806 ms] out: GET http://1.1.1.1/ — connected in 9 ms
[   10820 ms] out: GET http://1.1.1.1/ — HTTP/1.1 301 Moved Permanently
[   10820 ms]         Location: https://1.1.1.1/
[   10820 ms]         381 bytes in 23 ms
[   10826 ms] out: GET http://cp.cloudflare.com/generate_204 — connected in 6 ms
[   10850 ms] out: GET http://cp.cloudflare.com/generate_204 — HTTP/1.1 204 NO CONTENT
[   10850 ms]         755 bytes in 29 ms
[   10853 ms] dns: cp.cloudflare.com is 104.16.133.229
[   10854 ms] out: done. The page shows both answers; the difference between them is the point.
```

Nine milliseconds to connect and twenty-three for the whole exchange, through a
USB Ethernet gadget, a host's masquerade and the public internet.

## Status

**Verified on both, 2026-08-06. The claim is refuted.**

On Ubuntu, with `nmcli … ipv4.method shared` and no `sudo`: lease with a
gateway, `1.1.1.1` in 9 ms, `301` to a protocol it cannot speak, `204` from the
captive-portal endpoint, and a name resolved through the lease's resolver.

**On a Pixel 9a, flashed from that phone with `pflash.html`, with Ethernet
tethering as the only host-side action:**

```text
[     546 ms] 500 ms  link UP, still asking. Nothing has offered an address…
[   30535 ms] lease: 10.206.115.125/24
[   30535 ms]   gateway 10.206.115.129 — a claim that there is a way out
[   30535 ms]   DNS 10.206.115.129
[   30624 ms] out: GET http://1.1.1.1/ — conn…
```

and on the page the phone was holding:

```text
10.206.115.125 — chip 0x7fcaf01f 0x5613a90c
up 1309 s, 3 request(s) answered

GET http://1.1.1.1/                        301
GET http://cp.cloudflare.com/generate_204  204
cp.cloudflare.com resolves to              104.16.133.2…
```

So the sentence in [`../README.md`](../README.md) — *"a laptop can be told to do
[NAT] and a phone cannot — there is no such UI"* — is wrong. **Ethernet
tethering is that UI.** It is not named after what it does, which is why three
experiments could require somebody to turn it on without anybody noticing that
it also routes and masquerades.

The chip ID on that page is `0x7fcaf01f 0x5613a90c` and the serial the bootrom
gave `pflash.html` while writing this firmware was `7FCAF01F5613A90C`. Same
silicon over two interfaces: the board that was written and the board that
reached the internet are provably one board, which would otherwise have been an
assumption.

**What it cost the phone: nothing.** Mobile data stayed up throughout, as it did
in exp149 and exp150 — a USB Ethernet gadget on this phone displaces nothing,
and now that has been measured with traffic actually flowing through it rather
than with an idle link.

The request bytes were checked against the real server from the host before any
of this: the `301` puts `Location: https://1.1.1.1/` at byte 154, inside the 256
the firmware keeps, so a response that arrives cannot have its most interesting
line fall off the end.
