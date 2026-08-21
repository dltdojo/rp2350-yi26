# Pack verification — exp111-measuring-randomness

verified: 2026-08-06
steps: 5 of 5 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: fa3f9091abbbd0dc

Unpacked into an empty directory, `FLASH.txt` followed.

    1  unzip      firmware/exp111-measuring-randomness.uf2
    2  flash      [HUMAN STEP — machine substitute used]
    3  64 bits    trng 62.5%  adc-lsb 62.5%   — identical, and one is not random
    4  3264 bits  trng 50.6%  adc-lsb 38.0%
    5  the caveat —

Step 3 came out better than the walkthrough deserved: at 64 bits the good
source and the bad one printed the SAME number, 62.5% each. A reader could not
have picked the bad one with a coin.

ONE THING THIS RUN FOUND AND FIXED. Step 3 printed four specific percentages
under the word "Expect". They are noise — that is the entire content of the
step — and a reader comparing their run against them would be comparing two
samples of a random variable. The step now shows both runs side by side and
says outright that the numbers will not match.

A SECOND THING, recorded rather than fixed. The ADC's bottom bit is biased,
but not in a fixed direction: 69.4% ones in the README's older capture, 29.7%
during preparation, 38.0% from the zip — all on the same board. The
walkthrough says which way it walks is not fixed and that reading the bias is
not the lesson. What is reproducible is that the TRNG converges on half and
the ADC does not.
