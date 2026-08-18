# Pack verification — exp113-enumerable-seed

verified: 2026-08-06
steps: 5 of 5 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 92c03ebb894e3a62

Unpacked into an empty directory, `FLASH.txt` followed.

    1  unzip     firmware/exp113-enumerable-seed.uf2
    2  flash     [HUMAN STEP — machine substitute used]
    3  watch     otp identity 1f6ba31a
                 CRACKED: hidden value was 37615 us. 37616 candidates in 46 ms.
                 a full 2^24 sweep would take about 19373 ms (extrapolated)
    4  the ratio 2^24 space, 19373 ms to sweep it, 37616 tries, 46 ms
    5  the trap  bytes that pass every exp111 test, recovered in 46 ms

Reproduced across three boots. The OTP identity is stable (1f6ba31a, this
chip); the hidden boot duration moved between 37615, 37630 and 37638 us; the
crack took 46 ms every time. The walkthrough says which of those to expect to
match and which not to.

ONE THING THIS RUN FOUND AND FIXED, and it is the third appearance of the same
underlying nuisance.

  The whole demonstration is printed once, at about three seconds. Run from
  the zip, the board had been up eighteen seconds by the time the port was
  opened, and the serial buffer had already dropped it. What arrived was the
  periodic summary and nothing else — a reader following the walkthrough would
  have seen none of the block it told them to expect.

  The firmware already handles this: it repeats a one-line `result:` summary
  every ten seconds, carrying every number step 4 asks for. The walkthrough
  did not mention it. It now does, and gives the reboot-and-read-immediately
  route for anyone who wants the full block — verified afterwards, and it puts
  the 3037 ms block back on screen.

  exp107 is the experiment about this, exp110's timestamps were the second
  sighting, and this is the third. A walkthrough written by somebody watching
  from second zero quietly assumes its reader was too.
