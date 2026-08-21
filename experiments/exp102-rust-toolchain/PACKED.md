# Pack verification — exp102-rust-toolchain

verified: 2026-08-06
steps: 6 of 6 executed, 0 marked HUMAN STEP
host: Ubuntu, no board at any point
hash: 36eee99f75642a5c

The zip was unpacked into an empty directory and its `FLASH.txt` followed from
step 1 to step 6. This is the only experiment here whose walkthrough is about
the machine rather than the board, so there is nothing to flash and no LED.

What each step actually did:

    1  rust itself      rustup 1.29.0 (28d1352db 2026-03-05)
                        rustc 1.94.1 (e408947bf 2026-03-25)
    2  the target       thumbv8m.main-none-eabihf
    3  a C linker       cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
    4  the converter    elf2flash 0.1.0
    5  the proof        Finished `dev` profile ... in 0.08s
    6  get the repo     clone and ./check.sh — six PASS, exit 0

Steps 1 to 4 were already satisfied on this machine, so what was executed was
each step's CHECK command rather than its install command. Step 5 was run
verbatim, including the `cargo new` and the heredoc, in an empty /tmp
directory, and step 6's clone-and-check was run earlier the same day.

THREE THINGS THIS RUN FOUND AND FIXED, all the same gap seen at four depths:
an experiment that never touches a board was being handed hardware.

  * The zip carried pages/bootsel.html and pages/pflash.html — two pages for
    putting firmware on a board, in an experiment with no firmware and no
    board. pack.sh now omits them when USB_RUNS_ON is "none".
  * FLASH.txt printed three flashing routes, three ways a board can be wrong,
    and a note about host prerequisites. All of it is answered by "there is no
    board". Replaced with one paragraph that says so.
  * The contents list still named a pages/ directory that was no longer there,
    and pointed at a "WHAT IT RUNS ON" section that was no longer printed.
  * The generic line "you do not need the source, a compiler, or anything else
    in the repository" is false in the one experiment whose subject IS
    installing a compiler. Reworded for every experiment, not just this one.

exp140 is the other experiment with USB_RUNS_ON="none" and got the same
treatment, but has not been walked through yet.
