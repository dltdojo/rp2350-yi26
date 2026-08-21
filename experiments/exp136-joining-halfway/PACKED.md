# Pack verification — exp136-joining-halfway

verified: 2026-08-06
steps: 8 of 8 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 7949d6835e0d1fc8

Unpacked into an empty directory, `FLASH.txt` followed. Two firmware images,
two terminals, binary frames sent with `printf` on a raw port.

    1  unzip            two .uf2, one per framing
    2  flash length-prefix  [HUMAN STEP — machine substitute used]
    3  listen           deframer: length-prefix, max payload 128 bytes
    4  one clean frame  msg #1: 5 bytes: hello
    5  join halfway     msg #2: 5 bytes: world, found after discarding 3 bytes
    6  flash cobs       7 bytes discarded, no message
    7  join halfway     msg #1: 5 bytes: world, found after discarding 4 bytes
    8  side by side     —

The contrast reproduced exactly:

    length-prefix   delivered BOTH, by hunting for a magic byte
    cobs            LOST the first, then locked on with certainty

Step 6 is the one that looks like a bug and is the point. COBS discards a
whole valid frame because it attached mid-stream and cannot know whether seven
bytes are a frame or the tail of one. It refuses to guess. Length-prefix does
guess, which is why it got the first message — and why it can deliver a
message nobody sent, when a payload happens to contain the magic byte.

One loses messages, the other invents them, and neither is safe in general: a
lost message can be detected and an invented one cannot.

TWO THINGS THIS RUN FOUND, both about the walkthrough being usable at all.

  * **The frame formats had to be worked out before they could be written
    down.** `printf 'hello'` is discarded by both builds, and so is
    `\xa5\x05hello` — the length-prefix header is THREE bytes, magic plus a
    two-byte little-endian length. Four sends were wasted before that was
    established. The walkthrough now gives the exact bytes for both framings
    so nobody repeats it.
  * **The port must be in raw mode.** These are binary frames and a cooked
    terminal mangles them; the walkthrough says so before step 1 rather than
    in troubleshooting, because a mangled frame looks exactly like a firmware
    that does not work.
