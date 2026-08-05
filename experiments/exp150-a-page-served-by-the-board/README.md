# exp150-a-page-served-by-the-board — and the wall it found

The board serves its own web page over the USB link. **No WebUSB, no permission
dialog, no device chooser, no Chromium requirement, nothing installed.** That is
the prize this whole road was walked for: every page in
[`tools/pages/`](../../tools/pages/) exists inside those constraints, and a board
that serves its own page needs none of them.

The cost, written beside it because it is permanent: `http://` is **not a secure
context**, so the origin this board serves can never also use WebUSB. This road
opens one door by closing another.

**On a desktop it works. On Android it does not, and that is the finding.**

## What it serves

A status page — link, lease, uptime, requests answered, and the chip's own ID:

```console
$ curl http://192.168.7.1/
<h1>This page came off the board.</h1>
<dd>0x9952f83a 0x9b934884</dd>   <- chip id
<dd>1</dd>                       <- requests answered
<dd>5 s</dd>                     <- uptime
<dd>no</dd>                      <- gateway announced in DHCP
```

Not the log. Serving that would mean giving [`usb-log`](../../crates/usb-log/) a
second consumer and a retained ring buffer — a real feature, and a real risk to
the one instrument this repository debugs with. The question in front of this
experiment was whether a browser can reach the board *at all*, and this is the
smallest thing that answers it.

The request is **read and thrown away**. Not laziness: parsing a request line
means parsing untrusted input in a firmware, and every path here returns the same
page, so there is nothing a path could select. A URL starts meaning something in
a later experiment, and that is where the parser belongs.

## Expected output

Captured on Ubuntu, 2026-08-05.

```console
$ yi26 log --seconds 5
[      43 ms] exp150 up. CDC-ACM for this log, CDC-NCM for the link.
[      43 ms]   serving http://192.168.7.1/ on port 80
[    5839 ms] http: connection from Some(Endpoint { addr: Ipv4(192.168.7.2), port: 60744 })
[    5839 ms] http: 74 bytes of request, discarded
[    5842 ms] http: served request #1 (791 bytes)
```

Three milliseconds from connection to response, over a USB cable, from a chip
that also runs the DHCP server that gave the host its address.

## Two bugs a board found that no amount of reading would have

Both were in the connection **teardown**, both passed every static check, and
both are now guards in `check.sh`.

### Waiting for a state TCP never reaches

The first version closed the socket and waited for `State::Closed`, with a
two-second deadline as a safety net. It measured like this:

```console
$ for i in 1 2 3 4 5; do curl -o /dev/null -w '%{http_code} ' http://192.168.7.1/; done
200 000 000 000 000

$ # ...and with one second between them
200 200 200 200 200
```

> **A gracefully closed socket goes to TIME-WAIT, not to `Closed`**, and sits
> there for about ten seconds.

So the wait *always* ran to its deadline, and every request cost that worker two
seconds of not listening. With two workers that is exactly two requests before
the server goes silent — and a test with a gap between requests hides it
completely.

`flush()` is the wait that was actually wanted: it returns once the send queue is
empty and the FIN has left `FinWait1`/`LastAck`, which is to say once the data
and the goodbye are both acknowledged. What happens after that is bookkeeping the
peer does not need us for.

### The worker count is the concurrency limit

smoltcp has no listen backlog. A SYN that finds no listening socket is refused,
not queued, so **N workers serve exactly N simultaneous connections** and the
next one fails. With two:

```text
4 at once:  200 000 000 200
```

Four workers, measured:

```text
20 back to back:  ....................   (all 200)
4 at once:        200 200 200 200
6 at once:        000 000 200 200 200 200
```

That last line is not a failure — it is the property, and it is worth knowing
before somebody points a load generator at it. A browser fetching a page and its
favicon needs two; four is comfortable. Each worker costs about 3 KiB of buffers.

## Android: the wall

**Verified on a Pixel 9a, 2026-08-05.** The phone takes the address
([exp149](../exp149-the-board-hands-out-the-address/) established that), and then
Chrome at `http://192.168.7.1/` returns **`ERR_TIMED_OUT`**.

The board says where the packets did not go:

```text
link UP, 192.168.7.2 leased, 0 request(s) served
```

for 245 seconds. Not one connection arrived.

The error code carries the diagnosis. Not `ERR_ADDRESS_UNREACHABLE` and not
`ERR_CONNECTION_REFUSED` — so the packets left by *some* route and nothing
answered. They went out the phone's default network, where a private address is
blackholed.

**Why, exactly, is not settled, and the first answer written here was wrong.**
It said the interface never becomes a network Android knows about. Then the
phone was replugged with the *same* firmware and Android's **Ethernet tethering**
toggle — greyed until then — became available and was switched on. Tethering
needs an interface Android has recognised as Ethernet, so it had recognised it.
The browser still timed out and the board still recorded `0 request(s) served`.

So the measurement stands and the explanation does not. What is known: the
packets do not arrive. What is not known: which layer drops them.

There is a structural conflict worth testing before anything else, because it
would explain the whole thing without any mystery. **Ethernet tethering means
Android wants to be the DHCP server and the router on that link.** This firmware
*is* a DHCP server, on a static `192.168.7.1`. Two servers, one cable — and once
Android configures its own end for tethering, `192.168.7.1` is not on the subnet
it chose, so there is nothing to route to. That is a hypothesis, it is cheap to
test, and it points at the next experiment rather than at this one.

### The other arm of the experiment, and what it excluded

This ships **two builds**, differing in six bytes: `--features announce-gateway`
adds a DHCP router option, claiming the board is a way out to somewhere it is
not. It exists because a gatewayless network is one Android might correctly
decline to promote, and that would have explained exp149 exactly.

Identical result. So that is not the cause — the arm did its job, and a
suspicion is now an exclusion.

Both builds went in one zip. [`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md)
is emphatic that the round trip is the expensive thing, and spending two of them
to learn one bit would be ignoring this repository's own notes.

### What the wall settles

- **The default-route risk is retired.** Mobile data survived every variant,
  *including* the build announcing the board as the gateway — the worst case
  anyone had reason to fear. A USB Ethernet gadget on this phone displaces
  nothing. It also carries nothing.
- **The boundary is now measured, not assumed.** On an unrooted phone, from a
  browser: **PICOBOOT and CDC over WebUSB work; IP does not.** That is why
  `tools/pages/` is built the way it is.

## The LED, and the mistake made with it

Four states, and the fourth is deliberately not a fourth *rate* — three blink
speeds is already more than somebody can tell apart across a room:

```text
  dark    no link
  slow    link up, nobody has asked for an address
  fast    address leased, and NO request has been served
  solid   a browser got the page
```

That fourth state exists so that nobody has to read a log. When the page would
not load, the person holding the phone was asked for the LED and answered
**"fast"** — which was the complete answer. They were then asked to open
`log.html`, tap through a chooser, keep a tab alive, open a second tab, wait for
a timeout, and switch back to screenshot `0 request(s) served`: the same fact,
six steps later.

Their reply was *"除錯過程太複雜"*, and it was right. The rule is now written
down where it belongs: **before asking for a diagnostic, check whether the
readout you already built answers the question.**

## Make it yours

- Serve the log. It is the obvious next thing and it is deliberately not here:
  `usb-log` drains its queue to USB and has no second consumer. Giving it a
  retained ring is a real feature — and the instrument this repository debugs
  with is the last thing to experiment on casually.
- Parse the request line and serve two pages. The moment a URL selects
  something, untrusted input is being parsed in a firmware, and
  [`crates/dhcp`](../../crates/dhcp/) is the shape that job should take: no
  socket, and a test that cuts the input at every length.
- Drop the workers to one and watch a browser fail to load a favicon.

## Troubleshooting

**`curl` works and a browser does not, on the same machine.** Check the number
of workers before anything else; a browser opens more connections than `curl`
does.

**Everything times out and the log shows no connection.** The packets are not
reaching the board. On Android that is the expected result and there is no fix —
see above. On a desktop, check `ip route show dev enx...` shows a route to
`192.168.7.0/24`.

**The page loads but the count never rises.** That is a cache. The count is on
the page precisely so that this is visible.

## Next

The phone route is not IP. A page that reaches the board over **CDC/WebUSB** —
which is proven on that exact phone — and fetches on its behalf is what the road
continues into; see [the network road](../README.md#the-network-road).
