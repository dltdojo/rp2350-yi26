# Pack verification — exp114-health-tests

verified: 2026-08-06
steps: 7 of 7 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: d692263422b49fb2

Unpacked into an empty directory, `FLASH.txt` followed. One firmware, three
sources, two tests that each catch a different one.

    1  unzip     firmware/exp114-health-tests.uf2
    2  flash     [HUMAN STEP — machine substitute used]
    3  watch 20s —
    4  header    C = 21 (repetition), W = 1024 C = 589 (adaptive proportion)
    5  adc goes  FAILED repetition count at 21 after 191 bits (this run)
                 FAILED repetition count at 21 after 293 bits (preparation)
    6  broken    FAILED adaptive proportion at 922 after 1024 bits, 5083 ms
                 -> 1 of 2 real sources still permitted to emit
    7  the point OUTPUT WITHHELD, not a warning and carry on

TWO THINGS THIS RUN FOUND AND FIXED, and the second one was my own misreading
rather than the experiment's fault.

  * Step 4 claimed all three sources report HEALTHY in the first report —
    "three for three", with the broken one included, which is the nice part of
    the lesson. Run from the zip, `adc` had ALREADY failed by the first report
    (191 bits rather than 293). Which report catches it depends on when the
    bottom bit happens to stick. The step now shows both and says `at 21` is
    the fixed part and the bit count is not.

  * Step 6 said the broken source is caught "at about sixteen seconds". It is
    caught at 5083 ms, and was in both runs, with identical numbers. The 16205
    ms line I had written it from was the same message repeating a second at a
    time — every one of these lines repeats for as long as you watch, and I
    had grepped the tail rather than the head. The step now gives the first
    occurrence, notes that this failure is reproducible to the millisecond
    while the ADC's is not, and warns the reader about exactly the mistake I
    made.

The contrast is the experiment and it survived both fixes: the repetition
count catches a source that is STUCK and needs 21 samples; the adaptive
proportion catches one that is BIASED and cannot speak until it has 1024.
Neither would have caught the other's source.
