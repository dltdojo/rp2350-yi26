# tools/pages/

Five pages that are **tools**, not experiments. Each one works against every
firmware in this repository, needs no toolchain, no server and no build step,
and is opened by double-clicking it.

| Page | What it answers | Which interface it claims |
| --- | --- | --- |
| [`inspect.html`](./inspect.html) | what is inside this device — configurations, interfaces, endpoints | none; it only reads descriptors |
| [`log.html`](./log.html) | what the firmware is printing, live | the **CDC** pair |
| [`console.html`](./console.html) | the same log, plus whatever you type going back to the board — including a zero-length packet to end a message | the **CDC** pair |
| [`bootsel.html`](./bootsel.html) | put this board into its bootloader so it can be reflashed | the CDC control pipe, briefly |
| [`pflash.html`](./pflash.html) | write a `.uf2` into a board that is already in BOOTSEL, and reboot it into the new firmware | the **PICOBOOT** vendor interface |

`log.html` and `console.html` both claim CDC, so they cannot be open at the
same time — **one interface has exactly one owner**. Use `console.html` when
you want to talk back and `log.html` when you only want to watch.

**Writing one of these for somebody else to run?** Read
[`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md) first. These
pages are used on a phone by a person the author cannot see, over a link made of
screenshots, and that decides more about how they are written than any style
rule here: what they log, when they log it, and what their error messages are
allowed to claim.

**Every page here is named after the `yi26` subcommand that does the same job**
— see the table below. `bootsel.html` sends what `yi26 bootsel` sends,
`pflash.html` sends what `yi26 pflash` sends, in the same order. So an
instruction written for one reads correctly for the other, and neither name has
to be explained.

`bootsel.html` was called `flash.html` until 2026-08-05, which was wrong twice
over: it flashes nothing, and it sat beside `pflash.html`, which does. The two
names differed by one letter while the things they did did not overlap at all,
and this README used to carry a paragraph explaining that they were not
duplicates. **A name that needs defending is a name doing somebody else's
work.** Together they are the whole flashing cycle from a phone — which stopped
being optional when
[exp144](../../experiments/exp144-one-file-either-half/) measured that a board
with a partition table takes nothing from its BOOTSEL drive.

**On a board's own volume, this page is still called `FLASH.HTM`, and that is
a decision.** [exp131](../../experiments/exp131-the-volume-is-the-app-drawer/),
[exp133](../../experiments/exp133-a-page-per-job/) and
[exp137](../../experiments/exp137-the-volume-that-changes/) embed it under that
8.3 name, beside `INDEX.HTM` and `LOG.HTM`. Those three answer *what this board
does*, *how to read it*, and *how to replace it* — a list of goals, read by
somebody holding a phone with no other context. `BOOTSEL.HTM` would be the
precise name and the wrong one there: it names a mechanism to a reader who has
not been told the mechanism exists. The collision that forced the rename here
does not exist there either, because no volume carries `pflash.html`.

Two audiences, two names, on purpose: this directory is read by somebody who
also has a command line, and a volume is read by somebody who has nothing else.

## Two toolboxes, and the line between them

This repository has two ways to talk to a board: [`yi26`](../README.md), a
command-line program, and these pages. They overlap, but only in four places:

| The job | Command line | Browser |
| --- | --- | --- |
| read the log | `yi26 log` | `log.html`, `console.html` |
| send bytes | `yi26 send` | `console.html` |
| into the bootloader | `yi26 bootsel` | `bootsel.html` |
| write firmware, no drive | `yi26 pflash` | `pflash.html` |
| look at the descriptors | `yi26 doctor` | `inspect.html` |

Everywhere else they do not overlap, and the reason is worth knowing because it
is not going to change:

| Only `yi26` can | Why a page cannot |
| --- | --- |
| `doctor`, `state`, `port` | they read the host's USB tree and the processes on it |
| `udev --install` | it writes to `/etc/udev/rules.d/` as root |
| `drive`, `flash` | they mount a filesystem and copy a file into it |
| `markers` | it decodes a `.uf2` container off the disk |
| `detach` | it takes an interface away from a kernel driver |
| `flood --storm` | it writes and toggles RTS from two threads at once |
| `fido info` | it opens a `/dev/hidraw` node, and these pages have no HID access at all — browsers additionally exclude FIDO devices from WebHID, which is upstream policy this repository has not measured |

| Only a page can | Why the CLI cannot |
| --- | --- |
| run with **no toolchain installed** | `yi26` has to be compiled first |
| ~~end a message with a zero-length packet~~ | it could not, until `yi26 send --end` gave up its serial port to do the same thing — see [exp135](../../experiments/exp135-a-packet-with-no-bytes/) |
| run on a **phone** | there is no terminal, and the board is in the only port |
| **ship on the board itself** | exp126 onwards serve these files off a volume the firmware presents; a phone that has the board has the tools |

So the two sides are **not** meant to converge. A page that could write udev
rules would be a browser bug, and a CLI that pretended it had no filesystem
would be less useful for nothing. What must stay in step is the four jobs
above, and in particular the **vocabulary**.

### The vocabulary that is checked

`console.html` accepts the same six escapes as `yi26 send` — `\n` `\r` `\t`
`\0` `\\` and `\xNN` — and refuses anything else rather than guessing.
`check.sh` runs the page's parser through the fixtures `tools/yi26`'s own unit
tests use, and separately compares the *set* of accepted escapes on both sides,
because a form added to one and not the other would pass the fixtures unseen.

That matters more than it looks. An instruction that says *send `\x01`* has to
mean one byte whichever half of the repository the reader is holding. Before
this, it did not: exp120's page could send text only, so the byte that turns on
exp127's LED could not be typed into a browser at all, and typing `1` sent
`0x31`, which that firmware correctly refuses.

Verified against a Pico 2 running exp127 on 2026-08-03: `\x01` from the page
turned the LED on, `\x00` turned it off, and `1` was refused as `0x31` — the
same answer `yi26 send 1` gets. The capture is in
[exp127's README](../../experiments/exp127-host-owns-the-led/#the-same-thing-from-a-browser).

The **terminator** is the second thing that has to stay in step. The tick box
appends a zero-length packet, and both halves add it under the same rule —
only when the payload is a non-zero multiple of the endpoint's packet size,
which the page reads off the descriptor rather than assuming 64. That parity is
asserted in
[exp135's `check.sh`](../../experiments/exp135-a-packet-with-no-bytes/check.sh)
rather than here, and the measurement showing Chrome and `nusb` agree on the
wire is in
[exp135's README](../../experiments/exp135-a-packet-with-no-bytes/#the-browser-row-2026-08-03).

## What belongs here, and what does not

One question decides it:

> Does this page work against **every** firmware in this repository?

If yes it is a tool and it lives here. If no it is an **appliance** — it knows
one firmware's protocol — and it belongs to the experiment that defines that
protocol. exp130's and exp133's prize-draw pages are appliances and stay where
they are.

The sharpest form of the distinction is a filter. exp133's appliance page asks
for `serialNumber: '133'`, because Chrome identifies a device by vendor,
product *and* serial, and pinning the serial means its picker offers exactly
one board. A tool may never do that: every firmware here sets its serial to its
own experiment number, so a tool that pinned one would work against exactly one
experiment. `check.sh` enforces it.

**An appliance may be picky. A general tool may not.**

## Where these came from, and why a copy stayed behind

Every page here was built by an experiment, and **that experiment still has its
own copy**:

| Tool | Built by | The copy still there |
| --- | --- | --- |
| `inspect.html` | [exp115](../../experiments/exp115-webusb-enumerate/) | `usb-inspector.html` |
| `log.html` | [exp116](../../experiments/exp116-webusb-cdc-log/) | `cdc-log-viewer.html` |
| `bootsel.html` | [exp117](../../experiments/exp117-webusb-reboot/) | `reboot.html` |
| `console.html` | [exp120](../../experiments/exp120-webusb-two-way/) | `two-way.html` |

That is deliberate, and it is the opposite of what a tidy-up would do. This
repository's experiments are read in order, and each one's page *is* its
walkthrough — replacing exp116's file with a link to somewhere else would
delete the thing a reader came to exp116 for. exp120 is the clearest case: its
page cannot send `\x01`, and that limitation is the whole reason `console.html`
exists. A link would hide it.

The copies are not maintained and they say so, on the page itself, in a box a
reader sees before anything else. `check.sh` asserts that every one of them
says it and names its replacement, because a stale page that does not announce
itself is worse than no page.

**Fixes go here.** The firmwares from exp126 onwards `include_bytes!` these
files, so a fix reaches every board by rebuilding and by nothing else.

## Checking

```sh
./check.sh    # no board, no browser: self-contained, no serial filters,
              # escape parity with yi26, and every frozen copy still says so
```

The one thing it cannot check is a browser: opening a page, picking a device
from a native dialog and pressing a button needs a person. That is what the
experiments' own `run.sh` scripts are for.

## If you are an AI assistant

These pages are not how you talk to a board — `yi26` is, and it can do the
ten things in the table above that a page cannot (an earlier version of this
sentence said eight, and had not counted `flood --storm`; `fido info` is the
tenth). Open one only when the page
itself is what you are verifying. See [`AGENTS.md`](../../AGENTS.md).
