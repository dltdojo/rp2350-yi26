# Pack verification — exp129-numbered-draws

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 3a11d96300befa7f

Unpacked into an empty directory, `FLASH.txt` followed. Two terminals.

    1  unzip      firmware/exp129-numbered-draws.uf2
    2  flash      [HUMAN STEP — machine substitute used]
    3  listen     warmed up: 2048 bits through the health tests, at 101 ms
    4  a draw     draw #1: 2300 in 2100-2567 (468 values)
                    256 of 2^32 rejected to keep it unbiased
    5  a smaller  draw #2: 2 in 1-10 (10 values)
                    6 of 2^32 rejected to keep it unbiased
    6  numbering  #1, #2 — every draw counted whether or not it was liked

The drawn numbers differ between runs, as they must. The rejection counts do
not: 256 for a range of 468, 6 for a range of 10, both runs. That number is
`2^32 mod range` and it is printed every time, so the fairness is arithmetic
on the line in front of you rather than something to take on trust.

Step 3 is easy to read past. The board pushes 2048 bits through exp114's
health tests before accepting any request at all, and finishes within about a
tenth of a second. A draw from an unchecked source is not a draw, and the
checking happens before anybody asks rather than after something looks wrong.

`yi26 send '2100-2567'` becomes `printf '2100-2567' > /dev/ttyACM0`. The
firmware's idle line names the tool, so pack.sh's automatic warning appears in
this zip's FLASH.txt and the walkthrough says to ignore that line.

Nothing was missing and nothing needed fixing.
