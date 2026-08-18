# Pack verification — exp107-debug-logging

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 607578f28ce170cb

The zip was unpacked into an empty directory and its `FLASH.txt` followed. The
instrument is `cat`, which is on every machine — no `yi26` and no repository.

What each step actually did:

    1  unzip           firmware/exp107-debug-logging.uf2
    2  flash           43520 bytes  [HUMAN STEP — machine substitute used]
    3  leave it alone  —
    4  wait, then read stty -icrnl; timeout 8 cat  ->  33 lines
    5  read the gap    [7087 ms] heartbeat #8
                       [21037 ms] (+26 lines lost) scheduler: 210 wakeups
                       [21088 ms] heartbeat #22
    6  interleaving    scheduler and heartbeat, one second apart, offset 50 ms

Step 5 came out at exactly the numbers in the README's own capture, +26 and
#8 to #22, because the walkthrough asks for the same twenty-second wait that
`run.sh` uses. A 22-second wait during preparation gave +30 and #8 to #24 —
the numbers move with the wait, the shape does not, and the walkthrough says
so rather than presenting one run's arithmetic as a constant.

Nothing was missing and nothing needed fixing. exp105's ModemManager finding
was already carried into this walkthrough's troubleshooting before the run,
which is the only reason step 4 did not hang the way exp105's step 4 did.

The LED is mentioned by the firmware ("heartbeat #1 (LED flashed)") and was not
observed. Nothing here depends on it: the heartbeat's own numbering is the
evidence that the task kept its rhythm, and that arrives as text.
