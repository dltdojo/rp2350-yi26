# Pack verification — exp112-silent-fallback

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: bb0f2c588599aff4

Unpacked into an empty directory, `FLASH.txt` followed. Three firmware images;
two are the experiment.

    1  ask the artifact  exp112-hardware.uf2  yi26-cfg:rng=hardware
                         exp112-software.uf2  yi26-cfg:rng=software
    2  flash software    [HUMAN STEP — machine substitute used]
    3  three draws       a1 72 35 03 / b2 60 70 01 / d2 aa b1 51
    4  reboot, again     a1 72 35 03 / b2 60 70 01 / d2 aa b1 51   (identical)
    5  hardware, twice   c7 1b 30 05 ... then 35 1d 15 62 ...      (nothing shared)
    6  count the misses  —

Step 4's reboot ran verbatim from the walkthrough — 1200-baud touch, wait,
copy onto the boot drive — and produced the same three lines byte for byte.
That is the experiment, and it costs ten seconds.

Step 1 is worth keeping: `strings -a firmware/*.uf2 | grep yi26-cfg:rng=`
reads the marker straight out of the image with no repository and no
`audit.sh`. It is the only check here that reads what will actually run.

TWO THINGS THIS RUN FOUND AND FIXED.

  * `exp112-silent-fallback.uf2` — the third image, and the one with the most
    official-looking name — is a BY-PRODUCT. It is whatever check.sh built
    last, so its marker read `hardware` during preparation and `software` when
    packed, from the same source. A reader running step 1 across `firmware/*`
    gets an answer that changes between packs. Step 1 now names the two
    meaningful images explicitly and says to ignore the third, with the reason.
    A wart in this experiment's build, recorded rather than hidden — and a
    small instance of the lesson: a name is not evidence.

  * Step 4 first failed during preparation because the `cp` ran before the
    RP2350 volume had appeared and been mounted, leaving the board sitting in
    BOOTSEL with nothing copied. The step now waits, says why, and tells the
    reader that running the `cp` again is the whole fix — because a board
    stuck in its bootloader looks alarming and is not.
