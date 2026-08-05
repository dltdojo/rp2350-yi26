# Pack verification — where this got to, and how to carry it on

Every experiment here can be put in a `.zip` somebody without a checkout can
flash from — [`experiments/pack.sh`](../experiments/pack.sh). A zip carries the
firmware, the pages that write it from a phone, the experiment's README, the
output of the `check.sh` run that built it, and a **standalone walkthrough**:
every step, every command, and what each one should print, for a reader who has
the zip and nothing else.

A walkthrough nobody has followed is a guess. So each one is walked once —
unzipped into an empty directory, followed from step 1, with nothing read from
the repository and no command invented that the file does not carry — and the
result recorded in that experiment's `PACKED.md`, bound to a hash of everything
that decides the procedure or the firmware.

```sh
./pack.sh --status          # 52 rows: verified / STALE / never done
./pack.sh --stamp expNNN    # bind a written record to what it describes
```

Experiments here are frozen once made, so **once is the right number of times**.
When one does move, the hash stops matching and the row says `STALE` rather
than saying nothing.

## Where it got to

**24 of 52 verified**, on 2026-08-06, on Ubuntu against a Pico 2 (non-W).

```
exp102 exp105 exp107 exp108 exp109 exp110 exp111 exp112 exp113 exp114
exp118 exp119 exp121 exp122 exp123 exp124 exp125 exp128 exp129 exp134
exp136 exp140 exp151 exp152
```

Run `./pack.sh --status` for the current answer; the list above is what one day
produced and it is not maintained by hand.

## What is left, in the order to do it

### 1. Two that need nobody — start here

| | Why it is easy |
| --- | --- |
| **exp137**-the-volume-that-changes | PRESENCE 1, no partition table, no watcher problem |
| **exp138**-what-the-rom-already-knows | PRESENCE 1, reads ROM only — **writes no flash** |

### 2. Five that need somebody in the room

**exp139, exp142, exp143, exp144, exp145.**

These install a **partition table**, and a board with one takes *nothing* from
the BOOTSEL drive — that is exp144's own finding. From then on the board is
reflashed through `pflash.html` in a browser, or recovered by a physical BOOTSEL
press. `exp139/run.sh` says so in its own header:

> a physical BOOTSEL press to recover — see the README's "If it goes dark"

**Do not start these unattended.** One of them going dark stops everything after
it until a hand arrives. Doing all five in one sitting, with somebody able to
press the button, is the cheap way.

### 3. One that strands the board on its own

**exp104**-usb-serial has no 1200-baud watcher — it and exp103 are the only two
firmwares here without one. Flash it and the next flash needs the button.
Whatever else is planned, do exp104 **last**.

### 4. Twenty-two that need a person as the instrument

Thirteen at PRESENCE 2 (a browser permission dialog, a BOOTSEL press) and nine
at PRESENCE 3 (an LED, a phone). They can be walked as far as the human step and
recorded as `verified to step N`, which is what exp151 and exp152 already do.

## What the walking found

The point of following each zip was to find what reading it would not. A
representative list, all of them fixed unless marked otherwise:

- **exp105** — `stty -F /dev/ttyACM0 1200` hung with no output and no error.
  Ubuntu's ModemManager opens every new `ttyACM` for a few seconds, and the
  walkthrough's touch lands inside that window because it follows the flash.
  This would have hit every reader. Every later walkthrough carries the wait.
- **exp119** — the first walkthrough to ship a program, and its heredoc arrived
  indented, so the Python it delivered was an `IndentationError`. Broken in the
  README *and* in the packer. `pack.sh` now leaves fenced blocks at column zero.
- **exp109** — the `upstream-default` build does not merely make entropy
  expensive; after one draw it **stops producing at all**, while the heartbeat
  task keeps running beside it. The experiment's own capture stops two lines
  before this is visible. Measured, not diagnosed.
- **exp111, exp114** — walkthroughs that printed one run's numbers as if they
  were constants, when the numbers were the experiment's own noise.
- **exp102** — an experiment that never touches a board was being handed
  flashing pages, flashing routes and board-troubleshooting. `pack.sh` now
  recognises `USB_RUNS_ON="none"`.
- **exp112, exp128** — `firmware/` carrying more images than the experiment
  means, one of them a build by-product with the most official-looking name.
- **eighteen firmwares** print advice naming `yi26`, which is not in any zip and
  cannot be. `pack.sh` detects it and says what to use instead.

Three experiments needed a host-side tool that no shell command can be, so their
walkthroughs carry one: `flood.py` for exp119 (packets and RTS toggles on one
open port), `vecho.py` for exp122 (raw USB to an interface with no device node,
four ioctls, no pyusb).

## Conventions worth keeping

- **`## Do this, in order`** in a README is lifted verbatim into that zip's
  `FLASH.txt`. One copy of the procedure, and it lives where a reader already
  is. Markdown links are flattened; fenced blocks keep their indentation.
- **`[HUMAN STEP]`** marks a step only a person can do, and is followed by a
  machine equivalent where one exists. Where none exists — a hand on BOOTSEL for
  a board with no watcher — the walkthrough says so instead of pretending.
- **A record says what was not done.** `PACKED.md` names the steps that were
  substituted and the ones that were skipped, because a verification that hides
  its gaps is worth less than no verification.
