# Pack verification — exp110-await-not-block

verified: 2026-08-06
steps: 6 of 6 executed, 2 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 32ac431ba074066d

Unpacked into an empty directory, `FLASH.txt` followed. Two firmware images,
and the difference between them is the experiment.

    1  unzip           exp110-await.uf2, exp110-blocking.uf2, SHA256SUMS
    2  flash await     [HUMAN STEP — machine substitute used]
    3  read it         probe: 20 wakeups, worst lateness 13 us  at 2037 ms
                       probe: 40 wakeups, worst lateness  3 us  at 4037 ms
    4  flash blocking  [HUMAN STEP — machine substitute used]
    5  read that       probe: 440 wakeups, worst lateness 836948 us
                       probe: 460 wakeups, worst lateness 834553 us
    6  compare         3-13 us against ~836000 us, same 885 ms entropy either way

Reproduced exactly what the README's own capture claims, including the part
readers get wrong: the entropy request costs the same in both builds. Awaiting
made nothing faster. It only gave the processor back.

ONE THING THIS RUN FOUND AND FIXED. Step 5's expected output starts at
`[37 ms]`, and the run from the zip started at `[44274 ms]` — the flash took
longer that time, and a serial buffer nobody is reading holds only the last
ten or twenty seconds, which is exp107's subject arriving as a practical
nuisance in someone else's walkthrough. A reader comparing their first
timestamp against the printed one would think something was wrong.

Step 5 now says the timestamps depend on when the port was opened and the
evidence does not: the lateness figure and the wakeup count are the same at
any uptime.
