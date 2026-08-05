# Pack verification — exp109-hardware-trng

verified: 2026-08-06
steps: 6 of 6 executed, 2 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: ec1dd86cea7c38d8

Unpacked into an empty directory, `FLASH.txt` followed, nothing read from the
repository. Two firmware images, and comparing them is the experiment.

    1  unzip          two .uf2 and SHA256SUMS
    2  flash fast     44032 bytes  [HUMAN STEP — machine substitute used]
    3  measure it     65 cost: lines in 60 s, ~5.6 ms each
    4  flash slow     43520 bytes  [HUMAN STEP — machine substitute used]
    5  measure that   1 cost: line, and nothing for the rest of the minute
    6  still alive?   73 heartbeats over the same 60 s

WHAT SIXTY SECONDS FOUND THAT A SCREENFUL DID NOT, and it is the reason this
experiment was worth walking rather than reading.

The README's capture of the `upstream-default` build stops at `heartbeat #2`,
and everything that matters happens after that. Measured here, from clean
boots, read continuously from second zero: that build produces **exactly one
round and then stops**, while the heartbeat task goes on ticking beside it.
Three runs, three times one round.

So "wrong by a factor of thousands" is not quite what is happening. Per draw
the ratio is about 65x. But the slow build does not go on being slow — it
stops, and nothing in the firmware looks wrong from outside, which is the
worst way for something that seeds a key to fail.

AND A CORRECTION THIS RUN MADE TO ITS OWN WALKTHROUGH. Step 5 was first
written expecting `363837 us`, the number the preparation run produced. Run
from the zip it printed `144 us`; an earlier run gave `50063 us`. Three orders
of magnitude, one board, one hour. The count is reproducible and the cost is
not, and the step now says so — a 144 us draw has not gathered much of
anything, which is the shape exp112 is named after, though whether it is the
same problem is not established here.

This is measured, not diagnosed: `fill_bytes().await` returned once and had
not returned again sixty seconds later. Why is not established, and one board
is not a sample.
