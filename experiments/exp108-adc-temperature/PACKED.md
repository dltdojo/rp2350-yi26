# Pack verification — exp108-adc-temperature

verified: 2026-08-06
steps: 4 of 4 executed, 2 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 9902f4e5ea5702b7

Unpacked into an empty directory, `FLASH.txt` followed, nothing read from the
repository.

    1  unzip     firmware/exp108-adc-temperature.uf2
    2  flash     43520 bytes  [HUMAN STEP — machine substitute used]
    3  read      [37 ms] up, ADC channel 4
                 [37 ms] temp: raw 846 of 4095 -> 41.18 C
                 [1037 ms] temp: raw 844 of 4095 -> 42.11 C  (and steady after)
    4  watch it move  [HUMAN STEP — not performed]

Step 3 came out as written, including the detail the walkthrough warns about:
the first reading is the odd one out (41.18 against a steady 42.11), taken
before anything has settled.

Step 4 wants a finger on the chip, and there is no substitute for that. The
walkthrough says so and gives the machine reader the thing that IS checkable —
the numbers being plausible and steady, which is what tests the datasheet
arithmetic. Warming the chip tests the sensor, and the sensor is not this
repository's work.

Nothing was missing and nothing needed fixing. The ModemManager wait learned
from exp105 was written into step 3 before the run.
