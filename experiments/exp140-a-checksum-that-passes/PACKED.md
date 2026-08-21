# Pack verification — exp140-a-checksum-that-passes

verified: 2026-08-06
steps: 4 of 4 executed, 0 marked HUMAN STEP
host: Ubuntu, no board at any point
hash: 459c92b820bf2403

The zip was unpacked into an empty directory and its `FLASH.txt` followed. This
is the second of two experiments here that never touch a board, and the only
one whose substance is a test suite rather than a firmware — so its walkthrough
says up front that step 1 is cloning the repository, rather than pretending a
zip can carry a crate.

What each step actually did:

    1  clone            done earlier the same day, from GitHub
    2  ./check.sh       7 PASS, exit 0
    3  read it          —
    4  cargo test       5 passed, including only_the_four_bytes_moved and
                        the_same_attack_does_not_forge_a_hash

ONE THING THIS RUN FOUND AND FIXED. Step 2's expected output named
`exp138.uf2` and a specific CRC, copied from the README's own capture. The run
printed `exp152.uf2` and a different CRC, because the script forges whichever
`.uf2` it finds first in the checkout and this one had plenty. The README's
older capture had already warned that the CRC varies; it had not noticed that
the FILENAME varies too, which is the more confusing of the two when the line
you are comparing against names a different experiment. Both parentheses are
now marked as varying, with the reason.

This is the failure mode the walkthroughs exist to catch: an expected output
that was true once, on one machine, in one state.
