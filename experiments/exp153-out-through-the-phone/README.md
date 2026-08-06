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

## Reading it

Same route as exp152, because that route is the one that has been verified with a
person holding the phone:

1. plug the board in
2. turn on Ethernet tethering **straight away** — Settings → Network & internet →
   Hotspot & tethering (greyed out until something is plugged in, which is why the
   order is forced)
3. wait for the LED to blink fast; the drive appears then
4. open the drive in the system Files app, tap `OPEN.HTM`, tap the link

The **top of that page** is the result — a three-row table, above the log rather
than inside it, because that is the line somebody photographs and they should not
have to find it among a hundred others. The log underneath carries the raw first
line of each response and the `Location` header verbatim, so the parsed status
code is a convenience and never the only evidence.

On a desktop the same firmware needs the host to share its connection, which is a
`sudo` step; `curl http://<address>/` reads the same page.

## Status

**Built and hardware-smoke-tested on Ubuntu, 2026-08-06.** The board boots,
enumerates all six interfaces, the MSC volume reports NOT READY as it should
before an address exists, and the DHCP client asks. Ubuntu is not sharing its
connection, so it stops at `link UP, still asking` — which is as far as this half
of the bench can go.

**Not yet measured: the phone half**, which is the entire experiment. Until a
phone has run it, this README describes an apparatus and not a result.

The request bytes were checked against the real server from the host first: the
`301` response puts `Location: https://1.1.1.1/` at byte 154, inside the 256 bytes
the firmware keeps, so a response that arrives cannot have its most interesting
line fall off the end.
