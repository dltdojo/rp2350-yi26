# Pack verification — exp119-cancelled-reads

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 1cb2b3a46ea117ef

Unpacked into an empty directory, `FLASH.txt` followed, including pasting the
Python flood tool straight out of it.

    1  unzip        firmware/exp119-cancelled-reads.uf2
    2  flash        [HUMAN STEP — machine substitute used]
    3  write flood.py  pasted from FLASH.txt, parsed clean
    4  control run  20001 packets, 0 RTS toggles
                    -> 0 cancelled reads: this run has tested nothing
    5  storm run    20001 packets, 40002 RTS toggles
    6  the row      rx 20000  gaps 0  repeats 0  cancels 40002  runts 0

Forty thousand reads destroyed and reissued mid-flight, twenty thousand
packets, and not one byte lost, duplicated or truncated. Against step 4's row,
which carries the same three zeros and means nothing at all.

`yi26 flood` needed replacing rather than paraphrasing: the storm run has to
write packets and toggle RTS on the same open port at the same time, which no
combination of `printf` and `stty` can do. Eighteen lines of Python, standard
library only, and it produces the same shape of result.

ONE THING THIS RUN FOUND AND FIXED, and it was broken in two places at once.

  The flood tool is delivered by a heredoc. In the README the block sat inside
  a fence indented seven spaces, and pack.sh then added two more when lifting
  the section into FLASH.txt. A heredoc body is taken literally, so what a
  reader pasted was Python with nine leading spaces on every line:

      IndentationError: unexpected indent

  **A human following the README would have hit it too** — this was not a
  packaging artefact, the README was wrong on its own.

  Fixed in both places. The README's block now sits at the left margin and
  says why. pack.sh now tracks fenced blocks and leaves their contents at
  column zero while still indenting the prose around them, so any walkthrough
  that ships a program is safe from the same thing. Verified by extracting the
  heredoc from the packed FLASH.txt, running it, and parsing the result.

  This is the first walkthrough here to carry a program rather than commands,
  and it broke on the first thing a program cares about that prose does not.
