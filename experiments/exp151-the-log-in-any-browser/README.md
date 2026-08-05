# exp151-the-log-in-any-browser — half a window, and which half

Everything this repository debugs with reaches the board over **CDC**, and
reaching CDC from a browser means WebUSB — which is Chromium only. No iPhone
has it. Neither does Firefox or Safari on Android. For a student whose only
computer is one of those phones, this repository has been unusable since the
first experiment that printed anything.

[exp150](../exp150-a-page-served-by-the-board/) found the way round it and
deliberately did not take it: it served a *status page*, not the log, because
serving the log means giving [`usb-log`](../../crates/usb-log/) a second
consumer, and that crate is the one instrument everything here is debugged
with. This experiment does it, carefully.

**The result is half a window.** Reading the board's log now needs no WebUSB,
no permission dialog, no Chromium and nothing installed. *Finding* the board
still does — the address has to come from somewhere, and until
[exp152](../exp152-the-volume-that-waits/) that somewhere was the log, over
CDC, in Chromium. This README is careful about which half is which, because
the missing half is what the next experiment exists for.

## Two consumers, opposite rules

`usb-log` gains a `retain` feature: the most recent lines are also kept in a
ring something else can read. The queue that goes to the serial port is
untouched, and with the feature off the crate compiles to exactly what it
compiled to before — which is why exp147, exp148 and exp150 build
byte-identically either way.

```text
  the queue    drops the NEWEST when full   — its reader is already there
  the ring     drops the OLDEST when full   — its reader arrives late
```

Somebody who opens a page two minutes after plugging the board in wants what
just happened. Somebody watching a serial port wants not to miss the next
thing. Neither policy is right for both, so there are two.
[`crates/log-ring`](../../crates/log-ring/) decides which lines survive and has
no I/O in it, so `cargo test` can wring it out on a machine with no board.

## The bug a board found

Reading the log over HTTP logs lines about reading the log over HTTP, and the
page refreshes itself every three seconds. Measured before the fix:

> **58 of the 64 retained lines were the reader's own footsteps.**

The log had been erased by the act of reading it — worse than the observer
effect `usb-log`'s own documentation warns about, which is only about timing.

So `usb-log` gained `log_transient!`: the serial stream gets the line, the ring
does not. Measured after: zero request lines retained, and the serial port
still sees all of them. The request count moved onto the page, where counting
costs no history. [exp152](../exp152-the-volume-that-waits/) pays for the same
lesson a third time, one layer down, and that is where the rule was finally
written out.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. `pack.sh` lifts this section verbatim into that zip, so
there is one copy of the procedure and it is this one.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 (RP2350A, LED on GPIO 25) and a USB data cable.
  * Ubuntu with NetworkManager — `nmcli`, which a desktop install already has.
  * `unzip`, and any browser at all. Not Chromium in particular: that is the
    entire point of this experiment.
  * Nothing else. No udev rule, no `input` group, no root.

1. UNPACK IT.

       unzip exp151-the-log-in-any-browser.zip
       cd exp151-the-log-in-any-browser

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold the BOOTSEL button
   down, plug the board in, then let go. A drive called `RP2350` appears.

       cp firmware/exp151.uf2 /media/$USER/RP2350/

   The board reboots by itself as the copy finishes and the drive vanishes.
   That is success, not an error — some file managers report it as one.

   *Without hands:* if the board is already running exp105 or later, it reboots
   itself when its port is opened at 1200 baud, so `yi26 flash exp151.uf2`
   does the whole thing — but `yi26` needs the repository. A board running
   exp101–exp104 has no such watcher and there is no substitute for the button.

3. FIND THE BOARD'S NETWORK INTERFACE. It is named after the experiment.

       nmcli -t -f DEVICE,TYPE,STATE device | grep enx

   Expect a line beginning `enx022600000151:ethernet:`. What follows may be
   `disconnected`, `connecting (getting IP configuration)` or `connected`,
   depending on how far NetworkManager got adopting the new wired device on its
   own. Step 4 overrides whatever it decided.

4. BECOME ITS DHCP SERVER. This board asks for an address and will not invent
   one; until something answers, there is nothing to connect to. That is not a
   limitation — exp150 measured that a board which assigns itself an address is
   unreachable from the browser it is trying to serve.

       nmcli connection add type ethernet ifname enx022600000151 \
             con-name yi26-exp151 ipv4.method shared
       nmcli connection up yi26-exp151

   Expect: `Connection successfully activated`, in whatever language your
   machine is set to.

5. WAIT ABOUT FIFTEEN SECONDS. **[HUMAN STEP]** The LED tells you where you
   are without your having to read anything:

       dark    no link
       slow    link up, still asking for an address
       fast    address in hand, nobody has read the page
       solid   a browser got the log

   *Without eyes:* the same four states are in the serial log, and step 6
   answers the only question that matters anyway — if the address serves a
   page, the board got an address. Nothing here needs the LED to proceed.

6. OPEN THE LOG IN A BROWSER — any browser — at:

       http://10.42.0.250/

   That exact address, on a machine with no other shared connection:
   NetworkManager hands out `10.42.0.x` and the board pins itself to `.250` of
   whatever subnet it is given. Or check it without a browser:

       curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://10.42.0.250/

   Expect: `200` and a couple of thousand bytes.

   **What you get is the board's own log**, dark background, monospaced,
   refreshing itself every three seconds, headed with the address and the
   chip's ID and a line reading `up N s, M request(s) answered`. No WebUSB, no
   permission dialog, no chooser, nothing installed. That page is the
   experiment.

7. PUT THE MACHINE BACK.

       nmcli connection delete yi26-exp151

IF IT DOES NOT WORK
  * No `enx…` device at all — the board is not running this firmware, or the
    cable is charge-only. A charge-only cable is the commonest single cause of
    everything in this repository.
  * The address times out — check step 4 with `nmcli connection show --active`;
    `yi26-exp151` has to be listed.
  * You are on a machine with another shared connection, so the subnet is not
    `10.42.0.x`. Read the real address off the serial log, or use
    [exp152](../exp152-the-volume-that-waits/), which puts it on a drive.
  * The page loads but `request(s) answered` never rises — that is your
    browser's cache. The count is on the page precisely so this is visible.

## Expected output

Captured on Ubuntu, 2026-08-05, on a Pico 2 flashed hands-free by `yi26 flash`.

```console
$ yi26 log --seconds 22
[      44 ms] exp151 up. The log goes to CDC *and* to anyone who asks over HTTP.
[      45 ms]   asking for an address — whoever is on the other end is the server here.
[      45 ms]   serving the log itself on port 80, at whatever address I am given.
[      45 ms]   and answering to yi26.local, so nobody has to know the number.
[      45 ms]   LED: dark=no link, slow=still asking, fast=I have an address, SOLID=page served.
[      45 ms] 0 ms  link DOWN — nothing has claimed the NCM interface
[     445 ms] 400 ms  link UP, still asking for an address
[   13656 ms] mdns: listening as yi26.local
[   13657 ms] pinning: was given 10.42.0.213/24, taking 10.42.0.250 instead
[   13657 ms]   the subnet is the stable part; the lease is not. Bookmark the new one.
[   13697 ms] 13651 ms  I am at http://10.42.0.250/ — 0 request(s) served
[   13697 ms]         gateway 10.42.0.1 — there is a way out of here
```

The lease was `.213` and the board took `.250`. A bookmark is only as durable
as the address it points at, and a leased address is the server's business;
pinning makes it a property of the subnet, which is the part that stays put.

```console
$ curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://10.42.0.250/
200 2738

$ ./check.sh
PASS  builds (136704 byte .uf2)
...
NOTE  enumerated as: exp151 the log in any browser
PASS  the board has an address and says so — http://10.42.0.250
PASS  it served its own log over HTTP (65 lines, 0 of them about serving)
PASS  and reading it did not fill it with the reading
```

31 checks, exit 0. That middle line is the whole of the fix above: sixty-five
lines held and not one of them about serving.

## The name, and what a host does with it

The board answers to **`yi26.local`**. Android has resolved `.local` since 2021
by sending an ordinary DNS query to `224.0.0.251:5353` and waiting for a reply
— RFC 6762 §5.1, *one-shot multicast DNS* — so the responder needed is small:
receive, check the question is ours, answer whoever asked. No probing, no
announcements, no service discovery, no caching. Those exist because a real
network has many responders; a USB cable has one host on the other end. The
protocol is in [`crates/mdns`](../../crates/mdns/), with no socket in it.

**On a Pixel 9a it returned `NXDOMAIN`, and the board's log showed the question
never arrived.** That is the finding exp151 shipped with.

**On this Ubuntu host it does not resolve either, and the reason is different
and more interesting.** Measured 2026-08-05, with `avahi-daemon` active and
`nsswitch.conf` carrying `mdns4_minimal`:

```console
$ getent hosts yi26.local        # nothing
$ ping -c1 yi26.local
ping: yi26.local: 名稱或服務未知
```

...while the board, during those same seconds, reported:

```text
mdns: answered yi26.local -> 10.42.0.250
mdns: answered yi26.local -> 10.42.0.250
mdns: answered yi26.local -> 10.42.0.250
mdns: answered yi26.local -> 10.42.0.250
```

So the question arrives, and it is answered, four times, and the host still
says the name does not exist. The reply is not the problem — asked directly and
decoded byte by byte, it is exactly right:

```text
be ef 84 00 00 01 00 01 00 00 00 00  04 79 69 32 36 05 6c 6f 63 61 6c 00 00 01 00 01
04 79 69 32 36 05 6c 6f 63 61 6c 00  00 01 80 01 00 00 00 78 00 04 0a 2a 00 fa

id=0xbeef flags=0x8400 (response, authoritative) qd=1 an=1
question: yi26.local type=1 class=0x0001
answer:   yi26.local type=1 class=0x8001 ttl=120 rdlength=4 rdata=10.42.0.250
54 bytes, all 54 consumed.
```

Cache-flush bit set, TTL 120, the address right. **The likely reason avahi
ignores it is that the answer is sent unicast, straight back to whoever asked**
— `send_to(&tx[..len], from.endpoint)`, which is precisely what a one-shot
querier like Android wants and precisely what RFC 6762 §5.4 says a *multicast*
query should not get. A full responder expects the answer on the group.

That last step is inference, not measurement: nothing here captured avahi's
query to confirm it lacked the unicast-response bit. **What is measured** is
that the question arrives, the answer leaves, the answer is well formed, and
the host does not accept it.

`dig` calls the same reply malformed and prints its address as unknown-type
RDATA (`\# 4 0A2A00FA`, which is `10.42.0.250`). That is `dig` being strict
about class `0x8001`, not a defect in the packet — the decode above is the same
bytes, parsed without complaint.

[`go.html`](./go.html) exists because a phone's address bar *searches Google*
for `http://yi26.local/`, scheme and all, so the name has to be tappable rather
than typable. On the evidence above, on a host where the name does not resolve,
that link goes nowhere — which is exactly the wall exp152 was built to get
round.

## What this experiment does not do

- **It does not let a browser without WebUSB find the board.** That is the
  missing half, said plainly. The address comes out of the CDC log, which needs
  the WebUSB this experiment exists to escape. [exp152](../exp152-the-volume-that-waits/)
  closes it by putting the address on a drive.
- **It does not serve anything but the log.** The request line is read and
  thrown away — parsing untrusted input in a firmware is a real decision, and
  every path returns the same page, so there is nothing a path could select.
- **`http://` is not a secure context**, permanently. The origin this board
  serves can never also use WebUSB. This road opens one door by closing another.
- **It has no server role.** `ask-for-an-address` is not a feature here, it is
  the only arrangement exp150 found reachable from a phone's browser.

## Make it yours

- Turn `retain` off and watch the page serve an empty ring. The feature costs
  about 6 KiB, and it is off by default for every other experiment here.
- Shrink the ring to eight lines and reload the page twice. What survives is
  `crates/log-ring`'s policy, and it has tests you can change first.
- Answer the mDNS query by multicast instead of unicast and find out whether
  `getent hosts yi26.local` starts working. That is the one experiment this
  README could not finish, and it is a small change to `crates/mdns`.

## Troubleshooting

**`curl` works and a browser does not.** Check the worker count before anything
else — a browser opens more connections than `curl` does, and smoltcp has no
listen backlog, so N workers serve exactly N simultaneous connections. exp150
measured that from both sides.

**Everything times out and the log shows no connection.** The packets are not
reaching the board. On a desktop, check that `ip route` has a route to the
shared subnet; on Android, see exp150 — that is the expected result there.

**The board is enumerated but `yi26 log` shows nothing.** `yi26 doctor`, and
see [the tools README](../../tools/README.md).

## Next

[exp152](../exp152-the-volume-that-waits/) — the board carries a drive that
does not exist until it knows its own address, so the half this experiment left
open is closed by a file you tap rather than a name you type.
