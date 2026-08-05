# exp149-the-board-hands-out-the-address — four packets, and nobody has to configure anything

[exp148](../exp148-a-wire-with-no-address/) got a link and stopped. Two very
different hosts behaved identically: Ubuntu's NetworkManager and a Pixel 9a both
run a DHCP **client** on a new USB Ethernet interface, and so did the board. Two
clients, waiting for each other, forever.

A laptop can be told to be the server — one `nmcli` line. **A phone cannot.**
The setting does not exist and cannot be added. So if a board is to be reachable
from the machine most people actually own, the board is the one that answers.

`embassy-net` ships no DHCP server; its `dhcpv4` feature *is* the client, and
`mdns` is a resolver rather than a responder. So this firmware opens a UDP socket
on port 67 and speaks the four packets itself.

```text
  client ──DISCOVER──▶  "is anybody there?"        broadcast: it has no address
         ◀──OFFER────   "you may have 192.168.7.2"
         ──REQUEST──▶   "I'll take it"             still broadcast: not official yet
         ◀──ACK──────   "it's yours, for an hour"
```

That is the whole protocol for this case. Everything else DHCP can do — relays,
pools, declines, renewal bookkeeping, conflict detection — exists because real
networks have many clients and a router between them. **A USB cable has one host
on the other end of it.**

## Where the protocol lives

In [`crates/dhcp`](../../crates/dhcp/), with no socket in it. The firmware owns
the endpoint; the crate is given bytes and returns what was asked, or says why
the bytes were not a request.

That split is what lets `cargo test` do the thing a board cannot: feed the parser
a packet cut at **every length**, thirty thousand times, on the machine you are
reading this on. Sixteen tests, and two of them were written wrong first.

> **A truncation is not the same thing as malformed.**
>
> DHCP options carry their own lengths, and `OPT_END` is only needed when
> something follows it. So a packet cut *between* options is a smaller packet
> that is perfectly valid; only a cut *inside* one is malformed.

The test asserted "every truncation is refused" and the parser corrected it
twice — first at 243 bytes (header, cookie and a complete option 53: a legal
minimal DISCOVER) and again at 244 (which cuts into option 50, and is not). That
rule is not obvious, and it is the difference between refusing real clients and
reading past the end of a buffer.

## Three decisions, each of them a test

**One address in the pool.** There is one host on the other end. No lease table,
no pool arithmetic, no expiry bookkeeping.

**Every reply is broadcast to 255.255.255.255.** The obvious alternative —
unicast to the address being offered — cannot work, because the client does not
own that address yet and will not answer an ARP for it. Real servers solve that
by injecting an ARP entry they were never told. Broadcasting is legal, it is what
the `BROADCAST` flag in the reply announces, and it makes the problem disappear.

**No router option and no DNS.** Both are conventional and both would be false:
this board is one end of a cable and routes nothing. A host told otherwise acts
on it, and a phone that decides a USB link is its way to the internet is a phone
that has lost its way to the internet.

The evidence that this was the right call is in the host's routing table below:
it installed a route to the subnet **and nothing else**.

## The LED means something different from exp148's

The board now has a **static** address — it is the server, so it cannot ask for
one. That makes `is_config_up()` true from boot, which would leave exp148's LED
stuck on "fast" saying nothing.

So it reports the **client's** progress instead, which is what is being measured:

```text
  dark   no link — no host driver has claimed the NCM interface
  slow   link up, and nobody has asked for an address
  fast   a client asked, and took what it was offered
```

## Expected output

Captured on Ubuntu, 2026-08-05.

```console
$ yi26 pflash target/exp149.uf2
flashed 41728 bytes to 0x10000000 over PICOBOOT (11 sectors erased), and rebooted into it.

$ yi26 log --seconds 6
[      43 ms] exp149 up. CDC-ACM for this log, CDC-NCM for the link.
[      43 ms]   I am 192.168.7.1/24 and I hand out 192.168.7.2
[      43 ms]   no router option, no DNS — this board routes nothing and says so.
[      43 ms]   LED: dark = no link, slow = nobody asked, fast = address taken.
[      43 ms] 0 ms  link DOWN — nothing has claimed the NCM interface
[      44 ms] dhcp: listening on port 67
[     444 ms] 400 ms  link UP, waiting for a DISCOVER
[     490 ms] dhcp: Request from 02:26:00:00:01:49
[     490 ms] dhcp: Ack 192.168.7.2 broadcast, 262 bytes
[     494 ms] 450 ms  link UP, 192.168.7.2 is leased out
```

**No `nmcli`, no connection sharing, no configuration of any kind.** exp148
needed a line typed into the host before an address existed; this needed
plugging the board in.

Note what is missing from that capture: the DISCOVER. The host had leased this
address before, so it went straight to REQUEST — which is DHCP working as
designed, and the reason the server answers both.

What the host ended up with:

```console
$ ip -brief addr show enx022600000149
enx022600000149  UP    192.168.7.2/24 fe80::d661:27ea:a098:2f7b/64

$ ip route show dev enx022600000149
192.168.7.0/24 proto kernel scope link src 192.168.7.2 metric 100

$ ip route show default
default via 192.168.200.1 dev wlo1 proto dhcp src 192.168.200.102 metric 600
```

One route, to the subnet, and the default route untouched. That is the "no router
option" decision, visible.

### Ten boots, and the reason that number is in here

```text
boot  1: Ack=1 addr=1        boot  6: Ack=1 addr=1
boot  2: Ack=1 addr=1        boot  7: Ack=1 addr=1
boot  3: Ack=1 addr=1        boot  8: Ack=1 addr=1
boot  4: Ack=1 addr=1        boot  9: Ack=1 addr=1
boot  5: Ack=1 addr=1        boot 10: Ack=1 addr=1
```

Before the TRNG sample count was fixed, this ran at roughly **two failures in
six** — see below. A firmware that starts two times in three is not one to put
in front of anybody, and a single successful boot does not tell you which you
have.

## The detour, which cost more than the experiment

This booted dead about one time in three. USB enumerated, the 1200-baud watcher
answered, and everything spawned after the TRNG read never ran — no log, no DHCP,
host left with no address.

Reading `embassy-rp`'s TRNG driver turned up a plausible waker race, so the fix
was to switch to `blocking_fill_bytes`. That made it fail *every* time and took
the board off the USB bus entirely, because a busy-wait blocks the executor
before USB enumerates — and a board that cannot enumerate cannot be recovered
without a hand on BOOTSEL.

The answer was in this repository the whole time.
[exp109](../exp109-hardware-trng/) exists for exactly this, and the constant left
at its default is its headline:

> `embassy-rp`'s default is 25 clock cycles between ring-oscillator samples, and
> on this board that is too fast. The health tests reject the block and it starts
> over. Three consecutive 64-bit fills: **0.38 s, then 31.4 s, then 14.5 s.** At
> 1000 it is 5–6 ms, every time.
>
> *"Something that always works and sometimes takes half a minute is harder to
> diagnose than something that breaks."*

Nothing was hung. The log was being read seven seconds after a boot that spent
thirty in there. exp148 carries the same line and the same fix; its six clean
boots were luck.

Two rules came out of it, both now in the code:

- **Step 2 of [the interrogation](../README.md#every-new-experiment-starts-with-an-interrogation)
  is not optional.** The prior art was checked carefully — in `embassy-rp`'s
  source — and not at all in the experiment three directories away whose title is
  the peripheral in question.
- **Nothing may block the executor before USB is up.** An `.await` leaves
  `usb_task` free to enumerate and `control_task` free to answer the 1200-baud
  touch, so however long a wait takes, the board stays reflashable.

## What this experiment does not do

- **No TCP.** An address is not a service. [exp150](../exp150-a-page-served-by-the-board/)
  is where that changes.
- **No lease table.** One address, handed to whoever asks. A second client would
  be offered the same one.
- **No claim about what a host does with the offer.** Ubuntu takes it and
  configures the interface. A Pixel 9a takes it and lists no network at all —
  see below.

## The phone, which is what this was built for

**Verified 2026-08-05 on a Pixel 9a: the LED went fast.** The board sent an
`ACK`, so Android ran a DHCP client on the USB link and completed the handshake,
with nothing installed and nothing configured — because there is nothing on a
phone to configure.

Two other things were true at the same time, and they matter:

| | |
| --- | --- |
| Mobile data **survived** | 5G throughout. The link did not capture the default route |
| Settings showed **no Ethernet network** | nothing at all under Network & internet |

So Android took the address at a layer that never became a user-visible network.
[exp150](../exp150-a-page-served-by-the-board/) is where that turns out to
matter: an address a browser cannot route to is not reachability.

## Make it yours

- Change `CLIENT_IP` and watch the host take the new one on the next lease. The
  board keeps `.1`; nothing else in the firmware knows the difference.
- Set `LEASE_SECONDS` to 30 and watch the renewal traffic in the log. A short
  lease is the cheapest way to see DHCP's second half, which this README's
  capture skips over.
- Add a second address to the pool and a table to remember which MAC has which.
  That is the first thing this deliberately does not do, and doing it is how you
  find out what the rest of DHCP is *for*.

## Troubleshooting

**The LED stays slow.** Nothing has asked. On Linux, check that the interface
exists (`ip link | grep enx`) and that NetworkManager has not been told to
ignore it.

**The host gets 169.254.x.x instead.** That is the host giving up on DHCP and
self-assigning. The board's log will show whether a DISCOVER ever arrived — if it
did not, the problem is upstream of this firmware.

**A boot with no log at all.** Read the detour section above before suspecting
anything else.

## Next

[exp150](../exp150-a-page-served-by-the-board/) — the board serves a page over
the address it just handed out, which is the first time anything on this road is
useful without a toolchain.
