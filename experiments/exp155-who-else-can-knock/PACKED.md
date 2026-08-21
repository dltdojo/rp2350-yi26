# Pack verification — exp155-who-else-can-knock

verified: 2026-08-06
steps: 9 of 9 executed on a phone, 4 marked HUMAN STEP
host: Android (Pixel 9a), Chrome, Ethernet tethering — Pico 2 (non-W)
hash: c48d8ec4b280f16b

The zip built by `pack.sh` was unpacked **on the phone** and its `FLASH.txt`
was followed from step 1 to step 9 of the phone route, with nothing read from
the repository. This is the first zip in this repository walked on a phone
rather than on the machine that built it, and it is the route the experiment
exists for: the reader has no toolchain, no serial port and no `yi26`.

It ran on the **other board** — chip `0x7fcaf01f 0x5613a90c`, not the
`0x9952f83a 0x9b934884` every `Expected output` here is captured from. The two
are never on the same bench, so this is also the first time the network road's
result has been seen twice on two different pieces of silicon.

## What each step actually did

    1  unpack          pages/ and firmware/ out of the zip, in the Files app
    2  flash           pflash.html over PICOBOOT: 181760-byte .uf2, 90880 bytes
                       at 0x10000000, FLASH_ERASE 23 sectors, WRITE in 23
                       chunks, 256 bytes read back and matched, REBOOT2
                       [HUMAN STEP — a file picker and two taps]
    3  tether          Ethernet tethering on, straight away
    4  LED             fast blink  [HUMAN STEP — nothing else can see it]
    5  open the drive  YI26 BOARD appeared in the Files app
    6  OPEN.HTM        "The board is at this address", opened as content://,
                       and the link went to http://10.206.115.250/
                       [HUMAN STEP — a tap]
    7  the index       chip 0x7fcaf01f 0x5613a90c, up 94 s, the four-door table
                       and the five LED links, all rendered
    8  /log            the firmware's own log, in a browser with no WebUSB
    9  /trng           32 bytes, sampling 10785 us  [HUMAN STEP — reading it]

Step 6 is worth naming: the page was a `content://` URI and the link still
worked, because a **navigation** is not mixed content. exp150 measured that a
`fetch` and an `<iframe>` from such a page are both refused. The one thing that
goes through is the one thing this drive uses.

The phone's subnet was `10.206.115.x` — the same one exp151 and exp153 saw on
this phone across sessions — and the board pinned itself to `.250` of it, which
is the whole reason the address on the drive is worth bookmarking.

## Two defects it found, both invisible from a desktop

**1. Retained log lines were being cut mid-word.** `usb-log` truncates at 96
bytes *including the `[   45 ms] ` stamp* and says nothing. Two banner lines
were 88 characters and reached the phone ending in `…needs a header an` and
`…After that i`. Fixed by shortening them, and `check.sh` now computes the
static width of every retained line so it cannot come back.

The half worth more than the fix: the line that records **who knocked** could be
pushed over 96 by its own runtime value, so a long `Origin` would have lost its
tail silently. It is now truncated where it can be marked — `…not-fit.e~` — for
the same reason exp153 stopped a page showing a button labelled `http://10`.

**2. `/trng` ran off the right edge and never came back.** Chrome does not wrap
`text/plain`, so one long header line and 32 bytes of hex per line meant the
number the experiment is about was off-screen. A plain-text body has no
stylesheet to fix that afterwards, so the wrapping is now in the bytes: 32
columns, and the two costs on separate lines.

## What has not been re-walked, said plainly

Both fixes landed **after** the walk, so the zip that was followed is not
byte-for-byte the one this record is stamped against. The steps, the commands
and the order are unchanged; what changed is what two screens *show*:

- **`/log`** — the same page, with two banner lines no longer cut. Seen on the
  phone in its broken form; the fixed form is confirmed on Ubuntu only.
- **`/trng`** — reflowed to 32 columns. This is the one that was measured
  broken on a phone and has **not** been seen on a phone since.

Neither can change whether a step succeeds. Both are worth thirty seconds of
somebody's phone the next time one is in front of this board, and if the reflow
is not enough, that is a finding and this section is where it goes.

## Re-stamped 2026-08-21, and the firmware is provably untouched

A sibling experiment was renumbered from exp154 to exp161, and this
experiment's prose and comments followed it: eight comment lines in
`src/main.rs`, one `check.sh` message, and two README sections. The content
hash covers every file in the directory, so it moved.

**The firmware did not.** Every changed line in `src/main.rs` is a comment, and
that was checked rather than assumed: the pre-rename source and the post-rename
source were each built and converted, and both `.uf2` files hash to
`7774d4db2de96f1b903d96c083e4bd8e29acc9d41603a2d2597e4365a7aed9db`. The zip a
Pixel 9a walked on 2026-08-06 carries the same bytes this directory builds
today, so the walk is not re-opened by the rename. Re-stamped without
re-walking, and the identical hash is why.
