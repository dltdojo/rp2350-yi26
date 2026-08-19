# exp155-who-else-can-knock — an experiment that exists only on a board

**There is no source here, and there is unlikely ever to be.** This directory
is a record, not an experiment. It exists so the number is not reused and so
the next reader is not left wondering why the sequence skips.

## What is known, and how

A board on this bench is running a firmware that identifies itself as
**`exp155 who else can knock`**, USB serial **155**. It was read on 2026-08-18
through [exp154's page](../exp154-somewhere-to-put-a-key/otp-map.html), which
connected to it by accident while looking for something else — and said so,
which is the only reason any of this is written down.

Everything below is **read off its own log**. No source was consulted, because
none was found.

```text
exp155 up. The LED can now be set over HTTP, and the log says by whom.
  asking for an address — whoever is on the other end is the server here.
  port 80: / /log /status /trng, plus /led/<on|off|slow|fast|auto>.
  /led is open to anybody who can route here; /control/led needs a header and my o...
  and answering to yi26.local, so nobody has to know the number.
  LED until an address arrives: dark=no link, slow=still asking. After that it...
REQUEST SENSE  -> key 2 asc 3a
140567 ms  link UP, still asking for an address
```

So it is [exp153](../exp153-out-through-the-phone/)'s stack — CDC-NCM, DHCP
client, HTTP on port 80, mDNS answering to `yi26.local`, and a mass-storage
volume — **plus something new**: the LED can be set over HTTP, and there are
two doors to it. `/led` is open to anyone who can route to the board;
`/control/led` wants a header. That is an experiment about **authorisation**,
and it is the question [exp127](../exp127-host-owns-the-led/) opened when one
byte from a host first changed the board.

It had got far enough to be worth finishing. It was not finished.

## Where it went

It was built by a Claude Code session titled **RP2350手機測試**
(`session_014mFHSDdRKeQ2fbmxbx99yN`), 2026-08-05 to 2026-08-06, working on
`main`. The session is archived and its working directory is gone. Its last
recorded state names the same two routes the board prints:

> *fixes validated on two chips; awaiting reburn validation of `/trng` & `/log`
> wrapping*

Nothing was ever pushed. Searching this repository's history for
`who else can knock`, `/trng` and `/control/led` returns nothing — with the
caveat that the clone this was written in is shallow, so "not found" is weaker
evidence than it looks.

**The binary on the board is the only copy.** `picotool save`, or PICOBOOT
through [`pflash.html`](../../tools/pages/pflash.html)'s sibling read path, can
recover a flashable `.uf2` from it. Neither recovers source.

## Why the number is not reused

The next experiment took **156**. This one was here first, it ran on hardware,
and something in this repository can still meet it: a board in the field
reporting serial 155 is this firmware, and `exp_running 155` should not match
something else. A number that quietly changes meaning is worse than a gap.

## What this costs, said plainly

A day's work on a real experiment exists as one binary on one board, and
everything anybody knows about it was reconstructed from a screenshot of its
own log. That is the whole argument for the rule this repository amended on
2026-08-18 — that unverified work reaches a branch with its commit message
saying so, rather than waiting in a container for a bench visit that may come
after the container is gone.

It is also, uncomfortably, the argument the log itself makes. This firmware
could describe itself well enough to be catalogued from six lines of output
because somebody wrote those six lines carefully. **A firmware that prints what
it is survives its own source.**
