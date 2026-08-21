# Pack verification — exp134-the-log-nobody-reads

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: f34c363d67d2cf2c

Unpacked into an empty directory, `FLASH.txt` followed. Three firmware images,
each flashed, each left unread for twenty seconds, each then read.

    1  unzip              three .uf2, one per policy
    2  flash default      [HUMAN STEP — machine substitute used]
    3  read it            tick #1  (drop-newest)
    4  keep-recent        tick #5  (keep-recent)
    5  silent-while-idle  (+20 lines lost) tick #21
    6  side by side       —

The same board, the same work, the same twenty seconds of nobody listening,
and the first line you get reads three different ways:

    drop-newest        the beginning, and nothing about the present
    keep-recent        the present, and nothing about the beginning
    silent-while-idle  a marked hole, and the cost said out loud

Which is right depends on whether the reader arrives at the start of a problem
or in the middle of one, and there is no default that serves both. That is why
this ships as three builds.

ONE THING THIS RUN FOUND AND FIXED. The walkthrough printed #1, #7 and #23 as
the three answers. The run from the zip gave #1, #5 and #21: the last two move
with how long the wait really was and how quickly the reader attached. Only
`drop-newest`'s #1 is fixed, and it is fixed for a reason worth saying —
the beginning is the one thing that policy never loses. The comparison table
now says which of the three numbers to expect to match.
